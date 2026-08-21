//
//  NoteAppendListeningState.swift
//  Pindrop
//
//  Created on 2026-07-09.
//

import Foundation
import Combine
import PindropData

/// Published listening state for speak-to-append in the note editor.
/// Mirrors the FloatingIndicatorState recording/elapsed pattern without driving the global indicator UI.
@MainActor
final class NoteAppendListeningState: ObservableObject {
    @Published private(set) var isListening = false
    @Published private(set) var isProcessing = false
    @Published private(set) var elapsed: TimeInterval = 0
    /// Editor instance that started the session; committed appends are delivered only to this editor.
    @Published private(set) var activeEditorID: UUID?
    /// Durable note that owns the session; prevents a committed append targeting a reused editor.
    @Published private(set) var activeNoteID: UUID?

    private var listeningStartTime: Date?
    private var durationTimer: Timer?

    func startListening(editorID: UUID, noteID: UUID) {
        activeEditorID = editorID
        activeNoteID = noteID
        isListening = true
        isProcessing = false
        listeningStartTime = Date()
        elapsed = 0
        startDurationTimer()
    }

    func transitionToProcessing() {
        isListening = false
        isProcessing = true
        stopDurationTimer()
    }

    func finishSession() {
        isListening = false
        isProcessing = false
        elapsed = 0
        activeEditorID = nil
        activeNoteID = nil
        listeningStartTime = nil
        stopDurationTimer()
    }

    private func startDurationTimer() {
        stopDurationTimer()
        durationTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let start = self.listeningStartTime else { return }
                self.elapsed = Date().timeIntervalSince(start)
            }
        }
    }

    private func stopDurationTimer() {
        durationTimer?.invalidate()
        durationTimer = nil
    }
}

/// Editor-local ownership retained from the synchronous Start request until
/// durable delivery or the globally-owned session finishes.
struct NoteAppendEditorRequestState {
    private(set) var requestedNoteID: UUID?

    mutating func requestStart(noteID: UUID) {
        requestedNoteID = noteID
    }

    func isLocked(for noteID: UUID?) -> Bool {
        requestedNoteID != nil && requestedNoteID == noteID
    }

    mutating func clearAfterCommittedDelivery(noteID: UUID) {
        guard requestedNoteID == noteID else { return }
        requestedNoteID = nil
    }

    mutating func clearAfterStartRejected(noteID: UUID) {
        guard requestedNoteID == noteID else { return }
        requestedNoteID = nil
    }

    mutating func clearAfterSessionFinishes(
        isListening: Bool,
        isProcessing: Bool,
        activeEditorID: UUID?,
        activeNoteID: UUID?
    ) {
        guard !isListening,
              !isProcessing,
              activeEditorID == nil,
              activeNoteID == nil
        else {
            return
        }

        requestedNoteID = nil
    }
}

/// Typed committed speak-to-append payload decoded by the receiving editor.
struct NoteAppendCommittedPayload {
    let editorID: UUID
    let noteID: UUID
    let content: String
    let sourceTranscriptionID: UUID

    init?(notification: Notification) {
        guard let userInfo = notification.userInfo,
              let editorID = userInfo["editorID"] as? UUID,
              let noteID = userInfo["noteID"] as? UUID,
              let content = userInfo["content"] as? String,
              let sourceTranscriptionID = userInfo["sourceTranscriptionID"] as? UUID
        else {
            return nil
        }

        self.editorID = editorID
        self.noteID = noteID
        self.content = content
        self.sourceTranscriptionID = sourceTranscriptionID
    }

    private func belongs(to editorID: UUID, noteID: UUID) -> Bool {
        self.editorID == editorID && self.noteID == noteID
    }

    /// Replaces the editor draft only when this committed payload belongs to its durable note.
    @discardableResult
    func apply(to note: NoteSchema.Note, for editorID: UUID) -> Bool {
        guard belongs(to: editorID, noteID: note.id) else { return false }

        note.content = content
        note.sourceTranscriptionID = sourceTranscriptionID
        return true
    }
}

/// Typed rejected speak-to-append start acknowledgement decoded by the requesting editor.
struct NoteAppendRejectedPayload {
    let editorID: UUID
    let noteID: UUID

    init?(notification: Notification) {
        guard let userInfo = notification.userInfo,
              let editorID = userInfo["editorID"] as? UUID,
              let noteID = userInfo["noteID"] as? UUID
        else {
            return nil
        }

        self.editorID = editorID
        self.noteID = noteID
    }

    func matches(editorID: UUID, noteID: UUID) -> Bool {
        self.editorID == editorID && self.noteID == noteID
    }
}

extension Notification.Name {
    /// Posted by the note editor to request start/stop of speak-to-append.
    /// Both actions carry `editorID` (UUID), `noteID` (UUID), and `action`
    /// (`"start"` or `"stop"`).
    static let noteSpeakToAppendRequest = Notification.Name("noteSpeakToAppendRequest")
    /// Posted by AppCoordinator after a durable speak-to-append transcript commit.
    /// `userInfo`: `editorID` (UUID), `noteID` (UUID), `content` (String),
    /// `sourceTranscriptionID` (UUID).
    static let noteSpeakToAppendTranscript = Notification.Name("noteSpeakToAppendTranscript")
    /// Posted by AppCoordinator when a requested speak-to-append Start is rejected.
    /// `userInfo`: `editorID` (UUID), `noteID` (UUID).
    static let noteSpeakToAppendRejected = Notification.Name("noteSpeakToAppendRejected")
}
