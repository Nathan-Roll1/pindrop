//
//  CaptureSessionStore.swift
//  PindropData
//
//  Created on 2026-08-20.
//

import Foundation
import PindropCore
import SwiftData

/// The durable artifact retained for one meeting audio source.
public struct RetainedMeetingSource: Sendable, Equatable {
    public let sourceID: UUID
    public let sampleRate: Double
    public let channelCount: Int
    public let duration: TimeInterval
    public let managedMediaPath: String
    public let byteCount: Int
    public let sha256: String

    public init(
        sourceID: UUID,
        sampleRate: Double,
        channelCount: Int,
        duration: TimeInterval,
        managedMediaPath: String,
        byteCount: Int,
        sha256: String
    ) {
        self.sourceID = sourceID
        self.sampleRate = sampleRate
        self.channelCount = channelCount
        self.duration = duration
        self.managedMediaPath = managedMediaPath
        self.byteCount = byteCount
        self.sha256 = sha256
    }
}

/// The terminal stop failure for one meeting audio source.
public struct FailedMeetingSource: Sendable, Equatable {
    public let sourceID: UUID
    public let errorDomain: String
    public let errorCode: String?
    public let message: String
    public let occurredAt: Date

    public init(
        sourceID: UUID,
        errorDomain: String,
        errorCode: String? = nil,
        message: String,
        occurredAt: Date
    ) {
        self.sourceID = sourceID
        self.errorDomain = errorDomain
        self.errorCode = errorCode
        self.message = message
        self.occurredAt = occurredAt
    }
}

public enum CaptureSourceState: String, Codable, Sendable {
    case capturing
    case completed
    case failed
    case cancelled
}

public enum CaptureChunkState: String, Codable, Sendable {
    case sealed
}

/// Stable identifiers for the immutable raw and final transcript revisions of one capture.
public struct VoiceNoteTranscriptRevisions: Sendable, Equatable {
    public let rawRevisionID: UUID
    public let finalRevisionID: UUID

    public init(rawRevisionID: UUID, finalRevisionID: UUID) {
        self.rawRevisionID = rawRevisionID
        self.finalRevisionID = finalRevisionID
    }
}
/// An immutable, committed live-transcript revision for a voice-note capture.
public struct VoiceNoteLiveTranscriptCheckpoint: Sendable, Equatable {
    public let revisionID: UUID
    public let sequence: Int
    public let parentRevisionID: UUID?
    public let committedText: String
    public let providerSnapshotID: UUID
    public let createdAt: Date

    public init(
        revisionID: UUID,
        sequence: Int,
        parentRevisionID: UUID?,
        committedText: String,
        providerSnapshotID: UUID,
        createdAt: Date
    ) {
        self.revisionID = revisionID
        self.sequence = sequence
        self.parentRevisionID = parentRevisionID
        self.committedText = committedText
        self.providerSnapshotID = providerSnapshotID
        self.createdAt = createdAt
    }
}

/// A persisted view of one immutable, sealed raw-audio chunk for a meeting source.
public struct MeetingChunkCheckpoint: Sendable, Equatable {
    public let chunkID: UUID
    public let sourceID: UUID
    public let sequence: Int
    public let startOffset: TimeInterval
    public let duration: TimeInterval
    public let managedMediaPath: String
    public let byteCount: Int
    public let sha256: String
    public let sealedAt: Date

    public init(
        chunkID: UUID = UUID(),
        sourceID: UUID,
        sequence: Int,
        startOffset: TimeInterval,
        duration: TimeInterval,
        managedMediaPath: String,
        byteCount: Int,
        sha256: String,
        sealedAt: Date
    ) {
        self.chunkID = chunkID
        self.sourceID = sourceID
        self.sequence = sequence
        self.startOffset = startOffset
        self.duration = duration
        self.managedMediaPath = managedMediaPath
        self.byteCount = byteCount
        self.sha256 = sha256
        self.sealedAt = sealedAt
    }
}

/// A successful final-ASR output that can be merged without retranscribing its source chunk.
/// A successful final-ASR output that can be merged without retranscribing its source chunk.
public struct MeetingTranscriptionCheckpoint: Sendable, Equatable {
    public let revisionID: UUID
    public let providerSnapshotID: UUID?
    public let sequence: Int
    public let startOffset: TimeInterval
    public let duration: TimeInterval
    public let text: String
    public let segmentsJSON: String?
    public let languageCode: String?

    public init(
        revisionID: UUID,
        providerSnapshotID: UUID?,
        sequence: Int,
        startOffset: TimeInterval,
        duration: TimeInterval,
        text: String,
        segmentsJSON: String?,
        languageCode: String?
    ) {
        self.revisionID = revisionID
        self.providerSnapshotID = providerSnapshotID
        self.sequence = sequence
        self.startOffset = startOffset
        self.duration = duration
        self.text = text
        self.segmentsJSON = segmentsJSON
        self.languageCode = languageCode
    }
}

/// A durable, user-editable note that anchors a meeting before generated output exists.
public struct MeetingHumanAnchorSnapshot: Sendable, Equatable {
    public let sessionID: UUID
    public let noteID: UUID
    public let title: String
    public let content: String

    public init(sessionID: UUID, noteID: UUID, title: String, content: String) {
        self.sessionID = sessionID
        self.noteID = noteID
        self.title = title
        self.content = content
    }
}

/// The reservation and durable inputs required before generating a meeting note.
public struct MeetingGeneratedNotePreflightSnapshot: Sendable, Equatable {
    public let sessionID: UUID
    public let humanAnchor: MeetingHumanAnchorSnapshot
    public let sourceTranscriptionID: UUID
    public let providerSnapshotID: UUID
    public let assignmentAttempt: Int

    public init(
        sessionID: UUID,
        humanAnchor: MeetingHumanAnchorSnapshot,
        sourceTranscriptionID: UUID,
        providerSnapshotID: UUID,
        assignmentAttempt: Int
    ) {
        self.sessionID = sessionID
        self.humanAnchor = humanAnchor
        self.sourceTranscriptionID = sourceTranscriptionID
        self.providerSnapshotID = providerSnapshotID
        self.assignmentAttempt = assignmentAttempt
    }
}

/// The immutable store identity and provenance for a generated meeting note.
public struct MeetingGeneratedNoteSnapshot: Sendable, Equatable {
    public let sessionID: UUID
    public let noteID: UUID
    public let humanAnchorNoteID: UUID
    public let humanAnchorContent: String
    public let sourceTranscriptionID: UUID
    public let providerSnapshotID: UUID
    public let citations: [MeetingNoteCitation]

    public init(
        sessionID: UUID,
        noteID: UUID,
        humanAnchorNoteID: UUID,
        humanAnchorContent: String,
        sourceTranscriptionID: UUID,
        providerSnapshotID: UUID,
        citations: [MeetingNoteCitation]
    ) {
        self.sessionID = sessionID
        self.noteID = noteID
        self.humanAnchorNoteID = humanAnchorNoteID
        self.humanAnchorContent = humanAnchorContent
        self.sourceTranscriptionID = sourceTranscriptionID
        self.providerSnapshotID = providerSnapshotID
        self.citations = citations
    }
}

/// A recoverable or terminal failure observed while producing one meeting chunk.
public struct MeetingChunkFailure: Sendable, Equatable {
    public let sourceID: UUID
    public let sequence: Int?
    public let chunkID: UUID?
    public let stage: CapturePipelineStage?
    /// Whether verified recovery established that this entire source is unavailable.
    public let invalidatesSource: Bool
    public let errorDomain: String
    public let errorCode: String?
    public let message: String
    public let isRetryable: Bool
    public let occurredAt: Date

    public init(
        sourceID: UUID,
        sequence: Int? = nil,
        chunkID: UUID? = nil,
        stage: CapturePipelineStage? = nil,
        invalidatesSource: Bool = false,
        errorDomain: String,
        errorCode: String? = nil,
        message: String,
        isRetryable: Bool,
        occurredAt: Date
    ) {
        self.sourceID = sourceID
        self.sequence = sequence
        self.chunkID = chunkID
        self.stage = stage
        self.invalidatesSource = invalidatesSource
        self.errorDomain = errorDomain
        self.errorCode = errorCode
        self.message = message
        self.isRetryable = isRetryable
        self.occurredAt = occurredAt
    }
}

/// An immutable note-capture recovery candidate suitable for crossing concurrency domains.
///
/// One snapshot covers every note-capture mode. `latestLiveCheckpoint` carries the
/// salvageable committed text of a streaming capture; `sourceChunks` carries the
/// durable spool inventory. Either can be empty: a capture can crash before it
/// produces either kind of artifact.
public struct NoteCaptureRecoverySnapshot: Sendable, Equatable {
    public let handle: NoteCaptureHandle
    public let mode: CaptureSessionMode
    public let state: CaptureSessionState
    public let recoveryTarget: CaptureRecoveryTarget?
    /// What the capture was started for. `nil` for a session started before
    /// intent was recorded, and for a stored intent this build cannot read.
    public let intent: CaptureIntent?
    public let startedAt: Date?
    public let lastActivityAt: Date?
    public let latestLiveCheckpoint: VoiceNoteLiveTranscriptCheckpoint?
    public let sourceChunks: [MeetingChunkCheckpoint]
    public let failedSequences: Set<Int>
    public let completedASRCheckpoints: [MeetingTranscriptionCheckpoint]
    public var completedASRSequences: Set<Int> {
        Set(completedASRCheckpoints.map(\.sequence))
    }
    public let completedDiarizationSequences: Set<Int>
    public let reservedTranscriptionRecordID: UUID?

    public init(
        handle: NoteCaptureHandle,
        mode: CaptureSessionMode,
        state: CaptureSessionState,
        recoveryTarget: CaptureRecoveryTarget?,
        intent: CaptureIntent? = nil,
        startedAt: Date? = nil,
        lastActivityAt: Date? = nil,
        latestLiveCheckpoint: VoiceNoteLiveTranscriptCheckpoint? = nil,
        sourceChunks: [MeetingChunkCheckpoint],
        failedSequences: Set<Int> = [],
        completedASRCheckpoints: [MeetingTranscriptionCheckpoint],
        completedDiarizationSequences: Set<Int>,
        reservedTranscriptionRecordID: UUID?
    ) {
        self.handle = handle
        self.mode = mode
        self.state = state
        self.recoveryTarget = recoveryTarget
        self.intent = intent
        self.startedAt = startedAt
        self.lastActivityAt = lastActivityAt
        self.latestLiveCheckpoint = latestLiveCheckpoint
        self.sourceChunks = sourceChunks
        self.failedSequences = failedSequences
        self.completedASRCheckpoints = completedASRCheckpoints
        self.completedDiarizationSequences = completedDiarizationSequences
        self.reservedTranscriptionRecordID = reservedTranscriptionRecordID
    }
}

/// A deterministic, resumable meeting-finalization work plan.
public struct MeetingFinalizationPlan: Sendable, Equatable {
    public let handle: NoteCaptureHandle
    public let sourceChunks: [MeetingChunkCheckpoint]
    public let failedSequences: Set<Int>
    public let completedASRCheckpoints: [MeetingTranscriptionCheckpoint]
    public var completedASRSequences: Set<Int> {
        Set(completedASRCheckpoints.map(\.sequence))
    }
    public let completedDiarizationSequences: Set<Int>
    public let reservedTranscriptionRecordID: UUID?

    public init(
        handle: NoteCaptureHandle,
        sourceChunks: [MeetingChunkCheckpoint],
        failedSequences: Set<Int> = [],
        completedASRCheckpoints: [MeetingTranscriptionCheckpoint],
        completedDiarizationSequences: Set<Int>,
        reservedTranscriptionRecordID: UUID?
    ) {
        self.handle = handle
        self.sourceChunks = sourceChunks
        self.failedSequences = failedSequences
        self.completedASRCheckpoints = completedASRCheckpoints
        self.completedDiarizationSequences = completedDiarizationSequences
        self.reservedTranscriptionRecordID = reservedTranscriptionRecordID
    }
}

public enum CaptureSessionStoreError: Error, Equatable, LocalizedError {
    case sessionNotFound(UUID)
    case sourceNotFound(UUID)
    case sourceSessionMismatch(sourceID: UUID, expectedSessionID: UUID, actualSessionID: UUID)
    case sourceIsNotMicrophone(UUID)
    case sourceKindMismatch(sourceID: UUID, expected: CaptureSourceKind, actualRawValue: String)
    case sessionModeMismatch(sessionID: UUID, expected: CaptureSessionMode, actualRawValue: String)
    case meetingSessionNotFinalizing(sessionID: UUID, actualStateRawValue: String)
    case meetingSourceOutcomeDuplicate(UUID)
    case meetingSourceOutcomeForeign(UUID)
    case meetingSourceOutcomeMissing(UUID)
    case meetingSourceAlreadyStopped(UUID)
    case invalidRetainedMeetingSource(UUID)
    case meetingSourceNotTerminal(UUID)
    case meetingSourceOutcomeMismatch(UUID)
    case meetingCaptureHasNoCompletedSource(UUID)
    case invalidMeetingChunk(sourceID: UUID, sequence: Int)
    case meetingChunkConflict(sourceID: UUID, sequence: Int)
    case meetingChunkSequenceGap(sourceID: UUID, expected: Int, actual: Int)
    case meetingTranscriptionRevisionConflict(sequence: Int, stage: CapturePipelineStage)
    case meetingCaptureHasIncompleteFinalTranscript(sessionID: UUID, sequences: [Int])
    case meetingCaptureHasNoFinalTranscript(UUID)
    case transcriptionRecordReservationMismatch(expected: UUID, actual: UUID)
    case transcriptionRecordNotFound(UUID)
    case transcriptRevisionNotFound(UUID)
    case transcriptRevisionSessionMismatch(revisionID: UUID, expectedSessionID: UUID, actualSessionID: UUID)
    case transcriptRevisionSourceMismatch(revisionID: UUID, expectedSourceID: UUID, actualSourceID: UUID?)
    case invalidFinalTranscriptRevision(UUID)
    case emptyLiveTranscript(UUID)
    case voiceNoteSessionNotCapturing(sessionID: UUID, actualStateRawValue: String)
    case voiceNoteSessionNotFinalizing(sessionID: UUID, actualStateRawValue: String)
    case liveTranscriptAssignmentNotFound(sessionID: UUID, attempt: Int)
    case liveTranscriptAssignmentUnavailable(sessionID: UUID, attempt: Int)
    case duplicateLiveTranscriptAssignments(sessionID: UUID, attempt: Int)
    case liveTranscriptRegression(sessionID: UUID)
    case liveTranscriptConflict(sessionID: UUID, sequence: Int)
    case voiceNoteFinalTranscriptConflict(sessionID: UUID)
    case invalidCaptureIntent(CaptureIntentError)
    case captureIntentNotFound(UUID)
    case captureIntentDestinationConflict(sessionID: UUID, requestedNoteID: UUID)
    case invalidAssignmentAttempt(Int)
    case assignmentSessionNotFound(UUID)
    case assignmentKeyMismatch
    case duplicateAssignments(sessionID: UUID, stage: CapturePipelineStage, attempt: Int)
    case meetingHumanAnchorUnavailable(UUID)
    case meetingHumanAnchorConflict(UUID)
    case meetingGeneratedNoteConflict(UUID)
    case meetingGeneratedNoteSourceChanged(UUID)
    case invalidMeetingGeneratedNote(UUID)
    case meetingNoteEncodingFailed
    case invalidEnhancedPanel(sessionID: UUID)
    case enhancedPanelNotFound(UUID)
    case noteCaptureHasNoMicrophoneSource(UUID)
    case noteNotFound(UUID)
    case fetchFailed(String)
    case saveFailed(String)

    public var errorDescription: String? {
        switch self {
        case .sessionNotFound(let id):
            return "Capture session \(id.uuidString) was not found."
        case .sourceNotFound(let id):
            return "Capture source \(id.uuidString) was not found."
        case .sourceSessionMismatch(let sourceID, let expectedSessionID, let actualSessionID):
            return "Capture source \(sourceID.uuidString) belongs to \(actualSessionID.uuidString), not \(expectedSessionID.uuidString)."
        case .sourceIsNotMicrophone(let id):
            return "Capture source \(id.uuidString) is not a microphone source."
        case .sourceKindMismatch(let sourceID, let expected, let actualRawValue):
            return "Capture source \(sourceID.uuidString) has kind \(actualRawValue), not \(expected.rawValue)."
        case .sessionModeMismatch(let sessionID, let expected, let actualRawValue):
            return "Capture session \(sessionID.uuidString) has mode \(actualRawValue), not \(expected.rawValue)."
        case .meetingSessionNotFinalizing(let sessionID, let actualStateRawValue):
            return "Meeting capture session \(sessionID.uuidString) is \(actualStateRawValue), not finalizing."
        case .meetingSourceOutcomeDuplicate(let sourceID):
            return "Meeting capture source \(sourceID.uuidString) has more than one stop outcome."
        case .meetingSourceOutcomeForeign(let sourceID):
            return "Meeting capture source \(sourceID.uuidString) does not belong to this meeting."
        case .meetingSourceOutcomeMissing(let sourceID):
            return "Meeting capture source \(sourceID.uuidString) has no stop outcome."
        case .meetingSourceAlreadyStopped(let sourceID):
            return "Meeting capture source \(sourceID.uuidString) already has a terminal stop outcome."
        case .invalidRetainedMeetingSource(let sourceID):
            return "Meeting capture source \(sourceID.uuidString) has an invalid retained artifact."
        case .meetingSourceNotTerminal(let sourceID):
            return "Meeting capture source \(sourceID.uuidString) has not reached a terminal state."
        case .meetingSourceOutcomeMismatch(let sourceID):
            return "Meeting capture source \(sourceID.uuidString) has persisted outcomes that do not match its terminal state."
        case .meetingCaptureHasNoCompletedSource(let sessionID):
            return "Meeting capture session \(sessionID.uuidString) has no completed source."
        case .invalidMeetingChunk(let sourceID, let sequence):
            return "Meeting chunk \(sequence) for source \(sourceID.uuidString) is invalid."
        case .meetingChunkConflict(let sourceID, let sequence):
            return "Meeting chunk \(sequence) for source \(sourceID.uuidString) conflicts with its persisted checkpoint."
        case .meetingChunkSequenceGap(let sourceID, let expected, let actual):
            return "Meeting source \(sourceID.uuidString) expected chunk \(expected), not \(actual)."
        case .meetingTranscriptionRevisionConflict(let sequence, let stage):
            return "Meeting \(stage.rawValue) revision for chunk \(sequence) conflicts with its persisted checkpoint."
        case .meetingCaptureHasIncompleteFinalTranscript(let sessionID, let sequences):
            return "Meeting capture session \(sessionID.uuidString) is missing completed final transcripts for chunks \(sequences.map(String.init).joined(separator: ", "))."
        case .meetingCaptureHasNoFinalTranscript(let sessionID):
            return "Meeting capture session \(sessionID.uuidString) has no completed final transcript."
        case .transcriptionRecordReservationMismatch(let expected, let actual):
            return "Meeting capture reserved history record \(expected.uuidString), not \(actual.uuidString)."
        case .transcriptionRecordNotFound(let id):
            return "Transcription record \(id.uuidString) was not found."
        case .transcriptRevisionNotFound(let id):
            return "Transcript revision \(id.uuidString) was not found."
        case .transcriptRevisionSessionMismatch(let revisionID, let expectedSessionID, let actualSessionID):
            return "Transcript revision \(revisionID.uuidString) belongs to \(actualSessionID.uuidString), not \(expectedSessionID.uuidString)."
        case .transcriptRevisionSourceMismatch(let revisionID, let expectedSourceID, let actualSourceID):
            let actualSourceDescription = actualSourceID?.uuidString ?? "no source"
            return "Transcript revision \(revisionID.uuidString) belongs to \(actualSourceDescription), not \(expectedSourceID.uuidString)."
        case .invalidFinalTranscriptRevision(let revisionID):
            return "Transcript revision \(revisionID.uuidString) is not a completed final child of this capture."
        case .emptyLiveTranscript(let sessionID):
            return "Live transcript for capture session \(sessionID.uuidString) is empty."
        case .voiceNoteSessionNotCapturing(let sessionID, let actualStateRawValue):
            return "Voice-note capture session \(sessionID.uuidString) is \(actualStateRawValue), not capturing."
        case .voiceNoteSessionNotFinalizing(let sessionID, let actualStateRawValue):
            return "Voice-note capture session \(sessionID.uuidString) is \(actualStateRawValue), not finalizing."
        case .liveTranscriptAssignmentNotFound(let sessionID, let attempt):
            return "Voice-note capture session \(sessionID.uuidString) has no live-transcription assignment for attempt \(attempt)."
        case .liveTranscriptAssignmentUnavailable(let sessionID, let attempt):
            return "Voice-note capture session \(sessionID.uuidString) has an unavailable live-transcription assignment for attempt \(attempt)."
        case .duplicateLiveTranscriptAssignments(let sessionID, let attempt):
            return "Voice-note capture session \(sessionID.uuidString) has duplicate live-transcription assignments for attempt \(attempt)."
        case .liveTranscriptRegression(let sessionID):
            return "Live transcript for capture session \(sessionID.uuidString) does not extend the committed prefix."
        case .liveTranscriptConflict(let sessionID, let sequence):
            return "Live transcript revision \(sequence) for capture session \(sessionID.uuidString) is corrupt or conflicts with its persisted chain."
        case .voiceNoteFinalTranscriptConflict(let sessionID):
            return "Final transcript revisions for voice-note capture session \(sessionID.uuidString) conflict with the committed lineage."
        case .invalidCaptureIntent(let error):
            return error.errorDescription ?? "The capture intent is not valid."
        case .captureIntentNotFound(let sessionID):
            return "Capture session \(sessionID.uuidString) has no recorded intent."
        case .captureIntentDestinationConflict(let sessionID, let requestedNoteID):
            return "Capture session \(sessionID.uuidString) is already bound to a different destination than note \(requestedNoteID.uuidString)."
        case .invalidAssignmentAttempt(let attempt):
            return "Capture assignment attempt \(attempt) must be at least one."
        case .assignmentSessionNotFound(let id):
            return "Capture session \(id.uuidString) was not found for assignment persistence."
        case .assignmentKeyMismatch:
            return "Capture assignment does not match its requested stage and attempt."
        case .duplicateAssignments(let sessionID, let stage, let attempt):
            return "Capture session \(sessionID.uuidString) has duplicate \(stage.rawValue) assignments for attempt \(attempt)."
        case .meetingHumanAnchorUnavailable(let sessionID):
            return "Meeting capture session \(sessionID.uuidString) has no valid human anchor."
        case .meetingHumanAnchorConflict(let sessionID):
            return "Meeting capture session \(sessionID.uuidString) has conflicting human-anchor references."
        case .meetingGeneratedNoteConflict(let sessionID):
            return "Meeting capture session \(sessionID.uuidString) has conflicting generated-note references."
        case .meetingGeneratedNoteSourceChanged(let sessionID):
            return "Meeting capture session \(sessionID.uuidString) has changed generated-note source evidence."
        case .invalidMeetingGeneratedNote(let sessionID):
            return "Meeting capture session \(sessionID.uuidString) has invalid generated-note provenance."
        case .meetingNoteEncodingFailed:
            return "Meeting note provenance could not be encoded."
        case .invalidEnhancedPanel(let sessionID):
            return "Capture session \(sessionID.uuidString) cannot store an enhanced panel with no template or no content."
        case .enhancedPanelNotFound(let id):
            return "Enhanced panel \(id.uuidString) was not found."
        case .noteCaptureHasNoMicrophoneSource(let sessionID):
            return "Capture session \(sessionID.uuidString) has no microphone source."
        case .noteNotFound(let id):
            return "Note \(id.uuidString) was not found."
        case .fetchFailed(let message):
            return "Failed to fetch capture data: \(message)"
        case .saveFailed(let message):
            return "Failed to save capture data: \(message)"
        }
    }
}

/// Persists the capture-domain artifacts for voice-note and meeting lifecycles.
///
/// The store uses only stable IDs between SwiftData models. It deliberately does
/// not own history-record or note creation; callers commit those through their
/// dedicated stores before linking their IDs here.
@MainActor
public final class CaptureSessionStore {
    let modelContainer: ModelContainer
    /// The session and its owned source rows, microphone first.
    ///
    /// `sources` holds one row for a mic-only note capture and two when system
    /// audio was captured. A mic-only capture never creates a system-audio row,
    /// so finalization is never asked to explain a chunkless source.
    private struct OwnedNoteCapture {
        let session: CaptureSessionModel
        let sources: [CaptureSourceModel]

        var microphoneSource: CaptureSourceModel { sources[0] }
        var systemAudioSource: CaptureSourceModel? { sources.count > 1 ? sources[1] : nil }
    }
    private struct MeetingChunkIdentity: Hashable {
        let sourceID: UUID
        let sequence: Int
    }


    public init(modelContext: ModelContext) {
        modelContainer = modelContext.container
    }

    public func persistedAssignment(
        sessionID: UUID,
        stage: CapturePipelineStage,
        attempt: Int
    ) throws -> CaptureStageAssignment? {
        guard attempt >= 1 else {
            throw CaptureSessionStoreError.invalidAssignmentAttempt(attempt)
        }

        let context = ModelContext(modelContainer)
        _ = try fetchAssignmentSession(id: sessionID, in: context)
        return try persistedAssignment(
            sessionID: sessionID,
            stage: stage,
            attempt: attempt,
            in: context
        )
    }

    @discardableResult
    public func resolveAssignment(
        sessionID: UUID,
        stage: CapturePipelineStage,
        attempt: Int,
        selecting: () throws -> CaptureStageAssignment
    ) throws -> CaptureStageAssignment {
        guard attempt >= 1 else {
            throw CaptureSessionStoreError.invalidAssignmentAttempt(attempt)
        }

        let context = ModelContext(modelContainer)
        _ = try fetchAssignmentSession(id: sessionID, in: context)
        if let assignment = try persistedAssignment(
            sessionID: sessionID,
            stage: stage,
            attempt: attempt,
            in: context
        ) {
            return assignment
        }

        let assignment = try selecting()
        guard assignment.stage == stage, assignment.attempt == attempt else {
            throw CaptureSessionStoreError.assignmentKeyMismatch
        }

        let providerSnapshot = CaptureStageProviderSnapshotModel(
            sessionID: sessionID,
            assignment: assignment
        )
        context.insert(providerSnapshot)
        if let prompt = assignment.prompt {
            context.insert(
                CaptureStagePromptSnapshotModel(
                    sessionID: sessionID,
                    providerSnapshotID: providerSnapshot.id,
                    prompt: prompt
                )
            )
        }
        try save(context)

        return assignment
    }

    /// Records an idempotent pipeline-stage failure without attributing session work to a source or chunk.
    public func recordStageFailure(
        sessionID: UUID,
        stage: CapturePipelineStage,
        attempt: Int,
        domain: String,
        code: String? = nil,
        message: String,
        retryable: Bool,
        at timestamp: Date = Date()
    ) throws {
        guard attempt >= 1 else {
            throw CaptureSessionStoreError.invalidAssignmentAttempt(attempt)
        }

        let context = ModelContext(modelContainer)
        let session = try fetchAssignmentSession(id: sessionID, in: context)
        let failures = try fetchMeetingFailures(sessionID: sessionID, in: context)
        let duplicate = failures.contains {
            $0.sourceID == nil &&
                $0.chunkID == nil &&
                $0.transcriptRevisionID == nil &&
                $0.providerSnapshotID == nil &&
                $0.stageRawValue == stage.rawValue &&
                $0.attempt == attempt &&
                $0.errorDomain == domain &&
                $0.errorCode == code &&
                $0.message == message &&
                $0.isRetryable == retryable &&
                $0.detailsJSON == nil &&
                $0.occurredAt == timestamp
        }
        guard !duplicate else {
            return
        }

        context.insert(
            CaptureFailureRecordModel(
                sessionID: sessionID,
                stage: stage,
                attempt: attempt,
                errorDomain: domain,
                errorCode: code,
                message: message,
                isRetryable: retryable,
                occurredAt: timestamp,
                recoveryDisposition: retryable ? .recoverable : .terminal
            )
        )
        session.lastActivityAt = timestamp
        try save(context)
    }

    /// Starts a legacy `voiceNote` capture.
    ///
    /// Deprecated for production use: every capture now starts through
    /// `startNoteCapture`. This creator survives so the suites that read legacy
    /// `voiceNote` rows can still write one, and it must keep producing exactly
    /// the shape those stores hold today.
    @discardableResult
    public func startVoiceNoteCapture(
        startedAt: Date = Date(),
        microphoneDisplayName: String? = nil
    ) throws -> NoteCaptureHandle {
        var session = try CaptureSession(mode: .voiceNote, createdAt: startedAt)
        try session.start(at: startedAt)

        let context = ModelContext(modelContainer)
        let sessionModel = CaptureSessionModel(session: session, lastActivityAt: startedAt)
        let microphoneSource = CaptureSourceModel(
            sessionID: session.id,
            kind: .microphone,
            sequence: 0,
            stateRawValue: CaptureSourceState.capturing.rawValue,
            displayName: microphoneDisplayName,
            startedAt: startedAt,
            createdAt: startedAt,
            updatedAt: startedAt
        )
        context.insert(sessionModel)
        context.insert(microphoneSource)
        try save(context)

        return NoteCaptureHandle(
            sessionID: session.id,
            microphoneSourceID: microphoneSource.id
        )
    }
    /// Starts a legacy `meeting` capture.
    ///
    /// Deprecated for production use: every capture now starts through
    /// `startNoteCapture`. This creator survives so the suites that read legacy
    /// `meeting` rows (and the UI-test fixture in `AppTestMode`) can still write
    /// one.
    @discardableResult
    public func startMeetingCapture(
        startedAt: Date = Date(),
        microphoneDisplayName: String? = nil,
        systemAudioDisplayName: String? = nil
    ) throws -> NoteCaptureHandle {
        try startCapture(
            mode: .meeting,
            startedAt: startedAt,
            includeSystemAudio: true,
            intent: nil,
            microphoneDisplayName: microphoneDisplayName,
            systemAudioDisplayName: systemAudioDisplayName
        )
    }

    /// Starts one note capture with the source set the request asked for, and
    /// records what the capture is for in the same transaction.
    ///
    /// A mic-only capture creates no system-audio source row. Creating one and
    /// failing it later would make finalization reject a source that never
    /// recorded anything, and would leave that session unrecoverable.
    ///
    /// The intent is written with the session, never after it: a started
    /// session that survives a crash always says where its output belongs.
    @discardableResult
    public func startNoteCapture(
        startedAt: Date = Date(),
        includeSystemAudio: Bool,
        intent: CaptureIntentRequest,
        microphoneDisplayName: String? = nil,
        systemAudioDisplayName: String? = nil
    ) throws -> NoteCaptureHandle {
        try startCapture(
            mode: .note,
            startedAt: startedAt,
            includeSystemAudio: includeSystemAudio,
            intent: intent,
            microphoneDisplayName: microphoneDisplayName,
            systemAudioDisplayName: systemAudioDisplayName
        )
    }

    private func startCapture(
        mode: CaptureSessionMode,
        startedAt: Date,
        includeSystemAudio: Bool,
        intent intentRequest: CaptureIntentRequest?,
        microphoneDisplayName: String?,
        systemAudioDisplayName: String?
    ) throws -> NoteCaptureHandle {
        var session = try CaptureSession(mode: mode, createdAt: startedAt)
        try session.start(at: startedAt)

        // The recorded source kinds are the source rows this call creates, so
        // the intent can never claim a source the session does not own.
        let requestedSourceKinds = CaptureIntent.requestedSourceKinds(
            includeSystemAudio: includeSystemAudio
        )
        let intent: CaptureIntent? = try intentRequest.map { request in
            do {
                return try request.intent(
                    sessionID: session.id,
                    requestedSourceKinds: requestedSourceKinds,
                    createdAt: startedAt
                )
            } catch let error as CaptureIntentError {
                throw CaptureSessionStoreError.invalidCaptureIntent(error)
            }
        }

        let context = ModelContext(modelContainer)
        let sessionModel = CaptureSessionModel(session: session, lastActivityAt: startedAt)
        let microphoneSource = CaptureSourceModel(
            sessionID: session.id,
            kind: .microphone,
            sequence: 0,
            stateRawValue: CaptureSourceState.capturing.rawValue,
            displayName: microphoneDisplayName,
            startedAt: startedAt,
            createdAt: startedAt,
            updatedAt: startedAt
        )
        context.insert(sessionModel)
        context.insert(microphoneSource)

        var systemAudioSourceID: UUID?
        if includeSystemAudio {
            let systemAudioSource = CaptureSourceModel(
                sessionID: session.id,
                kind: .systemAudio,
                sequence: 1,
                stateRawValue: CaptureSourceState.capturing.rawValue,
                displayName: systemAudioDisplayName,
                startedAt: startedAt,
                createdAt: startedAt,
                updatedAt: startedAt
            )
            context.insert(systemAudioSource)
            systemAudioSourceID = systemAudioSource.id
        }
        if let intent {
            context.insert(try CaptureIntentModel(intent: intent))
        }
        try save(context)

        return NoteCaptureHandle(
            sessionID: session.id,
            microphoneSourceID: microphoneSource.id,
            systemAudioSourceID: systemAudioSourceID
        )
    }

    /// The recorded intent for one capture session.
    ///
    /// Returns `nil` for a session started before intent was recorded. A stored
    /// intent this build cannot read throws instead: an unreadable intent is a
    /// different problem from an absent one.
    public func fetchCaptureIntent(sessionID: UUID) throws -> CaptureIntent? {
        let context = ModelContext(modelContainer)
        return try fetchCaptureIntentModel(sessionID: sessionID, in: context)?.restoreIntent()
    }

    /// Points a `newNote` intent at the note the capture created.
    ///
    /// A capture that makes its own note only learns the note identifier once
    /// the note is committed. Calling this again with the same note is a no-op;
    /// a different note, or a `transcriptOnly` intent, is a conflict rather than
    /// a silent rewrite of what the capture was for.
    public func updateIntentDestination(sessionID: UUID, noteID: UUID) throws {
        let context = ModelContext(modelContainer)
        guard let model = try fetchCaptureIntentModel(sessionID: sessionID, in: context) else {
            throw CaptureSessionStoreError.captureIntentNotFound(sessionID)
        }
        let intent = try model.restoreIntent()
        switch intent.destination {
        case .newNote:
            break
        case .existingNote:
            guard intent.destinationNoteID == noteID else {
                throw CaptureSessionStoreError.captureIntentDestinationConflict(
                    sessionID: sessionID,
                    requestedNoteID: noteID
                )
            }
            return
        case .transcriptOnly:
            throw CaptureSessionStoreError.captureIntentDestinationConflict(
                sessionID: sessionID,
                requestedNoteID: noteID
            )
        }

        model.bindDestinationNote(noteID)
        try save(context)
    }

    public func beginMeetingFinalization(
        _ handle: NoteCaptureHandle,
        at timestamp: Date = Date()
    ) throws {
        let context = ModelContext(modelContainer)
        let ownedCapture = try fetchOwnedNoteCapture(for: handle, in: context)
        var session = try ownedCapture.session.restoreSession()
        try session.beginFinalization(at: timestamp)
        try ownedCapture.session.update(from: session)
        ownedCapture.session.lastActivityAt = timestamp
        try save(context)
    }
    public func recordSealedMeetingChunk(
        _ handle: NoteCaptureHandle,
        chunk: SealedAudioSourceChunk,
        at timestamp: Date = Date()
    ) throws {
        guard
            chunk.sessionID == handle.sessionID,
            let byteCount = Int(exactly: chunk.byteCount)
        else {
            throw CaptureSessionStoreError.invalidMeetingChunk(
                sourceID: chunk.sourceID,
                sequence: chunk.sequence
            )
        }
        try recordSealedMeetingChunk(
            handle,
            checkpoint: MeetingChunkCheckpoint(
                sourceID: chunk.sourceID,
                sequence: chunk.sequence,
                startOffset: chunk.startOffset,
                duration: chunk.duration,
                managedMediaPath: chunk.relativePath,
                byteCount: byteCount,
                sha256: chunk.sha256,
                sealedAt: timestamp
            )
        )
    }

    /// Persists an idempotent sealed-chunk checkpoint without taking ownership of media files.
    public func recordSealedMeetingChunk(
        _ handle: NoteCaptureHandle,
        checkpoint: MeetingChunkCheckpoint
    ) throws {
        let context = ModelContext(modelContainer)
        let ownedCapture = try fetchOwnedNoteCapture(for: handle, in: context)
        try checkpointMeetingChunk(
            checkpoint,
            handle: handle,
            sources: ownedCapture.sources,
            in: context
        )
        ownedCapture.session.lastActivityAt = checkpoint.sealedAt
        try save(context)
    }

    /// Records a chunk-scoped failure once, retaining it for recovery diagnostics.
    public func recordMeetingChunkFailure(
        _ handle: NoteCaptureHandle,
        failure: MeetingChunkFailure
    ) throws {
        let context = ModelContext(modelContainer)
        let ownedCapture = try fetchOwnedNoteCapture(for: handle, in: context)
        try checkpointMeetingChunkFailure(
            failure,
            handle: handle,
            sources: ownedCapture.sources,
            in: context
        )
        ownedCapture.session.lastActivityAt = failure.occurredAt
        try save(context)
    }

    /// Marks each meeting source terminal after its recorder has stopped.
    public func finishMeetingSources(
        _ handle: NoteCaptureHandle,
        sourceFailures: [FailedMeetingSource],
        at timestamp: Date = Date()
    ) throws {
        let context = ModelContext(modelContainer)
        let ownedCapture = try fetchOwnedNoteCapture(for: handle, in: context)
        guard ownedCapture.session.stateRawValue == CaptureSessionState.finalizing.rawValue else {
            throw CaptureSessionStoreError.meetingSessionNotFinalizing(
                sessionID: handle.sessionID,
                actualStateRawValue: ownedCapture.session.stateRawValue
            )
        }
        let sources = ownedCapture.sources
        try validateMeetingOutcomes(retained: [], failures: sourceFailures, for: sources, allowMissingRetained: true)
        let chunks = try fetchMeetingChunks(sessionID: handle.sessionID, in: context)
        let persistedFailures = try fetchMeetingFailures(sessionID: handle.sessionID, in: context)
        let failuresBySourceID = Dictionary(uniqueKeysWithValues: sourceFailures.map { ($0.sourceID, $0) })
        var invalidatedSequences = Set<Int>()

        for source in sources {
            let sourceChunks = chunks.filter { $0.sourceID == source.id }
            let sourceFailures = persistedFailures.filter { $0.sourceID == source.id }
            if let failure = failuresBySourceID[source.id] {
                guard source.stateRawValue == CaptureSourceState.capturing.rawValue ||
                    source.stateRawValue == CaptureSourceState.failed.rawValue else {
                    throw CaptureSessionStoreError.meetingSourceOutcomeMismatch(source.id)
                }
                for staleChunk in sourceChunks {
                    invalidatedSequences.insert(staleChunk.sequence)
                    context.delete(staleChunk)
                }
                source.stateRawValue = CaptureSourceState.failed.rawValue
                source.endedAt = timestamp
                source.updatedAt = timestamp
                try checkpointMeetingChunkFailure(
                    MeetingChunkFailure(
                        sourceID: source.id,
                        errorDomain: failure.errorDomain,
                        errorCode: failure.errorCode,
                        message: failure.message,
                        isRetryable: false,
                        occurredAt: failure.occurredAt
                    ),
                    handle: handle,
                    sources: sources,
                    in: context
                )
                continue
            }
            if hasSourceWideFailure(sourceFailures) {
                guard source.stateRawValue == CaptureSourceState.capturing.rawValue ||
                    source.stateRawValue == CaptureSourceState.failed.rawValue else {
                    throw CaptureSessionStoreError.meetingSourceOutcomeMismatch(source.id)
                }
                for staleChunk in sourceChunks {
                    invalidatedSequences.insert(staleChunk.sequence)
                    context.delete(staleChunk)
                }
                source.stateRawValue = CaptureSourceState.failed.rawValue
                source.endedAt = timestamp
                source.updatedAt = timestamp
                continue
            }
            guard !sourceChunks.isEmpty else {
                throw CaptureSessionStoreError.meetingSourceOutcomeMissing(source.id)
            }
            try validateMeetingChunks(
                sourceChunks,
                sourceID: source.id,
                sessionID: handle.sessionID,
                failedSequences: failedSequences(for: source.id, from: sourceFailures)
            )
            guard source.stateRawValue == CaptureSourceState.capturing.rawValue ||
                source.stateRawValue == CaptureSourceState.completed.rawValue else {
                throw CaptureSessionStoreError.meetingSourceOutcomeMismatch(source.id)
            }
            source.stateRawValue = CaptureSourceState.completed.rawValue
            source.sampleRate = Double(MeetingCaptureSpoolPlan.sampleRate)
            source.channelCount = MeetingCaptureSpoolPlan.channelCount
            source.codecRawValue = "pcm"
            source.endedAt = timestamp
            source.updatedAt = timestamp
        }
        if !invalidatedSequences.isEmpty {
            let revisions = try fetchTranscriptRevisions(sessionID: handle.sessionID, in: context)
            for revision in revisions where invalidatedSequences.contains(revision.sequence) {
                context.delete(revision)
            }
        }
        ownedCapture.session.lastActivityAt = timestamp
        try save(context)
    }

    /// Returns every nonterminal note capture, in every note-capture mode.
    ///
    /// A candidate needs exactly one microphone source and at most one
    /// system-audio source: any other source set cannot produce an honest handle,
    /// so that session is skipped. Candidates are newest-activity first.
    public func noteCaptureRecoveryCandidates() throws -> [NoteCaptureRecoverySnapshot] {
        let context = ModelContext(modelContainer)
        let dictateModeRawValue = CaptureSessionMode.dictate.rawValue
        let descriptor = FetchDescriptor<CaptureSessionModel>(
            predicate: #Predicate<CaptureSessionModel> {
                $0.modeRawValue != dictateModeRawValue
            }
        )
        do {
            let intentsBySessionID = try fetchCaptureIntentsBySessionID(in: context)
            var candidates: [NoteCaptureRecoverySnapshot] = []
            for sessionModel in try context.fetch(descriptor) {
                guard
                    let mode = CaptureSessionMode(rawValue: sessionModel.modeRawValue),
                    mode.isNoteCapture,
                    let session = try? sessionModel.restoreSession(),
                    [.capturing, .finalizing, .interrupted].contains(session.state)
                else {
                    continue
                }
                let sources = try fetchSources(sessionID: session.id, in: context)
                let microphones = sources.filter {
                    $0.kindRawValue == CaptureSourceKind.microphone.rawValue
                }
                let systemAudios = sources.filter {
                    $0.kindRawValue == CaptureSourceKind.systemAudio.rawValue
                }
                guard
                    microphones.count == 1,
                    let microphone = microphones.first,
                    systemAudios.count <= 1
                else {
                    continue
                }
                let handle = NoteCaptureHandle(
                    sessionID: session.id,
                    microphoneSourceID: microphone.id,
                    systemAudioSourceID: systemAudios.first?.id
                )
                let chunks = try fetchMeetingChunks(sessionID: session.id, in: context)
                let revisions = try fetchTranscriptRevisions(sessionID: session.id, in: context)
                let failures = try fetchMeetingFailures(sessionID: session.id, in: context)
                candidates.append(
                    makeNoteCaptureRecoverySnapshot(
                        handle: handle,
                        mode: mode,
                        session: session,
                        // A pre-intent session has none, and an intent this
                        // build cannot read must not drop the whole listing.
                        intent: try? intentsBySessionID[session.id]?.restoreIntent(),
                        lastActivityAt: sessionModel.lastActivityAt,
                        latestLiveCheckpoint: try? latestValidLiveTranscriptCheckpoint(
                            sessionID: session.id,
                            sourceID: microphone.id,
                            in: context
                        ),
                        chunks: chunks,
                        revisions: revisions,
                        failures: failures,
                        reservedTranscriptionRecordID: sessionModel.transcriptionRecordID
                    )
                )
            }
            return candidates.sorted {
                let lhsActivity = $0.lastActivityAt ?? .distantPast
                let rhsActivity = $1.lastActivityAt ?? .distantPast
                if lhsActivity != rhsActivity {
                    return lhsActivity > rhsActivity
                }
                return $0.handle.sessionID.uuidString < $1.handle.sessionID.uuidString
            }
        } catch let error as CaptureSessionStoreError {
            throw error
        } catch {
            throw CaptureSessionStoreError.fetchFailed(error.localizedDescription)
        }
    }

    /// The system-audio subset of `noteCaptureRecoveryCandidates()`.
    ///
    /// Startup recovery reads the unfiltered list: it delivers a microphone-only
    /// capture into the note the durable intent names. This narrower read is
    /// kept for callers that mean the meeting case specifically.
    public func meetingRecoveryCandidates() throws -> [NoteCaptureRecoverySnapshot] {
        try noteCaptureRecoveryCandidates().filter { $0.handle.capturesSystemAudio }
    }

    /// The streaming subset of `noteCaptureRecoveryCandidates()`.
    ///
    /// Legacy shim: a mic-only capture that has committed live text.
    public func voiceNoteRecoveryCandidates() throws -> [NoteCaptureRecoverySnapshot] {
        try noteCaptureRecoveryCandidates().filter {
            !$0.handle.capturesSystemAudio && $0.latestLiveCheckpoint != nil
        }
    }

    /// Returns terminal user-cancelled note-capture IDs whose managed artifacts
    /// can be safely retried for deletion during startup cleanup.
    public func cancelledNoteCaptureSessionIDs() throws -> [UUID] {
        let context = ModelContext(modelContainer)
        let meetingModeRawValue = CaptureSessionMode.meeting.rawValue
        let noteModeRawValue = CaptureSessionMode.note.rawValue
        let cancelledStateRawValue = CaptureSessionState.cancelled.rawValue
        let descriptor = FetchDescriptor<CaptureSessionModel>(
            predicate: #Predicate<CaptureSessionModel> {
                ($0.modeRawValue == meetingModeRawValue || $0.modeRawValue == noteModeRawValue)
                    && $0.stateRawValue == cancelledStateRawValue
            }
        )
        do {
            return try context.fetch(descriptor)
                .map(\.id)
                .sorted { $0.uuidString < $1.uuidString }
        } catch {
            throw CaptureSessionStoreError.fetchFailed(error.localizedDescription)
        }
    }

    /// Interrupts capturing or finalizing work without converting it into a terminal failure.
    public func interruptMeetingCapture(
        _ handle: NoteCaptureHandle,
        errorDomain: String,
        errorCode: String? = nil,
        message: String,
        at timestamp: Date = Date()
    ) throws {
        let context = ModelContext(modelContainer)
        let ownedCapture = try fetchOwnedNoteCapture(for: handle, in: context)
        var session = try ownedCapture.session.restoreSession()
        guard session.state != .interrupted else {
            return
        }
        let failure = CaptureFailure(
            sessionID: handle.sessionID,
            disposition: .recoverable,
            occurredAt: timestamp,
            code: errorCode ?? errorDomain,
            message: message
        )
        try session.interrupt(with: failure, at: timestamp)
        try ownedCapture.session.update(from: session)
        ownedCapture.session.lastActivityAt = timestamp
        context.insert(CaptureFailureRecordModel(
            id: failure.id,
            sessionID: handle.sessionID,
            errorDomain: errorDomain,
            errorCode: errorCode,
            message: message,
            isRetryable: true,
            occurredAt: timestamp,
            recoveryDisposition: .recoverable
        ))
        try save(context)
    }

    /// Resumes an interrupted meeting directly into finalization, preserving all checkpoints.
    public func recoverMeetingForFinalization(
        _ handle: NoteCaptureHandle,
        at timestamp: Date = Date()
    ) throws {
        let context = ModelContext(modelContainer)
        let ownedCapture = try fetchOwnedNoteCapture(for: handle, in: context)
        var session = try ownedCapture.session.restoreSession()
        if session.state == .finalizing {
            return
        }
        guard session.state == .interrupted else {
            throw CaptureSessionStoreError.meetingSessionNotFinalizing(
                sessionID: handle.sessionID,
                actualStateRawValue: session.state.rawValue
            )
        }
        let target = session.recoveryTarget
        try session.recover(at: timestamp)
        if target == .capturing {
            try session.beginFinalization(at: timestamp)
        }
        try ownedCapture.session.update(from: session)
        ownedCapture.session.lastActivityAt = timestamp
        if let latestFailureID = session.latestFailureID {
            try markFailureRecovered(id: latestFailureID, at: timestamp, in: context)
        }
        try save(context)
    }

    /// Reconciles inventory discovered after a crash, before any finalization work resumes.
    public func reconcileMeetingChunks(
        _ handle: NoteCaptureHandle,
        checkpoints: [MeetingChunkCheckpoint],
        failures: [MeetingChunkFailure],
        at timestamp: Date = Date()
    ) throws {
        let context = ModelContext(modelContainer)
        let ownedCapture = try fetchOwnedNoteCapture(for: handle, in: context)
        let sources = ownedCapture.sources
        let sortedCheckpoints = checkpoints.sorted {
            ($0.sourceID.uuidString, $0.sequence) < ($1.sourceID.uuidString, $1.sequence)
        }
        for checkpoint in sortedCheckpoints {
            try checkpointMeetingChunk(checkpoint, handle: handle, sources: sources, in: context)
        }
        for failure in failures {
            try checkpointMeetingChunkFailure(failure, handle: handle, sources: sources, in: context)
        }
        ownedCapture.session.lastActivityAt = timestamp
        try save(context)
    }
    /// Reconciles canonical media inventory after files were renamed but before a checkpoint commit.
    public func reconcileMeetingInventory(
        _ handle: NoteCaptureHandle,
        sealedChunks: [SealedAudioSourceChunk],
        failures: [MeetingChunkFailure] = [],
        at timestamp: Date = Date()
    ) throws {
        let context = ModelContext(modelContainer)
        let ownedCapture = try fetchOwnedNoteCapture(for: handle, in: context)
        let sources = ownedCapture.sources
        let sourceIDs = Set(sources.map(\.id))

        var inventory = [MeetingChunkIdentity: MeetingChunkCheckpoint]()
        for sealedChunk in sealedChunks {
            guard
                sealedChunk.sessionID == handle.sessionID,
                sourceIDs.contains(sealedChunk.sourceID),
                let byteCount = Int(exactly: sealedChunk.byteCount)
            else {
                throw CaptureSessionStoreError.invalidMeetingChunk(
                    sourceID: sealedChunk.sourceID,
                    sequence: sealedChunk.sequence
                )
            }
            let checkpoint = MeetingChunkCheckpoint(
                sourceID: sealedChunk.sourceID,
                sequence: sealedChunk.sequence,
                startOffset: sealedChunk.startOffset,
                duration: sealedChunk.duration,
                managedMediaPath: sealedChunk.relativePath,
                byteCount: byteCount,
                sha256: sealedChunk.sha256,
                sealedAt: timestamp
            )
            try validateMeetingChunk(checkpoint, sessionID: handle.sessionID)
            let identity = MeetingChunkIdentity(
                sourceID: checkpoint.sourceID,
                sequence: checkpoint.sequence
            )
            guard inventory[identity] == nil else {
                throw CaptureSessionStoreError.meetingChunkConflict(
                    sourceID: checkpoint.sourceID,
                    sequence: checkpoint.sequence
                )
            }
            inventory[identity] = checkpoint
        }

        for failure in failures {
            guard sourceIDs.contains(failure.sourceID), failure.sequence.map({ $0 >= 0 }) ?? true else {
                throw CaptureSessionStoreError.meetingSourceOutcomeForeign(failure.sourceID)
            }
        }

        let failedSources = Set(failures.compactMap { failure in
            failure.invalidatesSource ? failure.sourceID : nil
        })
        let failedChunks = Set(failures.compactMap { failure in
            failure.sequence.map { MeetingChunkIdentity(sourceID: failure.sourceID, sequence: $0) }
        })
        var changedSequences = Set<Int>()
        let persistedChunks = try fetchMeetingChunks(sessionID: handle.sessionID, in: context)
        var preservedIdentities = Set<MeetingChunkIdentity>()

        for persistedChunk in persistedChunks {
            let identity = MeetingChunkIdentity(
                sourceID: persistedChunk.sourceID,
                sequence: persistedChunk.sequence
            )
            guard
                !failedSources.contains(persistedChunk.sourceID),
                !failedChunks.contains(identity),
                !preservedIdentities.contains(identity),
                let verifiedChunk = inventory[identity],
                checkpointMatches(persistedChunk, verifiedChunk)
            else {
                changedSequences.insert(persistedChunk.sequence)
                context.delete(persistedChunk)
                continue
            }
            preservedIdentities.insert(identity)
        }

        for (identity, checkpoint) in inventory
            where !failedSources.contains(identity.sourceID) &&
                !failedChunks.contains(identity) &&
                !preservedIdentities.contains(identity) {
            changedSequences.insert(identity.sequence)
            context.insert(CaptureChunkModel(
                id: checkpoint.chunkID,
                sessionID: handle.sessionID,
                sourceID: checkpoint.sourceID,
                sequence: checkpoint.sequence,
                startOffset: checkpoint.startOffset,
                duration: checkpoint.duration,
                stateRawValue: CaptureChunkState.sealed.rawValue,
                managedMediaPath: checkpoint.managedMediaPath,
                byteCount: checkpoint.byteCount,
                sha256: checkpoint.sha256,
                createdAt: checkpoint.sealedAt,
                sealedAt: checkpoint.sealedAt
            ))
        }

        if !changedSequences.isEmpty {
            let revisions = try fetchTranscriptRevisions(sessionID: handle.sessionID, in: context)
            for revision in revisions where changedSequences.contains(revision.sequence) {
                context.delete(revision)
            }
        }
        for failure in failures {
            try checkpointMeetingChunkFailure(
                failure,
                handle: handle,
                sources: sources,
                associateWithPersistedChunk: false,
                in: context
            )
        }
        ownedCapture.session.lastActivityAt = timestamp
        try save(context)
    }


    /// Returns deterministic source chunks and revision skip-gates for finalization.
    public func makeMeetingFinalizationPlan(
        _ handle: NoteCaptureHandle
    ) throws -> MeetingFinalizationPlan {
        let context = ModelContext(modelContainer)
        let ownedCapture = try fetchOwnedNoteCapture(for: handle, in: context)
        let session = try ownedCapture.session.restoreSession()
        let chunks = try fetchMeetingChunks(sessionID: handle.sessionID, in: context)
        let revisions = try fetchTranscriptRevisions(sessionID: handle.sessionID, in: context)
        let failures = try fetchMeetingFailures(sessionID: handle.sessionID, in: context)
        let snapshot = makeNoteCaptureRecoverySnapshot(
            handle: handle,
            mode: session.mode,
            session: session,
            intent: try? fetchCaptureIntentModel(
                sessionID: handle.sessionID,
                in: context
            )?.restoreIntent(),
            lastActivityAt: ownedCapture.session.lastActivityAt,
            latestLiveCheckpoint: nil,
            chunks: chunks,
            revisions: revisions,
            failures: failures,
            reservedTranscriptionRecordID: ownedCapture.session.transcriptionRecordID
        )
        return MeetingFinalizationPlan(
            handle: snapshot.handle,
            sourceChunks: snapshot.sourceChunks,
            failedSequences: snapshot.failedSequences,
            completedASRCheckpoints: snapshot.completedASRCheckpoints,
            completedDiarizationSequences: snapshot.completedDiarizationSequences,
            reservedTranscriptionRecordID: snapshot.reservedTranscriptionRecordID
        )
    }

    /// Checkpoints one final-ASR revision; an exact retry returns its existing revision ID.
    @discardableResult
    public func recordMeetingTranscriptionChunk(
        _ handle: NoteCaptureHandle,
        sourceChunkSequence: Int,
        startOffset: TimeInterval,
        duration: TimeInterval,
        text: String,
        segmentsJSON: String? = nil,
        languageCode: String? = nil,
        assignmentAttempt: Int? = nil,
        at timestamp: Date = Date()
    ) throws -> UUID {
        try checkpointMeetingRevision(
            handle,
            sequence: sourceChunkSequence,
            stage: .finalTranscription,
            startOffset: startOffset,
            duration: duration,
            text: text,
            segmentsJSON: segmentsJSON,
            languageCode: languageCode,
            assignmentAttempt: assignmentAttempt,
            at: timestamp
        )
    }

    /// Checkpoints best-effort diarization separately so final ASR remains recoverable on its own.
    @discardableResult
    public func recordMeetingDiarizationChunk(
        _ handle: NoteCaptureHandle,
        sourceChunkSequence: Int,
        startOffset: TimeInterval,
        duration: TimeInterval,
        text: String,
        segmentsJSON: String?,
        languageCode: String?,
        assignmentAttempt: Int? = nil,
        at timestamp: Date = Date()
    ) throws -> UUID {
        try checkpointMeetingRevision(
            handle,
            sequence: sourceChunkSequence,
            stage: .diarization,
            startOffset: startOffset,
            duration: duration,
            text: text,

            segmentsJSON: segmentsJSON,
            languageCode: languageCode,
            assignmentAttempt: assignmentAttempt,
            at: timestamp
        )
    }
    /// Creates the single user-owned meeting anchor before any generated output exists.
    ///
    /// The note is deliberately returned as-is on retry: users may edit it while
    /// capture work is cancelled, interrupted, or later resumed.
    @discardableResult
    public func ensureMeetingHumanAnchor(
        _ handle: NoteCaptureHandle,
        title: String,
        at timestamp: Date = Date()
    ) throws -> MeetingHumanAnchorSnapshot {
        let context = ModelContext(modelContainer)
        let ownedCapture = try fetchOwnedNoteCapture(for: handle, in: context)
        guard isHumanAnchorAllowed(sessionStateRawValue: ownedCapture.session.stateRawValue) else {
            throw CaptureSessionStoreError.meetingHumanAnchorUnavailable(handle.sessionID)
        }
        if let existing = try validMeetingHumanAnchor(sessionID: handle.sessionID, in: context) {
            return existing
        }
        guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw CaptureSessionStoreError.meetingHumanAnchorUnavailable(handle.sessionID)
        }

        guard try meetingNoteReferences(sessionID: handle.sessionID, in: context).isEmpty else {
            throw CaptureSessionStoreError.meetingHumanAnchorConflict(handle.sessionID)
        }

        let note = Note(
            title: title,
            content: "",
            tags: [],
            sourceTranscriptionID: nil,
            createdAt: timestamp,
            updatedAt: timestamp
        )
        context.insert(note)
        context.insert(CaptureNoteReferenceModel(
            sessionID: handle.sessionID,
            noteID: note.id,
            role: .humanAnchor,
            createdAt: timestamp
        ))
        try save(context)
        return MeetingHumanAnchorSnapshot(
            sessionID: handle.sessionID,
            noteID: note.id,
            title: note.title,
            content: note.content
        )
    }

    /// Anchors one capture to a note that already exists.
    ///
    /// A note created before the capture starts (the "new note, then record"
    /// flow) is the anchor: it is never replaced by a note this call creates,
    /// and a second call with the same note is a no-op.
    @discardableResult
    public func ensureMeetingHumanAnchor(
        _ handle: NoteCaptureHandle,
        noteID: UUID,
        at timestamp: Date = Date()
    ) throws -> MeetingHumanAnchorSnapshot {
        let context = ModelContext(modelContainer)
        let ownedCapture = try fetchOwnedNoteCapture(for: handle, in: context)
        guard isHumanAnchorAllowed(sessionStateRawValue: ownedCapture.session.stateRawValue) else {
            throw CaptureSessionStoreError.meetingHumanAnchorUnavailable(handle.sessionID)
        }
        if let existing = try validMeetingHumanAnchor(sessionID: handle.sessionID, in: context) {
            guard existing.noteID == noteID else {
                throw CaptureSessionStoreError.meetingHumanAnchorConflict(handle.sessionID)
            }
            return existing
        }
        guard let note = try fetchNote(id: noteID, in: context) else {
            throw CaptureSessionStoreError.noteNotFound(noteID)
        }
        guard try meetingNoteReferences(sessionID: handle.sessionID, in: context).isEmpty else {
            throw CaptureSessionStoreError.meetingHumanAnchorConflict(handle.sessionID)
        }

        context.insert(CaptureNoteReferenceModel(
            sessionID: handle.sessionID,
            noteID: note.id,
            role: .humanAnchor,
            createdAt: timestamp
        ))
        try save(context)
        return MeetingHumanAnchorSnapshot(
            sessionID: handle.sessionID,
            noteID: note.id,
            title: note.title,
            content: note.content
        )
    }

    /// Returns the existing human anchor without creating or mutating durable state.
    public func meetingHumanAnchor(
        _ handle: NoteCaptureHandle
    ) throws -> MeetingHumanAnchorSnapshot? {
        let context = ModelContext(modelContainer)
        _ = try fetchOwnedNoteCapture(for: handle, in: context)
        return try validMeetingHumanAnchor(sessionID: handle.sessionID, in: context)
    }

    /// Removes the anchor note a capture created for itself when that capture
    /// produced nothing.
    ///
    /// A capture creates its note before audio starts so the person can type
    /// into it immediately. When the recording turns out to be silent, that note
    /// would otherwise stay behind as an empty row nobody asked for.
    ///
    /// Nothing a person could have written is ever removed: the note is
    /// discarded only while it is still untouched (no content, no tags, no
    /// pin, no linked transcription) and only while this capture owns the sole
    /// note reference. Returns `true` when the note was removed.
    @discardableResult
    public func discardEmptyCaptureAnchorNote(
        _ handle: NoteCaptureHandle
    ) throws -> Bool {
        let context = ModelContext(modelContainer)
        _ = try fetchOwnedNoteCapture(for: handle, in: context)
        let references = try meetingNoteReferences(sessionID: handle.sessionID, in: context)
        guard references.count == 1,
              let reference = references.first,
              (try? reference.resolvedRole()) == .humanAnchor else {
            return false
        }
        guard let note = try fetchNote(id: reference.noteID, in: context) else {
            return false
        }
        guard note.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              note.tags.isEmpty,
              !note.isPinned,
              note.sourceTranscriptionID == nil else {
            return false
        }
        context.delete(reference)
        context.delete(note)
        try save(context)
        return true
    }

    /// Removes a human-anchor reference whose note no longer exists.
    ///
    /// Recovery must never lose a transcript to a note that is gone. A
    /// reference pointing at a missing note is the only thing standing between
    /// the capture and a replacement anchor, and it points at nothing. A
    /// reference whose note is still there is left exactly as it is. Returns
    /// `true` when a reference was removed.
    @discardableResult
    public func discardMissingAnchorNoteReference(
        _ handle: NoteCaptureHandle
    ) throws -> Bool {
        let context = ModelContext(modelContainer)
        _ = try fetchOwnedNoteCapture(for: handle, in: context)
        let references = try meetingNoteReferences(sessionID: handle.sessionID, in: context)
        var didRemove = false
        for reference in references where (try? reference.resolvedRole()) == .humanAnchor {
            guard try fetchNote(id: reference.noteID, in: context) == nil else { continue }
            context.delete(reference)
            didRemove = true
        }
        guard didRemove else { return false }
        try save(context)
        return true
    }

    /// Validates the reservation and immutable provenance required for generated output.
    public func meetingGeneratedNotePreflight(
        _ handle: NoteCaptureHandle,
        assignmentAttempt: Int = 1
    ) throws -> MeetingGeneratedNotePreflightSnapshot {
        let context = ModelContext(modelContainer)
        return try meetingGeneratedNotePreflight(
            handle,
            assignmentAttempt: assignmentAttempt,
            in: context
        )
    }

    /// Returns persisted generated meeting output when its immutable provenance remains valid.
    public func generatedMeetingNote(
        _ handle: NoteCaptureHandle,
        assignmentAttempt: Int = 1
    ) throws -> MeetingGeneratedNoteSnapshot? {
        let context = ModelContext(modelContainer)
        _ = try fetchOwnedNoteCapture(for: handle, in: context)
        let references = try meetingNoteReferences(sessionID: handle.sessionID, in: context)
        let generatedReferences: [CaptureNoteReferenceModel]
        do {
            for reference in references {
                _ = try reference.resolvedRole()
            }
            generatedReferences = try references.filter {
                try $0.resolvedRole() == .generated
            }
        } catch {
            throw CaptureSessionStoreError.meetingGeneratedNoteConflict(handle.sessionID)
        }
        guard generatedReferences.count <= 1 else {
            throw CaptureSessionStoreError.meetingGeneratedNoteConflict(handle.sessionID)
        }
        guard let reference = generatedReferences.first else {
            return nil
        }
        guard references.count == 2 else {
            throw CaptureSessionStoreError.meetingGeneratedNoteConflict(handle.sessionID)
        }

        guard assignmentAttempt >= 1 else {
            throw CaptureSessionStoreError.invalidAssignmentAttempt(assignmentAttempt)
        }
        let preflight: MeetingGeneratedNotePreflightSnapshot
        do {
            preflight = try meetingGeneratedNotePreflight(
                handle,
                assignmentAttempt: assignmentAttempt,
                in: context
            )
        } catch {
            throw CaptureSessionStoreError.meetingGeneratedNoteConflict(handle.sessionID)
        }
        let note: Note
        let provenance: MeetingGeneratedNoteProvenance
        let humanAnchorContentSnapshot: String
        do {
            guard
                let fetchedNote = try fetchNote(id: reference.noteID, in: context),
                let provenanceJSON = reference.provenanceJSON,
                let provenanceData = provenanceJSON.data(using: .utf8),
                let snapshot = reference.humanAnchorContentSnapshot
            else {
                throw CaptureSessionStoreError.meetingGeneratedNoteConflict(handle.sessionID)
            }
            note = fetchedNote
            provenance = try JSONDecoder().decode(
                MeetingGeneratedNoteProvenance.self,
                from: provenanceData
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            guard provenanceJSON == String(decoding: try encoder.encode(provenance), as: UTF8.self) else {
                throw CaptureSessionStoreError.meetingGeneratedNoteConflict(handle.sessionID)
            }
            humanAnchorContentSnapshot = snapshot
        } catch {
            throw CaptureSessionStoreError.meetingGeneratedNoteConflict(handle.sessionID)
        }
        guard
            reference.sourceTranscriptRevisionID == nil,
            reference.providerSnapshotID == preflight.providerSnapshotID,
            preflight.humanAnchor.noteID == provenance.humanAnchorNoteID,
            note.sourceTranscriptionID == preflight.sourceTranscriptionID
        else {
            throw CaptureSessionStoreError.meetingGeneratedNoteConflict(handle.sessionID)
        }
        // The current anchor reference proves provenance still belongs to this meeting.
        // The write-once snapshot is the immutable input consumed by the generator.
        let expectedSource: MeetingNoteSourceBundle
        do {
            expectedSource = try derivedMeetingNoteSource(
                sessionID: handle.sessionID,
                humanNoteContent: humanAnchorContentSnapshot,
                in: context
            )
        } catch {
            throw CaptureSessionStoreError.meetingGeneratedNoteConflict(handle.sessionID)
        }
        let expectedProvenance = MeetingGeneratedNoteProvenance(
            humanAnchorNoteID: provenance.humanAnchorNoteID,
            evidenceInput: expectedSource.evidenceInput,
            citations: expectedSource.citations,
            sourceTranscriptRevisionIDs: expectedSource.sourceTranscriptRevisionIDs
        )
        guard provenance == expectedProvenance else {
            throw CaptureSessionStoreError.meetingGeneratedNoteConflict(handle.sessionID)
        }
        guard
            !note.title.isEmpty,
            note.title == MeetingNoteDerivation.sanitizingGeneratedContent(note.title),
            !note.content.isEmpty,
            note.content == MeetingNoteDerivation.sanitizingGeneratedContent(note.content)
        else {
            throw CaptureSessionStoreError.meetingGeneratedNoteConflict(handle.sessionID)
        }

        return MeetingGeneratedNoteSnapshot(
            sessionID: handle.sessionID,
            noteID: note.id,
            humanAnchorNoteID: provenance.humanAnchorNoteID,
            humanAnchorContent: humanAnchorContentSnapshot,
            sourceTranscriptionID: preflight.sourceTranscriptionID,
            providerSnapshotID: preflight.providerSnapshotID,
            citations: provenance.citations
        )
    }

    /// Returns a generated meeting note only when its durable provenance remains valid.
    ///
    /// The lookup context establishes the note's owning meeting handle. Validation then
    /// runs through `generatedMeetingNote(_:assignmentAttempt:)` in its own fresh context.
    public func generatedMeetingNote(
        noteID: UUID,
        assignmentAttempt: Int = 1
    ) throws -> MeetingGeneratedNoteSnapshot? {
        let context = ModelContext(modelContainer)
        let descriptor = FetchDescriptor<CaptureNoteReferenceModel>(
            predicate: #Predicate<CaptureNoteReferenceModel> { $0.noteID == noteID }
        )
        let references: [CaptureNoteReferenceModel]
        do {
            references = try context.fetch(descriptor)
        } catch {
            throw CaptureSessionStoreError.fetchFailed(error.localizedDescription)
        }
        guard !references.isEmpty else {
            return nil
        }

        let generatedReferences: [CaptureNoteReferenceModel]
        do {
            generatedReferences = try references.filter {
                try $0.resolvedRole() == .generated
            }
        } catch {
            throw CaptureSessionStoreError.meetingGeneratedNoteConflict(references[0].sessionID)
        }
        guard generatedReferences.count <= 1 else {
            throw CaptureSessionStoreError.meetingGeneratedNoteConflict(generatedReferences[0].sessionID)
        }
        guard let reference = generatedReferences.first else {
            return nil
        }
        guard assignmentAttempt >= 1 else {
            throw CaptureSessionStoreError.invalidAssignmentAttempt(assignmentAttempt)
        }

        let handle: NoteCaptureHandle
        do {
            let session = try fetchSession(id: reference.sessionID, in: context)
            guard
                let mode = CaptureSessionMode(rawValue: session.modeRawValue),
                mode.isNoteCapture
            else {
                throw CaptureSessionStoreError.meetingGeneratedNoteConflict(reference.sessionID)
            }
            let sources = try fetchSources(sessionID: reference.sessionID, in: context)
            let microphoneSources = sources.filter {
                $0.kindRawValue == CaptureSourceKind.microphone.rawValue
            }
            let systemAudioSources = sources.filter {
                $0.kindRawValue == CaptureSourceKind.systemAudio.rawValue
            }
            // A note capture owns one microphone source and at most one system-audio
            // source. Any other shape cannot name its own artifacts.
            guard
                sources.count == microphoneSources.count + systemAudioSources.count,
                microphoneSources.count == 1,
                systemAudioSources.count <= 1,
                let microphoneSource = microphoneSources.first
            else {
                throw CaptureSessionStoreError.meetingGeneratedNoteConflict(reference.sessionID)
            }
            handle = NoteCaptureHandle(
                sessionID: reference.sessionID,
                microphoneSourceID: microphoneSource.id,
                systemAudioSourceID: systemAudioSources.first?.id
            )
        } catch {
            throw CaptureSessionStoreError.meetingGeneratedNoteConflict(reference.sessionID)
        }

        do {
            guard let snapshot = try generatedMeetingNote(
                handle,
                assignmentAttempt: assignmentAttempt
            ), snapshot.noteID == noteID else {
                throw CaptureSessionStoreError.meetingGeneratedNoteConflict(reference.sessionID)
            }
            return snapshot
        } catch {
            throw CaptureSessionStoreError.meetingGeneratedNoteConflict(reference.sessionID)
        }
    }

    /// Saves generated meeting output and its provenance in one transaction.
    @discardableResult
    public func saveGeneratedMeetingNote(
        _ handle: NoteCaptureHandle,
        title: String,
        content: String,
        source: MeetingNoteSourceBundle,
        assignmentAttempt: Int = 1,
        at timestamp: Date = Date()
    ) throws -> MeetingGeneratedNoteSnapshot {
        guard
            !title.isEmpty,
            title == MeetingNoteDerivation.sanitizingGeneratedContent(title),
            !content.isEmpty,
            content == MeetingNoteDerivation.sanitizingGeneratedContent(content),
            !source.citations.isEmpty
        else {
            throw CaptureSessionStoreError.invalidMeetingGeneratedNote(handle.sessionID)
        }
        let context = ModelContext(modelContainer)
        let preflight = try meetingGeneratedNotePreflight(
            handle,
            assignmentAttempt: assignmentAttempt,
            in: context
        )
        let expectedSource: MeetingNoteSourceBundle
        do {
            expectedSource = try derivedMeetingNoteSource(
                sessionID: handle.sessionID,
                humanNoteContent: preflight.humanAnchor.content,
                in: context
            )
        } catch {
            throw CaptureSessionStoreError.invalidMeetingGeneratedNote(handle.sessionID)
        }
        guard source == expectedSource else {
            throw CaptureSessionStoreError.meetingGeneratedNoteSourceChanged(handle.sessionID)
        }
        let expectedProvenance = MeetingGeneratedNoteProvenance(
            humanAnchorNoteID: preflight.humanAnchor.noteID,
            evidenceInput: expectedSource.evidenceInput,
            citations: expectedSource.citations,
            sourceTranscriptRevisionIDs: expectedSource.sourceTranscriptRevisionIDs
        )
        let provenanceJSON: String
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            provenanceJSON = String(
                decoding: try encoder.encode(expectedProvenance),
                as: UTF8.self
            )
        } catch {
            throw CaptureSessionStoreError.meetingNoteEncodingFailed
        }

        let references = try meetingNoteReferences(sessionID: handle.sessionID, in: context)
        let generatedReferences = try references.filter {
            try $0.resolvedRole() == .generated
        }
        guard generatedReferences.count <= 1 else {
            throw CaptureSessionStoreError.meetingGeneratedNoteConflict(handle.sessionID)
        }
        if let existingReference = generatedReferences.first {
            let existingProvenance: MeetingGeneratedNoteProvenance
            do {
                guard
                    let existingProvenanceJSON = existingReference.provenanceJSON,
                    let existingProvenanceData = existingProvenanceJSON.data(using: .utf8)
                else {
                    throw CaptureSessionStoreError.meetingGeneratedNoteConflict(handle.sessionID)
                }
                existingProvenance = try JSONDecoder().decode(
                    MeetingGeneratedNoteProvenance.self,
                    from: existingProvenanceData
                )
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.sortedKeys]
                guard existingProvenanceJSON == String(
                    decoding: try encoder.encode(existingProvenance),
                    as: UTF8.self
                ) else {
                    throw CaptureSessionStoreError.meetingGeneratedNoteConflict(handle.sessionID)
                }
            } catch {
                throw CaptureSessionStoreError.meetingGeneratedNoteConflict(handle.sessionID)
            }
            guard
                references.count == 2,
                existingReference.sourceTranscriptRevisionID == nil,
                existingReference.providerSnapshotID == preflight.providerSnapshotID,
                let existingHumanAnchorContentSnapshot = existingReference.humanAnchorContentSnapshot,
                existingHumanAnchorContentSnapshot == preflight.humanAnchor.content,
                existingProvenance == expectedProvenance,
                let existingNote = try fetchNote(id: existingReference.noteID, in: context),
                existingNote.title == title,
                existingNote.content == content,
                existingNote.tags.isEmpty,
                existingNote.sourceTranscriptionID == preflight.sourceTranscriptionID
            else {
                throw CaptureSessionStoreError.meetingGeneratedNoteConflict(handle.sessionID)
            }
            return MeetingGeneratedNoteSnapshot(
                sessionID: handle.sessionID,
                noteID: existingNote.id,
                humanAnchorNoteID: existingProvenance.humanAnchorNoteID,
                humanAnchorContent: existingHumanAnchorContentSnapshot,
                sourceTranscriptionID: preflight.sourceTranscriptionID,
                providerSnapshotID: preflight.providerSnapshotID,
                citations: source.citations
            )
        }
        let ownedCapture = try fetchOwnedNoteCapture(for: handle, in: context)
        guard ownedCapture.session.stateRawValue == CaptureSessionState.finalizing.rawValue else {
            throw CaptureSessionStoreError.meetingSessionNotFinalizing(
                sessionID: handle.sessionID,
                actualStateRawValue: ownedCapture.session.stateRawValue
            )
        }

        guard references.count == 1 else {
            throw CaptureSessionStoreError.meetingGeneratedNoteConflict(handle.sessionID)
        }
        let note = Note(
            title: title,
            content: content,
            tags: [],
            sourceTranscriptionID: preflight.sourceTranscriptionID,
            createdAt: timestamp,
            updatedAt: timestamp
        )
        context.insert(note)
        context.insert(CaptureNoteReferenceModel(
            sessionID: handle.sessionID,
            noteID: note.id,
            role: .generated,
            sourceTranscriptRevisionID: nil,
            providerSnapshotID: preflight.providerSnapshotID,
            provenanceJSON: provenanceJSON,
            humanAnchorContentSnapshot: preflight.humanAnchor.content,
            createdAt: timestamp
        ))
        try save(context)
        return MeetingGeneratedNoteSnapshot(
            sessionID: handle.sessionID,
            noteID: note.id,
            humanAnchorNoteID: expectedProvenance.humanAnchorNoteID,
            humanAnchorContent: preflight.humanAnchor.content,
            sourceTranscriptionID: preflight.sourceTranscriptionID,
            providerSnapshotID: preflight.providerSnapshotID,
            citations: source.citations
        )
    }

    /// Reserves the stable HistoryStore ID before history persistence begins.
    @discardableResult
    public func reserveMeetingTranscriptionRecordID(
        _ handle: NoteCaptureHandle
    ) throws -> UUID {
        let context = ModelContext(modelContainer)
        let ownedCapture = try fetchOwnedNoteCapture(for: handle, in: context)
        if let reservedID = ownedCapture.session.transcriptionRecordID {
            return reservedID
        }
        let reservedID = UUID()
        ownedCapture.session.transcriptionRecordID = reservedID
        try save(context)
        return reservedID
    }
    /// Records a retryable HistoryStore failure without leaving finalization.
    public func recordMeetingHistoryFailure(
        _ handle: NoteCaptureHandle,
        errorDomain: String,
        errorCode: String? = nil,
        message: String,
        at timestamp: Date = Date()
    ) throws {
        let context = ModelContext(modelContainer)
        let ownedCapture = try fetchOwnedNoteCapture(for: handle, in: context)
        guard ownedCapture.session.stateRawValue == CaptureSessionState.finalizing.rawValue else {
            throw CaptureSessionStoreError.meetingSessionNotFinalizing(
                sessionID: handle.sessionID,
                actualStateRawValue: ownedCapture.session.stateRawValue
            )
        }
        let failures = try fetchMeetingFailures(sessionID: handle.sessionID, in: context)
        let duplicate = failures.contains {
            $0.sourceID == nil &&
                $0.stageRawValue == CapturePipelineStage.finalTranscription.rawValue &&
                $0.errorDomain == errorDomain &&
                $0.errorCode == errorCode &&
                $0.message == message &&
                $0.isRetryable &&
                $0.occurredAt == timestamp
        }
        if !duplicate {
            context.insert(CaptureFailureRecordModel(
                sessionID: handle.sessionID,
                stage: .finalTranscription,
                errorDomain: errorDomain,
                errorCode: errorCode,
                message: message,
                isRetryable: true,
                occurredAt: timestamp,
                recoveryDisposition: .recoverable
            ))
        }
        ownedCapture.session.lastActivityAt = timestamp
        try save(context)
    }

    /// Records a finalization failure without assigning session-level or mixed work to a source.
    public func recordMeetingFinalizationFailure(
        _ handle: NoteCaptureHandle,
        sequence: Int? = nil,
        stage: CapturePipelineStage,
        domain: String,
        code: String? = nil,
        message: String,
        retryable: Bool,
        at timestamp: Date = Date()
    ) throws {
        let context = ModelContext(modelContainer)
        let ownedCapture = try fetchOwnedNoteCapture(for: handle, in: context)
        guard ownedCapture.session.stateRawValue == CaptureSessionState.finalizing.rawValue else {
            throw CaptureSessionStoreError.meetingSessionNotFinalizing(
                sessionID: handle.sessionID,
                actualStateRawValue: ownedCapture.session.stateRawValue
            )
        }
        let detailsJSON = sequence.map { "{\"sequence\":\($0)}" }
        let failures = try fetchMeetingFailures(sessionID: handle.sessionID, in: context)
        let duplicate = failures.contains {
            $0.sourceID == nil &&
                $0.chunkID == nil &&
                $0.stageRawValue == stage.rawValue &&
                $0.errorDomain == domain &&
                $0.errorCode == code &&
                $0.message == message &&
                $0.isRetryable == retryable &&
                $0.detailsJSON == detailsJSON &&
                $0.occurredAt == timestamp
        }
        if !duplicate {
            context.insert(CaptureFailureRecordModel(
                sessionID: handle.sessionID,
                stage: stage,
                errorDomain: domain,
                errorCode: code,
                message: message,
                isRetryable: retryable,
                detailsJSON: detailsJSON,
                occurredAt: timestamp,
                recoveryDisposition: retryable ? .recoverable : .terminal
            ))
        }
        ownedCapture.session.lastActivityAt = timestamp
        try save(context)
    }



    public func recordMeetingStop(
        _ handle: NoteCaptureHandle,
        retained: [RetainedMeetingSource],
        failures: [FailedMeetingSource],
        at timestamp: Date = Date()
    ) throws {
        let context = ModelContext(modelContainer)
        let ownedCapture = try fetchOwnedNoteCapture(for: handle, in: context)
        let meetingSession = try ownedCapture.session.restoreSession()
        guard ownedCapture.session.stateRawValue == CaptureSessionState.finalizing.rawValue else {
            throw CaptureSessionStoreError.meetingSessionNotFinalizing(
                sessionID: handle.sessionID,
                actualStateRawValue: ownedCapture.session.stateRawValue
            )
        }

        let sources = ownedCapture.sources
        try validateMeetingOutcomes(
            retained: retained,
            failures: failures,
            for: sources
        )

        for source in sources where source.stateRawValue != CaptureSourceState.capturing.rawValue {
            throw CaptureSessionStoreError.meetingSourceAlreadyStopped(source.id)
        }

        let retainedBySourceID = Dictionary(uniqueKeysWithValues: retained.map { ($0.sourceID, $0) })
        let failuresBySourceID = Dictionary(uniqueKeysWithValues: failures.map { ($0.sourceID, $0) })

        for source in sources {
            if let retainedSource = retainedBySourceID[source.id] {
                source.stateRawValue = CaptureSourceState.completed.rawValue
                source.sampleRate = retainedSource.sampleRate
                source.channelCount = retainedSource.channelCount
                source.codecRawValue = "pcm"
                source.endedAt = timestamp
                source.updatedAt = timestamp
                context.insert(CaptureChunkModel(
                    sessionID: handle.sessionID,
                    sourceID: source.id,
                    sequence: 0,
                    startOffset: 0,
                    duration: retainedSource.duration,
                    stateRawValue: CaptureChunkState.sealed.rawValue,
                    managedMediaPath: retainedSource.managedMediaPath,
                    byteCount: retainedSource.byteCount,
                    sha256: retainedSource.sha256,
                    createdAt: timestamp,
                    sealedAt: timestamp
                ))
            } else if let failedSource = failuresBySourceID[source.id] {
                source.stateRawValue = CaptureSourceState.failed.rawValue
                source.endedAt = timestamp
                source.updatedAt = timestamp
                context.insert(CaptureFailureRecordModel(
                    sessionID: handle.sessionID,
                    sourceID: source.id,
                    errorDomain: failedSource.errorDomain,
                    errorCode: failedSource.errorCode,
                    message: failedSource.message,
                    isRetryable: false,
                    occurredAt: failedSource.occurredAt,
                    recoveryDisposition: .terminal
                ))
            }
        }

        if retained.isEmpty {
            let latestFailure = failures.sorted {
                if $0.occurredAt == $1.occurredAt {
                    return $0.sourceID.uuidString < $1.sourceID.uuidString
                }
                return $0.occurredAt < $1.occurredAt
            }.last!
            let aggregateFailure = CaptureFailure(
                sessionID: handle.sessionID,
                disposition: .terminal,
                occurredAt: latestFailure.occurredAt,
                code: latestFailure.errorCode ?? latestFailure.errorDomain,
                message: latestFailure.message
            )
            var session = meetingSession
            try session.fail(with: aggregateFailure, at: timestamp)
            try ownedCapture.session.update(from: session)
            ownedCapture.session.lastActivityAt = timestamp
            context.insert(CaptureFailureRecordModel(
                id: aggregateFailure.id,
                sessionID: handle.sessionID,
                errorDomain: latestFailure.errorDomain,
                errorCode: latestFailure.errorCode,
                message: latestFailure.message,
                isRetryable: false,
                occurredAt: latestFailure.occurredAt,
                recoveryDisposition: .terminal
            ))
        } else {
            ownedCapture.session.lastActivityAt = timestamp
        }
        try save(context)
    }

    public func completeMeetingCapture(
        _ handle: NoteCaptureHandle,
        transcriptionRecordID: UUID,
        at timestamp: Date = Date()
    ) throws {
        let context = ModelContext(modelContainer)
        let ownedCapture = try fetchOwnedNoteCapture(for: handle, in: context)
        let meetingSession = try ownedCapture.session.restoreSession()
        guard ownedCapture.session.stateRawValue == CaptureSessionState.finalizing.rawValue else {
            throw CaptureSessionStoreError.meetingSessionNotFinalizing(
                sessionID: handle.sessionID,
                actualStateRawValue: ownedCapture.session.stateRawValue
            )
        }
        if let reservedID = ownedCapture.session.transcriptionRecordID,
           reservedID != transcriptionRecordID {
            throw CaptureSessionStoreError.transcriptionRecordReservationMismatch(
                expected: reservedID,
                actual: transcriptionRecordID
            )
        }
        try validateMeetingCompletionOutcomes(
            ownedCapture,
            handle: handle,
            in: context
        )
        guard try fetchTranscriptionRecord(id: transcriptionRecordID, in: context) != nil else {
            throw CaptureSessionStoreError.transcriptionRecordNotFound(transcriptionRecordID)
        }
        var session = meetingSession
        try session.complete(at: timestamp)
        try ownedCapture.session.update(from: session)
        ownedCapture.session.transcriptionRecordID = transcriptionRecordID
        ownedCapture.session.lastActivityAt = timestamp
        try save(context)
    }

    public func cancelMeetingCapture(
        _ handle: NoteCaptureHandle,
        at timestamp: Date = Date()
    ) throws {
        let context = ModelContext(modelContainer)
        let ownedCapture = try fetchOwnedNoteCapture(for: handle, in: context)
        var session = try ownedCapture.session.restoreSession()
        guard session.state != .cancelled else {
            return
        }
        try session.cancel(at: timestamp)
        try ownedCapture.session.update(from: session)
        ownedCapture.session.lastActivityAt = timestamp
        for source in ownedCapture.sources
        where source.stateRawValue == CaptureSourceState.capturing.rawValue {
            source.stateRawValue = CaptureSourceState.cancelled.rawValue
            source.endedAt = timestamp
            source.updatedAt = timestamp
        }
        try save(context)
    }

    public func failMeetingCapture(
        _ handle: NoteCaptureHandle,
        stage: CapturePipelineStage?,
        errorDomain: String,
        errorCode: String?,
        message: String,
        at timestamp: Date = Date()
    ) throws {
        let context = ModelContext(modelContainer)
        let ownedCapture = try fetchOwnedNoteCapture(for: handle, in: context)
        let failure = CaptureFailure(
            sessionID: handle.sessionID,
            disposition: .terminal,
            occurredAt: timestamp,
            code: errorCode ?? errorDomain,
            message: message,
            stage: stage
        )
        for source in ownedCapture.sources
        where source.stateRawValue == CaptureSourceState.capturing.rawValue {
            source.stateRawValue = CaptureSourceState.failed.rawValue
            source.endedAt = timestamp
            source.updatedAt = timestamp
            context.insert(CaptureFailureRecordModel(
                sessionID: handle.sessionID,
                sourceID: source.id,
                stage: stage,
                errorDomain: errorDomain,
                errorCode: errorCode,
                message: message,
                isRetryable: false,
                occurredAt: timestamp,
                recoveryDisposition: .terminal
            ))
        }
        var session = try ownedCapture.session.restoreSession()
        try session.fail(with: failure, at: timestamp)
        try ownedCapture.session.update(from: session)
        ownedCapture.session.lastActivityAt = timestamp
        context.insert(CaptureFailureRecordModel(
            id: failure.id,
            sessionID: handle.sessionID,
            stage: stage,
            errorDomain: errorDomain,
            errorCode: errorCode,
            message: message,
            isRetryable: false,
            occurredAt: timestamp,
            recoveryDisposition: .terminal
        ))
        try save(context)
    }

    public func beginFinalization(
        _ handle: NoteCaptureHandle,
        at timestamp: Date = Date()
    ) throws {
        let context = ModelContext(modelContainer)
        let sessionModel = try fetchOwnedSession(for: handle, in: context)
        var session = try sessionModel.restoreSession()
        try session.beginFinalization(at: timestamp)
        try sessionModel.update(from: session)
        sessionModel.lastActivityAt = timestamp
        try save(context)
    }
    /// Persists one cumulative committed-text checkpoint for an active voice-note capture.
    @discardableResult
    public func checkpointVoiceNoteLiveTranscript(
        for handle: NoteCaptureHandle,
        committedText: String,
        assignmentAttempt: Int = 1,
        at timestamp: Date = Date()
    ) throws -> VoiceNoteLiveTranscriptCheckpoint {
        guard !committedText.isEmpty else {
            throw CaptureSessionStoreError.emptyLiveTranscript(handle.sessionID)
        }
        guard assignmentAttempt >= 1 else {
            throw CaptureSessionStoreError.invalidAssignmentAttempt(assignmentAttempt)
        }

        let context = ModelContext(modelContainer)
        let sessionModel = try fetchOwnedSession(for: handle, in: context)
        let providerSnapshot = try liveTranscriptProviderSnapshot(
            sessionID: handle.sessionID,
            attempt: assignmentAttempt,
            in: context
        )
        let checkpoints = try validatedLiveTranscriptCheckpoints(
            sessionID: handle.sessionID,
            sourceID: handle.microphoneSourceID,
            providerSnapshotID: providerSnapshot.id,
            in: context
        )
        if let latest = checkpoints.last {
            if latest.committedText == committedText {
                return latest
            }
            guard committedText.hasPrefix(latest.committedText) else {
                throw CaptureSessionStoreError.liveTranscriptRegression(
                    sessionID: handle.sessionID
                )
            }
        }

        let session = try sessionModel.restoreSession()
        guard session.state == .capturing else {
            throw CaptureSessionStoreError.voiceNoteSessionNotCapturing(
                sessionID: handle.sessionID,
                actualStateRawValue: sessionModel.stateRawValue
            )
        }

        let revision = CaptureTranscriptRevisionModel(
            sessionID: handle.sessionID,
            sourceID: handle.microphoneSourceID,
            sequence: checkpoints.last.map { $0.sequence + 1 } ?? 0,
            parentRevisionID: checkpoints.last?.revisionID,
            stage: .liveTranscription,
            statusRawValue: "completed",
            startOffset: 0,
            duration: 0,
            text: committedText,
            providerSnapshotID: providerSnapshot.id,
            createdAt: timestamp
        )
        context.insert(revision)
        sessionModel.lastActivityAt = timestamp
        try save(context)

        return try liveTranscriptCheckpoint(from: revision)
    }

    @discardableResult
    public func saveTranscriptRevisions(
        for handle: NoteCaptureHandle,
        rawText: String,
        finalText: String,
        duration: TimeInterval,
        languageCode: String?,
        createdAt: Date = Date()
    ) throws -> VoiceNoteTranscriptRevisions {
        let context = ModelContext(modelContainer)
        let sessionModel = try fetchOwnedSession(for: handle, in: context)
        let latestLiveCheckpoint = try latestValidLiveTranscriptCheckpoint(
            sessionID: handle.sessionID,
            sourceID: handle.microphoneSourceID,
            in: context
        )
        let finalStageRawValue = CapturePipelineStage.finalTranscription.rawValue
        let finalRevisions = try fetchTranscriptRevisions(sessionID: handle.sessionID, in: context)
            .filter { $0.stageRawValue == finalStageRawValue }

        if !finalRevisions.isEmpty {
            return try existingVoiceNoteTranscriptRevisions(
                finalRevisions,
                for: handle,
                latestLiveCheckpoint: latestLiveCheckpoint,
                rawText: rawText,
                finalText: finalText,
                duration: duration,
                languageCode: languageCode
            )
        }

        let session = try sessionModel.restoreSession()
        guard session.state == .finalizing else {
            throw CaptureSessionStoreError.voiceNoteSessionNotFinalizing(
                sessionID: handle.sessionID,
                actualStateRawValue: sessionModel.stateRawValue
            )
        }

        let sequence = latestLiveCheckpoint.map { $0.sequence + 1 } ?? 0
        let rawRevision = CaptureTranscriptRevisionModel(
            sessionID: handle.sessionID,
            sourceID: handle.microphoneSourceID,
            sequence: sequence,
            parentRevisionID: latestLiveCheckpoint?.revisionID,
            stage: .finalTranscription,
            statusRawValue: "completed",
            startOffset: 0,
            duration: duration,
            text: rawText,
            languageCode: languageCode,
            createdAt: createdAt
        )
        let finalRevision = CaptureTranscriptRevisionModel(
            sessionID: handle.sessionID,
            sourceID: handle.microphoneSourceID,
            sequence: sequence + 1,
            parentRevisionID: rawRevision.id,
            stage: .finalTranscription,
            statusRawValue: "completed",
            startOffset: 0,
            duration: duration,
            text: finalText,
            languageCode: languageCode,
            createdAt: createdAt
        )
        context.insert(rawRevision)
        context.insert(finalRevision)
        try save(context)

        return VoiceNoteTranscriptRevisions(
            rawRevisionID: rawRevision.id,
            finalRevisionID: finalRevision.id
        )
    }

    /// The newest committed live-transcript checkpoint for one note capture.
    ///
    /// Finalization reads this when no batch transcription can run, so a capture
    /// whose final-ASR stage is unavailable still keeps the text the live engine
    /// already committed instead of losing the recording.
    public func latestLiveTranscriptCheckpoint(
        for handle: NoteCaptureHandle
    ) throws -> VoiceNoteLiveTranscriptCheckpoint? {
        let context = ModelContext(modelContainer)
        _ = try fetchOwnedSession(for: handle, in: context)
        return try latestValidLiveTranscriptCheckpoint(
            sessionID: handle.sessionID,
            sourceID: handle.microphoneSourceID,
            in: context
        )
    }

    public func linkTranscriptionRecord(
        _ transcriptionRecordID: UUID,
        to handle: NoteCaptureHandle,
        at timestamp: Date = Date()
    ) throws {
        let context = ModelContext(modelContainer)
        let sessionModel = try fetchOwnedSession(for: handle, in: context)
        guard try fetchTranscriptionRecord(id: transcriptionRecordID, in: context) != nil else {
            throw CaptureSessionStoreError.transcriptionRecordNotFound(transcriptionRecordID)
        }
        sessionModel.transcriptionRecordID = transcriptionRecordID
        sessionModel.lastActivityAt = timestamp
        try save(context)
    }

    public func complete(
        _ handle: NoteCaptureHandle,
        noteID: UUID,
        finalTranscriptRevisionID: UUID,
        at timestamp: Date = Date()
    ) throws {
        let context = ModelContext(modelContainer)
        let sessionModel = try fetchOwnedSession(for: handle, in: context)
        let revision = try fetchTranscriptRevision(id: finalTranscriptRevisionID, in: context)
        try validateFinalTranscriptRevision(revision, for: handle, in: context)
        guard try fetchNote(id: noteID, in: context) != nil else {
            throw CaptureSessionStoreError.noteNotFound(noteID)
        }

        var session = try sessionModel.restoreSession()
        try session.complete(at: timestamp)
        try sessionModel.update(from: session)
        sessionModel.lastActivityAt = timestamp
        context.insert(CaptureNoteReferenceModel(
            sessionID: handle.sessionID,
            noteID: noteID,
            role: .humanAnchor,
            sourceTranscriptRevisionID: finalTranscriptRevisionID,
            createdAt: timestamp
        ))
        try save(context)
    }

    public func cancel(
        _ handle: NoteCaptureHandle,
        at timestamp: Date = Date()
    ) throws {
        let context = ModelContext(modelContainer)
        let sessionModel = try fetchOwnedSession(for: handle, in: context)
        var session = try sessionModel.restoreSession()
        try session.cancel(at: timestamp)
        try sessionModel.update(from: session)
        sessionModel.lastActivityAt = timestamp
        try save(context)
    }

    public func fail(
        _ handle: NoteCaptureHandle,
        stage: CapturePipelineStage?,
        errorDomain: String,
        errorCode: String?,
        message: String,
        at timestamp: Date = Date()
    ) throws {
        let context = ModelContext(modelContainer)
        let sessionModel = try fetchOwnedSession(for: handle, in: context)
        let failure = CaptureFailure(
            sessionID: handle.sessionID,
            disposition: .terminal,
            occurredAt: timestamp,
            code: errorCode ?? errorDomain,
            message: message,
            stage: stage,
            sourceID: handle.microphoneSourceID
        )
        var session = try sessionModel.restoreSession()
        try session.fail(with: failure, at: timestamp)
        try sessionModel.update(from: session)
        sessionModel.lastActivityAt = timestamp
        context.insert(CaptureFailureRecordModel(
            id: failure.id,
            sessionID: handle.sessionID,
            sourceID: handle.microphoneSourceID,
            stage: stage,
            errorDomain: errorDomain,
            errorCode: errorCode,
            message: message,
            isRetryable: false,
            occurredAt: timestamp,
            recoveryDisposition: .terminal
        ))
        try save(context)
    }

    private func validateMeetingCompletionOutcomes(
        _ ownedCapture: OwnedNoteCapture,
        handle: NoteCaptureHandle,
        in context: ModelContext
    ) throws {
        let sources = ownedCapture.sources
        let sourceIDs = Set(sources.map(\.id))
        let chunks = try fetchMeetingChunks(sessionID: handle.sessionID, in: context)
        let failures = try fetchMeetingFailures(sessionID: handle.sessionID, in: context)

        for chunk in chunks where !sourceIDs.contains(chunk.sourceID) {
            throw CaptureSessionStoreError.meetingSourceOutcomeForeign(chunk.sourceID)
        }
        for failure in failures {
            if let sourceID = failure.sourceID, !sourceIDs.contains(sourceID) {
                throw CaptureSessionStoreError.meetingSourceOutcomeForeign(sourceID)
            }
        }

        var completedSourceCount = 0
        for source in sources {
            let sourceChunks = chunks.filter { $0.sourceID == source.id }
            let sourceFailures = failures.filter { $0.sourceID == source.id }
            switch source.stateRawValue {
            case CaptureSourceState.completed.rawValue:
                try validateMeetingChunks(
                    sourceChunks,
                    sourceID: source.id,
                    sessionID: handle.sessionID,
                    failedSequences: failedSequences(for: source.id, from: sourceFailures)
                )
                guard !hasSourceWideFailure(sourceFailures) else {
                    throw CaptureSessionStoreError.meetingSourceOutcomeMismatch(source.id)
                }
                completedSourceCount += 1
            case CaptureSourceState.failed.rawValue:
                guard sourceChunks.isEmpty, hasSourceWideFailure(sourceFailures) else {
                    throw CaptureSessionStoreError.meetingSourceOutcomeMismatch(source.id)
                }
            case CaptureSourceState.capturing.rawValue:
                throw CaptureSessionStoreError.meetingSourceNotTerminal(source.id)
            default:
                throw CaptureSessionStoreError.meetingSourceOutcomeMismatch(source.id)
            }
        }

        guard completedSourceCount > 0 else {
            throw CaptureSessionStoreError.meetingCaptureHasNoCompletedSource(handle.sessionID)
        }
        let revisions = try fetchTranscriptRevisions(sessionID: handle.sessionID, in: context)
        let completedCheckpoints = revisions.compactMap(finalASRCheckpoint(from:))
        let expectedSequences = Set(chunks.compactMap(meetingCheckpoint(from:)).map(\.sequence))
        let completedSequences = Set(completedCheckpoints.map(\.sequence))
        let missingSequences = expectedSequences.subtracting(completedSequences).sorted()
        guard missingSequences.isEmpty else {
            throw CaptureSessionStoreError.meetingCaptureHasIncompleteFinalTranscript(
                sessionID: handle.sessionID,
                sequences: missingSequences
            )
        }
        guard completedCheckpoints.contains(where: { !$0.text.isEmpty }) else {
            throw CaptureSessionStoreError.meetingCaptureHasNoFinalTranscript(handle.sessionID)
        }
    }

    private func validateMeetingOutcomes(
        retained: [RetainedMeetingSource],
        failures: [FailedMeetingSource],
        for sources: [CaptureSourceModel],
        allowMissingRetained: Bool = false
    ) throws {
        let sourcesByID = Dictionary(uniqueKeysWithValues: sources.map { ($0.id, $0) })
        var outcomeSourceIDs = Set<UUID>()

        for retainedSource in retained {
            guard let source = sourcesByID[retainedSource.sourceID] else {
                throw CaptureSessionStoreError.meetingSourceOutcomeForeign(retainedSource.sourceID)
            }
            guard outcomeSourceIDs.insert(retainedSource.sourceID).inserted else {
                throw CaptureSessionStoreError.meetingSourceOutcomeDuplicate(retainedSource.sourceID)
            }
            guard
                retainedSource.sampleRate > 0,
                retainedSource.channelCount > 0,
                retainedSource.duration >= 0,
                retainedSource.managedMediaPath == CaptureSourceArtifactPath.relativePath(
                    sessionID: source.sessionID,
                    sourceID: source.id,
                    chunkSequence: 0
                ),
                retainedSource.byteCount >= 0,
                !retainedSource.sha256.isEmpty
            else {
                throw CaptureSessionStoreError.invalidRetainedMeetingSource(retainedSource.sourceID)
            }
        }
        for failedSource in failures {
            guard sourcesByID[failedSource.sourceID] != nil else {
                throw CaptureSessionStoreError.meetingSourceOutcomeForeign(failedSource.sourceID)
            }
            guard outcomeSourceIDs.insert(failedSource.sourceID).inserted else {
                throw CaptureSessionStoreError.meetingSourceOutcomeDuplicate(failedSource.sourceID)
            }
        }
        if !allowMissingRetained {
            for source in sources where !outcomeSourceIDs.contains(source.id) {
                throw CaptureSessionStoreError.meetingSourceOutcomeMissing(source.id)
            }
        }
    }

    private func checkpointMeetingChunk(
        _ checkpoint: MeetingChunkCheckpoint,
        handle: NoteCaptureHandle,
        sources: [CaptureSourceModel],
        in context: ModelContext
    ) throws {
        guard sources.contains(where: { $0.id == checkpoint.sourceID }) else {
            throw CaptureSessionStoreError.meetingSourceOutcomeForeign(checkpoint.sourceID)
        }
        try validateMeetingChunk(checkpoint, sessionID: handle.sessionID)
        let existingChunks = try fetchMeetingChunks(sessionID: handle.sessionID, in: context)
            .filter { $0.sourceID == checkpoint.sourceID }
        let matching = existingChunks.filter { $0.sequence == checkpoint.sequence }
        if let existing = matching.first {
            guard matching.count == 1, checkpointMatches(existing, checkpoint) else {
                throw CaptureSessionStoreError.meetingChunkConflict(
                    sourceID: checkpoint.sourceID,
                    sequence: checkpoint.sequence
                )
            }
            return
        }
        let ordered = existingChunks.sorted { $0.sequence < $1.sequence }
        let expectedSequence = (ordered.last?.sequence ?? -1) + 1
        let missingSequences = checkpoint.sequence > expectedSequence
            ? Set(expectedSequence..<checkpoint.sequence)
            : []
        let persistedFailures = try fetchMeetingFailures(sessionID: handle.sessionID, in: context)
        let failedSequenceSet = failedSequences(
            for: checkpoint.sourceID,
            from: persistedFailures
        )
        guard
            checkpoint.sequence >= expectedSequence,
            missingSequences.isSubset(of: failedSequenceSet)
        else {
            throw CaptureSessionStoreError.meetingChunkSequenceGap(
                sourceID: checkpoint.sourceID,
                expected: expectedSequence,
                actual: checkpoint.sequence
            )
        }
        if let previous = ordered.last {
            let sampleDuration = 1.0 / Double(MeetingCaptureSpoolPlan.sampleRate)
            guard checkpoint.startOffset + sampleDuration >= previous.startOffset + previous.duration else {
                throw CaptureSessionStoreError.invalidMeetingChunk(
                    sourceID: checkpoint.sourceID,
                    sequence: checkpoint.sequence
                )
            }
        }
        context.insert(CaptureChunkModel(
            id: checkpoint.chunkID,
            sessionID: handle.sessionID,
            sourceID: checkpoint.sourceID,
            sequence: checkpoint.sequence,
            startOffset: checkpoint.startOffset,
            duration: checkpoint.duration,
            stateRawValue: CaptureChunkState.sealed.rawValue,
            managedMediaPath: checkpoint.managedMediaPath,
            byteCount: checkpoint.byteCount,
            sha256: checkpoint.sha256,
            createdAt: checkpoint.sealedAt,
            sealedAt: checkpoint.sealedAt
        ))
    }

    private func checkpointMeetingChunkFailure(
        _ failure: MeetingChunkFailure,
        handle: NoteCaptureHandle,
        sources: [CaptureSourceModel],
        associateWithPersistedChunk: Bool = true,
        in context: ModelContext
    ) throws {
        guard sources.contains(where: { $0.id == failure.sourceID }), failure.sequence.map({ $0 >= 0 }) ?? true else {
            throw CaptureSessionStoreError.meetingSourceOutcomeForeign(failure.sourceID)
        }
        let detailsJSON = meetingFailureDetailsJSON(for: failure)
        let existingFailures = try fetchMeetingFailures(sessionID: handle.sessionID, in: context)
        if existingFailures.contains(where: { failureMatches($0, failure, detailsJSON: detailsJSON) }) {
            return
        }
        let chunkID: UUID?
        if let sequence = failure.sequence, associateWithPersistedChunk {
            let chunks = try fetchMeetingChunks(sessionID: handle.sessionID, in: context)
            let persistedChunkID = chunks.first(where: {
                $0.sourceID == failure.sourceID && $0.sequence == sequence
            })?.id
            chunkID = failure.chunkID ?? persistedChunkID
        } else {
            chunkID = failure.chunkID
        }
        context.insert(CaptureFailureRecordModel(
            sessionID: handle.sessionID,
            sourceID: failure.sourceID,
            chunkID: chunkID,
            stage: failure.stage,
            errorDomain: failure.errorDomain,
            errorCode: failure.errorCode,
            message: failure.message,
            isRetryable: failure.isRetryable,
            detailsJSON: detailsJSON,
            occurredAt: failure.occurredAt,
            recoveryDisposition: failure.isRetryable ? .recoverable : .terminal
        ))
    }

    private func isHumanAnchorAllowed(sessionStateRawValue: String) -> Bool {
        switch sessionStateRawValue {
        case CaptureSessionState.capturing.rawValue,
             CaptureSessionState.finalizing.rawValue,
             CaptureSessionState.interrupted.rawValue:
            return true
        default:
            return false
        }
    }

    private func meetingGeneratedNotePreflight(
        _ handle: NoteCaptureHandle,
        assignmentAttempt: Int,
        in context: ModelContext
    ) throws -> MeetingGeneratedNotePreflightSnapshot {
        guard assignmentAttempt >= 1 else {
            throw CaptureSessionStoreError.invalidAssignmentAttempt(assignmentAttempt)
        }
        let ownedCapture = try fetchOwnedNoteCapture(for: handle, in: context)
        guard let humanAnchor = try validMeetingHumanAnchor(
            sessionID: handle.sessionID,
            in: context
        ) else {
            throw CaptureSessionStoreError.meetingHumanAnchorUnavailable(handle.sessionID)
        }
        guard let sourceTranscriptionID = ownedCapture.session.transcriptionRecordID else {
            throw CaptureSessionStoreError.invalidMeetingGeneratedNote(handle.sessionID)
        }
        guard try fetchTranscriptionRecord(id: sourceTranscriptionID, in: context) != nil else {
            throw CaptureSessionStoreError.transcriptionRecordNotFound(sourceTranscriptionID)
        }

        let snapshots = try fetchAssignmentSnapshots(
            sessionID: handle.sessionID,
            stage: .noteGeneration,
            attempt: assignmentAttempt,
            in: context
        )
        guard snapshots.count == 1 else {
            if snapshots.count > 1 {
                throw CaptureSessionStoreError.duplicateAssignments(
                    sessionID: handle.sessionID,
                    stage: .noteGeneration,
                    attempt: assignmentAttempt
                )
            }
            throw CaptureSessionStoreError.invalidMeetingGeneratedNote(handle.sessionID)
        }
        let assignment: CaptureStageAssignment
        do {
            guard let restoredAssignment = try persistedAssignment(
                sessionID: handle.sessionID,
                stage: .noteGeneration,
                attempt: assignmentAttempt,
                in: context
            ) else {
                throw CaptureSessionStoreError.invalidMeetingGeneratedNote(handle.sessionID)
            }
            assignment = restoredAssignment
        } catch let error as CaptureSessionStoreError {
            throw error
        } catch {
            throw CaptureSessionStoreError.invalidMeetingGeneratedNote(handle.sessionID)
        }
        guard
            assignment.stage == .noteGeneration,
            assignment.providerKind == .generativeAI,
            let modelIdentifier = assignment.modelIdentifier,
            !modelIdentifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            let resolvedPrompt = assignment.prompt?.resolvedPrompt,
            !resolvedPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            throw CaptureSessionStoreError.invalidMeetingGeneratedNote(handle.sessionID)
        }

        return MeetingGeneratedNotePreflightSnapshot(
            sessionID: handle.sessionID,
            humanAnchor: humanAnchor,
            sourceTranscriptionID: sourceTranscriptionID,
            providerSnapshotID: snapshots[0].id,
            assignmentAttempt: assignmentAttempt
        )
    }

    func validMeetingHumanAnchor(
        sessionID: UUID,
        in context: ModelContext
    ) throws -> MeetingHumanAnchorSnapshot? {
        let references = try meetingNoteReferences(sessionID: sessionID, in: context)
        let humanReferences: [CaptureNoteReferenceModel]
        do {
            for reference in references {
                _ = try reference.resolvedRole()
            }
            humanReferences = try references.filter {
                try $0.resolvedRole() == .humanAnchor
            }
        } catch {
            throw CaptureSessionStoreError.meetingHumanAnchorConflict(sessionID)
        }
        guard humanReferences.count <= 1 else {
            throw CaptureSessionStoreError.meetingHumanAnchorConflict(sessionID)
        }
        guard let reference = humanReferences.first else {
            return nil
        }
        guard
            reference.sourceTranscriptRevisionID == nil,
            reference.providerSnapshotID == nil,
            reference.provenanceJSON == nil,
            reference.humanAnchorContentSnapshot == nil,
            let note = try fetchNote(id: reference.noteID, in: context),
            note.sourceTranscriptionID == nil
        else {
            throw CaptureSessionStoreError.meetingHumanAnchorConflict(sessionID)
        }
        return MeetingHumanAnchorSnapshot(
            sessionID: sessionID,
            noteID: note.id,
            title: note.title,
            content: note.content
        )
    }

    func meetingNoteReferences(
        sessionID: UUID,
        in context: ModelContext
    ) throws -> [CaptureNoteReferenceModel] {
        let descriptor = FetchDescriptor<CaptureNoteReferenceModel>(
            predicate: #Predicate<CaptureNoteReferenceModel> { $0.sessionID == sessionID }
        )
        do {
            return try context.fetch(descriptor)
        } catch {
            throw CaptureSessionStoreError.fetchFailed(error.localizedDescription)
        }
    }

    private func checkpointMeetingRevision(
        _ handle: NoteCaptureHandle,
        sequence: Int,
        stage: CapturePipelineStage,
        startOffset: TimeInterval,
        duration: TimeInterval,
        text: String,
        segmentsJSON: String?,
        languageCode: String?,
        assignmentAttempt: Int?,
        at timestamp: Date
    ) throws -> UUID {
        guard sequence >= 0, startOffset >= 0, duration >= 0 else {
            throw CaptureSessionStoreError.meetingTranscriptionRevisionConflict(sequence: sequence, stage: stage)
        }
        let context = ModelContext(modelContainer)
        _ = try fetchOwnedNoteCapture(for: handle, in: context)
        let providerSnapshotID = try assignmentAttempt.map {
            try meetingRevisionProviderSnapshotID(
                sessionID: handle.sessionID,
                stage: stage,
                assignmentAttempt: $0,
                sequence: sequence,
                in: context
            )
        }
        let chunks = try fetchMeetingChunks(sessionID: handle.sessionID, in: context)
            .filter { $0.sequence == sequence }
        guard
            let expectedStartOffset = chunks.map(\.startOffset).min(),
            let expectedDuration = chunks.map(\.duration).max()
        else {
            throw CaptureSessionStoreError.invalidMeetingChunk(
                sourceID: handle.microphoneSourceID,
                sequence: sequence
            )
        }
        let sampleDuration = 1.0 / Double(MeetingCaptureSpoolPlan.sampleRate)
        guard
            abs(startOffset - expectedStartOffset) <= sampleDuration,
            abs(duration - expectedDuration) <= sampleDuration
        else {
            throw CaptureSessionStoreError.meetingTranscriptionRevisionConflict(
                sequence: sequence,
                stage: stage
            )
        }
        let revisions = try fetchTranscriptRevisions(sessionID: handle.sessionID, in: context)
        let matching = revisions.filter {
            $0.sourceID == nil &&
                $0.sequence == sequence &&
                $0.stageRawValue == stage.rawValue
        }
        if let existing = matching.first {
            guard
                matching.count == 1,
                existing.statusRawValue == "completed",
                abs(existing.startOffset - expectedStartOffset) <= sampleDuration,
                abs(existing.duration - expectedDuration) <= sampleDuration,
                existing.text == text,
                existing.segmentsJSON == segmentsJSON,
                existing.languageCode == languageCode,
                (existing.providerSnapshotID == providerSnapshotID ||
                    existing.providerSnapshotID == nil)
            else {
                throw CaptureSessionStoreError.meetingTranscriptionRevisionConflict(
                    sequence: sequence,
                    stage: stage
                )
            }
            if stage == .finalTranscription,
               try markRetryableFinalTranscriptionFailuresRecovered(
                    sessionID: handle.sessionID,
                    sequence: sequence,
                    at: timestamp,
                    in: context
               ) {
                try save(context)
            }
            return existing.id
        }
        let revision = CaptureTranscriptRevisionModel(
            sessionID: handle.sessionID,
            sequence: sequence,
            stage: stage,
            statusRawValue: "completed",
            startOffset: expectedStartOffset,
            duration: expectedDuration,
            text: text,
            segmentsJSON: segmentsJSON,
            languageCode: languageCode,
            providerSnapshotID: providerSnapshotID,
            createdAt: timestamp
        )
        context.insert(revision)
        if stage == .finalTranscription {
            _ = try markRetryableFinalTranscriptionFailuresRecovered(
                sessionID: handle.sessionID,
                sequence: sequence,
                at: timestamp,
                in: context
            )
        }
        try save(context)
        return revision.id
    }
    private func meetingRevisionProviderSnapshotID(
        sessionID: UUID,
        stage: CapturePipelineStage,
        assignmentAttempt: Int,
        sequence: Int,
        in context: ModelContext
    ) throws -> UUID {
        guard assignmentAttempt >= 1 else {
            throw CaptureSessionStoreError.invalidAssignmentAttempt(assignmentAttempt)
        }
        let snapshots = try fetchAssignmentSnapshots(
            sessionID: sessionID,
            stage: stage,
            attempt: assignmentAttempt,
            in: context
        )
        guard snapshots.count == 1 else {
            if snapshots.count > 1 {
                throw CaptureSessionStoreError.duplicateAssignments(
                    sessionID: sessionID,
                    stage: stage,
                    attempt: assignmentAttempt
                )
            }
            throw CaptureSessionStoreError.meetingTranscriptionRevisionConflict(
                sequence: sequence,
                stage: stage
            )
        }
        guard try persistedAssignment(
            sessionID: sessionID,
            stage: stage,
            attempt: assignmentAttempt,
            in: context
        ) != nil else {
            throw CaptureSessionStoreError.meetingTranscriptionRevisionConflict(
                sequence: sequence,
                stage: stage
            )
        }
        return snapshots[0].id
    }


    private func makeNoteCaptureRecoverySnapshot(
        handle: NoteCaptureHandle,
        mode: CaptureSessionMode,
        session: CaptureSession,
        intent: CaptureIntent?,
        lastActivityAt: Date?,
        latestLiveCheckpoint: VoiceNoteLiveTranscriptCheckpoint?,
        chunks: [CaptureChunkModel],
        revisions: [CaptureTranscriptRevisionModel],
        failures: [CaptureFailureRecordModel],
        reservedTranscriptionRecordID: UUID?
    ) -> NoteCaptureRecoverySnapshot {
        let sourceChunks = chunks.compactMap(meetingCheckpoint(from:)).sorted {
            ($0.sequence, $0.sourceID.uuidString) < ($1.sequence, $1.sourceID.uuidString)
        }
        let completedASRCheckpoints = revisions.compactMap(finalASRCheckpoint(from:)).sorted {
            $0.sequence < $1.sequence
        }
        let completedDiarizationSequences = Set(revisions.compactMap {
            $0.stageRawValue == CapturePipelineStage.diarization.rawValue &&
                $0.statusRawValue == "completed" ? $0.sequence : nil
        })
        return NoteCaptureRecoverySnapshot(
            handle: handle,
            mode: mode,
            state: session.state,
            recoveryTarget: session.recoveryTarget,
            intent: intent,
            startedAt: session.startedAt,
            lastActivityAt: lastActivityAt,
            latestLiveCheckpoint: latestLiveCheckpoint,
            sourceChunks: sourceChunks,
            failedSequences: failedSequences(from: failures),
            completedASRCheckpoints: completedASRCheckpoints,
            completedDiarizationSequences: completedDiarizationSequences,
            reservedTranscriptionRecordID: reservedTranscriptionRecordID
        )
    }

    private func meetingCheckpoint(from chunk: CaptureChunkModel) -> MeetingChunkCheckpoint? {
        guard
            chunk.stateRawValue == CaptureChunkState.sealed.rawValue,
            let managedMediaPath = chunk.managedMediaPath,
            let sha256 = chunk.sha256,
            let sealedAt = chunk.sealedAt
        else {
            return nil
        }
        return MeetingChunkCheckpoint(
            chunkID: chunk.id,
            sourceID: chunk.sourceID,
            sequence: chunk.sequence,
            startOffset: chunk.startOffset,
            duration: chunk.duration,
            managedMediaPath: managedMediaPath,
            byteCount: chunk.byteCount,
            sha256: sha256,
            sealedAt: sealedAt
        )
    }

    /// The chunk-level final-ASR checkpoints a meeting note is generated from.
    /// Source-scoped revisions are excluded: they belong to the whole-capture
    /// voice-note shape, which is not chunked evidence.
    private func finalASRCheckpoint(
        from revision: CaptureTranscriptRevisionModel
    ) -> MeetingTranscriptionCheckpoint? {
        guard revision.sourceID == nil else {
            return nil
        }
        return completedFinalTranscriptCheckpoint(from: revision)
    }

    /// One completed final-transcript revision as a checkpoint, whether it is
    /// scoped to a chunk of the session or to the whole microphone source.
    func completedFinalTranscriptCheckpoint(
        from revision: CaptureTranscriptRevisionModel
    ) -> MeetingTranscriptionCheckpoint? {
        guard
            revision.stageRawValue == CapturePipelineStage.finalTranscription.rawValue,
            revision.statusRawValue == "completed"
        else {
            return nil
        }
        return MeetingTranscriptionCheckpoint(
            revisionID: revision.id,
            providerSnapshotID: revision.providerSnapshotID,
            sequence: revision.sequence,
            startOffset: revision.startOffset,
            duration: revision.duration,
            text: revision.text,
            segmentsJSON: revision.segmentsJSON,
            languageCode: revision.languageCode
        )
    }
    func derivedMeetingNoteSource(
        sessionID: UUID,
        humanNoteContent: String,
        in context: ModelContext
    ) throws -> MeetingNoteSourceBundle {
        let checkpoints = try fetchTranscriptRevisions(sessionID: sessionID, in: context)
            .compactMap(finalASRCheckpoint(from:))
            .sorted {
                if $0.sequence != $1.sequence {
                    return $0.sequence < $1.sequence
                }
                return $0.revisionID.uuidString < $1.revisionID.uuidString
            }
        return try MeetingNoteDerivation.make(
            humanNoteContent: humanNoteContent,
            checkpoints: checkpoints
        )
    }

    private func validateMeetingChunk(
        _ checkpoint: MeetingChunkCheckpoint,
        sessionID: UUID
    ) throws {
        let expectedPath = CaptureSourceArtifactPath.relativePath(
            sessionID: sessionID,
            sourceID: checkpoint.sourceID,
            chunkSequence: checkpoint.sequence
        )
        let expectedDuration = Double(checkpoint.byteCount) /
            Double(MeetingCaptureSpoolPlan.sampleRate * MeetingCaptureSpoolPlan.bytesPerSample)
        guard
            checkpoint.sequence >= 0,
            checkpoint.startOffset >= 0,
            checkpoint.duration > 0,
            checkpoint.managedMediaPath == expectedPath,
            checkpoint.byteCount > 0,
            checkpoint.byteCount <= MeetingCaptureSpoolPlan.defaultChunkByteCount,
            checkpoint.byteCount % MeetingCaptureSpoolPlan.bytesPerSample == 0,
            !checkpoint.sha256.isEmpty,
            abs(checkpoint.duration - expectedDuration) <= (1.0 / Double(MeetingCaptureSpoolPlan.sampleRate))
        else {
            throw CaptureSessionStoreError.invalidMeetingChunk(
                sourceID: checkpoint.sourceID,
                sequence: checkpoint.sequence
            )
        }
    }

    private func validateMeetingChunks(
        _ chunks: [CaptureChunkModel],
        sourceID: UUID,
        sessionID: UUID,
        failedSequences: Set<Int>
    ) throws {
        guard !chunks.isEmpty else {
            throw CaptureSessionStoreError.meetingSourceOutcomeMismatch(sourceID)
        }
        let sampleDuration = 1.0 / Double(MeetingCaptureSpoolPlan.sampleRate)
        var expectedSequence = 0
        var previousEndOffset: TimeInterval?
        for chunk in chunks.sorted(by: { $0.sequence < $1.sequence }) {
            guard
                let checkpoint = meetingCheckpoint(from: chunk),
                checkpoint.sourceID == sourceID,
                checkpoint.sequence >= expectedSequence
            else {
                throw CaptureSessionStoreError.meetingSourceOutcomeMismatch(sourceID)
            }
            let missingSequences = checkpoint.sequence > expectedSequence
                ? Set(expectedSequence..<checkpoint.sequence)
                : []
            guard missingSequences.isSubset(of: failedSequences) else {
                throw CaptureSessionStoreError.meetingSourceOutcomeMismatch(sourceID)
            }
            try validateMeetingChunk(checkpoint, sessionID: sessionID)
            if let previousEndOffset,
               checkpoint.startOffset + sampleDuration < previousEndOffset {
                throw CaptureSessionStoreError.meetingSourceOutcomeMismatch(sourceID)
            }
            expectedSequence = checkpoint.sequence + 1
            previousEndOffset = checkpoint.startOffset + checkpoint.duration
        }
    }

    private struct MeetingFailureDetails: Decodable {
        let sequence: Int?
        let invalidatesSource: Bool?
    }

    private func meetingFailureDetailsJSON(for failure: MeetingChunkFailure) -> String? {
        if let sequence = failure.sequence {
            return failure.invalidatesSource
                ? "{\"sequence\":\(sequence),\"invalidatesSource\":true}"
                : "{\"sequence\":\(sequence)}"
        }
        return failure.invalidatesSource ? "{\"invalidatesSource\":true}" : nil
    }

    private func failureDetails(
        from failure: CaptureFailureRecordModel
    ) -> MeetingFailureDetails? {
        guard let detailsJSON = failure.detailsJSON else {
            return nil
        }
        do {
            return try JSONDecoder().decode(
                MeetingFailureDetails.self,
                from: Data(detailsJSON.utf8)
            )
        } catch {
            return nil
        }
    }

    private func persistedFailureSequence(
        from failure: CaptureFailureRecordModel
    ) -> Int? {
        guard let sequence = failureDetails(from: failure)?.sequence, sequence >= 0 else {
            return nil
        }
        return sequence
    }

    private func failedSequences(
        from failures: [CaptureFailureRecordModel]
    ) -> Set<Int> {
        Set(failures.compactMap(persistedFailureSequence(from:)))
    }

    private func failedSequences(
        for sourceID: UUID,
        from failures: [CaptureFailureRecordModel]
    ) -> Set<Int> {
        failedSequences(from: failures.filter { $0.sourceID == sourceID })
    }

    private func hasSourceWideFailure(
        _ failures: [CaptureFailureRecordModel]
    ) -> Bool {
        failures.contains { failure in
            persistedFailureSequence(from: failure) == nil &&
                (failureDetails(from: failure)?.invalidatesSource == true || !failure.isRetryable)
        }
    }

    private func checkpointMatches(
        _ existing: CaptureChunkModel,
        _ checkpoint: MeetingChunkCheckpoint
    ) -> Bool {
        existing.sequence == checkpoint.sequence &&
            existing.startOffset == checkpoint.startOffset &&
            existing.duration == checkpoint.duration &&
            existing.stateRawValue == CaptureChunkState.sealed.rawValue &&
            existing.managedMediaPath == checkpoint.managedMediaPath &&
            existing.byteCount == checkpoint.byteCount &&
            existing.sha256 == checkpoint.sha256
    }

    private func failureMatches(
        _ existing: CaptureFailureRecordModel,
        _ failure: MeetingChunkFailure,
        detailsJSON: String?
    ) -> Bool {
        existing.sourceID == failure.sourceID &&
            (failure.chunkID == nil || existing.chunkID == failure.chunkID) &&
            existing.stageRawValue == failure.stage?.rawValue &&
            existing.errorDomain == failure.errorDomain &&
            existing.errorCode == failure.errorCode &&
            existing.message == failure.message &&
            existing.isRetryable == failure.isRetryable &&
            existing.detailsJSON == detailsJSON &&
            existing.occurredAt == failure.occurredAt
    }

    private func markRetryableFinalTranscriptionFailuresRecovered(
        sessionID: UUID,
        sequence: Int,
        at timestamp: Date,
        in context: ModelContext
    ) throws -> Bool {
        let failures = try fetchMeetingFailures(sessionID: sessionID, in: context)
        let matchingFailures = failures.filter {
            $0.stageRawValue == CapturePipelineStage.finalTranscription.rawValue &&
                $0.isRetryable &&
                $0.recoveredAt == nil &&
                persistedFailureSequence(from: $0) == sequence
        }
        for failure in matchingFailures {
            failure.recoveredAt = timestamp
        }
        return !matchingFailures.isEmpty
    }
    private func markFailureRecovered(
        id: UUID,
        at timestamp: Date,
        in context: ModelContext
    ) throws {
        var descriptor = FetchDescriptor<CaptureFailureRecordModel>(
            predicate: #Predicate<CaptureFailureRecordModel> { $0.id == id }
        )
        descriptor.fetchLimit = 1
        do {
            try context.fetch(descriptor).first?.recoveredAt = timestamp
        } catch {
            throw CaptureSessionStoreError.fetchFailed(error.localizedDescription)
        }
    }
    func persistedAssignment(
        sessionID: UUID,
        stage: CapturePipelineStage,
        attempt: Int,
        in context: ModelContext
    ) throws -> CaptureStageAssignment? {
        let snapshots = try fetchAssignmentSnapshots(
            sessionID: sessionID,
            stage: stage,
            attempt: attempt,
            in: context
        )
        guard snapshots.count <= 1 else {
            throw CaptureSessionStoreError.duplicateAssignments(
                sessionID: sessionID,
                stage: stage,
                attempt: attempt
            )
        }
        guard let snapshot = snapshots.first else {
            return nil
        }

        guard snapshot.sessionID == sessionID else {
            throw CaptureSessionProjectionError.invalidPersistedAssignment
        }

        let promptSnapshots = try fetchPromptSnapshots(
            providerSnapshotID: snapshot.id,
            in: context
        )
        guard promptSnapshots.count <= 1 else {
            throw CaptureSessionStoreError.duplicateAssignments(
                sessionID: sessionID,
                stage: stage,
                attempt: attempt
            )
        }
        if let promptSnapshot = promptSnapshots.first {
            guard
                promptSnapshot.providerSnapshotID == snapshot.id,
                promptSnapshot.sessionID == sessionID
            else {
                throw CaptureSessionProjectionError.invalidPersistedAssignment
            }

            let providerAssignment = try snapshot.restoreAssignment()
            do {
                return try CaptureStageAssignment(
                    stage: providerAssignment.stage,
                    providerKind: providerAssignment.providerKind,
                    providerIdentifier: providerAssignment.providerIdentifier,
                    modelIdentifier: providerAssignment.modelIdentifier,
                    prompt: promptSnapshot.restorePrompt(),
                    selectedAt: providerAssignment.selectedAt,
                    attempt: providerAssignment.attempt
                )
            } catch {
                throw CaptureSessionProjectionError.invalidPersistedAssignment
            }
        }

        let providerAssignment = try snapshot.restoreAssignment()
        guard let legacyPromptPresetID = snapshot.promptPresetID else {
            return providerAssignment
        }

        do {
            return try CaptureStageAssignment(
                stage: providerAssignment.stage,
                providerKind: providerAssignment.providerKind,
                providerIdentifier: providerAssignment.providerIdentifier,
                modelIdentifier: providerAssignment.modelIdentifier,
                prompt: CapturePromptSnapshot(
                    presetIdentifier: legacyPromptPresetID.uuidString,
                    resolvedPrompt: nil
                ),
                selectedAt: providerAssignment.selectedAt,
                attempt: providerAssignment.attempt
            )
        } catch {
            throw CaptureSessionProjectionError.invalidPersistedAssignment
        }
    }

    func fetchAssignmentSession(
        id: UUID,
        in context: ModelContext
    ) throws -> CaptureSessionModel {
        do {
            return try fetchSession(id: id, in: context)
        } catch CaptureSessionStoreError.sessionNotFound {
            throw CaptureSessionStoreError.assignmentSessionNotFound(id)
        }
    }

    func fetchAssignmentSnapshots(
        sessionID: UUID,
        stage: CapturePipelineStage,
        attempt: Int,
        in context: ModelContext
    ) throws -> [CaptureStageProviderSnapshotModel] {
        let stageRawValue = stage.rawValue
        let descriptor = FetchDescriptor<CaptureStageProviderSnapshotModel>(
            predicate: #Predicate<CaptureStageProviderSnapshotModel> {
                $0.sessionID == sessionID &&
                    $0.stageRawValue == stageRawValue &&
                    $0.attempt == attempt
            }
        )
        do {
            return try context.fetch(descriptor)
        } catch {
            throw CaptureSessionStoreError.fetchFailed(error.localizedDescription)
        }
    }

    private func fetchPromptSnapshots(
        providerSnapshotID: UUID,
        in context: ModelContext
    ) throws -> [CaptureStagePromptSnapshotModel] {
        let descriptor = FetchDescriptor<CaptureStagePromptSnapshotModel>(
            predicate: #Predicate<CaptureStagePromptSnapshotModel> {
                $0.providerSnapshotID == providerSnapshotID
            }
        )
        do {
            return try context.fetch(descriptor)
        } catch {
            throw CaptureSessionStoreError.fetchFailed(error.localizedDescription)
        }
    }
    private func fetchLiveTranscriptProviderSnapshots(
        sessionID: UUID,
        in context: ModelContext
    ) throws -> [CaptureStageProviderSnapshotModel] {
        let stageRawValue = CapturePipelineStage.liveTranscription.rawValue
        let descriptor = FetchDescriptor<CaptureStageProviderSnapshotModel>(
            predicate: #Predicate<CaptureStageProviderSnapshotModel> {
                $0.sessionID == sessionID && $0.stageRawValue == stageRawValue
            }
        )
        do {
            return try context.fetch(descriptor)
        } catch {
            throw CaptureSessionStoreError.fetchFailed(error.localizedDescription)
        }
    }
    private func liveTranscriptProviderSnapshot(
        sessionID: UUID,
        attempt: Int,
        in context: ModelContext
    ) throws -> CaptureStageProviderSnapshotModel {
        let snapshots = try fetchAssignmentSnapshots(
            sessionID: sessionID,
            stage: .liveTranscription,
            attempt: attempt,
            in: context
        )
        guard snapshots.count <= 1 else {
            throw CaptureSessionStoreError.duplicateLiveTranscriptAssignments(
                sessionID: sessionID,
                attempt: attempt
            )
        }
        guard let snapshot = snapshots.first else {
            throw CaptureSessionStoreError.liveTranscriptAssignmentNotFound(
                sessionID: sessionID,
                attempt: attempt
            )
        }
        guard
            let assignment = try? snapshot.restoreAssignment(),
            assignment.providerKind == .streamingSpeech,
            assignment.modelIdentifier != nil
        else {
            throw CaptureSessionStoreError.liveTranscriptAssignmentUnavailable(
                sessionID: sessionID,
                attempt: attempt
            )
        }
        return snapshot
    }

    func latestValidLiveTranscriptCheckpoint(
        sessionID: UUID,
        sourceID: UUID,
        in context: ModelContext
    ) throws -> VoiceNoteLiveTranscriptCheckpoint? {
        try validatedLiveTranscriptCheckpoints(
            sessionID: sessionID,
            sourceID: sourceID,
            providerSnapshotID: nil,
            in: context
        ).last
    }

    private func validatedLiveTranscriptCheckpoints(
        sessionID: UUID,
        sourceID: UUID,
        providerSnapshotID: UUID?,
        in context: ModelContext
    ) throws -> [VoiceNoteLiveTranscriptCheckpoint] {
        let liveStageRawValue = CapturePipelineStage.liveTranscription.rawValue
        let revisions = try fetchTranscriptRevisions(sessionID: sessionID, in: context)
            .filter { $0.stageRawValue == liveStageRawValue }
            .sorted {
                if $0.sequence != $1.sequence {
                    return $0.sequence < $1.sequence
                }
                return $0.id.uuidString < $1.id.uuidString
            }
        guard !revisions.isEmpty else {
            return []
        }

        let persistedProviderSnapshotID = revisions[0].providerSnapshotID
        guard let persistedProviderSnapshotID else {
            throw CaptureSessionStoreError.liveTranscriptConflict(
                sessionID: sessionID,
                sequence: revisions[0].sequence
            )
        }
        guard providerSnapshotID == nil || providerSnapshotID == persistedProviderSnapshotID else {
            throw CaptureSessionStoreError.liveTranscriptConflict(
                sessionID: sessionID,
                sequence: revisions[0].sequence
            )
        }
        let snapshots = try fetchLiveTranscriptProviderSnapshots(
            sessionID: sessionID,
            in: context
        )
        let persistedSnapshot = snapshots.first { $0.id == persistedProviderSnapshotID }
        guard
            let persistedSnapshot,
            !snapshots.contains(where: { snapshot in
                snapshot.id != persistedProviderSnapshotID && snapshot.attempt == persistedSnapshot.attempt
            }),
            let assignment = try? persistedSnapshot.restoreAssignment(),
            assignment.providerKind == .streamingSpeech,
            assignment.modelIdentifier != nil
        else {
            throw CaptureSessionStoreError.liveTranscriptConflict(
                sessionID: sessionID,
                sequence: revisions[0].sequence
            )
        }

        var checkpoints: [VoiceNoteLiveTranscriptCheckpoint] = []
        for revision in revisions {
            guard
                revision.sourceID == sourceID,
                revision.parentRevisionID == checkpoints.last?.revisionID,
                revision.statusRawValue == "completed",
                revision.startOffset == 0,
                revision.duration == 0,
                revision.segmentsJSON == nil,
                revision.languageCode == nil,
                revision.providerSnapshotID == persistedProviderSnapshotID,
                !revision.text.isEmpty
            else {
                throw CaptureSessionStoreError.liveTranscriptConflict(
                    sessionID: sessionID,
                    sequence: revision.sequence
                )
            }
            if let previous = checkpoints.last {
                guard
                    revision.sequence == previous.sequence + 1,
                    revision.text != previous.committedText,
                    revision.text.hasPrefix(previous.committedText)
                else {
                    throw CaptureSessionStoreError.liveTranscriptConflict(
                        sessionID: sessionID,
                        sequence: revision.sequence
                    )
                }
            } else if revision.sequence != 0 {
                throw CaptureSessionStoreError.liveTranscriptConflict(
                    sessionID: sessionID,
                    sequence: revision.sequence
                )
            }
            checkpoints.append(try liveTranscriptCheckpoint(from: revision))
        }
        return checkpoints
    }

    private func liveTranscriptCheckpoint(
        from revision: CaptureTranscriptRevisionModel
    ) throws -> VoiceNoteLiveTranscriptCheckpoint {
        guard let providerSnapshotID = revision.providerSnapshotID else {
            throw CaptureSessionStoreError.liveTranscriptConflict(
                sessionID: revision.sessionID,
                sequence: revision.sequence
            )
        }
        return VoiceNoteLiveTranscriptCheckpoint(
            revisionID: revision.id,
            sequence: revision.sequence,
            parentRevisionID: revision.parentRevisionID,
            committedText: revision.text,
            providerSnapshotID: providerSnapshotID,
            createdAt: revision.createdAt
        )
    }


    private func fetchOwnedNoteCapture(
        for handle: NoteCaptureHandle,
        in context: ModelContext
    ) throws -> OwnedNoteCapture {
        let session = try fetchSession(id: handle.sessionID, in: context)
        guard
            let mode = CaptureSessionMode(rawValue: session.modeRawValue),
            mode.isNoteCapture
        else {
            throw CaptureSessionStoreError.sessionModeMismatch(
                sessionID: handle.sessionID,
                expected: .note,
                actualRawValue: session.modeRawValue
            )
        }
        var sources = [
            try fetchOwnedSource(
                id: handle.microphoneSourceID,
                sessionID: handle.sessionID,
                kind: .microphone,
                in: context
            )
        ]
        if let systemAudioSourceID = handle.systemAudioSourceID {
            sources.append(
                try fetchOwnedSource(
                    id: systemAudioSourceID,
                    sessionID: handle.sessionID,
                    kind: .systemAudio,
                    in: context
                )
            )
        }
        return OwnedNoteCapture(session: session, sources: sources)
    }

    private func fetchOwnedSource(
        id: UUID,
        sessionID: UUID,
        kind: CaptureSourceKind,
        in context: ModelContext
    ) throws -> CaptureSourceModel {
        let source = try fetchSource(id: id, in: context)
        guard source.sessionID == sessionID else {
            throw CaptureSessionStoreError.sourceSessionMismatch(
                sourceID: source.id,
                expectedSessionID: sessionID,
                actualSessionID: source.sessionID
            )
        }
        guard source.kindRawValue == kind.rawValue else {
            throw CaptureSessionStoreError.sourceKindMismatch(
                sourceID: source.id,
                expected: kind,
                actualRawValue: source.kindRawValue
            )
        }
        return source
    }

    private func existingVoiceNoteTranscriptRevisions(
        _ revisions: [CaptureTranscriptRevisionModel],
        for handle: NoteCaptureHandle,
        latestLiveCheckpoint: VoiceNoteLiveTranscriptCheckpoint?,
        rawText: String,
        finalText: String,
        duration: TimeInterval,
        languageCode: String?
    ) throws -> VoiceNoteTranscriptRevisions {
        guard revisions.count == 2 else {
            throw CaptureSessionStoreError.voiceNoteFinalTranscriptConflict(
                sessionID: handle.sessionID
            )
        }

        let orderedRevisions = revisions.sorted {
            if $0.sequence != $1.sequence {
                return $0.sequence < $1.sequence
            }
            return $0.id.uuidString < $1.id.uuidString
        }
        let rawRevision = orderedRevisions[0]
        let finalRevision = orderedRevisions[1]
        let expectedRawSequence = latestLiveCheckpoint.map { $0.sequence + 1 } ?? 0
        let finalStageRawValue = CapturePipelineStage.finalTranscription.rawValue

        guard
            rawRevision.sessionID == handle.sessionID,
            rawRevision.sourceID == handle.microphoneSourceID,
            rawRevision.sequence == expectedRawSequence,
            rawRevision.parentRevisionID == latestLiveCheckpoint?.revisionID,
            rawRevision.stageRawValue == finalStageRawValue,
            rawRevision.statusRawValue == "completed",
            rawRevision.startOffset == 0,
            rawRevision.duration == duration,
            rawRevision.text == rawText,
            rawRevision.segmentsJSON == nil,
            rawRevision.languageCode == languageCode,
            rawRevision.providerSnapshotID == nil,
            finalRevision.sessionID == handle.sessionID,
            finalRevision.sourceID == handle.microphoneSourceID,
            finalRevision.sequence == expectedRawSequence + 1,
            finalRevision.parentRevisionID == rawRevision.id,
            finalRevision.stageRawValue == finalStageRawValue,
            finalRevision.statusRawValue == "completed",
            finalRevision.startOffset == 0,
            finalRevision.duration == duration,
            finalRevision.text == finalText,
            finalRevision.segmentsJSON == nil,
            finalRevision.languageCode == languageCode,
            finalRevision.providerSnapshotID == nil
        else {
            throw CaptureSessionStoreError.voiceNoteFinalTranscriptConflict(
                sessionID: handle.sessionID
            )
        }

        return VoiceNoteTranscriptRevisions(
            rawRevisionID: rawRevision.id,
            finalRevisionID: finalRevision.id
        )
    }

    private func validateFinalTranscriptRevision(
        _ revision: CaptureTranscriptRevisionModel,
        for handle: NoteCaptureHandle,
        in context: ModelContext
    ) throws {
        guard revision.sessionID == handle.sessionID else {
            throw CaptureSessionStoreError.transcriptRevisionSessionMismatch(
                revisionID: revision.id,
                expectedSessionID: handle.sessionID,
                actualSessionID: revision.sessionID
            )
        }
        guard revision.sourceID == handle.microphoneSourceID else {
            throw CaptureSessionStoreError.transcriptRevisionSourceMismatch(
                revisionID: revision.id,
                expectedSourceID: handle.microphoneSourceID,
                actualSourceID: revision.sourceID
            )
        }
        guard
            revision.stageRawValue == CapturePipelineStage.finalTranscription.rawValue,
            revision.statusRawValue == "completed",
            let parentRevisionID = revision.parentRevisionID
        else {
            throw CaptureSessionStoreError.invalidFinalTranscriptRevision(revision.id)
        }

        let parent = try fetchTranscriptRevision(id: parentRevisionID, in: context)
        let latestLiveCheckpoint = try latestValidLiveTranscriptCheckpoint(
            sessionID: handle.sessionID,
            sourceID: handle.microphoneSourceID,
            in: context
        )
        let expectedRawParentSequence = latestLiveCheckpoint.map { $0.sequence + 1 } ?? 0

        guard
            parent.sessionID == handle.sessionID,
            parent.sourceID == handle.microphoneSourceID,
            parent.parentRevisionID == latestLiveCheckpoint?.revisionID,
            parent.stageRawValue == CapturePipelineStage.finalTranscription.rawValue,
            parent.statusRawValue == "completed",
            parent.sequence == expectedRawParentSequence,
            revision.sequence == parent.sequence + 1
        else {
            throw CaptureSessionStoreError.invalidFinalTranscriptRevision(revision.id)
        }
    }

    private func fetchOwnedSession(
        for handle: NoteCaptureHandle,
        in context: ModelContext
    ) throws -> CaptureSessionModel {
        let session = try fetchSession(id: handle.sessionID, in: context)
        // Streaming voice-note artifacts belong to legacy `voiceNote` rows and to
        // the unified `note` mode. They never belong to a `meeting` row.
        guard
            session.modeRawValue == CaptureSessionMode.voiceNote.rawValue ||
                session.modeRawValue == CaptureSessionMode.note.rawValue
        else {
            throw CaptureSessionStoreError.sessionModeMismatch(
                sessionID: handle.sessionID,
                expected: .voiceNote,
                actualRawValue: session.modeRawValue
            )
        }
        let source = try fetchSource(id: handle.microphoneSourceID, in: context)
        guard source.sessionID == handle.sessionID else {
            throw CaptureSessionStoreError.sourceSessionMismatch(
                sourceID: source.id,
                expectedSessionID: handle.sessionID,
                actualSessionID: source.sessionID
            )
        }
        guard source.kindRawValue == CaptureSourceKind.microphone.rawValue else {
            throw CaptureSessionStoreError.sourceIsNotMicrophone(source.id)
        }
        return session
    }

    private func fetchMeetingChunks(
        sessionID: UUID,
        in context: ModelContext
    ) throws -> [CaptureChunkModel] {
        let descriptor = FetchDescriptor<CaptureChunkModel>(
            predicate: #Predicate<CaptureChunkModel> { $0.sessionID == sessionID }
        )
        do {
            return try context.fetch(descriptor)
        } catch {
            throw CaptureSessionStoreError.fetchFailed(error.localizedDescription)
        }
    }
    private func fetchCaptureIntentModel(
        sessionID: UUID,
        in context: ModelContext
    ) throws -> CaptureIntentModel? {
        var descriptor = FetchDescriptor<CaptureIntentModel>(
            predicate: #Predicate<CaptureIntentModel> { $0.sessionID == sessionID }
        )
        descriptor.fetchLimit = 1
        do {
            return try context.fetch(descriptor).first
        } catch {
            throw CaptureSessionStoreError.fetchFailed(error.localizedDescription)
        }
    }

    /// Every recorded intent, keyed by session, for one pass over the candidates.
    private func fetchCaptureIntentsBySessionID(
        in context: ModelContext
    ) throws -> [UUID: CaptureIntentModel] {
        do {
            return try context.fetch(FetchDescriptor<CaptureIntentModel>())
                .reduce(into: [:]) { result, model in
                    result[model.sessionID] = model
                }
        } catch {
            throw CaptureSessionStoreError.fetchFailed(error.localizedDescription)
        }
    }

    func fetchSources(
        sessionID: UUID,
        in context: ModelContext
    ) throws -> [CaptureSourceModel] {
        let descriptor = FetchDescriptor<CaptureSourceModel>(
            predicate: #Predicate<CaptureSourceModel> { $0.sessionID == sessionID }
        )
        do {
            return try context.fetch(descriptor)
        } catch {
            throw CaptureSessionStoreError.fetchFailed(error.localizedDescription)
        }
    }

    func fetchTranscriptRevisions(
        sessionID: UUID,
        in context: ModelContext
    ) throws -> [CaptureTranscriptRevisionModel] {
        let descriptor = FetchDescriptor<CaptureTranscriptRevisionModel>(
            predicate: #Predicate<CaptureTranscriptRevisionModel> { $0.sessionID == sessionID }
        )
        do {
            return try context.fetch(descriptor)
        } catch {
            throw CaptureSessionStoreError.fetchFailed(error.localizedDescription)
        }
    }


    private func fetchMeetingFailures(
        sessionID: UUID,
        in context: ModelContext
    ) throws -> [CaptureFailureRecordModel] {
        let descriptor = FetchDescriptor<CaptureFailureRecordModel>(
            predicate: #Predicate<CaptureFailureRecordModel> { $0.sessionID == sessionID }
        )
        do {
            return try context.fetch(descriptor)
        } catch {
            throw CaptureSessionStoreError.fetchFailed(error.localizedDescription)
        }
    }

    func fetchSession(id: UUID, in context: ModelContext) throws -> CaptureSessionModel {
        var descriptor = FetchDescriptor<CaptureSessionModel>(
            predicate: #Predicate<CaptureSessionModel> { $0.id == id }
        )
        descriptor.fetchLimit = 1
        do {
            guard let session = try context.fetch(descriptor).first else {
                throw CaptureSessionStoreError.sessionNotFound(id)
            }
            return session
        } catch let error as CaptureSessionStoreError {
            throw error
        } catch {
            throw CaptureSessionStoreError.fetchFailed(error.localizedDescription)
        }
    }

    private func fetchSource(id: UUID, in context: ModelContext) throws -> CaptureSourceModel {
        var descriptor = FetchDescriptor<CaptureSourceModel>(
            predicate: #Predicate<CaptureSourceModel> { $0.id == id }
        )
        descriptor.fetchLimit = 1
        do {
            guard let source = try context.fetch(descriptor).first else {
                throw CaptureSessionStoreError.sourceNotFound(id)
            }
            return source
        } catch let error as CaptureSessionStoreError {
            throw error
        } catch {
            throw CaptureSessionStoreError.fetchFailed(error.localizedDescription)
        }
    }

    private func fetchTranscriptionRecord(
        id: UUID,
        in context: ModelContext
    ) throws -> TranscriptionRecord? {
        var descriptor = FetchDescriptor<TranscriptionRecord>(
            predicate: #Predicate<TranscriptionRecord> { $0.id == id }
        )
        descriptor.fetchLimit = 1
        do {
            return try context.fetch(descriptor).first
        } catch {
            throw CaptureSessionStoreError.fetchFailed(error.localizedDescription)
        }
    }

    private func fetchTranscriptRevision(
        id: UUID,
        in context: ModelContext
    ) throws -> CaptureTranscriptRevisionModel {
        var descriptor = FetchDescriptor<CaptureTranscriptRevisionModel>(
            predicate: #Predicate<CaptureTranscriptRevisionModel> { $0.id == id }
        )
        descriptor.fetchLimit = 1
        do {
            guard let revision = try context.fetch(descriptor).first else {
                throw CaptureSessionStoreError.transcriptRevisionNotFound(id)
            }
            return revision
        } catch let error as CaptureSessionStoreError {
            throw error
        } catch {
            throw CaptureSessionStoreError.fetchFailed(error.localizedDescription)
        }
    }

    func fetchNote(id: UUID, in context: ModelContext) throws -> Note? {
        var descriptor = FetchDescriptor<Note>(
            predicate: #Predicate<Note> { $0.id == id }
        )
        descriptor.fetchLimit = 1
        do {
            return try context.fetch(descriptor).first
        } catch {
            throw CaptureSessionStoreError.fetchFailed(error.localizedDescription)
        }
    }

    private func nextTranscriptSequence(for sessionID: UUID, in context: ModelContext) throws -> Int {
        let descriptor = FetchDescriptor<CaptureTranscriptRevisionModel>(
            predicate: #Predicate<CaptureTranscriptRevisionModel> { $0.sessionID == sessionID }
        )
        do {
            let revisions = try context.fetch(descriptor)
            return (revisions.map(\.sequence).max() ?? -1) + 1
        } catch {
            throw CaptureSessionStoreError.fetchFailed(error.localizedDescription)
        }
    }

    func save(_ context: ModelContext) throws {
        do {
            try context.save()
        } catch {
            throw CaptureSessionStoreError.saveFailed(error.localizedDescription)
        }
    }
}
