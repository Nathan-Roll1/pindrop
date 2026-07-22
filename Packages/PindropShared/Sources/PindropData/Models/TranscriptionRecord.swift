//
//  TranscriptionRecord.swift
//  PindropData
//
//  Created on 2026-01-28.
//

import Foundation
import SwiftData
import PindropCore

public typealias TranscriptionRecord = TranscriptionRecordSchemaV12.TranscriptionRecord
public typealias MediaFolder = TranscriptionRecordSchemaV12.MediaFolder
public typealias ParticipantProfile = TranscriptionRecordSchemaV12.ParticipantProfile
public typealias ParticipantTrainingEvidence = TranscriptionRecordSchemaV12.ParticipantTrainingEvidence

public enum TranscriptionTitleOrigin: String {
    case sourceMetadata
    case fallback
}

extension TranscriptionRecord {
    public var sourceTitleOrigin: TranscriptionTitleOrigin? {
        guard let sourceTitleOriginRawValue else { return nil }
        return TranscriptionTitleOrigin(rawValue: sourceTitleOriginRawValue)
    }

    public var hasSourceMetadataTitle: Bool {
        sourceTitleOrigin == .sourceMetadata
    }

    public var preferredTitle: String? {
        let trimmedSourceDisplayName = sourceDisplayName?.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedGeneratedTitle = generatedTitle?.trimmingCharacters(in: .whitespacesAndNewlines)

        if hasSourceMetadataTitle, let trimmedSourceDisplayName, !trimmedSourceDisplayName.isEmpty {
            return trimmedSourceDisplayName
        }
        if let trimmedGeneratedTitle, !trimmedGeneratedTitle.isEmpty {
            return trimmedGeneratedTitle
        }
        if let trimmedSourceDisplayName, !trimmedSourceDisplayName.isEmpty {
            return trimmedSourceDisplayName
        }

        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedText.isEmpty ? nil : trimmedText
    }

    public var resolvedSourceKind: MediaSourceKind {
        guard let sourceKindRawValue else { return .voiceRecording }
        return MediaSourceKind(rawValue: sourceKindRawValue) ?? .voiceRecording
    }

    public var isVoiceTranscription: Bool {
        resolvedSourceKind == .voiceRecording
    }

    public var isMediaTranscription: Bool {
        resolvedSourceKind.isMediaBacked
    }

    public var managedMediaURL: URL? {
        guard let managedMediaPath, !managedMediaPath.isEmpty else { return nil }
        return URL(fileURLWithPath: managedMediaPath)
    }

    public var thumbnailURL: URL? {
        guard let thumbnailPath, !thumbnailPath.isEmpty else { return nil }
        return URL(fileURLWithPath: thumbnailPath)
    }

    /// Decoded pipeline latency breakdown, when this record was produced by an
    /// instrumented dictation path.
    public var pipelineMetrics: PipelineMetrics? {
        guard let pipelineMetricsJSON else { return nil }
        return PipelineMetrics(jsonString: pipelineMetricsJSON)
    }

    public var diarizedSegments: [DiarizedTranscriptSegment] {
        guard let diarizationSegmentsJSON,
              let data = diarizationSegmentsJSON.data(using: .utf8),
              let segments = try? JSONDecoder().decode([DiarizedTranscriptSegment].self, from: data) else {
            return []
        }
        return segments
    }

    public var mediaLibrarySortName: String {
        preferredTitle ?? text
    }

    public func matchesMediaLibrarySearch(_ query: String) -> Bool {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuery.isEmpty else { return true }

        let searchableFields = [
            preferredTitle,
            text,
            originalText,
            sourceDisplayName,
            generatedTitle,
            aiSummary,
            originalSourceURL
        ]

        return searchableFields.contains { value in
            guard let value, !value.isEmpty else { return false }
            return value.localizedStandardContains(trimmedQuery)
        }
    }

    /// Cached word count when present; otherwise derived from `text`.
    public var effectiveWordCount: Int {
        wordCount ?? text.wordCount
    }

    // MARK: - Meeting metadata helpers

    /// Distinct speaker count from diarized segments (by speakerId, falling back to label).
    public var speakerCount: Int {
        let segments = diarizedSegments
        guard !segments.isEmpty else { return 0 }
        var seen = Set<String>()
        for segment in segments {
            let key = segment.speakerId.isEmpty ? segment.speakerLabel : segment.speakerId
            if !key.isEmpty {
                seen.insert(key)
            }
        }
        return seen.count
    }

    /// Whether diarization payload is present on the record.
    public var isDiarized: Bool {
        diarizationSegmentsJSON != nil
    }

    /// Whether a non-empty AI summary is available.
    public var hasSummary: Bool {
        guard let aiSummary else { return false }
        return !aiSummary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

extension MediaFolder {
    public var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
