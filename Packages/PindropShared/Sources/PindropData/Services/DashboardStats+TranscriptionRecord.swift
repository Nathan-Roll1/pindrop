//
//  DashboardStats+TranscriptionRecord.swift
//  PindropData
//
//  Created on 2026-07-22.
//
//  TranscriptionRecord -> StatsSample adaptation. Pure windowed stats stay in
//  PindropCore; this adapter is the only SwiftData bridge.
//

import Foundation
import PindropCore

extension StatsSample {
    /// Projects a persisted transcription into the model-free stats input.
    ///
    /// Uses `effectiveWordCount` (cached `wordCount` when present, otherwise
    /// derived from `text`) and `resolvedSourceKind` so voice-only dashboard
    /// filtering matches library semantics for legacy nil source rows.
    public init(_ record: TranscriptionRecord) {
        self.init(
            timestamp: record.timestamp,
            wordCount: record.effectiveWordCount,
            duration: record.duration,
            sourceKind: record.resolvedSourceKind
        )
    }
}

extension Array where Element == TranscriptionRecord {
    /// Maps persisted records into stats samples for `DashboardStatsService`.
    public func asStatsSamples() -> [StatsSample] {
        map(StatsSample.init)
    }
}
