//
//  CaptureSessionStoreTests.swift
//  PindropDataTests
//
//  Created on 2026-08-20.
//

import Foundation
import PindropCore
import SwiftData
import Testing
@testable import PindropData

@MainActor
@Suite(.serialized)
struct CaptureSessionStoreTests {
    private func makeContainer() throws -> ModelContainer {
        try PindropModelContainerFactory.makeInMemoryContainer()
    }

    private func makeStore(in container: ModelContainer) -> CaptureSessionStore {
        CaptureSessionStore(modelContext: ModelContext(container))
    }

    private func noteIntent(
        destination: CaptureIntentDestination = .newNote,
        destinationNoteID: UUID? = nil,
        templatePresetIdentifier: String? = nil,
        origin: CaptureIntentOrigin = .mainWindow
    ) -> CaptureIntentRequest {
        CaptureIntentRequest(
            destination: destination,
            destinationNoteID: destinationNoteID,
            requestedTemplatePresetIdentifier: templatePresetIdentifier,
            origin: origin
        )
    }

    private func retained(
        _ sourceID: UUID,
        sessionID: UUID,
        path: String? = nil
    ) -> RetainedMeetingSource {
        RetainedMeetingSource(
            sourceID: sourceID,
            sampleRate: 16_000,
            channelCount: 1,
            duration: 2,
            managedMediaPath: path ?? CaptureSourceArtifactPath.relativePath(
                sessionID: sessionID,
                sourceID: sourceID,
                chunkSequence: 0
            ),
            byteCount: 128_000,
            sha256: String(repeating: "a", count: 64)
        )
    }

    private func failed(
        _ sourceID: UUID,
        at timestamp: Date,
        message: String = "Source capture failed."
    ) -> FailedMeetingSource {
        FailedMeetingSource(
            sourceID: sourceID,
            errorDomain: "AudioCapture",
            errorCode: "unavailable",
            message: message,
            occurredAt: timestamp
        )
    }
    private func chunk(
        _ sourceID: UUID,
        sessionID: UUID,
        sequence: Int,
        sealedAt: Date
    ) -> MeetingChunkCheckpoint {
        let byteCount = MeetingCaptureSpoolPlan.defaultChunkByteCount
        let duration = Double(byteCount) /
            Double(MeetingCaptureSpoolPlan.sampleRate * MeetingCaptureSpoolPlan.bytesPerSample)
        return MeetingChunkCheckpoint(
            sourceID: sourceID,
            sequence: sequence,
            startOffset: Double(sequence) * duration,
            duration: duration,
            managedMediaPath: CaptureSourceArtifactPath.relativePath(
                sessionID: sessionID,
                sourceID: sourceID,
                chunkSequence: sequence
            ),
            byteCount: byteCount,
            sha256: String(format: "%064x", sequence + 1),
            sealedAt: sealedAt
        )
    }
    private func sealed(
        _ checkpoint: MeetingChunkCheckpoint,
        sessionID: UUID
    ) -> SealedAudioSourceChunk {
        SealedAudioSourceChunk(
            sessionID: sessionID,
            sourceID: checkpoint.sourceID,
            sequence: checkpoint.sequence,
            startOffset: checkpoint.startOffset,
            duration: checkpoint.duration,
            fileURL: URL(fileURLWithPath: "/recovered/chunk-\(checkpoint.sequence).pcm"),
            relativePath: checkpoint.managedMediaPath,
            byteCount: Int64(checkpoint.byteCount),
            sha256: checkpoint.sha256
        )
    }

    private func recoveryFailure(
        _ sourceID: UUID,
        sequence: Int? = nil,
        invalidatesSource: Bool = false,
        at timestamp: Date,
        message: String
    ) -> MeetingChunkFailure {
        MeetingChunkFailure(
            sourceID: sourceID,
            sequence: sequence,
            invalidatesSource: invalidatesSource,
            errorDomain: "MeetingArtifactRecovery",
            errorCode: "corrupt",
            message: message,
            isRetryable: true,
            occurredAt: timestamp
        )
    }

    private func assignment(
        stage: CapturePipelineStage,
        providerKind: CaptureAssignmentProviderKind? = nil,
        providerIdentifier: String = "catalog-provider",
        modelIdentifier: String? = "catalog-model",
        prompt: CapturePromptSnapshot? = nil,
        selectedAt: Date = Date(timeIntervalSinceReferenceDate: 20_000),
        attempt: Int = 1
    ) throws -> CaptureStageAssignment {
        try CaptureStageAssignment(
            stage: stage,
            providerKind: providerKind ?? (
                stage == .liveTranscription ? .streamingSpeech : .batchSpeech
            ),
            providerIdentifier: providerIdentifier,
            modelIdentifier: modelIdentifier,
            prompt: prompt,
            selectedAt: selectedAt,
            attempt: attempt
        )
    }
    private func generatedMeetingNoteInputs(
        in container: ModelContainer,
        store: CaptureSessionStore,
        startedAt: Date
    ) throws -> (
        handle: NoteCaptureHandle,
        transcriptionRecordID: UUID,
        source: MeetingNoteSourceBundle
    ) {
        let handle = try store.startMeetingCapture(startedAt: startedAt)
        _ = try store.ensureMeetingHumanAnchor(
            handle,
            title: "Planning",
            at: startedAt
        )
        try store.beginMeetingFinalization(handle, at: startedAt.addingTimeInterval(1))
        let checkpoint = chunk(
            handle.microphoneSourceID,
            sessionID: handle.sessionID,
            sequence: 0,
            sealedAt: startedAt.addingTimeInterval(2)
        )
        try store.recordSealedMeetingChunk(handle, checkpoint: checkpoint)
        _ = try store.resolveAssignment(
            sessionID: handle.sessionID,
            stage: .finalTranscription,
            attempt: 1,
            selecting: { try assignment(stage: .finalTranscription) }
        )
        let revisionID = try store.recordMeetingTranscriptionChunk(
            handle,
            sourceChunkSequence: 0,
            startOffset: checkpoint.startOffset,
            duration: checkpoint.duration,
            text: "Completed final transcript",
            assignmentAttempt: 1
        )
        let transcriptionRecordID = try store.reserveMeetingTranscriptionRecordID(handle)
        let context = ModelContext(container)
        context.insert(TranscriptionRecord(
            id: transcriptionRecordID,
            text: "Completed final transcript",
            duration: checkpoint.duration,
            modelUsed: "test"
        ))
        try context.save()
        _ = try store.resolveAssignment(
            sessionID: handle.sessionID,
            stage: .noteGeneration,
            attempt: 1,
            selecting: {
                try assignment(
                    stage: .noteGeneration,
                    providerKind: .generativeAI,
                    providerIdentifier: "generator",
                    modelIdentifier: "generator-model",
                    prompt: CapturePromptSnapshot(
                        presetIdentifier: "meeting-summary",
                        resolvedPrompt: "Summarize this meeting."
                    )
                )
            }
        )
        let source = try MeetingNoteDerivation.make(
            humanNoteContent: "",
            checkpoints: [
                MeetingTranscriptionCheckpoint(
                    revisionID: revisionID,
                    providerSnapshotID: nil,
                    sequence: checkpoint.sequence,
                    startOffset: checkpoint.startOffset,
                    duration: checkpoint.duration,
                    text: "Completed final transcript",
                    segmentsJSON: nil,
                    languageCode: nil
                )
            ]
        )
        return (
            handle: handle,
            transcriptionRecordID: transcriptionRecordID,
            source: source
        )
    }

    private func generatedMeetingNoteContent(
        _ body: String = "Auditable generated content."
    ) -> String {
        MeetingNoteDerivation.sanitizingGeneratedContent(body)
    }


    @Test func captureSourceArtifactPathUsesCanonicalMeetingLocation() throws {
        let sessionID = try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000001"))
        let sourceID = try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000002"))

        #expect(
            CaptureSourceArtifactPath.relativePath(
                sessionID: sessionID,
                sourceID: sourceID,
                chunkSequence: 0
            ) == "CaptureSessions/00000000-0000-0000-0000-000000000001/Sources/00000000-0000-0000-0000-000000000002/chunk-00000.pcm"
        )
    }

    @Test func startCreatesVoiceNoteSessionAndMicrophoneSource() throws {
        let container = try makeContainer()
        let startedAt = Date(timeIntervalSinceReferenceDate: 2_000)
        let handle = try makeStore(in: container).startVoiceNoteCapture(
            startedAt: startedAt,
            microphoneDisplayName: "Built-in Microphone"
        )

        let freshContext = ModelContext(container)
        let session = try #require(
            freshContext.fetch(FetchDescriptor<CaptureSessionModel>()).first { $0.id == handle.sessionID }
        )
        let source = try #require(
            freshContext.fetch(FetchDescriptor<CaptureSourceModel>()).first { $0.id == handle.microphoneSourceID }
        )
        let restored = try session.restoreSession()
        #expect(restored.mode == .voiceNote)
        #expect(restored.state == .capturing)
        #expect(restored.startedAt == startedAt)
        #expect(source.sessionID == handle.sessionID)
        #expect(source.kindRawValue == CaptureSourceKind.microphone.rawValue)
        #expect(source.sequence == 0)
        #expect(source.displayName == "Built-in Microphone")
        #expect(source.startedAt == startedAt)
    }

    @Test func transcriptRevisionsHaveParentChainWhenTextsMatch() throws {
        let container = try makeContainer()
        let store = makeStore(in: container)
        let startedAt = Date(timeIntervalSinceReferenceDate: 3_000)
        let handle = try store.startVoiceNoteCapture(startedAt: startedAt)
        try store.beginFinalization(handle, at: startedAt.addingTimeInterval(1))

        let revisions = try store.saveTranscriptRevisions(
            for: handle,
            rawText: "Matching transcript",
            finalText: "Matching transcript",
            duration: 12.5,
            languageCode: "en",
            createdAt: startedAt.addingTimeInterval(2)
        )

        let freshContext = ModelContext(container)
        let raw = try #require(
            freshContext.fetch(FetchDescriptor<CaptureTranscriptRevisionModel>()).first {
                $0.id == revisions.rawRevisionID
            }
        )
        let finalRevision = try #require(
            freshContext.fetch(FetchDescriptor<CaptureTranscriptRevisionModel>()).first {
                $0.id == revisions.finalRevisionID
            }
        )
        #expect(raw.sessionID == handle.sessionID)
        #expect(raw.sourceID == handle.microphoneSourceID)
        #expect(raw.parentRevisionID == nil)
        #expect(finalRevision.sessionID == handle.sessionID)
        #expect(finalRevision.sourceID == handle.microphoneSourceID)
        #expect(finalRevision.parentRevisionID == raw.id)
        #expect(finalRevision.sequence == raw.sequence + 1)
        #expect(raw.sequence == 0)
        #expect(finalRevision.stageRawValue == CapturePipelineStage.finalTranscription.rawValue)
        #expect(raw.text == finalRevision.text)
    }

    @Test func linksHistoryRecordAndCompletesWithHumanAnchorNote() async throws {
        let container = try makeContainer()
        let store = makeStore(in: container)
        let startedAt = Date(timeIntervalSinceReferenceDate: 4_000)
        let handle = try store.startVoiceNoteCapture(startedAt: startedAt)
        try store.beginFinalization(handle, at: startedAt.addingTimeInterval(1))
        let revisions = try store.saveTranscriptRevisions(
            for: handle,
            rawText: "Raw transcript",
            finalText: "Final transcript",
            duration: 8,
            languageCode: "en",
            createdAt: startedAt.addingTimeInterval(2)
        )
        let retriedRevisions = try store.saveTranscriptRevisions(
            for: handle,
            rawText: "Raw transcript",
            finalText: "Final transcript",
            duration: 8,
            languageCode: "en",
            createdAt: startedAt.addingTimeInterval(20)
        )
        #expect(retriedRevisions == revisions)
        let historyRecord = try HistoryStore(modelContext: ModelContext(container)).save(
            text: "Final transcript",
            originalText: "Raw transcript",
            duration: 8,
            modelUsed: "voice-note"
        )
        try store.linkTranscriptionRecord(
            historyRecord.id,
            to: handle,
            at: startedAt.addingTimeInterval(3)
        )
        let note = try await NotesStore(
            modelContext: ModelContext(container),
            metadataGenerator: { _, _ in nil }
        ).create(
            title: "Voice note",
            content: "Final transcript",
            sourceTranscriptionID: historyRecord.id
        )
        try store.complete(
            handle,
            noteID: note.id,
            finalTranscriptRevisionID: retriedRevisions.finalRevisionID,
            at: startedAt.addingTimeInterval(4)
        )
        let completedRetry = try store.saveTranscriptRevisions(
            for: handle,
            rawText: "Raw transcript",
            finalText: "Final transcript",
            duration: 8,
            languageCode: "en",
            createdAt: startedAt.addingTimeInterval(5)
        )
        #expect(completedRetry == retriedRevisions)

        let freshContext = ModelContext(container)
        let session = try #require(
            freshContext.fetch(FetchDescriptor<CaptureSessionModel>()).first { $0.id == handle.sessionID }
        )
        let reference = try #require(
            freshContext.fetch(FetchDescriptor<CaptureNoteReferenceModel>()).first {
                $0.sessionID == handle.sessionID
            }
        )
        #expect(session.transcriptionRecordID == historyRecord.id)
        #expect(try session.restoreSession().state == .completed)
        #expect(reference.noteID == note.id)
        #expect(reference.roleRawValue == CaptureNoteRole.humanAnchor.rawValue)
        #expect(reference.sourceTranscriptRevisionID == retriedRevisions.finalRevisionID)
    }

    @Test func transcriptRevisionsRequireFinalizingAndExactRetriesPreserveTheirCanonicalPair() throws {
        let container = try makeContainer()
        let store = makeStore(in: container)
        let startedAt = Date(timeIntervalSinceReferenceDate: 4_500)
        let handle = try store.startVoiceNoteCapture(startedAt: startedAt)

        #expect(
            throws: CaptureSessionStoreError.voiceNoteSessionNotFinalizing(
                sessionID: handle.sessionID,
                actualStateRawValue: CaptureSessionState.capturing.rawValue
            )
        ) {
            try store.saveTranscriptRevisions(
                for: handle,
                rawText: "Raw transcript",
                finalText: "Final transcript",
                duration: 8,
                languageCode: "en",
                createdAt: startedAt.addingTimeInterval(1)
            )
        }

        try store.beginFinalization(handle, at: startedAt.addingTimeInterval(2))
        let saved = try store.saveTranscriptRevisions(
            for: handle,
            rawText: "Raw transcript",
            finalText: "Final transcript",
            duration: 8,
            languageCode: "en",
            createdAt: startedAt.addingTimeInterval(3)
        )
        let retried = try store.saveTranscriptRevisions(
            for: handle,
            rawText: "Raw transcript",
            finalText: "Final transcript",
            duration: 8,
            languageCode: "en",
            createdAt: startedAt.addingTimeInterval(30)
        )

        #expect(retried == saved)
        let context = ModelContext(container)
        let revisions = try context.fetch(FetchDescriptor<CaptureTranscriptRevisionModel>())
            .filter { $0.sessionID == handle.sessionID }
        #expect(revisions.count == 2)

        #expect(
            throws: CaptureSessionStoreError.voiceNoteFinalTranscriptConflict(
                sessionID: handle.sessionID
            )
        ) {
            try store.saveTranscriptRevisions(
                for: handle,
                rawText: "Changed raw transcript",
                finalText: "Final transcript",
                duration: 8,
                languageCode: "en"
            )
        }
        #expect(
            throws: CaptureSessionStoreError.voiceNoteFinalTranscriptConflict(
                sessionID: handle.sessionID
            )
        ) {
            try store.saveTranscriptRevisions(
                for: handle,
                rawText: "Raw transcript",
                finalText: "Changed final transcript",
                duration: 8,
                languageCode: "en"
            )
        }
        #expect(
            throws: CaptureSessionStoreError.voiceNoteFinalTranscriptConflict(
                sessionID: handle.sessionID
            )
        ) {
            try store.saveTranscriptRevisions(
                for: handle,
                rawText: "Raw transcript",
                finalText: "Final transcript",
                duration: 9,
                languageCode: "en"
            )
        }
        #expect(
            throws: CaptureSessionStoreError.voiceNoteFinalTranscriptConflict(
                sessionID: handle.sessionID
            )
        ) {
            try store.saveTranscriptRevisions(
                for: handle,
                rawText: "Raw transcript",
                finalText: "Final transcript",
                duration: 8,
                languageCode: "fr"
            )
        }
        #expect(
            try context.fetch(FetchDescriptor<CaptureTranscriptRevisionModel>())
                .filter { $0.sessionID == handle.sessionID }
                .count == 2
        )
    }

    @Test func transcriptRevisionRetriesRejectExtraFinalStageRowsWithoutMutation() throws {
        let container = try makeContainer()
        let store = makeStore(in: container)
        let startedAt = Date(timeIntervalSinceReferenceDate: 4_750)
        let handle = try store.startVoiceNoteCapture(startedAt: startedAt)
        try store.beginFinalization(handle, at: startedAt.addingTimeInterval(1))
        let revisions = try store.saveTranscriptRevisions(
            for: handle,
            rawText: "Raw transcript",
            finalText: "Final transcript",
            duration: 8,
            languageCode: "en",
            createdAt: startedAt.addingTimeInterval(2)
        )

        let context = ModelContext(container)
        context.insert(
            CaptureTranscriptRevisionModel(
                sessionID: handle.sessionID,
                sourceID: handle.microphoneSourceID,
                sequence: 2,
                parentRevisionID: revisions.finalRevisionID,
                stage: .finalTranscription,
                statusRawValue: "completed",
                startOffset: 0,
                duration: 8,
                text: "Unexpected extra transcript",
                languageCode: "en"
            )
        )
        try context.save()

        #expect(
            throws: CaptureSessionStoreError.voiceNoteFinalTranscriptConflict(
                sessionID: handle.sessionID
            )
        ) {
            try store.saveTranscriptRevisions(
                for: handle,
                rawText: "Raw transcript",
                finalText: "Final transcript",
                duration: 8,
                languageCode: "en"
            )
        }
        #expect(
            try context.fetch(FetchDescriptor<CaptureTranscriptRevisionModel>())
                .filter { $0.sessionID == handle.sessionID }
                .count == 3
        )
    }

    @Test func completionPreflightsNoteBeforeCreatingReference() throws {
        let container = try makeContainer()
        let store = makeStore(in: container)
        let startedAt = Date(timeIntervalSinceReferenceDate: 5_000)
        let handle = try store.startVoiceNoteCapture(startedAt: startedAt)
        try store.beginFinalization(handle, at: startedAt.addingTimeInterval(1))
        let revisions = try store.saveTranscriptRevisions(
            for: handle,
            rawText: "Raw",
            finalText: "Final",
            duration: 1,
            languageCode: nil,
            createdAt: startedAt.addingTimeInterval(2)
        )
        let missingNoteID = UUID()

        #expect(throws: CaptureSessionStoreError.noteNotFound(missingNoteID)) {
            try store.complete(
                handle,
                noteID: missingNoteID,
                finalTranscriptRevisionID: revisions.finalRevisionID,
                at: startedAt.addingTimeInterval(3)
            )
        }

        let freshContext = ModelContext(container)
        let session = try #require(
            freshContext.fetch(FetchDescriptor<CaptureSessionModel>()).first { $0.id == handle.sessionID }
        )
        let references = try freshContext.fetch(FetchDescriptor<CaptureNoteReferenceModel>())
        #expect(try session.restoreSession().state == .finalizing)
        #expect(references.filter { $0.sessionID == handle.sessionID }.isEmpty)
    }

    @Test func completionRejectsInvalidFinalRevisionShapesBeforeMutation() throws {
        let container = try makeContainer()
        let store = makeStore(in: container)
        let startedAt = Date(timeIntervalSinceReferenceDate: 5_500)
        let handle = try store.startVoiceNoteCapture(startedAt: startedAt)
        try store.beginFinalization(handle, at: startedAt.addingTimeInterval(1))

        let note = Note(title: "Voice note", content: "Final transcript")
        let raw = CaptureTranscriptRevisionModel(
            sessionID: handle.sessionID,
            sourceID: handle.microphoneSourceID,
            sequence: 0,
            stage: .finalTranscription,
            statusRawValue: "completed",
            startOffset: 0,
            duration: 1,
            text: "Raw transcript"
        )
        let wrongSourceID = UUID()
        let wrongSourceFinal = CaptureTranscriptRevisionModel(
            sessionID: handle.sessionID,
            sourceID: wrongSourceID,
            sequence: 1,
            parentRevisionID: raw.id,
            stage: .finalTranscription,
            statusRawValue: "completed",
            startOffset: 0,
            duration: 1,
            text: "Wrong source final"
        )
        let nonChildFinal = CaptureTranscriptRevisionModel(
            sessionID: handle.sessionID,
            sourceID: handle.microphoneSourceID,
            sequence: 2,
            parentRevisionID: raw.id,
            stage: .finalTranscription,
            statusRawValue: "completed",
            startOffset: 0,
            duration: 1,
            text: "Non-child final"
        )
        let wrongStageFinal = CaptureTranscriptRevisionModel(
            sessionID: handle.sessionID,
            sourceID: handle.microphoneSourceID,
            sequence: 1,
            parentRevisionID: raw.id,
            stage: .liveTranscription,
            statusRawValue: "completed",
            startOffset: 0,
            duration: 1,
            text: "Wrong stage final"
        )
        let pendingFinal = CaptureTranscriptRevisionModel(
            sessionID: handle.sessionID,
            sourceID: handle.microphoneSourceID,
            sequence: 1,
            parentRevisionID: raw.id,
            stage: .finalTranscription,
            statusRawValue: "pending",
            startOffset: 0,
            duration: 1,
            text: "Pending final"
        )
        let foreignSourceParent = CaptureTranscriptRevisionModel(
            sessionID: handle.sessionID,
            sourceID: UUID(),
            sequence: 10,
            stage: .finalTranscription,
            statusRawValue: "completed",
            startOffset: 0,
            duration: 1,
            text: "Foreign source raw transcript"
        )
        let foreignParentFinal = CaptureTranscriptRevisionModel(
            sessionID: handle.sessionID,
            sourceID: handle.microphoneSourceID,
            sequence: 11,
            parentRevisionID: foreignSourceParent.id,
            stage: .finalTranscription,
            statusRawValue: "completed",
            startOffset: 0,
            duration: 1,
            text: "Foreign parent final"
        )
        let context = ModelContext(container)
        context.insert(note)
        context.insert(raw)
        context.insert(wrongSourceFinal)
        context.insert(nonChildFinal)
        context.insert(pendingFinal)
        context.insert(foreignSourceParent)
        context.insert(foreignParentFinal)
        try context.save()

        #expect(throws: CaptureSessionStoreError.invalidFinalTranscriptRevision(raw.id)) {
            try store.complete(
                handle,
                noteID: note.id,
                finalTranscriptRevisionID: raw.id,
                at: startedAt.addingTimeInterval(2)
            )
        }
        #expect(
            throws: CaptureSessionStoreError.transcriptRevisionSourceMismatch(
                revisionID: wrongSourceFinal.id,
                expectedSourceID: handle.microphoneSourceID,
                actualSourceID: wrongSourceID
            )
        ) {
            try store.complete(
                handle,
                noteID: note.id,
                finalTranscriptRevisionID: wrongSourceFinal.id,
                at: startedAt.addingTimeInterval(2)
            )
        }
        #expect(throws: CaptureSessionStoreError.invalidFinalTranscriptRevision(nonChildFinal.id)) {
            try store.complete(
                handle,
                noteID: note.id,
                finalTranscriptRevisionID: nonChildFinal.id,
                at: startedAt.addingTimeInterval(2)
            )
        }
        context.insert(wrongStageFinal)
        try context.save()

        #expect(throws: CaptureSessionStoreError.invalidFinalTranscriptRevision(wrongStageFinal.id)) {
            try store.complete(
                handle,
                noteID: note.id,
                finalTranscriptRevisionID: wrongStageFinal.id,
                at: startedAt.addingTimeInterval(2)
            )
        }
        context.delete(wrongStageFinal)
        try context.save()
        #expect(throws: CaptureSessionStoreError.invalidFinalTranscriptRevision(pendingFinal.id)) {
            try store.complete(
                handle,
                noteID: note.id,
                finalTranscriptRevisionID: pendingFinal.id,
                at: startedAt.addingTimeInterval(2)
            )
        }
        #expect(throws: CaptureSessionStoreError.invalidFinalTranscriptRevision(foreignParentFinal.id)) {
            try store.complete(
                handle,
                noteID: note.id,
                finalTranscriptRevisionID: foreignParentFinal.id,
                at: startedAt.addingTimeInterval(2)
            )
        }

        let freshContext = ModelContext(container)
        let session = try #require(
            freshContext.fetch(FetchDescriptor<CaptureSessionModel>()).first { $0.id == handle.sessionID }
        )
        #expect(try session.restoreSession().state == .finalizing)
        let references = try freshContext.fetch(FetchDescriptor<CaptureNoteReferenceModel>())
        #expect(references.filter { $0.sessionID == handle.sessionID }.isEmpty)
    }

    @Test func cancelAndFailWriteTypedTerminalStates() throws {
        let container = try makeContainer()
        let store = makeStore(in: container)
        let startedAt = Date(timeIntervalSinceReferenceDate: 6_000)
        let cancelled = try store.startVoiceNoteCapture(startedAt: startedAt)
        try store.cancel(cancelled, at: startedAt.addingTimeInterval(1))

        let failed = try store.startVoiceNoteCapture(startedAt: startedAt)
        try store.fail(
            failed,
            stage: .finalTranscription,
            errorDomain: "Transcription",
            errorCode: "unavailable",
            message: "The provider did not produce a final transcript.",
            at: startedAt.addingTimeInterval(1)
        )

        let freshContext = ModelContext(container)
        let cancelledSession = try #require(
            freshContext.fetch(FetchDescriptor<CaptureSessionModel>()).first { $0.id == cancelled.sessionID }
        )
        let failedSession = try #require(
            freshContext.fetch(FetchDescriptor<CaptureSessionModel>()).first { $0.id == failed.sessionID }
        )
        let failure = try #require(
            freshContext.fetch(FetchDescriptor<CaptureFailureRecordModel>()).first {
                $0.sessionID == failed.sessionID
            }
        )
        #expect(try cancelledSession.restoreSession().state == .cancelled)
        #expect(try failedSession.restoreSession().state == .failed)
        #expect(failure.sessionID == failed.sessionID)
        #expect(failure.sourceID == failed.microphoneSourceID)
        #expect(failure.stageRawValue == CapturePipelineStage.finalTranscription.rawValue)
        #expect(failure.errorDomain == "Transcription")
        #expect(failure.errorCode == "unavailable")
        #expect(failure.recoveryDispositionRawValue == CaptureFailureDisposition.terminal.rawValue)
    }

    @Test func rejectsUnknownStaleAndCrossSessionHandles() throws {
        let container = try makeContainer()
        let store = makeStore(in: container)
        let startedAt = Date(timeIntervalSinceReferenceDate: 7_000)
        let first = try store.startVoiceNoteCapture(startedAt: startedAt)
        let second = try store.startVoiceNoteCapture(startedAt: startedAt)
        let unknown = VoiceNoteCaptureHandle(sessionID: UUID(), microphoneSourceID: UUID())
        let stale = VoiceNoteCaptureHandle(sessionID: first.sessionID, microphoneSourceID: UUID())
        let crossSession = VoiceNoteCaptureHandle(
            sessionID: second.sessionID,
            microphoneSourceID: first.microphoneSourceID
        )

        #expect(throws: CaptureSessionStoreError.sessionNotFound(unknown.sessionID)) {
            try store.beginFinalization(unknown, at: startedAt.addingTimeInterval(1))
        }
        #expect(throws: CaptureSessionStoreError.sourceNotFound(stale.microphoneSourceID)) {
            try store.beginFinalization(stale, at: startedAt.addingTimeInterval(1))
        }
        #expect(
            throws: CaptureSessionStoreError.sourceSessionMismatch(
                sourceID: first.microphoneSourceID,
                expectedSessionID: second.sessionID,
                actualSessionID: first.sessionID
            )
        ) {
            try store.beginFinalization(crossSession, at: startedAt.addingTimeInterval(1))
        }
    }
    @Test func meetingStopPersistsBothRetainedSourcesAndSealedChunks() throws {
        let container = try makeContainer()
        let store = makeStore(in: container)
        let startedAt = Date(timeIntervalSinceReferenceDate: 8_000)
        let handle = try store.startMeetingCapture(
            startedAt: startedAt,
            microphoneDisplayName: "Built-in Microphone",
            systemAudioDisplayName: "System Audio"
        )
        try store.beginMeetingFinalization(handle, at: startedAt.addingTimeInterval(1))
        try store.recordMeetingStop(
            handle,
            retained: [
                retained(handle.microphoneSourceID, sessionID: handle.sessionID),
                retained(handle.dualSourceSystemAudioID, sessionID: handle.sessionID)
            ],
            failures: [],
            at: startedAt.addingTimeInterval(2)
        )

        let context = ModelContext(container)
        let session = try #require(
            context.fetch(FetchDescriptor<CaptureSessionModel>()).first { $0.id == handle.sessionID }
        )
        let sources = try context.fetch(FetchDescriptor<CaptureSourceModel>())
            .filter { $0.sessionID == handle.sessionID }
        let chunks = try context.fetch(FetchDescriptor<CaptureChunkModel>())
            .filter { $0.sessionID == handle.sessionID }
        let microphoneSource = try #require(sources.first { $0.id == handle.microphoneSourceID })
        #expect(try session.restoreSession().state == .finalizing)
        #expect(Set(sources.map(\.stateRawValue)) == Set([CaptureSourceState.completed.rawValue]))
        #expect(microphoneSource.sampleRate == 16_000)
        #expect(microphoneSource.channelCount == 1)
        #expect(microphoneSource.codecRawValue == "pcm")
        #expect(microphoneSource.endedAt == startedAt.addingTimeInterval(2))
        #expect(chunks.count == 2)
        #expect(
            Set(chunks.map(\.sourceID)) ==
                Set([handle.microphoneSourceID, handle.dualSourceSystemAudioID])
        )
        #expect(chunks.allSatisfy {
            $0.sequence == 0 &&
                $0.stateRawValue == CaptureChunkState.sealed.rawValue &&
                $0.startOffset == 0 &&
                $0.sealedAt == startedAt.addingTimeInterval(2)
        })
    }

    @Test func meetingStopRetainsMicrophoneWhenSystemAudioFails() throws {
        let container = try makeContainer()
        let store = makeStore(in: container)
        let startedAt = Date(timeIntervalSinceReferenceDate: 8_100)
        let handle = try store.startMeetingCapture(startedAt: startedAt)
        try store.beginMeetingFinalization(handle, at: startedAt.addingTimeInterval(1))
        try store.recordMeetingStop(
            handle,
            retained: [retained(handle.microphoneSourceID, sessionID: handle.sessionID)],
            failures: [failed(handle.dualSourceSystemAudioID, at: startedAt.addingTimeInterval(2))],
            at: startedAt.addingTimeInterval(3)
        )

        let context = ModelContext(container)
        let session = try #require(
            context.fetch(FetchDescriptor<CaptureSessionModel>()).first { $0.id == handle.sessionID }
        )
        let chunks = try context.fetch(FetchDescriptor<CaptureChunkModel>())
        let failures = try context.fetch(FetchDescriptor<CaptureFailureRecordModel>())
        let sourceStates = Dictionary(
            uniqueKeysWithValues: try context.fetch(FetchDescriptor<CaptureSourceModel>())
                .map { ($0.id, $0.stateRawValue) }
        )
        #expect(chunks.filter { $0.sessionID == handle.sessionID }.map(\.sourceID) == [handle.microphoneSourceID])
        #expect(failures.filter { $0.sessionID == handle.sessionID }.map(\.sourceID) == [handle.dualSourceSystemAudioID])
        #expect(sourceStates[handle.microphoneSourceID] == CaptureSourceState.completed.rawValue)
        #expect(sourceStates[handle.dualSourceSystemAudioID] == CaptureSourceState.failed.rawValue)
        #expect(try session.restoreSession().state == .finalizing)
    }

    @Test func meetingStopRetainsSystemAudioWhenMicrophoneFails() throws {
        let container = try makeContainer()
        let store = makeStore(in: container)
        let startedAt = Date(timeIntervalSinceReferenceDate: 8_200)
        let handle = try store.startMeetingCapture(startedAt: startedAt)
        try store.beginMeetingFinalization(handle, at: startedAt.addingTimeInterval(1))
        try store.recordMeetingStop(
            handle,
            retained: [retained(handle.dualSourceSystemAudioID, sessionID: handle.sessionID)],
            failures: [failed(handle.microphoneSourceID, at: startedAt.addingTimeInterval(2))],
            at: startedAt.addingTimeInterval(3)
        )

        let context = ModelContext(container)
        let session = try #require(
            context.fetch(FetchDescriptor<CaptureSessionModel>()).first { $0.id == handle.sessionID }
        )
        let chunks = try context.fetch(FetchDescriptor<CaptureChunkModel>())
        let failures = try context.fetch(FetchDescriptor<CaptureFailureRecordModel>())
        #expect(chunks.filter { $0.sessionID == handle.sessionID }.map(\.sourceID) == [handle.dualSourceSystemAudioID])
        #expect(failures.filter { $0.sessionID == handle.sessionID }.map(\.sourceID) == [handle.microphoneSourceID])
        #expect(try session.restoreSession().state == .finalizing)
    }

    @Test func meetingStopFailsSessionWithLatestFailureWhenNeitherSourceRetainsAudio() throws {
        let container = try makeContainer()
        let store = makeStore(in: container)
        let startedAt = Date(timeIntervalSinceReferenceDate: 8_300)
        let handle = try store.startMeetingCapture(startedAt: startedAt)
        try store.beginMeetingFinalization(handle, at: startedAt.addingTimeInterval(1))
        try store.recordMeetingStop(
            handle,
            retained: [],
            failures: [
                failed(handle.microphoneSourceID, at: startedAt.addingTimeInterval(2), message: "Microphone failed."),
                failed(handle.dualSourceSystemAudioID, at: startedAt.addingTimeInterval(3), message: "System audio failed.")
            ],
            at: startedAt.addingTimeInterval(4)
        )

        let context = ModelContext(container)
        let session = try #require(
            context.fetch(FetchDescriptor<CaptureSessionModel>()).first { $0.id == handle.sessionID }
        )
        let chunks = try context.fetch(FetchDescriptor<CaptureChunkModel>())
            .filter { $0.sessionID == handle.sessionID }
        let failures = try context.fetch(FetchDescriptor<CaptureFailureRecordModel>())
            .filter { $0.sessionID == handle.sessionID }
        let aggregateFailure = try #require(failures.first { $0.id == session.latestFailureID })
        #expect(try session.restoreSession().state == .failed)
        #expect(chunks.isEmpty)
        #expect(failures.count == 3)
        #expect(aggregateFailure.sourceID == nil)
        #expect(aggregateFailure.message == "System audio failed.")
    }

    @Test func meetingCancelAndStartFailureLeaveHonestTerminalSourceStates() throws {
        let container = try makeContainer()
        let store = makeStore(in: container)
        let startedAt = Date(timeIntervalSinceReferenceDate: 8_400)
        let cancelled = try store.startMeetingCapture(startedAt: startedAt)
        try store.cancelMeetingCapture(cancelled, at: startedAt.addingTimeInterval(1))
        let failed = try store.startMeetingCapture(startedAt: startedAt)
        try store.failMeetingCapture(
            failed,
            stage: nil,
            errorDomain: "AudioCapture",
            errorCode: "startFailed",
            message: "Audio capture could not start.",
            at: startedAt.addingTimeInterval(1)
        )

        let context = ModelContext(container)
        let sessions = try context.fetch(FetchDescriptor<CaptureSessionModel>())
        let sources = try context.fetch(FetchDescriptor<CaptureSourceModel>())
        let cancelledSession = try #require(sessions.first { $0.id == cancelled.sessionID })
        let failedSession = try #require(sessions.first { $0.id == failed.sessionID })
        #expect(try cancelledSession.restoreSession().state == .cancelled)
        #expect(try failedSession.restoreSession().state == .failed)
        #expect(
            sources.filter { $0.sessionID == cancelled.sessionID }
                .allSatisfy { $0.stateRawValue == CaptureSourceState.cancelled.rawValue }
        )
        #expect(
            sources.filter { $0.sessionID == failed.sessionID }
                .allSatisfy { $0.stateRawValue == CaptureSourceState.failed.rawValue }
        )
    }

    @Test func cancelledMeetingCancellationIsIdempotentAndOnlyFeedsCleanup() throws {
        let container = try makeContainer()
        let store = makeStore(in: container)
        let startedAt = Date(timeIntervalSinceReferenceDate: 8_450)
        let cancelled = try store.startMeetingCapture(startedAt: startedAt)
        let active = try store.startMeetingCapture(startedAt: startedAt.addingTimeInterval(1))

        try store.cancelMeetingCapture(cancelled, at: startedAt.addingTimeInterval(2))
        try store.cancelMeetingCapture(cancelled, at: startedAt.addingTimeInterval(3))

        #expect(try store.cancelledNoteCaptureSessionIDs() == [cancelled.sessionID])
        #expect(try store.meetingRecoveryCandidates().allSatisfy {
            $0.handle.sessionID != cancelled.sessionID
        })
        #expect(try store.meetingRecoveryCandidates().contains {
            $0.handle.sessionID == active.sessionID
        })
    }

    @Test func meetingStopRejectsInvalidOutcomesWithoutMutatingAnySource() throws {
        let container = try makeContainer()
        let store = makeStore(in: container)
        let startedAt = Date(timeIntervalSinceReferenceDate: 8_500)
        let handle = try store.startMeetingCapture(startedAt: startedAt)
        try store.beginMeetingFinalization(handle, at: startedAt.addingTimeInterval(1))

        #expect(throws: CaptureSessionStoreError.meetingSourceOutcomeDuplicate(handle.microphoneSourceID)) {
            try store.recordMeetingStop(
                handle,
                retained: [retained(handle.microphoneSourceID, sessionID: handle.sessionID)],
                failures: [failed(handle.microphoneSourceID, at: startedAt.addingTimeInterval(2))],
                at: startedAt.addingTimeInterval(3)
            )
        }
        #expect(throws: CaptureSessionStoreError.meetingSourceOutcomeMissing(handle.dualSourceSystemAudioID)) {
            try store.recordMeetingStop(
                handle,
                retained: [retained(handle.microphoneSourceID, sessionID: handle.sessionID)],
                failures: [],
                at: startedAt.addingTimeInterval(3)
            )
        }
        let foreignSourceID = UUID()
        #expect(throws: CaptureSessionStoreError.meetingSourceOutcomeForeign(foreignSourceID)) {
            try store.recordMeetingStop(
                handle,
                retained: [retained(handle.microphoneSourceID, sessionID: handle.sessionID)],
                failures: [failed(foreignSourceID, at: startedAt.addingTimeInterval(2))],
                at: startedAt.addingTimeInterval(3)
            )
        }

        let context = ModelContext(container)
        let sources = try context.fetch(FetchDescriptor<CaptureSourceModel>())
            .filter { $0.sessionID == handle.sessionID }
        let chunks = try context.fetch(FetchDescriptor<CaptureChunkModel>())
            .filter { $0.sessionID == handle.sessionID }
        let failures = try context.fetch(FetchDescriptor<CaptureFailureRecordModel>())
            .filter { $0.sessionID == handle.sessionID }
        #expect(sources.allSatisfy { $0.stateRawValue == CaptureSourceState.capturing.rawValue })
        #expect(chunks.isEmpty)
        #expect(failures.isEmpty)
    }

    @Test func meetingHandleRejectsCrossSessionAndWrongKindSources() throws {
        let container = try makeContainer()
        let store = makeStore(in: container)
        let startedAt = Date(timeIntervalSinceReferenceDate: 8_550)
        let first = try store.startMeetingCapture(startedAt: startedAt)
        let second = try store.startMeetingCapture(startedAt: startedAt)
        let crossSession = NoteCaptureHandle(
            sessionID: first.sessionID,
            microphoneSourceID: first.microphoneSourceID,
            systemAudioSourceID: second.dualSourceSystemAudioID
        )
        let wrongKind = NoteCaptureHandle(
            sessionID: first.sessionID,
            microphoneSourceID: first.dualSourceSystemAudioID,
            systemAudioSourceID: first.dualSourceSystemAudioID
        )

        #expect(
            throws: CaptureSessionStoreError.sourceSessionMismatch(
                sourceID: second.dualSourceSystemAudioID,
                expectedSessionID: first.sessionID,
                actualSessionID: second.sessionID
            )
        ) {
            try store.beginMeetingFinalization(crossSession, at: startedAt.addingTimeInterval(1))
        }
        #expect(
            throws: CaptureSessionStoreError.sourceKindMismatch(
                sourceID: first.dualSourceSystemAudioID,
                expected: .microphone,
                actualRawValue: CaptureSourceKind.systemAudio.rawValue
            )
        ) {
            try store.beginMeetingFinalization(wrongKind, at: startedAt.addingTimeInterval(1))
        }
    }

    @Test func micOnlyNoteCaptureCreatesOnlyAMicrophoneSourceRow() throws {
        let container = try makeContainer()
        let store = makeStore(in: container)
        let startedAt = Date(timeIntervalSinceReferenceDate: 8_560)
        let handle = try store.startNoteCapture(
            startedAt: startedAt,
            includeSystemAudio: false,
            intent: noteIntent(),
            microphoneDisplayName: "Built-in Microphone"
        )

        #expect(handle.systemAudioSourceID == nil)
        #expect(handle.sourceIDs == [handle.microphoneSourceID])

        let context = ModelContext(container)
        let session = try #require(
            context.fetch(FetchDescriptor<CaptureSessionModel>()).first { $0.id == handle.sessionID }
        )
        let sources = try context.fetch(FetchDescriptor<CaptureSourceModel>())
            .filter { $0.sessionID == handle.sessionID }
        #expect(try session.restoreSession().mode == .note)
        #expect(sources.count == 1)
        #expect(sources[0].id == handle.microphoneSourceID)
        #expect(sources[0].sequence == 0)
        #expect(sources[0].kindRawValue == CaptureSourceKind.microphone.rawValue)
    }

    @Test func noteCaptureWithSystemAudioOrdersMicrophoneFirst() throws {
        let container = try makeContainer()
        let store = makeStore(in: container)
        let startedAt = Date(timeIntervalSinceReferenceDate: 8_565)
        let handle = try store.startNoteCapture(
            startedAt: startedAt,
            includeSystemAudio: true,
            intent: noteIntent(),
            microphoneDisplayName: "Built-in Microphone",
            systemAudioDisplayName: "System Audio"
        )

        let context = ModelContext(container)
        let sources = try context.fetch(FetchDescriptor<CaptureSourceModel>())
            .filter { $0.sessionID == handle.sessionID }
            .sorted { $0.sequence < $1.sequence }
        #expect(sources.count == 2)
        #expect(sources[0].id == handle.microphoneSourceID)
        #expect(sources[0].sequence == 0)
        #expect(sources[1].id == handle.dualSourceSystemAudioID)
        #expect(sources[1].sequence == 1)
        #expect(sources[1].kindRawValue == CaptureSourceKind.systemAudio.rawValue)
    }

    @Test func micOnlyNoteCaptureFinishesFinalizesAndCompletesWithOneSource() throws {
        let container = try makeContainer()
        let store = makeStore(in: container)
        let startedAt = Date(timeIntervalSinceReferenceDate: 8_570)
        let handle = try store.startNoteCapture(
            startedAt: startedAt,
            includeSystemAudio: false,
            intent: noteIntent()
        )
        try store.beginMeetingFinalization(handle, at: startedAt.addingTimeInterval(1))
        let checkpoint = chunk(
            handle.microphoneSourceID,
            sessionID: handle.sessionID,
            sequence: 0,
            sealedAt: startedAt.addingTimeInterval(2)
        )
        try store.recordSealedMeetingChunk(handle, checkpoint: checkpoint)

        // A one-source finish is accepted: there is no system-audio row to explain.
        try store.finishMeetingSources(
            handle,
            sourceFailures: [],
            at: startedAt.addingTimeInterval(3)
        )
        _ = try store.recordMeetingTranscriptionChunk(
            handle,
            sourceChunkSequence: 0,
            startOffset: checkpoint.startOffset,
            duration: checkpoint.duration,
            text: "Mic-only note transcript",
            at: startedAt.addingTimeInterval(4)
        )
        let history = try HistoryStore(modelContext: ModelContext(container)).save(
            text: "Mic-only note transcript",
            originalText: "Mic-only note transcript",
            duration: checkpoint.duration,
            modelUsed: "note"
        )
        try store.completeMeetingCapture(
            handle,
            transcriptionRecordID: history.id,
            at: startedAt.addingTimeInterval(5)
        )

        let context = ModelContext(container)
        let session = try #require(
            context.fetch(FetchDescriptor<CaptureSessionModel>()).first { $0.id == handle.sessionID }
        )
        let sources = try context.fetch(FetchDescriptor<CaptureSourceModel>())
            .filter { $0.sessionID == handle.sessionID }
        #expect(try session.restoreSession().state == .completed)
        #expect(session.transcriptionRecordID == history.id)
        #expect(sources.count == 1)
        #expect(sources[0].stateRawValue == CaptureSourceState.completed.rawValue)
    }

    @Test func micOnlyNoteCaptureCancelAndFailTouchOnlyTheMicrophoneSource() throws {
        let container = try makeContainer()
        let store = makeStore(in: container)
        let startedAt = Date(timeIntervalSinceReferenceDate: 8_575)
        let cancelled = try store.startNoteCapture(
            startedAt: startedAt,
            includeSystemAudio: false,
            intent: noteIntent()
        )
        let failedCapture = try store.startNoteCapture(
            startedAt: startedAt,
            includeSystemAudio: false,
            intent: noteIntent()
        )

        try store.cancelMeetingCapture(cancelled, at: startedAt.addingTimeInterval(1))
        try store.failMeetingCapture(
            failedCapture,
            stage: .finalTranscription,
            errorDomain: "AudioCapture",
            errorCode: "unavailable",
            message: "The microphone stopped.",
            at: startedAt.addingTimeInterval(1)
        )

        let context = ModelContext(container)
        let cancelledSources = try context.fetch(FetchDescriptor<CaptureSourceModel>())
            .filter { $0.sessionID == cancelled.sessionID }
        let failedSources = try context.fetch(FetchDescriptor<CaptureSourceModel>())
            .filter { $0.sessionID == failedCapture.sessionID }
        #expect(cancelledSources.map(\.stateRawValue) == [CaptureSourceState.cancelled.rawValue])
        #expect(failedSources.map(\.stateRawValue) == [CaptureSourceState.failed.rawValue])
        #expect(try store.cancelledNoteCaptureSessionIDs() == [cancelled.sessionID])
    }

    @Test func noteCaptureRecoveryCandidatesCoverEveryNoteCaptureMode() throws {
        let container = try makeContainer()
        let store = makeStore(in: container)
        let startedAt = Date(timeIntervalSinceReferenceDate: 8_580)
        let legacyVoiceNote = try store.startVoiceNoteCapture(startedAt: startedAt)
        let legacyMeeting = try store.startMeetingCapture(startedAt: startedAt.addingTimeInterval(1))
        let micOnlyNote = try store.startNoteCapture(
            startedAt: startedAt.addingTimeInterval(2),
            includeSystemAudio: false,
            intent: noteIntent()
        )
        let dualSourceNote = try store.startNoteCapture(
            startedAt: startedAt.addingTimeInterval(3),
            includeSystemAudio: true,
            intent: noteIntent()
        )

        let candidates = try store.noteCaptureRecoveryCandidates()
        let bySessionID = Dictionary(
            uniqueKeysWithValues: candidates.map { ($0.handle.sessionID, $0) }
        )
        #expect(bySessionID[legacyVoiceNote.sessionID]?.mode == .voiceNote)
        #expect(bySessionID[legacyMeeting.sessionID]?.mode == .meeting)
        #expect(bySessionID[micOnlyNote.sessionID]?.mode == .note)
        #expect(bySessionID[dualSourceNote.sessionID]?.mode == .note)
        #expect(bySessionID[legacyVoiceNote.sessionID]?.handle.systemAudioSourceID == nil)
        #expect(bySessionID[micOnlyNote.sessionID]?.handle.systemAudioSourceID == nil)
        #expect(
            bySessionID[dualSourceNote.sessionID]?.handle.systemAudioSourceID
                == dualSourceNote.dualSourceSystemAudioID
        )
        // Newest activity first.
        #expect(candidates.map(\.handle.sessionID) == [
            dualSourceNote.sessionID,
            micOnlyNote.sessionID,
            legacyMeeting.sessionID,
            legacyVoiceNote.sessionID
        ])

        // The durable-spool shim keeps only captures that record system audio.
        #expect(try store.meetingRecoveryCandidates().map(\.handle.sessionID) == [
            dualSourceNote.sessionID,
            legacyMeeting.sessionID
        ])
        // The streaming shim keeps only mic-only captures with committed text.
        #expect(try store.voiceNoteRecoveryCandidates().isEmpty)

        _ = try store.resolveAssignment(
            sessionID: micOnlyNote.sessionID,
            stage: .liveTranscription,
            attempt: 1,
            selecting: { try assignment(stage: .liveTranscription) }
        )
        _ = try store.checkpointVoiceNoteLiveTranscript(
            for: VoiceNoteCaptureHandle(
                sessionID: micOnlyNote.sessionID,
                microphoneSourceID: micOnlyNote.microphoneSourceID
            ),
            committedText: "Committed note text",
            at: startedAt.addingTimeInterval(4)
        )
        #expect(try store.voiceNoteRecoveryCandidates().map(\.handle.sessionID) == [
            micOnlyNote.sessionID
        ])
        #expect(
            try store.noteCaptureRecoveryCandidates()
                .first { $0.handle.sessionID == micOnlyNote.sessionID }?
                .latestLiveCheckpoint?.committedText == "Committed note text"
        )
    }

    @Test func meetingCompletionLinksExistingHistoryOnlyAfterSourceStop() throws {
        let container = try makeContainer()
        let store = makeStore(in: container)
        let startedAt = Date(timeIntervalSinceReferenceDate: 8_600)
        let handle = try store.startMeetingCapture(startedAt: startedAt)
        try store.beginMeetingFinalization(handle, at: startedAt.addingTimeInterval(1))
        try store.recordMeetingStop(
            handle,
            retained: [retained(handle.microphoneSourceID, sessionID: handle.sessionID)],
            failures: [failed(handle.dualSourceSystemAudioID, at: startedAt.addingTimeInterval(2))],
            at: startedAt.addingTimeInterval(3)
        )
        let history = try HistoryStore(modelContext: ModelContext(container)).save(
            text: "Meeting transcript",
            originalText: "Meeting transcript",
            duration: 2,
            modelUsed: "meeting"
        )
        #expect(
            throws: CaptureSessionStoreError.meetingCaptureHasIncompleteFinalTranscript(
                sessionID: handle.sessionID,
                sequences: [0]
            )
        ) {
            try store.completeMeetingCapture(
                handle,
                transcriptionRecordID: history.id,
                at: startedAt.addingTimeInterval(4)
            )
        }
        _ = try store.recordMeetingTranscriptionChunk(
            handle,
            sourceChunkSequence: 0,
            startOffset: 0,
            duration: 2,
            text: "Meeting transcript",
            at: startedAt.addingTimeInterval(3)
        )
        let missingHistoryID = UUID()
        #expect(throws: CaptureSessionStoreError.transcriptionRecordNotFound(missingHistoryID)) {
            try store.completeMeetingCapture(
                handle,
                transcriptionRecordID: missingHistoryID,
                at: startedAt.addingTimeInterval(4)
            )
        }
        try store.completeMeetingCapture(
            handle,
            transcriptionRecordID: history.id,
            at: startedAt.addingTimeInterval(5)
        )

        let context = ModelContext(container)
        let session = try #require(
            context.fetch(FetchDescriptor<CaptureSessionModel>()).first { $0.id == handle.sessionID }
        )
        #expect(try session.restoreSession().state == .completed)
        #expect(session.transcriptionRecordID == history.id)
    }
    @Test func meetingCompletionRejectsMissingDurableChunkCheckpointWithoutMutation() throws {
        let container = try makeContainer()
        let store = makeStore(in: container)
        let startedAt = Date(timeIntervalSinceReferenceDate: 8_650)
        let handle = try store.startMeetingCapture(startedAt: startedAt)
        try store.beginMeetingFinalization(handle, at: startedAt.addingTimeInterval(1))
        let checkpoints = (0...1).map {
            chunk(
                handle.microphoneSourceID,
                sessionID: handle.sessionID,
                sequence: $0,
                sealedAt: startedAt.addingTimeInterval(Double($0 + 2))
            )
        }
        try store.reconcileMeetingChunks(handle, checkpoints: checkpoints, failures: [])
        try store.finishMeetingSources(
            handle,
            sourceFailures: [failed(handle.dualSourceSystemAudioID, at: startedAt.addingTimeInterval(4))],
            at: startedAt.addingTimeInterval(5)
        )
        _ = try store.recordMeetingTranscriptionChunk(
            handle,
            sourceChunkSequence: 0,
            startOffset: checkpoints[0].startOffset,
            duration: checkpoints[0].duration,
            text: "Opening chunk",
            at: startedAt.addingTimeInterval(6)
        )
        let history = try HistoryStore(modelContext: ModelContext(container)).save(
            text: "Opening chunk",
            originalText: "Opening chunk",
            duration: checkpoints[0].duration,
            modelUsed: "meeting"
        )

        #expect(
            throws: CaptureSessionStoreError.meetingCaptureHasIncompleteFinalTranscript(
                sessionID: handle.sessionID,
                sequences: [1]
            )
        ) {
            try store.completeMeetingCapture(
                handle,
                transcriptionRecordID: history.id,
                at: startedAt.addingTimeInterval(7)
            )
        }

        let context = ModelContext(container)
        let session = try #require(
            context.fetch(FetchDescriptor<CaptureSessionModel>()).first { $0.id == handle.sessionID }
        )
        #expect(try session.restoreSession().state == .finalizing)
        #expect(session.transcriptionRecordID == nil)
    }

    @Test func meetingStopRejectsSwappedArtifactPathsWithoutMutation() throws {
        let container = try makeContainer()
        let store = makeStore(in: container)
        let startedAt = Date(timeIntervalSinceReferenceDate: 8_700)
        let handle = try store.startMeetingCapture(startedAt: startedAt)
        try store.beginMeetingFinalization(handle, at: startedAt.addingTimeInterval(1))

        #expect(throws: CaptureSessionStoreError.invalidRetainedMeetingSource(handle.microphoneSourceID)) {
            try store.recordMeetingStop(
                handle,
                retained: [
                    retained(
                        handle.microphoneSourceID,
                        sessionID: handle.sessionID,
                        path: CaptureSourceArtifactPath.relativePath(
                            sessionID: handle.sessionID,
                            sourceID: handle.dualSourceSystemAudioID,
                            chunkSequence: 0
                        )
                    )
                ],
                failures: [failed(handle.dualSourceSystemAudioID, at: startedAt.addingTimeInterval(2))],
                at: startedAt.addingTimeInterval(3)
            )
        }

        let context = ModelContext(container)
        let session = try #require(
            context.fetch(FetchDescriptor<CaptureSessionModel>()).first { $0.id == handle.sessionID }
        )
        let sources = try context.fetch(FetchDescriptor<CaptureSourceModel>())
            .filter { $0.sessionID == handle.sessionID }
        let chunks = try context.fetch(FetchDescriptor<CaptureChunkModel>())
            .filter { $0.sessionID == handle.sessionID }
        let failures = try context.fetch(FetchDescriptor<CaptureFailureRecordModel>())
            .filter { $0.sessionID == handle.sessionID }
        #expect(try session.restoreSession().state == .finalizing)
        #expect(sources.allSatisfy { $0.stateRawValue == CaptureSourceState.capturing.rawValue })
        #expect(chunks.isEmpty)
        #expect(failures.isEmpty)
    }

    @Test func meetingCompletionRejectsEarlyCompletionWithoutMutation() throws {
        let container = try makeContainer()
        let store = makeStore(in: container)
        let startedAt = Date(timeIntervalSinceReferenceDate: 8_800)
        let handle = try store.startMeetingCapture(startedAt: startedAt)
        try store.beginMeetingFinalization(handle, at: startedAt.addingTimeInterval(1))
        let history = try HistoryStore(modelContext: ModelContext(container)).save(
            text: "Meeting transcript",
            originalText: "Meeting transcript",
            duration: 2,
            modelUsed: "meeting"
        )

        #expect(throws: CaptureSessionStoreError.meetingSourceNotTerminal(handle.microphoneSourceID)) {
            try store.completeMeetingCapture(
                handle,
                transcriptionRecordID: history.id,
                at: startedAt.addingTimeInterval(2)
            )
        }

        let context = ModelContext(container)
        let session = try #require(
            context.fetch(FetchDescriptor<CaptureSessionModel>()).first { $0.id == handle.sessionID }
        )
        let sources = try context.fetch(FetchDescriptor<CaptureSourceModel>())
            .filter { $0.sessionID == handle.sessionID }
        let chunks = try context.fetch(FetchDescriptor<CaptureChunkModel>())
            .filter { $0.sessionID == handle.sessionID }
        let failures = try context.fetch(FetchDescriptor<CaptureFailureRecordModel>())
            .filter { $0.sessionID == handle.sessionID }
        #expect(try session.restoreSession().state == .finalizing)
        #expect(session.transcriptionRecordID == nil)
        #expect(sources.allSatisfy { $0.stateRawValue == CaptureSourceState.capturing.rawValue })
        #expect(chunks.isEmpty)
        #expect(failures.isEmpty)
    }

    @Test func meetingCompletionRejectsDuplicateChunksWithoutMutation() throws {
        let container = try makeContainer()
        let store = makeStore(in: container)
        let startedAt = Date(timeIntervalSinceReferenceDate: 8_900)
        let handle = try store.startMeetingCapture(startedAt: startedAt)
        try store.beginMeetingFinalization(handle, at: startedAt.addingTimeInterval(1))
        try store.recordMeetingStop(
            handle,
            retained: [retained(handle.microphoneSourceID, sessionID: handle.sessionID)],
            failures: [failed(handle.dualSourceSystemAudioID, at: startedAt.addingTimeInterval(2))],
            at: startedAt.addingTimeInterval(3)
        )

        let collisionContext = ModelContext(container)
        collisionContext.insert(CaptureChunkModel(
            sessionID: handle.sessionID,
            sourceID: handle.microphoneSourceID,
            sequence: 0,
            startOffset: 0,
            duration: 2,
            stateRawValue: CaptureChunkState.sealed.rawValue,
            managedMediaPath: CaptureSourceArtifactPath.relativePath(
                sessionID: handle.sessionID,
                sourceID: handle.microphoneSourceID,
                chunkSequence: 0
            ),
            byteCount: 64_000,
            sha256: String(repeating: "a", count: 64),
            createdAt: startedAt.addingTimeInterval(4),
            sealedAt: startedAt.addingTimeInterval(4)
        ))
        try collisionContext.save()
        let history = try HistoryStore(modelContext: ModelContext(container)).save(
            text: "Meeting transcript",
            originalText: "Meeting transcript",
            duration: 2,
            modelUsed: "meeting"
        )

        #expect(throws: CaptureSessionStoreError.meetingSourceOutcomeMismatch(handle.microphoneSourceID)) {
            try store.completeMeetingCapture(
                handle,
                transcriptionRecordID: history.id,
                at: startedAt.addingTimeInterval(5)
            )
        }

        let context = ModelContext(container)
        let session = try #require(
            context.fetch(FetchDescriptor<CaptureSessionModel>()).first { $0.id == handle.sessionID }
        )
        let sources = try context.fetch(FetchDescriptor<CaptureSourceModel>())
            .filter { $0.sessionID == handle.sessionID }
        let chunks = try context.fetch(FetchDescriptor<CaptureChunkModel>())
            .filter { $0.sessionID == handle.sessionID }
        let failures = try context.fetch(FetchDescriptor<CaptureFailureRecordModel>())
            .filter { $0.sessionID == handle.sessionID }
        #expect(try session.restoreSession().state == .finalizing)
        #expect(session.transcriptionRecordID == nil)
        #expect(
            Dictionary(uniqueKeysWithValues: sources.map { ($0.id, $0.stateRawValue) }) ==
                [
                    handle.microphoneSourceID: CaptureSourceState.completed.rawValue,
                    handle.dualSourceSystemAudioID: CaptureSourceState.failed.rawValue
                ]
        )
        #expect(chunks.count == 2)
        #expect(failures.count == 1)
    }

    @Test func meetingCompletionRejectsMismatchedSourceFailureWithoutMutation() throws {
        let container = try makeContainer()
        let store = makeStore(in: container)
        let startedAt = Date(timeIntervalSinceReferenceDate: 9_000)
        let handle = try store.startMeetingCapture(startedAt: startedAt)
        try store.beginMeetingFinalization(handle, at: startedAt.addingTimeInterval(1))
        try store.recordMeetingStop(
            handle,
            retained: [retained(handle.microphoneSourceID, sessionID: handle.sessionID)],
            failures: [failed(handle.dualSourceSystemAudioID, at: startedAt.addingTimeInterval(2))],
            at: startedAt.addingTimeInterval(3)
        )

        let mismatchContext = ModelContext(container)
        mismatchContext.insert(CaptureFailureRecordModel(
            sessionID: handle.sessionID,
            sourceID: handle.microphoneSourceID,
            errorDomain: "AudioCapture",
            errorCode: "lateFailure",
            message: "A completed source cannot also fail.",
            isRetryable: false,
            occurredAt: startedAt.addingTimeInterval(4),
            recoveryDisposition: .terminal
        ))
        try mismatchContext.save()
        let history = try HistoryStore(modelContext: ModelContext(container)).save(
            text: "Meeting transcript",
            originalText: "Meeting transcript",
            duration: 2,
            modelUsed: "meeting"
        )

        #expect(throws: CaptureSessionStoreError.meetingSourceOutcomeMismatch(handle.microphoneSourceID)) {
            try store.completeMeetingCapture(
                handle,
                transcriptionRecordID: history.id,
                at: startedAt.addingTimeInterval(5)
            )
        }

        let context = ModelContext(container)
        let session = try #require(
            context.fetch(FetchDescriptor<CaptureSessionModel>()).first { $0.id == handle.sessionID }
        )
        let chunks = try context.fetch(FetchDescriptor<CaptureChunkModel>())
            .filter { $0.sessionID == handle.sessionID }
        let failures = try context.fetch(FetchDescriptor<CaptureFailureRecordModel>())
            .filter { $0.sessionID == handle.sessionID }
        #expect(try session.restoreSession().state == .finalizing)
        #expect(session.transcriptionRecordID == nil)
        #expect(chunks.count == 1)
        #expect(failures.count == 2)
    }
    @Test func reconcilesNinetyMinuteChunksAndCompletesOneRetainedSource() throws {
        let container = try makeContainer()
        let store = makeStore(in: container)
        let startedAt = Date(timeIntervalSinceReferenceDate: 10_000)
        let handle = try store.startMeetingCapture(startedAt: startedAt)
        try store.beginMeetingFinalization(handle, at: startedAt.addingTimeInterval(1))
        let microphoneChunks = (0..<18).map {
            chunk(
                handle.microphoneSourceID,
                sessionID: handle.sessionID,
                sequence: $0,
                sealedAt: startedAt.addingTimeInterval(Double($0 + 1))
            )
        }

        try store.reconcileMeetingChunks(
            handle,
            checkpoints: microphoneChunks,
            failures: [],
            at: startedAt.addingTimeInterval(20)
        )
        try store.finishMeetingSources(
            handle,
            sourceFailures: [
                failed(handle.dualSourceSystemAudioID, at: startedAt.addingTimeInterval(21))
            ],
            at: startedAt.addingTimeInterval(22)
        )
        for checkpoint in microphoneChunks {
            _ = try store.recordMeetingTranscriptionChunk(
                handle,
                sourceChunkSequence: checkpoint.sequence,
                startOffset: checkpoint.startOffset,
                duration: checkpoint.duration,
                text: "Ninety-minute chunk \(checkpoint.sequence)",
                at: startedAt.addingTimeInterval(23)
            )
        }
        let plan = try store.makeMeetingFinalizationPlan(handle)
        #expect(plan.sourceChunks.count == 18)
        #expect(plan.sourceChunks.map(\.sequence) == Array(0..<18))
        #expect(plan.completedASRSequences == Set(0..<18))

        let history = try HistoryStore(modelContext: ModelContext(container)).save(
            text: "Complete ninety-minute transcript",
            originalText: "Complete ninety-minute transcript",
            duration: 5_400,
            modelUsed: "meeting"
        )
        try store.completeMeetingCapture(
            handle,
            transcriptionRecordID: history.id,
            at: startedAt.addingTimeInterval(24)
        )
        let context = ModelContext(container)
        let session = try #require(
            context.fetch(FetchDescriptor<CaptureSessionModel>()).first { $0.id == handle.sessionID }
        )
        #expect(try session.restoreSession().state == .completed)
    }

    @Test func successfulAndExactReplayFinalASRCheckpointsRecoverOnlyMatchingRetryableFailures() throws {
        let container = try makeContainer()
        let store = makeStore(in: container)
        let startedAt = Date(timeIntervalSinceReferenceDate: 10_100)
        let handle = try store.startMeetingCapture(startedAt: startedAt)
        try store.beginMeetingFinalization(handle, at: startedAt.addingTimeInterval(1))
        let checkpoint = chunk(
            handle.microphoneSourceID,
            sessionID: handle.sessionID,
            sequence: 0,
            sealedAt: startedAt.addingTimeInterval(2)
        )
        try store.recordSealedMeetingChunk(handle, checkpoint: checkpoint)
        let initialFailureAt = startedAt.addingTimeInterval(3)
        try store.recordMeetingFinalizationFailure(
            handle,
            sequence: 0,
            stage: .finalTranscription,
            domain: "ASR",
            code: "transient",
            message: "The first attempt timed out.",
            retryable: true,
            at: initialFailureAt
        )
        try store.recordMeetingFinalizationFailure(
            handle,
            sequence: 1,
            stage: .finalTranscription,
            domain: "ASR",
            code: "transient",
            message: "Another chunk timed out.",
            retryable: true,
            at: startedAt.addingTimeInterval(4)
        )
        try store.recordMeetingFinalizationFailure(
            handle,
            sequence: 0,
            stage: .finalTranscription,
            domain: "ASR",
            code: "permanent",
            message: "A nonretryable failure remains unresolved.",
            retryable: false,
            at: startedAt.addingTimeInterval(5)
        )

        let firstSuccessAt = startedAt.addingTimeInterval(6)
        let revisionID = try store.recordMeetingTranscriptionChunk(
            handle,
            sourceChunkSequence: checkpoint.sequence,
            startOffset: checkpoint.startOffset,
            duration: checkpoint.duration,
            text: "Recovered transcript",
            at: firstSuccessAt
        )
        let replayFailureAt = startedAt.addingTimeInterval(7)
        try store.recordMeetingFinalizationFailure(
            handle,
            sequence: 0,
            stage: .finalTranscription,
            domain: "ASR",
            code: "replay",
            message: "A retry was interrupted after its checkpoint.",
            retryable: true,
            at: replayFailureAt
        )
        let exactReplayAt = startedAt.addingTimeInterval(8)
        #expect(
            try store.recordMeetingTranscriptionChunk(
                handle,
                sourceChunkSequence: checkpoint.sequence,
                startOffset: checkpoint.startOffset,
                duration: checkpoint.duration,
                text: "Recovered transcript",
                at: exactReplayAt
            ) == revisionID
        )

        let context = ModelContext(container)
        let failures = try context.fetch(FetchDescriptor<CaptureFailureRecordModel>())
            .filter { $0.sessionID == handle.sessionID }
        let recoveredInitialFailure = try #require(
            failures.first { $0.occurredAt == initialFailureAt }
        )
        let unmatchedRetryableFailure = try #require(
            failures.first { $0.occurredAt == startedAt.addingTimeInterval(4) }
        )
        let nonretryableFailure = try #require(
            failures.first { $0.occurredAt == startedAt.addingTimeInterval(5) }
        )
        let recoveredReplayFailure = try #require(
            failures.first { $0.occurredAt == replayFailureAt }
        )
        #expect(recoveredInitialFailure.recoveredAt == firstSuccessAt)
        #expect(unmatchedRetryableFailure.recoveredAt == nil)
        #expect(nonretryableFailure.recoveredAt == nil)
        #expect(recoveredReplayFailure.recoveredAt == exactReplayAt)
    }

    @Test func reconciliationIsIdempotentAndRejectsConflictingRenameCheckpoint() throws {
        let container = try makeContainer()
        let store = makeStore(in: container)
        let startedAt = Date(timeIntervalSinceReferenceDate: 11_000)
        let handle = try store.startMeetingCapture(startedAt: startedAt)
        let checkpoint = chunk(
            handle.microphoneSourceID,
            sessionID: handle.sessionID,
            sequence: 0,
            sealedAt: startedAt.addingTimeInterval(1)
        )

        let renamedChunk = SealedAudioSourceChunk(
            sessionID: handle.sessionID,
            sourceID: checkpoint.sourceID,
            sequence: checkpoint.sequence,
            startOffset: checkpoint.startOffset,
            duration: checkpoint.duration,
            fileURL: URL(fileURLWithPath: "/recovered/chunk-00000.pcm"),
            relativePath: checkpoint.managedMediaPath,
            byteCount: Int64(checkpoint.byteCount),
            sha256: checkpoint.sha256
        )
        try store.reconcileMeetingInventory(handle, sealedChunks: [renamedChunk])
        try store.reconcileMeetingInventory(handle, sealedChunks: [renamedChunk])
        let conflicting = MeetingChunkCheckpoint(
            sourceID: checkpoint.sourceID,
            sequence: checkpoint.sequence,
            startOffset: checkpoint.startOffset,
            duration: checkpoint.duration,
            managedMediaPath: checkpoint.managedMediaPath,
            byteCount: checkpoint.byteCount,
            sha256: String(repeating: "f", count: 64),
            sealedAt: checkpoint.sealedAt
        )
        #expect(
            throws: CaptureSessionStoreError.meetingChunkConflict(
                sourceID: handle.microphoneSourceID,
                sequence: 0
            )
        ) {
            try store.reconcileMeetingChunks(handle, checkpoints: [conflicting], failures: [])
        }

        let context = ModelContext(container)
        let chunks = try context.fetch(FetchDescriptor<CaptureChunkModel>())
            .filter { $0.sessionID == handle.sessionID }
        #expect(chunks.count == 1)
        #expect(chunks[0].sha256 == checkpoint.sha256)
    }

    @Test func authoritativeInventoryRemovesLostSourceRowsAndIsIdempotent() throws {
        let container = try makeContainer()
        let store = makeStore(in: container)
        let startedAt = Date(timeIntervalSinceReferenceDate: 11_100)
        let handle = try store.startMeetingCapture(startedAt: startedAt)
        let microphone = chunk(
            handle.microphoneSourceID,
            sessionID: handle.sessionID,
            sequence: 0,
            sealedAt: startedAt.addingTimeInterval(1)
        )
        let systemAudio = chunk(
            handle.dualSourceSystemAudioID,
            sessionID: handle.sessionID,
            sequence: 0,
            sealedAt: startedAt.addingTimeInterval(1)
        )
        let lostSource = recoveryFailure(
            handle.dualSourceSystemAudioID,
            invalidatesSource: true,
            at: startedAt.addingTimeInterval(2),
            message: "The system-audio artifact is missing."
        )

        try store.reconcileMeetingChunks(handle, checkpoints: [microphone, systemAudio], failures: [])
        try store.reconcileMeetingInventory(
            handle,
            sealedChunks: [sealed(microphone, sessionID: handle.sessionID)],
            failures: [lostSource],
            at: startedAt.addingTimeInterval(3)
        )
        try store.reconcileMeetingInventory(
            handle,
            sealedChunks: [sealed(microphone, sessionID: handle.sessionID)],
            failures: [lostSource],
            at: startedAt.addingTimeInterval(3)
        )

        let context = ModelContext(container)
        let chunks = try context.fetch(FetchDescriptor<CaptureChunkModel>())
            .filter { $0.sessionID == handle.sessionID }
        let failures = try context.fetch(FetchDescriptor<CaptureFailureRecordModel>())
            .filter { $0.sessionID == handle.sessionID }
        #expect(chunks.count == 1)
        #expect(chunks[0].sourceID == handle.microphoneSourceID)
        #expect(chunks[0].sequence == 0)
        #expect(failures.count == 1)
        #expect(failures[0].sourceID == handle.dualSourceSystemAudioID)
        #expect(failures[0].chunkID == nil)
    }

    @Test func corruptMiddleChunkRemainsRecoverableThroughFinalization() throws {
        let container = try makeContainer()
        let store = makeStore(in: container)
        let startedAt = Date(timeIntervalSinceReferenceDate: 11_200)
        let handle = try store.startMeetingCapture(startedAt: startedAt)
        try store.beginMeetingFinalization(handle, at: startedAt.addingTimeInterval(0.5))
        let microphoneChunks = (0...2).map {
            chunk(
                handle.microphoneSourceID,
                sessionID: handle.sessionID,
                sequence: $0,
                sealedAt: startedAt.addingTimeInterval(Double($0 + 1))
            )
        }
        let systemAudio = chunk(
            handle.dualSourceSystemAudioID,
            sessionID: handle.sessionID,
            sequence: 0,
            sealedAt: startedAt.addingTimeInterval(1)
        )
        let corruptMiddle = recoveryFailure(
            handle.microphoneSourceID,
            sequence: 1,
            at: startedAt.addingTimeInterval(4),
            message: "The canonical middle chunk failed its hash check."
        )

        try store.reconcileMeetingChunks(
            handle,
            checkpoints: microphoneChunks + [systemAudio],
            failures: []
        )
        try store.reconcileMeetingInventory(
            handle,
            sealedChunks: [
                sealed(microphoneChunks[0], sessionID: handle.sessionID),
                sealed(microphoneChunks[2], sessionID: handle.sessionID),
                sealed(systemAudio, sessionID: handle.sessionID)
            ],
            failures: [corruptMiddle],
            at: startedAt.addingTimeInterval(5)
        )
        try store.finishMeetingSources(
            handle,
            sourceFailures: [],
            at: startedAt.addingTimeInterval(6)
        )

        let plan = try store.makeMeetingFinalizationPlan(handle)
        #expect(
            Set(plan.sourceChunks.map { "\($0.sourceID.uuidString):\($0.sequence)" }) ==
                [
                    "\(handle.microphoneSourceID.uuidString):0",
                    "\(handle.microphoneSourceID.uuidString):2",
                    "\(handle.dualSourceSystemAudioID.uuidString):0"
                ]
        )
        #expect(plan.failedSequences == [1])
        _ = try store.recordMeetingTranscriptionChunk(
            handle,
            sourceChunkSequence: 0,
            startOffset: 0,
            duration: 300,
            text: "Opening chunk",
            at: startedAt.addingTimeInterval(7)
        )
        _ = try store.recordMeetingTranscriptionChunk(
            handle,
            sourceChunkSequence: 2,
            startOffset: 600,
            duration: 300,
            text: "Closing chunk",
            at: startedAt.addingTimeInterval(8)
        )
        let history = try HistoryStore(modelContext: ModelContext(container)).save(
            text: "Opening chunk Closing chunk",
            originalText: "Opening chunk Closing chunk",
            duration: 900,
            modelUsed: "meeting"
        )
        try store.completeMeetingCapture(
            handle,
            transcriptionRecordID: history.id,
            at: startedAt.addingTimeInterval(9)
        )

        let context = ModelContext(container)
        let sources = try context.fetch(FetchDescriptor<CaptureSourceModel>())
            .filter { $0.sessionID == handle.sessionID }
        let failures = try context.fetch(FetchDescriptor<CaptureFailureRecordModel>())
            .filter { $0.sessionID == handle.sessionID }
        #expect(
            sources.allSatisfy { $0.stateRawValue == CaptureSourceState.completed.rawValue }
        )
        #expect(failures.count == 1)
        #expect(failures[0].sourceID == handle.microphoneSourceID)
        #expect(failures[0].chunkID == nil)
        #expect(failures[0].detailsJSON == "{\"sequence\":1}")
    }

    @Test func finishMeetingSourcesRejectsUnexplainedChunkGap() throws {
        let container = try makeContainer()
        let store = makeStore(in: container)
        let startedAt = Date(timeIntervalSinceReferenceDate: 11_250)
        let handle = try store.startMeetingCapture(startedAt: startedAt)
        try store.beginMeetingFinalization(handle, at: startedAt.addingTimeInterval(0.5))
        let microphoneChunks = (0...2).map {
            chunk(
                handle.microphoneSourceID,
                sessionID: handle.sessionID,
                sequence: $0,
                sealedAt: startedAt.addingTimeInterval(Double($0 + 1))
            )
        }
        let systemAudio = chunk(
            handle.dualSourceSystemAudioID,
            sessionID: handle.sessionID,
            sequence: 0,
            sealedAt: startedAt.addingTimeInterval(1)
        )

        try store.reconcileMeetingChunks(
            handle,
            checkpoints: microphoneChunks + [systemAudio],
            failures: []
        )
        try store.reconcileMeetingInventory(
            handle,
            sealedChunks: [
                sealed(microphoneChunks[0], sessionID: handle.sessionID),
                sealed(microphoneChunks[2], sessionID: handle.sessionID),
                sealed(systemAudio, sessionID: handle.sessionID)
            ],
            at: startedAt.addingTimeInterval(5)
        )

        #expect(throws: CaptureSessionStoreError.meetingSourceOutcomeMismatch(handle.microphoneSourceID)) {
            try store.finishMeetingSources(
                handle,
                sourceFailures: [],
                at: startedAt.addingTimeInterval(6)
            )
        }
    }

    @Test func finishMeetingSourcesPrioritizesVerifiedSourceFailureOverStaleChunks() throws {
        let container = try makeContainer()
        let store = makeStore(in: container)
        let startedAt = Date(timeIntervalSinceReferenceDate: 11_300)
        let handle = try store.startMeetingCapture(startedAt: startedAt)
        try store.beginMeetingFinalization(handle, at: startedAt.addingTimeInterval(1))
        let microphone = chunk(
            handle.microphoneSourceID,
            sessionID: handle.sessionID,
            sequence: 0,
            sealedAt: startedAt.addingTimeInterval(2)
        )
        let systemAudio = chunk(
            handle.dualSourceSystemAudioID,
            sessionID: handle.sessionID,
            sequence: 0,
            sealedAt: startedAt.addingTimeInterval(2)
        )
        try store.reconcileMeetingChunks(handle, checkpoints: [microphone, systemAudio], failures: [])

        try store.finishMeetingSources(
            handle,
            sourceFailures: [
                failed(handle.dualSourceSystemAudioID, at: startedAt.addingTimeInterval(3))
            ],
            at: startedAt.addingTimeInterval(4)
        )

        let context = ModelContext(container)
        let chunks = try context.fetch(FetchDescriptor<CaptureChunkModel>())
            .filter { $0.sessionID == handle.sessionID }
        let sources = try context.fetch(FetchDescriptor<CaptureSourceModel>())
            .filter { $0.sessionID == handle.sessionID }
        #expect(chunks.count == 1)
        #expect(chunks[0].sourceID == handle.microphoneSourceID)
        #expect(
            sources.first { $0.id == handle.dualSourceSystemAudioID }?.stateRawValue ==
                CaptureSourceState.failed.rawValue
        )
        #expect(
            sources.first { $0.id == handle.microphoneSourceID }?.stateRawValue ==
                CaptureSourceState.completed.rawValue
        )
    }

    @Test func firstMeetingRevisionRejectsMismatchedMixedWindowWithoutPersisting() throws {
        let container = try makeContainer()
        let store = makeStore(in: container)
        let startedAt = Date(timeIntervalSinceReferenceDate: 11_400)
        let handle = try store.startMeetingCapture(startedAt: startedAt)
        let microphoneByteCount = MeetingCaptureSpoolPlan.defaultChunkByteCount -
            MeetingCaptureSpoolPlan.sampleRate * MeetingCaptureSpoolPlan.bytesPerSample
        let microphone = MeetingChunkCheckpoint(
            sourceID: handle.microphoneSourceID,
            sequence: 0,
            startOffset: 0,
            duration: Double(microphoneByteCount) /
                Double(MeetingCaptureSpoolPlan.sampleRate * MeetingCaptureSpoolPlan.bytesPerSample),
            managedMediaPath: CaptureSourceArtifactPath.relativePath(
                sessionID: handle.sessionID,
                sourceID: handle.microphoneSourceID,
                chunkSequence: 0
            ),
            byteCount: microphoneByteCount,
            sha256: String(repeating: "a", count: 64),
            sealedAt: startedAt.addingTimeInterval(1)
        )
        let systemAudio = chunk(
            handle.dualSourceSystemAudioID,
            sessionID: handle.sessionID,
            sequence: 0,
            sealedAt: startedAt.addingTimeInterval(1)
        )
        try store.reconcileMeetingChunks(handle, checkpoints: [microphone, systemAudio], failures: [])

        #expect(throws: CaptureSessionStoreError.meetingTranscriptionRevisionConflict(
            sequence: 0,
            stage: .finalTranscription
        )) {
            _ = try store.recordMeetingTranscriptionChunk(
                handle,
                sourceChunkSequence: 0,
                startOffset: 2.0 / Double(MeetingCaptureSpoolPlan.sampleRate),
                duration: microphone.duration,
                text: "Misaligned"
            )
        }

        let context = ModelContext(container)
        let revisions = try context.fetch(FetchDescriptor<CaptureTranscriptRevisionModel>())
            .filter { $0.sessionID == handle.sessionID }
        #expect(revisions.isEmpty)

        let revisionID = try store.recordMeetingTranscriptionChunk(
            handle,
            sourceChunkSequence: 0,
            startOffset: 0,
            duration: systemAudio.duration,
            text: "Aligned"
        )
        let revision = try #require(
            context.fetch(FetchDescriptor<CaptureTranscriptRevisionModel>()).first { $0.id == revisionID }
        )
        #expect(revision.startOffset == 0)
        #expect(revision.duration == systemAudio.duration)
    }

    @Test func interruptionRecoveryAndReservationPreserveFinalizationSkipGates() throws {
        let container = try makeContainer()
        let store = makeStore(in: container)
        let startedAt = Date(timeIntervalSinceReferenceDate: 12_000)
        let handle = try store.startMeetingCapture(startedAt: startedAt)
        let checkpoint = chunk(
            handle.microphoneSourceID,
            sessionID: handle.sessionID,
            sequence: 0,
            sealedAt: startedAt.addingTimeInterval(1)
        )
        try store.recordSealedMeetingChunk(handle, checkpoint: checkpoint)
        try store.interruptMeetingCapture(
            handle,
            errorDomain: "Cancellation",
            message: "The process was interrupted.",
            at: startedAt.addingTimeInterval(2)
        )
        let interrupted = try #require(
            store.meetingRecoveryCandidates().first { $0.handle.sessionID == handle.sessionID }
        )
        #expect(interrupted.state == .interrupted)
        #expect(interrupted.recoveryTarget == .capturing)

        try store.recoverMeetingForFinalization(handle, at: startedAt.addingTimeInterval(3))
        try store.recordMeetingHistoryFailure(
            handle,
            errorDomain: "HistoryStore",
            message: "History persistence is temporarily unavailable.",
            at: startedAt.addingTimeInterval(3)
        )
        let recoveryContext = ModelContext(container)
        let recoveringSession = try #require(
            recoveryContext.fetch(FetchDescriptor<CaptureSessionModel>()).first {
                $0.id == handle.sessionID
            }
        )
        #expect(try recoveringSession.restoreSession().state == .finalizing)
        let historyFailure = try #require(
            recoveryContext.fetch(FetchDescriptor<CaptureFailureRecordModel>()).first {
                $0.sessionID == handle.sessionID && $0.sourceID == nil
            }
        )
        #expect(historyFailure.isRetryable)
        let reservation = try store.reserveMeetingTranscriptionRecordID(handle)
        #expect(try store.reserveMeetingTranscriptionRecordID(handle) == reservation)
        _ = try store.recordMeetingTranscriptionChunk(
            handle,
            sourceChunkSequence: 0,
            startOffset: 0,
            duration: 300,
            text: "Recovered final transcript",
            at: startedAt.addingTimeInterval(4)
        )
        let plan = try store.makeMeetingFinalizationPlan(handle)
        #expect(plan.completedASRSequences == [0])
        #expect(plan.reservedTranscriptionRecordID == reservation)
    }

    @Test func chunkAndRevisionCheckpointsRejectCorruptionAndConflictsBeforeMutation() throws {
        let container = try makeContainer()
        let store = makeStore(in: container)
        let startedAt = Date(timeIntervalSinceReferenceDate: 13_000)
        let handle = try store.startMeetingCapture(startedAt: startedAt)
        let valid = chunk(
            handle.microphoneSourceID,
            sessionID: handle.sessionID,
            sequence: 0,
            sealedAt: startedAt.addingTimeInterval(1)
        )
        let corrupt = MeetingChunkCheckpoint(
            sourceID: valid.sourceID,
            sequence: 1,
            startOffset: valid.duration,
            duration: valid.duration,
            managedMediaPath: CaptureSourceArtifactPath.relativePath(
                sessionID: handle.sessionID,
                sourceID: valid.sourceID,
                chunkSequence: 1
            ),
            byteCount: 3,
            sha256: valid.sha256,
            sealedAt: valid.sealedAt
        )
        #expect(throws: CaptureSessionStoreError.invalidMeetingChunk(
            sourceID: handle.microphoneSourceID,
            sequence: 1
        )) {
            try store.reconcileMeetingChunks(handle, checkpoints: [corrupt], failures: [])
        }
        try store.reconcileMeetingChunks(handle, checkpoints: [valid], failures: [])
        _ = try store.recordMeetingTranscriptionChunk(
            handle,
            sourceChunkSequence: 0,
            startOffset: 0,
            duration: 300,
            text: "Original"
        )
        #expect(throws: CaptureSessionStoreError.meetingTranscriptionRevisionConflict(
            sequence: 0,
            stage: .finalTranscription
        )) {
            _ = try store.recordMeetingTranscriptionChunk(
                handle,
                sourceChunkSequence: 0,
                startOffset: 0,
                duration: 300,
                text: "Changed"
            )
        }
    }

    @Test func meetingRecoveryCarriesSortedMergeReadyFinalASROutputs() throws {
        let container = try makeContainer()
        let store = makeStore(in: container)
        let startedAt = Date(timeIntervalSinceReferenceDate: 14_000)
        let handle = try store.startMeetingCapture(startedAt: startedAt)
        let first = chunk(
            handle.microphoneSourceID,
            sessionID: handle.sessionID,
            sequence: 0,
            sealedAt: startedAt.addingTimeInterval(1)
        )
        let second = chunk(
            handle.microphoneSourceID,
            sessionID: handle.sessionID,
            sequence: 1,
            sealedAt: startedAt.addingTimeInterval(2)
        )
        try store.reconcileMeetingChunks(handle, checkpoints: [first, second], failures: [])

        let secondRevisionID = try store.recordMeetingTranscriptionChunk(
            handle,
            sourceChunkSequence: 1,
            startOffset: second.startOffset,
            duration: second.duration,
            text: "Second completed chunk",
            segmentsJSON: #"[{"speaker":"speaker-2","start":0,"end":300,"text":"Second completed chunk"}]"#,
            languageCode: "fr-CA"
        )
        let firstRevisionID = try store.recordMeetingTranscriptionChunk(
            handle,
            sourceChunkSequence: 0,
            startOffset: first.startOffset,
            duration: first.duration,
            text: "First completed chunk",
            segmentsJSON: #"[{"speaker":"speaker-1","start":0,"end":300,"text":"First completed chunk"}]"#,
            languageCode: "en-US"
        )

        let expected = [
            MeetingTranscriptionCheckpoint(
                revisionID: firstRevisionID,
                providerSnapshotID: nil,
                sequence: 0,
                startOffset: first.startOffset,
                duration: first.duration,
                text: "First completed chunk",
                segmentsJSON: #"[{"speaker":"speaker-1","start":0,"end":300,"text":"First completed chunk"}]"#,
                languageCode: "en-US"
            ),
            MeetingTranscriptionCheckpoint(
                revisionID: secondRevisionID,
                providerSnapshotID: nil,
                sequence: 1,
                startOffset: second.startOffset,
                duration: second.duration,
                text: "Second completed chunk",
                segmentsJSON: #"[{"speaker":"speaker-2","start":0,"end":300,"text":"Second completed chunk"}]"#,
                languageCode: "fr-CA"
            )
        ]
        let snapshot = try #require(
            store.meetingRecoveryCandidates().first { $0.handle.sessionID == handle.sessionID }
        )
        let plan = try store.makeMeetingFinalizationPlan(handle)

        #expect(snapshot.completedASRCheckpoints == expected)
        #expect(snapshot.completedASRSequences == [0, 1])
        #expect(plan.completedASRCheckpoints == expected)
        #expect(plan.completedASRSequences == [0, 1])
        #expect(plan.sourceChunks.map(\.chunkID) == [first.chunkID, second.chunkID])
    }

    @Test func finalASRCheckpointIsFullyIdempotentAndRejectsEveryOutputConflict() throws {
        let container = try makeContainer()
        let store = makeStore(in: container)
        let startedAt = Date(timeIntervalSinceReferenceDate: 15_000)
        let handle = try store.startMeetingCapture(startedAt: startedAt)
        let sourceChunk = chunk(
            handle.microphoneSourceID,
            sessionID: handle.sessionID,
            sequence: 0,
            sealedAt: startedAt.addingTimeInterval(1)
        )
        try store.recordSealedMeetingChunk(handle, checkpoint: sourceChunk)
        let segments = #"[{"speaker":"speaker-1","start":0,"end":300,"text":"Original"}]"#

        func record(
            startOffset: TimeInterval,
            duration: TimeInterval,
            text: String,
            segmentsJSON: String?,
            languageCode: String?
        ) throws -> UUID {
            try store.recordMeetingTranscriptionChunk(
                handle,
                sourceChunkSequence: 0,
                startOffset: startOffset,
                duration: duration,
                text: text,
                segmentsJSON: segmentsJSON,
                languageCode: languageCode
            )
        }

        let revisionID = try record(
            startOffset: sourceChunk.startOffset,
            duration: sourceChunk.duration,
            text: "Original",
            segmentsJSON: segments,
            languageCode: "en-US"
        )
        #expect(try record(
            startOffset: sourceChunk.startOffset,
            duration: sourceChunk.duration,
            text: "Original",
            segmentsJSON: segments,
            languageCode: "en-US"
        ) == revisionID)
        #expect(throws: CaptureSessionStoreError.meetingTranscriptionRevisionConflict(
            sequence: 0,
            stage: .finalTranscription
        )) {
            _ = try record(
                startOffset: sourceChunk.startOffset + 1,
                duration: sourceChunk.duration,
                text: "Original",
                segmentsJSON: segments,
                languageCode: "en-US"
            )
        }
        #expect(throws: CaptureSessionStoreError.meetingTranscriptionRevisionConflict(
            sequence: 0,
            stage: .finalTranscription
        )) {
            _ = try record(
                startOffset: sourceChunk.startOffset,
                duration: sourceChunk.duration - 1,
                text: "Original",
                segmentsJSON: segments,
                languageCode: "en-US"
            )
        }
        #expect(throws: CaptureSessionStoreError.meetingTranscriptionRevisionConflict(
            sequence: 0,
            stage: .finalTranscription
        )) {
            _ = try record(
                startOffset: sourceChunk.startOffset,
                duration: sourceChunk.duration,
                text: "Changed",
                segmentsJSON: segments,
                languageCode: "en-US"
            )
        }
        #expect(throws: CaptureSessionStoreError.meetingTranscriptionRevisionConflict(
            sequence: 0,
            stage: .finalTranscription
        )) {
            _ = try record(
                startOffset: sourceChunk.startOffset,
                duration: sourceChunk.duration,
                text: "Original",
                segmentsJSON: "[]",
                languageCode: "en-US"
            )
        }
        #expect(throws: CaptureSessionStoreError.meetingTranscriptionRevisionConflict(
            sequence: 0,
            stage: .finalTranscription
        )) {
            _ = try record(
                startOffset: sourceChunk.startOffset,
                duration: sourceChunk.duration,
                text: "Original",
                segmentsJSON: segments,
                languageCode: "fr-CA"
            )
        }
    }

    @Test func finalizationFailuresRemainSessionScopedAndAreIdempotent() throws {
        let container = try makeContainer()
        let store = makeStore(in: container)
        let startedAt = Date(timeIntervalSinceReferenceDate: 16_000)
        let handle = try store.startMeetingCapture(startedAt: startedAt)
        try store.beginMeetingFinalization(handle, at: startedAt.addingTimeInterval(1))
        let sessionFailureAt = startedAt.addingTimeInterval(2)
        try store.recordMeetingFinalizationFailure(
            handle,
            stage: .finalTranscription,
            domain: "HistoryStore",
            code: "unavailable",
            message: "History persistence is temporarily unavailable.",
            retryable: true,
            at: sessionFailureAt
        )
        try store.recordMeetingFinalizationFailure(
            handle,
            stage: .finalTranscription,
            domain: "HistoryStore",
            code: "unavailable",
            message: "History persistence is temporarily unavailable.",
            retryable: true,
            at: sessionFailureAt
        )
        try store.recordMeetingFinalizationFailure(
            handle,
            sequence: 0,
            stage: .diarization,
            domain: "MeetingMix",
            code: "mixed-input",
            message: "The mixed chunk could not be diarized.",
            retryable: false,
            at: startedAt.addingTimeInterval(3)
        )

        let context = ModelContext(container)
        let failures = try context.fetch(FetchDescriptor<CaptureFailureRecordModel>())
            .filter { $0.sessionID == handle.sessionID }
        #expect(failures.count == 2)
        #expect(failures.allSatisfy { $0.sourceID == nil && $0.chunkID == nil })
        #expect(failures.contains {
            $0.stageRawValue == CapturePipelineStage.diarization.rawValue &&
                $0.detailsJSON == #"{"sequence":0}"#
        })
    }

    @Test func stageFailuresRemainSessionScopedAndAreIdempotentOnlyForTheirExactKey() throws {
        let container = try makeContainer()
        let store = makeStore(in: container)
        let handle = try store.startVoiceNoteCapture()
        let occurredAt = Date(timeIntervalSinceReferenceDate: 16_100)

        try store.recordStageFailure(
            sessionID: handle.sessionID,
            stage: .finalTranscription,
            attempt: 1,
            domain: "Transcription",
            code: "unavailable",
            message: "The assigned model is unavailable.",
            retryable: true,
            at: occurredAt
        )
        try store.recordStageFailure(
            sessionID: handle.sessionID,
            stage: .finalTranscription,
            attempt: 1,
            domain: "Transcription",
            code: "unavailable",
            message: "The assigned model is unavailable.",
            retryable: true,
            at: occurredAt
        )
        try store.recordStageFailure(
            sessionID: handle.sessionID,
            stage: .finalTranscription,
            attempt: 1,
            domain: "Transcription",
            code: "credential-unavailable",
            message: "The assigned credential is unavailable.",
            retryable: true,
            at: occurredAt
        )

        let context = ModelContext(container)
        let failures = try context.fetch(FetchDescriptor<CaptureFailureRecordModel>())
            .filter { $0.sessionID == handle.sessionID }
        let session = try #require(
            context.fetch(FetchDescriptor<CaptureSessionModel>())
                .first { $0.id == handle.sessionID }
        )
        let modelFailure = try #require(
            failures.first { $0.errorCode == "unavailable" }
        )

        #expect(failures.count == 2)
        #expect(modelFailure.sourceID == nil)
        #expect(modelFailure.chunkID == nil)
        #expect(modelFailure.transcriptRevisionID == nil)
        #expect(modelFailure.providerSnapshotID == nil)
        #expect(modelFailure.stageRawValue == CapturePipelineStage.finalTranscription.rawValue)
        #expect(modelFailure.attempt == 1)
        #expect(modelFailure.isRetryable)
        #expect(modelFailure.recoveryDispositionRawValue == CaptureFailureDisposition.recoverable.rawValue)
        #expect(session.lastActivityAt == occurredAt)
    }

    @Test func captureStageAssignmentRejectsInvalidImmutableValues() throws {
        #expect(throws: CaptureStageAssignmentError.invalidAttempt(0)) {
            try assignment(stage: .finalTranscription, attempt: 0)
        }
        #expect(
            throws: CaptureStageAssignmentError.promptNotAllowed(stage: .finalTranscription)
        ) {
            try assignment(
                stage: .finalTranscription,
                prompt: CapturePromptSnapshot(
                    presetIdentifier: "meeting-summary",
                    resolvedPrompt: "Summarize this meeting."
                )
            )
        }
        #expect(
            throws: CaptureStageAssignmentError.missingModelIdentifier(providerKind: .generativeAI)
        ) {
            try assignment(
                stage: .noteGeneration,
                providerKind: .generativeAI,
                modelIdentifier: nil
            )
        }

        let disabled = try assignment(
            stage: .liveTranscription,
            providerKind: .disabled,
            providerIdentifier: "disabled",
            modelIdentifier: nil
        )
        #expect(disabled.modelIdentifier == nil)
    }

    @Test func resolveAssignmentInsertsOnceAndDoesNotReevaluateSelector() throws {
        let container = try makeContainer()
        let store = makeStore(in: container)
        let handle = try store.startVoiceNoteCapture()
        let expected = try assignment(stage: .finalTranscription)
        var selectionCount = 0

        let first = try store.resolveAssignment(
            sessionID: handle.sessionID,
            stage: .finalTranscription,
            attempt: 1
        ) {
            selectionCount += 1
            return expected
        }
        let reused = try store.resolveAssignment(
            sessionID: handle.sessionID,
            stage: .finalTranscription,
            attempt: 1
        ) {
            selectionCount += 1
            return try assignment(
                stage: .finalTranscription,
                providerIdentifier: "different-provider",
                modelIdentifier: "different-model"
            )
        }

        let context = ModelContext(container)
        let snapshots = try context.fetch(FetchDescriptor<CaptureStageProviderSnapshotModel>())
            .filter { $0.sessionID == handle.sessionID }
        #expect(first == expected)
        #expect(reused == expected)
        #expect(selectionCount == 1)
        #expect(snapshots.count == 1)
    }

    @Test func resolveAssignmentKeepsAttemptsAndStagesAsSeparateImmutableKeys() throws {
        let container = try makeContainer()
        let store = makeStore(in: container)
        let handle = try store.startMeetingCapture()
        let assignments = try [
            assignment(stage: .liveTranscription, attempt: 1),
            assignment(stage: .finalTranscription, attempt: 1),
            assignment(stage: .finalTranscription, attempt: 2),
            assignment(stage: .diarization, attempt: 1)
        ]

        for assignment in assignments {
            let resolved = try store.resolveAssignment(
                sessionID: handle.sessionID,
                stage: assignment.stage,
                attempt: assignment.attempt
            ) {
                assignment
            }
            #expect(resolved == assignment)
        }

        let context = ModelContext(container)
        let snapshots = try context.fetch(FetchDescriptor<CaptureStageProviderSnapshotModel>())
            .filter { $0.sessionID == handle.sessionID }
        #expect(snapshots.count == assignments.count)
        #expect(Set(snapshots.map { "\($0.stageRawValue)-\($0.attempt)" }).count == assignments.count)
    }

    @Test func assignmentPersistenceReportsMissingMismatchedDuplicateAndCorruptRows() throws {
        let container = try makeContainer()
        let store = makeStore(in: container)
        let missingSessionID = UUID()
        #expect(throws: CaptureSessionStoreError.assignmentSessionNotFound(missingSessionID)) {
            try store.persistedAssignment(
                sessionID: missingSessionID,
                stage: .finalTranscription,
                attempt: 1
            )
        }

        let handle = try store.startVoiceNoteCapture()
        let mismatched = try assignment(stage: .diarization)
        #expect(throws: CaptureSessionStoreError.assignmentKeyMismatch) {
            try store.resolveAssignment(
                sessionID: handle.sessionID,
                stage: .finalTranscription,
                attempt: 1
            ) {
                mismatched
            }
        }

        let context = ModelContext(container)
        context.insert(
            CaptureStageProviderSnapshotModel(
                sessionID: handle.sessionID,
                stage: .finalTranscription,
                attempt: 1,
                providerKindRawValue: CaptureAssignmentProviderKind.batchSpeech.rawValue,
                providerIdentifier: "first-provider",
                modelIdentifier: "first-model"
            )
        )
        context.insert(
            CaptureStageProviderSnapshotModel(
                sessionID: handle.sessionID,
                stage: .finalTranscription,
                attempt: 1,
                providerKindRawValue: CaptureAssignmentProviderKind.batchSpeech.rawValue,
                providerIdentifier: "second-provider",
                modelIdentifier: "second-model"
            )
        )
        try context.save()

        #expect(
            throws: CaptureSessionStoreError.duplicateAssignments(
                sessionID: handle.sessionID,
                stage: .finalTranscription,
                attempt: 1
            )
        ) {
            try store.persistedAssignment(
                sessionID: handle.sessionID,
                stage: .finalTranscription,
                attempt: 1
            )
        }

        let corruptHandle = try store.startVoiceNoteCapture()
        let corruptContext = ModelContext(container)
        corruptContext.insert(
            CaptureStageProviderSnapshotModel(
                sessionID: corruptHandle.sessionID,
                stage: .finalTranscription,
                attempt: 1,
                providerKindRawValue: "not-a-provider-kind",
                providerIdentifier: "catalog-provider",
                modelIdentifier: "catalog-model"
            )
        )
        try corruptContext.save()

        #expect(
            throws: CaptureSessionProjectionError.invalidAssignmentProviderKindRawValue(
                "not-a-provider-kind"
            )
        ) {
            try store.persistedAssignment(
                sessionID: corruptHandle.sessionID,
                stage: .finalTranscription,
                attempt: 1
            )
        }
    }

    @Test func snapshotModelsExposeReadOnlyProjectionValuesWithoutConnectionDetails() throws {
        let container = try makeContainer()
        let store = makeStore(in: container)
        let handle = try store.startVoiceNoteCapture()
        let prompt = CapturePromptSnapshot(
            presetIdentifier: "meeting-summary",
            resolvedPrompt: "Create concise meeting notes."
        )
        let expected = try assignment(
            stage: .noteGeneration,
            providerKind: .generativeAI,
            providerIdentifier: "catalog-provider",
            modelIdentifier: "catalog-model",
            prompt: prompt
        )

        let resolved = try store.resolveAssignment(
            sessionID: handle.sessionID,
            stage: .noteGeneration,
            attempt: 1
        ) {
            expected
        }
        let restored = try #require(
            try store.persistedAssignment(
                sessionID: handle.sessionID,
                stage: .noteGeneration,
                attempt: 1
            )
        )
        let context = ModelContext(container)
        let providerSnapshots = try context.fetch(FetchDescriptor<CaptureStageProviderSnapshotModel>())
            .filter { $0.sessionID == handle.sessionID }
        let promptSnapshots = try context.fetch(FetchDescriptor<CaptureStagePromptSnapshotModel>())
            .filter { $0.sessionID == handle.sessionID }
        let providerSnapshot = try #require(providerSnapshots.first)
        let promptSnapshot = try #require(promptSnapshots.first)
        let observableFields = Set(Mirror(reflecting: restored).children.compactMap(\.label))

        #expect(resolved == expected)
        #expect(restored == expected)
        #expect(providerSnapshots.count == 1)
        #expect(try providerSnapshot.restoreAssignment().prompt == nil)
        #expect(providerSnapshot.sessionID == handle.sessionID)
        #expect(promptSnapshots.count == 1)
        #expect(promptSnapshot.restorePrompt() == prompt)
        #expect(
            observableFields == [
                "stage",
                "providerKind",
                "providerIdentifier",
                "modelIdentifier",
                "prompt",
                "selectedAt",
                "attempt"
            ]
        )
    }

    @Test func legacyProviderSnapshotWithMissingPromptPresetReturnsUnresolvedPromptWithoutCompanion() throws {
        let container = try makeContainer()
        let store = makeStore(in: container)
        let handle = try store.startVoiceNoteCapture()
        let legacyPromptPresetID = UUID()
        let context = ModelContext(container)
        context.insert(
            CaptureStageProviderSnapshotModel(
                sessionID: handle.sessionID,
                stage: .noteGeneration,
                attempt: 1,
                providerKindRawValue: CaptureAssignmentProviderKind.generativeAI.rawValue,
                providerIdentifier: "catalog-provider",
                modelIdentifier: "catalog-model",
                promptPresetID: legacyPromptPresetID
            )
        )
        try context.save()

        let restored = try #require(
            try store.persistedAssignment(
                sessionID: handle.sessionID,
                stage: .noteGeneration,
                attempt: 1
            )
        )
        let promptSnapshots = try context.fetch(FetchDescriptor<CaptureStagePromptSnapshotModel>())
            .filter { $0.sessionID == handle.sessionID }

        #expect(
            restored.prompt == CapturePromptSnapshot(
                presetIdentifier: legacyPromptPresetID.uuidString,
                resolvedPrompt: nil
            )
        )
        #expect(promptSnapshots.isEmpty)
    }

    @Test func legacyProviderSnapshotWithoutCompanionRemainsFailClosedAfterPresetCreationAndMutation() throws {
        let container = try makeContainer()
        let store = makeStore(in: container)
        let handle = try store.startVoiceNoteCapture()
        let providerSnapshotID = UUID()
        let legacyPromptPresetID = UUID()
        let expectedPrompt = CapturePromptSnapshot(
            presetIdentifier: legacyPromptPresetID.uuidString,
            resolvedPrompt: nil
        )
        let context = ModelContext(container)
        context.insert(
            CaptureStageProviderSnapshotModel(
                id: providerSnapshotID,
                sessionID: handle.sessionID,
                stage: .noteGeneration,
                attempt: 1,
                providerKindRawValue: CaptureAssignmentProviderKind.generativeAI.rawValue,
                providerIdentifier: "catalog-provider",
                modelIdentifier: "catalog-model",
                promptPresetID: legacyPromptPresetID
            )
        )
        try context.save()

        let beforePresetCreation = try #require(
            try store.persistedAssignment(
                sessionID: handle.sessionID,
                stage: .noteGeneration,
                attempt: 1
            )
        )

        let preset = PromptPreset(
            id: legacyPromptPresetID,
            name: "Legacy custom preset",
            prompt: "Created prompt"
        )
        context.insert(preset)
        try context.save()

        let afterPresetCreation = try #require(
            try store.persistedAssignment(
                sessionID: handle.sessionID,
                stage: .noteGeneration,
                attempt: 1
            )
        )

        preset.prompt = "Mutated prompt"
        try context.save()

        let afterPresetMutation = try #require(
            try store.persistedAssignment(
                sessionID: handle.sessionID,
                stage: .noteGeneration,
                attempt: 1
            )
        )
        let inspectionContext = ModelContext(container)
        let companions = try inspectionContext.fetch(
            FetchDescriptor<CaptureStagePromptSnapshotModel>()
        )
        .filter { $0.providerSnapshotID == providerSnapshotID }

        #expect(beforePresetCreation.prompt == expectedPrompt)
        #expect(afterPresetCreation.prompt == expectedPrompt)
        #expect(afterPresetMutation.prompt == expectedPrompt)
        #expect(companions.isEmpty)
    }

    @Test func promptCompanionRemainsAuthoritativeOverLegacyPromptPresetIdentifier() throws {
        let container = try makeContainer()
        let store = makeStore(in: container)
        let handle = try store.startVoiceNoteCapture()
        let providerSnapshotID = UUID()
        let context = ModelContext(container)
        context.insert(
            CaptureStageProviderSnapshotModel(
                id: providerSnapshotID,
                sessionID: handle.sessionID,
                stage: .noteGeneration,
                attempt: 1,
                providerKindRawValue: CaptureAssignmentProviderKind.generativeAI.rawValue,
                providerIdentifier: "catalog-provider",
                modelIdentifier: "catalog-model",
                promptPresetID: UUID()
            )
        )
        context.insert(
            CaptureStagePromptSnapshotModel(
                providerSnapshotID: providerSnapshotID,
                sessionID: handle.sessionID,
                presetIdentifier: "companion-preset",
                resolvedPrompt: "Companion prompt."
            )
        )
        try context.save()

        let restored = try #require(
            try store.persistedAssignment(
                sessionID: handle.sessionID,
                stage: .noteGeneration,
                attempt: 1
            )
        )
        #expect(
            restored.prompt == CapturePromptSnapshot(
                presetIdentifier: "companion-preset",
                resolvedPrompt: "Companion prompt."
            )
        )
    }
    @Test func liveVoiceNoteCheckpointsPersistOnlyCommittedPrefixGrowthAndExactRetries() throws {
        let container = try makeContainer()
        let store = makeStore(in: container)
        let startedAt = Date(timeIntervalSinceReferenceDate: 22_000)
        let handle = try store.startVoiceNoteCapture(startedAt: startedAt)
        _ = try store.resolveAssignment(
            sessionID: handle.sessionID,
            stage: .liveTranscription,
            attempt: 1,
            selecting: { try assignment(stage: .liveTranscription) }
        )

        let first = try store.checkpointVoiceNoteLiveTranscript(
            for: handle,
            committedText: "Hello",
            at: startedAt.addingTimeInterval(1)
        )
        let second = try store.checkpointVoiceNoteLiveTranscript(
            for: handle,
            committedText: "Hello, world",
            at: startedAt.addingTimeInterval(2)
        )
        let retried = try store.checkpointVoiceNoteLiveTranscript(
            for: handle,
            committedText: "Hello, world",
            at: startedAt.addingTimeInterval(3)
        )

        #expect(retried == second)
        #expect(throws: CaptureSessionStoreError.emptyLiveTranscript(handle.sessionID)) {
            try store.checkpointVoiceNoteLiveTranscript(
                for: handle,
                committedText: "",
                at: startedAt.addingTimeInterval(4)
            )
        }
        #expect(throws: CaptureSessionStoreError.liveTranscriptRegression(sessionID: handle.sessionID)) {
            try store.checkpointVoiceNoteLiveTranscript(
                for: handle,
                committedText: "Hello again",
                at: startedAt.addingTimeInterval(4)
            )
        }

        let context = ModelContext(container)
        let revisions = try context.fetch(FetchDescriptor<CaptureTranscriptRevisionModel>())
            .filter { $0.sessionID == handle.sessionID }
            .sorted { $0.sequence < $1.sequence }
        let session = try #require(
            context.fetch(FetchDescriptor<CaptureSessionModel>()).first { $0.id == handle.sessionID }
        )
        #expect(revisions.count == 2)
        #expect(revisions.map(\.text) == ["Hello", "Hello, world"])
        #expect(revisions[0].id == first.revisionID)
        #expect(revisions[0].sourceID == handle.microphoneSourceID)
        #expect(revisions[0].stageRawValue == CapturePipelineStage.liveTranscription.rawValue)
        #expect(revisions[0].statusRawValue == "completed")
        #expect(revisions[0].providerSnapshotID == first.providerSnapshotID)
        #expect(revisions[0].parentRevisionID == nil)
        #expect(revisions[0].sequence == 0)
        #expect(revisions[1].id == second.revisionID)
        #expect(revisions[1].parentRevisionID == first.revisionID)
        #expect(revisions[1].providerSnapshotID == first.providerSnapshotID)
        #expect(session.lastActivityAt == startedAt.addingTimeInterval(2))
    }

    @Test func liveVoiceNoteCheckpointRejectsDuplicateProvenanceAndMeetingHandles() throws {
        let container = try makeContainer()
        let store = makeStore(in: container)
        let voiceNote = try store.startVoiceNoteCapture()
        let context = ModelContext(container)
        for providerIdentifier in ["first", "second"] {
            context.insert(
                CaptureStageProviderSnapshotModel(
                    sessionID: voiceNote.sessionID,
                    stage: .liveTranscription,
                    attempt: 1,
                    providerKindRawValue: CaptureAssignmentProviderKind.streamingSpeech.rawValue,
                    providerIdentifier: providerIdentifier,
                    modelIdentifier: "catalog-model"
                )
            )
        }
        try context.save()

        #expect(
            throws: CaptureSessionStoreError.duplicateLiveTranscriptAssignments(
                sessionID: voiceNote.sessionID,
                attempt: 1
            )
        ) {
            try store.checkpointVoiceNoteLiveTranscript(
                for: voiceNote,
                committedText: "Committed text"
            )
        }
        let corrupt = try store.startVoiceNoteCapture()
        _ = try store.resolveAssignment(
            sessionID: corrupt.sessionID,
            stage: .liveTranscription,
            attempt: 1,
            selecting: { try assignment(stage: .liveTranscription) }
        )
        context.insert(
            CaptureTranscriptRevisionModel(
                sessionID: corrupt.sessionID,
                sourceID: corrupt.microphoneSourceID,
                sequence: 0,
                stage: .liveTranscription,
                statusRawValue: "completed",
                startOffset: 0,
                duration: 0,
                text: "Corrupt provenance"
            )
        )
        try context.save()
        #expect(
            throws: CaptureSessionStoreError.liveTranscriptConflict(
                sessionID: corrupt.sessionID,
                sequence: 0
            )
        ) {
            try store.checkpointVoiceNoteLiveTranscript(
                for: corrupt,
                committedText: "Corrupt provenance extended"
            )
        }


        let meeting = try store.startMeetingCapture()
        #expect(
            throws: CaptureSessionStoreError.sessionModeMismatch(
                sessionID: meeting.sessionID,
                expected: .voiceNote,
                actualRawValue: CaptureSessionMode.meeting.rawValue
            )
        ) {
            try store.checkpointVoiceNoteLiveTranscript(
                for: VoiceNoteCaptureHandle(
                    sessionID: meeting.sessionID,
                    microphoneSourceID: meeting.microphoneSourceID
                ),
                committedText: "Must not leak into meetings"
            )
        }
    }

    @Test func liveVoiceNoteCheckpointsRequireStreamingAssignmentAndRejectInvalidRecoveryProvenance() throws {
        let container = try makeContainer()
        let store = makeStore(in: container)
        let wrongKind = try store.startVoiceNoteCapture()
        _ = try store.resolveAssignment(
            sessionID: wrongKind.sessionID,
            stage: .liveTranscription,
            attempt: 1,
            selecting: {
                try assignment(
                    stage: .liveTranscription,
                    providerKind: .batchSpeech
                )
            }
        )

        #expect(
            throws: CaptureSessionStoreError.liveTranscriptAssignmentUnavailable(
                sessionID: wrongKind.sessionID,
                attempt: 1
            )
        ) {
            try store.checkpointVoiceNoteLiveTranscript(
                for: wrongKind,
                committedText: "Must not persist"
            )
        }

        let unavailable = try store.startVoiceNoteCapture()
        _ = try store.resolveAssignment(
            sessionID: unavailable.sessionID,
            stage: .liveTranscription,
            attempt: 1,
            selecting: {
                try assignment(
                    stage: .liveTranscription,
                    providerKind: .bestEffortUnavailable,
                    providerIdentifier: "unavailable",
                    modelIdentifier: nil
                )
            }
        )
        #expect(
            throws: CaptureSessionStoreError.liveTranscriptAssignmentUnavailable(
                sessionID: unavailable.sessionID,
                attempt: 1
            )
        ) {
            try store.checkpointVoiceNoteLiveTranscript(
                for: unavailable,
                committedText: "Must not persist"
            )
        }

        let restoredWrongKind = try store.startVoiceNoteCapture()
        let context = ModelContext(container)
        let snapshot = CaptureStageProviderSnapshotModel(
            sessionID: restoredWrongKind.sessionID,
            stage: .liveTranscription,
            attempt: 1,
            providerKindRawValue: CaptureAssignmentProviderKind.batchSpeech.rawValue,
            providerIdentifier: "batch-provider",
            modelIdentifier: "batch-model"
        )
        context.insert(snapshot)
        context.insert(
            CaptureTranscriptRevisionModel(
                sessionID: restoredWrongKind.sessionID,
                sourceID: restoredWrongKind.microphoneSourceID,
                sequence: 0,
                stage: .liveTranscription,
                statusRawValue: "completed",
                startOffset: 0,
                duration: 0,
                text: "Wrong-kind persisted checkpoint",
                providerSnapshotID: snapshot.id
            )
        )
        try context.save()

        let persistedRevisions = try context.fetch(FetchDescriptor<CaptureTranscriptRevisionModel>())
        #expect(persistedRevisions.filter { $0.sessionID == wrongKind.sessionID }.isEmpty)
        #expect(persistedRevisions.filter { $0.sessionID == unavailable.sessionID }.isEmpty)
        #expect(
            try store.voiceNoteRecoveryCandidates()
                .contains { $0.handle.sessionID == restoredWrongKind.sessionID } == false
        )
    }

    @Test func finalVoiceNoteRawRevisionParentsLatestLiveCheckpoint() throws {
        let container = try makeContainer()
        let store = makeStore(in: container)
        let startedAt = Date(timeIntervalSinceReferenceDate: 23_000)
        let handle = try store.startVoiceNoteCapture(startedAt: startedAt)
        _ = try store.resolveAssignment(
            sessionID: handle.sessionID,
            stage: .liveTranscription,
            attempt: 1,
            selecting: { try assignment(stage: .liveTranscription) }
        )
        let live = try store.checkpointVoiceNoteLiveTranscript(
            for: handle,
            committedText: "Committed live text",
            at: startedAt.addingTimeInterval(1)
        )
        try store.beginFinalization(handle, at: startedAt.addingTimeInterval(2))
        let revisions = try store.saveTranscriptRevisions(
            for: handle,
            rawText: "Final raw text",
            finalText: "Final polished text",
            duration: 4,
            languageCode: "en",
            createdAt: startedAt.addingTimeInterval(3)
        )

        let context = ModelContext(container)
        let raw = try #require(
            context.fetch(FetchDescriptor<CaptureTranscriptRevisionModel>()).first {
                $0.id == revisions.rawRevisionID
            }
        )
        let final = try #require(
            context.fetch(FetchDescriptor<CaptureTranscriptRevisionModel>()).first {
                $0.id == revisions.finalRevisionID
            }
        )
        #expect(raw.parentRevisionID == live.revisionID)
        #expect(final.parentRevisionID == raw.id)
        #expect(raw.sequence == live.sequence + 1)
        #expect(final.sequence == raw.sequence + 1)
    }

    @Test func voiceNoteRecoveryCandidatesAreStableAndExcludeIncompleteAndMeetingSessions() throws {
        let container = try makeContainer()
        let store = makeStore(in: container)
        let startedAt = Date(timeIntervalSinceReferenceDate: 24_000)
        let capturing = try store.startVoiceNoteCapture(startedAt: startedAt)
        let finalizing = try store.startVoiceNoteCapture(startedAt: startedAt)
        let interrupted = try store.startVoiceNoteCapture(startedAt: startedAt)
        _ = try store.startVoiceNoteCapture(startedAt: startedAt)
        _ = try store.startMeetingCapture(startedAt: startedAt)

        for handle in [capturing, finalizing, interrupted] {
            _ = try store.resolveAssignment(
                sessionID: handle.sessionID,
                stage: .liveTranscription,
                attempt: 1,
                selecting: { try assignment(stage: .liveTranscription) }
            )
        }
        _ = try store.checkpointVoiceNoteLiveTranscript(
            for: capturing,
            committedText: "Capturing checkpoint",
            at: startedAt.addingTimeInterval(1)
        )
        _ = try store.checkpointVoiceNoteLiveTranscript(
            for: finalizing,
            committedText: "Finalizing checkpoint",
            at: startedAt.addingTimeInterval(2)
        )
        try store.beginFinalization(finalizing, at: startedAt.addingTimeInterval(3))
        _ = try store.checkpointVoiceNoteLiveTranscript(
            for: interrupted,
            committedText: "Interrupted checkpoint",
            at: startedAt.addingTimeInterval(4)
        )

        let interruptionAt = startedAt.addingTimeInterval(5)
        let context = ModelContext(container)
        let interruptedModel = try #require(
            context.fetch(FetchDescriptor<CaptureSessionModel>()).first { $0.id == interrupted.sessionID }
        )
        var interruptedSession = try interruptedModel.restoreSession()
        let failure = CaptureFailure(
            sessionID: interrupted.sessionID,
            disposition: .recoverable,
            occurredAt: interruptionAt,
            code: "interrupted",
            message: "Application terminated.",
            stage: .liveTranscription,
            sourceID: interrupted.microphoneSourceID
        )
        try interruptedSession.interrupt(with: failure, at: interruptionAt)
        try interruptedModel.update(from: interruptedSession)
        interruptedModel.lastActivityAt = interruptionAt
        try context.save()

        let candidates = try store.voiceNoteRecoveryCandidates()
        #expect(candidates.map(\.handle.sessionID) == [
            interrupted.sessionID,
            finalizing.sessionID,
            capturing.sessionID
        ])
        #expect(candidates.map(\.state) == [.interrupted, .finalizing, .capturing])
        #expect(candidates[0].latestLiveCheckpoint?.committedText == "Interrupted checkpoint")
        #expect(candidates[1].latestLiveCheckpoint?.committedText == "Finalizing checkpoint")
        #expect(candidates[2].latestLiveCheckpoint?.committedText == "Capturing checkpoint")
        #expect(candidates[0].recoveryTarget == .capturing)
        let repeatedCandidates = try store.voiceNoteRecoveryCandidates()
        #expect(candidates == repeatedCandidates)
    }

    @Test func meetingAnchorAndGeneratedNotePersistExactProvenance() throws {
        let container = try makeContainer()
        let store = makeStore(in: container)
        let startedAt = Date(timeIntervalSinceReferenceDate: 24_500)
        let handle = try store.startMeetingCapture(startedAt: startedAt)
        let anchor = try store.ensureMeetingHumanAnchor(
            handle,
            title: "Planning",
            at: startedAt
        )

        let notesContext = ModelContext(container)
        let editedAnchor = try #require(
            notesContext.fetch(FetchDescriptor<Note>()).first { $0.id == anchor.noteID }
        )
        editedAnchor.title = "Edited planning"
        editedAnchor.content = "Human edits survive."
        try notesContext.save()
        let retriedAnchor = try store.ensureMeetingHumanAnchor(
            handle,
            title: "Ignored replacement title",
            at: startedAt.addingTimeInterval(1)
        )
        #expect(retriedAnchor.title == "Edited planning")
        #expect(retriedAnchor.content == "Human edits survive.")
        try store.beginMeetingFinalization(handle, at: startedAt.addingTimeInterval(1))
        let canceledHandle = try store.startMeetingCapture(startedAt: startedAt.addingTimeInterval(2))
        let canceledAnchor = try store.ensureMeetingHumanAnchor(
            canceledHandle,
            title: "Canceled planning",
            at: startedAt.addingTimeInterval(2)
        )
        try store.cancelMeetingCapture(canceledHandle, at: startedAt.addingTimeInterval(3))
        #expect(try store.meetingHumanAnchor(canceledHandle)?.noteID == canceledAnchor.noteID)

        let checkpoint = chunk(
            handle.microphoneSourceID,
            sessionID: handle.sessionID,
            sequence: 0,
            sealedAt: startedAt.addingTimeInterval(2)
        )
        let segmentsJSON = String(
            decoding: try JSONEncoder().encode([
                DiarizedTranscriptSegment(
                    speakerId: "speaker-1",
                    speakerLabel: "Speaker 1",
                    startTime: 0,
                    endTime: checkpoint.duration / 2,
                    confidence: 1,
                    text: "Completed final"
                ),
                DiarizedTranscriptSegment(
                    speakerId: "speaker-2",
                    speakerLabel: "Speaker 2",
                    startTime: checkpoint.duration / 2,
                    endTime: checkpoint.duration,
                    confidence: 1,
                    text: "transcript"
                )
            ]),
            as: UTF8.self
        )
        try store.recordSealedMeetingChunk(handle, checkpoint: checkpoint)
        _ = try store.resolveAssignment(
            sessionID: handle.sessionID,
            stage: .finalTranscription,
            attempt: 1,
            selecting: { try assignment(stage: .finalTranscription) }
        )
        let revisionID = try store.recordMeetingTranscriptionChunk(
            handle,
            sourceChunkSequence: checkpoint.sequence,
            startOffset: checkpoint.startOffset,
            duration: checkpoint.duration,
            text: "Completed final transcript",
            segmentsJSON: segmentsJSON,
            assignmentAttempt: 1
        )
        let historyID = try store.reserveMeetingTranscriptionRecordID(handle)
        let historyContext = ModelContext(container)
        historyContext.insert(TranscriptionRecord(
            id: historyID,
            text: "Completed final transcript",
            duration: checkpoint.duration,
            modelUsed: "test"
        ))
        try historyContext.save()
        _ = try store.resolveAssignment(
            sessionID: handle.sessionID,
            stage: .noteGeneration,
            attempt: 1,
            selecting: {
                try assignment(
                    stage: .noteGeneration,
                    providerKind: .generativeAI,
                    providerIdentifier: "generator",
                    modelIdentifier: "generator-model",
                    prompt: CapturePromptSnapshot(
                        presetIdentifier: "meeting-summary",
                        resolvedPrompt: "Summarize this meeting."
                    )
                )
            }
        )
        let finalizationPlan = try store.makeMeetingFinalizationPlan(handle)
        #expect(finalizationPlan.completedASRCheckpoints.count == 1)
        let source = try MeetingNoteDerivation.make(
            humanNoteContent: retriedAnchor.content,
            checkpoints: finalizationPlan.completedASRCheckpoints
        )
        #expect(source.citations.count == 2)
        #expect(source.sourceTranscriptRevisionIDs == [revisionID])
        let stateBeforeInvalidSources = ModelContext(container)
        let noteCountBeforeInvalidSources = try stateBeforeInvalidSources.fetch(
            FetchDescriptor<Note>()
        ).count
        let referenceCountBeforeInvalidSources = try stateBeforeInvalidSources.fetch(
            FetchDescriptor<CaptureNoteReferenceModel>()
        )
        .filter { $0.sessionID == handle.sessionID }
        .count
        let missingSourceRevision = MeetingNoteSourceBundle(
            evidenceInput: source.evidenceInput,
            citations: source.citations,
            sourceTranscriptRevisionIDs: []
        )
        #expect(throws: CaptureSessionStoreError.meetingGeneratedNoteSourceChanged(handle.sessionID)) {
            try store.saveGeneratedMeetingNote(
                handle,
                title: "Generated summary",
                content: "Auditable generated content.",
                source: missingSourceRevision
            )
        }
        let fabricatedCitation = try #require(source.citations.first)
        let fabricatedCitationSource = MeetingNoteSourceBundle(
            evidenceInput: source.evidenceInput,
            citations: [
                MeetingNoteCitation(
                    identifier: fabricatedCitation.identifier,
                    transcriptRevisionID: fabricatedCitation.transcriptRevisionID,
                    startTime: fabricatedCitation.startTime,
                    endTime: fabricatedCitation.endTime + 1,
                    speakerLabel: fabricatedCitation.speakerLabel,
                    text: "Fabricated transcript text"
                ),
                source.citations[1]
            ],
            sourceTranscriptRevisionIDs: source.sourceTranscriptRevisionIDs
        )
        #expect(throws: CaptureSessionStoreError.meetingGeneratedNoteSourceChanged(handle.sessionID)) {
            try store.saveGeneratedMeetingNote(
                handle,
                title: "Generated summary",
                content: "Auditable generated content.",
                source: fabricatedCitationSource
            )
        }
        let fabricatedPromptSource = MeetingNoteSourceBundle(
            evidenceInput: "Fabricated evidence input",
            citations: source.citations,
            sourceTranscriptRevisionIDs: source.sourceTranscriptRevisionIDs
        )
        #expect(throws: CaptureSessionStoreError.meetingGeneratedNoteSourceChanged(handle.sessionID)) {
            try store.saveGeneratedMeetingNote(
                handle,
                title: "Generated summary",
                content: "Auditable generated content.",
                source: fabricatedPromptSource
            )
        }
        let extraSourceRevision = MeetingNoteSourceBundle(
            evidenceInput: source.evidenceInput,
            citations: source.citations,
            sourceTranscriptRevisionIDs: [revisionID, UUID()]
        )
        #expect(throws: CaptureSessionStoreError.meetingGeneratedNoteSourceChanged(handle.sessionID)) {
            try store.saveGeneratedMeetingNote(
                handle,
                title: "Generated summary",
                content: "Auditable generated content.",
                source: extraSourceRevision
            )
        }
        let stateAfterExtraSourceRevision = ModelContext(container)
        #expect(
            try stateAfterExtraSourceRevision.fetch(FetchDescriptor<Note>()).count
                == noteCountBeforeInvalidSources
        )
        #expect(
            try stateAfterExtraSourceRevision.fetch(FetchDescriptor<CaptureNoteReferenceModel>())
                .filter { $0.sessionID == handle.sessionID }
                .count == referenceCountBeforeInvalidSources
        )
        do {
            #expect(try store.generatedMeetingNote(handle) == nil)
        } catch {
            Issue.record("Pre-save generated-note discovery failed: \(error)")
            return
        }
        let generatedContent = generatedMeetingNoteContent()


        let generated: MeetingGeneratedNoteSnapshot
        do {
            generated = try store.saveGeneratedMeetingNote(
                handle,
                title: "Generated summary",
                content: generatedContent,
                source: source
            )
        } catch {
            Issue.record("Plain generated-note save failed: \(error)")
            return
        }
        let retriedWhileFinalizing: MeetingGeneratedNoteSnapshot
        do {
            retriedWhileFinalizing = try store.saveGeneratedMeetingNote(
                handle,
                title: "Generated summary",
                content: generatedContent,
                source: source
            )
        } catch {
            Issue.record("Finalizing generated-note retry failed: \(error)")
            return
        }
        do {
            let discovered = try store.generatedMeetingNote(handle)
            #expect(discovered == generated)
        } catch {
            Issue.record("Finalizing generated-note discovery failed: \(error)")
            return
        }
        #expect(retriedWhileFinalizing == generated)

        try store.finishMeetingSources(
            handle,
            sourceFailures: [
                failed(handle.dualSourceSystemAudioID, at: startedAt.addingTimeInterval(4))
            ],
            at: startedAt.addingTimeInterval(4)
        )
        try store.completeMeetingCapture(
            handle,
            transcriptionRecordID: historyID,
            at: startedAt.addingTimeInterval(5)
        )
        let retriedAfterCompletion = try store.saveGeneratedMeetingNote(
            handle,
            title: "Generated summary",
            content: generatedContent,
            source: source
        )
        #expect(retriedAfterCompletion == generated)
        #expect(try store.generatedMeetingNote(handle) == generated)
        let stateAfterRetries = ModelContext(container)
        #expect(
            try stateAfterRetries.fetch(FetchDescriptor<Note>()).count
                == noteCountBeforeInvalidSources + 1
        )
        #expect(
            try stateAfterRetries.fetch(FetchDescriptor<CaptureNoteReferenceModel>())
                .filter { $0.sessionID == handle.sessionID }
                .count == referenceCountBeforeInvalidSources + 1
        )

        let references = try ModelContext(container).fetch(FetchDescriptor<CaptureNoteReferenceModel>())
            .filter { $0.sessionID == handle.sessionID }
        let generatedReferences = try references.filter { reference in
            try reference.resolvedRole() == .generated
        }
        #expect(generatedReferences.count == 1)
        let generatedReference = try #require(generatedReferences.first)
        #expect(generatedReference.sourceTranscriptRevisionID == nil)
        #expect(generatedReference.humanAnchorContentSnapshot == retriedAnchor.content)
        let expectedProvenance = MeetingGeneratedNoteProvenance(
            humanAnchorNoteID: retriedAnchor.noteID,
            evidenceInput: source.evidenceInput,
            citations: source.citations,
            sourceTranscriptRevisionIDs: source.sourceTranscriptRevisionIDs
        )
        let provenanceEncoder = JSONEncoder()
        provenanceEncoder.outputFormatting = [.sortedKeys]
        #expect(
            generatedReference.provenanceJSON == String(
                decoding: try provenanceEncoder.encode(expectedProvenance),
                as: UTF8.self
            )
        )
        let corruptionContext = ModelContext(container)
        let corruptNote = try #require(
            corruptionContext.fetch(FetchDescriptor<Note>())
                .first { $0.id == generated.noteID }
        )
        corruptNote.content = "\(generatedContent)\n\nCitation Appendix: altered"
        try corruptionContext.save()
        #expect(throws: CaptureSessionStoreError.meetingGeneratedNoteConflict(handle.sessionID)) {
            _ = try store.generatedMeetingNote(handle)
        }
        corruptNote.content = generatedContent
        let corruptReference = try #require(
            corruptionContext.fetch(FetchDescriptor<CaptureNoteReferenceModel>())
                .first { $0.id == generatedReference.id }
        )
        corruptReference.provenanceJSON = "[]"
        try corruptionContext.save()
        #expect(throws: CaptureSessionStoreError.meetingGeneratedNoteConflict(handle.sessionID)) {
            _ = try store.generatedMeetingNote(handle)
        }
    }
    @Test func generatedMeetingNoteLookupPreservesImmutableHumanAnchorSnapshotAfterEdit() throws {
        let container = try makeContainer()
        let store = makeStore(in: container)
        let prepared = try generatedMeetingNoteInputs(
            in: container,
            store: store,
            startedAt: Date(timeIntervalSinceReferenceDate: 24_700)
        )
        let generated = try store.saveGeneratedMeetingNote(
            prepared.handle,
            title: "Generated summary",
            content: generatedMeetingNoteContent(),
            source: prepared.source
        )
        let anchor = try #require(try store.meetingHumanAnchor(prepared.handle))
        let originalAnchorContent = anchor.content
        #expect(generated.humanAnchorContent == originalAnchorContent)

        let editedAnchorContent = "Edited after generated note was saved."
        let editContext = ModelContext(container)
        let editedAnchor = try #require(
            editContext.fetch(FetchDescriptor<Note>()).first { $0.id == anchor.noteID }
        )
        editedAnchor.content = editedAnchorContent
        try editContext.save()
        #expect(try store.meetingHumanAnchor(prepared.handle)?.content == editedAnchorContent)

        let byHandle = try #require(try store.generatedMeetingNote(prepared.handle))
        let byNoteID = try #require(try store.generatedMeetingNote(noteID: generated.noteID))
        #expect(byHandle == generated)
        #expect(byNoteID == generated)
        #expect(byHandle.humanAnchorContent == originalAnchorContent)
        #expect(byNoteID.humanAnchorContent == originalAnchorContent)
        #expect(byHandle.humanAnchorContent != editedAnchorContent)
        #expect(byNoteID.humanAnchorContent != editedAnchorContent)
    }

    @Test func generatedMeetingNoteLookupRequiresCompleteProvenance() throws {
        typealias GeneratedFixture = (
            container: ModelContainer,
            store: CaptureSessionStore,
            handle: NoteCaptureHandle,
            historyID: UUID,
            noteID: UUID
        )

        func makeFixture(at timestamp: TimeInterval) throws -> GeneratedFixture {
            let container = try makeContainer()
            let store = makeStore(in: container)
            let prepared = try generatedMeetingNoteInputs(
                in: container,
                store: store,
                startedAt: Date(timeIntervalSinceReferenceDate: timestamp)
            )
            let generated = try store.saveGeneratedMeetingNote(
                prepared.handle,
                title: "Generated summary",
                content: generatedMeetingNoteContent(),
                source: prepared.source
            )
            return (
                container,
                store,
                prepared.handle,
                prepared.transcriptionRecordID,
                generated.noteID
            )
        }

        func assertConflict(
            _ fixture: GeneratedFixture,
            mutating mutate: (ModelContext, GeneratedFixture) throws -> Void
        ) throws {
            let context = ModelContext(fixture.container)
            try mutate(context, fixture)
            try context.save()
            #expect(
                throws: CaptureSessionStoreError.meetingGeneratedNoteConflict(fixture.handle.sessionID)
            ) {
                _ = try fixture.store.generatedMeetingNote(noteID: fixture.noteID)
            }
        }

        let valid = try makeFixture(at: 24_700)
        let byHandle = try valid.store.generatedMeetingNote(valid.handle)
        let byNoteID = try valid.store.generatedMeetingNote(noteID: valid.noteID)
        #expect(byNoteID == byHandle)
        #expect(try valid.store.generatedMeetingNote(noteID: UUID()) == nil)

        try assertConflict(try makeFixture(at: 24_701)) { context, fixture in
            let reference = try #require(
                context.fetch(FetchDescriptor<CaptureNoteReferenceModel>())
                    .first { $0.noteID == fixture.noteID }
            )
            reference.sourceTranscriptRevisionID = UUID()
        }

        try assertConflict(try makeFixture(at: 24_702)) { context, fixture in
            let reference = try #require(
                context.fetch(FetchDescriptor<CaptureNoteReferenceModel>())
                    .first { $0.noteID == fixture.noteID }
            )
            reference.providerSnapshotID = UUID()
        }

        try assertConflict(try makeFixture(at: 24_703)) { context, fixture in
            let history = try #require(
                context.fetch(FetchDescriptor<TranscriptionRecord>())
                    .first { $0.id == fixture.historyID }
            )
            context.delete(history)
        }

        try assertConflict(try makeFixture(at: 24_704)) { context, fixture in
            let humanReference = try #require(
                context.fetch(FetchDescriptor<CaptureNoteReferenceModel>())
                    .first { (try? $0.resolvedRole()) == .humanAnchor }
            )
            let humanNote = try #require(
                context.fetch(FetchDescriptor<Note>())
                    .first { $0.id == humanReference.noteID }
            )
            humanNote.sourceTranscriptionID = UUID()
        }

        try assertConflict(try makeFixture(at: 24_705)) { context, fixture in
            context.insert(CaptureNoteReferenceModel(
                sessionID: fixture.handle.sessionID,
                noteID: UUID(),
                role: .generated
            ))
        }

        try assertConflict(try makeFixture(at: 24_706)) { context, fixture in
            let reference = try #require(
                context.fetch(FetchDescriptor<CaptureNoteReferenceModel>())
                    .first { $0.noteID == fixture.noteID }
            )
            reference.provenanceJSON = "[]"
        }
        try assertConflict(try makeFixture(at: 24_707)) { context, fixture in
            let reference = try #require(
                context.fetch(FetchDescriptor<CaptureNoteReferenceModel>())
                    .first { $0.noteID == fixture.noteID }
            )
            let provenance = try JSONDecoder().decode(
                MeetingGeneratedNoteProvenance.self,
                from: try #require(reference.provenanceJSON).data(using: .utf8)!
            )
            let duplicateCitation = try #require(provenance.citations.first)
            let duplicateProvenance = MeetingGeneratedNoteProvenance(
                humanAnchorNoteID: provenance.humanAnchorNoteID,
                evidenceInput: provenance.evidenceInput,
                citations: provenance.citations + [duplicateCitation],
                sourceTranscriptRevisionIDs: provenance.sourceTranscriptRevisionIDs
            )
            reference.provenanceJSON = String(
                decoding: try JSONEncoder().encode(duplicateProvenance),
                as: UTF8.self
            )
        }

        try assertConflict(try makeFixture(at: 24_708)) { context, fixture in
            let reference = try #require(
                context.fetch(FetchDescriptor<CaptureNoteReferenceModel>())
                    .first { $0.noteID == fixture.noteID }
            )
            let provenance = try JSONDecoder().decode(
                MeetingGeneratedNoteProvenance.self,
                from: try #require(reference.provenanceJSON).data(using: .utf8)!
            )
            let orphanProvenance = MeetingGeneratedNoteProvenance(
                humanAnchorNoteID: provenance.humanAnchorNoteID,
                evidenceInput: provenance.evidenceInput,
                citations: provenance.citations,
                sourceTranscriptRevisionIDs: provenance.sourceTranscriptRevisionIDs + [UUID()]
            )
            reference.provenanceJSON = String(
                decoding: try JSONEncoder().encode(orphanProvenance),
                as: UTF8.self
            )
        }

        try assertConflict(try makeFixture(at: 24_709)) { context, fixture in
            let reference = try #require(
                context.fetch(FetchDescriptor<CaptureNoteReferenceModel>())
                    .first { $0.noteID == fixture.noteID }
            )
            let originalSnapshot = try #require(reference.humanAnchorContentSnapshot)
            let provenanceJSON = try #require(reference.provenanceJSON)
            var provenanceObject = try #require(
                try JSONSerialization.jsonObject(
                    with: Data(provenanceJSON.utf8)
                ) as? [String: Any]
            )
            provenanceObject["humanAnchorContent"] = "Forged anchor content."
            provenanceObject["evidenceInput"] = "Forged evidence input."
            reference.provenanceJSON = String(
                decoding: try JSONSerialization.data(
                    withJSONObject: provenanceObject,
                    options: [.sortedKeys]
                ),
                as: UTF8.self
            )
            #expect(reference.humanAnchorContentSnapshot == originalSnapshot)
        }
    }

    @Test func generatedNoteAcceptsPlainSanitizedOutputAndRejectsReservedSyntaxWithoutMutation() throws {
        let container = try makeContainer()
        let store = makeStore(in: container)
        let prepared = try generatedMeetingNoteInputs(
            in: container,
            store: store,
            startedAt: Date(timeIntervalSinceReferenceDate: 24_650)
        )
        let validContent = generatedMeetingNoteContent()
        let reservedMarker = "Auditable generated content. [C1]"
        let reservedHeading = "\(validContent)\n\nCitation Appendix:\n[C1] Forged source text."
        let unsanitizedFormatControl = "Auditable generated\u{200B} content."
        let beforeContext = ModelContext(container)
        let noteCountBefore = try beforeContext.fetch(FetchDescriptor<Note>()).count
        let referenceCountBefore = try beforeContext.fetch(
            FetchDescriptor<CaptureNoteReferenceModel>()
        )
        .filter { $0.sessionID == prepared.handle.sessionID }
        .count

        for rejectedContent in [reservedMarker, reservedHeading, unsanitizedFormatControl] {
            #expect(throws: CaptureSessionStoreError.invalidMeetingGeneratedNote(prepared.handle.sessionID)) {
                try store.saveGeneratedMeetingNote(
                    prepared.handle,
                    title: "Generated summary",
                    content: rejectedContent,
                    source: prepared.source
                )
            }
            let currentContext = ModelContext(container)
            #expect(try currentContext.fetch(FetchDescriptor<Note>()).count == noteCountBefore)
            #expect(
                try currentContext.fetch(FetchDescriptor<CaptureNoteReferenceModel>())
                    .filter { $0.sessionID == prepared.handle.sessionID }
                    .count == referenceCountBefore
            )
        }

        for rejectedTitle in ["Generated summary [C1]", "Generated\u{200B} summary"] {
            #expect(throws: CaptureSessionStoreError.invalidMeetingGeneratedNote(prepared.handle.sessionID)) {
                try store.saveGeneratedMeetingNote(
                    prepared.handle,
                    title: rejectedTitle,
                    content: validContent,
                    source: prepared.source
                )
            }
            let currentContext = ModelContext(container)
            #expect(try currentContext.fetch(FetchDescriptor<Note>()).count == noteCountBefore)
            #expect(
                try currentContext.fetch(FetchDescriptor<CaptureNoteReferenceModel>())
                    .filter { $0.sessionID == prepared.handle.sessionID }
                    .count == referenceCountBefore
            )
        }

        let saved = try store.saveGeneratedMeetingNote(
            prepared.handle,
            title: "Generated summary",
            content: validContent,
            source: prepared.source
        )
        #expect(saved.citations == prepared.source.citations)
        let savedContext = ModelContext(container)
        let savedNote = try #require(
            savedContext.fetch(FetchDescriptor<Note>())
                .first { $0.id == saved.noteID }
        )
        #expect(savedNote.content == validContent)
        let savedReference = try #require(
            savedContext.fetch(FetchDescriptor<CaptureNoteReferenceModel>())
                .first { $0.noteID == saved.noteID }
        )
        let savedProvenance = try JSONDecoder().decode(
            MeetingGeneratedNoteProvenance.self,
            from: try #require(savedReference.provenanceJSON).data(using: .utf8)!
        )
        #expect(savedProvenance.citations == prepared.source.citations)
        #expect(savedProvenance.evidenceInput == prepared.source.evidenceInput)
        #expect(
            savedProvenance.sourceTranscriptRevisionIDs
                == prepared.source.sourceTranscriptRevisionIDs
        )
        #expect(try store.generatedMeetingNote(prepared.handle) == saved)
        savedNote.title = "Generated summary [C1]"
        try savedContext.save()
        #expect(throws: CaptureSessionStoreError.meetingGeneratedNoteConflict(prepared.handle.sessionID)) {
            _ = try store.generatedMeetingNote(prepared.handle)
        }
        #expect(throws: CaptureSessionStoreError.meetingGeneratedNoteConflict(prepared.handle.sessionID)) {
            _ = try store.generatedMeetingNote(noteID: saved.noteID)
        }
    }

    @Test func meetingHumanAnchorRejectsEmptyCreationWithoutMutation() throws {
        let container = try makeContainer()
        let store = makeStore(in: container)
        let handle = try store.startMeetingCapture()

        #expect(throws: CaptureSessionStoreError.meetingHumanAnchorUnavailable(handle.sessionID)) {
            try store.ensureMeetingHumanAnchor(handle, title: " \n ")
        }

        let context = ModelContext(container)
        #expect(try context.fetch(FetchDescriptor<Note>()).isEmpty)
        #expect(
            try context.fetch(FetchDescriptor<CaptureNoteReferenceModel>())
                .filter { $0.sessionID == handle.sessionID }
                .isEmpty
        )
    }

    @Test func generatedNotePreflightRejectsNonExecutableAssignmentsAndUnresolvedPrompts() throws {
        let container = try makeContainer()
        let store = makeStore(in: container)
        let startedAt = Date(timeIntervalSinceReferenceDate: 24_600)
        let handle = try store.startMeetingCapture(startedAt: startedAt)
        _ = try store.ensureMeetingHumanAnchor(handle, title: "Planning", at: startedAt)
        try store.beginMeetingFinalization(handle, at: startedAt.addingTimeInterval(1))
        let historyID = try store.reserveMeetingTranscriptionRecordID(handle)
        let historyContext = ModelContext(container)
        historyContext.insert(TranscriptionRecord(
            id: historyID,
            text: "Completed final transcript",
            duration: 1,
            modelUsed: "test"
        ))
        try historyContext.save()

        let resolvedPrompt = CapturePromptSnapshot(
            presetIdentifier: "meeting-summary",
            resolvedPrompt: "Summarize this meeting."
        )
        let assignments = [
            try assignment(
                stage: .noteGeneration,
                providerKind: .batchSpeech,
                prompt: resolvedPrompt,
                attempt: 1
            ),
            try assignment(
                stage: .noteGeneration,
                providerKind: .disabled,
                modelIdentifier: nil,
                prompt: resolvedPrompt,
                attempt: 2
            ),
            try assignment(
                stage: .noteGeneration,
                providerKind: .bestEffortUnavailable,
                modelIdentifier: nil,
                prompt: resolvedPrompt,
                attempt: 3
            ),
            try assignment(
                stage: .noteGeneration,
                providerKind: .generativeAI,
                prompt: nil,
                attempt: 4
            ),
            try assignment(
                stage: .noteGeneration,
                providerKind: .generativeAI,
                prompt: CapturePromptSnapshot(
                    presetIdentifier: "meeting-summary",
                    resolvedPrompt: ""
                ),
                attempt: 5
            )
        ]
        for assignment in assignments {
            _ = try store.resolveAssignment(
                sessionID: handle.sessionID,
                stage: .noteGeneration,
                attempt: assignment.attempt,
                selecting: { assignment }
            )
            #expect(throws: CaptureSessionStoreError.invalidMeetingGeneratedNote(handle.sessionID)) {
                try store.meetingGeneratedNotePreflight(
                    handle,
                    assignmentAttempt: assignment.attempt
                )
            }
        }
    }

    @Test func generatedNoteCreationRejectsCancelledMeetingWithoutMutation() throws {
        let container = try makeContainer()
        let store = makeStore(in: container)
        let prepared = try generatedMeetingNoteInputs(
            in: container,
            store: store,
            startedAt: Date(timeIntervalSinceReferenceDate: 24_700)
        )
        try store.cancelMeetingCapture(prepared.handle)
        let beforeContext = ModelContext(container)
        let noteCountBefore = try beforeContext.fetch(FetchDescriptor<Note>()).count
        let referenceCountBefore = try beforeContext.fetch(
            FetchDescriptor<CaptureNoteReferenceModel>()
        )
        .filter { $0.sessionID == prepared.handle.sessionID }
        .count

        #expect(
            throws: CaptureSessionStoreError.meetingSessionNotFinalizing(
                sessionID: prepared.handle.sessionID,
                actualStateRawValue: CaptureSessionState.cancelled.rawValue
            )
        ) {
            try store.saveGeneratedMeetingNote(
                prepared.handle,
                title: "Generated summary",
                content: generatedMeetingNoteContent(),
                source: prepared.source
            )
        }

        let afterContext = ModelContext(container)
        #expect(try afterContext.fetch(FetchDescriptor<Note>()).count == noteCountBefore)
        #expect(
            try afterContext.fetch(FetchDescriptor<CaptureNoteReferenceModel>())
                .filter { $0.sessionID == prepared.handle.sessionID }
                .count == referenceCountBefore
        )
        #expect(try store.generatedMeetingNote(prepared.handle) == nil)
    }

    @Test func meetingHumanAnchorSurvivesInterruptedDiskBackedReopen() throws {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("pindrop-meeting-anchor-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directoryURL) }
        let storeURL = directoryURL.appendingPathComponent("capture.store")
        let expectedHandle: NoteCaptureHandle
        let expectedAnchorID: UUID

        do {
            let container = try PindropModelContainerFactory.makeContainer(at: storeURL)
            let store = makeStore(in: container)
            let handle = try store.startMeetingCapture()
            let anchor = try store.ensureMeetingHumanAnchor(handle, title: "Durable anchor")
            let context = ModelContext(container)
            let note = try #require(
                context.fetch(FetchDescriptor<Note>()).first { $0.id == anchor.noteID }
            )
            note.content = "User edit persists through interruption."
            try context.save()
            try store.interruptMeetingCapture(
                handle,
                errorDomain: "Test",
                message: "Interrupted for reopen coverage."
            )
            expectedHandle = handle
            expectedAnchorID = anchor.noteID
        }

        let reopenedContainer = try PindropModelContainerFactory.makeContainer(at: storeURL)
        let reopenedAnchorCandidate = try makeStore(in: reopenedContainer).meetingHumanAnchor(expectedHandle)
        let reopenedAnchor = try #require(reopenedAnchorCandidate)
        #expect(reopenedAnchor.noteID == expectedAnchorID)
        #expect(reopenedAnchor.content == "User edit persists through interruption.")
    }

    @Test func liveVoiceNoteCheckpointSurvivesDiskBackedReopen() throws {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("pindrop-live-voice-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directoryURL) }
        let storeURL = directoryURL.appendingPathComponent("capture.store")
        let startedAt = Date(timeIntervalSinceReferenceDate: 25_000)
        let expectedHandle: VoiceNoteCaptureHandle
        let expectedCheckpoint: VoiceNoteLiveTranscriptCheckpoint

        do {
            let container = try PindropModelContainerFactory.makeContainer(at: storeURL)
            let store = makeStore(in: container)
            let handle = try store.startVoiceNoteCapture(startedAt: startedAt)
            _ = try store.resolveAssignment(
                sessionID: handle.sessionID,
                stage: .liveTranscription,
                attempt: 1,
                selecting: { try assignment(stage: .liveTranscription) }
            )
            expectedHandle = handle
            expectedCheckpoint = try store.checkpointVoiceNoteLiveTranscript(
                for: handle,
                committedText: "Crash-surviving committed text",
                at: startedAt.addingTimeInterval(1)
            )
        }

        let reopenedContainer = try PindropModelContainerFactory.makeContainer(at: storeURL)
        let candidates = try makeStore(in: reopenedContainer).voiceNoteRecoveryCandidates()
        let recovered = try #require(
            candidates.first { $0.handle.sessionID == expectedHandle.sessionID }
        )
        #expect(recovered.handle.microphoneSourceID == expectedHandle.microphoneSourceID)
        #expect(recovered.handle.systemAudioSourceID == nil)
        #expect(recovered.latestLiveCheckpoint == expectedCheckpoint)
    }
}

/// The system-audio identifier of a fixture that was started with system audio.
///
/// Every fixture that reads this starts a dual-source capture, so a missing
/// identifier means the fixture itself is wrong.
private extension NoteCaptureHandle {
    var dualSourceSystemAudioID: UUID {
        guard let systemAudioSourceID else {
            preconditionFailure("This capture fixture must own a system-audio source.")
        }
        return systemAudioSourceID
    }
}
