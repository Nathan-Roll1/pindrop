//
//  HistoryStore.swift
//  Pindrop
//
//  macOS presentation for history export. Storage/encoding live in PindropData.
//

import AppKit
import Foundation
import PindropData
import UniformTypeIdentifiers

/// Presents a pre-encoded history export payload via `NSSavePanel` and writes bytes to disk.
@MainActor
enum MacHistoryExportPresenter {
    /// Shows a save panel using `payload.suggestedFilename` / `payload.contentType`,
    /// then atomically writes `payload.data` to the chosen URL.
    static func present(_ payload: HistoryExportPayload) throws {
        let savePanel = NSSavePanel()
        savePanel.allowedContentTypes = [payload.contentType]
        savePanel.nameFieldStringValue = payload.suggestedFilename
        savePanel.title = "Export Transcription History"
        savePanel.message = "Choose a location to save the transcription history"

        let response = savePanel.runModal()
        guard response == .OK, let url = savePanel.url else {
            throw HistoryStore.HistoryStoreError.exportFailed("Export cancelled")
        }

        do {
            try payload.data.write(to: url, options: .atomic)
        } catch {
            throw HistoryStore.HistoryStoreError.exportFailed(error.localizedDescription)
        }
    }
}

// MARK: - App-facing export entry points

extension HistoryStore {
    /// Encodes records as plain text and presents a save panel.
    func exportToPlainText(records: [TranscriptionRecord]? = nil) throws {
        let recordsToExport = try records ?? fetchAll()
        let payload = try HistoryExportEncoder.encode(records: recordsToExport, format: .plainText)
        try MacHistoryExportPresenter.present(payload)
    }

    /// Encodes records as JSON and presents a save panel.
    func exportToJSON(records: [TranscriptionRecord]? = nil) throws {
        let recordsToExport = try records ?? fetchAll()
        let payload = try HistoryExportEncoder.encode(records: recordsToExport, format: .json)
        try MacHistoryExportPresenter.present(payload)
    }

    /// Encodes records as CSV and presents a save panel.
    func exportToCSV(records: [TranscriptionRecord]? = nil) throws {
        let recordsToExport = try records ?? fetchAll()
        let payload = try HistoryExportEncoder.encode(records: recordsToExport, format: .csv)
        try MacHistoryExportPresenter.present(payload)
    }
}
