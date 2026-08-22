//
//  CaptureSessionStoreNoteViewsTests.swift
//  PindropDataTests
//
//  Created on 2026-08-22.
//
//  One suite per note shape this build has to open: a legacy meeting note, a
//  legacy voice note, a plain typed note, and a note with enhanced panels. Every
//  one of them asserts the whole triple, because a note page that resolves two
//  of the three views is a page that draws the wrong thing.
//

import Foundation
import PindropCore
import SwiftData
import Testing
@testable import PindropData

@MainActor
@Suite(.serialized)
struct CaptureSessionStoreNoteViewsTests {

    // MARK: - Shared fixture builders

    private func makeContainer() throws -> ModelContainer {
        try PindropModelContainerFactory.makeInMemoryContainer()
    }

    private func makeStore(in container: ModelContainer) -> CaptureSessionStore {
        CaptureSessionStore(modelContext: ModelContext(container))
    }

    private func assignment(
        stage: CapturePipelineStage,
        providerKind: CaptureAssignmentProviderKind = .batchSpeech,
        providerIdentifier: String = "catalog-provider",
        modelIdentifier: String? = "catalog-model",
        prompt: CapturePromptSnapshot? = nil,
        attempt: Int = 1,
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

    private func segmentsJSON(_ segments: [DiarizedTranscriptSegment]) throws -> String {
        String(decoding: try JSONEncoder().encode(segments), as: UTF8.self)
    }

    private func setNoteContent(
        _ noteID: UUID,
        to content: String,
        in container: ModelContainer
    ) throws {
        let context = ModelContext(container)
        var descriptor = FetchDescriptor<Note>(predicate: #Predicate<Note> { $0.id == noteID })
        descriptor.fetchLimit = 1
        let note = try #require(try context.fetch(descriptor).first)
        note.content = content
        try context.save()
    }

    private func noteContent(_ id: UUID, in container: ModelContainer) throws -> String {
        var descriptor = FetchDescriptor<Note>(predicate: #Predicate<Note> { $0.id == id })
        descriptor.fetchLimit = 1
        return try #require(try ModelContext(container).fetch(descriptor).first).content
    }

    /// A finished note capture with typed notes, one sealed chunk, and one
    /// completed final-ASR revision. `diarized` decides whether that revision
    /// carries two speaker turns or only the whole-chunk text.
    private struct RecordedNote {
        let container: ModelContainer
        let store: CaptureSessionStore
        let handle: NoteCaptureHandle
        let noteID: UUID
        let typedContent: String
        let revisionID: UUID
        let chunkDuration: TimeInterval
    }

    private nonisolated static let twoSpeakerText = "Completed final transcript"

    private func twoSpeakerSegments(chunkDuration: TimeInterval) -> [DiarizedTranscriptSegment] {
        [
            DiarizedTranscriptSegment(
                speakerId: "speaker-1",
                speakerLabel: "Speaker 1",
                startTime: 0,
                endTime: chunkDuration / 2,
                confidence: 1,
                text: "Completed final"
            ),
            DiarizedTranscriptSegment(
                speakerId: "speaker-2",
                speakerLabel: "Speaker 2",
                startTime: chunkDuration / 2,
                endTime: chunkDuration,
                confidence: 1,
                text: "transcript"
            )
        ]
    }

    private func makeRecordedNote(
        includeSystemAudio: Bool = true,
        typedContent: String = "My own notes about the release.",
        segments: ((TimeInterval) -> [DiarizedTranscriptSegment])? = nil,
        text: String = twoSpeakerText,
        startedAt: Date = Date(timeIntervalSinceReferenceDate: 40_000)
    ) throws -> RecordedNote {
        let container = try makeContainer()
        let store = makeStore(in: container)
        let handle = try store.startNoteCapture(
            startedAt: startedAt,
            includeSystemAudio: includeSystemAudio,
            intent: CaptureIntentRequest(destination: .newNote, origin: .mainWindow)
        )
        let anchor = try store.ensureMeetingHumanAnchor(
            handle,
            title: "Release review",
            at: startedAt
        )
        try setNoteContent(anchor.noteID, to: typedContent, in: container)

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
            selecting: { try assignment(stage: .finalTranscription) }
        )
        let encoded = try segments.map { try segmentsJSON($0(checkpoint.duration)) }
        let revisionID = try store.recordMeetingTranscriptionChunk(
            handle,
            sourceChunkSequence: 0,
            startOffset: checkpoint.startOffset,
            duration: checkpoint.duration,
            text: text,
            segmentsJSON: encoded,
            assignmentAttempt: 1
        )
        return RecordedNote(
            container: container,
            store: store,
            handle: handle,
            noteID: anchor.noteID,
            typedContent: typedContent,
            revisionID: revisionID,
            chunkDuration: checkpoint.duration
        )
    }

    // MARK: - Legacy meeting note

    @Test func aLegacyMeetingNoteResolvesToTypedNotesAReadOnlyPanelAndItsDiarizedTranscript() throws {
        let recorded = try makeRecordedNote(segments: twoSpeakerSegments)
        // Exactly the rows an older build wrote for a generated meeting note: a
        // second note plus a `generated` reference carrying its citations.
        let context = ModelContext(recorded.container)
        let generated = Note(
            title: "Release review",
            content: "Decisions: ship Friday.",
            tags: [],
            sourceTranscriptionID: nil,
            createdAt: Date(timeIntervalSinceReferenceDate: 41_000),
            updatedAt: Date(timeIntervalSinceReferenceDate: 41_000)
        )
        context.insert(generated)
        context.insert(CaptureNoteReferenceModel(
            sessionID: recorded.handle.sessionID,
            noteID: generated.id,
            role: .generated,
            sourceTranscriptRevisionID: recorded.revisionID,
            providerSnapshotID: UUID(),
            provenanceJSON: "{\"legacy\":true}",
            humanAnchorContentSnapshot: recorded.typedContent,
            createdAt: Date(timeIntervalSinceReferenceDate: 41_000)
        ))
        try context.save()

        let views = try recorded.store.noteCaptureViews(noteID: recorded.noteID)

        #expect(views.typedNotes?.id == recorded.noteID)
        #expect(views.typedNotes?.content == recorded.typedContent)

        #expect(views.panels.count == 1)
        let panel = try #require(views.panels.first)
        #expect(panel.isLegacy)
        #expect(!panel.isRegenerable)
        #expect(panel.content == "Decisions: ship Friday.")
        #expect(
            panel.templatePresetIdentifier
                == CaptureEnhancedPanelSnapshot.legacyMeetingNoteTemplateIdentifier
        )

        let transcript = try #require(views.transcript)
        #expect(!transcript.isLive)
        #expect(transcript.segments.map(\.text) == ["Completed final", "transcript"])
        #expect(transcript.segments.map(\.speakerLabel) == ["Speaker 1", "Speaker 2"])
        #expect(transcript.segments.map(\.speakerNumber) == [1, 2])
        #expect(transcript.speakerCount == 2)
        #expect(transcript.duration == recorded.chunkDuration)
        #expect(transcript.segments.allSatisfy { $0.revisionID == recorded.revisionID })

        let captureState = try #require(views.captureState)
        #expect(captureState.handle.sessionID == recorded.handle.sessionID)
        #expect(captureState.capturesSystemAudio)
        #expect(views.availableViews == [.humanNotes, .enhanced, .transcript])
    }

    // MARK: - Legacy voice note

    @Test func aLegacyVoiceNoteResolvesToTypedNotesNoPanelsAndItsCorrectedTranscript() throws {
        let container = try makeContainer()
        let store = makeStore(in: container)
        let startedAt = Date(timeIntervalSinceReferenceDate: 50_000)
        let handle = try store.startVoiceNoteCapture(startedAt: startedAt)
        try store.beginFinalization(handle, at: startedAt.addingTimeInterval(1))
        let revisions = try store.saveTranscriptRevisions(
            for: handle,
            rawText: "raw transcript with wobbles",
            finalText: "Final transcript.",
            duration: 8,
            languageCode: "en",
            createdAt: startedAt.addingTimeInterval(2)
        )
        let context = ModelContext(container)
        let note = Note(
            title: "Voice note",
            content: "What I typed afterwards.",
            tags: [],
            sourceTranscriptionID: nil,
            createdAt: startedAt,
            updatedAt: startedAt
        )
        context.insert(note)
        try context.save()
        try store.complete(
            handle,
            noteID: note.id,
            finalTranscriptRevisionID: revisions.finalRevisionID,
            at: startedAt.addingTimeInterval(3)
        )

        let views = try store.noteCaptureViews(noteID: note.id)

        #expect(views.typedNotes?.content == "What I typed afterwards.")
        #expect(views.panels.isEmpty)

        let transcript = try #require(views.transcript)
        // The raw revision is the same speech said twice: only the corrected
        // leaf of the chain is read.
        #expect(transcript.segments.map(\.text) == ["Final transcript."])
        #expect(transcript.segments.map(\.revisionID) == [revisions.finalRevisionID])
        // One microphone, one speaker: the person recording.
        #expect(transcript.segments.map(\.speakerLabel) == ["You"])
        #expect(transcript.segments.allSatisfy { $0.isCurrentUser })
        #expect(transcript.speakerCount == 1)
        #expect(!transcript.isLive)

        let captureState = try #require(views.captureState)
        #expect(captureState.mode == .voiceNote)
        #expect(captureState.state == .completed)
        #expect(!captureState.capturesSystemAudio)
        #expect(views.availableViews == [.humanNotes, .transcript])
    }

    // MARK: - Plain typed note

    @Test func aNoteNobodyRecordedResolvesToTypedNotesOnly() throws {
        let container = try makeContainer()
        let store = makeStore(in: container)
        let context = ModelContext(container)
        let note = Note(
            title: "Groceries",
            content: "Milk, bread.",
            tags: ["home"],
            sourceTranscriptionID: nil,
            createdAt: Date(timeIntervalSinceReferenceDate: 60_000),
            updatedAt: Date(timeIntervalSinceReferenceDate: 60_060)
        )
        context.insert(note)
        try context.save()

        let views = try store.noteCaptureViews(noteID: note.id)

        #expect(views.noteID == note.id)
        #expect(views.typedNotes?.title == "Groceries")
        #expect(views.typedNotes?.content == "Milk, bread.")
        #expect(views.typedNotes?.updatedAt == Date(timeIntervalSinceReferenceDate: 60_060))
        #expect(views.panels.isEmpty)
        #expect(views.transcript == nil)
        #expect(views.captureState == nil)
        #expect(!views.isRecorded)
        #expect(views.availableViews == [.humanNotes])
        #expect(views.selectedView == .humanNotes)
    }

    @Test func aNoteIdentifierNothingWasEverWrittenForResolvesEmpty() throws {
        let container = try makeContainer()
        let store = makeStore(in: container)

        let views = try store.noteCaptureViews(noteID: UUID())

        #expect(views.typedNotes == nil)
        #expect(views.panels.isEmpty)
        #expect(views.transcript == nil)
        #expect(views.captureState == nil)
    }

    // MARK: - A note with enhanced panels

    @Test func aNoteWithPanelsResolvesToTheCurrentPanelOfEveryTemplate() throws {
        let recorded = try makeRecordedNote(segments: twoSpeakerSegments)
        let superseded = try recorded.store.saveEnhancedPanel(
            sessionID: recorded.handle.sessionID,
            noteID: recorded.noteID,
            templatePresetIdentifier: "summary",
            templateDisplayName: "Summary",
            content: "First pass.",
            assignmentAttempt: 2,
            at: Date(timeIntervalSinceReferenceDate: 41_000)
        )
        let current = try recorded.store.saveEnhancedPanel(
            sessionID: recorded.handle.sessionID,
            noteID: recorded.noteID,
            templatePresetIdentifier: "summary",
            templateDisplayName: "Summary",
            content: "Second pass.",
            assignmentAttempt: 3,
            at: Date(timeIntervalSinceReferenceDate: 41_060)
        )
        let standup = try recorded.store.saveEnhancedPanel(
            sessionID: recorded.handle.sessionID,
            noteID: recorded.noteID,
            templatePresetIdentifier: "standup",
            templateDisplayName: "Standup",
            content: "Blockers: none.",
            assignmentAttempt: 4,
            at: Date(timeIntervalSinceReferenceDate: 41_120)
        )

        let views = try recorded.store.noteCaptureViews(noteID: recorded.noteID)

        #expect(views.panels.map(\.id) == [standup.id, current.id])
        #expect(!views.panels.contains { $0.id == superseded.id })
        #expect(views.typedNotes?.content == recorded.typedContent)
        #expect(views.transcript?.segments.count == 2)
        #expect(views.captureState?.mode == .note)
        #expect(views.availableViews == [.humanNotes, .enhanced, .transcript])
        #expect(views.panel(for: .enhanced(templatePresetIdentifier: "summary"))?.id == current.id)
        // An unknown template falls back to the newest panel instead of nothing.
        #expect(views.panel(for: .enhanced(templatePresetIdentifier: "unknown"))?.id == standup.id)
    }

    // MARK: - Transcript deletion

    @Test func deletingATranscriptHidesItAndLeavesTheNotesPanelsAndRevisions() throws {
        let recorded = try makeRecordedNote(segments: twoSpeakerSegments)
        let panel = try recorded.store.saveEnhancedPanel(
            sessionID: recorded.handle.sessionID,
            noteID: recorded.noteID,
            templatePresetIdentifier: "summary",
            templateDisplayName: "Summary",
            content: "Ships Friday.",
            assignmentAttempt: 2
        )
        #expect(try recorded.store.noteCaptureViews(noteID: recorded.noteID).transcript != nil)

        let deletedAt = try recorded.store.deleteTranscript(
            noteID: recorded.noteID,
            at: Date(timeIntervalSinceReferenceDate: 42_000)
        )
        let views = try recorded.store.noteCaptureViews(noteID: recorded.noteID)

        #expect(deletedAt == Date(timeIntervalSinceReferenceDate: 42_000))
        #expect(views.transcript == nil)
        #expect(views.isTranscriptDeleted)
        #expect(views.transcriptDeletedAt == deletedAt)
        #expect(views.availableViews == [.humanNotes, .enhanced])
        // The typed notes, the panel, and the recording behind them are intact.
        #expect(try noteContent(recorded.noteID, in: recorded.container) == recorded.typedContent)
        #expect(views.panels.map(\.id) == [panel.id])
        #expect(views.captureState?.handle.sessionID == recorded.handle.sessionID)
        let revisions = try ModelContext(recorded.container)
            .fetch(FetchDescriptor<CaptureTranscriptRevisionModel>())
        #expect(revisions.contains { $0.id == recorded.revisionID })

        // Repeating the call reports the first deletion time.
        let repeated = try recorded.store.deleteTranscript(
            noteID: recorded.noteID,
            at: Date(timeIntervalSinceReferenceDate: 43_000)
        )
        #expect(repeated == deletedAt)
    }

    // MARK: - Live fallback

    @Test func aRunningCaptureReadsItsCommittedLiveTranscript() throws {
        let container = try makeContainer()
        let store = makeStore(in: container)
        let startedAt = Date(timeIntervalSinceReferenceDate: 70_000)
        let handle = try store.startNoteCapture(
            startedAt: startedAt,
            includeSystemAudio: false,
            intent: CaptureIntentRequest(destination: .newNote, origin: .mainWindow)
        )
        let anchor = try store.ensureMeetingHumanAnchor(handle, title: "Live", at: startedAt)
        _ = try store.resolveAssignment(
            sessionID: handle.sessionID,
            stage: .liveTranscription,
            attempt: 1,
            selecting: {
                try assignment(
                    stage: .liveTranscription,
                    providerKind: .streamingSpeech,
                    providerIdentifier: "streaming-provider",
                    modelIdentifier: "streaming-model"
                )
            }
        )
        _ = try store.checkpointVoiceNoteLiveTranscript(
            for: handle,
            committedText: "Hello",
            at: startedAt.addingTimeInterval(1)
        )
        let latest = try store.checkpointVoiceNoteLiveTranscript(
            for: handle,
            committedText: "Hello, this is what I said so far",
            at: startedAt.addingTimeInterval(2)
        )

        let views = try store.noteCaptureViews(noteID: anchor.noteID)
        let transcript = try #require(views.transcript)

        #expect(transcript.isLive)
        #expect(transcript.segments.map(\.text) == ["Hello, this is what I said so far"])
        #expect(transcript.segments.map(\.revisionID) == [latest.revisionID])
        #expect(transcript.segments.map(\.speakerLabel) == ["You"])
        #expect(transcript.duration == 0)
        #expect(transcript.speakerCount == 1)
        #expect(views.captureState?.isRecording == true)
        #expect(views.availableViews == [.humanNotes, .transcript])
    }

    @Test func aCommittedFinalTranscriptReplacesTheLiveOne() throws {
        let recorded = try makeRecordedNote(includeSystemAudio: false, segments: nil)

        let transcript = try #require(
            try recorded.store.noteCaptureViews(noteID: recorded.noteID).transcript
        )

        #expect(!transcript.isLive)
        // No usable diarization: the whole revision is one span.
        #expect(transcript.segments.map(\.text) == [Self.twoSpeakerText])
        #expect(transcript.segments.map(\.speakerLabel) == ["You"])
        #expect(transcript.duration == recorded.chunkDuration)
    }

    @Test func aCaptureThatProducedNothingHasNoTranscript() throws {
        let container = try makeContainer()
        let store = makeStore(in: container)
        let startedAt = Date(timeIntervalSinceReferenceDate: 80_000)
        let handle = try store.startNoteCapture(
            startedAt: startedAt,
            includeSystemAudio: false,
            intent: CaptureIntentRequest(destination: .newNote, origin: .mainWindow)
        )
        let anchor = try store.ensureMeetingHumanAnchor(handle, title: "Silence", at: startedAt)

        let views = try store.noteCaptureViews(noteID: anchor.noteID)

        #expect(views.transcript == nil)
        #expect(views.captureState?.isRecording == true)
        #expect(views.availableViews == [.humanNotes])
    }

    // MARK: - View-state round trip

    @Test func theSelectedViewRoundTripsAndFallsBackWhenItCannotBeShown() throws {
        let recorded = try makeRecordedNote(segments: twoSpeakerSegments)
        let panel = try recorded.store.saveEnhancedPanel(
            sessionID: recorded.handle.sessionID,
            noteID: recorded.noteID,
            templatePresetIdentifier: "summary",
            templateDisplayName: "Summary",
            content: "Ships Friday.",
            assignmentAttempt: 2
        )

        #expect(try recorded.store.selectedView(noteID: recorded.noteID) == nil)
        #expect(try recorded.store.noteCaptureViews(noteID: recorded.noteID).selectedView == .humanNotes)

        try recorded.store.selectView(noteID: recorded.noteID, kind: .transcript)
        #expect(try recorded.store.selectedView(noteID: recorded.noteID) == .transcript)
        #expect(try recorded.store.noteCaptureViews(noteID: recorded.noteID).selectedView == .transcript)

        try recorded.store.selectView(
            noteID: recorded.noteID,
            selection: .enhanced(templatePresetIdentifier: "summary")
        )
        #expect(
            try recorded.store.selectedView(noteID: recorded.noteID)
                == .enhanced(templatePresetIdentifier: "summary")
        )
        let enhancedViews = try recorded.store.noteCaptureViews(noteID: recorded.noteID)
        #expect(enhancedViews.selectedView == panel.viewSelection)

        // A deleted transcript must not leave the note opening on nothing.
        try recorded.store.selectView(noteID: recorded.noteID, kind: .transcript)
        try recorded.store.deleteTranscript(noteID: recorded.noteID)
        let afterDeletion = try recorded.store.noteCaptureViews(noteID: recorded.noteID)
        #expect(afterDeletion.storedSelection == .transcript)
        #expect(afterDeletion.selectedView == .humanNotes)
    }

    @Test func aStoredPanelViewWithNoPanelBehindItFallsBackToTheTypedNotes() throws {
        let recorded = try makeRecordedNote(segments: twoSpeakerSegments)

        try recorded.store.selectView(
            noteID: recorded.noteID,
            selection: .enhanced(templatePresetIdentifier: "never-generated")
        )
        let views = try recorded.store.noteCaptureViews(noteID: recorded.noteID)

        #expect(views.panels.isEmpty)
        #expect(views.storedSelection == .enhanced(templatePresetIdentifier: "never-generated"))
        #expect(views.selectedView == .humanNotes)
        #expect(views.availableViews == [.humanNotes, .transcript])
    }

    @Test func viewStateIsRememberedForANoteNobodyRecorded() throws {
        let container = try makeContainer()
        let store = makeStore(in: container)
        let context = ModelContext(container)
        let note = Note(title: "Plain", content: "Body.", tags: [])
        context.insert(note)
        try context.save()

        try store.selectView(noteID: note.id, kind: .humanNotes)

        #expect(try store.selectedView(noteID: note.id) == .humanNotes)
        #expect(try store.noteCaptureViews(noteID: note.id).selectedView == .humanNotes)
    }

    // MARK: - Diarization parity

    @Test func transcriptSpansMatchTheCitationsGeneratedFromTheSameRevisions() throws {
        let recorded = try makeRecordedNote(segments: twoSpeakerSegments)

        let evidence = try recorded.store.noteGenerationEvidence(
            sessionID: recorded.handle.sessionID,
            humanNoteContent: recorded.typedContent
        )
        let transcript = try #require(
            try recorded.store.noteCaptureViews(noteID: recorded.noteID).transcript
        )

        // A citation marker has to land on a span that is on screen, so both
        // sides resolve their spans through the same acceptance rule.
        #expect(evidence.citations.count == transcript.segments.count)
        for (citation, segment) in zip(evidence.citations, transcript.segments) {
            #expect(citation.transcriptRevisionID == segment.revisionID)
            #expect(citation.text == segment.text)
            #expect(citation.startTime == segment.startOffset)
            #expect(citation.endTime == segment.endOffset)
        }
    }

    @Test func unusableDiarizationReadsAsOneSpanOnBothSides() throws {
        // Segments whose joined text is not the revision's text: enrichment this
        // build cannot trust, on either side.
        let recorded = try makeRecordedNote(
            includeSystemAudio: true,
            segments: { duration in
                [
                    DiarizedTranscriptSegment(
                        speakerId: "speaker-1",
                        speakerLabel: "Speaker 1",
                        startTime: 0,
                        endTime: duration,
                        confidence: 1,
                        text: "Something else entirely"
                    )
                ]
            }
        )

        let evidence = try recorded.store.noteGenerationEvidence(
            sessionID: recorded.handle.sessionID,
            humanNoteContent: recorded.typedContent
        )
        let transcript = try #require(
            try recorded.store.noteCaptureViews(noteID: recorded.noteID).transcript
        )

        #expect(evidence.citations.map(\.text) == [Self.twoSpeakerText])
        #expect(transcript.segments.map(\.text) == [Self.twoSpeakerText])
        // Two sources and no usable attribution: nobody is named.
        #expect(transcript.segments.map(\.speakerLabel) == [nil])
        #expect(transcript.speakerCount == 0)
    }

    @Test func malformedSegmentPayloadDegradesToTheWholeRevision() throws {
        let recorded = try makeRecordedNote(includeSystemAudio: true, segments: nil)
        let context = ModelContext(recorded.container)
        let revisionID = recorded.revisionID
        var descriptor = FetchDescriptor<CaptureTranscriptRevisionModel>(
            predicate: #Predicate<CaptureTranscriptRevisionModel> { $0.id == revisionID }
        )
        descriptor.fetchLimit = 1
        let revision = try #require(try context.fetch(descriptor).first)
        revision.segmentsJSON = "{not json"
        try context.save()

        let transcript = try #require(
            try recorded.store.noteCaptureViews(noteID: recorded.noteID).transcript
        )

        #expect(transcript.segments.map(\.text) == [Self.twoSpeakerText])
        #expect(transcript.segments.map(\.speakerLabel) == [nil])
    }

    // MARK: - Speaker attribution

    @Test func aMatchedParticipantProfileNamesTheSpeaker() throws {
        let recorded = try makeRecordedNote(segments: nil, text: "Avery said this.")
        let context = ModelContext(recorded.container)
        let avery = ParticipantProfile(normalizedName: "avery", displayName: "Avery")
        let me = ParticipantProfile(
            normalizedName: "me",
            displayName: "Me",
            isCurrentUser: true
        )
        context.insert(avery)
        context.insert(me)
        let revisionID = recorded.revisionID
        var descriptor = FetchDescriptor<CaptureTranscriptRevisionModel>(
            predicate: #Predicate<CaptureTranscriptRevisionModel> { $0.id == revisionID }
        )
        descriptor.fetchLimit = 1
        let revision = try #require(try context.fetch(descriptor).first)
        revision.segmentsJSON = try segmentsJSON([
            DiarizedTranscriptSegment(
                speakerId: "speaker-1",
                speakerLabel: "Speaker 1",
                speakerProfileID: avery.id,
                startTime: 0,
                endTime: recorded.chunkDuration / 2,
                confidence: 1,
                text: "Avery said"
            ),
            DiarizedTranscriptSegment(
                speakerId: "speaker-2",
                speakerLabel: "Speaker 2",
                speakerProfileID: me.id,
                startTime: recorded.chunkDuration / 2,
                endTime: recorded.chunkDuration,
                confidence: 1,
                text: "this."
            )
        ])
        try context.save()

        let transcript = try #require(
            try recorded.store.noteCaptureViews(noteID: recorded.noteID).transcript
        )

        #expect(transcript.segments.map(\.speakerLabel) == ["Avery", "You"])
        #expect(transcript.segments.map(\.speakerNumber) == [nil, nil])
        #expect(transcript.segments.map(\.isCurrentUser) == [false, true])
        #expect(transcript.segments.map(\.speakerProfileID) == [avery.id, me.id])
        #expect(transcript.speakerCount == 2)
    }

    @Test func aMicrophoneOnlyCaptureWithSeveralSpeakersStillNumbersThem() throws {
        let recorded = try makeRecordedNote(
            includeSystemAudio: false,
            segments: twoSpeakerSegments
        )

        let transcript = try #require(
            try recorded.store.noteCaptureViews(noteID: recorded.noteID).transcript
        )

        // One microphone can still record a room. "You" is only right when the
        // capture found exactly one speaker.
        #expect(transcript.segments.map(\.speakerLabel) == ["Speaker 1", "Speaker 2"])
        #expect(transcript.segments.allSatisfy { !$0.isCurrentUser })
    }
}
