//
//  PindropPersistentSchemaVersion.swift
//  PindropData
//
//  Created on 2026-07-22.
//

import Foundation
import SwiftData

/// Catalog of historical and current SwiftData schema versions for repair/reference tooling.
/// Concrete V1 through V12 schema types remain package-internal; this exposes the version map only.
public enum PindropPersistentSchemaVersion: String, CaseIterable, Sendable {
    case v1 = "1.0.0"
    case v2 = "1.0.1"
    case v3 = "1.0.2"
    case v4 = "1.0.3"
    case v5 = "1.0.4"
    case v6 = "1.0.5"
    case v7 = "1.0.6"
    case v8 = "1.0.7"
    case v9 = "1.0.8"
    case v10 = "1.0.9"
    case v11 = "1.0.10"
    case v12 = "1.0.11"

    public var versionedSchema: any VersionedSchema.Type {
        switch self {
        case .v1: return TranscriptionRecordSchemaV1.self
        case .v2: return TranscriptionRecordSchemaV2.self
        case .v3: return TranscriptionRecordSchemaV3.self
        case .v4: return TranscriptionRecordSchemaV4.self
        case .v5: return TranscriptionRecordSchemaV5.self
        case .v6: return TranscriptionRecordSchemaV6.self
        case .v7: return TranscriptionRecordSchemaV7.self
        case .v8: return TranscriptionRecordSchemaV8.self
        case .v9: return TranscriptionRecordSchemaV9.self
        case .v10: return TranscriptionRecordSchemaV10.self
        case .v11: return TranscriptionRecordSchemaV11.self
        case .v12: return TranscriptionRecordSchemaV12.self
        }
    }
}
