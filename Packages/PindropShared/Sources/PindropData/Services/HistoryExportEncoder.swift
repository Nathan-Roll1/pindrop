//
//  HistoryExportEncoder.swift
//  PindropData
//
//  Created on 2026-07-22.
//
//  Pure history export encoding. Presentation (NSSavePanel / filesystem write)
//  stays in the macOS app target.
//

import Foundation
import UniformTypeIdentifiers

/// On-disk history export formats previously produced by `HistoryStore`.
public enum HistoryExportFormat: String, CaseIterable, Sendable, Equatable {
    case plainText
    case json
    case csv
}

/// Encodes transcription history into deterministic JSON / CSV / plain-text payloads.
@MainActor
public enum HistoryExportEncoder {
    /// Encodes `records` for the given format.
    ///
    /// Production defaults match the previous `HistoryStore` behavior (`Date()`,
    /// `Locale.current`, `TimeZone.current`). Tests inject fixed values for
    /// byte-stable fixtures. JSON and CSV use ISO-8601 timestamps (timezone-aware
    /// via the injected `timeZone`). Plain text uses medium date/time styles with
    /// the injected locale and time zone.
    public static func encode(
        records: [TranscriptionRecord],
        format: HistoryExportFormat,
        generatedAt: Date = Date(),
        locale: Locale = .current,
        timeZone: TimeZone = .current
    ) throws -> HistoryExportPayload {
        guard !records.isEmpty else {
            throw HistoryStore.HistoryStoreError.exportFailed("No records to export")
        }

        switch format {
        case .json:
            return try encodeJSON(
                records: records,
                generatedAt: generatedAt,
                timeZone: timeZone
            )
        case .csv:
            return encodeCSV(
                records: records,
                timeZone: timeZone
            )
        case .plainText:
            return encodePlainText(
                records: records,
                generatedAt: generatedAt,
                locale: locale,
                timeZone: timeZone
            )
        }
    }

    // MARK: - JSON

    private static func encodeJSON(
        records: [TranscriptionRecord],
        generatedAt: Date,
        timeZone: TimeZone
    ) throws -> HistoryExportPayload {
        struct ExportRecord: Codable {
            let id: String
            let text: String
            let originalText: String?
            let timestamp: String
            let duration: TimeInterval
            let modelUsed: String
            let wasEnhanced: Bool
        }

        struct ExportData: Codable {
            let exportDate: String
            let totalRecords: Int
            let records: [ExportRecord]
        }

        let dateFormatter = ISO8601DateFormatter()
        dateFormatter.timeZone = timeZone

        let exportRecords = records.map { record in
            ExportRecord(
                id: record.id.uuidString,
                text: record.text,
                originalText: record.originalText,
                timestamp: dateFormatter.string(from: record.timestamp),
                duration: record.duration,
                modelUsed: record.modelUsed,
                wasEnhanced: record.wasEnhanced
            )
        }

        let exportData = ExportData(
            exportDate: dateFormatter.string(from: generatedAt),
            totalRecords: records.count,
            records: exportRecords
        )

        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let jsonData = try encoder.encode(exportData)
            return HistoryExportPayload(
                data: jsonData,
                suggestedFilename: "transcription_history.json",
                contentType: .json
            )
        } catch {
            throw HistoryStore.HistoryStoreError.exportFailed(error.localizedDescription)
        }
    }

    // MARK: - CSV

    private static func encodeCSV(
        records: [TranscriptionRecord],
        timeZone: TimeZone
    ) -> HistoryExportPayload {
        let dateFormatter = ISO8601DateFormatter()
        dateFormatter.timeZone = timeZone

        var csvContent = "ID,Timestamp,Duration,Model,Original Text,Enhanced Text,Was Enhanced\n"

        for record in records {
            let escapedOriginal = (record.originalText ?? "")
                .replacingOccurrences(of: "\"", with: "\"\"")
                .replacingOccurrences(of: "\n", with: " ")
                .replacingOccurrences(of: "\r", with: " ")

            let escapedText = record.text
                .replacingOccurrences(of: "\"", with: "\"\"")
                .replacingOccurrences(of: "\n", with: " ")
                .replacingOccurrences(of: "\r", with: " ")

            let row = [
                record.id.uuidString,
                dateFormatter.string(from: record.timestamp),
                String(format: "%.2f", record.duration),
                record.modelUsed,
                "\"\(escapedOriginal)\"",
                "\"\(escapedText)\"",
                record.wasEnhanced ? "true" : "false"
            ].joined(separator: ",")

            csvContent += row + "\n"
        }

        let data = Data(csvContent.utf8)
        return HistoryExportPayload(
            data: data,
            suggestedFilename: "transcription_history.csv",
            contentType: .commaSeparatedText
        )
    }

    // MARK: - Plain text

    private static func encodePlainText(
        records: [TranscriptionRecord],
        generatedAt: Date,
        locale: Locale,
        timeZone: TimeZone
    ) -> HistoryExportPayload {
        let dateFormatter = DateFormatter()
        dateFormatter.dateStyle = .medium
        dateFormatter.timeStyle = .medium
        dateFormatter.locale = locale
        dateFormatter.timeZone = timeZone

        var content = "Transcription History Export\n"
        content += "Generated: \(dateFormatter.string(from: generatedAt))\n"
        content += "Total Records: \(records.count)\n"
        content += String(repeating: "=", count: 80) + "\n\n"

        for (index, record) in records.enumerated() {
            content += "Record \(index + 1)\n"
            content += "Timestamp: \(dateFormatter.string(from: record.timestamp))\n"
            content += "Duration: \(String(format: "%.2f", record.duration))s\n"
            content += "Model: \(record.modelUsed)\n"
            if let originalText = record.originalText, originalText != record.text {
                content += "Original:\n\(originalText)\n\n"
            }
            content += "Enhanced:\n\(record.text)\n"
            content += String(repeating: "-", count: 80) + "\n\n"
        }

        let data = Data(content.utf8)
        return HistoryExportPayload(
            data: data,
            suggestedFilename: "transcription_history.txt",
            contentType: .plainText
        )
    }
}
