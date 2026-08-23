//
//  LocalizationKeyResolutionTests.swift
//  PindropTests
//
//  Created on 2026-08-22.
//
//  `localized("English text")` resolves through generated metadata: an exact
//  source-string match first, then a slug of the text. The slug step is where
//  strings collide: "edited" slugs onto the "Edited" stat label, "Delete Note"
//  onto the "Delete note?" dialog title, "Current" onto "Current: %@".
//
//  These tests pin the resolution for the strings the notes surfaces call, so a
//  key removed from the YAML source shows up here as a wrong English string
//  rather than as wrong words on screen.
//

import Foundation
import Testing
@testable import Pindrop

@Suite
struct LocalizationKeyResolutionTests {

    private let en = Locale(identifier: "en")

    /// Every source string on the notes surfaces has to come back as itself in
    /// English. Anything else means the slug fallback caught a neighbour.
    @Test(arguments: [
        // The two collisions WP3 reported.
        "Delete Note",
        "edited %@",
        // Their neighbours, so a fix that swaps the two is still caught.
        "Delete note?",
        "Edited",
        // Notes list.
        "Notes",
        "Note",
        "Voice note",
        "Meeting note",
        "Enhanced",
        "Pinned",
        "Recording",
        "New note",
        "New note with system audio",
        "New note without recording",
        "No notes yet.",
        "Click New note to start one. Pindrop records while you type.",
        // Note page chrome.
        "Back to notes",
        "Record",
        "Record with system audio",
        "More recording options",
        "More note actions",
        "Open in new window",
        "Cancel recording",
        "Delete transcript",
        "Delete this note",
        "Save now (⌘S)",
        "⌘S to save",
        // Capture dock.
        "Finish",
        "Live transcript",
        "Show live transcript",
        "Hide live transcript",
        "Jump to live",
        "Mic",
        "System audio",
        "On",
        "Off",
        "Sources are fixed when the recording starts.",
        // Finalizing stages.
        "Sealing audio",
        "Transcribing",
        "Identifying speakers",
        "Writing note",
        // Enhanced view.
        "Enhanced note",
        "No enhanced note yet.",
        "Try again",
        "Templates",
        "Manage templates…",
        "Was this note useful?",
        "Helpful",
        "Not helpful",
        // Transcript view.
        "Transcript",
        "Find in transcript",
        "Jump to this line",
        "Playback position",
        "You",
        "Speaker",
        // Dictate page.
        "No dictations yet.",
        "Stop"
    ])
    func sourceStringsResolveToThemselvesInEnglish(_ source: String) {
        #expect(localized(source, locale: en) == source)
    }

    /// The lowercase running copy and the capitalised stat label are two strings,
    /// and the footer that used `localized("edited")` got the wrong one.
    @Test func editedLabelUsesTheRunningCopyNotTheStatLabel() {
        let now = Date(timeIntervalSinceReferenceDate: 0)
        let label = NotesDateFormatting.editedLabel(
            date: now.addingTimeInterval(-30),
            now: now,
            locale: en
        )
        #expect(label == "edited just now")
        #expect(label != "Edited just now")
    }
}
