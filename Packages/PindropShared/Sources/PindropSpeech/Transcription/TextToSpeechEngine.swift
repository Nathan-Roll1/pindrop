//
//  TextToSpeechEngine.swift
//  PindropSpeech
//
//  Created on 2026-01-30.
//

import AVFoundation
import Foundation
import PindropCore

public enum SystemTextToSpeechError: Error, LocalizedError, Equatable {
    case modelNotLoaded
    case emptyText
    case voiceUnavailable(String)
    case synthesisFailed(String)
    case writeFailed(String)

    public var errorDescription: String? {
        switch self {
        case .modelNotLoaded:
            return "Text-to-speech engine is not loaded."
        case .emptyText:
            return "Cannot synthesize empty text."
        case .voiceUnavailable(let id):
            return "Requested TTS voice is unavailable: \(id)"
        case .synthesisFailed(let message):
            return "Speech synthesis failed: \(message)"
        case .writeFailed(let message):
            return "Unable to write synthesized audio: \(message)"
        }
    }
}

/// On-device TTS backend backed by `AVSpeechSynthesizer`.
///
/// Construction is side-effect free. Voice enumeration and synthesis run only from
/// explicit `loadModel` / `synthesize` calls. Uses Core `TextToSpeechEngine` contracts.
@MainActor
public final class SystemTextToSpeechEngine: NSObject, TextToSpeechEngine {
    public private(set) var state: TextToSpeechState = .unloaded
    public private(set) var availableVoices: [TTSVoice] = []
    public private(set) var currentVoice: TTSVoice?
    public private(set) var error: Error?

    private let synthesizer = AVSpeechSynthesizer()
    /// PCM sample rate used when writing synthesis buffers via `AVSpeechSynthesizer.write`.
    private let outputSampleRate = 22_050

    public override init() {
        super.init()
    }

    public func loadModel() async throws {
        state = .loading
        error = nil

        let voices = AVSpeechSynthesisVoice.speechVoices().map(Self.mapVoice(_:))
        availableVoices = voices

        if currentVoice == nil {
            if let preferred = AVSpeechSynthesisVoice(language: Locale.current.identifier).map(Self.mapVoice) {
                currentVoice = preferred
            } else {
                currentVoice = voices.first
            }
        } else if let selected = currentVoice,
                  !voices.contains(where: { $0.id == selected.id }) {
            currentVoice = voices.first
        }

        state = .ready
    }

    public func unloadModel() async {
        if synthesizer.isSpeaking {
            synthesizer.stopSpeaking(at: .immediate)
        }
        availableVoices = []
        currentVoice = nil
        error = nil
        state = .unloaded
    }

    public func setVoice(_ voice: TTSVoice) async throws {
        guard state == .ready || state == .synthesizing else {
            throw SystemTextToSpeechError.modelNotLoaded
        }
        guard availableVoices.contains(where: { $0.id == voice.id })
            || AVSpeechSynthesisVoice(identifier: voice.id) != nil else {
            throw SystemTextToSpeechError.voiceUnavailable(voice.id)
        }
        currentVoice = voice
    }

    public func synthesize(text: String) async throws -> SpeechSynthesisResult {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw SystemTextToSpeechError.emptyText
        }
        guard state == .ready || state == .synthesizing, let voice = currentVoice else {
            throw SystemTextToSpeechError.modelNotLoaded
        }

        state = .synthesizing
        error = nil

        do {
            let result = try await render(text: trimmed, voice: voice)
            state = .ready
            return result
        } catch {
            state = .ready
            self.error = error
            throw error
        }
    }

    public func synthesizeToFile(text: String, outputURL: URL) async throws {
        let result = try await synthesize(text: text)
        do {
            let parent = outputURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: outputURL.path) {
                try FileManager.default.removeItem(at: outputURL)
            }
            try result.audioData.write(to: outputURL, options: .atomic)
        } catch let error as SystemTextToSpeechError {
            throw error
        } catch {
            throw SystemTextToSpeechError.writeFailed(error.localizedDescription)
        }
    }

    // MARK: - Private

    private func render(text: String, voice: TTSVoice) async throws -> SpeechSynthesisResult {
        let utterance = AVSpeechUtterance(string: text)
        if let systemVoice = AVSpeechSynthesisVoice(identifier: voice.id) {
            utterance.voice = systemVoice
        } else if let languageVoice = AVSpeechSynthesisVoice(language: voice.language) {
            utterance.voice = languageVoice
        } else {
            throw SystemTextToSpeechError.voiceUnavailable(voice.id)
        }

        let collector = SynthesisBufferCollector(defaultSampleRate: outputSampleRate)

        return try await withCheckedThrowingContinuation { continuation in
            collector.onFinish = { result in
                continuation.resume(with: result)
            }
            synthesizer.write(utterance) { buffer in
                collector.consume(buffer)
            }
        }
    }

    private static func mapVoice(_ voice: AVSpeechSynthesisVoice) -> TTSVoice {
        TTSVoice(
            id: voice.identifier,
            name: voice.name,
            language: voice.language,
            gender: mapGender(voice.gender)
        )
    }

    private static func mapGender(_ gender: AVSpeechSynthesisVoiceGender) -> TTSVoiceGender {
        switch gender {
        case .male:
            return .male
        case .female:
            return .female
        case .unspecified:
            return .neutral
        @unknown default:
            return .neutral
        }
    }
}

/// Collects PCM buffers from `AVSpeechSynthesizer.write`. The write callback is not
/// MainActor-isolated, so accumulation lives off the actor behind a lock.
private final class SynthesisBufferCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var pcmFrames: [Float] = []
    private var sampleRate: Int
    private var didFinish = false
    var onFinish: ((Result<SpeechSynthesisResult, Error>) -> Void)?

    init(defaultSampleRate: Int) {
        self.sampleRate = defaultSampleRate
    }

    func consume(_ buffer: AVAudioBuffer) {
        guard let pcmBuffer = buffer as? AVAudioPCMBuffer else {
            finish(.failure(SystemTextToSpeechError.synthesisFailed("Unexpected non-PCM synthesis buffer.")))
            return
        }

        // Empty frame length signals end-of-stream for write(_:toBufferCallback:).
        if pcmBuffer.frameLength == 0 {
            lock.lock()
            let frames = pcmFrames
            let rate = sampleRate
            lock.unlock()

            guard !frames.isEmpty else {
                finish(.failure(SystemTextToSpeechError.synthesisFailed("No audio buffers produced.")))
                return
            }

            var data = Data(count: frames.count * MemoryLayout<Float>.size)
            data.withUnsafeMutableBytes { raw in
                guard let dest = raw.bindMemory(to: Float.self).baseAddress else { return }
                frames.withUnsafeBufferPointer { source in
                    guard let base = source.baseAddress else { return }
                    dest.update(from: base, count: frames.count)
                }
            }
            let duration = TimeInterval(frames.count) / TimeInterval(max(rate, 1))
            finish(.success(SpeechSynthesisResult(
                audioData: data,
                sampleRate: rate,
                duration: duration
            )))
            return
        }

        guard let channelData = pcmBuffer.floatChannelData else { return }
        let frameLength = Int(pcmBuffer.frameLength)
        let channel = channelData[0]
        let rate = Int(pcmBuffer.format.sampleRate.rounded())

        lock.lock()
        if rate > 0 {
            sampleRate = rate
        }
        pcmFrames.append(contentsOf: UnsafeBufferPointer(start: channel, count: frameLength))
        lock.unlock()
    }

    private func finish(_ result: Result<SpeechSynthesisResult, Error>) {
        lock.lock()
        let alreadyFinished = didFinish
        if !alreadyFinished {
            didFinish = true
        }
        let callback = onFinish
        lock.unlock()

        guard !alreadyFinished else { return }
        callback?(result)
    }
}
