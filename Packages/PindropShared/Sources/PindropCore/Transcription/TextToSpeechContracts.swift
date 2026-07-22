//
//  TextToSpeechContracts.swift
//  PindropCore
//
//  Created on 2026-07-22.
//

import Foundation

public struct SpeechSynthesisResult: Sendable, Equatable {
    public let audioData: Data
    public let sampleRate: Int
    public let duration: TimeInterval

    public init(audioData: Data, sampleRate: Int, duration: TimeInterval) {
        self.audioData = audioData
        self.sampleRate = sampleRate
        self.duration = duration
    }
}

public enum TTSVoiceGender: String, Sendable, Equatable {
    case male
    case female
    case neutral
}

public struct TTSVoice: Identifiable, Sendable, Equatable {
    public let id: String
    public let name: String
    public let language: String
    public let gender: TTSVoiceGender

    public init(id: String, name: String, language: String, gender: TTSVoiceGender) {
        self.id = id
        self.name = name
        self.language = language
        self.gender = gender
    }
}

public enum TextToSpeechState: Equatable, Sendable {
    case unloaded
    case loading
    case ready
    case synthesizing
    case error
}

@MainActor
public protocol TextToSpeechEngine: AnyObject {
    var state: TextToSpeechState { get }
    var availableVoices: [TTSVoice] { get }
    var currentVoice: TTSVoice? { get }

    func loadModel() async throws
    func unloadModel() async

    func setVoice(_ voice: TTSVoice) async throws

    func synthesize(text: String) async throws -> SpeechSynthesisResult
    func synthesize(text: String, voice: TTSVoice) async throws -> SpeechSynthesisResult

    func synthesizeToFile(text: String, outputURL: URL) async throws
}

extension TextToSpeechEngine {
    public func synthesize(text: String, voice: TTSVoice) async throws -> SpeechSynthesisResult {
        try await setVoice(voice)
        return try await synthesize(text: text)
    }
}
