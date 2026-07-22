// Created on 2026-07-22

import Foundation

/// Version-1 portable note document body.
public struct NoteSyncPayload: Codable, Equatable, Sendable {
    public let id: UUID
    public let title: String
    public let content: String
    public let tags: [String]
    public let sourceTranscriptionID: UUID?
    public let createdAt: Date
    public let updatedAt: Date
    public let isPinned: Bool

    public init(
        id: UUID,
        title: String,
        content: String,
        tags: [String],
        sourceTranscriptionID: UUID?,
        createdAt: Date,
        updatedAt: Date,
        isPinned: Bool
    ) {
        self.id = id
        self.title = title
        self.content = content
        self.tags = tags
        self.sourceTranscriptionID = sourceTranscriptionID
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.isPinned = isPinned
    }
}
