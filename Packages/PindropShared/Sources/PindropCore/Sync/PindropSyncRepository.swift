// Created on 2026-07-22

import Foundation

/// Host-owned snapshot/apply seam for synchronized documents.
///
/// No concrete repository or transport is provided in this contract layer.
@MainActor
public protocol PindropSyncRepository: AnyObject {
    func snapshot() async throws -> [PindropSyncDocument]
    func apply(_ mutations: [PindropSyncMutation]) async throws
}
