// Created on 2026-07-22

import Foundation

/// Version-1 portable custom prompt-preset document body.
///
/// Built-in presets are never projected into this payload.
public struct PromptPresetSyncPayload: Codable, Equatable, Sendable {
    public let id: UUID
    public let name: String
    public let prompt: String
    public let sortOrder: Int
    public let createdAt: Date
    public let updatedAt: Date

    public init(
        id: UUID,
        name: String,
        prompt: String,
        sortOrder: Int,
        createdAt: Date,
        updatedAt: Date
    ) {
        self.id = id
        self.name = name
        self.prompt = prompt
        self.sortOrder = sortOrder
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}
