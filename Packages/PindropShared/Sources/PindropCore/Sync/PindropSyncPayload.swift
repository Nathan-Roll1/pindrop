// Created on 2026-07-22

import Foundation

/// Discriminated version-1 sync document body.
public enum PindropSyncPayload: Codable, Equatable, Sendable {
    case transcription(TranscriptionSyncPayload)
    case mediaFolder(MediaFolderSyncPayload)
    case note(NoteSyncPayload)
    case wordReplacement(WordReplacementSyncPayload)
    case vocabularyWord(VocabularyWordSyncPayload)
    case customPromptPreset(PromptPresetSyncPayload)
}
