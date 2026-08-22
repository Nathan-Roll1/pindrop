//
//  SchemaV14MigrationTests.swift
//  PindropDataTests
//
//  Created on 2026-08-21.
//

import Foundation
import PindropCore
import SwiftData
import Testing
@testable import PindropData

@MainActor
@Suite(.serialized)
struct SchemaV14MigrationTests {
    @Test func currentSchemaAppendsPromptSnapshotToV13ModelOrder() throws {
        let v13Models = TranscriptionRecordSchemaV13.models
        let v14Models = TranscriptionRecordSchemaV14.models
        let finalModel = try #require(v14Models.last)

        #expect(TranscriptionRecordSchemaV14.versionIdentifier == .init(1, 0, 13))
        #expect(v14Models.count == 17)
        #expect(finalModel == CaptureStagePromptSnapshotModel.self)
        for (model, v13Model) in zip(v14Models.dropLast(), v13Models) {
            #expect(model == v13Model)
        }
    }

    // The catalog and plan end at the newest schema version; SchemaV15MigrationTests
    // owns those counts. This keeps V14's own identity and position.
    @Test func migrationPlanKeepsV14ImmediatelyAfterV13() throws {
        let schemas = TranscriptionRecordMigrationPlan.schemas
        let v13Index = try #require(schemas.firstIndex { $0 == TranscriptionRecordSchemaV13.self })
        let v14Index = try #require(schemas.firstIndex { $0 == TranscriptionRecordSchemaV14.self })

        #expect(PindropPersistentSchemaVersion.v14.rawValue == "1.0.13")
        #expect(PindropPersistentSchemaVersion.v14.versionedSchema == TranscriptionRecordSchemaV14.self)
        #expect(v14Index == v13Index + 1)
    }

    @Test func diskBackedMigrationFromV13EagerlyFreezesPromptSnapshotsAndPreservesEveryExistingModel() throws {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directoryURL) }

        let storeURL = directoryURL.appendingPathComponent("migration.store")
        let timestamp = Date(timeIntervalSinceReferenceDate: 2_000)
        let recordID = UUID()
        let sessionID = UUID()
        let sourceID = UUID()
        let providerSnapshotID = UUID()
        let promptPresetID = UUID()
        let missingProviderSnapshotID = UUID()
        let missingPromptPresetID = UUID()
        let noteID = UUID()

        do {
            let legacySchema = Schema(versionedSchema: TranscriptionRecordSchemaV13.self)
            let legacyContainer = try ModelContainer(
                for: legacySchema,
                configurations: [ModelConfiguration(schema: legacySchema, url: storeURL)]
            )
            let legacyContext = ModelContext(legacyContainer)
            let session = try CaptureSession(
                id: sessionID,
                mode: .meeting,
                createdAt: timestamp
            )

            legacyContext.insert(
                TranscriptionRecord(
                    id: recordID,
                    text: "V13 transcription",
                    timestamp: timestamp,
                    duration: 2.5,
                    modelUsed: "base"
                )
            )
            legacyContext.insert(MediaFolder(name: "V13 folder", createdAt: timestamp, updatedAt: timestamp))
            legacyContext.insert(
                ParticipantProfile(
                    normalizedName: "v13 participant",
                    displayName: "V13 Participant",
                    createdAt: timestamp,
                    updatedAt: timestamp
                )
            )
            legacyContext.insert(
                ParticipantTrainingEvidence(
                    evidenceKey: "v13-evidence",
                    sourceTypeRawValue: "capture",
                    sourceSpeakerID: "speaker-1",
                    segmentStartTime: 0,
                    segmentEndTime: 1,
                    segmentDuration: 1,
                    confidence: 1,
                    embeddingData: Data([1]),
                    createdAt: timestamp,
                    updatedAt: timestamp
                )
            )
            legacyContext.insert(
                WordReplacement(
                    originals: ["v13"],
                    replacement: "V14",
                    createdAt: timestamp
                )
            )
            legacyContext.insert(VocabularyWord(word: "V13", createdAt: timestamp))
            legacyContext.insert(
                Note(
                    id: noteID,
                    title: "V13 note",
                    content: "V13 content",
                    sourceTranscriptionID: recordID,
                    createdAt: timestamp,
                    updatedAt: timestamp
                )
            )
            legacyContext.insert(
                PromptPreset(
                    id: promptPresetID,
                    name: "V13 preset",
                    prompt: "V13 prompt",
                    isBuiltIn: true,
                    createdAt: timestamp,
                    updatedAt: timestamp,
                    builtInIdentifier: "v13-built-in-preset"
                )
            )
            legacyContext.insert(
                TrainingContribution(
                    createdAt: timestamp,
                    kind: .manualEdit,
                    inputText: "before",
                    targetText: "after",
                    redactionVersion: 1
                )
            )
            legacyContext.insert(CaptureSessionModel(session: session))
            legacyContext.insert(
                CaptureSourceModel(
                    id: sourceID,
                    sessionID: sessionID,
                    kind: .microphone,
                    sequence: 0,
                    createdAt: timestamp,
                    updatedAt: timestamp
                )
            )
            legacyContext.insert(
                CaptureChunkModel(
                    sessionID: sessionID,
                    sourceID: sourceID,
                    sequence: 0,
                    startOffset: 0,
                    duration: 1,
                    createdAt: timestamp
                )
            )
            legacyContext.insert(
                CaptureTranscriptRevisionModel(
                    sessionID: sessionID,
                    sourceID: sourceID,
                    sequence: 0,
                    stage: .finalTranscription,
                    startOffset: 0,
                    duration: 1,
                    text: "V13 revision",
                    providerSnapshotID: providerSnapshotID,
                    createdAt: timestamp
                )
            )
            legacyContext.insert(
                CaptureStageProviderSnapshotModel(
                    id: providerSnapshotID,
                    sessionID: sessionID,
                    stage: .noteGeneration,
                    attempt: 1,
                    providerKindRawValue: CaptureAssignmentProviderKind.generativeAI.rawValue,
                    providerIdentifier: "catalog-provider",
                    modelIdentifier: "catalog-model",
                    promptPresetID: promptPresetID,
                    selectedAt: timestamp
                )
            )
            legacyContext.insert(
                CaptureStageProviderSnapshotModel(
                    id: missingProviderSnapshotID,
                    sessionID: sessionID,
                    stage: .noteGeneration,
                    attempt: 2,
                    providerKindRawValue: CaptureAssignmentProviderKind.generativeAI.rawValue,
                    providerIdentifier: "catalog-provider",
                    modelIdentifier: "catalog-model",
                    promptPresetID: missingPromptPresetID,
                    selectedAt: timestamp
                )
            )
            legacyContext.insert(
                CaptureNoteReferenceModel(
                    sessionID: sessionID,
                    noteID: noteID,
                    role: .humanAnchor,
                    providerSnapshotID: providerSnapshotID,
                    createdAt: timestamp
                )
            )
            legacyContext.insert(
                CaptureFailureRecordModel(
                    sessionID: sessionID,
                    sourceID: sourceID,
                    stage: .finalTranscription,
                    attempt: 1,
                    errorDomain: "migration-test",
                    errorCode: "v13",
                    message: "V13 failure",
                    isRetryable: true,
                    occurredAt: timestamp,
                    recoveryDisposition: .recoverable
                )
            )
            try legacyContext.save()
        }

        let migratedContainer = try PindropModelContainerFactory.makeContainer(at: storeURL)
        let migratedContext = ModelContext(migratedContainer)
        let promptSnapshots = try migratedContext.fetch(
            FetchDescriptor<CaptureStagePromptSnapshotModel>()
        )
        #expect(promptSnapshots.count == 2)

        let matchingPromptSnapshot = try #require(
            promptSnapshots.first { $0.providerSnapshotID == providerSnapshotID }
        )
        #expect(matchingPromptSnapshot.sessionID == sessionID)
        #expect(
            matchingPromptSnapshot.restorePrompt() == CapturePromptSnapshot(
                presetIdentifier: "v13-built-in-preset",
                resolvedPrompt: "V13 prompt"
            )
        )

        let missingPromptSnapshot = try #require(
            promptSnapshots.first { $0.providerSnapshotID == missingProviderSnapshotID }
        )
        #expect(missingPromptSnapshot.sessionID == sessionID)
        #expect(
            missingPromptSnapshot.restorePrompt() == CapturePromptSnapshot(
                presetIdentifier: missingPromptPresetID.uuidString,
                resolvedPrompt: nil
            )
        )
        #expect(try migratedContext.fetch(FetchDescriptor<PromptPreset>()).count == 1)

        let mutablePreset = try #require(
            try migratedContext.fetch(
                FetchDescriptor<PromptPreset>(
                    predicate: #Predicate<PromptPreset> { $0.id == promptPresetID }
                )
            ).first
        )
        mutablePreset.prompt = "Mutated V14 prompt"
        try migratedContext.save()
        migratedContext.delete(mutablePreset)
        try migratedContext.save()
        migratedContext.insert(
            PromptPreset(
                id: promptPresetID,
                name: "Recreated V13 preset",
                prompt: "Recreated V14 prompt",
                isBuiltIn: true,
                createdAt: timestamp,
                updatedAt: timestamp,
                builtInIdentifier: "recreated-v13-built-in-preset"
            )
        )
        migratedContext.insert(
            PromptPreset(
                id: missingPromptPresetID,
                name: "Recreated missing preset",
                prompt: "Unexpected V14 prompt",
                isBuiltIn: true,
                createdAt: timestamp,
                updatedAt: timestamp,
                builtInIdentifier: "unexpected-v14-built-in-preset"
            )
        )
        try migratedContext.save()

        let store = CaptureSessionStore(modelContext: migratedContext)
        let persistedAssignment = try #require(
            try store.persistedAssignment(
                sessionID: sessionID,
                stage: .noteGeneration,
                attempt: 1
            )
        )
        #expect(
            persistedAssignment.prompt == CapturePromptSnapshot(
                presetIdentifier: "v13-built-in-preset",
                resolvedPrompt: "V13 prompt"
            )
        )

        let persistedTombstoneAssignment = try #require(
            try store.persistedAssignment(
                sessionID: sessionID,
                stage: .noteGeneration,
                attempt: 2
            )
        )
        #expect(
            persistedTombstoneAssignment.prompt == CapturePromptSnapshot(
                presetIdentifier: missingPromptPresetID.uuidString,
                resolvedPrompt: nil
            )
        )

        let records = try migratedContext.fetch(FetchDescriptor<TranscriptionRecord>())
        #expect(records.count == 1)
        #expect(records.first?.id == recordID)
        #expect(records.first?.text == "V13 transcription")
        #expect(try migratedContext.fetch(FetchDescriptor<MediaFolder>()).count == 1)
        #expect(try migratedContext.fetch(FetchDescriptor<ParticipantProfile>()).count == 1)
        #expect(try migratedContext.fetch(FetchDescriptor<ParticipantTrainingEvidence>()).count == 1)
        #expect(try migratedContext.fetch(FetchDescriptor<WordReplacement>()).count == 1)
        #expect(try migratedContext.fetch(FetchDescriptor<VocabularyWord>()).count == 1)
        #expect(try migratedContext.fetch(FetchDescriptor<Note>()).count == 1)
        #expect(try migratedContext.fetch(FetchDescriptor<PromptPreset>()).count == 2)
        #expect(try migratedContext.fetch(FetchDescriptor<TrainingContribution>()).count == 1)
        #expect(try migratedContext.fetch(FetchDescriptor<CaptureSessionModel>()).count == 1)
        #expect(try migratedContext.fetch(FetchDescriptor<CaptureSourceModel>()).count == 1)
        #expect(try migratedContext.fetch(FetchDescriptor<CaptureChunkModel>()).count == 1)
        #expect(try migratedContext.fetch(FetchDescriptor<CaptureTranscriptRevisionModel>()).count == 1)
        #expect(try migratedContext.fetch(FetchDescriptor<CaptureStageProviderSnapshotModel>()).count == 2)
        #expect(try migratedContext.fetch(FetchDescriptor<CaptureNoteReferenceModel>()).count == 1)
        #expect(try migratedContext.fetch(FetchDescriptor<CaptureFailureRecordModel>()).count == 1)
        #expect(try migratedContext.fetch(FetchDescriptor<CaptureStagePromptSnapshotModel>()).count == 2)
    }
}
