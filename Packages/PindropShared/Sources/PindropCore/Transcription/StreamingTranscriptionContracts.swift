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
    /// Seconds of audio the engine had consumed when it produced this text.
    ///
    /// The engine's own consumption counter, carried as data. A consumer must
    /// never read a clock when an emission arrives instead: emissions coalesce
    /// and hop isolation before delivery, so arrival time is arbitrarily late.
    public let fedSeconds: TimeInterval

    public init(
        text: String,
        isFinal: Bool,
        confidence: Float? = nil,
        timestamp: TimeInterval = 0,
        fedSeconds: TimeInterval = 0
    ) {
        self.text = text
        self.isFinal = isFinal
        self.confidence = confidence
        self.timestamp = timestamp
        self.fedSeconds = fedSeconds
    }
}

/// One piece of streaming text with the fed watermark that produced it.
///
/// What a streaming sink receives. `fedSeconds` is the engine's consumption
/// counter, not a clock read, so it stays correct after the delivery bridge
/// coalesces a burst of partials down to the survivor.
public struct StreamingTranscriptionEmission: Sendable, Equatable {
    public let text: String
    public let fedSeconds: TimeInterval

    public init(text: String, fedSeconds: TimeInterval = 0) {
        self.text = text
        self.fedSeconds = fedSeconds
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
public typealias EndOfUtteranceCallback = @Sendable (StreamingTranscriptionEmission) -> Void

/// Where a streaming sink receives text. Main-actor by contract: the delivery
/// bridge takes exactly one isolation hop and consumers draw from there.
public typealias StreamingEmissionSink =
    @MainActor @Sendable (StreamingTranscriptionEmission) async -> Void

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
