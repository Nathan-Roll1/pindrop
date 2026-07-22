//
//  PindropSyncProjector.swift
//  PindropData
//
//  Created on 2026-07-22.
//

import Foundation
import PindropCore

/// Projects local SwiftData models into CloudKit-neutral ``PindropSyncDocument`` values.
///
/// Projection is outbound-only for this execution: there is no reverse/apply path.
/// Only step-3 DTO fields are included; host-local paths, metrics, usage counters,
/// speaker identity state, training contributions, and built-in presets are excluded.
@MainActor
public enum PindropSyncProjector {

    /// Projects a transcription record.
    ///
    /// Preserves the persisted diarization distinction:
    /// - `diarizationSegmentsJSON == nil` -> `diarizationSegments == nil`
    /// - valid JSON `[]` -> empty non-optional array
    /// - valid segments omit `speakerProfileID` and `speakerEmbedding`
    /// - malformed JSON throws ``PindropSyncProjectionError/invalidDiarization(recordID:)``
    public static func document(from record: TranscriptionRecord) throws -> PindropSyncDocument {
        let payload = TranscriptionSyncPayload(
            id: record.id,
            text: record.text,
            originalText: record.originalText,
            timestamp: record.timestamp,
            duration: record.duration,
            modelUsed: record.modelUsed,
            enhancedWith: record.enhancedWith,
            diarizationSegments: try projectDiarizationSegments(from: record),
            sourceKindRawValue: record.sourceKindRawValue,
            sourceDisplayName: record.sourceDisplayName,
            generatedTitle: record.generatedTitle,
            aiSummary: record.aiSummary,
            sourceTitleOriginRawValue: record.sourceTitleOriginRawValue,
            folderID: record.folder?.id,
            wordCount: record.wordCount,
            userEditedAt: record.userEditedAt
        )
        return PindropSyncDocument(payload: .transcription(payload))
    }

    /// Projects a media folder.
    public static func document(from folder: MediaFolder) -> PindropSyncDocument {
        let payload = MediaFolderSyncPayload(
            id: folder.id,
            name: folder.name,
            createdAt: folder.createdAt,
            updatedAt: folder.updatedAt
        )
        return PindropSyncDocument(payload: .mediaFolder(payload))
    }

    /// Projects a note.
    public static func document(from note: Note) -> PindropSyncDocument {
        let payload = NoteSyncPayload(
            id: note.id,
            title: note.title,
            content: note.content,
            tags: note.tags,
            sourceTranscriptionID: note.sourceTranscriptionID,
            createdAt: note.createdAt,
            updatedAt: note.updatedAt,
            isPinned: note.isPinned
        )
        return PindropSyncDocument(payload: .note(payload))
    }

    /// Projects a word replacement. Excludes local ``usageCount``.
    public static func document(from replacement: WordReplacement) -> PindropSyncDocument {
        let payload = WordReplacementSyncPayload(
            id: replacement.id,
            originals: replacement.originals,
            replacement: replacement.replacement,
            createdAt: replacement.createdAt,
            sortOrder: replacement.sortOrder,
            matchModeRawValue: replacement.matchModeRawValue
        )
        return PindropSyncDocument(payload: .wordReplacement(payload))
    }

    /// Projects a vocabulary word. Excludes local ``usageCount``.
    public static func document(from word: VocabularyWord) -> PindropSyncDocument {
        let payload = VocabularyWordSyncPayload(
            id: word.id,
            word: word.word,
            createdAt: word.createdAt
        )
        return PindropSyncDocument(payload: .vocabularyWord(payload))
    }

    /// Projects a custom prompt preset.
    ///
    /// Returns `nil` only for built-in rows (`isBuiltIn == true`). Built-in
    /// identifier and flag are never included in the payload.
    public static func document(from preset: PromptPreset) -> PindropSyncDocument? {
        guard !preset.isBuiltIn else {
            return nil
        }
        let payload = PromptPresetSyncPayload(
            id: preset.id,
            name: preset.name,
            prompt: preset.prompt,
            sortOrder: preset.sortOrder,
            createdAt: preset.createdAt,
            updatedAt: preset.updatedAt
        )
        return PindropSyncDocument(payload: .customPromptPreset(payload))
    }

    // MARK: - Diarization

    /// Decodes persisted diarization JSON without mutating the record.
    ///
    /// Does not use ``TranscriptionRecord/diarizedSegments``, which swallows decode
    /// failures into `[]` and collapses the nil-vs-empty distinction.
    private static func projectDiarizationSegments(
        from record: TranscriptionRecord
    ) throws -> [PortableDiarizationSegment]? {
        guard let json = record.diarizationSegmentsJSON else {
            return nil
        }

        guard let data = json.data(using: .utf8) else {
            throw PindropSyncProjectionError.invalidDiarization(recordID: record.id)
        }

        let segments: [DiarizedTranscriptSegment]
        do {
            segments = try JSONDecoder().decode([DiarizedTranscriptSegment].self, from: data)
        } catch {
            throw PindropSyncProjectionError.invalidDiarization(recordID: record.id)
        }

        return segments.map { segment in
            PortableDiarizationSegment(
                speakerID: segment.speakerId,
                speakerLabel: segment.speakerLabel,
                startTime: segment.startTime,
                endTime: segment.endTime,
                text: segment.text
            )
        }
    }
}
