//
//  HistoryExportPayload.swift
//  PindropData
//
//  Created on 2026-07-22.
//

import Foundation
import UniformTypeIdentifiers

/// Encoded history export bytes plus presentation metadata for a save panel or writer.
public struct HistoryExportPayload: Equatable, Sendable {
    public let data: Data
    public let suggestedFilename: String
    public let contentType: UTType

    public init(data: Data, suggestedFilename: String, contentType: UTType) {
        self.data = data
        self.suggestedFilename = suggestedFilename
        self.contentType = contentType
    }
}
