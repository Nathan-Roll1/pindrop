//
//  CaptureIntentPersistenceTests.swift
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
struct CaptureIntentPersistenceTests {
    private func makeContainer() throws -> ModelContainer {
        try PindropModelContainerFactory.makeInMemoryContainer()
    }

    private func makeStore(in container: ModelContainer) -> CaptureSessionStore {
        CaptureSessionStore(modelContext: ModelContext(container))
    }

    private func intents(in container: ModelContainer) throws -> [CaptureIntentModel] {
        try ModelContext(container).fetch(FetchDescriptor<CaptureIntentModel>())
    }

    private func sessions(in container: ModelContainer) throws -> [CaptureSessionModel] {
        try ModelContext(container).fetch(FetchDescriptor<CaptureSessionModel>())
    }

    private func sources(in container: ModelContainer) throws -> [CaptureSourceModel] {
        try ModelContext(container).fetch(FetchDescriptor<CaptureSourceModel>())
    }

    // MARK: - Written with the session

    @Test func micOnlyNoteCaptureWritesItsIntentWithTheSession() throws {
        let container = try makeContainer()
        let store = makeStore(in: container)
        let startedAt = Date(timeIntervalSinceReferenceDate: 9_100)
        let noteID = UUID()

        let handle = try store.startNoteCapture(
            startedAt: startedAt,
            includeSystemAudio: false,
            intent: CaptureIntentRequest(
                destination: .existingNote,
                destinationNoteID: noteID,
                requestedTemplatePresetIdentifier: "meeting-summary",
                origin: .hotkey
            )
        )

        let intent = try #require(try store.fetchCaptureIntent(sessionID: handle.sessionID))
        #expect(intent.sessionID == handle.sessionID)
        #expect(intent.destination == .existingNote)
        #expect(intent.destinationNoteID == noteID)
        #expect(intent.requestedSourceKinds == [.microphone])
        #expect(intent.requestsSystemAudio == false)
        #expect(intent.requestedTemplatePresetIdentifier == "meeting-summary")
        #expect(intent.origin == .hotkey)
        #expect(intent.createdAt == startedAt)
        #expect(try intents(in: container).count == 1)
    }

    @Test func noteCaptureWithSystemAudioRecordsBothRequestedSourceKinds() throws {
        let container = try makeContainer()
        let store = makeStore(in: container)
        let startedAt = Date(timeIntervalSinceReferenceDate: 9_110)

        let handle = try store.startNoteCapture(
            startedAt: startedAt,
            includeSystemAudio: true,
            intent: CaptureIntentRequest(destination: .newNote, origin: .menuBar)
        )

        let intent = try #require(try store.fetchCaptureIntent(sessionID: handle.sessionID))
        // The recorded kinds are exactly the source rows the same call created.
        #expect(intent.requestedSourceKinds == [.microphone, .systemAudio])
        #expect(intent.requestsSystemAudio)
        #expect(intent.destination == .newNote)
        #expect(intent.destinationNoteID == nil)
        #expect(intent.origin == .menuBar)

        let sourceKinds = try sources(in: container)
            .filter { $0.sessionID == handle.sessionID }
            .sorted { $0.sequence < $1.sequence }
            .map(\.kindRawValue)
        #expect(sourceKinds == intent.requestedSourceKinds.map(\.rawValue))
    }

    @Test func transcriptOnlyIntentIsRecordedWithoutADestinationNote() throws {
        let container = try makeContainer()
        let store = makeStore(in: container)

        let handle = try store.startNoteCapture(
            startedAt: Date(timeIntervalSinceReferenceDate: 9_120),
            includeSystemAudio: false,
            intent: CaptureIntentRequest(destination: .transcriptOnly, origin: .automation)
        )

        let intent = try #require(try store.fetchCaptureIntent(sessionID: handle.sessionID))
        #expect(intent.destination == .transcriptOnly)
        #expect(intent.destinationNoteID == nil)
        #expect(intent.origin == .automation)
    }

    // MARK: - Validation

    @Test func existingNoteIntentWithoutANoteFailsTheStartAndWritesNothing() throws {
        let container = try makeContainer()
        let store = makeStore(in: container)

        #expect(
            throws: CaptureSessionStoreError.invalidCaptureIntent(.missingDestinationNote)
        ) {
            try store.startNoteCapture(
                startedAt: Date(timeIntervalSinceReferenceDate: 9_130),
                includeSystemAudio: false,
                intent: CaptureIntentRequest(destination: .existingNote, origin: .mainWindow)
            )
        }

        // The session never started, so nothing is left half-written.
        #expect(try sessions(in: container).isEmpty)
        #expect(try sources(in: container).isEmpty)
        #expect(try intents(in: container).isEmpty)
    }

    @Test func newNoteIntentNamingANoteFailsTheStart() throws {
        let container = try makeContainer()
        let store = makeStore(in: container)

        #expect(
            throws: CaptureSessionStoreError.invalidCaptureIntent(
                .unexpectedDestinationNote(.newNote)
            )
        ) {
            try store.startNoteCapture(
                startedAt: Date(timeIntervalSinceReferenceDate: 9_140),
                includeSystemAudio: true,
                intent: CaptureIntentRequest(
                    destination: .newNote,
                    destinationNoteID: UUID(),
                    origin: .mainWindow
                )
            )
        }

        #expect(try sessions(in: container).isEmpty)
        #expect(try sources(in: container).isEmpty)
        #expect(try intents(in: container).isEmpty)
    }

    // MARK: - Binding the destination note

    @Test func updateIntentDestinationBindsANewNoteIntentToItsNote() throws {
        let container = try makeContainer()
        let store = makeStore(in: container)
        let handle = try store.startNoteCapture(
            startedAt: Date(timeIntervalSinceReferenceDate: 9_150),
            includeSystemAudio: false,
            intent: CaptureIntentRequest(destination: .newNote, origin: .mainWindow)
        )
        let noteID = UUID()

        try store.updateIntentDestination(sessionID: handle.sessionID, noteID: noteID)

        let bound = try #require(try store.fetchCaptureIntent(sessionID: handle.sessionID))
        #expect(bound.destination == .existingNote)
        #expect(bound.destinationNoteID == noteID)
        #expect(bound.requestedSourceKinds == [.microphone])
        #expect(bound.origin == .mainWindow)

        // Repeating the bind with the same note is a no-op.
        try store.updateIntentDestination(sessionID: handle.sessionID, noteID: noteID)
        let rebound = try #require(try store.fetchCaptureIntent(sessionID: handle.sessionID))
        #expect(rebound == bound)
        #expect(try intents(in: container).count == 1)
    }

    @Test func updateIntentDestinationRejectsADifferentNote() throws {
        let container = try makeContainer()
        let store = makeStore(in: container)
        let handle = try store.startNoteCapture(
            startedAt: Date(timeIntervalSinceReferenceDate: 9_160),
            includeSystemAudio: false,
            intent: CaptureIntentRequest(destination: .newNote, origin: .mainWindow)
        )
        let noteID = UUID()
        let otherNoteID = UUID()
        try store.updateIntentDestination(sessionID: handle.sessionID, noteID: noteID)

        #expect(
            throws: CaptureSessionStoreError.captureIntentDestinationConflict(
                sessionID: handle.sessionID,
                requestedNoteID: otherNoteID
            )
        ) {
            try store.updateIntentDestination(sessionID: handle.sessionID, noteID: otherNoteID)
        }
        #expect(try store.fetchCaptureIntent(sessionID: handle.sessionID)?.destinationNoteID == noteID)
    }

    @Test func updateIntentDestinationRejectsATranscriptOnlyIntent() throws {
        let container = try makeContainer()
        let store = makeStore(in: container)
        let handle = try store.startNoteCapture(
            startedAt: Date(timeIntervalSinceReferenceDate: 9_170),
            includeSystemAudio: false,
            intent: CaptureIntentRequest(destination: .transcriptOnly, origin: .mainWindow)
        )
        let noteID = UUID()

        #expect(
            throws: CaptureSessionStoreError.captureIntentDestinationConflict(
                sessionID: handle.sessionID,
                requestedNoteID: noteID
            )
        ) {
            try store.updateIntentDestination(sessionID: handle.sessionID, noteID: noteID)
        }
        #expect(try store.fetchCaptureIntent(sessionID: handle.sessionID)?.destination == .transcriptOnly)
    }

    @Test func updateIntentDestinationReportsASessionWithoutAnIntent() throws {
        let container = try makeContainer()
        let store = makeStore(in: container)
        let legacy = try store.startVoiceNoteCapture(
            startedAt: Date(timeIntervalSinceReferenceDate: 9_180)
        )

        #expect(throws: CaptureSessionStoreError.captureIntentNotFound(legacy.sessionID)) {
            try store.updateIntentDestination(sessionID: legacy.sessionID, noteID: UUID())
        }
    }

    // MARK: - Recovery snapshots

    @Test func recoveryCandidatesCarryTheirIntent() throws {
        let container = try makeContainer()
        let store = makeStore(in: container)
        let startedAt = Date(timeIntervalSinceReferenceDate: 9_190)
        let noteID = UUID()
        let handle = try store.startNoteCapture(
            startedAt: startedAt,
            includeSystemAudio: true,
            intent: CaptureIntentRequest(
                destination: .existingNote,
                destinationNoteID: noteID,
                requestedTemplatePresetIdentifier: "standup",
                origin: .menuBar
            )
        )

        let candidate = try #require(
            try store.noteCaptureRecoveryCandidates()
                .first { $0.handle.sessionID == handle.sessionID }
        )
        let intent = try #require(candidate.intent)
        #expect(intent.sessionID == handle.sessionID)
        #expect(intent.destination == .existingNote)
        #expect(intent.destinationNoteID == noteID)
        #expect(intent.requestedSourceKinds == [.microphone, .systemAudio])
        #expect(intent.requestedTemplatePresetIdentifier == "standup")
        #expect(intent.origin == .menuBar)
        #expect(intent == (try store.fetchCaptureIntent(sessionID: handle.sessionID)))
    }

    @Test func recoveryCandidatesReportNoIntentForLegacySessions() throws {
        let container = try makeContainer()
        let store = makeStore(in: container)
        let startedAt = Date(timeIntervalSinceReferenceDate: 9_200)
        let legacyVoiceNote = try store.startVoiceNoteCapture(startedAt: startedAt)
        let legacyMeeting = try store.startMeetingCapture(
            startedAt: startedAt.addingTimeInterval(1)
        )
        let noteCapture = try store.startNoteCapture(
            startedAt: startedAt.addingTimeInterval(2),
            includeSystemAudio: false,
            intent: CaptureIntentRequest(destination: .newNote, origin: .mainWindow)
        )

        let bySessionID = Dictionary(
            uniqueKeysWithValues: try store.noteCaptureRecoveryCandidates()
                .map { ($0.handle.sessionID, $0) }
        )
        #expect(bySessionID[legacyVoiceNote.sessionID]?.intent == nil)
        #expect(bySessionID[legacyMeeting.sessionID]?.intent == nil)
        #expect(bySessionID[noteCapture.sessionID]?.intent?.destination == .newNote)
        #expect(try store.fetchCaptureIntent(sessionID: legacyVoiceNote.sessionID) == nil)
        #expect(try store.fetchCaptureIntent(sessionID: legacyMeeting.sessionID) == nil)
    }

    @Test func recoveryCandidatesReflectABoundDestination() throws {
        let container = try makeContainer()
        let store = makeStore(in: container)
        let handle = try store.startNoteCapture(
            startedAt: Date(timeIntervalSinceReferenceDate: 9_210),
            includeSystemAudio: false,
            intent: CaptureIntentRequest(destination: .newNote, origin: .hotkey)
        )
        let noteID = UUID()
        try store.updateIntentDestination(sessionID: handle.sessionID, noteID: noteID)

        let candidate = try #require(
            try store.noteCaptureRecoveryCandidates()
                .first { $0.handle.sessionID == handle.sessionID }
        )
        #expect(candidate.intent?.destination == .existingNote)
        #expect(candidate.intent?.destinationNoteID == noteID)
    }
}
