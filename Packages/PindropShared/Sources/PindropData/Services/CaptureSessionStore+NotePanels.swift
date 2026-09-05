//
//  CaptureSessionStore+NotePanels.swift
//  PindropData
//
//  Created on 2026-08-22.
//
//  Enhanced panels: the generated views of a note that records.
//
//  A panel is never an edit of the typed notes. Regenerating a template writes a
//  new row with the next generation and supersedes the previous one in the same
//  transaction, so the typed notes stay byte-identical and the evidence behind
//  every panel that was ever shown stays readable.
//

import Foundation
import PindropCore
import SwiftData

/// The provider and prompt identity one note-generation attempt was frozen with.
///
/// The attempt is allocated and the snapshots are written in one transaction, so
/// two generations started back to back can never share an attempt or disagree
/// about which provider produced which panel.
public struct NoteGenerationAssignmentAllocation: Sendable, Equatable {
    public let assignment: CaptureStageAssignment
    public let providerSnapshotID: UUID
    public let promptSnapshotID: UUID?

    public var attempt: Int { assignment.attempt }

    public init(
        assignment: CaptureStageAssignment,
        providerSnapshotID: UUID,
        promptSnapshotID: UUID?
    ) {
        self.assignment = assignment
        self.providerSnapshotID = providerSnapshotID
        self.promptSnapshotID = promptSnapshotID
    }
}

extension CaptureSessionStore {

    // MARK: - Attempt allocation

    /// The attempt a new note generation must use: one past the highest
    /// note-generation attempt this session has already frozen.
    ///
    /// Capture start freezes attempt 1, so the first panel of a finished capture
    /// is attempt 2 and every regeneration takes the next number. Reading and
    /// writing happen in one context in `resolveNoteGenerationAssignment`, so
    /// this projection is for callers that only want to look.
    public func nextNoteGenerationAttempt(sessionID: UUID) throws -> Int {
        let context = ModelContext(modelContainer)
        _ = try fetchAssignmentSession(id: sessionID, in: context)
        return try nextNoteGenerationAttempt(sessionID: sessionID, in: context)
    }

    /// Allocates the next note-generation attempt and freezes the assignment the
    /// selector returns against it, in one transaction.
    ///
    /// `selecting` receives the allocated attempt and must return an assignment
    /// for exactly that attempt and for `.noteGeneration`.
    @discardableResult
    public func resolveNoteGenerationAssignment(
        sessionID: UUID,
        selecting: (Int) throws -> CaptureStageAssignment
    ) throws -> NoteGenerationAssignmentAllocation {
        let context = ModelContext(modelContainer)
        _ = try fetchAssignmentSession(id: sessionID, in: context)
        let attempt = try nextNoteGenerationAttempt(sessionID: sessionID, in: context)

        let assignment = try selecting(attempt)
        guard assignment.stage == .noteGeneration, assignment.attempt == attempt else {
            throw CaptureSessionStoreError.assignmentKeyMismatch
        }

        let providerSnapshot = CaptureStageProviderSnapshotModel(
            sessionID: sessionID,
            assignment: assignment
        )
        context.insert(providerSnapshot)
        var promptSnapshotID: UUID?
        if let prompt = assignment.prompt {
            let promptSnapshot = CaptureStagePromptSnapshotModel(
                sessionID: sessionID,
                providerSnapshotID: providerSnapshot.id,
                prompt: prompt
            )
            context.insert(promptSnapshot)
            promptSnapshotID = promptSnapshot.id
        }
        try save(context)

        return NoteGenerationAssignmentAllocation(
            assignment: assignment,
            providerSnapshotID: providerSnapshot.id,
            promptSnapshotID: promptSnapshotID
        )
    }

    // MARK: - Panel writes

    /// Saves one generated panel and retires the previous generation of the same
    /// template in the same transaction.
    ///
    /// Nothing the person typed is read or written here: the typed notes are
    /// carried into the panel only as the immutable `humanAnchorContentSnapshot`
    /// the generation saw.
    @discardableResult
    public func saveEnhancedPanel(
        sessionID: UUID,
        noteID: UUID,
        templatePresetIdentifier: String,
        templateDisplayName: String,
        content: String,
        providerSnapshotID: UUID? = nil,
        promptSnapshotID: UUID? = nil,
        assignmentAttempt: Int,
        provenanceJSON: String? = nil,
        humanAnchorContentSnapshot: String? = nil,
        at timestamp: Date = Date()
    ) throws -> CaptureEnhancedPanelSnapshot {
        guard
            !templatePresetIdentifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            throw CaptureSessionStoreError.invalidEnhancedPanel(sessionID: sessionID)
        }
        guard assignmentAttempt >= 1 else {
            throw CaptureSessionStoreError.invalidAssignmentAttempt(assignmentAttempt)
        }

        let context = ModelContext(modelContainer)
        _ = try fetchAssignmentSession(id: sessionID, in: context)
        try validateEnhancedPanelAnchor(
            sessionID: sessionID,
            noteID: noteID,
            in: context
        )
        let templatePanels = try panelModels(noteID: noteID, in: context)
            .filter {
                $0.sessionID == sessionID &&
                    $0.templatePresetIdentifier == templatePresetIdentifier
            }
        let generation = (templatePanels.map(\.generation).max() ?? 0) + 1
        for panel in templatePanels where panel.supersededAt == nil {
            panel.markSuperseded(at: timestamp)
        }

        let model = CaptureEnhancedPanelModel(
            sessionID: sessionID,
            noteID: noteID,
            templatePresetIdentifier: templatePresetIdentifier,
            templateDisplayName: templateDisplayName,
            content: content,
            generation: generation,
            providerSnapshotID: providerSnapshotID,
            promptSnapshotID: promptSnapshotID,
            assignmentAttempt: assignmentAttempt,
            provenanceJSON: provenanceJSON,
            humanAnchorContentSnapshot: humanAnchorContentSnapshot,
            createdAt: timestamp
        )
        context.insert(model)
        try save(context)
        return try model.restorePanel()
    }

    /// Records how a person rated one panel.
    public func setEnhancedPanelFeedback(
        panelID: UUID,
        feedback: CaptureNotePanelFeedback?
    ) throws {
        let context = ModelContext(modelContainer)
        guard let model = try panelModel(id: panelID, in: context) else {
            throw CaptureSessionStoreError.enhancedPanelNotFound(panelID)
        }
        model.setFeedback(feedback)
        try save(context)
    }

    // MARK: - Panel reads

    /// The panel to show for each session and template of one note, newest first.
    ///
    /// A superseded row is never returned: it stays on disk as the evidence trail
    /// of what an earlier generation produced.
    public func currentPanels(noteID: UUID) throws -> [CaptureEnhancedPanelSnapshot] {
        let context = ModelContext(modelContainer)
        var newestByTemplate: [PanelGenerationKey: CaptureEnhancedPanelModel] = [:]
        for panel in try panelModels(noteID: noteID, in: context) where panel.supersededAt == nil {
            let key = PanelGenerationKey(
                sessionID: panel.sessionID,
                templatePresetIdentifier: panel.templatePresetIdentifier
            )
            guard let incumbent = newestByTemplate[key] else {
                newestByTemplate[key] = panel
                continue
            }
            if isNewer(panel, than: incumbent) {
                newestByTemplate[key] = panel
            }
        }
        return try newestByTemplate.values
            .map { try $0.restorePanel() }
            .sorted { isNewer($0, than: $1) }
    }

    /// Every panel of one note, newest first, superseded generations included.
    public func enhancedPanels(noteID: UUID) throws -> [CaptureEnhancedPanelSnapshot] {
        let context = ModelContext(modelContainer)
        return try panelModels(noteID: noteID, in: context)
            .map { try $0.restorePanel() }
            .sorted { isNewer($0, than: $1) }
    }

    public func enhancedPanel(id: UUID) throws -> CaptureEnhancedPanelSnapshot? {
        let context = ModelContext(modelContainer)
        return try panelModel(id: id, in: context)?.restorePanel()
    }

    /// The sources one panel was generated from.
    ///
    /// The stored provenance is trusted only when it re-encodes to itself byte
    /// for byte and still names this panel's note: a blob that was rewritten
    /// after the generation describes nothing this build wrote. A panel that
    /// kept no provenance simply has no sources.
    ///
    /// A citation returned here says which span of which transcript revision it
    /// quotes. It does not say that span is still readable, so a reader must
    /// resolve every citation against the transcript on screen before offering
    /// it as a link.
    public func enhancedPanelCitations(panelID: UUID) throws -> [MeetingNoteCitation] {
        let context = ModelContext(modelContainer)
        guard let model = try panelModel(id: panelID, in: context) else {
            throw CaptureSessionStoreError.enhancedPanelNotFound(panelID)
        }
        guard
            let provenanceJSON = model.provenanceJSON,
            let provenanceData = provenanceJSON.data(using: .utf8),
            let provenance = try? JSONDecoder().decode(
                MeetingGeneratedNoteProvenance.self,
                from: provenanceData
            )
        else {
            return []
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard
            let reencoded = try? encoder.encode(provenance),
            String(decoding: reencoded, as: UTF8.self) == provenanceJSON,
            provenance.humanAnchorNoteID == model.noteID
        else {
            return []
        }
        return provenance.citations
    }

    // MARK: - Legacy generated notes

    /// Presents a legacy generated meeting note as a read-only panel.
    ///
    /// Captures from before enhanced panels wrote their generated output as a
    /// second `Note` row. Those rows are shown, never rewritten: this reads them
    /// through the same projection the note page uses for generated panels, and
    /// touches neither the note nor its byte-identical provenance.
    ///
    /// `noteID` is the note the person typed into (the human anchor).
    public func legacyEnhancedPanel(noteID: UUID) throws -> CaptureEnhancedPanelSnapshot? {
        let context = ModelContext(modelContainer)
        guard let anchorReference = try latestHumanAnchorReference(
            noteID: noteID,
            in: context
        ) else {
            return nil
        }

        let references = try meetingNoteReferences(
            sessionID: anchorReference.sessionID,
            in: context
        )
        let generatedReferences = references.filter {
            (try? $0.resolvedRole()) == .generated
        }
        guard
            generatedReferences.count == 1,
            let generatedReference = generatedReferences.first,
            let generatedNote = try fetchNote(id: generatedReference.noteID, in: context),
            !generatedNote.content.isEmpty
        else {
            return nil
        }

        return try CaptureEnhancedPanelSnapshot(
            id: generatedNote.id,
            sessionID: anchorReference.sessionID,
            noteID: noteID,
            templatePresetIdentifier: CaptureEnhancedPanelSnapshot.legacyMeetingNoteTemplateIdentifier,
            templateDisplayName: CaptureEnhancedPanelSnapshot.legacyMeetingNoteDisplayName,
            content: generatedNote.content,
            generation: 1,
            providerSnapshotID: generatedReference.providerSnapshotID,
            assignmentAttempt: 1,
            createdAt: generatedReference.createdAt,
            isLegacy: true
        )
    }

    // MARK: - Save as note

    /// Copies one panel's content into a note of its own.
    ///
    /// This is only ever an explicit action. A panel is a derived view; turning
    /// it into a note is the person deciding they want an editable copy, so the
    /// copy is a plain note with no capture reference and the panel is untouched.
    @discardableResult
    public func saveEnhancedPanelAsNote(
        panelID: UUID,
        title: String? = nil,
        at timestamp: Date = Date()
    ) throws -> UUID {
        let context = ModelContext(modelContainer)
        guard let panel = try panelModel(id: panelID, in: context) else {
            throw CaptureSessionStoreError.enhancedPanelNotFound(panelID)
        }

        let resolvedTitle = title?.trimmingCharacters(in: .whitespacesAndNewlines)
        let note = Note(
            title: (resolvedTitle?.isEmpty == false ? resolvedTitle! : panel.templateDisplayName),
            content: panel.content,
            tags: [],
            sourceTranscriptionID: nil,
            createdAt: timestamp,
            updatedAt: timestamp
        )
        context.insert(note)
        try save(context)
        return note.id
    }

    // MARK: - Evidence

    /// The citation-marked evidence one generation must run on.
    ///
    /// This is the same derivation the generated-note path has always used: the
    /// completed final-ASR checkpoints of the session, wrapped with the typed
    /// notes in the untrusted-source envelope. Throws
    /// `MeetingNoteDerivationError.noTranscriptSources` when the session has
    /// produced no transcript yet.
    public func noteGenerationEvidence(
        sessionID: UUID,
        humanNoteContent: String
    ) throws -> MeetingNoteSourceBundle {
        let context = ModelContext(modelContainer)
        return try derivedMeetingNoteSource(
            sessionID: sessionID,
            humanNoteContent: humanNoteContent,
            in: context
        )
    }

    // MARK: - Helpers

    private struct PanelGenerationKey: Hashable {
        let sessionID: UUID
        let templatePresetIdentifier: String
    }

    /// The latest capture that uses this note as its human anchor.
    /// The identifier makes equal timestamps deterministic.
    func latestHumanAnchorReference(
        noteID: UUID,
        in context: ModelContext
    ) throws -> CaptureNoteReferenceModel? {
        let descriptor = FetchDescriptor<CaptureNoteReferenceModel>(
            predicate: #Predicate<CaptureNoteReferenceModel> { $0.noteID == noteID }
        )
        let references: [CaptureNoteReferenceModel]
        do {
            references = try context.fetch(descriptor)
        } catch {
            throw CaptureSessionStoreError.fetchFailed(error.localizedDescription)
        }
        var newest: (reference: CaptureNoteReferenceModel, startedAt: Date)?
        for reference in references where (try? reference.resolvedRole()) == .humanAnchor {
            let session = try fetchSession(id: reference.sessionID, in: context)
                .restoreSession()
            let startedAt = session.startedAt ?? session.createdAt
            if let current = newest {
                guard
                    startedAt > current.startedAt ||
                    (startedAt == current.startedAt &&
                        reference.sessionID.uuidString > current.reference.sessionID.uuidString)
                else {
                    continue
                }
            }
            newest = (reference, startedAt)
        }
        return newest?.reference
    }

    /// A panel can be saved only while its note and this session's human anchor
    /// still exist in the same write context.
    private func validateEnhancedPanelAnchor(
        sessionID: UUID,
        noteID: UUID,
        in context: ModelContext
    ) throws {
        guard try fetchNote(id: noteID, in: context) != nil else {
            throw CaptureSessionStoreError.noteNotFound(noteID)
        }
        guard
            let anchor = try validMeetingHumanAnchor(sessionID: sessionID, in: context),
            anchor.noteID == noteID
        else {
            throw CaptureSessionStoreError.meetingHumanAnchorConflict(sessionID)
        }
    }

    private func nextNoteGenerationAttempt(
        sessionID: UUID,
        in context: ModelContext
    ) throws -> Int {
        let stageRawValue = CapturePipelineStage.noteGeneration.rawValue
        let descriptor = FetchDescriptor<CaptureStageProviderSnapshotModel>(
            predicate: #Predicate<CaptureStageProviderSnapshotModel> {
                $0.sessionID == sessionID && $0.stageRawValue == stageRawValue
            }
        )
        do {
            return (try context.fetch(descriptor).map(\.attempt).max() ?? 0) + 1
        } catch {
            throw CaptureSessionStoreError.fetchFailed(error.localizedDescription)
        }
    }

    private func panelModels(
        noteID: UUID,
        in context: ModelContext
    ) throws -> [CaptureEnhancedPanelModel] {
        let descriptor = FetchDescriptor<CaptureEnhancedPanelModel>(
            predicate: #Predicate<CaptureEnhancedPanelModel> { $0.noteID == noteID }
        )
        do {
            return try context.fetch(descriptor)
        } catch {
            throw CaptureSessionStoreError.fetchFailed(error.localizedDescription)
        }
    }

    private func panelModel(
        id: UUID,
        in context: ModelContext
    ) throws -> CaptureEnhancedPanelModel? {
        var descriptor = FetchDescriptor<CaptureEnhancedPanelModel>(
            predicate: #Predicate<CaptureEnhancedPanelModel> { $0.id == id }
        )
        descriptor.fetchLimit = 1
        do {
            return try context.fetch(descriptor).first
        } catch {
            throw CaptureSessionStoreError.fetchFailed(error.localizedDescription)
        }
    }

    private func isNewer(
        _ panel: CaptureEnhancedPanelModel,
        than other: CaptureEnhancedPanelModel
    ) -> Bool {
        if panel.createdAt != other.createdAt {
            return panel.createdAt > other.createdAt
        }
        if panel.generation != other.generation {
            return panel.generation > other.generation
        }
        return panel.id.uuidString > other.id.uuidString
    }

    private func isNewer(
        _ panel: CaptureEnhancedPanelSnapshot,
        than other: CaptureEnhancedPanelSnapshot
    ) -> Bool {
        if panel.createdAt != other.createdAt {
            return panel.createdAt > other.createdAt
        }
        if panel.generation != other.generation {
            return panel.generation > other.generation
        }
        return panel.id.uuidString > other.id.uuidString
    }
}
