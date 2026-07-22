// Created on 2026-07-22

import Foundation

/// Stable cross-device identity for one synchronized row.
public struct PindropSyncKey: Codable, Hashable, Sendable {
    public let entity: PindropSyncEntity
    public let id: UUID

    public init(entity: PindropSyncEntity, id: UUID) {
        self.entity = entity
        self.id = id
    }
}
