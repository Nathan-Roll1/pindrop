//
//  CaptureNotePanelModels.swift
//  PindropData
//
//  Created on 2026-08-22.
//

import Foundation
import PindropCore
import SwiftData

public enum CaptureNotePanelProjectionError: Error, Equatable, LocalizedError {
    case invalidPanelFeedbackRawValue(String)
    case invalidIntentDestinationRawValue(String)
    case invalidIntentOriginRawValue(String)
    case invalidRequestedSourceKinds(String)
    case invalidPersistedPanel
    case invalidPersistedIntent

    public var errorDescription: String? {
        switch self {
        case .invalidPanelFeedbackRawValue(let rawValue):
            "Enhanced panel feedback '\(rawValue)' is not recognized."
        case .invalidIntentDestinationRawValue(let rawValue):
            "Capture intent destination '\(rawValue)' is not recognized."
        case .invalidIntentOriginRawValue(let rawValue):
            "Capture intent origin '\(rawValue)' is not recognized."
        case .invalidRequestedSourceKinds(let rawValue):
            "Capture intent requested sources '\(rawValue)' cannot be read."
        case .invalidPersistedPanel:
            "Enhanced panel persistence does not describe a valid panel."
        case .invalidPersistedIntent:
            "Capture intent persistence does not describe a valid intent."
        }
    }
}

/// One generated view of a note, stored beside the typed notes and never over them.
///
/// Regenerating a template inserts a new row with the next `generation` and
/// marks the previous row superseded, so the provider, prompt, and evidence
/// behind every panel that was ever shown stay readable.
@Model
public final class CaptureEnhancedPanelModel {
    @Attribute(.unique) public private(set) var id: UUID
    public private(set) var sessionID: UUID
    public private(set) var noteID: UUID
    public private(set) var templatePresetIdentifier: String
    /// Frozen at generation time so renaming or deleting a preset does not
    /// relabel a panel that already exists.
    public private(set) var templateDisplayName: String
    public private(set) var content: String
    public private(set) var generation: Int
    public private(set) var supersededAt: Date?
    public private(set) var providerSnapshotID: UUID?
    public private(set) var promptSnapshotID: UUID?
    public private(set) var assignmentAttempt: Int
    /// Encoded `MeetingGeneratedNoteProvenance`: the evidence and citations
    /// this panel was generated from.
    public private(set) var provenanceJSON: String?
    public private(set) var humanAnchorContentSnapshot: String?
    public private(set) var userFeedbackRawValue: String?
    public private(set) var createdAt: Date

    public init(
        id: UUID = UUID(),
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
        provenanceJSON: String? = nil,
        humanAnchorContentSnapshot: String? = nil,
        feedback: CaptureNotePanelFeedback? = nil,
        createdAt: Date = Date()
    ) {
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
        self.provenanceJSON = provenanceJSON
        self.humanAnchorContentSnapshot = humanAnchorContentSnapshot
        self.userFeedbackRawValue = feedback?.rawValue
        self.createdAt = createdAt
    }

    public func resolvedFeedback() throws -> CaptureNotePanelFeedback? {
        guard let userFeedbackRawValue else {
            return nil
        }
        guard let feedback = CaptureNotePanelFeedback(rawValue: userFeedbackRawValue) else {
            throw CaptureNotePanelProjectionError.invalidPanelFeedbackRawValue(userFeedbackRawValue)
        }
        return feedback
    }

    public func restorePanel() throws -> CaptureEnhancedPanelSnapshot {
        let feedback = try resolvedFeedback()
        do {
            return try CaptureEnhancedPanelSnapshot(
                id: id,
                sessionID: sessionID,
                noteID: noteID,
                templatePresetIdentifier: templatePresetIdentifier,
                templateDisplayName: templateDisplayName,
                content: content,
                generation: generation,
                supersededAt: supersededAt,
                providerSnapshotID: providerSnapshotID,
                promptSnapshotID: promptSnapshotID,
                assignmentAttempt: assignmentAttempt,
                feedback: feedback,
                createdAt: createdAt
            )
        } catch {
            throw CaptureNotePanelProjectionError.invalidPersistedPanel
        }
    }

    /// Retires this panel in favor of a newer generation. Keeps the first
    /// timestamp so repeating the call cannot rewrite history.
    public func markSuperseded(at timestamp: Date = Date()) {
        guard supersededAt == nil else {
            return
        }
        supersededAt = timestamp
    }

    public func setFeedback(_ feedback: CaptureNotePanelFeedback?) {
        userFeedbackRawValue = feedback?.rawValue
    }
}

/// Per-note reading state: which view the note opens in, and whether the
/// person deleted its transcript.
///
/// Transcript deletion is independent of the note: clearing a transcript must
/// not remove the typed notes or the panels derived from it.
@Model
public final class NoteViewStateModel {
    @Attribute(.unique) public private(set) var id: UUID
    @Attribute(.unique) public private(set) var noteID: UUID
    public private(set) var selectedPanelKey: String?
    public private(set) var transcriptDeletedAt: Date?
    public private(set) var updatedAt: Date

    public init(
        id: UUID = UUID(),
        noteID: UUID,
        selection: CaptureNoteViewSelection? = nil,
        transcriptDeletedAt: Date? = nil,
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.noteID = noteID
        self.selectedPanelKey = selection?.storageKey
        self.transcriptDeletedAt = transcriptDeletedAt
        self.updatedAt = updatedAt
    }

    /// The stored view, or nil when nothing is stored and when the stored key
    /// belongs to a build that wrote a view this one cannot show. Callers fall
    /// back to the default view rather than failing the note read.
    public func resolvedSelection() -> CaptureNoteViewSelection? {
        guard let selectedPanelKey else {
            return nil
        }
        return CaptureNoteViewSelection(storageKey: selectedPanelKey)
    }

    public func select(_ selection: CaptureNoteViewSelection, at timestamp: Date = Date()) {
        selectedPanelKey = selection.storageKey
        updatedAt = timestamp
    }

    /// Records that the transcript was deleted. Keeps the first timestamp so
    /// repeating the call reports the same deletion time.
    public func markTranscriptDeleted(at timestamp: Date = Date()) {
        guard transcriptDeletedAt == nil else {
            return
        }
        transcriptDeletedAt = timestamp
        updatedAt = timestamp
    }

    public var isTranscriptDeleted: Bool {
        transcriptDeletedAt != nil
    }
}

/// What a capture was started for, written in the same transaction as the start.
///
/// After a crash this is the only record that says where an unfinished
/// capture's output belongs.
@Model
public final class CaptureIntentModel {
    @Attribute(.unique) public private(set) var id: UUID
    @Attribute(.unique) public private(set) var sessionID: UUID
    public private(set) var destinationRawValue: String
    public private(set) var destinationNoteID: UUID?
    /// JSON array of `CaptureSourceKind` raw values, in request order.
    public private(set) var requestedSourceKindsJSON: String
    public private(set) var requestedTemplatePresetIdentifier: String?
    public private(set) var originRawValue: String
    public private(set) var createdAt: Date

    public init(id: UUID = UUID(), intent: CaptureIntent) throws {
        self.id = id
        self.sessionID = intent.sessionID
        self.destinationRawValue = intent.destination.rawValue
        self.destinationNoteID = intent.destinationNoteID
        self.requestedSourceKindsJSON = try Self.encodeSourceKinds(intent.requestedSourceKinds)
        self.requestedTemplatePresetIdentifier = intent.requestedTemplatePresetIdentifier
        self.originRawValue = intent.origin.rawValue
        self.createdAt = intent.createdAt
    }

    public func restoreIntent() throws -> CaptureIntent {
        guard let destination = CaptureIntentDestination(rawValue: destinationRawValue) else {
            throw CaptureNotePanelProjectionError.invalidIntentDestinationRawValue(destinationRawValue)
        }
        guard let origin = CaptureIntentOrigin(rawValue: originRawValue) else {
            throw CaptureNotePanelProjectionError.invalidIntentOriginRawValue(originRawValue)
        }
        let requestedSourceKinds = try Self.decodeSourceKinds(requestedSourceKindsJSON)

        do {
            return try CaptureIntent(
                sessionID: sessionID,
                destination: destination,
                destinationNoteID: destinationNoteID,
                requestedSourceKinds: requestedSourceKinds,
                requestedTemplatePresetIdentifier: requestedTemplatePresetIdentifier,
                origin: origin,
                createdAt: createdAt
            )
        } catch {
            throw CaptureNotePanelProjectionError.invalidPersistedIntent
        }
    }

    /// Points a `newNote` intent at the note the capture created.
    ///
    /// A capture that makes its own note only learns the note identifier after
    /// the note is committed, so the destination is bound then. The store
    /// rejects a rebind that would contradict an already bound destination.
    public func bindDestinationNote(_ noteID: UUID) {
        destinationRawValue = CaptureIntentDestination.existingNote.rawValue
        destinationNoteID = noteID
    }

    private static func encodeSourceKinds(_ kinds: [CaptureSourceKind]) throws -> String {
        let rawValues = kinds.map(\.rawValue)
        guard
            let data = try? JSONEncoder().encode(rawValues),
            let json = String(data: data, encoding: .utf8)
        else {
            throw CaptureNotePanelProjectionError.invalidRequestedSourceKinds(rawValues.joined(separator: ","))
        }
        return json
    }

    private static func decodeSourceKinds(_ json: String) throws -> [CaptureSourceKind] {
        guard
            let data = json.data(using: .utf8),
            let rawValues = try? JSONDecoder().decode([String].self, from: data)
        else {
            throw CaptureNotePanelProjectionError.invalidRequestedSourceKinds(json)
        }
        return try rawValues.map { rawValue in
            guard let kind = CaptureSourceKind(rawValue: rawValue) else {
                throw CaptureNotePanelProjectionError.invalidRequestedSourceKinds(rawValue)
            }
            return kind
        }
    }
}
