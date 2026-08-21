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
}
