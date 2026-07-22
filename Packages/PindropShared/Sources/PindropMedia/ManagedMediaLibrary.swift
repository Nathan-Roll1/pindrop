//
//  ManagedMediaLibrary.swift
//  PindropMedia
//
//  Created on 2026-07-22.
//

import AVFoundation
import Foundation
import ImageIO
import PindropCore
import UniformTypeIdentifiers

/// File-backed managed media library rooted at an injected base URL.
///
/// Hosts supply the root (for example Application Support/Pindrop/MediaLibrary on macOS,
/// or a sandbox container path on iOS). This type never reconstructs Application Support.
public final class ManagedMediaLibrary: MediaLibraryManaging, @unchecked Sendable {
    private let fileManager: FileManager

    /// Root directory for job folders and derived areas such as DictationAudio.
    public let baseURL: URL

    /// `baseURL/DictationAudio` - ordinary voice dictation audio.
    public var dictationAudioDirectoryURL: URL {
        baseURL.appendingPathComponent("DictationAudio", isDirectory: true)
    }

    /// Alias for `baseURL` kept for call-site clarity at composition roots.
    public var libraryBaseURL: URL {
        baseURL
    }

    public init(baseURL: URL, fileManager: FileManager = .default) {
        self.baseURL = baseURL
        self.fileManager = fileManager
    }

    public func makeJobDirectory(for jobID: UUID) throws -> URL {
        let directory = baseURL.appendingPathComponent(jobID.uuidString, isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    /// Ensures the DictationAudio area exists and returns its URL.
    public func ensureDictationAudioDirectory() throws -> URL {
        let directory = dictationAudioDirectoryURL
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    public func importLocalFile(at sourceURL: URL, jobID: UUID) async throws -> ManagedMediaAsset {
        let directoryURL = try makeJobDirectory(for: jobID)
        let destinationURL = directoryURL.appendingPathComponent("media").appendingPathExtension(sourceURL.pathExtension)

        do {
            if fileManager.fileExists(atPath: destinationURL.path) {
                try fileManager.removeItem(at: destinationURL)
            }
            try fileManager.copyItem(at: sourceURL, to: destinationURL)
        } catch {
            throw MediaLibraryError.localFileImportFailed(error.localizedDescription)
        }

        let thumbnailURL = try? await generateThumbnailIfPossible(for: destinationURL, in: directoryURL)

        return ManagedMediaAsset(
            directoryURL: directoryURL,
            mediaURL: destinationURL,
            thumbnailURL: thumbnailURL,
            sourceKind: .importedFile,
            displayName: sourceURL.lastPathComponent,
            hasSourceMetadataTitle: false,
            originalSourceURL: sourceURL.absoluteString
        )
    }

    public func storeRecordedAudio(
        _ audioData: Data,
        jobID: UUID,
        displayName: String,
        sourceKind: MediaSourceKind
    ) throws -> ManagedMediaAsset {
        let directoryURL = try makeJobDirectory(for: jobID)
        let destinationURL = directoryURL.appendingPathComponent("media").appendingPathExtension("caf")

        if fileManager.fileExists(atPath: destinationURL.path) {
            try fileManager.removeItem(at: destinationURL)
        }

        let format = AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1)
            ?? AVAudioFormat()
        guard format.sampleRate > 0,
              let buffer = AVAudioPCMBuffer(
                pcmFormat: format,
                frameCapacity: AVAudioFrameCount(audioData.count / MemoryLayout<Float>.size)
              ),
              let channelData = buffer.floatChannelData else {
            throw MediaLibraryError.localFileImportFailed("Unable to prepare recorded audio for storage.")
        }

        let samples = audioData.count / MemoryLayout<Float>.size
        buffer.frameLength = AVAudioFrameCount(samples)
        audioData.withUnsafeBytes { rawBuffer in
            guard let source = rawBuffer.bindMemory(to: Float.self).baseAddress else { return }
            channelData[0].update(from: source, count: samples)
        }

        do {
            let outputFile = try AVAudioFile(forWriting: destinationURL, settings: format.settings)
            try outputFile.write(from: buffer)
        } catch {
            throw MediaLibraryError.localFileImportFailed(error.localizedDescription)
        }

        return ManagedMediaAsset(
            directoryURL: directoryURL,
            mediaURL: destinationURL,
            thumbnailURL: nil,
            sourceKind: sourceKind,
            displayName: displayName,
            hasSourceMetadataTitle: false,
            originalSourceURL: nil
        )
    }

    public func finalizeDownloadedAsset(
        in directoryURL: URL,
        sourceURL: String,
        suggestedTitle: String?
    ) async throws -> ManagedMediaAsset {
        guard let mediaURL = try locatePrimaryMediaFile(in: directoryURL) else {
            throw MediaLibraryError.downloadedMediaMissing
        }

        let thumbnailURL: URL?
        if let existingThumbnail = locateThumbnail(in: directoryURL) {
            thumbnailURL = existingThumbnail
        } else {
            thumbnailURL = try? await generateThumbnailIfPossible(for: mediaURL, in: directoryURL)
        }

        let resolvedTitle = suggestedTitle?.trimmingCharacters(in: .whitespacesAndNewlines)

        return ManagedMediaAsset(
            directoryURL: directoryURL,
            mediaURL: mediaURL,
            thumbnailURL: thumbnailURL,
            sourceKind: .webLink,
            displayName: (resolvedTitle?.isEmpty == false ? resolvedTitle! : mediaURL.lastPathComponent),
            hasSourceMetadataTitle: resolvedTitle?.isEmpty == false,
            originalSourceURL: sourceURL
        )
    }

    private func locatePrimaryMediaFile(in directoryURL: URL) throws -> URL? {
        let items = try fileManager.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        )

        return items
            .filter { url in
                guard let type = UTType(filenameExtension: url.pathExtension.lowercased()) else {
                    return false
                }
                if type.conforms(to: .image) || type.conforms(to: .json) || type.conforms(to: .plainText) {
                    return false
                }
                return type.conforms(to: .audio) || type.conforms(to: .movie) || type.conforms(to: .mpeg4Movie) || type.conforms(to: .video)
            }
            .sorted {
                let leftSize = (try? $0.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                let rightSize = (try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                return leftSize > rightSize
            }
            .first
    }

    private func locateThumbnail(in directoryURL: URL) -> URL? {
        guard let items = try? fileManager.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            return nil
        }

        return items.first { url in
            guard let type = UTType(filenameExtension: url.pathExtension.lowercased()) else {
                return false
            }
            return type.conforms(to: .image)
        }
    }

    private func generateThumbnailIfPossible(for mediaURL: URL, in directoryURL: URL) async throws -> URL? {
        let asset = AVURLAsset(url: mediaURL)
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        guard !videoTracks.isEmpty else { return nil }

        let imageGenerator = AVAssetImageGenerator(asset: asset)
        imageGenerator.appliesPreferredTrackTransform = true

        let duration = try await asset.load(.duration)
        let seconds = max(duration.seconds.isFinite ? duration.seconds : 0, 0.1)
        let cgImage = try imageGenerator.copyCGImage(at: CMTime(seconds: min(1.0, seconds * 0.25), preferredTimescale: 600), actualTime: nil)
        let destinationURL = directoryURL.appendingPathComponent("thumbnail.png")

        guard let destination = CGImageDestinationCreateWithURL(destinationURL as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            return nil
        }

        CGImageDestinationAddImage(destination, cgImage, nil)
        guard CGImageDestinationFinalize(destination) else {
            return nil
        }

        return destinationURL
    }
}
