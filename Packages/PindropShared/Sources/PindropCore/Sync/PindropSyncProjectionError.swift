// Created on 2026-07-22

import Foundation

/// Errors raised while projecting local models into sync documents.
///
/// Reverse/apply projection is intentionally out of scope for this contract layer.
public enum PindropSyncProjectionError: Error, Equatable, Sendable {
    /// Persisted diarization JSON for the given record could not be decoded.
    case invalidDiarization(recordID: UUID)
}
