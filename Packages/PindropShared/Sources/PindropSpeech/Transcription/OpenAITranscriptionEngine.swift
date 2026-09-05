//
//  OpenAITranscriptionEngine.swift
//  PindropSpeech
//
//  Created on 2026-07-21.
//

import AVFoundation
import Foundation
import PindropCore

/// Testable URL loading seam for OpenAI transcription. Kept Speech-local so
/// `PindropSpeech` does not depend on `PindropAI`.
public protocol OpenAITranscriptionSession: AnyObject, Sendable {
    func data(for request: URLRequest) async throws -> (Data, URLResponse)
}

extension URLSession: OpenAITranscriptionSession {}

/// Remote OpenAI `/v1/audio/transcriptions` backend.
///
/// Network work is strictly caller-invoked (`loadModel` / `transcribe`).
/// Construction only stores injected dependencies.
public enum OpenAITranscriptionEngineError: Error, LocalizedError, Sendable, Equatable {
    case modelNotLoaded
    case unsupportedModel(String)
    case apiKeyMissing
    case invalidAudioData
    case audioEncodingFailed(String)
    case uploadTooLarge
    case invalidResponse
    case apiError(statusCode: Int, message: String)

    public var errorDescription: String? {
        switch self {
        case .modelNotLoaded:
            return "OpenAI transcription model is not loaded."
        case .unsupportedModel(let model):
            return "Unsupported OpenAI transcription model: \(model)"
        case .apiKeyMissing:
            return "Enter an OpenAI API key in Settings → Models before using cloud transcription."
        case .invalidAudioData:
            return "Invalid audio data. Expected 16 kHz mono Float32 PCM."
        case .audioEncodingFailed(let message):
            return "Unable to prepare audio for OpenAI: \(message)"
        case .uploadTooLarge:
            return "An encoded audio chunk exceeded OpenAI's 25 MB upload limit."
        case .invalidResponse:
            return "OpenAI returned an invalid transcription response."
        case .apiError(let statusCode, let message):
            return "OpenAI transcription failed (HTTP \(statusCode)): \(message)"
        }
    }
}

@MainActor
public final class OpenAITranscriptionEngine: TranscriptionEngine {
    /// Compatibility alias matching the previous nested `EngineError` name.
    public typealias EngineError = OpenAITranscriptionEngineError

    public private(set) var state: TranscriptionEngineState = .unloaded
    public private(set) var error: Error?

    nonisolated public static let defaultEndpoint = URL(string: "https://api.openai.com/v1/audio/transcriptions")!
    nonisolated private static let sampleRate = 16_000
    private static let bytesPerSample = MemoryLayout<Float>.size
    private static let maximumChunkDurationSeconds = 30 * 60
    private static let maximumUploadBytes = 25 * 1_024 * 1_024
    private static let modelIDs: [String: String] = [
        "openai_gpt-4o-transcribe": "gpt-4o-transcribe",
        "openai_gpt-4o-mini-transcribe": "gpt-4o-mini-transcribe"
    ]

    private let apiKeyProvider: @MainActor () throws -> String
    private let session: any OpenAITranscriptionSession
    private let endpoint: URL
    private var modelID: String?

    public init(
        apiKeyProvider: @escaping @MainActor () throws -> String,
        session: any OpenAITranscriptionSession = URLSession.shared,
        endpoint: URL = OpenAITranscriptionEngine.defaultEndpoint
    ) {
        self.apiKeyProvider = apiKeyProvider
        self.session = session
        self.endpoint = endpoint
    }

    public func loadModel(path: String) async throws {
        throw EngineError.unsupportedModel(path)
    }

    public func loadModel(name: String, downloadBase: URL?) async throws {
        state = .loading
        error = nil

        do {
            guard let resolvedModelID = Self.modelIDs[name] else {
                throw EngineError.unsupportedModel(name)
            }
            _ = try resolvedAPIKey()
            modelID = resolvedModelID
            state = .ready
        } catch {
            self.error = error
            state = .error
            throw error
        }
    }

    public func transcribe(audioData: Data, options: TranscriptionOptions) async throws -> String {
        guard state == .ready, let modelID else {
            throw EngineError.modelNotLoaded
        }
        guard !audioData.isEmpty,
              audioData.count.isMultiple(of: Self.bytesPerSample) else {
            throw EngineError.invalidAudioData
        }

        state = .transcribing
        error = nil

        do {
            let apiKey = try resolvedAPIKey()
            let maximumChunkBytes = Self.maximumChunkDurationSeconds
                * Self.sampleRate
                * Self.bytesPerSample
            let prompt = VocabularyBiasPrompt.assemblePrompt(words: options.vocabularyBiasWords)
            var transcripts: [String] = []
            transcripts.reserveCapacity((audioData.count + maximumChunkBytes - 1) / maximumChunkBytes)

            var offset = 0
            while offset < audioData.count {
                try Task.checkCancellation()
                let end = min(offset + maximumChunkBytes, audioData.count)
                let chunk = audioData.subdata(in: offset..<end)
                let encodedAudio = try await Self.encodeM4A(chunk)
                guard encodedAudio.count < Self.maximumUploadBytes else {
                    throw EngineError.uploadTooLarge
                }

                let transcript = try await transcribeChunk(
                    encodedAudio,
                    modelID: modelID,
                    apiKey: apiKey,
                    languageCode: options.language.whisperLanguageCode,
                    prompt: prompt
                )
                let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    transcripts.append(trimmed)
                }
                offset = end
            }

            state = .ready
            return transcripts.joined(separator: " ")
        } catch {
            state = .ready
            self.error = error
            throw error
        }
    }

    public func unloadModel() async {
        modelID = nil
        error = nil
        state = .unloaded
    }

    private func resolvedAPIKey() throws -> String {
        let key = try apiKeyProvider().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else {
            throw EngineError.apiKeyMissing
        }
        return key
    }

    private func transcribeChunk(
        _ audio: Data,
        modelID: String,
        apiKey: String,
        languageCode: String?,
        prompt: String?
    ) async throws -> String {
        let boundary = "Pindrop-\(UUID().uuidString)"
        var request = URLRequest(url: endpoint, timeoutInterval: 300)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = Self.multipartBody(
            boundary: boundary,
            modelID: modelID,
            languageCode: languageCode,
            prompt: prompt,
            audio: audio
        )

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw EngineError.invalidResponse
        }

        guard (200..<300).contains(httpResponse.statusCode) else {
            let message = (try? JSONDecoder().decode(APIErrorEnvelope.self, from: data))?.error.message
                ?? HTTPURLResponse.localizedString(forStatusCode: httpResponse.statusCode)
            let requestID = httpResponse.value(forHTTPHeaderField: "x-request-id") ?? "unavailable"
            Log.transcription.error(
                "OpenAI transcription request failed status=\(httpResponse.statusCode) requestID=\(requestID)"
            )
            throw EngineError.apiError(statusCode: httpResponse.statusCode, message: message)
        }

        guard let response = try? JSONDecoder().decode(TranscriptionResponse.self, from: data) else {
            throw EngineError.invalidResponse
        }
        return response.text
    }

    /// Encodes 16 kHz mono Float32 PCM to AAC `.m4a` for the OpenAI upload path.
    /// Behavior matches `DictationAudioEncoder.encodePCMFloatData` at the ASR sample rate
    /// (resample sub-32 kHz input to 44.1 kHz before AAC). Kept local so Speech does not
    /// depend on PindropMedia.
    nonisolated private static func encodeM4A(_ audioData: Data) async throws -> Data {
        do {
            return try await Task.detached(priority: .userInitiated) {
                let destination = FileManager.default.temporaryDirectory
                    .appendingPathComponent("pindrop-openai-\(UUID().uuidString)")
                    .appendingPathExtension("m4a")
                defer { try? FileManager.default.removeItem(at: destination) }

                try OpenAIAudioEncoder.encodePCMFloatData(audioData, to: destination)
                return try Data(contentsOf: destination)
            }.value
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as OpenAITranscriptionEngineError {
            throw error
        } catch {
            throw OpenAITranscriptionEngineError.audioEncodingFailed(error.localizedDescription)
        }
    }

    nonisolated private static func multipartBody(
        boundary: String,
        modelID: String,
        languageCode: String?,
        prompt: String?,
        audio: Data
    ) -> Data {
        var body = Data()
        appendField(name: "model", value: modelID, boundary: boundary, to: &body)
        if let languageCode {
            appendField(name: "language", value: languageCode, boundary: boundary, to: &body)
        }
        if let prompt {
            appendField(name: "prompt", value: prompt, boundary: boundary, to: &body)
        }

        append("--\(boundary)\r\n", to: &body)
        append("Content-Disposition: form-data; name=\"file\"; filename=\"audio.m4a\"\r\n", to: &body)
        append("Content-Type: audio/mp4\r\n\r\n", to: &body)
        body.append(audio)
        append("\r\n--\(boundary)--\r\n", to: &body)
        return body
    }

    nonisolated private static func appendField(
        name: String,
        value: String,
        boundary: String,
        to body: inout Data
    ) {
        append("--\(boundary)\r\n", to: &body)
        append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n", to: &body)
        append("\(value)\r\n", to: &body)
    }

    nonisolated private static func append(_ string: String, to data: inout Data) {
        data.append(contentsOf: string.utf8)
    }
}

// MARK: - Local AAC encode (mirrors Media DictationAudioEncoder for 16 kHz PCM)

/// Speech-local AAC helper used only by OpenAI upload preparation.
/// Keeps the same 16 kHz → 44.1 kHz resample + AAC bit-rate path as Media's encoder.
private enum OpenAIAudioEncoder {
    static let inputSampleRate: Double = 16_000
    static let outputSampleRate: Double = 44_100
    static let channelCount: AVAudioChannelCount = 1
    static let bitRate = 96_000

    static func encodeSampleRate(forInputRate inputRate: Double) -> Double {
        inputRate >= 32_000 ? inputRate : outputSampleRate
    }

    static func encodePCMFloatData(
        _ audioData: Data,
        to destinationURL: URL,
        inputSampleRate: Double = inputSampleRate,
        channelCount: AVAudioChannelCount = channelCount
    ) throws {
        try Task.checkCancellation()

        let sampleCount = audioData.count / MemoryLayout<Float>.size
        guard sampleCount > 0 else {
            throw OpenAITranscriptionEngineError.audioEncodingFailed("No audio samples to encode.")
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
            throw OpenAITranscriptionEngineError.audioEncodingFailed(
                "Unable to prepare PCM buffer for AAC encode."
            )
        }

        inputBuffer.frameLength = AVAudioFrameCount(sampleCount)
        audioData.withUnsafeBytes { rawBuffer in
            guard let source = rawBuffer.bindMemory(to: Float.self).baseAddress else { return }
            inputChannelData[0].update(from: source, count: sampleCount)
        }

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
            throw OpenAITranscriptionEngineError.audioEncodingFailed(error.localizedDescription)
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
            throw OpenAITranscriptionEngineError.audioEncodingFailed(
                "Unable to create AAC resample format."
            )
        }

        guard let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else {
            throw OpenAITranscriptionEngineError.audioEncodingFailed(
                "Unable to create audio converter for AAC encode."
            )
        }

        let ratio = outputSampleRate / inputFormat.sampleRate
        let capacity = AVAudioFrameCount(Double(inputBuffer.frameLength) * ratio) + 32
        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else {
            throw OpenAITranscriptionEngineError.audioEncodingFailed(
                "Unable to allocate resample buffer."
            )
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
            throw OpenAITranscriptionEngineError.audioEncodingFailed(error.localizedDescription)
        }
        guard status != .error else {
            throw OpenAITranscriptionEngineError.audioEncodingFailed("Audio resampler failed.")
        }
        guard outputBuffer.frameLength > 0 else {
            throw OpenAITranscriptionEngineError.audioEncodingFailed(
                "Audio resampler produced empty buffer."
            )
        }

        return outputBuffer
    }
}

private struct TranscriptionResponse: Decodable {
    let text: String
}

private struct APIErrorEnvelope: Decodable {
    struct APIError: Decodable {
        let message: String
    }

    let error: APIError
}
