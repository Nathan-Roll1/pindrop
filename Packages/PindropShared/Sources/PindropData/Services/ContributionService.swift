//
//  ContributionService.swift
//  PindropData
//
//  Created on 2026-07-14.
//
//  Captures opt-in training-data contributions: before/after transcript text
//  pairs that could eventually train an on-device transcript-correction model
//  (docs/transcript-post-processing-model-research.md, Phase 5). Everything is
//  gated on host-supplied ContributionCaptureMetadata (off by default),
//  redacted at capture time, and stored only in the local SwiftData store.
//  Contributions remain local; there is no upload path in this module.
//

import Foundation
import PindropCore
import SwiftData

@MainActor
public final class ContributionService {
    private let modelContext: ModelContext
    private let metadataProvider: @MainActor @Sendable () -> ContributionCaptureMetadata
    private let redactor: TrainingTextRedactor

    public init(
        modelContext: ModelContext,
        metadataProvider: @escaping @MainActor @Sendable () -> ContributionCaptureMetadata,
        redactor: TrainingTextRedactor = TrainingTextRedactor()
    ) {
        self.modelContext = modelContext
        self.metadataProvider = metadataProvider
        self.redactor = redactor
    }

    // MARK: - Capture

    /// Records a raw-ASR to AI-enhanced pair. No-op unless the user opted in.
    public func recordAIEnhancementPair(
        input: String,
        target: String,
        modelUsed: String?,
        enhancedWith: String?,
        sourceRecordID: UUID?
    ) {
        record(
            kind: .aiEnhancement,
            input: input,
            target: target,
            modelUsed: modelUsed,
            enhancedWith: enhancedWith,
            sourceRecordID: sourceRecordID
        )
    }

    /// Records a pre-edit to user-corrected pair. No-op unless the user opted in.
    public func recordManualEdit(
        input: String,
        target: String,
        modelUsed: String?,
        sourceRecordID: UUID?
    ) {
        record(
            kind: .manualEdit,
            input: input,
            target: target,
            modelUsed: modelUsed,
            enhancedWith: nil,
            sourceRecordID: sourceRecordID
        )
    }

    private func record(
        kind: TrainingContributionKind,
        input: String,
        target: String,
        modelUsed: String?,
        enhancedWith: String?,
        sourceRecordID: UUID?
    ) {
        let metadata = metadataProvider()
        guard metadata.isEnabled else { return }

        let redactedInput = redactor.redact(input)
        let redactedTarget = redactor.redact(target)

        // Identity pairs teach nothing the identity split can't; skip them.
        let trimmedInput = redactedInput.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedTarget = redactedTarget.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedInput.isEmpty, !trimmedTarget.isEmpty, trimmedInput != trimmedTarget else {
            return
        }

        let contribution = TrainingContribution(
            kind: kind,
            inputText: redactedInput,
            targetText: redactedTarget,
            modelUsed: modelUsed,
            enhancedWith: enhancedWith,
            language: metadata.languageRawValue,
            locale: metadata.localeIdentifier,
            appVersion: metadata.appVersion,
            sourceRecordID: sourceRecordID,
            redactionVersion: TrainingTextRedactor.version
        )
        modelContext.insert(contribution)
        do {
            try modelContext.save()
        } catch {
            Log.telemetry.error("Failed to save training contribution: \(error.localizedDescription)")
            return
        }
        Log.telemetry.info("Stored training contribution kind=\(kind.rawValue)")
    }

    // MARK: - Review / export / delete

    public func count() -> Int {
        (try? modelContext.fetchCount(FetchDescriptor<TrainingContribution>())) ?? 0
    }

    public func fetchAll() throws -> [TrainingContribution] {
        try modelContext.fetch(
            FetchDescriptor<TrainingContribution>(
                sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
            )
        )
    }

    public func deleteAll() throws {
        try Self.deleteAll(in: modelContext)
    }

    /// Shared mutation used by both the service and the Privacy settings pane
    /// (which reaches the same store through its SwiftUI model context).
    public static func deleteAll(in modelContext: ModelContext) throws {
        try modelContext.delete(model: TrainingContribution.self)
        try modelContext.save()
    }

    // MARK: - JSONL export

    /// One JSON object per line, keyed to align with the canonical example schema
    /// in docs/transcript-post-processing-model-research.md section 7. `sourceRecordID`
    /// is intentionally not exported.
    public static func jsonlData(from contributions: [TrainingContribution]) -> Data {
        let formatter = ISO8601DateFormatter()
        var lines: [String] = []
        lines.reserveCapacity(contributions.count)

        for contribution in contributions {
            let transformationType: String
            switch contribution.kind {
            case .aiEnhancement: transformationType = "ai_enhancement"
            case .manualEdit: transformationType = "manual_edit"
            case nil: transformationType = contribution.kindRawValue
            }

            var object: [String: Any] = [
                "example_id": contribution.id.uuidString,
                "created_at": formatter.string(from: contribution.createdAt),
                "input_text": contribution.inputText,
                "target_text": contribution.targetText,
                "primary_transformation_type": transformationType,
                "synthetic_or_observed": "observed",
                "redaction_version": contribution.redactionVersion,
                "source": "pindrop-first-party"
            ]
            object["language"] = contribution.language
            object["locale"] = contribution.locale
            object["recognizer"] = contribution.modelUsed
            object["enhanced_with"] = contribution.enhancedWith
            object["app_version"] = contribution.appVersion

            guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
                  let line = String(data: data, encoding: .utf8) else {
                continue
            }
            lines.append(line)
        }

        return Data((lines.joined(separator: "\n") + (lines.isEmpty ? "" : "\n")).utf8)
    }
}
