//
//  MediaPreparationService.swift
//  PindropMedia
//
//  AVFoundation-backed media audio preparation for transcription.
//  External-process fallback is injected by the host via MediaFallbackTranscoding.
//

@preconcurrency import AVFoundation
import Foundation
import PindropCore

@MainActor
public final class MediaPreparationService: MediaAudioPreparing {
    private let worker: MediaAudioPreparationWorker

    public init(
        fileManager: FileManager = .default,
        temporaryDirectory: URL? = nil,
        fallbackTranscoder: (any MediaFallbackTranscoding)? = nil
    ) {
        worker = MediaAudioPreparationWorker(
            fileManager: fileManager,
            temporaryDirectory: temporaryDirectory ?? fileManager.temporaryDirectory,
            fallbackTranscoder: fallbackTranscoder
        )
    }

    public func prepareAudio(from mediaURL: URL) async throws -> PreparedMediaAudio {
        try await worker.prepare(mediaURL)
    }
}

/// Keeps synchronous AVFoundation decode and conversion work off the main actor.
private actor MediaAudioPreparationWorker {
    private let fileManager: FileManager
    private let temporaryDirectory: URL
    private let fallbackTranscoder: (any MediaFallbackTranscoding)?
    private static let targetSampleRate: Double = 16_000
    // Target buffer size per read — small enough to tolerate malformed packet
    // tables on ~MB boundaries instead of blowing up on a single multi-GB read.
    private static let readChunkFrames: AVAudioFrameCount = 1 << 17  // 131 072 frames ≈ 2.7s @ 48 kHz

    init(
        fileManager: FileManager = .default,
        temporaryDirectory: URL,
        fallbackTranscoder: (any MediaFallbackTranscoding)?
    ) {
        self.fileManager = fileManager
        self.temporaryDirectory = temporaryDirectory
        self.fallbackTranscoder = fallbackTranscoder
    }

    func prepare(_ mediaURL: URL) async throws -> PreparedMediaAudio {
        try Task.checkCancellation()
        let fileSize = (try? fileManager.attributesOfItem(atPath: mediaURL.path)[.size] as? NSNumber)?.int64Value ?? -1
        let uti = (try? mediaURL.resourceValues(forKeys: [.contentTypeKey]).contentType?.identifier) ?? "unknown"
        let hasFallback = fallbackTranscoder != nil
        Log.app.info(
            "MediaPreparation: begin source=\(mediaURL.lastPathComponent) " +
            "ext=\(mediaURL.pathExtension) size=\(fileSize) uti=\(uti) " +
            "fallbackAvailable=\(hasFallback)"
        )

        // 1. Try the fast path: AVAudioFile directly on the source.
        if let prepared = try await tryPrepareWithAVAudioFile(url: mediaURL, label: "direct") {
            return prepared
        }
        try Task.checkCancellation()

        // 2. Host-injected fallback transcoder (e.g. macOS ffmpeg adapter).
        //    Most robust path for malformed packet tables, HLS segments, or
        //    exotic containers that AVAssetExportSession inherits bugs from.
        if let fallbackTranscoder {
            do {
                let wavURL = try await fallbackTranscode(
                    mediaURL: mediaURL,
                    fallback: fallbackTranscoder
                )
                defer { try? fileManager.removeItem(at: wavURL) }
                if let prepared = try await tryPrepareWithAVAudioFile(url: wavURL, label: "fallback") {
                    return prepared
                }
                Log.app.warning(
                    "MediaPreparation: fallback PCM still not readable by AVAudioFile, falling back to AVAssetExportSession"
                )
            } catch {
                if error is CancellationError {
                    throw error
                }
                Log.app.warning(
                    "MediaPreparation: fallback transcode failed — \(error.localizedDescription). Falling back to AVAssetExportSession"
                )
            }
        }
        try Task.checkCancellation()

        // 3. AVAssetExportSession → m4a when direct open fails.
        do {
            let exportedURL = try await exportAudioTrack(from: mediaURL)
            defer { try? fileManager.removeItem(at: exportedURL) }
            try Task.checkCancellation()
            if let prepared = try await tryPrepareWithAVAudioFile(url: exportedURL, label: "export") {
                return prepared
            }
        } catch {
            if error is CancellationError {
                throw error
            }
            // Host-supplied fallback already failed (or was absent). Surface the
            // AVFoundation failure; without a fallback, map to unsupported media.
            if fallbackTranscoder == nil {
                if let preparationError = error as? MediaPreparationError,
                   case .unsupportedMedia = preparationError {
                    throw preparationError
                }
                throw MediaPreparationError.unsupportedMedia(
                    (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                )
            }
            throw error
        }

        // All decode paths exhausted.
        if fallbackTranscoder == nil {
            throw MediaPreparationError.unsupportedMedia(
                "None of the decode paths could read this media."
            )
        }

        throw MediaPreparationError.readFailed(
            "None of the decode paths could read this media."
        )
    }

    // MARK: - AVAudioFile path

    /// Open `url` with AVAudioFile and convert to 16 kHz mono Float32 via
    /// chunked reads. Returns `nil` if the open itself fails — the caller
    /// should fall through to a more aggressive decode. Any failure *after*
    /// a successful open (mid-read, converter allocation) is thrown so the
    /// caller can surface or log it.
    private func tryPrepareWithAVAudioFile(url: URL, label: String) async throws -> PreparedMediaAudio? {
        let audioFile: AVAudioFile
        do {
            audioFile = try AVAudioFile(forReading: url)
        } catch {
            Log.app.info("MediaPreparation[\(label)]: AVAudioFile open failed — \(error.localizedDescription)")
            return nil
        }

        let inputFormat = audioFile.processingFormat
        let totalFrames = audioFile.length
        Log.app.info(
            "MediaPreparation[\(label)]: opened frames=\(totalFrames) " +
            "sampleRate=\(inputFormat.sampleRate) channels=\(inputFormat.channelCount) " +
            "common=\(inputFormat.commonFormat.rawValue) interleaved=\(inputFormat.isInterleaved)"
        )

        guard totalFrames > 0 else {
            // AVAudioFile can open some containers (notably MP4 with AAC) and
            // report 0 frames because it doesn't decode the inner track.
            // Signal the caller to try another decode path instead of
            // producing a silent transcript.
            Log.app.warning("MediaPreparation[\(label)]: file reports zero frames, falling through to next decode path")
            return nil
        }

        let outputFormat = Self.targetFormat
        guard let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else {
            throw MediaPreparationError.conversionFailed("Unable to initialize audio converter.")
        }

        var accumulated = Data()
        // Reserve a generous capacity to reduce reallocations.
        let expectedOutputFrames = Int(Double(totalFrames) * outputFormat.sampleRate / max(inputFormat.sampleRate, 1))
        accumulated.reserveCapacity(max(0, expectedOutputFrames) * MemoryLayout<Float>.size)

        do {
            try await readAndConvert(
                audioFile: audioFile,
                inputFormat: inputFormat,
                outputFormat: outputFormat,
                converter: converter,
                into: &accumulated
            )
        } catch {
            Log.app.error("MediaPreparation[\(label)]: chunked read failed — \(error.localizedDescription)")
            // Signal the caller to try another decode path rather than surfacing here —
            // except for .conversionFailed which is definitive.
            if error is CancellationError || error is MediaPreparationError {
                throw error
            }
            return nil
        }

        let duration = Double(totalFrames) / max(inputFormat.sampleRate, 1)
        Log.app.info("MediaPreparation[\(label)]: success bytes=\(accumulated.count) duration=\(String(format: "%.2f", duration))s")
        return PreparedMediaAudio(audioData: accumulated, duration: duration)
    }

    private func readAndConvert(
        audioFile: AVAudioFile,
        inputFormat: AVAudioFormat,
        outputFormat: AVAudioFormat,
        converter: AVAudioConverter,
        into accumulated: inout Data
    ) async throws {
        guard let inputBuffer = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: Self.readChunkFrames) else {
            throw MediaPreparationError.readFailed("Unable to allocate input buffer.")
        }

        let sampleRatio = outputFormat.sampleRate / max(inputFormat.sampleRate, 1)
        let outputCapacity = AVAudioFrameCount(Double(Self.readChunkFrames) * sampleRatio) + 1024
        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: outputCapacity) else {
            throw MediaPreparationError.conversionFailed("Unable to allocate output buffer.")
        }

        final class ChunkState: @unchecked Sendable {
            var supplied = false
            var reachedEnd = false
        }
        let state = ChunkState()

        while true {
            try Task.checkCancellation()
            inputBuffer.frameLength = 0
            do {
                try audioFile.read(into: inputBuffer)
            } catch {
                // Per AVAudioFile docs, read throws once EOF/packet issues are
                // hit. If we already produced some samples treat it as the
                // natural end of stream; otherwise rethrow so the caller can
                // try another decode path.
                if accumulated.isEmpty {
                    throw MediaPreparationError.readFailed(error.localizedDescription)
                } else {
                    Log.app.warning("MediaPreparation: truncating read at tail — \(error.localizedDescription)")
                    break
                }
            }

            if inputBuffer.frameLength == 0 {
                break
            }

            state.supplied = false
            state.reachedEnd = (audioFile.framePosition >= audioFile.length)

            outputBuffer.frameLength = 0
            var conversionError: NSError?
            let status = converter.convert(to: outputBuffer, error: &conversionError) { _, outStatus in
                if state.supplied {
                    outStatus.pointee = state.reachedEnd ? .endOfStream : .noDataNow
                    return nil
                }
                state.supplied = true
                outStatus.pointee = .haveData
                return inputBuffer
            }

            if let conversionError {
                throw MediaPreparationError.conversionFailed(conversionError.localizedDescription)
            }

            if outputBuffer.frameLength > 0, let channelData = outputBuffer.floatChannelData {
                let frames = Int(outputBuffer.frameLength)
                let byteCount = frames * MemoryLayout<Float>.size
                channelData[0].withMemoryRebound(to: UInt8.self, capacity: byteCount) { ptr in
                    accumulated.append(ptr, count: byteCount)
                }
            }

            try Task.checkCancellation()

            if status == .endOfStream || state.reachedEnd {
                break
            }
        }
    }

    // MARK: - Host fallback path

    private func fallbackTranscode(
        mediaURL: URL,
        fallback: any MediaFallbackTranscoding
    ) async throws -> URL {
        let outputURL = temporaryDirectory
            .appendingPathComponent("pindrop-prep-\(UUID().uuidString)")
            .appendingPathExtension("wav")

        if fileManager.fileExists(atPath: outputURL.path) {
            try? fileManager.removeItem(at: outputURL)
        }

        Log.app.info(
            "MediaPreparation: launching fallback transcoder for \(mediaURL.lastPathComponent) → \(outputURL.lastPathComponent)"
        )

        do {
            try await fallback.transcodeToPCM(sourceURL: mediaURL, destinationURL: outputURL)
            try Task.checkCancellation()
            guard fileManager.fileExists(atPath: outputURL.path) else {
                throw MediaPreparationError.exportFailed("Fallback transcoder reported success but produced no output file.")
            }
            return outputURL
        } catch is CancellationError {
            // Leave the partial destination in place. A host Process adapter may
            // still be reaping a SIGTERM-ignoring child that writes residual
            // bytes; the host removes the file only after that child exits.
            throw CancellationError()
        } catch {
            try? fileManager.removeItem(at: outputURL)
            throw error
        }
    }

    // MARK: - AVAssetExportSession path (fallback)

    private func exportAudioTrack(from mediaURL: URL) async throws -> URL {
        let asset = AVURLAsset(url: mediaURL)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        guard !audioTracks.isEmpty else {
            throw MediaPreparationError.unsupportedMedia("No audio track was found.")
        }

        guard let exportSession = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
            throw MediaPreparationError.exportFailed("Unable to create export session.")
        }

        let outputURL = temporaryDirectory
            .appendingPathComponent("pindrop-export-\(UUID().uuidString)")
            .appendingPathExtension("m4a")

        if fileManager.fileExists(atPath: outputURL.path) {
            try? fileManager.removeItem(at: outputURL)
        }

        exportSession.outputURL = outputURL
        exportSession.outputFileType = .m4a
        exportSession.shouldOptimizeForNetworkUse = false

        await exportSession.export()

        if exportSession.status == .completed {
            Log.app.info("MediaPreparation: AVAssetExportSession produced \(outputURL.lastPathComponent)")
            return outputURL
        }

        throw MediaPreparationError.exportFailed(exportSession.error?.localizedDescription ?? "Export session did not complete.")
    }

    private static var targetFormat: AVAudioFormat {
        AVAudioFormat(standardFormatWithSampleRate: targetSampleRate, channels: 1)!
    }
}
