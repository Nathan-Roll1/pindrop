//
//  CaptureSessionStoreNotePanelsTests.swift
//  PindropDataTests
//
//  Created on 2026-08-22.
//

import Foundation
import PindropCore
import SwiftData
import Testing
@testable import PindropData

@MainActor
@Suite(.serialized)
struct CaptureSessionStoreNotePanelsTests {

    // MARK: - Fixture

    private struct Fixture {
        let container: ModelContainer
        let store: CaptureSessionStore
        let handle: NoteCaptureHandle
        let noteID: UUID
        let typedContent: String
    }

    private func makeContainer() throws -> ModelContainer {
        try PindropModelContainerFactory.makeInMemoryContainer()
    }

    private func chunk(
        _ sourceID: UUID,
        sessionID: UUID,
        sequence: Int,
        sealedAt: Date
    ) -> MeetingChunkCheckpoint {
        let byteCount = MeetingCaptureSpoolPlan.defaultChunkByteCount
        let duration = Double(byteCount) /
            Double(MeetingCaptureSpoolPlan.sampleRate * MeetingCaptureSpoolPlan.bytesPerSample)
        return MeetingChunkCheckpoint(
            sourceID: sourceID,
            sequence: sequence,
            startOffset: Double(sequence) * duration,
            duration: duration,
            managedMediaPath: CaptureSourceArtifactPath.relativePath(
                sessionID: sessionID,
                sourceID: sourceID,
                chunkSequence: sequence
            ),
            byteCount: byteCount,
            sha256: String(format: "%064x", sequence + 1),
            sealedAt: sealedAt
        )
    }

    private func assignment(
        stage: CapturePipelineStage,
        providerKind: CaptureAssignmentProviderKind,
        providerIdentifier: String,
        modelIdentifier: String?,
        prompt: CapturePromptSnapshot? = nil,
        attempt: Int,
        selectedAt: Date = Date(timeIntervalSinceReferenceDate: 30_000)
    ) throws -> CaptureStageAssignment {
        try CaptureStageAssignment(
            stage: stage,
            providerKind: providerKind,
            providerIdentifier: providerIdentifier,
            modelIdentifier: modelIdentifier,
            prompt: prompt,
            selectedAt: selectedAt,
            attempt: attempt
        )
    }

    /// A finished note capture with one typed note and one completed final-ASR
    /// checkpoint: the exact shape a panel is generated from.
    private func makeFixture(
        typedContent: String = "My own notes about the release.",
        startedAt: Date = Date(timeIntervalSinceReferenceDate: 40_000)
    ) throws -> Fixture {
        let container = try makeContainer()
        let store = CaptureSessionStore(modelContext: ModelContext(container))
        let handle = try store.startNoteCapture(
            startedAt: startedAt,
            includeSystemAudio: false,
            intent: CaptureIntentRequest(destination: .newNote, origin: .mainWindow)
        )
        let anchor = try store.ensureMeetingHumanAnchor(
            handle,
            title: "Release review",
            at: startedAt
        )
        // The person types into the note while the capture runs.
        let context = ModelContext(container)
        let noteID = anchor.noteID
        var descriptor = FetchDescriptor<Note>(predicate: #Predicate<Note> { $0.id == noteID })
        descriptor.fetchLimit = 1
        let note = try #require(try context.fetch(descriptor).first)
        note.content = typedContent
        try context.save()

        try store.beginMeetingFinalization(handle, at: startedAt.addingTimeInterval(1))
        let checkpoint = chunk(
            handle.microphoneSourceID,
            sessionID: handle.sessionID,
            sequence: 0,
            sealedAt: startedAt.addingTimeInterval(2)
        )
        try store.recordSealedMeetingChunk(handle, checkpoint: checkpoint)
        _ = try store.resolveAssignment(
            sessionID: handle.sessionID,
            stage: .finalTranscription,
            attempt: 1,
            selecting: {
                try assignment(
                    stage: .finalTranscription,
                    providerKind: .batchSpeech,
                    providerIdentifier: "catalog-provider",
                    modelIdentifier: "catalog-model",
                    attempt: 1
                )
            }
        )
        _ = try store.recordMeetingTranscriptionChunk(
            handle,
            sourceChunkSequence: 0,
            startOffset: checkpoint.startOffset,
            duration: checkpoint.duration,
            text: "The release candidate ships on Friday.",
            assignmentAttempt: 1
        )
        return Fixture(
            container: container,
            store: store,
            handle: handle,
            noteID: anchor.noteID,
            typedContent: typedContent
        )
    }

    private func noteContent(_ id: UUID, in container: ModelContainer) throws -> String {
        var descriptor = FetchDescriptor<Note>(predicate: #Predicate<Note> { $0.id == id })
        descriptor.fetchLimit = 1
        return try #require(try ModelContext(container).fetch(descriptor).first).content
    }

    private func noteGenerationAssignment(attempt: Int, presetIdentifier: String) throws -> CaptureStageAssignment {
        try assignment(
            stage: .noteGeneration,
            providerKind: .generativeAI,
            providerIdentifier: UUID().uuidString,
            modelIdentifier: "generator-model",
            prompt: CapturePromptSnapshot(
                presetIdentifier: presetIdentifier,
                resolvedPrompt: "Summarize this note."
            ),
            attempt: attempt
        )
    }

    // MARK: - Attempt allocation

    @Test func firstNoteGenerationAttemptFollowsTheAttemptCaptureStartFroze() throws {
        let fixture = try makeFixture()
        #expect(try fixture.store.nextNoteGenerationAttempt(sessionID: fixture.handle.sessionID) == 1)

        _ = try fixture.store.resolveAssignment(
            sessionID: fixture.handle.sessionID,
            stage: .noteGeneration,
            attempt: 1,
            selecting: { try noteGenerationAssignment(attempt: 1, presetIdentifier: "summary") }
        )

        #expect(try fixture.store.nextNoteGenerationAttempt(sessionID: fixture.handle.sessionID) == 2)
    }

    @Test func eachAllocationTakesTheNextAttemptAndFreezesItsOwnSnapshots() throws {
        let fixture = try makeFixture()

        let first = try fixture.store.resolveNoteGenerationAssignment(
            sessionID: fixture.handle.sessionID
        ) { attempt in
            try noteGenerationAssignment(attempt: attempt, presetIdentifier: "summary")
        }
        let second = try fixture.store.resolveNoteGenerationAssignment(
            sessionID: fixture.handle.sessionID
        ) { attempt in
            try noteGenerationAssignment(attempt: attempt, presetIdentifier: "standup")
        }

        #expect(first.attempt == 1)
        #expect(second.attempt == 2)
        #expect(first.providerSnapshotID != second.providerSnapshotID)
        #expect(first.promptSnapshotID != nil)
        #expect(second.promptSnapshotID != nil)
        #expect(first.promptSnapshotID != second.promptSnapshotID)
        #expect(try fixture.store.nextNoteGenerationAttempt(sessionID: fixture.handle.sessionID) == 3)
    }

    @Test func anAllocationThatSelectsAnotherAttemptIsRejected() throws {
        let fixture = try makeFixture()

        #expect(throws: CaptureSessionStoreError.assignmentKeyMismatch) {
            try fixture.store.resolveNoteGenerationAssignment(
                sessionID: fixture.handle.sessionID
            ) { _ in
                try noteGenerationAssignment(attempt: 7, presetIdentifier: "summary")
            }
        }
    }

    @Test func attemptAllocationRequiresAKnownSession() throws {
        let container = try makeContainer()
        let store = CaptureSessionStore(modelContext: ModelContext(container))
        let sessionID = UUID()

        #expect(throws: CaptureSessionStoreError.assignmentSessionNotFound(sessionID)) {
            try store.nextNoteGenerationAttempt(sessionID: sessionID)
        }
    }

    // MARK: - Panel writes

    @Test func savingAPanelStoresItsFrozenTemplateProvenanceAndAnchorSnapshot() throws {
        let fixture = try makeFixture()
        let allocation = try fixture.store.resolveNoteGenerationAssignment(
            sessionID: fixture.handle.sessionID
        ) { attempt in
            try noteGenerationAssignment(attempt: attempt, presetIdentifier: "summary")
        }
        let savedAt = Date(timeIntervalSinceReferenceDate: 50_000)

        let panel = try fixture.store.saveEnhancedPanel(
            sessionID: fixture.handle.sessionID,
            noteID: fixture.noteID,
            templatePresetIdentifier: "summary",
            templateDisplayName: "Summary",
            content: "Ships Friday.",
            providerSnapshotID: allocation.providerSnapshotID,
            promptSnapshotID: allocation.promptSnapshotID,
            assignmentAttempt: allocation.attempt,
            provenanceJSON: "{\"evidence\":\"frozen\"}",
            humanAnchorContentSnapshot: fixture.typedContent,
            at: savedAt
        )

        #expect(panel.generation == 1)
        #expect(panel.isCurrent)
        #expect(!panel.isLegacy)
        #expect(panel.isRegenerable)
        #expect(panel.templateDisplayName == "Summary")
        #expect(panel.assignmentAttempt == allocation.attempt)
        #expect(panel.providerSnapshotID == allocation.providerSnapshotID)
        #expect(panel.promptSnapshotID == allocation.promptSnapshotID)
        #expect(panel.createdAt == savedAt)

        let stored = try #require(try fixture.store.enhancedPanel(id: panel.id))
        #expect(stored == panel)
        #expect(try fixture.store.currentPanels(noteID: fixture.noteID) == [panel])
    }

    @Test func aPanelWithNoTemplateOrNoContentIsRejected() throws {
        let fixture = try makeFixture()

        #expect(
            throws: CaptureSessionStoreError.invalidEnhancedPanel(sessionID: fixture.handle.sessionID)
        ) {
            try fixture.store.saveEnhancedPanel(
                sessionID: fixture.handle.sessionID,
                noteID: fixture.noteID,
                templatePresetIdentifier: "  ",
                templateDisplayName: "Summary",
                content: "Ships Friday.",
                assignmentAttempt: 1
            )
        }
        #expect(
            throws: CaptureSessionStoreError.invalidEnhancedPanel(sessionID: fixture.handle.sessionID)
        ) {
            try fixture.store.saveEnhancedPanel(
                sessionID: fixture.handle.sessionID,
                noteID: fixture.noteID,
                templatePresetIdentifier: "summary",
                templateDisplayName: "Summary",
                content: "\n ",
                assignmentAttempt: 1
            )
        }
        #expect(try fixture.store.enhancedPanels(noteID: fixture.noteID).isEmpty)
    }

    @Test func aPanelWriteFailsWhenItsNoteWasDeletedDuringGeneration() throws {
        let fixture = try makeFixture()
        let context = ModelContext(fixture.container)
        let noteID = fixture.noteID
        let note = try #require(try context.fetch(
            FetchDescriptor<Note>(predicate: #Predicate<Note> { $0.id == noteID })
        ).first)
        let references = try context.fetch(
            FetchDescriptor<CaptureNoteReferenceModel>(
                predicate: #Predicate<CaptureNoteReferenceModel> { $0.noteID == noteID }
            )
        )
        for reference in references {
            context.delete(reference)
        }
        context.delete(note)
        try context.save()

        #expect(throws: CaptureSessionStoreError.noteNotFound(noteID)) {
            try fixture.store.saveEnhancedPanel(
                sessionID: fixture.handle.sessionID,
                noteID: noteID,
                templatePresetIdentifier: "summary",
                templateDisplayName: "Summary",
                content: "Generation finished after deletion.",
                assignmentAttempt: 1,
                humanAnchorContentSnapshot: fixture.typedContent
            )
        }
        #expect(try fixture.store.enhancedPanels(noteID: noteID).isEmpty)
    }

    @Test func aPanelWriteFailsWhenItsHumanAnchorWasDeletedDuringGeneration() throws {
        let fixture = try makeFixture()
        let context = ModelContext(fixture.container)
        let sessionID = fixture.handle.sessionID
        let references = try context.fetch(
            FetchDescriptor<CaptureNoteReferenceModel>(
                predicate: #Predicate<CaptureNoteReferenceModel> { $0.sessionID == sessionID }
            )
        )
        for reference in references {
            context.delete(reference)
        }
        try context.save()

        #expect(throws: CaptureSessionStoreError.meetingHumanAnchorConflict(sessionID)) {
            try fixture.store.saveEnhancedPanel(
                sessionID: sessionID,
                noteID: fixture.noteID,
                templatePresetIdentifier: "summary",
                templateDisplayName: "Summary",
                content: "Generation finished after anchor deletion.",
                assignmentAttempt: 1,
                humanAnchorContentSnapshot: fixture.typedContent
            )
        }
        #expect(try fixture.store.enhancedPanels(noteID: fixture.noteID).isEmpty)
    }

    // MARK: - Regeneration

    @Test func regeneratingATemplateSupersedesThePreviousGenerationAndKeepsBothRows() throws {
        let fixture = try makeFixture()
        let firstAllocation = try fixture.store.resolveNoteGenerationAssignment(
            sessionID: fixture.handle.sessionID
        ) { attempt in
            try noteGenerationAssignment(attempt: attempt, presetIdentifier: "summary")
        }
        let first = try fixture.store.saveEnhancedPanel(
            sessionID: fixture.handle.sessionID,
            noteID: fixture.noteID,
            templatePresetIdentifier: "summary",
            templateDisplayName: "Summary",
            content: "First pass.",
            providerSnapshotID: firstAllocation.providerSnapshotID,
            promptSnapshotID: firstAllocation.promptSnapshotID,
            assignmentAttempt: firstAllocation.attempt,
            at: Date(timeIntervalSinceReferenceDate: 50_000)
        )

        let secondAllocation = try fixture.store.resolveNoteGenerationAssignment(
            sessionID: fixture.handle.sessionID
        ) { attempt in
            try noteGenerationAssignment(attempt: attempt, presetIdentifier: "summary")
        }
        let second = try fixture.store.saveEnhancedPanel(
            sessionID: fixture.handle.sessionID,
            noteID: fixture.noteID,
            templatePresetIdentifier: "summary",
            templateDisplayName: "Summary",
            content: "Second pass.",
            providerSnapshotID: secondAllocation.providerSnapshotID,
            promptSnapshotID: secondAllocation.promptSnapshotID,
            assignmentAttempt: secondAllocation.attempt,
            at: Date(timeIntervalSinceReferenceDate: 50_060)
        )

        #expect(second.generation == 2)
        #expect(second.isCurrent)
        #expect(second.assignmentAttempt == first.assignmentAttempt + 1)
        // Distinct provider and prompt snapshots: each generation stays readable
        // with the exact provider and prompt that produced it.
        #expect(second.providerSnapshotID != first.providerSnapshotID)
        #expect(second.promptSnapshotID != first.promptSnapshotID)

        let refreshedFirst = try #require(try fixture.store.enhancedPanel(id: first.id))
        #expect(refreshedFirst.supersededAt == Date(timeIntervalSinceReferenceDate: 50_060))
        #expect(!refreshedFirst.isCurrent)
        #expect(refreshedFirst.content == "First pass.")

        #expect(try fixture.store.enhancedPanels(noteID: fixture.noteID).count == 2)
        #expect(try fixture.store.currentPanels(noteID: fixture.noteID).map(\.id) == [second.id])
    }

    @Test func panelGenerationsAreIndependentForEachCaptureOnTheSameNote() throws {
        let fixture = try makeFixture()
        let first = try fixture.store.saveEnhancedPanel(
            sessionID: fixture.handle.sessionID,
            noteID: fixture.noteID,
            templatePresetIdentifier: "summary",
            templateDisplayName: "Summary",
            content: "First capture.",
            assignmentAttempt: 1,
            at: Date(timeIntervalSinceReferenceDate: 50_000)
        )
        let secondHandle = try fixture.store.startNoteCapture(
            startedAt: Date(timeIntervalSinceReferenceDate: 41_000),
            includeSystemAudio: false,
            intent: CaptureIntentRequest(
                destination: .existingNote,
                destinationNoteID: fixture.noteID,
                origin: .mainWindow
            )
        )
        _ = try fixture.store.ensureMeetingHumanAnchor(
            secondHandle,
            noteID: fixture.noteID,
            at: Date(timeIntervalSinceReferenceDate: 41_000)
        )
        let second = try fixture.store.saveEnhancedPanel(
            sessionID: secondHandle.sessionID,
            noteID: fixture.noteID,
            templatePresetIdentifier: "summary",
            templateDisplayName: "Summary",
            content: "Second capture.",
            assignmentAttempt: 1,
            at: Date(timeIntervalSinceReferenceDate: 51_000)
        )
        let regeneratedFirst = try fixture.store.saveEnhancedPanel(
            sessionID: fixture.handle.sessionID,
            noteID: fixture.noteID,
            templatePresetIdentifier: "summary",
            templateDisplayName: "Summary",
            content: "First capture regenerated later.",
            assignmentAttempt: 2,
            at: Date(timeIntervalSinceReferenceDate: 52_000)
        )

        #expect(first.generation == 1)
        #expect(second.generation == 1)
        #expect(regeneratedFirst.generation == 2)
        #expect(try fixture.store.enhancedPanel(id: first.id)?.isCurrent == false)
        #expect(try fixture.store.enhancedPanel(id: second.id)?.isCurrent == true)
        #expect(
            Set(try fixture.store.currentPanels(noteID: fixture.noteID).map(\.id))
                == Set([second.id, regeneratedFirst.id])
        )
    }

    @Test func generatingASecondTemplateLeavesTheFirstTemplatesPanelCurrent() throws {
        let fixture = try makeFixture()
        let summary = try fixture.store.saveEnhancedPanel(
            sessionID: fixture.handle.sessionID,
            noteID: fixture.noteID,
            templatePresetIdentifier: "summary",
            templateDisplayName: "Summary",
            content: "Ships Friday.",
            assignmentAttempt: 1,
            at: Date(timeIntervalSinceReferenceDate: 50_000)
        )
        let standup = try fixture.store.saveEnhancedPanel(
            sessionID: fixture.handle.sessionID,
            noteID: fixture.noteID,
            templatePresetIdentifier: "standup",
            templateDisplayName: "Standup",
            content: "Blockers: none.",
            assignmentAttempt: 2,
            at: Date(timeIntervalSinceReferenceDate: 50_060)
        )

        let current = try fixture.store.currentPanels(noteID: fixture.noteID)
        #expect(current.map(\.id) == [standup.id, summary.id])
        #expect(current.allSatisfy { $0.isCurrent })
        #expect(standup.generation == 1)
    }

    @Test func typedNotesAreByteIdenticalBeforeAndAfterGeneration() throws {
        let typed = "  Lead: Avery\n- ship Friday\n\nRaw *markdown* kept exactly  "
        let fixture = try makeFixture(typedContent: typed)
        let before = try noteContent(fixture.noteID, in: fixture.container)

        _ = try fixture.store.saveEnhancedPanel(
            sessionID: fixture.handle.sessionID,
            noteID: fixture.noteID,
            templatePresetIdentifier: "summary",
            templateDisplayName: "Summary",
            content: "Ships Friday.",
            assignmentAttempt: 1,
            humanAnchorContentSnapshot: before
        )
        _ = try fixture.store.saveEnhancedPanel(
            sessionID: fixture.handle.sessionID,
            noteID: fixture.noteID,
            templatePresetIdentifier: "summary",
            templateDisplayName: "Summary",
            content: "Ships Friday, per Avery.",
            assignmentAttempt: 2,
            humanAnchorContentSnapshot: before
        )

        #expect(before == typed)
        #expect(try noteContent(fixture.noteID, in: fixture.container) == typed)
    }

    // MARK: - Panel sources

    private func provenanceJSON(
        noteID: UUID,
        citations: [MeetingNoteCitation]
    ) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let provenance = MeetingGeneratedNoteProvenance(
            humanAnchorNoteID: noteID,
            evidenceInput: "frozen evidence",
            citations: citations,
            sourceTranscriptRevisionIDs: citations.map(\.transcriptRevisionID)
        )
        return String(decoding: try encoder.encode(provenance), as: UTF8.self)
    }

    private func citation(_ identifier: String, revisionID: UUID) -> MeetingNoteCitation {
        MeetingNoteCitation(
            identifier: identifier,
            transcriptRevisionID: revisionID,
            startTime: 10,
            endTime: 14,
            speakerLabel: "Speaker 1",
            text: "The release candidate ships on Friday."
        )
    }

    @Test func panelSourcesComeBackFromTheFrozenProvenance() throws {
        let fixture = try makeFixture()
        let revisionID = UUID()
        let citations = [
            citation("C1", revisionID: revisionID),
            citation("C2", revisionID: revisionID)
        ]
        let panel = try fixture.store.saveEnhancedPanel(
            sessionID: fixture.handle.sessionID,
            noteID: fixture.noteID,
            templatePresetIdentifier: "summary",
            templateDisplayName: "Summary",
            content: "Ships Friday.",
            assignmentAttempt: 1,
            provenanceJSON: try provenanceJSON(noteID: fixture.noteID, citations: citations),
            humanAnchorContentSnapshot: fixture.typedContent
        )

        #expect(try fixture.store.enhancedPanelCitations(panelID: panel.id) == citations)
    }

    @Test func aPanelWithNoProvenanceHasNoSources() throws {
        let fixture = try makeFixture()
        let panel = try fixture.store.saveEnhancedPanel(
            sessionID: fixture.handle.sessionID,
            noteID: fixture.noteID,
            templatePresetIdentifier: "summary",
            templateDisplayName: "Summary",
            content: "Ships Friday.",
            assignmentAttempt: 1
        )

        #expect(try fixture.store.enhancedPanelCitations(panelID: panel.id).isEmpty)
    }

    @Test func provenanceThatIsNotByteIdenticalToItselfCitesNothing() throws {
        // A blob somebody rewrote decodes fine and describes nothing this build
        // wrote, so it must not be presented as evidence.
        let fixture = try makeFixture()
        let revisionID = UUID()
        let rewritten = try provenanceJSON(
            noteID: fixture.noteID,
            citations: [citation("C1", revisionID: revisionID)]
        ) + " "
        let panel = try fixture.store.saveEnhancedPanel(
            sessionID: fixture.handle.sessionID,
            noteID: fixture.noteID,
            templatePresetIdentifier: "summary",
            templateDisplayName: "Summary",
            content: "Ships Friday.",
            assignmentAttempt: 1,
            provenanceJSON: rewritten
        )

        #expect(try fixture.store.enhancedPanelCitations(panelID: panel.id).isEmpty)
    }

    @Test func provenanceAnchoredToAnotherNoteCitesNothing() throws {
        let fixture = try makeFixture()
        let panel = try fixture.store.saveEnhancedPanel(
            sessionID: fixture.handle.sessionID,
            noteID: fixture.noteID,
            templatePresetIdentifier: "summary",
            templateDisplayName: "Summary",
            content: "Ships Friday.",
            assignmentAttempt: 1,
            provenanceJSON: try provenanceJSON(
                noteID: UUID(),
                citations: [citation("C1", revisionID: UUID())]
            )
        )

        #expect(try fixture.store.enhancedPanelCitations(panelID: panel.id).isEmpty)
    }

    @Test func readingSourcesOfAPanelThatDoesNotExistFails() throws {
        let fixture = try makeFixture()
        let panelID = UUID()

        #expect(throws: CaptureSessionStoreError.enhancedPanelNotFound(panelID)) {
            try fixture.store.enhancedPanelCitations(panelID: panelID)
        }
    }

    // MARK: - Feedback

    @Test func panelFeedbackRoundTripsAndClears() throws {
        let fixture = try makeFixture()
        let panel = try fixture.store.saveEnhancedPanel(
            sessionID: fixture.handle.sessionID,
            noteID: fixture.noteID,
            templatePresetIdentifier: "summary",
            templateDisplayName: "Summary",
            content: "Ships Friday.",
            assignmentAttempt: 1
        )

        try fixture.store.setEnhancedPanelFeedback(panelID: panel.id, feedback: .helpful)
        #expect(try fixture.store.enhancedPanel(id: panel.id)?.feedback == .helpful)

        try fixture.store.setEnhancedPanelFeedback(panelID: panel.id, feedback: nil)
        #expect(try fixture.store.enhancedPanel(id: panel.id)?.feedback == nil)

        let missing = UUID()
        #expect(throws: CaptureSessionStoreError.enhancedPanelNotFound(missing)) {
            try fixture.store.setEnhancedPanelFeedback(panelID: missing, feedback: .helpful)
        }
    }

    // MARK: - Evidence

    @Test func evidenceCarriesTheTypedNotesAndTheCompletedCheckpoints() throws {
        let fixture = try makeFixture()

        let source = try fixture.store.noteGenerationEvidence(
            sessionID: fixture.handle.sessionID,
            humanNoteContent: fixture.typedContent
        )

        #expect(source.evidenceInput.contains("<untrusted-human-notes>"))
        #expect(source.evidenceInput.contains(fixture.typedContent))
        // A microphone-only note has no diarized segments, so the whole chunk is
        // the citation.
        #expect(source.citations.count == 1)
        #expect(source.citations[0].text == "The release candidate ships on Friday.")
        #expect(source.sourceTranscriptRevisionIDs.count == 1)
    }

    @Test func aCaptureWithNoTranscriptHasNothingToEnhance() throws {
        let container = try makeContainer()
        let store = CaptureSessionStore(modelContext: ModelContext(container))
        let handle = try store.startNoteCapture(
            startedAt: Date(timeIntervalSinceReferenceDate: 60_000),
            includeSystemAudio: false,
            intent: CaptureIntentRequest(destination: .newNote, origin: .mainWindow)
        )

        #expect(throws: MeetingNoteDerivationError.noTranscriptSources) {
            try store.noteGenerationEvidence(
                sessionID: handle.sessionID,
                humanNoteContent: "Typed only."
            )
        }
    }

    // MARK: - Legacy generated notes

    @Test func aLegacyGeneratedMeetingNoteReadsAsAReadOnlyPanel() throws {
        let container = try makeContainer()
        let store = CaptureSessionStore(modelContext: ModelContext(container))
        let startedAt = Date(timeIntervalSinceReferenceDate: 70_000)
        let handle = try store.startMeetingCapture(startedAt: startedAt)
        let anchor = try store.ensureMeetingHumanAnchor(handle, title: "Planning", at: startedAt)

        // Exactly the row shape older builds wrote: a second note plus a
        // `generated` reference. Neither is touched by the projection.
        let context = ModelContext(container)
        let generatedNote = Note(
            title: "Planning",
            content: "Decisions: ship Friday.",
            tags: [],
            sourceTranscriptionID: nil,
            createdAt: startedAt,
            updatedAt: startedAt
        )
        context.insert(generatedNote)
        let providerSnapshotID = UUID()
        context.insert(CaptureNoteReferenceModel(
            sessionID: handle.sessionID,
            noteID: generatedNote.id,
            role: .generated,
            sourceTranscriptRevisionID: nil,
            providerSnapshotID: providerSnapshotID,
            provenanceJSON: "{\"legacy\":true}",
            humanAnchorContentSnapshot: "",
            createdAt: startedAt
        ))
        try context.save()

        let panel = try #require(try store.legacyEnhancedPanel(noteID: anchor.noteID))
        #expect(panel.isLegacy)
        #expect(!panel.isRegenerable)
        #expect(panel.noteID == anchor.noteID)
        #expect(panel.id == generatedNote.id)
        #expect(panel.content == "Decisions: ship Friday.")
        #expect(panel.templateDisplayName == CaptureEnhancedPanelSnapshot.legacyMeetingNoteDisplayName)
        #expect(
            panel.templatePresetIdentifier
                == CaptureEnhancedPanelSnapshot.legacyMeetingNoteTemplateIdentifier
        )
        #expect(panel.providerSnapshotID == providerSnapshotID)
        // The legacy rows are untouched: the strict validator still reads them.
        #expect(try noteContent(generatedNote.id, in: container) == "Decisions: ship Friday.")
        // A legacy note is not an enhanced panel row.
        #expect(try store.enhancedPanels(noteID: anchor.noteID).isEmpty)
    }

    @Test func aNoteWithNoLegacyGeneratedOutputHasNoLegacyPanel() throws {
        let fixture = try makeFixture()

        #expect(try fixture.store.legacyEnhancedPanel(noteID: fixture.noteID) == nil)
        #expect(try fixture.store.legacyEnhancedPanel(noteID: UUID()) == nil)
    }

    // MARK: - Save as note

    @Test func savingAPanelAsANoteCopiesItsContentWithoutTouchingThePanel() throws {
        let fixture = try makeFixture()
        let panel = try fixture.store.saveEnhancedPanel(
            sessionID: fixture.handle.sessionID,
            noteID: fixture.noteID,
            templatePresetIdentifier: "summary",
            templateDisplayName: "Summary",
            content: "Decisions: ship Friday.",
            assignmentAttempt: 1
        )

        let copyID = try fixture.store.saveEnhancedPanelAsNote(
            panelID: panel.id,
            title: "Release decisions",
            at: Date(timeIntervalSinceReferenceDate: 80_000)
        )

        #expect(copyID != fixture.noteID)
        #expect(try noteContent(copyID, in: fixture.container) == "Decisions: ship Friday.")
        // The typed notes and the panel are unchanged.
        #expect(try noteContent(fixture.noteID, in: fixture.container) == fixture.typedContent)
        #expect(try fixture.store.enhancedPanel(id: panel.id) == panel)
        // The copy is a plain note: it claims no capture reference of its own.
        let references = try ModelContext(fixture.container)
            .fetch(FetchDescriptor<CaptureNoteReferenceModel>())
        #expect(!references.contains { $0.noteID == copyID })
    }

    @Test func savingAPanelAsANoteFallsBackToTheFrozenTemplateName() throws {
        let fixture = try makeFixture()
        let panel = try fixture.store.saveEnhancedPanel(
            sessionID: fixture.handle.sessionID,
            noteID: fixture.noteID,
            templatePresetIdentifier: "summary",
            templateDisplayName: "Summary",
            content: "Decisions: ship Friday.",
            assignmentAttempt: 1
        )

        let copyID = try fixture.store.saveEnhancedPanelAsNote(panelID: panel.id, title: "   ")

        var descriptor = FetchDescriptor<Note>(predicate: #Predicate<Note> { $0.id == copyID })
        descriptor.fetchLimit = 1
        let copy = try #require(try ModelContext(fixture.container).fetch(descriptor).first)
        #expect(copy.title == "Summary")

        let missing = UUID()
        #expect(throws: CaptureSessionStoreError.enhancedPanelNotFound(missing)) {
            try fixture.store.saveEnhancedPanelAsNote(panelID: missing)
        }
    }
}
