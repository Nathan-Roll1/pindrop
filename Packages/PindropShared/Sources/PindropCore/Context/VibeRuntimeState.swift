//
//  VibeRuntimeState.swift
//  PindropCore
//
//  Created on 2026-07-22.
//

import Foundation

public enum VibeRuntimeState: String, CaseIterable, Sendable {
    case ready
    case limited
    case degraded
}
