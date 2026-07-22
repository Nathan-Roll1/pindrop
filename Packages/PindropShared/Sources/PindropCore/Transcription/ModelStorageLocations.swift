//
//  ModelStorageLocations.swift
//  PindropCore
//
//  Created on 2026-07-22.
//

import Foundation

/// Injected roots for downloaded-model consumers.
///
/// Host composition supplies platform-specific Application Support (or sandbox)
/// URLs. Shared speech/media code must never reconstruct default roots.
public struct ModelStorageLocations: Sendable, Equatable {
    public let pindropApplicationSupportRoot: URL
    public let fluidAudioModelsRoot: URL

    public init(
        pindropApplicationSupportRoot: URL,
        fluidAudioModelsRoot: URL
    ) {
        self.pindropApplicationSupportRoot = pindropApplicationSupportRoot
        self.fluidAudioModelsRoot = fluidAudioModelsRoot
    }
}
