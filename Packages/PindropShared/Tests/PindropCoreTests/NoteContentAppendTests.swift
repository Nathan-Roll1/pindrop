//
//  NoteContentAppendTests.swift
//  PindropCoreTests
//
//  Created on 2026-07-09.
//

import Foundation
import Testing
import PindropCore

@Suite("NoteContentAppend")
struct NoteContentAppendTests {
    @Test func appendsToEmptyContent() {
        #expect(NoteContentAppend.append(transcript: "hello", to: "") == "hello")
        #expect(NoteContentAppend.append(transcript: "  hello  ", to: "") == "hello")
    }

    @Test func appendsWithSpaceWhenNeeded() {
        #expect(NoteContentAppend.append(transcript: "world", to: "hello") == "hello world")
    }

    @Test func appendsDirectlyAfterWhitespace() {
        #expect(NoteContentAppend.append(transcript: "world", to: "hello ") == "hello world")
        #expect(NoteContentAppend.append(transcript: "world", to: "hello\n") == "hello\nworld")
    }

    @Test func ignoresEmptyTranscript() {
        #expect(NoteContentAppend.append(transcript: "   ", to: "keep") == "keep")
        #expect(NoteContentAppend.append(transcript: "", to: "keep") == "keep")
    }
}

@Suite("NoteAppendGate")
struct NoteAppendGateTests {
    @Test func refusesNoteAppendWhenGlobalDictationActive() {
        #expect(NoteAppendGate.canStartNoteAppend(isRecording: true, isProcessing: false) == false)
        #expect(NoteAppendGate.canStartNoteAppend(isRecording: false, isProcessing: true) == false)
        #expect(NoteAppendGate.canStartNoteAppend(isRecording: false, isProcessing: false) == true)
    }

    @Test func refusesGlobalDictationWhenNoteAppendActive() {
        #expect(NoteAppendGate.canStartGlobalDictation(isNoteAppendListening: true) == false)
        #expect(NoteAppendGate.canStartGlobalDictation(isNoteAppendListening: false) == true)
    }
}
