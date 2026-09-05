// Created on 2026-07-22

import Foundation

/// Version-1 portable media-folder document body.
public struct MediaFolderSyncPayload: Codable, Equatable, Sendable {
    public let id: UUID
    public let name: String
    public let createdAt: Date
    public let updatedAt: Date

    public init(
        id: UUID,
        name: String,
        createdAt: Date,
        updatedAt: Date
    ) {
        self.id = id
        self.name = name
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}
