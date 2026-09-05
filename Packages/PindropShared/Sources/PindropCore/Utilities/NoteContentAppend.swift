//
//  NoteContentAppend.swift
//  PindropCore
//
//  Created on 2026-07-09.
//

import Foundation

/// Pure helpers for speak-to-append into an open note.
public enum NoteContentAppend {
    /// Appends a transcript at the end of existing note content.
    /// Inserts a separating space when the content does not already end in whitespace.
    public static func append(transcript: String, to content: String) -> String {
        let trimmedTranscript = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTranscript.isEmpty else { return content }

        if content.isEmpty {
            return trimmedTranscript
        }

        if let last = content.last, last.isWhitespace || last.isNewline {
            return content + trimmedTranscript
        }

        return content + " " + trimmedTranscript
    }
}

/// Gate checks that keep note-append capture and global dictation mutually exclusive.
public enum NoteAppendGate {
    /// Whether the note editor may start a speak-to-append session.
    public static func canStartNoteAppend(isRecording: Bool, isProcessing: Bool) -> Bool {
        !isRecording && !isProcessing
    }

    /// Whether global dictation / quick-capture may start while a note is listening.
    public static func canStartGlobalDictation(isNoteAppendListening: Bool) -> Bool {
        !isNoteAppendListening
    }
}
