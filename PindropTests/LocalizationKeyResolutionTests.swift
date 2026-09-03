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
        "Stop",
        // Live attribution.
        "Call audio",
        "Someone else spoke here. The finished note has it.",
        "You spoke here. The finished note has it.",
        "%1$@ said: %2$@",
        "Still hearing: %@",
        "was %@",
        "%1$@ is now %2$@.",
        "Pindrop is transcribing only your microphone. The call audio is in the finished note.",
        // Live speaker names.
        "Live speaker names need the speaker model. Download it to name people while you record.",
        "The live speaker model could not be loaded. Recording continues, and the finished note still names everyone.",
        "Live names cover up to four voices.",
        "Live speaker names paused.",
        "Pindrop checks the speakers again when the recording ends.",
        "Speaker names were checked again against the full recording.",
        "Name speakers while recording",
        "Show who is talking in the live transcript. Names are checked again when the recording ends.",
        // Meeting entry points.
        "Record this call",
        "New meeting note",
        "A call started",
        "Record it as a note?",
        "Not now",
        "Meetings",
        "Watch for calls",
        "Show a way to record when a meeting app opens your microphone.",
        "Notify me when a call starts",
        "Notifications are turned off for Pindrop. Turn them on in System Settings to be asked about calls.",
        "Record system audio in meeting notes",
        "Pindrop noticed a call.",
        "Do you want a notification when a call starts?",
        "Notify me",
        "No thanks",
        // Template picker. "Template" slugs onto the same key as the shipped
        // "Template: %@" chip, which is the collision class this suite exists
        // for, so it is pinned from the day the string is called.
        "Template",
        "No template. The note is written as plain notes."
    ])
    func sourceStringsResolveToThemselvesInEnglish(_ source: String) {
        #expect(localized(source, locale: en) == source)
    }

    /// The live attribution copy names a channel and a gap in the live text, and
    /// the meeting copy names a call and asks a question, so a reader who does
    /// not read English learns nothing from the untranslated source. `localized`
    /// falls back to the English key when a locale lacks the string, which makes
    /// a missing translation invisible on screen and visible only here.
    @Test(arguments: LocalizationMetadata.supportedLocales.filter { $0 != "en" })
    func liveAttributionStringsAreTranslatedInEveryLocale(_ identifier: String) {
        let locale = Locale(identifier: identifier)

        for source in Self.liveAttributionSources {
            #expect(
                localized(source, locale: locale) != source,
                "\(identifier) still reads the English source for \(source)"
            )
        }
    }

    private static let liveAttributionSources = [
        "Call audio",
        "Someone else spoke here. The finished note has it.",
        "You spoke here. The finished note has it.",
        "%1$@ said: %2$@",
        "Still hearing: %@",
        "was %@",
        "%1$@ is now %2$@.",
        "Pindrop is transcribing only your microphone. The call audio is in the finished note.",
        "Live speaker names need the speaker model. Download it to name people while you record.",
        "The live speaker model could not be loaded. Recording continues, and the finished note still names everyone.",
        "Live names cover up to four voices.",
        "Live speaker names paused.",
        "Pindrop checks the speakers again when the recording ends.",
        "Speaker names were checked again against the full recording.",
        "Name speakers while recording",
        "Show who is talking in the live transcript. Names are checked again when the recording ends.",
        // Meeting entry points. "Meetings" is left out on purpose: German keeps
        // the English word, so an equality check would call a correct
        // translation a miss.
        "Record this call",
        "New meeting note",
        "A call started",
        "Record it as a note?",
        "Not now",
        "Watch for calls",
        "Show a way to record when a meeting app opens your microphone.",
        "Notify me when a call starts",
        "Notifications are turned off for Pindrop. Turn them on in System Settings to be asked about calls.",
        "Record system audio in meeting notes",
        "Pindrop noticed a call.",
        "Do you want a notification when a call starts?",
        "Notify me",
        "No thanks"
    ]

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
