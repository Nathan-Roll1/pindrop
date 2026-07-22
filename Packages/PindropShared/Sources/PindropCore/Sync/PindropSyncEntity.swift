// Created on 2026-07-22

import Foundation

/// Stable identity for a synchronized entity kind.
public enum PindropSyncEntity: String, Codable, Sendable, CaseIterable {
    case transcription
    case mediaFolder
    case note
    case wordReplacement
    case vocabularyWord
    case customPromptPreset
}
