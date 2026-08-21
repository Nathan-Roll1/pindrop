//
//  SchemaV12MigrationTests.swift
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
struct SchemaV12MigrationTests {
    @Test func schemaV12AddsPipelineMetricsColumn() {
        #expect(TranscriptionRecordSchemaV12.versionIdentifier == .init(1, 0, 11))
        #expect(TranscriptionRecordSchemaV12.models.contains { $0 == TranscriptionRecordSchemaV12.TranscriptionRecord.self })
        #expect(PindropPersistentSchemaVersion.v12.rawValue == "1.0.11")
        #expect(TranscriptionRecordMigrationPlan.schemas.last == TranscriptionRecordSchemaV13.self)

        let record = TranscriptionRecordSchemaV12.TranscriptionRecord(
            text: "hello world",
            duration: 1.0,
            modelUsed: "test",
            pipelineMetricsJSON: "{\"kind\":\"batch\"}"
        )
        #expect(record.pipelineMetricsJSON == "{\"kind\":\"batch\"}")
    }

    @Test func migrationPlanOrdersV11BeforeV12() throws {
        let schemas = TranscriptionRecordMigrationPlan.schemas
        let v11Index = try #require(schemas.firstIndex { $0 == TranscriptionRecordSchemaV11.self })
        let v12Index = try #require(schemas.firstIndex { $0 == TranscriptionRecordSchemaV12.self })

        #expect(v12Index == v11Index + 1)
    }

    @Test func pipelineMetricsRoundTripsThroughRecord() throws {
        let container = try PindropModelContainerFactory.makeInMemoryContainer()
        let context = ModelContext(container)

        var metrics = PipelineMetrics(kind: .batch)
        metrics.audioStopSeconds = 0.08
        metrics.transcriptionSeconds = 1.42
        metrics.enhancementSeconds = 2.61
        metrics.enhancementRequestSeconds = 2.55
        metrics.enhancementPromptTokens = 812
        metrics.enhancementCompletionTokens = 96
        metrics.enhancementReasoningTokens = 64
        metrics.outputSeconds = 0.05
        metrics.totalSeconds = 4.31

        let record = TranscriptionRecord(
            text: "hello world",
            duration: 1.0,
            modelUsed: "test",
            pipelineMetricsJSON: metrics.jsonString()
        )
        context.insert(record)
        try context.save()

        let fetched = try context.fetch(FetchDescriptor<TranscriptionRecord>())
        let decoded = try #require(fetched.first?.pipelineMetrics)
        #expect(decoded == metrics)
        #expect(decoded.kind == .batch)
        #expect(decoded.enhancementReasoningTokens == 64)
    }

    @Test func diskBackedMigrationFromV11LeavesMetricsNil() throws {
        let directoryURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directoryURL) }
        let storeURL = directoryURL.appendingPathComponent("migration.store")

        do {
            let legacySchema = Schema(versionedSchema: TranscriptionRecordSchemaV11.self)
            let legacyContainer = try ModelContainer(
                for: legacySchema,
                configurations: [ModelConfiguration(schema: legacySchema, url: storeURL)]
            )
            let legacyContext = ModelContext(legacyContainer)
            legacyContext.insert(
                TranscriptionRecordSchemaV11.TranscriptionRecord(
                    text: "Legacy transcription",
                    duration: 2.0,
                    modelUsed: "base"
                )
            )
            try legacyContext.save()
        }

        let migratedContainer = try PindropModelContainerFactory.makeContainer(at: storeURL)
        let migratedContext = ModelContext(migratedContainer)

        let records = try migratedContext.fetch(FetchDescriptor<TranscriptionRecord>())
        #expect(records.count == 1)
        #expect(records.first?.text == "Legacy transcription")
        #expect(records.first?.pipelineMetricsJSON == nil)
        #expect(records.first?.pipelineMetrics == nil)
    }

    @Test func factoryReopensExistingStoreForHistoryFetch() throws {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directoryURL) }
        let storeURL = directoryURL.appendingPathComponent("history.store")
        let schema = Schema(versionedSchema: TranscriptionRecordSchemaV12.self)

        // Seed a store with the URL-only configuration. SwiftData creates
        // persistent-history tables as records are saved.
        do {
            let legacyContainer = try ModelContainer(
                for: schema,
                migrationPlan: TranscriptionRecordMigrationPlan.self,
                configurations: ModelConfiguration(url: storeURL)
            )
            let legacyContext = ModelContext(legacyContainer)
            legacyContext.insert(
                TranscriptionRecord(
                    text: "Existing transcript",
                    duration: 1.0,
                    modelUsed: "test"
                )
            )
            try legacyContext.save()
        }

        let reopenedContainer = try PindropModelContainerFactory.makeContainer(at: storeURL)
        let historyStore = HistoryStore(modelContext: ModelContext(reopenedContainer))
        let records = try historyStore.fetch(limit: 5)

        #expect(records.count == 1)
        #expect(records.first?.text == "Existing transcript")
    }

    @Test func factorySupportsSpeakerIdentityReadAndWrite() throws {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directoryURL) }
        let storeURL = directoryURL.appendingPathComponent("speaker-identities.store")

        let container = try PindropModelContainerFactory.makeContainer(at: storeURL)
        let context = ModelContext(container)
        let identityService = SpeakerIdentityService(modelContext: context)

        let createdProfile = try identityService.createProfile(displayName: "Alice", notes: "Test profile")
        let profiles = try identityService.fetchAllProfiles()

        #expect(profiles.count == 1)
        #expect(profiles.first?.id == createdProfile.id)
        #expect(profiles.first?.displayName == "Alice")
        #expect(profiles.first?.notes == "Test profile")
    }
}
