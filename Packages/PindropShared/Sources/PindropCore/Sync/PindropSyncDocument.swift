// Created on 2026-07-22

import Foundation

/// Versioned portable sync document envelope.
///
/// ``init(payload:)`` always stamps ``currentSchemaVersion``. Decoding rejects
/// unsupported schema versions instead of silently accepting them.
public struct PindropSyncDocument: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public let payload: PindropSyncPayload

    public init(payload: PindropSyncPayload) {
        self.schemaVersion = Self.currentSchemaVersion
        self.payload = payload
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        guard schemaVersion == Self.currentSchemaVersion else {
            throw DecodingError.dataCorruptedError(
                forKey: .schemaVersion,
                in: container,
                debugDescription: "Unsupported PindropSyncDocument schema version \(schemaVersion); expected \(Self.currentSchemaVersion)."
            )
        }
        self.schemaVersion = schemaVersion
        self.payload = try container.decode(PindropSyncPayload.self, forKey: .payload)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(payload, forKey: .payload)
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case payload
    }
}
