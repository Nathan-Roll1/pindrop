//
//  DictationAudioEncoder.swift
//  PindropMedia
//
//  Created on 2026-07-09.
//

import AVFoundation
import Foundation

/// Encodes float32 PCM dictation buffers to AAC `.m4a` under the managed DictationAudio area.
/// Preferred input is the native-rate copy kept by `AudioRecorder` (44.1/48 kHz) so retained
/// audio isn't telephone-bandwidth; the 16 kHz ASR feed remains the fallback. Sub-32 kHz
/// input is resampled to 44.1 kHz (Core Audio rejects MPEG-4 AAC at 16 kHz).
public enum DictationAudioEncoder {
    /// Sample rate of the ASR-feed PCM from `AudioRecorder` (fallback input).
    public static let inputSampleRate: Double = 16_000
    /// AAC-friendly output rate for low-rate input.
    public static let outputSampleRate: Double = 44_100
    public static let channelCount: AVAudioChannelCount = 1
    public static let bitRate = 96_000

    /// AAC output rate for a given input: keep native rates the encoder accepts,
    /// resample only genuinely low-rate input.
    public static func encodeSampleRate(forInputRate inputRate: Double) -> Double {
        inputRate >= 32_000 ? inputRate : outputSampleRate
    }

    public static func encodePCMFloatData(
        _ audioData: Data,
        to destinationURL: URL,
        inputSampleRate: Double = inputSampleRate,
        channelCount: AVAudioChannelCount = channelCount
    ) throws {
        try Task.checkCancellation()

        let sampleCount = audioData.count / MemoryLayout<Float>.size
        guard sampleCount > 0 else {
            throw DictationAudioError.emptyAudio
        }

        guard let inputFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: inputSampleRate,
            channels: channelCount,
            interleaved: false
        ),
        let inputBuffer = AVAudioPCMBuffer(
            pcmFormat: inputFormat,
            frameCapacity: AVAudioFrameCount(sampleCount)
        ),
        let inputChannelData = inputBuffer.floatChannelData else {
            throw DictationAudioError.encodingFailed("Unable to prepare PCM buffer for AAC encode.")
        }

        inputBuffer.frameLength = AVAudioFrameCount(sampleCount)
        audioData.withUnsafeBytes { rawBuffer in
            guard let source = rawBuffer.bindMemory(to: Float.self).baseAddress else { return }
            inputChannelData[0].update(from: source, count: sampleCount)
        }

        // Resample only when the input rate isn't AAC-friendly (sub-32 kHz).
        let encodeRate = encodeSampleRate(forInputRate: inputSampleRate)
        let encodeBuffer: AVAudioPCMBuffer
        if abs(inputSampleRate - encodeRate) < 0.5 {
            encodeBuffer = inputBuffer
        } else {
            try Task.checkCancellation()
            encodeBuffer = try resample(inputBuffer, toSampleRate: encodeRate)
        }

        try Task.checkCancellation()
        try writeEncodeBuffer(
            encodeBuffer,
            to: destinationURL,
            channelCount: channelCount
        )
    }

    /// Streams a raw Float32 PCM spool into the AAC writer in small buffers so
    /// native capture never has to coexist with a second full-size Data value.
    public static func encodePCMFloatFile(
        _ sourceURL: URL,
        to destinationURL: URL,
        inputSampleRate: Double,
        channelCount: AVAudioChannelCount = channelCount
    ) throws {
        try Task.checkCancellation()

        guard let inputFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: inputSampleRate,
            channels: channelCount,
            interleaved: false
        ) else {
            throw DictationAudioError.encodingFailed("Unable to prepare PCM format for AAC encode.")
        }
        let encodeRate = encodeSampleRate(forInputRate: inputSampleRate)
        let parent = destinationURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)

        // Stage into a unique temp file so cancellation / superseding work cannot
        // leave a half-written destination visible under the final media path.
        let stagingURL = destinationURL
            .deletingLastPathComponent()
            .appendingPathComponent(".\(destinationURL.deletingPathExtension().lastPathComponent).\(UUID().uuidString).tmp")
            .appendingPathExtension(destinationURL.pathExtension)
        defer {
            if FileManager.default.fileExists(atPath: stagingURL.path) {
                try? FileManager.default.removeItem(at: stagingURL)
            }
        }

        if FileManager.default.fileExists(atPath: stagingURL.path) {
            try FileManager.default.removeItem(at: stagingURL)
        }

        let outputFile = try AVAudioFile(
            forWriting: stagingURL,
            settings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: encodeRate,
                AVNumberOfChannelsKey: Int(channelCount),
                AVEncoderBitRateKey: bitRate
            ],
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )
        let converter: AVAudioConverter?
        if abs(inputSampleRate - encodeRate) < 0.5 {
            converter = nil
        } else {
            guard let outputFormat = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: encodeRate,
                channels: channelCount,
                interleaved: false
            ) else {
                throw DictationAudioError.encodingFailed("Unable to create AAC resample format.")
            }
            converter = AVAudioConverter(from: inputFormat, to: outputFormat)
        }

        let sourceHandle = try FileHandle(forReadingFrom: sourceURL)
        defer { try? sourceHandle.close() }
        let framesPerChunk = 16_384
        var wroteFrames = false
        while true {
            try Task.checkCancellation()
            let data = sourceHandle.readData(ofLength: framesPerChunk * MemoryLayout<Float>.size)
            guard !data.isEmpty else { break }
            let frameCount = data.count / MemoryLayout<Float>.size
            guard let inputBuffer = AVAudioPCMBuffer(
                pcmFormat: inputFormat,
                frameCapacity: AVAudioFrameCount(frameCount)
            ), let channelData = inputBuffer.floatChannelData else {
                throw DictationAudioError.encodingFailed("Unable to prepare PCM chunk for AAC encode.")
            }
            inputBuffer.frameLength = AVAudioFrameCount(frameCount)
            data.withUnsafeBytes { rawBuffer in
                channelData[0].update(
                    from: rawBuffer.bindMemory(to: Float.self).baseAddress!,
                    count: frameCount
                )
            }
            if let converter {
                let outputCapacity = AVAudioFrameCount(Double(frameCount) * encodeRate / inputSampleRate) + 32
                guard let outputBuffer = AVAudioPCMBuffer(
                    pcmFormat: converter.outputFormat,
                    frameCapacity: outputCapacity
                ) else {
                    throw DictationAudioError.encodingFailed("Unable to prepare resample chunk for AAC encode.")
                }
                var consumed = false
                var conversionError: NSError?
                let status = converter.convert(to: outputBuffer, error: &conversionError) { _, outStatus in
                    if consumed {
                        outStatus.pointee = .noDataNow
                        return nil
                    }
                    consumed = true
                    outStatus.pointee = .haveData
                    return inputBuffer
                }
                if let conversionError { throw DictationAudioError.encodingFailed(conversionError.localizedDescription) }
                guard status != .error else {
                    throw DictationAudioError.encodingFailed("Audio resampler failed.")
                }
                if outputBuffer.frameLength > 0 { try outputFile.write(from: outputBuffer) }
            } else {
                try outputFile.write(from: inputBuffer)
            }
            wroteFrames = true
        }
        guard wroteFrames else { throw DictationAudioError.emptyAudio }

        try Task.checkCancellation()
        if FileManager.default.fileExists(atPath: destinationURL.path) {
            try FileManager.default.removeItem(at: destinationURL)
        }
        try FileManager.default.moveItem(at: stagingURL, to: destinationURL)
    }

    private static func writeEncodeBuffer(
        _ encodeBuffer: AVAudioPCMBuffer,
        to destinationURL: URL,
        channelCount: AVAudioChannelCount
    ) throws {
        let parent = destinationURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)

        let stagingURL = destinationURL
            .deletingLastPathComponent()
            .appendingPathComponent(".\(destinationURL.deletingPathExtension().lastPathComponent).\(UUID().uuidString).tmp")
            .appendingPathExtension(destinationURL.pathExtension)
        defer {
            if FileManager.default.fileExists(atPath: stagingURL.path) {
                try? FileManager.default.removeItem(at: stagingURL)
            }
        }

        if FileManager.default.fileExists(atPath: stagingURL.path) {
            try FileManager.default.removeItem(at: stagingURL)
        }

        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: encodeBuffer.format.sampleRate,
            AVNumberOfChannelsKey: Int(channelCount),
            AVEncoderBitRateKey: bitRate
        ]

        do {
            let outputFile = try AVAudioFile(
                forWriting: stagingURL,
                settings: settings,
                commonFormat: .pcmFormatFloat32,
                interleaved: false
            )
            try outputFile.write(from: encodeBuffer)
        } catch {
            throw DictationAudioError.encodingFailed(error.localizedDescription)
        }

        try Task.checkCancellation()
        if FileManager.default.fileExists(atPath: destinationURL.path) {
            try FileManager.default.removeItem(at: destinationURL)
        }
        try FileManager.default.moveItem(at: stagingURL, to: destinationURL)
    }

    private static func resample(
        _ inputBuffer: AVAudioPCMBuffer,
        toSampleRate outputSampleRate: Double
    ) throws -> AVAudioPCMBuffer {
        let inputFormat = inputBuffer.format
        guard let outputFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: outputSampleRate,
            channels: inputFormat.channelCount,
            interleaved: false
        ) else {
            throw DictationAudioError.encodingFailed("Unable to create AAC resample format.")
        }

        guard let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else {
            throw DictationAudioError.encodingFailed("Unable to create audio converter for AAC encode.")
        }

        let ratio = outputSampleRate / inputFormat.sampleRate
        let capacity = AVAudioFrameCount(Double(inputBuffer.frameLength) * ratio) + 32
        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else {
            throw DictationAudioError.encodingFailed("Unable to allocate resample buffer.")
        }

        var inputConsumed = false
        var error: NSError?
        let status = converter.convert(to: outputBuffer, error: &error) { _, outStatus in
            if inputConsumed {
                outStatus.pointee = .endOfStream
                return nil
            }
            inputConsumed = true
            outStatus.pointee = .haveData
            return inputBuffer
        }

        if let error {
            throw DictationAudioError.encodingFailed(error.localizedDescription)
        }
        guard status != .error else {
            throw DictationAudioError.encodingFailed("Audio resampler failed.")
        }
        guard outputBuffer.frameLength > 0 else {
            throw DictationAudioError.encodingFailed("Audio resampler produced empty buffer.")
        }

        return outputBuffer
    }
}

public enum DictationAudioError: Error, LocalizedError {
    case emptyAudio
    case encodingFailed(String)

    public var errorDescription: String? {
        switch self {
        case .emptyAudio:
            return "No audio samples to encode."
        case .encodingFailed(let message):
            return "Failed to encode dictation audio: \(message)"
        }
    }
}
