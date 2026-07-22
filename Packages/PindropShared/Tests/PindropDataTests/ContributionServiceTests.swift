//
//  ContributionServiceTests.swift
//  PindropDataTests
//
//  Created on 2026-07-14.
//

import Foundation
import SwiftData
import Testing
import PindropCore
@testable import PindropData

@MainActor
@Suite(.serialized)
struct ContributionServiceTests {
    private struct Fixture {
        let modelContainer: ModelContainer
        let modelContext: ModelContext
        let service: ContributionService
    }

    /// Mutable box so tests can toggle opt-in after fixture construction.
    private final class MetadataBox: @unchecked Sendable {
        var value: ContributionCaptureMetadata
        init(_ value: ContributionCaptureMetadata) { self.value = value }
    }

    private func makeEnabledFixture() throws -> (Fixture, MetadataBox) {
        let modelContainer = try PindropModelContainerFactory.makeInMemoryContainer()
        let modelContext = ModelContext(modelContainer)
        let box = MetadataBox(
            ContributionCaptureMetadata(
                isEnabled: true,
                languageRawValue: "en",
                localeIdentifier: "en_US",
                appVersion: "test"
            )
        )
        let service = ContributionService(
            modelContext: modelContext,
            metadataProvider: { box.value }
        )
        let fixture = Fixture(
            modelContainer: modelContainer,
            modelContext: modelContext,
            service: service
        )
        return (fixture, box)
    }

    private func makeDisabledFixture() throws -> (Fixture, MetadataBox) {
        let modelContainer = try PindropModelContainerFactory.makeInMemoryContainer()
        let modelContext = ModelContext(modelContainer)
        let box = MetadataBox(
            ContributionCaptureMetadata(
                isEnabled: false,
                languageRawValue: "en",
                localeIdentifier: "en_US",
                appVersion: "test"
            )
        )
        let service = ContributionService(
            modelContext: modelContext,
            metadataProvider: { box.value }
        )
        let fixture = Fixture(
            modelContainer: modelContainer,
            modelContext: modelContext,
            service: service
        )
        return (fixture, box)
    }

    @Test func recordsNothingWhenOptedOut() throws {
        let (fixture, _) = try makeDisabledFixture()

        fixture.service.recordAIEnhancementPair(
            input: "helo world",
            target: "Hello world.",
            modelUsed: "parakeet",
            enhancedWith: "test-model",
            sourceRecordID: UUID()
        )

        #expect(fixture.service.count() == 0)
    }

    @Test func recordsAIEnhancementPairWhenOptedIn() throws {
        let (fixture, _) = try makeEnabledFixture()

        let recordID = UUID()
        fixture.service.recordAIEnhancementPair(
            input: "helo world",
            target: "Hello world.",
            modelUsed: "parakeet",
            enhancedWith: "test-model",
            sourceRecordID: recordID
        )

        let stored = try fixture.service.fetchAll()
        #expect(stored.count == 1)
        #expect(stored.first?.kind == .aiEnhancement)
        #expect(stored.first?.inputText == "helo world")
        #expect(stored.first?.targetText == "Hello world.")
        #expect(stored.first?.modelUsed == "parakeet")
        #expect(stored.first?.enhancedWith == "test-model")
        #expect(stored.first?.sourceRecordID == recordID)
        #expect(stored.first?.uploadState == .pending)
    }

    @Test func recordsManualEditPairWhenOptedIn() throws {
        let (fixture, _) = try makeEnabledFixture()

        fixture.service.recordManualEdit(
            input: "the quick brwn fox",
            target: "the quick brown fox",
            modelUsed: "parakeet",
            sourceRecordID: UUID()
        )

        let stored = try fixture.service.fetchAll()
        #expect(stored.count == 1)
        #expect(stored.first?.kind == .manualEdit)
        #expect(stored.first?.enhancedWith == nil)
    }

    @Test func skipsIdentityPairs() throws {
        let (fixture, _) = try makeEnabledFixture()

        fixture.service.recordManualEdit(
            input: "same text",
            target: "  same text  ",
            modelUsed: nil,
            sourceRecordID: nil
        )

        #expect(fixture.service.count() == 0)
    }

    @Test func redactsStoredTexts() throws {
        let (fixture, _) = try makeEnabledFixture()

        fixture.service.recordManualEdit(
            input: "email jane@example.com about it",
            target: "Email jane@example.com about it today.",
            modelUsed: nil,
            sourceRecordID: nil
        )

        let stored = try fixture.service.fetchAll()
        #expect(stored.first?.inputText == "email <email> about it")
        #expect(stored.first?.targetText == "Email <email> about it today.")
        #expect(stored.first?.redactionVersion == TrainingTextRedactor.version)
    }

    @Test func deleteAllRemovesEverything() throws {
        let (fixture, _) = try makeEnabledFixture()

        fixture.service.recordManualEdit(input: "a b", target: "A b.", modelUsed: nil, sourceRecordID: nil)
        fixture.service.recordManualEdit(input: "c d", target: "C d.", modelUsed: nil, sourceRecordID: nil)
        #expect(fixture.service.count() == 2)

        try fixture.service.deleteAll()
        #expect(fixture.service.count() == 0)
    }

    @Test func jsonlExportMatchesResearchSchemaAndOmitsSourceRecordID() throws {
        let (fixture, _) = try makeEnabledFixture()

        fixture.service.recordAIEnhancementPair(
            input: "helo",
            target: "Hello.",
            modelUsed: "parakeet",
            enhancedWith: "test-model",
            sourceRecordID: UUID()
        )

        let data = ContributionService.jsonlData(from: try fixture.service.fetchAll())
        let lines = String(decoding: data, as: UTF8.self)
            .split(separator: "\n", omittingEmptySubsequences: true)
        #expect(lines.count == 1)

        let object = try #require(
            try JSONSerialization.jsonObject(with: Data(lines[0].utf8)) as? [String: Any]
        )
        #expect(object["input_text"] as? String == "helo")
        #expect(object["target_text"] as? String == "Hello.")
        #expect(object["primary_transformation_type"] as? String == "ai_enhancement")
        #expect(object["synthetic_or_observed"] as? String == "observed")
        #expect(object["recognizer"] as? String == "parakeet")
        #expect(object["enhanced_with"] as? String == "test-model")
        #expect(object["source"] as? String == "pindrop-first-party")
        #expect(object["example_id"] != nil)
        #expect(object["created_at"] != nil)
        #expect(object["source_record_id"] == nil)
        #expect(object["sourceRecordID"] == nil)
    }

    @Test func historyStoreSaveCapturesEnhancementPair() throws {
        let modelContainer = try PindropModelContainerFactory.makeInMemoryContainer()
        let modelContext = ModelContext(modelContainer)
        let box = MetadataBox(
            ContributionCaptureMetadata(
                isEnabled: true,
                languageRawValue: "en",
                localeIdentifier: "en_US",
                appVersion: "test"
            )
        )
        let service = ContributionService(
            modelContext: modelContext,
            metadataProvider: { box.value }
        )
        let historyStore = HistoryStore(modelContext: modelContext, contributionService: service)

        let record = try historyStore.save(
            text: "Hello world.",
            originalText: "helo world",
            duration: 1.2,
            modelUsed: "parakeet",
            enhancedWith: "test-model"
        )

        let stored = try service.fetchAll()
        #expect(stored.count == 1)
        #expect(stored.first?.sourceRecordID == record.id)

        // Unenhanced saves produce no pair.
        try historyStore.save(
            text: "Plain dictation.",
            duration: 0.8,
            modelUsed: "parakeet"
        )
        #expect(service.count() == 1)
    }
}
