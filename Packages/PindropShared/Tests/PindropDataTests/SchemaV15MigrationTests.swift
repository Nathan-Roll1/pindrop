//
//  SchemaV15MigrationTests.swift
//  PindropDataTests
//
//  Created on 2026-08-22.
//

import Foundation
import PindropCore
import SwiftData
import Testing
@testable import PindropData

@MainActor
@Suite(.serialized)
struct SchemaV15MigrationTests {
    @Test func currentSchemaAppendsNotePanelModelsToV14ModelOrder() throws {
        let v14Models = TranscriptionRecordSchemaV14.models
        let v15Models = TranscriptionRecordSchemaV15.models

        #expect(TranscriptionRecordSchemaV15.versionIdentifier == .init(1, 0, 14))
        #expect(v15Models.count == 20)
        #expect(v15Models[17] == CaptureEnhancedPanelModel.self)
        #expect(v15Models[18] == NoteViewStateModel.self)
        #expect(v15Models[19] == CaptureIntentModel.self)
        for (model, v14Model) in zip(v15Models.dropLast(3), v14Models) {
            #expect(model == v14Model)
        }
    }

    @Test func currentSchemaCatalogAndMigrationPlanEndAtV15() throws {
        let schemas = TranscriptionRecordMigrationPlan.schemas
        let v14Index = try #require(schemas.firstIndex { $0 == TranscriptionRecordSchemaV14.self })
        let v15Index = try #require(schemas.firstIndex { $0 == TranscriptionRecordSchemaV15.self })

        #expect(PindropPersistentSchemaVersion.v15.rawValue == "1.0.14")
        #expect(PindropPersistentSchemaVersion.v15.versionedSchema == TranscriptionRecordSchemaV15.self)
        #expect(PindropPersistentSchemaVersion.allCases.count == 15)
        #expect(PindropPersistentSchemaVersion.allCases.last == .v15)
        #expect(schemas.count == 15)
        #expect(TranscriptionRecordMigrationPlan.stages.count == 14)
        #expect(v15Index == v14Index + 1)
    }

    @Test func diskBackedMigrationFromV14PreservesEveryExistingModelAndOpensTheNewTables() throws {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directoryURL) }

        let storeURL = directoryURL.appendingPathComponent("migration.store")
        let timestamp = Date(timeIntervalSinceReferenceDate: 3_000)
        let recordID = UUID()
        let sessionID = UUID()
        let sourceID = UUID()
        let providerSnapshotID = UUID()
        let promptSnapshotID = UUID()
        let promptPresetID = UUID()
        let noteID = UUID()

        try autoreleasepool {
            let legacySchema = Schema(versionedSchema: TranscriptionRecordSchemaV14.self)
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
                    text: "V14 transcription",
                    timestamp: timestamp,
                    duration: 2.5,
                    modelUsed: "base"
                )
            )
            legacyContext.insert(MediaFolder(name: "V14 folder", createdAt: timestamp, updatedAt: timestamp))
            legacyContext.insert(
                ParticipantProfile(
                    normalizedName: "v14 participant",
                    displayName: "V14 Participant",
                    createdAt: timestamp,
                    updatedAt: timestamp
                )
            )
            legacyContext.insert(
                ParticipantTrainingEvidence(
                    evidenceKey: "v14-evidence",
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
                    originals: ["v14"],
                    replacement: "V15",
                    createdAt: timestamp
                )
            )
            legacyContext.insert(VocabularyWord(word: "V14", createdAt: timestamp))
            legacyContext.insert(
                Note(
                    id: noteID,
                    title: "V14 note",
                    content: "V14 content",
                    sourceTranscriptionID: recordID,
                    createdAt: timestamp,
                    updatedAt: timestamp
                )
            )
            legacyContext.insert(
                PromptPreset(
                    id: promptPresetID,
                    name: "V14 preset",
                    prompt: "V14 prompt",
                    isBuiltIn: true,
                    createdAt: timestamp,
                    updatedAt: timestamp,
                    builtInIdentifier: "v14-built-in-preset"
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
                    text: "V14 revision",
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
                CaptureStagePromptSnapshotModel(
                    id: promptSnapshotID,
                    providerSnapshotID: providerSnapshotID,
                    sessionID: sessionID,
                    presetIdentifier: "v14-built-in-preset",
                    resolvedPrompt: "V14 prompt"
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
                    errorCode: "v14",
                    message: "V14 failure",
                    isRetryable: true,
                    occurredAt: timestamp,
                    recoveryDisposition: .recoverable
                )
            )
            try legacyContext.save()
        }

        let panelID = UUID()
        try autoreleasepool {
            let migratedContainer = try PindropModelContainerFactory.makeContainer(at: storeURL)
            let migratedContext = ModelContext(migratedContainer)

            let records = try migratedContext.fetch(FetchDescriptor<TranscriptionRecord>())
            #expect(records.map(\.id) == [recordID])
            #expect(records.first?.text == "V14 transcription")
            #expect(try migratedContext.fetch(FetchDescriptor<MediaFolder>()).count == 1)
            #expect(try migratedContext.fetch(FetchDescriptor<ParticipantProfile>()).count == 1)
            #expect(try migratedContext.fetch(FetchDescriptor<ParticipantTrainingEvidence>()).count == 1)
            #expect(try migratedContext.fetch(FetchDescriptor<WordReplacement>()).count == 1)
            #expect(try migratedContext.fetch(FetchDescriptor<VocabularyWord>()).count == 1)
            #expect(try migratedContext.fetch(FetchDescriptor<Note>()).count == 1)
            #expect(try migratedContext.fetch(FetchDescriptor<PromptPreset>()).count == 1)
            #expect(try migratedContext.fetch(FetchDescriptor<TrainingContribution>()).count == 1)
            #expect(try migratedContext.fetch(FetchDescriptor<CaptureSessionModel>()).count == 1)
            #expect(try migratedContext.fetch(FetchDescriptor<CaptureSourceModel>()).count == 1)
            #expect(try migratedContext.fetch(FetchDescriptor<CaptureChunkModel>()).count == 1)
            #expect(try migratedContext.fetch(FetchDescriptor<CaptureTranscriptRevisionModel>()).count == 1)
            #expect(try migratedContext.fetch(FetchDescriptor<CaptureStageProviderSnapshotModel>()).count == 1)
            #expect(try migratedContext.fetch(FetchDescriptor<CaptureNoteReferenceModel>()).count == 1)
            #expect(try migratedContext.fetch(FetchDescriptor<CaptureFailureRecordModel>()).count == 1)

            let promptSnapshots = try migratedContext.fetch(
                FetchDescriptor<CaptureStagePromptSnapshotModel>()
            )
            #expect(promptSnapshots.map(\.id) == [promptSnapshotID])

            // The V15 tables start empty and must accept writes right away.
            #expect(try migratedContext.fetch(FetchDescriptor<CaptureEnhancedPanelModel>()).isEmpty)
            #expect(try migratedContext.fetch(FetchDescriptor<NoteViewStateModel>()).isEmpty)
            #expect(try migratedContext.fetch(FetchDescriptor<CaptureIntentModel>()).isEmpty)

            migratedContext.insert(
                CaptureEnhancedPanelModel(
                    id: panelID,
                    sessionID: sessionID,
                    noteID: noteID,
                    templatePresetIdentifier: "meeting-summary",
                    templateDisplayName: "Meeting summary",
                    content: "## Decisions",
                    generation: 1,
                    providerSnapshotID: providerSnapshotID,
                    promptSnapshotID: promptSnapshotID,
                    assignmentAttempt: 1,
                    humanAnchorContentSnapshot: "V14 content",
                    createdAt: timestamp
                )
            )
            migratedContext.insert(
                NoteViewStateModel(
                    noteID: noteID,
                    selection: .enhanced(templatePresetIdentifier: "meeting-summary"),
                    updatedAt: timestamp
                )
            )
            migratedContext.insert(
                try CaptureIntentModel(
                    intent: CaptureIntent(
                        sessionID: sessionID,
                        destination: .existingNote,
                        destinationNoteID: noteID,
                        requestedSourceKinds: [.microphone, .systemAudio],
                        requestedTemplatePresetIdentifier: "meeting-summary",
                        origin: .mainWindow,
                        createdAt: timestamp
                    )
                )
            )
            try migratedContext.save()
        }

        let reopenedContainer = try PindropModelContainerFactory.makeContainer(at: storeURL)
        let reopenedContext = ModelContext(reopenedContainer)

        let panel = try #require(
            try reopenedContext.fetch(FetchDescriptor<CaptureEnhancedPanelModel>()).first
        ).restorePanel()
        #expect(panel.id == panelID)
        #expect(panel.noteID == noteID)
        #expect(panel.templateDisplayName == "Meeting summary")
        #expect(panel.generation == 1)
        #expect(panel.isCurrent)

        let viewState = try #require(
            try reopenedContext.fetch(FetchDescriptor<NoteViewStateModel>()).first
        )
        #expect(viewState.noteID == noteID)
        #expect(
            viewState.resolvedSelection() == .enhanced(templatePresetIdentifier: "meeting-summary")
        )
        #expect(viewState.isTranscriptDeleted == false)

        let intent = try #require(
            try reopenedContext.fetch(FetchDescriptor<CaptureIntentModel>()).first
        ).restoreIntent()
        #expect(intent.sessionID == sessionID)
        #expect(intent.destination == .existingNote)
        #expect(intent.destinationNoteID == noteID)
        #expect(intent.requestedSourceKinds == [.microphone, .systemAudio])
        #expect(intent.requestsSystemAudio)
        #expect(intent.origin == .mainWindow)

        // The typed note the capture was anchored to must be untouched.
        let migratedNote = try #require(
            try reopenedContext.fetch(FetchDescriptor<Note>()).first
        )
        #expect(migratedNote.content == "V14 content")
    }
}
