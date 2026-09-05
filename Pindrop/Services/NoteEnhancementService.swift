//
//  NoteEnhancementService.swift
//  Pindrop
//
//  Created on 2026-08-22.
//
//  Generates one enhanced panel for a note that records.
//
//  A panel is a derived view of a note, never an edit of it: the typed notes go
//  into the generation as evidence and come back out untouched. Regenerating a
//  template writes the next generation and retires the previous one, so what a
//  person saw earlier stays readable.
//
//  The evidence is built by `MeetingNoteDerivation`, which wraps the typed notes
//  and every completed transcript checkpoint in the untrusted-source envelope.
//  Its whole-chunk citation fallback is what makes a microphone-only note work:
//  a note with no diarized segments still cites the chunk it came from.
//

import Foundation
import PindropAI
import PindropCore
import PindropData

@MainActor
final class NoteEnhancementService {

    // MARK: - Errors

    enum NoteEnhancementError: Error, LocalizedError, Equatable {
        /// The session has produced no transcript yet, so there is nothing to
        /// generate from.
        case nothingToEnhance
        case noteUnavailable
        /// No model is assigned to note enhancement.
        case enhancementDisabled
        /// A model is assigned but cannot run right now.
        case enhancementUnavailable
        case promptUnavailable
        case generationFailed
        case emptyOutput
        case saveFailed

        var errorDescription: String? {
            switch self {
            case .nothingToEnhance:
                localized(
                    "There is no transcript to enhance yet. Record this note first.",
                    locale: .autoupdatingCurrent
                )
            case .noteUnavailable:
                localized(
                    "The note this recording belongs to could not be opened.",
                    locale: .autoupdatingCurrent
                )
            case .enhancementDisabled:
                localized(
                    "Pick a model for note enhancement in Settings, then try again.",
                    locale: .autoupdatingCurrent
                )
            case .enhancementUnavailable:
                localized(
                    "The note enhancement model is unavailable. Check it in Settings, then try again.",
                    locale: .autoupdatingCurrent
                )
            case .promptUnavailable:
                localized(
                    "This template could not be read. Pick another template and try again.",
                    locale: .autoupdatingCurrent
                )
            case .generationFailed:
                localized(
                    "The enhanced note could not be generated. Try again.",
                    locale: .autoupdatingCurrent
                )
            case .emptyOutput:
                localized(
                    "The model returned an empty note. Try again.",
                    locale: .autoupdatingCurrent
                )
            case .saveFailed:
                localized(
                    "The enhanced note could not be saved. Try again.",
                    locale: .autoupdatingCurrent
                )
            }
        }
    }

    /// Template identity used when neither the request nor the settings name a
    /// preset. A panel must always say which template produced it.
    static let defaultTemplateIdentifier = "default"

    // MARK: - Dependencies

    private let captureSessionStore: PindropData.CaptureSessionStore
    private let notesStore: PindropData.NotesStore
    private let promptPresetStore: PindropData.PromptPresetStore
    private let assignmentResolver: CaptureStageAssignmentResolver
    private let aiEnhancementService: PindropAI.AIEnhancementService
    private let settingsStore: SettingsStore

    init(
        captureSessionStore: PindropData.CaptureSessionStore,
        notesStore: PindropData.NotesStore,
        promptPresetStore: PindropData.PromptPresetStore,
        assignmentResolver: CaptureStageAssignmentResolver,
        aiEnhancementService: PindropAI.AIEnhancementService,
        settingsStore: SettingsStore
    ) {
        self.captureSessionStore = captureSessionStore
        self.notesStore = notesStore
        self.promptPresetStore = promptPresetStore
        self.assignmentResolver = assignmentResolver
        self.aiEnhancementService = aiEnhancementService
        self.settingsStore = settingsStore
    }

    /// The template a capture generates with when nothing asked for one.
    var defaultTemplatePresetIdentifier: String? {
        settingsStore.assignment(for: .noteEnhancement)?.promptPresetID
    }

    // MARK: - Generation

    /// Generates one enhanced panel and supersedes the previous generation of
    /// the same template.
    ///
    /// `templatePresetIdentifier` is the template the person asked for. Passing
    /// `nil` uses whatever the settings assign to note enhancement.
    @discardableResult
    func generatePanel(
        sessionID: UUID,
        noteID: UUID,
        templatePresetIdentifier: String?
    ) async throws -> CaptureEnhancedPanelSnapshot {
        let humanNoteContent: String
        do {
            humanNoteContent = try notesStore.fetch(id: noteID).content
        } catch {
            throw NoteEnhancementError.noteUnavailable
        }

        // Attempt allocation and assignment freezing happen in one store
        // transaction, so two generations started back to back cannot share an
        // attempt or disagree about which provider produced which panel.
        let allocation: NoteGenerationAssignmentAllocation
        do {
            allocation = try captureSessionStore.resolveNoteGenerationAssignment(
                sessionID: sessionID
            ) { [assignmentResolver] attempt in
                try assignmentResolver.select(
                    stage: .noteGeneration,
                    attempt: attempt,
                    activeBatchModelName: nil,
                    promptPresetOverride: templatePresetIdentifier
                )
            }
        } catch {
            if Self.isCancellation(error) { throw CancellationError() }
            Log.aiEnhancement.warning(
                "Note enhancement assignment unavailable: \(error.localizedDescription)"
            )
            throw NoteEnhancementError.enhancementUnavailable
        }

        // The same admission decisions the capture path has always used: an
        // unassigned, disabled, or non-generative stage cannot produce a panel.
        switch NoteCaptureController.meetingNoteGenerationExecutionDecision(
            for: allocation.assignment
        ) {
        case .skipDisabled:
            throw NoteEnhancementError.enhancementDisabled
        case .skipUnavailable, .rejectInvalidAssignment:
            throw NoteEnhancementError.enhancementUnavailable
        case .resolveRuntime:
            break
        }
        guard let persistedAssignment = NoteCaptureController.noteGenerationRuntimeAssignment(
            from: allocation.assignment
        ) else {
            throw NoteEnhancementError.enhancementUnavailable
        }

        let runtime: ResolvedAssignment
        do {
            runtime = try assignmentResolver.resolveNoteGenerationRuntime(
                for: persistedAssignment
            )
        } catch {
            if Self.isCancellation(error) { throw CancellationError() }
            Log.aiEnhancement.warning(
                "Note enhancement runtime unavailable: \(error.localizedDescription)"
            )
            throw NoteEnhancementError.enhancementUnavailable
        }

        guard let formatPrompt = runtime.prompt,
              NoteCaptureController.canExecutePersistedNoteGeneration(
                  resolvedPrompt: formatPrompt
              ) else {
            throw NoteEnhancementError.promptUnavailable
        }

        let source: MeetingNoteSourceBundle
        do {
            source = try captureSessionStore.noteGenerationEvidence(
                sessionID: sessionID,
                humanNoteContent: humanNoteContent
            )
        } catch MeetingNoteDerivationError.noTranscriptSources {
            throw NoteEnhancementError.nothingToEnhance
        } catch {
            if Self.isCancellation(error) { throw CancellationError() }
            Log.aiEnhancement.warning(
                "Note enhancement evidence could not be derived: \(error.localizedDescription)"
            )
            throw NoteEnhancementError.generationFailed
        }

        let generated: AIEnhancementService.EnhancedNote
        do {
            generated = try await aiEnhancementService.generateMeetingNote(
                evidence: source.evidenceInput,
                assignment: runtime,
                formatPrompt: formatPrompt
            )
        } catch {
            if Self.isCancellation(error) { throw CancellationError() }
            Log.aiEnhancement.warning(
                "Note enhancement generation failed: \(error.localizedDescription)"
            )
            throw NoteEnhancementError.generationFailed
        }

        let content = MeetingNoteDerivation.sanitizingGeneratedContent(
            generated.content.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        guard !content.isEmpty else {
            throw NoteEnhancementError.emptyOutput
        }

        let resolvedTemplateIdentifier = allocation.assignment.prompt?.presetIdentifier
            ?? templatePresetIdentifier
            ?? Self.defaultTemplateIdentifier
        let provenanceJSON = Self.encodedProvenance(
            MeetingGeneratedNoteProvenance(
                humanAnchorNoteID: noteID,
                evidenceInput: source.evidenceInput,
                citations: source.citations,
                sourceTranscriptRevisionIDs: source.sourceTranscriptRevisionIDs
            )
        )

        do {
            return try captureSessionStore.saveEnhancedPanel(
                sessionID: sessionID,
                noteID: noteID,
                templatePresetIdentifier: resolvedTemplateIdentifier,
                templateDisplayName: templateDisplayName(for: resolvedTemplateIdentifier),
                content: content,
                providerSnapshotID: allocation.providerSnapshotID,
                promptSnapshotID: allocation.promptSnapshotID,
                assignmentAttempt: allocation.attempt,
                provenanceJSON: provenanceJSON,
                humanAnchorContentSnapshot: humanNoteContent,
                at: .now
            )
        } catch {
            if Self.isCancellation(error) { throw CancellationError() }
            Log.aiEnhancement.error(
                "Enhanced panel could not be saved: \(error.localizedDescription)"
            )
            throw NoteEnhancementError.saveFailed
        }
    }

    // MARK: - Template naming

    /// The label frozen into a panel at generation time, so renaming or deleting
    /// a preset later cannot relabel a panel that already exists.
    func templateDisplayName(for identifier: String) -> String {
        if let builtIn = BuiltInPresets.definition(for: identifier) {
            return builtIn.name
        }
        if let presetID = UUID(uuidString: identifier),
           let preset = try? promptPresetStore.fetchAll().first(where: { $0.id == presetID }) {
            if let builtInIdentifier = preset.builtInIdentifier,
               let builtIn = BuiltInPresets.definition(for: builtInIdentifier) {
                return builtIn.name
            }
            return preset.name
        }
        return localized("Enhanced note", locale: settingsStore.selectedAppLocale.locale)
    }

    // MARK: - Pure helpers

    static func encodedProvenance(_ provenance: MeetingGeneratedNoteProvenance) -> String? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(provenance) else {
            Log.aiEnhancement.warning("Enhanced panel provenance could not be encoded")
            return nil
        }
        return String(decoding: data, as: UTF8.self)
    }

    static func isCancellation(_ error: Error) -> Bool {
        NoteCaptureController.isTaskCancellation(error)
    }
}
