// Created on 2026-07-22

import Foundation

/// Version-1 portable word-replacement document body.
public struct WordReplacementSyncPayload: Codable, Equatable, Sendable {
    public let id: UUID
    public let originals: [String]
    public let replacement: String
    public let createdAt: Date
    public let sortOrder: Int
    public let matchModeRawValue: String?

    public init(
        id: UUID,
        originals: [String],
        replacement: String,
        createdAt: Date,
        sortOrder: Int,
        matchModeRawValue: String?
    ) {
        self.id = id
        self.originals = originals
        self.replacement = replacement
        self.createdAt = createdAt
        self.sortOrder = sortOrder
        self.matchModeRawValue = matchModeRawValue
    }
}
