// Created on 2026-07-22

import Foundation

/// Host-controlled sync participation mode.
///
/// Network transport is intentionally out of scope for this contract layer.
/// The default host mode is ``disabled``.
public enum PindropSyncMode: String, Codable, Sendable {
    case disabled
    case privateCloud
}
