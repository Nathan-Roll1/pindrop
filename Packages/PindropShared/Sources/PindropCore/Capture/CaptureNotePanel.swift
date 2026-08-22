//
//  CaptureNotePanel.swift
//  PindropCore
//
//  Created on 2026-08-22.
//

import Foundation

/// One switchable view of a note that records.
///
/// The three kinds are always available for a recorded note: the notes the
/// person typed, a derived panel generated from one template, and the
/// transcript. Generation never writes back into `humanNotes`.
public enum CaptureNoteViewKind: String, Codable, Sendable, CaseIterable {
    case humanNotes
    case enhanced
    case transcript
}

/// Which view a note opens in, including the template of an enhanced panel.
///
/// The persisted form is a single string (`storageKey`) so the stored view
/// state does not change shape when new template presets appear.
public struct CaptureNoteViewSelection: Codable, Sendable, Equatable {
    /// Prefix of the storage key that carries a template preset identifier.
    public static let enhancedKeySeparator: Character = ":"

    public let kind: CaptureNoteViewKind
    /// Set only for `.enhanced`. Nil selects the newest enhanced panel.
    public let templatePresetIdentifier: String?

    public init(kind: CaptureNoteViewKind, templatePresetIdentifier: String? = nil) {
        self.kind = kind
        self.templatePresetIdentifier = kind == .enhanced ? templatePresetIdentifier : nil
    }

    public static let humanNotes = CaptureNoteViewSelection(kind: .humanNotes)
    public static let transcript = CaptureNoteViewSelection(kind: .transcript)

    public static func enhanced(templatePresetIdentifier: String? = nil) -> CaptureNoteViewSelection {
        CaptureNoteViewSelection(
            kind: .enhanced,
            templatePresetIdentifier: templatePresetIdentifier
        )
    }

    /// The durable single-string form written to `NoteViewStateModel`.
    public var storageKey: String {
        guard let templatePresetIdentifier, kind == .enhanced else {
            return kind.rawValue
        }
        return "\(kind.rawValue)\(Self.enhancedKeySeparator)\(templatePresetIdentifier)"
    }

    /// Reads a persisted key. Returns nil for a key this build does not know,
    /// so an unreadable stored view falls back to the default view instead of
    /// failing the whole note read.
    public init?(storageKey: String) {
        guard !storageKey.isEmpty else {
            return nil
        }
        guard let separatorIndex = storageKey.firstIndex(of: Self.enhancedKeySeparator) else {
            guard let kind = CaptureNoteViewKind(rawValue: storageKey) else {
                return nil
            }
            self.init(kind: kind)
            return
        }

        let kindRawValue = String(storageKey[storageKey.startIndex..<separatorIndex])
        let identifier = String(storageKey[storageKey.index(after: separatorIndex)...])
        guard
            let kind = CaptureNoteViewKind(rawValue: kindRawValue),
            kind == .enhanced,
            !identifier.isEmpty
        else {
            return nil
        }
        self.init(kind: kind, templatePresetIdentifier: identifier)
    }
}

/// Where a capture's output must land once the capture finishes.
public enum CaptureIntentDestination: String, Codable, Sendable {
    /// Create a note when the capture starts and keep writing to it.
    case newNote
    /// Attach the capture to a note that already exists.
    case existingNote
    /// Keep only the transcript in the library; do not create a note.
    case transcriptOnly
}

/// What asked for the capture. Recovery uses this to explain an unfinished capture.
public enum CaptureIntentOrigin: String, Codable, Sendable {
    case mainWindow
    case menuBar
    case hotkey
    case automation
}

/// How a person rated one generated panel.
public enum CaptureNotePanelFeedback: String, Codable, Sendable {
    case helpful
    case notHelpful
}

public enum CaptureIntentError: Error, Codable, Sendable, Equatable, LocalizedError {
    case missingDestinationNote
    case unexpectedDestinationNote(CaptureIntentDestination)
    case emptyRequestedSourceKinds
    case duplicateRequestedSourceKind(CaptureSourceKind)

    public var errorDescription: String? {
        switch self {
        case .missingDestinationNote:
            "A capture intent for an existing note must name that note."
        case .unexpectedDestinationNote(let destination):
            "A capture intent for \(destination.rawValue) must not name a note."
        case .emptyRequestedSourceKinds:
            "A capture intent must request at least one audio source."
        case .duplicateRequestedSourceKind(let kind):
            "A capture intent must request the \(kind.rawValue) source only once."
        }
    }
}

/// The durable request recorded in the same transaction as a capture start.
///
/// It answers "what was this recording for?" after a crash, so an interrupted
/// capture can be delivered to the right note instead of being dropped. The
/// microphone source is expected first; a system-audio source is additive.
public struct CaptureIntent: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID { sessionID }

    public let sessionID: UUID
    public let destination: CaptureIntentDestination
    public let destinationNoteID: UUID?
    public let requestedSourceKinds: [CaptureSourceKind]
    public let requestedTemplatePresetIdentifier: String?
    public let origin: CaptureIntentOrigin
    public let createdAt: Date

    public init(
        sessionID: UUID,
        destination: CaptureIntentDestination,
        destinationNoteID: UUID? = nil,
        requestedSourceKinds: [CaptureSourceKind],
        requestedTemplatePresetIdentifier: String? = nil,
        origin: CaptureIntentOrigin,
        createdAt: Date = Date()
    ) throws {
        switch destination {
        case .existingNote:
            guard destinationNoteID != nil else {
                throw CaptureIntentError.missingDestinationNote
            }
        case .newNote, .transcriptOnly:
            guard destinationNoteID == nil else {
                throw CaptureIntentError.unexpectedDestinationNote(destination)
            }
        }
        guard !requestedSourceKinds.isEmpty else {
            throw CaptureIntentError.emptyRequestedSourceKinds
        }
        var seenSourceKinds: Set<CaptureSourceKind> = []
        for kind in requestedSourceKinds {
            guard seenSourceKinds.insert(kind).inserted else {
                throw CaptureIntentError.duplicateRequestedSourceKind(kind)
            }
        }

        self.sessionID = sessionID
        self.destination = destination
        self.destinationNoteID = destinationNoteID
        self.requestedSourceKinds = requestedSourceKinds
        self.requestedTemplatePresetIdentifier = requestedTemplatePresetIdentifier
        self.origin = origin
        self.createdAt = createdAt
    }

    public var requestsSystemAudio: Bool {
        requestedSourceKinds.contains(.systemAudio)
    }
}

/// One capture intent before the store gives it a session identity.
///
/// A caller cannot know the session identifier until the store creates the
/// session, and it must not guess the source set either. The store binds this
/// request to the session it creates and to the source rows it creates in the
/// same transaction, so the persisted `requestedSourceKinds` can never disagree
/// with the sources that exist.
public struct CaptureIntentRequest: Sendable, Equatable {
    public let destination: CaptureIntentDestination
    public let destinationNoteID: UUID?
    public let requestedTemplatePresetIdentifier: String?
    public let origin: CaptureIntentOrigin

    public init(
        destination: CaptureIntentDestination,
        destinationNoteID: UUID? = nil,
        requestedTemplatePresetIdentifier: String? = nil,
        origin: CaptureIntentOrigin
    ) {
        self.destination = destination
        self.destinationNoteID = destinationNoteID
        self.requestedTemplatePresetIdentifier = requestedTemplatePresetIdentifier
        self.origin = origin
    }

    /// Binds this request to one session and the sources that session owns.
    ///
    /// Validation is `CaptureIntent`'s: this throws the same `CaptureIntentError`
    /// values, so an impossible request fails at the moment the capture starts
    /// rather than at recovery time.
    public func intent(
        sessionID: UUID,
        requestedSourceKinds: [CaptureSourceKind],
        createdAt: Date = Date()
    ) throws -> CaptureIntent {
        try CaptureIntent(
            sessionID: sessionID,
            destination: destination,
            destinationNoteID: destinationNoteID,
            requestedSourceKinds: requestedSourceKinds,
            requestedTemplatePresetIdentifier: requestedTemplatePresetIdentifier,
            origin: origin,
            createdAt: createdAt
        )
    }
}

public enum CaptureEnhancedPanelError: Error, Codable, Sendable, Equatable, LocalizedError {
    case invalidGeneration(Int)
    case invalidAssignmentAttempt(Int)
    case emptyTemplatePresetIdentifier

    public var errorDescription: String? {
        switch self {
        case .invalidGeneration(let generation):
            "Enhanced panel generation \(generation) must be at least one."
        case .invalidAssignmentAttempt(let attempt):
            "Enhanced panel assignment attempt \(attempt) must be at least one."
        case .emptyTemplatePresetIdentifier:
            "An enhanced panel must name the template preset it was generated from."
        }
    }
}

/// One generated view of a note, frozen at the moment it was produced.
///
/// A panel is never an edit of the typed notes: regenerating a template writes
/// a new panel with the next generation and supersedes the previous one, so the
/// evidence behind every shown panel stays readable.
public struct CaptureEnhancedPanelSnapshot: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public let sessionID: UUID
    public let noteID: UUID
    public let templatePresetIdentifier: String
    /// Frozen at generation time so a renamed or deleted preset does not
    /// rewrite the label of a panel that already exists.
    public let templateDisplayName: String
    public let content: String
    public let generation: Int
    public let supersededAt: Date?
    public let providerSnapshotID: UUID?
    public let promptSnapshotID: UUID?
    public let assignmentAttempt: Int
    public let feedback: CaptureNotePanelFeedback?
    public let createdAt: Date

    public init(
        id: UUID,
        sessionID: UUID,
        noteID: UUID,
        templatePresetIdentifier: String,
        templateDisplayName: String,
        content: String,
        generation: Int,
        supersededAt: Date? = nil,
        providerSnapshotID: UUID? = nil,
        promptSnapshotID: UUID? = nil,
        assignmentAttempt: Int,
        feedback: CaptureNotePanelFeedback? = nil,
        createdAt: Date
    ) throws {
        guard generation >= 1 else {
            throw CaptureEnhancedPanelError.invalidGeneration(generation)
        }
        guard assignmentAttempt >= 1 else {
            throw CaptureEnhancedPanelError.invalidAssignmentAttempt(assignmentAttempt)
        }
        guard !templatePresetIdentifier.isEmpty else {
            throw CaptureEnhancedPanelError.emptyTemplatePresetIdentifier
        }

        self.id = id
        self.sessionID = sessionID
        self.noteID = noteID
        self.templatePresetIdentifier = templatePresetIdentifier
        self.templateDisplayName = templateDisplayName
        self.content = content
        self.generation = generation
        self.supersededAt = supersededAt
        self.providerSnapshotID = providerSnapshotID
        self.promptSnapshotID = promptSnapshotID
        self.assignmentAttempt = assignmentAttempt
        self.feedback = feedback
        self.createdAt = createdAt
    }

    /// True while this is the panel to show for its template.
    public var isCurrent: Bool {
        supersededAt == nil
    }

    public var viewSelection: CaptureNoteViewSelection {
        .enhanced(templatePresetIdentifier: templatePresetIdentifier)
    }
}
