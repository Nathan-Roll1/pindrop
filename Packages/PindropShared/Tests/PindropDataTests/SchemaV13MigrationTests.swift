//
//  SchemaV13MigrationTests.swift
//  PindropDataTests
//
//  Created on 2026-08-20.
//

import Foundation
import SwiftData
import Testing
import PindropCore
@testable import PindropData

@MainActor
@Suite(.serialized)
struct SchemaV13MigrationTests {
    @Test func schemaV13RemainsAnOrderedHistoricalSnapshot() {
        let expectedModels: [any PersistentModel.Type] = [
            TranscriptionRecord.self,
            MediaFolder.self,
            ParticipantProfile.self,
            ParticipantTrainingEvidence.self,
            WordReplacement.self,
            VocabularyWord.self,
            Note.self,
            PromptPreset.self,
            TrainingContribution.self,
            CaptureSessionModel.self,
            CaptureSourceModel.self,
            CaptureChunkModel.self,
            CaptureTranscriptRevisionModel.self,
            CaptureStageProviderSnapshotModel.self,
            CaptureNoteReferenceModel.self,
            CaptureFailureRecordModel.self
        ]

        #expect(TranscriptionRecordSchemaV13.versionIdentifier == .init(1, 0, 12))
        #expect(TranscriptionRecordSchemaV13.models.count == expectedModels.count)
        for (model, expectedModel) in zip(TranscriptionRecordSchemaV13.models, expectedModels) {
            #expect(model == expectedModel)
        }
        #expect(PindropPersistentSchemaVersion.v13.rawValue == "1.0.12")
        #expect(PindropPersistentSchemaVersion.v13.versionedSchema == TranscriptionRecordSchemaV13.self)
    }

    @Test func migrationPlanKeepsV13ImmediatelyAfterV12() throws {
        let schemas = TranscriptionRecordMigrationPlan.schemas
        let v12Index = try #require(schemas.firstIndex { $0 == TranscriptionRecordSchemaV12.self })
        let v13Index = try #require(schemas.firstIndex { $0 == TranscriptionRecordSchemaV13.self })

        #expect(v13Index == v12Index + 1)
    }

    @Test func diskBackedMigrationFromV12PreservesExistingDataAndRegistersCaptureModels() throws {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directoryURL) }
        let storeURL = directoryURL.appendingPathComponent("migration.store")
        let recordID = UUID()
        let timestamp = Date(timeIntervalSinceReferenceDate: 2_000)

        do {
            let legacySchema = Schema(versionedSchema: TranscriptionRecordSchemaV12.self)
            let legacyContainer = try ModelContainer(
                for: legacySchema,
                configurations: [ModelConfiguration(schema: legacySchema, url: storeURL)]
            )
            let legacyContext = ModelContext(legacyContainer)
            legacyContext.insert(
                TranscriptionRecordSchemaV12.TranscriptionRecord(
                    id: recordID,
                    text: "V12 transcription",
                    timestamp: timestamp,
                    duration: 2.5,
                    modelUsed: "base"
                )
            )
            try legacyContext.save()
        }

        let migratedContainer = try PindropModelContainerFactory.makeContainer(at: storeURL)
        let migratedContext = ModelContext(migratedContainer)

        let records = try migratedContext.fetch(FetchDescriptor<TranscriptionRecord>())
        let record = try #require(records.first)
        #expect(records.count == 1)
        #expect(record.id == recordID)
        #expect(record.text == "V12 transcription")
        #expect(record.timestamp == timestamp)
        #expect(record.duration == 2.5)
        #expect(record.modelUsed == "base")

        #expect(try migratedContext.fetch(FetchDescriptor<CaptureSessionModel>()).isEmpty)
        #expect(try migratedContext.fetch(FetchDescriptor<CaptureSourceModel>()).isEmpty)
        #expect(try migratedContext.fetch(FetchDescriptor<CaptureChunkModel>()).isEmpty)
        #expect(try migratedContext.fetch(FetchDescriptor<CaptureTranscriptRevisionModel>()).isEmpty)
        #expect(try migratedContext.fetch(FetchDescriptor<CaptureStageProviderSnapshotModel>()).isEmpty)
        #expect(try migratedContext.fetch(FetchDescriptor<CaptureNoteReferenceModel>()).isEmpty)
        #expect(try migratedContext.fetch(FetchDescriptor<CaptureFailureRecordModel>()).isEmpty)
    }
}
