// Created on 2026-07-22

import Foundation

/// One outbound or inbound sync mutation.
public enum PindropSyncMutation: Codable, Equatable, Sendable {
    case upsert(PindropSyncDocument, modifiedAt: Date)
    case delete(PindropSyncKey, deletedAt: Date)
}
