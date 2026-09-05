//
//  PreparedMediaAudio.swift
//  PindropMedia
//
//  Cross-platform media audio preparation contracts.
//

import Foundation

public struct PreparedMediaAudio: Equatable, Sendable {
    public let audioData: Data
    public let duration: TimeInterval

    public init(audioData: Data, duration: TimeInterval) {
        self.audioData = audioData
        self.duration = duration
    }
}

public protocol MediaAudioPreparing: Sendable {
    func prepareAudio(from mediaURL: URL) async throws -> PreparedMediaAudio
}

public enum MediaPreparationError: Error, LocalizedError, Sendable {
    case unsupportedMedia(String)
    case exportFailed(String)
    case readFailed(String)
    case conversionFailed(String)

    public var errorDescription: String? {
        switch self {
        case .unsupportedMedia(let message):
            return "Unsupported media: \(message)"
        case .exportFailed(let message):
            return "Failed to export audio from media: \(message)"
        case .readFailed(let message):
            return "Failed to read audio: \(message)"
        case .conversionFailed(let message):
            return "Failed to prepare audio for transcription: \(message)"
        }
    }
}
