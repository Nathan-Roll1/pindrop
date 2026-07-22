//
//  ModelDownloadEventReporting.swift
//  PindropCore
//
//  Created on 2026-07-22.
//

import Foundation

/// Host-facing telemetry seam for model download lifecycle events.
///
/// Keeps TelemetryDeck (and any other analytics backend) out of the package graph.
@MainActor
public protocol ModelDownloadEventReporting: AnyObject {
    func modelDownloadDidStart(modelName: String)
    func modelDownloadDidFail(modelName: String, error: Error)
}
