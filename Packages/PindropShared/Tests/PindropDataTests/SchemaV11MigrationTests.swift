//
//  SchemaV11MigrationTests.swift
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
struct SchemaV11MigrationTests {
    @Test func schemaV11AddsTrainingContributionTable() throws {
        #expect(TranscriptionRecordSchemaV11.versionIdentifier == .init(1, 0, 10))
        #expect(TranscriptionRecordSchemaV11.models.contains { $0 == TrainingContribution.self })
        #expect(TranscriptionRecordSchemaV11.models.contains { $0 == TranscriptionRecordSchemaV11.TranscriptionRecord.self })
    }

    @Test func migrationPlanContainsV10ToV11Stage() {
        #expect(TranscriptionRecordMigrationPlan.schemas.contains { $0 == TranscriptionRecordSchemaV10.self })
        #expect(TranscriptionRecordMigrationPlan.schemas.contains { $0 == TranscriptionRecordSchemaV11.self })
        #expect(TranscriptionRecordMigrationPlan.schemas.count == 12)
        #expect(TranscriptionRecordMigrationPlan.stages.count == 11)
    }

    @Test func userEditedAtStartsNilAndTrainingContributionRoundTrips() throws {
        let container = try PindropModelContainerFactory.makeInMemoryContainer()
        let context = ModelContext(container)

        let record = TranscriptionRecord(text: "hello world", duration: 1.0, modelUsed: "test")
        context.insert(record)

        let contribution = TrainingContribution(
            kind: .aiEnhancement,
            inputText: "helo world",
            targetText: "hello world",
            modelUsed: "test",
            redactionVersion: TrainingTextRedactor.version
        )
        context.insert(contribution)
        try context.save()

        let fetchedRecords = try context.fetch(FetchDescriptor<TranscriptionRecord>())
        #expect(fetchedRecords.first?.userEditedAt == nil)

        let fetchedContributions = try context.fetch(FetchDescriptor<TrainingContribution>())
        #expect(fetchedContributions.count == 1)
        #expect(fetchedContributions.first?.kind == .aiEnhancement)
        #expect(fetchedContributions.first?.uploadState == .pending)
        #expect(fetchedContributions.first?.redactionVersion == TrainingTextRedactor.version)
    }

    @Test func diskBackedMigrationFromV10AddsContributionTable() throws {
        let directoryURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directoryURL) }
        let storeURL = directoryURL.appendingPathComponent("migration.store")

        do {
            let legacySchema = Schema(versionedSchema: TranscriptionRecordSchemaV10.self)
            let legacyContainer = try ModelContainer(
                for: legacySchema,
                configurations: [ModelConfiguration(schema: legacySchema, url: storeURL)]
            )
            let legacyContext = ModelContext(legacyContainer)
            legacyContext.insert(
                TranscriptionRecordSchemaV10.TranscriptionRecord(
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
        #expect(records.first?.userEditedAt == nil)

        // The new table exists and is writable after migration.
        let contributionCount = try migratedContext.fetchCount(FetchDescriptor<TrainingContribution>())
        #expect(contributionCount == 0)
    }
}
