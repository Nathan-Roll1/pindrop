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
            byteCount: 64_000,
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
        let missingHistoryID = UUID()
        #expect(throws: CaptureSessionStoreError.transcriptionRecordNotFound(missingHistoryID)) {
            try store.completeMeetingCapture(
                handle,
                transcriptionRecordID: missingHistoryID,
                at: startedAt.addingTimeInterval(4)
            )
        }
        let history = try HistoryStore(modelContext: ModelContext(container)).save(
            text: "Meeting transcript",
            originalText: "Meeting transcript",
            duration: 2,
            modelUsed: "meeting"
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
}
