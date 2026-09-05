// Created on 2026-07-22

import Foundation

/// Version-1 portable vocabulary-word document body.
public struct VocabularyWordSyncPayload: Codable, Equatable, Sendable {
    public let id: UUID
    public let word: String
    public let createdAt: Date

    public init(
        id: UUID,
        word: String,
        createdAt: Date
    ) {
        self.id = id
        self.word = word
        self.createdAt = createdAt
    }
}
