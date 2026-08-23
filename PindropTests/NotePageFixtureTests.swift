//
//  NotePageFixtureTests.swift
//  PindropTests
//
//  Created on 2026-08-22.
//
//  The `notePage` UI-test surface builds its store by hand. UI tests cannot run
//  on a developer machine, and a seeding failure there is a `fatalError` at app
//  launch, so the seed is proved here instead: the fixture has to produce all
//  three views the note page draws.
//

import Foundation
import PindropData
import SwiftData
import Testing
@testable import Pindrop

@MainActor
@Suite
struct NotePageFixtureTests {

    @Test func notePageFixtureSeedsAllThreeViews() throws {
        let fixture = try RecordedNoteFixture.seedNotePage()
        let store = CaptureSessionStore(modelContext: ModelContext(fixture.container))
        let views = try store.noteCaptureViews(noteID: fixture.noteID)

        // My notes: the typed content the person would have written.
        #expect(views.typedNotes?.content == RecordedNoteFixture.typedContent)

        // Enhanced: exactly one panel, from the named template, with citations
        // resolved from the transcript behind it.
        #expect(views.panels.count == 1)
        let panel = try #require(views.panels.first)
        #expect(panel.templatePresetIdentifier == RecordedNoteFixture.notePageTemplateIdentifier)
        #expect(panel.templateDisplayName == RecordedNoteFixture.notePageTemplateDisplayName)
        #expect(panel.content == RecordedNoteFixture.notePagePanelContent)

        // Transcript: a finished one, so the page offers the Transcript segment.
        let transcript = try #require(views.transcript)
        #expect(!transcript.isLive)
        #expect(transcript.plainText.contains("publish the final report on Friday"))
        // Two speakers, so the transcript view draws real speaker turns.
        #expect(transcript.speakerCount == 2)

        // A capture ran, which is what puts the page in its recorded shape.
        #expect(views.isRecorded)
        #expect(!views.isTranscriptDeleted)
    }

    /// Each call seeds its own in-memory store, so two fixtures never share
    /// state and a UI test can never read another run's note.
    @Test func eachSeedIsIndependent() throws {
        let first = try RecordedNoteFixture.seedNotePage()
        let second = try RecordedNoteFixture.seedNotePage()
        #expect(first.noteID != second.noteID)
    }
}
