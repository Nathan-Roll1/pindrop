//
//  CaptureNoteViews.swift
//  PindropCore
//
//  Created on 2026-08-22.
//
//  The three views of a note that records, read as one value.
//
//  A note page never asks four questions to draw itself. It asks once and gets
//  the notes the person typed, the generated panels, the transcript, and the
//  capture behind them. Every type here is plain data: no store, no view, no
//  formatting decisions.
//

import Foundation

/// The notes a person typed into one note.
public struct TypedNotesSnapshot: Sendable, Equatable, Identifiable {
    /// The note identifier. It is the identity of the whole note, not of this
    /// projection, so the three views of one note all agree on it.
    public let id: UUID
    public let title: String
    public let content: String
    public let createdAt: Date
    public let updatedAt: Date

    public init(
        id: UUID,
        title: String,
        content: String,
        createdAt: Date,
        updatedAt: Date
    ) {
        self.id = id
        self.title = title
        self.content = content
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    /// True while the person has written nothing. A recorded note is created
    /// before its first keystroke, so an empty body is a normal state.
    public var isEmpty: Bool {
        content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

/// One attributed span of a transcript.
///
/// A span is either one diarized speaker turn or, when the capture produced no
/// usable diarization, one whole transcript revision.
public struct TranscriptSegmentSnapshot: Sendable, Equatable, Identifiable {
    /// The label used for the person who is recording.
    ///
    /// `isCurrentUser` carries the same fact in a form a localized interface can
    /// act on; the string is the untranslated fallback.
    public static let currentUserSpeakerLabel = "You"

    /// Stable within one transcript read: the revision it came from plus its
    /// position in that revision.
    public let id: String
    /// The transcript revision this span was read from. A citation names the
    /// same identifier, so a citation can be resolved to the span it quotes.
    public let revisionID: UUID
    /// Groups every span of one speaker. Nil when the span carries no speaker
    /// attribution at all.
    public let speakerKey: String?
    /// The name to show, already resolved: a participant profile's name, "You",
    /// or a generic "Speaker n". Nil when the span is un-attributed.
    public let speakerLabel: String?
    /// Set only when `speakerLabel` is the generic form, so an interface can
    /// render "Speaker \(speakerNumber)" in its own language.
    public let speakerNumber: Int?
    public let speakerProfileID: UUID?
    public let isCurrentUser: Bool
    public let text: String
    /// Seconds from the start of the capture.
    public let startOffset: TimeInterval
    public let duration: TimeInterval

    public init(
        id: String,
        revisionID: UUID,
        speakerKey: String?,
        speakerLabel: String?,
        speakerNumber: Int? = nil,
        speakerProfileID: UUID? = nil,
        isCurrentUser: Bool = false,
        text: String,
        startOffset: TimeInterval,
        duration: TimeInterval
    ) {
        self.id = id
        self.revisionID = revisionID
        self.speakerKey = speakerKey
        self.speakerLabel = speakerLabel
        self.speakerNumber = speakerNumber
        self.speakerProfileID = speakerProfileID
        self.isCurrentUser = isCurrentUser
        self.text = text
        self.startOffset = startOffset
        self.duration = duration
    }

    public var endOffset: TimeInterval {
        startOffset + duration
    }
}

/// The transcript of one note, ready to read.
public struct TranscriptViewSnapshot: Sendable, Equatable {
    public let segments: [TranscriptSegmentSnapshot]
    /// The end of the last span. Zero while only a live transcript exists,
    /// because a running capture has no measured spans yet.
    public let duration: TimeInterval
    /// How many distinct speakers were attributed. Zero when the capture
    /// produced no attribution at all.
    public let speakerCount: Int
    /// True while this is the uncommitted text of a capture that is still
    /// running. A live transcript is microphone-only and carries no timings.
    public let isLive: Bool

    public init(
        segments: [TranscriptSegmentSnapshot],
        duration: TimeInterval,
        speakerCount: Int,
        isLive: Bool
    ) {
        self.segments = segments
        self.duration = duration
        self.speakerCount = speakerCount
        self.isLive = isLive
    }

    public var isEmpty: Bool {
        segments.isEmpty
    }

    /// Every span's text, one per line, with no speaker names. For copy and
    /// export, never for display: display groups spans into speaker turns.
    public var plainText: String {
        segments.map(\.text).joined(separator: "\n")
    }
}

/// The capture that produced a note, as far as a reader needs to know it.
public struct NoteCaptureSessionSnapshot: Sendable, Equatable {
    public let handle: NoteCaptureHandle
    public let mode: CaptureSessionMode
    public let state: CaptureSessionState
    public let startedAt: Date?
    public let endedAt: Date?
    /// The history record this capture produced, when it reached one. It owns
    /// the recorded audio file, so it is how a note page finds something to
    /// play. Nil while the capture is still running and when it never finished.
    public let transcriptionRecordID: UUID?

    public init(
        handle: NoteCaptureHandle,
        mode: CaptureSessionMode,
        state: CaptureSessionState,
        startedAt: Date?,
        endedAt: Date?,
        transcriptionRecordID: UUID? = nil
    ) {
        self.handle = handle
        self.mode = mode
        self.state = state
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.transcriptionRecordID = transcriptionRecordID
    }

    public var capturesSystemAudio: Bool {
        handle.capturesSystemAudio
    }

    /// True while audio is still being captured, including after an
    /// interruption that has not been resolved yet.
    public var isRecording: Bool {
        state == .capturing || state == .interrupted
    }

    public var isFinalizing: Bool {
        state == .finalizing
    }
}

/// Everything one note page reads: the typed notes, the generated panels, the
/// transcript, and the capture behind them.
///
/// A note with no capture resolves too: it has typed notes, no panels, no
/// transcript, and no capture state. That is what makes this one read good for
/// every note in the app instead of only for recorded ones.
public struct NoteCaptureViews: Sendable, Equatable {
    public let noteID: UUID
    public let typedNotes: TypedNotesSnapshot?
    /// The panel to show for each template, newest first, with a legacy
    /// read-only panel last. Superseded generations are never included.
    public let panels: [CaptureEnhancedPanelSnapshot]
    /// Nil when the capture produced no transcript and when the person deleted
    /// the transcript.
    public let transcript: TranscriptViewSnapshot?
    public let captureState: NoteCaptureSessionSnapshot?
    /// The view this note was last left in, exactly as stored.
    public let storedSelection: CaptureNoteViewSelection?
    public let transcriptDeletedAt: Date?

    public init(
        noteID: UUID,
        typedNotes: TypedNotesSnapshot?,
        panels: [CaptureEnhancedPanelSnapshot],
        transcript: TranscriptViewSnapshot?,
        captureState: NoteCaptureSessionSnapshot?,
        storedSelection: CaptureNoteViewSelection? = nil,
        transcriptDeletedAt: Date? = nil
    ) {
        self.noteID = noteID
        self.typedNotes = typedNotes
        self.panels = panels
        self.transcript = transcript
        self.captureState = captureState
        self.storedSelection = storedSelection
        self.transcriptDeletedAt = transcriptDeletedAt
    }

    public var isTranscriptDeleted: Bool {
        transcriptDeletedAt != nil
    }

    /// True when a capture ever ran for this note. A plain typed note is false.
    public var isRecorded: Bool {
        captureState != nil
    }

    /// The views that can be shown right now, in toggle order. Typed notes are
    /// always one of them: they exist before a capture produces anything.
    public var availableViews: [CaptureNoteViewKind] {
        var kinds: [CaptureNoteViewKind] = [.humanNotes]
        if !panels.isEmpty {
            kinds.append(.enhanced)
        }
        if transcript != nil {
            kinds.append(.transcript)
        }
        return kinds
    }

    /// The panel a selection names: the exact template when it is still
    /// current, otherwise the newest panel.
    public func panel(for selection: CaptureNoteViewSelection) -> CaptureEnhancedPanelSnapshot? {
        guard selection.kind == .enhanced else {
            return nil
        }
        guard let templatePresetIdentifier = selection.templatePresetIdentifier else {
            return panels.first
        }
        return panels.first { $0.templatePresetIdentifier == templatePresetIdentifier }
            ?? panels.first
    }

    /// The view to open in.
    ///
    /// The stored view wins while it can still be shown. A stored view whose
    /// panel was never generated, or whose transcript was deleted, falls back to
    /// the typed notes rather than opening on nothing.
    public var selectedView: CaptureNoteViewSelection {
        guard let storedSelection else {
            return .humanNotes
        }
        switch storedSelection.kind {
        case .humanNotes:
            return .humanNotes
        case .enhanced:
            guard let panel = panel(for: storedSelection) else {
                return .humanNotes
            }
            return panel.viewSelection
        case .transcript:
            return transcript == nil ? .humanNotes : .transcript
        }
    }
}
