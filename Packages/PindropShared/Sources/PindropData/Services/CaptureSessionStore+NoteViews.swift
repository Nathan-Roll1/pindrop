//
//  CaptureSessionStore+NoteViews.swift
//  PindropData
//
//  Created on 2026-08-22.
//
//  One read for the whole note page.
//
//  The typed notes, the generated panels, and the transcript are three views of
//  one note, and a page that draws them has to agree with itself about which of
//  them exist. Resolving them in one pass is what makes that true: the same
//  capture, the same view state, and the same transcript revisions answer every
//  part of the triple.
//
//  Reading is never destructive. Deleting a transcript hides it from this read
//  and touches nothing else: the audio, the revisions, the typed notes, and the
//  panels derived from them all stay exactly as they were.
//

import Foundation
import PindropCore
import SwiftData

extension CaptureSessionStore {

    // MARK: - The three views

    /// The typed notes, the current panels, the transcript, and the capture
    /// behind them, resolved together.
    ///
    /// Every note resolves, recorded or not. A note nobody recorded has typed
    /// notes, no panels, no transcript, and no capture state, so one note page
    /// can draw a plain note and a note that records without asking which it is.
    public func noteCaptureViews(noteID: UUID) throws -> NoteCaptureViews {
        let context = ModelContext(modelContainer)
        let typedNotes = try fetchNote(id: noteID, in: context).map(typedNotesSnapshot)
        let viewState = try noteViewStateModel(noteID: noteID, in: context)
        let transcriptDeletedAt = viewState?.transcriptDeletedAt

        var panels = try currentPanels(noteID: noteID)
        if let legacy = try legacyEnhancedPanel(noteID: noteID) {
            // Older builds wrote their generated output as a second note. It is
            // shown after everything this build generated, and never rewritten.
            panels.append(legacy)
        }

        guard let anchorReference = try humanAnchorReference(noteID: noteID, in: context) else {
            return NoteCaptureViews(
                noteID: noteID,
                typedNotes: typedNotes,
                panels: panels,
                transcript: nil,
                captureState: nil,
                storedSelection: viewState?.resolvedSelection(),
                transcriptDeletedAt: transcriptDeletedAt
            )
        }

        let sessionID = anchorReference.sessionID
        let sessionModel = try fetchSession(id: sessionID, in: context)
        let session = try sessionModel.restoreSession()
        let handle = try noteCaptureHandle(sessionID: sessionID, in: context)
        let captureState = NoteCaptureSessionSnapshot(
            handle: handle,
            mode: session.mode,
            state: session.state,
            startedAt: session.startedAt,
            endedAt: session.endedAt,
            transcriptionRecordID: sessionModel.transcriptionRecordID,
            // One fetch for one note page, because the recovered state is
            // derived from the failure records rather than written on the note.
            wasRecovered: try wasRecovered(sessionID: sessionID, in: context)
        )

        let transcript = transcriptDeletedAt == nil
            ? try transcriptView(
                handle: handle,
                session: session,
                transcriptionRecordID: sessionModel.transcriptionRecordID,
                in: context
            )
            : nil

        return NoteCaptureViews(
            noteID: noteID,
            typedNotes: typedNotes,
            panels: panels,
            transcript: transcript,
            captureState: captureState,
            storedSelection: viewState?.resolvedSelection(),
            transcriptDeletedAt: transcriptDeletedAt
        )
    }

    /// True when startup recovery finished an interruption for this capture.
    ///
    /// The single derivation lives on `CaptureFailureRecordModel`, so this page
    /// and the library list cannot disagree about which notes are recovered.
    private func wasRecovered(sessionID: UUID, in context: ModelContext) throws -> Bool {
        do {
            return try context.fetch(
                CaptureFailureRecordModel.recoveredInterruptionsDescriptor(sessionID: sessionID)
            ).isEmpty == false
        } catch {
            throw CaptureSessionStoreError.fetchFailed(error.localizedDescription)
        }
    }

    // MARK: - Library cross-link

    /// The note a library record belongs to, when the record came out of a note
    /// capture. Nil for dictations, imports, and links: they have no note page.
    public func noteID(forTranscriptionRecordID recordID: UUID) throws -> UUID? {
        let context = ModelContext(modelContainer)
        var sessionDescriptor = FetchDescriptor<CaptureSessionModel>(
            predicate: #Predicate<CaptureSessionModel> {
                $0.transcriptionRecordID == recordID
            }
        )
        sessionDescriptor.fetchLimit = 1
        do {
            guard let session = try context.fetch(sessionDescriptor).first else {
                return nil
            }
            let sessionID = session.id
            let references = try context.fetch(
                FetchDescriptor<CaptureNoteReferenceModel>(
                    predicate: #Predicate<CaptureNoteReferenceModel> {
                        $0.sessionID == sessionID
                    }
                )
            )
            return references.first { (try? $0.resolvedRole()) == .humanAnchor }?.noteID
        } catch {
            throw CaptureSessionStoreError.fetchFailed(error.localizedDescription)
        }
    }

    // MARK: - View state

    /// The view this note was last left in, or nil when nothing is stored and
    /// when the stored view belongs to a build this one cannot read.
    public func selectedView(noteID: UUID) throws -> CaptureNoteViewSelection? {
        let context = ModelContext(modelContainer)
        return try noteViewStateModel(noteID: noteID, in: context)?.resolvedSelection()
    }

    /// Remembers which view a note opens in.
    public func selectView(
        noteID: UUID,
        selection: CaptureNoteViewSelection,
        at timestamp: Date = Date()
    ) throws {
        let context = ModelContext(modelContainer)
        let viewState = try ensuredNoteViewStateModel(
            noteID: noteID,
            at: timestamp,
            in: context
        )
        viewState.select(selection, at: timestamp)
        try save(context)
    }

    /// Remembers a view that needs no template, which is every view except an
    /// enhanced panel of one named template.
    public func selectView(
        noteID: UUID,
        kind: CaptureNoteViewKind,
        at timestamp: Date = Date()
    ) throws {
        try selectView(
            noteID: noteID,
            selection: CaptureNoteViewSelection(kind: kind),
            at: timestamp
        )
    }

    // MARK: - Transcript deletion

    /// Hides this note's transcript from every read of it.
    ///
    /// The recording, its revisions, the typed notes, and the panels generated
    /// from the transcript are all left alone: a person deleting a transcript is
    /// saying they do not want to read it again, not that the note is wrong.
    /// Repeating the call reports the first deletion time.
    @discardableResult
    public func deleteTranscript(noteID: UUID, at timestamp: Date = Date()) throws -> Date {
        let context = ModelContext(modelContainer)
        let viewState = try ensuredNoteViewStateModel(
            noteID: noteID,
            at: timestamp,
            in: context
        )
        viewState.markTranscriptDeleted(at: timestamp)
        try save(context)
        return viewState.transcriptDeletedAt ?? timestamp
    }

    // MARK: - Transcript assembly

    /// The transcript to read for one capture.
    ///
    /// Committed final transcript wins. While a capture is still running there
    /// is none yet, so the committed live-transcript chain stands in for it; the
    /// snapshot says so with `isLive`, because that text has no timings and no
    /// speaker separation.
    private func transcriptView(
        handle: NoteCaptureHandle,
        session: CaptureSession,
        transcriptionRecordID: UUID?,
        in context: ModelContext
    ) throws -> TranscriptViewSnapshot? {
        let revisions = try readableFinalTranscriptRevisions(
            sessionID: handle.sessionID,
            in: context
        )
        if !revisions.isEmpty {
            let payload = try recordedDiarizationPayload(
                transcriptionRecordID: transcriptionRecordID,
                in: context
            )
            if let snapshot = try finalTranscriptView(
                revisions,
                handle: handle,
                micOnlyRanges: payload?.micOnlyRanges ?? [],
                liveLabelsDiffered: payload?.liveLabelsDiffered ?? false,
                in: context
            ) {
                return snapshot
            }
        }
        return try liveTranscriptView(handle: handle, session: session, in: context)
    }

    /// What the live path recorded beside the segments at finalization: the
    /// mic-only ranges and whether the finished names differed from the live
    /// ones.
    ///
    /// Nil for every capture finalized before these keys existed and for every
    /// capture that recorded none, and nil reads exactly like the old
    /// behaviour.
    private func recordedDiarizationPayload(
        transcriptionRecordID: UUID?,
        in context: ModelContext
    ) throws -> DiarizationPayload? {
        guard let transcriptionRecordID else { return nil }
        do {
            return try transcriptionRecord(id: transcriptionRecordID, in: context)?
                .diarizationPayload
        } catch {
            throw CaptureSessionStoreError.fetchFailed(error.localizedDescription)
        }
    }

    private func transcriptionRecord(
        id: UUID,
        in context: ModelContext
    ) throws -> TranscriptionRecord? {
        var descriptor = FetchDescriptor<TranscriptionRecord>(
            predicate: #Predicate<TranscriptionRecord> { $0.id == id }
        )
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }

    /// Forgets that the finished speaker names differed from the live ones.
    ///
    /// The flag lives inside `diarizationSegmentsJSON`, so dismissing the line
    /// survives quit and relaunch. Nothing else in the payload is touched: the
    /// mic-only ranges are still what makes the recorder "You". A record that is
    /// not there is not an error; the note simply has nothing to clear.
    public func dismissLiveLabelReconciliation(transcriptionRecordID: UUID) throws {
        let context = ModelContext(modelContainer)
        let record: TranscriptionRecord?
        do {
            record = try transcriptionRecord(id: transcriptionRecordID, in: context)
        } catch {
            throw CaptureSessionStoreError.fetchFailed(error.localizedDescription)
        }
        guard let record else { return }
        do {
            try record.clearLiveLabelsDiffered()
        } catch {
            throw CaptureSessionStoreError.saveFailed(error.localizedDescription)
        }
        try save(context)
    }

    /// The final-transcript revisions that describe the capture once, ordered by
    /// sequence.
    ///
    /// A chunked capture writes one session-scoped revision per sealed chunk.
    /// A whole-capture voice note instead writes a source-scoped raw revision and
    /// a corrected child of it, so only the leaf of that chain is read: the raw
    /// parent is the same speech said twice.
    private func readableFinalTranscriptRevisions(
        sessionID: UUID,
        in context: ModelContext
    ) throws -> [CaptureTranscriptRevisionModel] {
        let finalStageRawValue = CapturePipelineStage.finalTranscription.rawValue
        let completed = try fetchTranscriptRevisions(sessionID: sessionID, in: context)
            .filter { $0.stageRawValue == finalStageRawValue && $0.statusRawValue == "completed" }
        let chunked = completed.filter { $0.sourceID == nil }
        let readable: [CaptureTranscriptRevisionModel]
        if chunked.isEmpty {
            let supersededIDs = Set(completed.compactMap(\.parentRevisionID))
            readable = completed.filter { !supersededIDs.contains($0.id) }
        } else {
            readable = chunked
        }
        return readable.sorted {
            if $0.sequence != $1.sequence {
                return $0.sequence < $1.sequence
            }
            return $0.id.uuidString < $1.id.uuidString
        }
    }

    private func finalTranscriptView(
        _ revisions: [CaptureTranscriptRevisionModel],
        handle: NoteCaptureHandle,
        micOnlyRanges: [MicOnlyRange],
        liveLabelsDiffered: Bool,
        in context: ModelContext
    ) throws -> TranscriptViewSnapshot? {
        var spans: [TranscriptSpan] = []
        for revision in revisions {
            guard let checkpoint = completedFinalTranscriptCheckpoint(from: revision) else {
                continue
            }
            // The evidence a panel was generated from and the transcript a
            // person reads resolve their spans the same way, so a citation
            // always names a span that is on screen.
            guard let segments = MeetingNoteDerivation.usableDiarizedSegments(for: checkpoint) else {
                guard !checkpoint.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    continue
                }
                spans.append(
                    TranscriptSpan(
                        revisionID: checkpoint.revisionID,
                        segment: nil,
                        text: checkpoint.text,
                        startOffset: checkpoint.startOffset,
                        duration: checkpoint.duration
                    )
                )
                continue
            }
            for segment in segments {
                spans.append(
                    TranscriptSpan(
                        revisionID: checkpoint.revisionID,
                        segment: segment,
                        text: segment.text,
                        startOffset: checkpoint.startOffset + segment.startTime,
                        duration: segment.endTime - segment.startTime
                    )
                )
            }
        }

        guard !spans.isEmpty else {
            return nil
        }

        let segments = try attributedSegments(
            spans,
            capturesSystemAudio: handle.capturesSystemAudio,
            micOnlyRanges: micOnlyRanges,
            in: context
        )
        let attributedKeys = Set(
            segments
                .filter { $0.speakerLabel != nil }
                .compactMap(\.speakerKey)
        )
        return TranscriptViewSnapshot(
            segments: segments,
            duration: segments.map(\.endOffset).max() ?? 0,
            speakerCount: attributedKeys.count,
            isLive: false,
            liveLabelsDiffered: liveLabelsDiffered
        )
    }

    /// The committed live transcript, used while a capture has produced no final
    /// transcript yet.
    ///
    /// A corrupt live chain reads as no transcript rather than failing the note:
    /// the person can still open their notes and their panels.
    private func liveTranscriptView(
        handle: NoteCaptureHandle,
        session: CaptureSession,
        in context: ModelContext
    ) throws -> TranscriptViewSnapshot? {
        let checkpoint = try? latestValidLiveTranscriptCheckpoint(
            sessionID: handle.sessionID,
            sourceID: handle.microphoneSourceID,
            in: context
        )
        guard
            let checkpoint,
            !checkpoint.committedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            return nil
        }

        // Live transcription runs on the microphone only, so the one speaker is
        // the person recording.
        let segment = TranscriptSegmentSnapshot(
            id: "\(checkpoint.revisionID.uuidString)-0",
            revisionID: checkpoint.revisionID,
            speakerKey: Self.currentUserSpeakerKey,
            speakerLabel: TranscriptSegmentSnapshot.currentUserSpeakerLabel,
            isCurrentUser: true,
            text: checkpoint.committedText,
            startOffset: 0,
            duration: 0
        )
        return TranscriptViewSnapshot(
            segments: [segment],
            duration: 0,
            speakerCount: 1,
            isLive: session.state == .capturing || session.state == .interrupted
        )
    }

    // MARK: - Speaker attribution

    /// One span of transcript before its speaker is named.
    private struct TranscriptSpan {
        let revisionID: UUID
        let segment: DiarizedTranscriptSegment?
        let text: String
        let startOffset: TimeInterval
        let duration: TimeInterval
    }

    /// The key used for the one speaker of a microphone-only capture.
    private static let currentUserSpeakerKey = "self"

    /// The offline clusters that are the person recording.
    ///
    /// A cluster qualifies when a majority of its speech landed inside the
    /// mic-only ranges: the microphone gate open while the system gate was
    /// shut. No profile match is asked for, because there is nothing better to
    /// match against. Nobody but the person recording is on that channel alone.
    ///
    /// A majority rather than any overlap, because the microphone also hears
    /// the room and the far end leaks into it, so a passing overlap is evidence
    /// of leakage while a majority is evidence of ownership.
    private static func recorderSpeakerKeys(
        _ spans: [TranscriptSpan],
        micOnlyRanges: [MicOnlyRange]
    ) -> Set<String> {
        guard !micOnlyRanges.isEmpty else { return [] }
        var speechByKey: [String: TimeInterval] = [:]
        var micOnlyByKey: [String: TimeInterval] = [:]
        for span in spans {
            guard let key = span.segment?.canonicalSpeakerKey, span.duration > 0 else {
                continue
            }
            let end = span.startOffset + span.duration
            speechByKey[key, default: 0] += span.duration
            micOnlyByKey[key, default: 0] += MicOnlyRange.overlap(
                of: micOnlyRanges,
                withStart: span.startOffset,
                end: end
            )
        }
        return Set(
            speechByKey.compactMap { key, speech in
                let share = (micOnlyByKey[key] ?? 0) / speech
                return share > MicOnlyRange.recorderMajority ? key : nil
            }
        )
    }

    /// Names the speaker of every span.
    ///
    /// A participant profile wins whenever diarization matched one, so a person
    /// reads the names they gave. Everything else gets the deterministic generic
    /// number the rest of the app uses, because the diarizer's own label is only
    /// a cluster index and changes between runs. A microphone-only capture with
    /// one speaker is the person recording, and is named as such.
    ///
    /// A meeting names the person recording too, from `micOnlyRanges`. The
    /// offline pass has strictly less information than the microphone channel
    /// had during the capture, and "the offline pass replaces every label" must
    /// not mean "the offline pass discards what was already known for certain".
    private func attributedSegments(
        _ spans: [TranscriptSpan],
        capturesSystemAudio: Bool,
        micOnlyRanges: [MicOnlyRange],
        in context: ModelContext
    ) throws -> [TranscriptSegmentSnapshot] {
        var numbersByKey: [String: Int] = [:]
        for span in spans {
            guard let key = span.segment?.canonicalSpeakerKey, numbersByKey[key] == nil else {
                continue
            }
            numbersByKey[key] = numbersByKey.count + 1
        }
        let profileNames = try participantProfileNames(
            for: Set(spans.compactMap { $0.segment?.speakerProfileID }),
            in: context
        )
        // One microphone and one speaker: nobody else was recorded, so the
        // generic number would only hide who is talking.
        let isSoloMicrophoneCapture = !capturesSystemAudio && numbersByKey.count <= 1
        let recorderKeys = Self.recorderSpeakerKeys(spans, micOnlyRanges: micOnlyRanges)

        var segments: [TranscriptSegmentSnapshot] = []
        segments.reserveCapacity(spans.count)
        var indexByRevision: [UUID: Int] = [:]
        for span in spans {
            let index = indexByRevision[span.revisionID, default: 0]
            indexByRevision[span.revisionID] = index + 1

            let profileID = span.segment?.speakerProfileID
            let profile = profileID.flatMap { profileNames[$0] }
            let key = span.segment?.canonicalSpeakerKey
            var speakerKey = key
            var speakerLabel: String?
            var speakerNumber: Int?
            var isCurrentUser = false

            if let profile {
                speakerLabel = profile.isCurrentUser
                    ? TranscriptSegmentSnapshot.currentUserSpeakerLabel
                    : profile.displayName
                isCurrentUser = profile.isCurrentUser
            } else if isSoloMicrophoneCapture {
                speakerKey = Self.currentUserSpeakerKey
                speakerLabel = TranscriptSegmentSnapshot.currentUserSpeakerLabel
                isCurrentUser = true
            } else if let key, recorderKeys.contains(key) {
                // The cluster keeps its own key here, unlike a solo capture: a
                // speaker color and a later profile assignment must still name
                // the cluster the diarizer found.
                speakerLabel = TranscriptSegmentSnapshot.currentUserSpeakerLabel
                isCurrentUser = true
            } else if let key, let number = numbersByKey[key] {
                speakerLabel = "Speaker \(number)"
                speakerNumber = number
            }

            segments.append(
                TranscriptSegmentSnapshot(
                    id: "\(span.revisionID.uuidString)-\(index)",
                    revisionID: span.revisionID,
                    speakerKey: speakerKey,
                    speakerLabel: speakerLabel,
                    speakerNumber: speakerNumber,
                    speakerProfileID: profileID,
                    isCurrentUser: isCurrentUser,
                    text: span.text,
                    startOffset: span.startOffset,
                    duration: span.duration
                )
            )
        }
        return segments
    }

    private struct ParticipantName {
        let displayName: String
        let isCurrentUser: Bool
    }

    private func participantProfileNames(
        for profileIDs: Set<UUID>,
        in context: ModelContext
    ) throws -> [UUID: ParticipantName] {
        guard !profileIDs.isEmpty else {
            return [:]
        }
        let profiles: [ParticipantProfile]
        do {
            profiles = try context.fetch(FetchDescriptor<ParticipantProfile>())
        } catch {
            throw CaptureSessionStoreError.fetchFailed(error.localizedDescription)
        }
        var names: [UUID: ParticipantName] = [:]
        for profile in profiles where profileIDs.contains(profile.id) {
            names[profile.id] = ParticipantName(
                displayName: profile.displayName,
                isCurrentUser: profile.isCurrentUser
            )
        }
        return names
    }

    // MARK: - Helpers

    private func typedNotesSnapshot(_ note: Note) -> TypedNotesSnapshot {
        TypedNotesSnapshot(
            id: note.id,
            title: note.title,
            content: note.content,
            createdAt: note.createdAt,
            updatedAt: note.updatedAt
        )
    }

    /// The capture reference that says this note is the one a capture wrote into.
    private func humanAnchorReference(
        noteID: UUID,
        in context: ModelContext
    ) throws -> CaptureNoteReferenceModel? {
        let descriptor = FetchDescriptor<CaptureNoteReferenceModel>(
            predicate: #Predicate<CaptureNoteReferenceModel> { $0.noteID == noteID }
        )
        do {
            return try context.fetch(descriptor)
                .first { (try? $0.resolvedRole()) == .humanAnchor }
        } catch {
            throw CaptureSessionStoreError.fetchFailed(error.localizedDescription)
        }
    }

    private func noteCaptureHandle(
        sessionID: UUID,
        in context: ModelContext
    ) throws -> NoteCaptureHandle {
        let sources = try fetchSources(sessionID: sessionID, in: context)
            .sorted { $0.sequence < $1.sequence }
        guard
            let microphone = sources.first(where: {
                $0.kindRawValue == CaptureSourceKind.microphone.rawValue
            })
        else {
            throw CaptureSessionStoreError.noteCaptureHasNoMicrophoneSource(sessionID)
        }
        let systemAudio = sources.first {
            $0.kindRawValue == CaptureSourceKind.systemAudio.rawValue
        }
        return NoteCaptureHandle(
            sessionID: sessionID,
            microphoneSourceID: microphone.id,
            systemAudioSourceID: systemAudio?.id
        )
    }

    private func noteViewStateModel(
        noteID: UUID,
        in context: ModelContext
    ) throws -> NoteViewStateModel? {
        var descriptor = FetchDescriptor<NoteViewStateModel>(
            predicate: #Predicate<NoteViewStateModel> { $0.noteID == noteID }
        )
        descriptor.fetchLimit = 1
        do {
            return try context.fetch(descriptor).first
        } catch {
            throw CaptureSessionStoreError.fetchFailed(error.localizedDescription)
        }
    }

    private func ensuredNoteViewStateModel(
        noteID: UUID,
        at timestamp: Date,
        in context: ModelContext
    ) throws -> NoteViewStateModel {
        if let existing = try noteViewStateModel(noteID: noteID, in: context) {
            return existing
        }
        let created = NoteViewStateModel(noteID: noteID, updatedAt: timestamp)
        context.insert(created)
        return created
    }
}
