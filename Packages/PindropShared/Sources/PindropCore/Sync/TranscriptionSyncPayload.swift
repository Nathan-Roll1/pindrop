// Created on 2026-07-22

import Foundation

/// Version-1 portable transcription document body.
///
/// Excludes audio paths, pipeline metrics, destination application metadata,
/// and other host-local fields.
public struct TranscriptionSyncPayload: Codable, Equatable, Sendable {
    public let id: UUID
    public let text: String
    public let originalText: String?
    public let timestamp: Date
    public let duration: TimeInterval
    public let modelUsed: String
    public let enhancedWith: String?
    public let diarizationSegments: [PortableDiarizationSegment]?
    public let sourceKindRawValue: String?
    public let sourceDisplayName: String?
    public let generatedTitle: String?
    public let aiSummary: String?
    public let sourceTitleOriginRawValue: String?
    public let folderID: UUID?
    public let wordCount: Int?
    public let userEditedAt: Date?

    public init(
        id: UUID,
        text: String,
        originalText: String?,
        timestamp: Date,
        duration: TimeInterval,
        modelUsed: String,
        enhancedWith: String?,
        diarizationSegments: [PortableDiarizationSegment]?,
        sourceKindRawValue: String?,
        sourceDisplayName: String?,
        generatedTitle: String?,
        aiSummary: String?,
        sourceTitleOriginRawValue: String?,
        folderID: UUID?,
        wordCount: Int?,
        userEditedAt: Date?
    ) {
        self.id = id
        self.text = text
        self.originalText = originalText
        self.timestamp = timestamp
        self.duration = duration
        self.modelUsed = modelUsed
        self.enhancedWith = enhancedWith
        self.diarizationSegments = diarizationSegments
        self.sourceKindRawValue = sourceKindRawValue
        self.sourceDisplayName = sourceDisplayName
        self.generatedTitle = generatedTitle
        self.aiSummary = aiSummary
        self.sourceTitleOriginRawValue = sourceTitleOriginRawValue
        self.folderID = folderID
        self.wordCount = wordCount
        self.userEditedAt = userEditedAt
    }
}
