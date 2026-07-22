//
//  StreamingTranscriptionContracts.swift
//  PindropCore
//
//  Created on 2026-07-22.
//
//  Foundation-only streaming result/state/callback contracts. The engine protocol
//  method that accepts AVAudioPCMBuffer stays in PindropSpeech.
//

import Foundation

public struct StreamingTranscriptionResult: Sendable, Equatable {
    public let text: String
    public let isFinal: Bool
    public let confidence: Float?
    public let timestamp: TimeInterval

    public init(text: String, isFinal: Bool, confidence: Float? = nil, timestamp: TimeInterval = 0) {
        self.text = text
        self.isFinal = isFinal
        self.confidence = confidence
        self.timestamp = timestamp
    }
}

public enum StreamingTranscriptionState: Equatable, Sendable {
    case unloaded
    case loading
    case ready
    case streaming
    case paused
    case error
}

public typealias StreamingTranscriptionCallback = @Sendable (StreamingTranscriptionResult) -> Void
public typealias EndOfUtteranceCallback = @Sendable (String) -> Void

/// Foundation-only surface for streaming engines.
///
/// Deliberately NOT `@MainActor`: per-buffer decode must never queue behind UI work.
/// Concrete engines may refine this with AVFoundation buffer methods in PindropSpeech.
public protocol StreamingTranscriptionEngine: AnyObject {
    var state: StreamingTranscriptionState { get async }

    func loadModel(name: String) async throws
    /// Releases the model and ends callback production for the current session.
    /// Once this method returns, no callback originating before the unload may
    /// ever be invoked, even if this concrete instance is loaded again later.
    func unloadModel() async

    func startStreaming() async throws
    func stopStreaming() async throws -> String
    func pauseStreaming() async
    func resumeStreaming() async throws

    func processAudioChunk(_ samples: [Float]) async throws

    func setTranscriptionCallback(_ callback: @escaping StreamingTranscriptionCallback) async
    func setEndOfUtteranceCallback(_ callback: @escaping EndOfUtteranceCallback) async

    /// Ends the current streaming session and drains its callback production.
    /// Once this method returns, callbacks originating in any prior session must
    /// never be invoked. A subsequent `startStreaming()` begins a fresh session.
    func reset() async
}

extension StreamingTranscriptionEngine {
    public func processAudioChunk(_ data: Data) async throws {
        let samples = data.withUnsafeBytes { bytes in
            Array(bytes.bindMemory(to: Float.self))
        }
        try await processAudioChunk(samples)
    }
}
