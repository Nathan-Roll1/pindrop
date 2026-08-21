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
            finalTranscriptRevisionID: revisions.finalRevisionID,
            at: startedAt.addingTimeInterval(4)
        )

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
        #expect(reference.sourceTranscriptRevisionID == revisions.finalRevisionID)
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
        context.insert(wrongStageFinal)
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
        #expect(throws: CaptureSessionStoreError.invalidFinalTranscriptRevision(wrongStageFinal.id)) {
            try store.complete(
                handle,
                noteID: note.id,
                finalTranscriptRevisionID: wrongStageFinal.id,
                at: startedAt.addingTimeInterval(2)
            )
        }
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
                retained(handle.systemAudioSourceID, sessionID: handle.sessionID)
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
                Set([handle.microphoneSourceID, handle.systemAudioSourceID])
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
            failures: [failed(handle.systemAudioSourceID, at: startedAt.addingTimeInterval(2))],
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
        #expect(failures.filter { $0.sessionID == handle.sessionID }.map(\.sourceID) == [handle.systemAudioSourceID])
        #expect(sourceStates[handle.microphoneSourceID] == CaptureSourceState.completed.rawValue)
        #expect(sourceStates[handle.systemAudioSourceID] == CaptureSourceState.failed.rawValue)
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
            retained: [retained(handle.systemAudioSourceID, sessionID: handle.sessionID)],
            failures: [failed(handle.microphoneSourceID, at: startedAt.addingTimeInterval(2))],
            at: startedAt.addingTimeInterval(3)
        )

        let context = ModelContext(container)
        let session = try #require(
            context.fetch(FetchDescriptor<CaptureSessionModel>()).first { $0.id == handle.sessionID }
        )
        let chunks = try context.fetch(FetchDescriptor<CaptureChunkModel>())
        let failures = try context.fetch(FetchDescriptor<CaptureFailureRecordModel>())
        #expect(chunks.filter { $0.sessionID == handle.sessionID }.map(\.sourceID) == [handle.systemAudioSourceID])
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
                failed(handle.systemAudioSourceID, at: startedAt.addingTimeInterval(3), message: "System audio failed.")
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
        #expect(throws: CaptureSessionStoreError.meetingSourceOutcomeMissing(handle.systemAudioSourceID)) {
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
        let crossSession = MeetingCaptureHandle(
            sessionID: first.sessionID,
            microphoneSourceID: first.microphoneSourceID,
            systemAudioSourceID: second.systemAudioSourceID
        )
        let wrongKind = MeetingCaptureHandle(
            sessionID: first.sessionID,
            microphoneSourceID: first.systemAudioSourceID,
            systemAudioSourceID: first.systemAudioSourceID
        )

        #expect(
            throws: CaptureSessionStoreError.sourceSessionMismatch(
                sourceID: second.systemAudioSourceID,
                expectedSessionID: first.sessionID,
                actualSessionID: second.sessionID
            )
        ) {
            try store.beginMeetingFinalization(crossSession, at: startedAt.addingTimeInterval(1))
        }
        #expect(
            throws: CaptureSessionStoreError.sourceKindMismatch(
                sourceID: first.systemAudioSourceID,
                expected: .microphone,
                actualRawValue: CaptureSourceKind.systemAudio.rawValue
            )
        ) {
            try store.beginMeetingFinalization(wrongKind, at: startedAt.addingTimeInterval(1))
        }
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
            failures: [failed(handle.systemAudioSourceID, at: startedAt.addingTimeInterval(2))],
            at: startedAt.addingTimeInterval(3)
        )
        let history = try HistoryStore(modelContext: ModelContext(container)).save(
            text: "Meeting transcript",
            originalText: "Meeting transcript",
            duration: 2,
            modelUsed: "meeting"
        )
        #expect(throws: CaptureSessionStoreError.meetingCaptureHasNoFinalTranscript(handle.sessionID)) {
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
                            sourceID: handle.systemAudioSourceID,
                            chunkSequence: 0
                        )
                    )
                ],
                failures: [failed(handle.systemAudioSourceID, at: startedAt.addingTimeInterval(2))],
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
            failures: [failed(handle.systemAudioSourceID, at: startedAt.addingTimeInterval(2))],
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
                    handle.systemAudioSourceID: CaptureSourceState.failed.rawValue
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
            failures: [failed(handle.systemAudioSourceID, at: startedAt.addingTimeInterval(2))],
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
                failed(handle.systemAudioSourceID, at: startedAt.addingTimeInterval(21))
            ],
            at: startedAt.addingTimeInterval(22)
        )
        _ = try store.recordMeetingTranscriptionChunk(
            handle,
            sourceChunkSequence: 17,
            startOffset: 5_100,
            duration: 300,
            text: "Final ninety-minute chunk",
            at: startedAt.addingTimeInterval(23)
        )
        let plan = try store.makeMeetingFinalizationPlan(handle)
        #expect(plan.sourceChunks.count == 18)
        #expect(plan.sourceChunks.map(\.sequence) == Array(0..<18))
        #expect(plan.completedASRSequences == [17])

        let history = try HistoryStore(modelContext: ModelContext(container)).save(
            text: "Final ninety-minute chunk",
            originalText: "Final ninety-minute chunk",
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
            handle.systemAudioSourceID,
            sessionID: handle.sessionID,
            sequence: 0,
            sealedAt: startedAt.addingTimeInterval(1)
        )
        let lostSource = recoveryFailure(
            handle.systemAudioSourceID,
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
        #expect(failures[0].sourceID == handle.systemAudioSourceID)
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
            handle.systemAudioSourceID,
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
                    "\(handle.systemAudioSourceID.uuidString):0"
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
            handle.systemAudioSourceID,
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
            handle.systemAudioSourceID,
            sessionID: handle.sessionID,
            sequence: 0,
            sealedAt: startedAt.addingTimeInterval(2)
        )
        try store.reconcileMeetingChunks(handle, checkpoints: [microphone, systemAudio], failures: [])

        try store.finishMeetingSources(
            handle,
            sourceFailures: [
                failed(handle.systemAudioSourceID, at: startedAt.addingTimeInterval(3))
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
            sources.first { $0.id == handle.systemAudioSourceID }?.stateRawValue ==
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
            handle.systemAudioSourceID,
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

        _ = try store.recordMeetingTranscriptionChunk(
            handle,
            sourceChunkSequence: 1,
            startOffset: second.startOffset,
            duration: second.duration,
            text: "Second completed chunk",
            segmentsJSON: #"[{"speaker":"speaker-2","start":0,"end":300,"text":"Second completed chunk"}]"#,
            languageCode: "fr-CA"
        )
        _ = try store.recordMeetingTranscriptionChunk(
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
                sequence: 0,
                startOffset: first.startOffset,
                duration: first.duration,
                text: "First completed chunk",
                segmentsJSON: #"[{"speaker":"speaker-1","start":0,"end":300,"text":"First completed chunk"}]"#,
                languageCode: "en-US"
            ),
            MeetingTranscriptionCheckpoint(
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
}
