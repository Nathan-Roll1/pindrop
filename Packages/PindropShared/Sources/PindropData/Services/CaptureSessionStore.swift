//
//  CaptureSessionStore.swift
//  PindropData
//
//  Created on 2026-08-20.
//

import Foundation
import PindropCore
import SwiftData

/// Stable identifiers for the artifacts created when a voice-note capture starts.
public struct VoiceNoteCaptureHandle: Sendable, Equatable {
    public let sessionID: UUID
    public let microphoneSourceID: UUID

    public init(sessionID: UUID, microphoneSourceID: UUID) {
        self.sessionID = sessionID
        self.microphoneSourceID = microphoneSourceID
    }
}

/// Stable identifiers for the two sources created when a meeting capture starts.
public struct MeetingCaptureHandle: Sendable, Equatable {
    public let sessionID: UUID
    public let microphoneSourceID: UUID
    public let systemAudioSourceID: UUID

    public init(
        sessionID: UUID,
        microphoneSourceID: UUID,
        systemAudioSourceID: UUID
    ) {
        self.sessionID = sessionID
        self.microphoneSourceID = microphoneSourceID
        self.systemAudioSourceID = systemAudioSourceID
    }
}

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
public struct MeetingTranscriptionCheckpoint: Sendable, Equatable {
    public let sequence: Int
    public let startOffset: TimeInterval
    public let duration: TimeInterval
    public let text: String
    public let segmentsJSON: String?
    public let languageCode: String?

    public init(
        sequence: Int,
        startOffset: TimeInterval,
        duration: TimeInterval,
        text: String,
        segmentsJSON: String?,
        languageCode: String?
    ) {
        self.sequence = sequence
        self.startOffset = startOffset
        self.duration = duration
        self.text = text
        self.segmentsJSON = segmentsJSON
        self.languageCode = languageCode
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

/// An immutable meeting-recovery candidate suitable for crossing concurrency domains.
public struct MeetingRecoverySnapshot: Sendable, Equatable {
    public let handle: MeetingCaptureHandle
    public let state: CaptureSessionState
    public let recoveryTarget: CaptureRecoveryTarget?
    public let sourceChunks: [MeetingChunkCheckpoint]
    public let failedSequences: Set<Int>
    public let completedASRCheckpoints: [MeetingTranscriptionCheckpoint]
    public var completedASRSequences: Set<Int> {
        Set(completedASRCheckpoints.map(\.sequence))
    }
    public let completedDiarizationSequences: Set<Int>
    public let reservedTranscriptionRecordID: UUID?

    public init(
        handle: MeetingCaptureHandle,
        state: CaptureSessionState,
        recoveryTarget: CaptureRecoveryTarget?,
        sourceChunks: [MeetingChunkCheckpoint],
        failedSequences: Set<Int> = [],
        completedASRCheckpoints: [MeetingTranscriptionCheckpoint],
        completedDiarizationSequences: Set<Int>,
        reservedTranscriptionRecordID: UUID?
    ) {
        self.handle = handle
        self.state = state
        self.recoveryTarget = recoveryTarget
        self.sourceChunks = sourceChunks
        self.failedSequences = failedSequences
        self.completedASRCheckpoints = completedASRCheckpoints
        self.completedDiarizationSequences = completedDiarizationSequences
        self.reservedTranscriptionRecordID = reservedTranscriptionRecordID
    }
}

/// A deterministic, resumable meeting-finalization work plan.
public struct MeetingFinalizationPlan: Sendable, Equatable {
    public let handle: MeetingCaptureHandle
    public let sourceChunks: [MeetingChunkCheckpoint]
    public let failedSequences: Set<Int>
    public let completedASRCheckpoints: [MeetingTranscriptionCheckpoint]
    public var completedASRSequences: Set<Int> {
        Set(completedASRCheckpoints.map(\.sequence))
    }
    public let completedDiarizationSequences: Set<Int>
    public let reservedTranscriptionRecordID: UUID?

    public init(
        handle: MeetingCaptureHandle,
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
    case meetingCaptureHasNoFinalTranscript(UUID)
    case transcriptionRecordReservationMismatch(expected: UUID, actual: UUID)
    case transcriptionRecordNotFound(UUID)
    case transcriptRevisionNotFound(UUID)
    case transcriptRevisionSessionMismatch(revisionID: UUID, expectedSessionID: UUID, actualSessionID: UUID)
    case transcriptRevisionSourceMismatch(revisionID: UUID, expectedSourceID: UUID, actualSourceID: UUID?)
    case invalidFinalTranscriptRevision(UUID)
    case invalidAssignmentAttempt(Int)
    case assignmentSessionNotFound(UUID)
    case assignmentKeyMismatch
    case duplicateAssignments(sessionID: UUID, stage: CapturePipelineStage, attempt: Int)
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
        case .invalidAssignmentAttempt(let attempt):
            return "Capture assignment attempt \(attempt) must be at least one."
        case .assignmentSessionNotFound(let id):
            return "Capture session \(id.uuidString) was not found for assignment persistence."
        case .assignmentKeyMismatch:
            return "Capture assignment does not match its requested stage and attempt."
        case .duplicateAssignments(let sessionID, let stage, let attempt):
            return "Capture session \(sessionID.uuidString) has duplicate \(stage.rawValue) assignments for attempt \(attempt)."
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
    private let modelContainer: ModelContainer
    private struct OwnedMeeting {
        let session: CaptureSessionModel
        let microphoneSource: CaptureSourceModel
        let systemAudioSource: CaptureSourceModel
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

    @discardableResult
    public func startVoiceNoteCapture(
        startedAt: Date = Date(),
        microphoneDisplayName: String? = nil
    ) throws -> VoiceNoteCaptureHandle {
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

        return VoiceNoteCaptureHandle(
            sessionID: session.id,
            microphoneSourceID: microphoneSource.id
        )
    }
    @discardableResult
    public func startMeetingCapture(
        startedAt: Date = Date(),
        microphoneDisplayName: String? = nil,
        systemAudioDisplayName: String? = nil
    ) throws -> MeetingCaptureHandle {
        var session = try CaptureSession(mode: .meeting, createdAt: startedAt)
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
        context.insert(sessionModel)
        context.insert(microphoneSource)
        context.insert(systemAudioSource)
        try save(context)

        return MeetingCaptureHandle(
            sessionID: session.id,
            microphoneSourceID: microphoneSource.id,
            systemAudioSourceID: systemAudioSource.id
        )
    }

    public func beginMeetingFinalization(
        _ handle: MeetingCaptureHandle,
        at timestamp: Date = Date()
    ) throws {
        let context = ModelContext(modelContainer)
        let ownedMeeting = try fetchOwnedMeeting(for: handle, in: context)
        var session = try ownedMeeting.session.restoreSession()
        try session.beginFinalization(at: timestamp)
        try ownedMeeting.session.update(from: session)
        ownedMeeting.session.lastActivityAt = timestamp
        try save(context)
    }
    public func recordSealedMeetingChunk(
        _ handle: MeetingCaptureHandle,
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
        _ handle: MeetingCaptureHandle,
        checkpoint: MeetingChunkCheckpoint
    ) throws {
        let context = ModelContext(modelContainer)
        let ownedMeeting = try fetchOwnedMeeting(for: handle, in: context)
        try checkpointMeetingChunk(
            checkpoint,
            handle: handle,
            sources: [ownedMeeting.microphoneSource, ownedMeeting.systemAudioSource],
            in: context
        )
        ownedMeeting.session.lastActivityAt = checkpoint.sealedAt
        try save(context)
    }

    /// Records a chunk-scoped failure once, retaining it for recovery diagnostics.
    public func recordMeetingChunkFailure(
        _ handle: MeetingCaptureHandle,
        failure: MeetingChunkFailure
    ) throws {
        let context = ModelContext(modelContainer)
        let ownedMeeting = try fetchOwnedMeeting(for: handle, in: context)
        try checkpointMeetingChunkFailure(
            failure,
            handle: handle,
            sources: [ownedMeeting.microphoneSource, ownedMeeting.systemAudioSource],
            in: context
        )
        ownedMeeting.session.lastActivityAt = failure.occurredAt
        try save(context)
    }

    /// Marks each meeting source terminal after its recorder has stopped.
    public func finishMeetingSources(
        _ handle: MeetingCaptureHandle,
        sourceFailures: [FailedMeetingSource],
        at timestamp: Date = Date()
    ) throws {
        let context = ModelContext(modelContainer)
        let ownedMeeting = try fetchOwnedMeeting(for: handle, in: context)
        guard ownedMeeting.session.stateRawValue == CaptureSessionState.finalizing.rawValue else {
            throw CaptureSessionStoreError.meetingSessionNotFinalizing(
                sessionID: handle.sessionID,
                actualStateRawValue: ownedMeeting.session.stateRawValue
            )
        }
        let sources = [ownedMeeting.microphoneSource, ownedMeeting.systemAudioSource]
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
        ownedMeeting.session.lastActivityAt = timestamp
        try save(context)
    }

    /// Returns only meeting sessions whose work can honestly be resumed.
    public func meetingRecoveryCandidates() throws -> [MeetingRecoverySnapshot] {
        let context = ModelContext(modelContainer)
        let meetingModeRawValue = CaptureSessionMode.meeting.rawValue
        let descriptor = FetchDescriptor<CaptureSessionModel>(
            predicate: #Predicate<CaptureSessionModel> {
                $0.modeRawValue == meetingModeRawValue
            }
        )
        do {
            return try context.fetch(descriptor).compactMap { sessionModel in
                let session = try sessionModel.restoreSession()
                guard [.capturing, .finalizing, .interrupted].contains(session.state) else {
                    return nil
                }
                let sources = try fetchSources(sessionID: session.id, in: context)
                guard
                    let microphone = sources.first(where: { $0.kindRawValue == CaptureSourceKind.microphone.rawValue }),
                    let systemAudio = sources.first(where: { $0.kindRawValue == CaptureSourceKind.systemAudio.rawValue })
                else {
                    return nil
                }
                let handle = MeetingCaptureHandle(
                    sessionID: session.id,
                    microphoneSourceID: microphone.id,
                    systemAudioSourceID: systemAudio.id
                )
                let chunks = try fetchMeetingChunks(sessionID: session.id, in: context)
                let revisions = try fetchTranscriptRevisions(sessionID: session.id, in: context)
                let failures = try fetchMeetingFailures(sessionID: session.id, in: context)
                return makeMeetingRecoverySnapshot(
                    handle: handle,
                    session: session,
                    chunks: chunks,
                    revisions: revisions,
                    failures: failures,
                    reservedTranscriptionRecordID: sessionModel.transcriptionRecordID
                )
            }
        } catch let error as CaptureSessionStoreError {
            throw error
        } catch {
            throw CaptureSessionStoreError.fetchFailed(error.localizedDescription)
        }
    }

    /// Interrupts capturing or finalizing work without converting it into a terminal failure.
    public func interruptMeetingCapture(
        _ handle: MeetingCaptureHandle,
        errorDomain: String,
        errorCode: String? = nil,
        message: String,
        at timestamp: Date = Date()
    ) throws {
        let context = ModelContext(modelContainer)
        let ownedMeeting = try fetchOwnedMeeting(for: handle, in: context)
        var session = try ownedMeeting.session.restoreSession()
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
        try ownedMeeting.session.update(from: session)
        ownedMeeting.session.lastActivityAt = timestamp
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
        _ handle: MeetingCaptureHandle,
        at timestamp: Date = Date()
    ) throws {
        let context = ModelContext(modelContainer)
        let ownedMeeting = try fetchOwnedMeeting(for: handle, in: context)
        var session = try ownedMeeting.session.restoreSession()
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
        try ownedMeeting.session.update(from: session)
        ownedMeeting.session.lastActivityAt = timestamp
        if let latestFailureID = session.latestFailureID {
            try markFailureRecovered(id: latestFailureID, at: timestamp, in: context)
        }
        try save(context)
    }

    /// Reconciles inventory discovered after a crash, before any finalization work resumes.
    public func reconcileMeetingChunks(
        _ handle: MeetingCaptureHandle,
        checkpoints: [MeetingChunkCheckpoint],
        failures: [MeetingChunkFailure],
        at timestamp: Date = Date()
    ) throws {
        let context = ModelContext(modelContainer)
        let ownedMeeting = try fetchOwnedMeeting(for: handle, in: context)
        let sources = [ownedMeeting.microphoneSource, ownedMeeting.systemAudioSource]
        let sortedCheckpoints = checkpoints.sorted {
            ($0.sourceID.uuidString, $0.sequence) < ($1.sourceID.uuidString, $1.sequence)
        }
        for checkpoint in sortedCheckpoints {
            try checkpointMeetingChunk(checkpoint, handle: handle, sources: sources, in: context)
        }
        for failure in failures {
            try checkpointMeetingChunkFailure(failure, handle: handle, sources: sources, in: context)
        }
        ownedMeeting.session.lastActivityAt = timestamp
        try save(context)
    }
    /// Reconciles canonical media inventory after files were renamed but before a checkpoint commit.
    public func reconcileMeetingInventory(
        _ handle: MeetingCaptureHandle,
        sealedChunks: [SealedAudioSourceChunk],
        failures: [MeetingChunkFailure] = [],
        at timestamp: Date = Date()
    ) throws {
        let context = ModelContext(modelContainer)
        let ownedMeeting = try fetchOwnedMeeting(for: handle, in: context)
        let sources = [ownedMeeting.microphoneSource, ownedMeeting.systemAudioSource]
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
        ownedMeeting.session.lastActivityAt = timestamp
        try save(context)
    }


    /// Returns deterministic source chunks and revision skip-gates for finalization.
    public func makeMeetingFinalizationPlan(
        _ handle: MeetingCaptureHandle
    ) throws -> MeetingFinalizationPlan {
        let context = ModelContext(modelContainer)
        let ownedMeeting = try fetchOwnedMeeting(for: handle, in: context)
        let session = try ownedMeeting.session.restoreSession()
        let chunks = try fetchMeetingChunks(sessionID: handle.sessionID, in: context)
        let revisions = try fetchTranscriptRevisions(sessionID: handle.sessionID, in: context)
        let failures = try fetchMeetingFailures(sessionID: handle.sessionID, in: context)
        let snapshot = makeMeetingRecoverySnapshot(
            handle: handle,
            session: session,
            chunks: chunks,
            revisions: revisions,
            failures: failures,
            reservedTranscriptionRecordID: ownedMeeting.session.transcriptionRecordID
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
        _ handle: MeetingCaptureHandle,
        sourceChunkSequence: Int,
        startOffset: TimeInterval,
        duration: TimeInterval,
        text: String,
        segmentsJSON: String? = nil,
        languageCode: String? = nil,
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
            at: timestamp
        )
    }

    /// Checkpoints best-effort diarization separately so final ASR remains recoverable on its own.
    @discardableResult
    public func recordMeetingDiarizationChunk(
        _ handle: MeetingCaptureHandle,
        sourceChunkSequence: Int,
        startOffset: TimeInterval,
        duration: TimeInterval,
        text: String,
        segmentsJSON: String?,
        languageCode: String?,
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
            at: timestamp
        )
    }

    /// Reserves the stable HistoryStore ID before history persistence begins.
    @discardableResult
    public func reserveMeetingTranscriptionRecordID(
        _ handle: MeetingCaptureHandle
    ) throws -> UUID {
        let context = ModelContext(modelContainer)
        let ownedMeeting = try fetchOwnedMeeting(for: handle, in: context)
        if let reservedID = ownedMeeting.session.transcriptionRecordID {
            return reservedID
        }
        let reservedID = UUID()
        ownedMeeting.session.transcriptionRecordID = reservedID
        try save(context)
        return reservedID
    }
    /// Records a retryable HistoryStore failure without leaving finalization.
    public func recordMeetingHistoryFailure(
        _ handle: MeetingCaptureHandle,
        errorDomain: String,
        errorCode: String? = nil,
        message: String,
        at timestamp: Date = Date()
    ) throws {
        let context = ModelContext(modelContainer)
        let ownedMeeting = try fetchOwnedMeeting(for: handle, in: context)
        guard ownedMeeting.session.stateRawValue == CaptureSessionState.finalizing.rawValue else {
            throw CaptureSessionStoreError.meetingSessionNotFinalizing(
                sessionID: handle.sessionID,
                actualStateRawValue: ownedMeeting.session.stateRawValue
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
        ownedMeeting.session.lastActivityAt = timestamp
        try save(context)
    }

    /// Records a finalization failure without assigning session-level or mixed work to a source.
    public func recordMeetingFinalizationFailure(
        _ handle: MeetingCaptureHandle,
        sequence: Int? = nil,
        stage: CapturePipelineStage,
        domain: String,
        code: String? = nil,
        message: String,
        retryable: Bool,
        at timestamp: Date = Date()
    ) throws {
        let context = ModelContext(modelContainer)
        let ownedMeeting = try fetchOwnedMeeting(for: handle, in: context)
        guard ownedMeeting.session.stateRawValue == CaptureSessionState.finalizing.rawValue else {
            throw CaptureSessionStoreError.meetingSessionNotFinalizing(
                sessionID: handle.sessionID,
                actualStateRawValue: ownedMeeting.session.stateRawValue
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
        ownedMeeting.session.lastActivityAt = timestamp
        try save(context)
    }



    public func recordMeetingStop(
        _ handle: MeetingCaptureHandle,
        retained: [RetainedMeetingSource],
        failures: [FailedMeetingSource],
        at timestamp: Date = Date()
    ) throws {
        let context = ModelContext(modelContainer)
        let ownedMeeting = try fetchOwnedMeeting(for: handle, in: context)
        let meetingSession = try ownedMeeting.session.restoreSession()
        guard ownedMeeting.session.stateRawValue == CaptureSessionState.finalizing.rawValue else {
            throw CaptureSessionStoreError.meetingSessionNotFinalizing(
                sessionID: handle.sessionID,
                actualStateRawValue: ownedMeeting.session.stateRawValue
            )
        }

        let sources = [
            ownedMeeting.microphoneSource,
            ownedMeeting.systemAudioSource
        ]
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
            try ownedMeeting.session.update(from: session)
            ownedMeeting.session.lastActivityAt = timestamp
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
            ownedMeeting.session.lastActivityAt = timestamp
        }
        try save(context)
    }

    public func completeMeetingCapture(
        _ handle: MeetingCaptureHandle,
        transcriptionRecordID: UUID,
        at timestamp: Date = Date()
    ) throws {
        let context = ModelContext(modelContainer)
        let ownedMeeting = try fetchOwnedMeeting(for: handle, in: context)
        let meetingSession = try ownedMeeting.session.restoreSession()
        guard ownedMeeting.session.stateRawValue == CaptureSessionState.finalizing.rawValue else {
            throw CaptureSessionStoreError.meetingSessionNotFinalizing(
                sessionID: handle.sessionID,
                actualStateRawValue: ownedMeeting.session.stateRawValue
            )
        }
        if let reservedID = ownedMeeting.session.transcriptionRecordID,
           reservedID != transcriptionRecordID {
            throw CaptureSessionStoreError.transcriptionRecordReservationMismatch(
                expected: reservedID,
                actual: transcriptionRecordID
            )
        }
        try validateMeetingCompletionOutcomes(
            ownedMeeting,
            handle: handle,
            in: context
        )
        guard try fetchTranscriptionRecord(id: transcriptionRecordID, in: context) != nil else {
            throw CaptureSessionStoreError.transcriptionRecordNotFound(transcriptionRecordID)
        }
        var session = meetingSession
        try session.complete(at: timestamp)
        try ownedMeeting.session.update(from: session)
        ownedMeeting.session.transcriptionRecordID = transcriptionRecordID
        ownedMeeting.session.lastActivityAt = timestamp
        try save(context)
    }

    public func cancelMeetingCapture(
        _ handle: MeetingCaptureHandle,
        at timestamp: Date = Date()
    ) throws {
        let context = ModelContext(modelContainer)
        let ownedMeeting = try fetchOwnedMeeting(for: handle, in: context)
        var session = try ownedMeeting.session.restoreSession()
        try session.cancel(at: timestamp)
        try ownedMeeting.session.update(from: session)
        ownedMeeting.session.lastActivityAt = timestamp
        for source in [ownedMeeting.microphoneSource, ownedMeeting.systemAudioSource]
        where source.stateRawValue == CaptureSourceState.capturing.rawValue {
            source.stateRawValue = CaptureSourceState.cancelled.rawValue
            source.endedAt = timestamp
            source.updatedAt = timestamp
        }
        try save(context)
    }

    public func failMeetingCapture(
        _ handle: MeetingCaptureHandle,
        stage: CapturePipelineStage?,
        errorDomain: String,
        errorCode: String?,
        message: String,
        at timestamp: Date = Date()
    ) throws {
        let context = ModelContext(modelContainer)
        let ownedMeeting = try fetchOwnedMeeting(for: handle, in: context)
        let failure = CaptureFailure(
            sessionID: handle.sessionID,
            disposition: .terminal,
            occurredAt: timestamp,
            code: errorCode ?? errorDomain,
            message: message,
            stage: stage
        )
        for source in [ownedMeeting.microphoneSource, ownedMeeting.systemAudioSource]
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
        var session = try ownedMeeting.session.restoreSession()
        try session.fail(with: failure, at: timestamp)
        try ownedMeeting.session.update(from: session)
        ownedMeeting.session.lastActivityAt = timestamp
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
        _ handle: VoiceNoteCaptureHandle,
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

    @discardableResult
    public func saveTranscriptRevisions(
        for handle: VoiceNoteCaptureHandle,
        rawText: String,
        finalText: String,
        duration: TimeInterval,
        languageCode: String?,
        createdAt: Date = Date()
    ) throws -> VoiceNoteTranscriptRevisions {
        let context = ModelContext(modelContainer)
        _ = try fetchOwnedSession(for: handle, in: context)
        let sequence = try nextTranscriptSequence(for: handle.sessionID, in: context)
        let rawRevision = CaptureTranscriptRevisionModel(
            sessionID: handle.sessionID,
            sourceID: handle.microphoneSourceID,
            sequence: sequence,
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

    public func linkTranscriptionRecord(
        _ transcriptionRecordID: UUID,
        to handle: VoiceNoteCaptureHandle,
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
        _ handle: VoiceNoteCaptureHandle,
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
        _ handle: VoiceNoteCaptureHandle,
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
        _ handle: VoiceNoteCaptureHandle,
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
        _ ownedMeeting: OwnedMeeting,
        handle: MeetingCaptureHandle,
        in context: ModelContext
    ) throws {
        let sources = [ownedMeeting.microphoneSource, ownedMeeting.systemAudioSource]
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
        guard revisions.contains(where: {
            $0.stageRawValue == CapturePipelineStage.finalTranscription.rawValue &&
                $0.statusRawValue == "completed" &&
                !$0.text.isEmpty
        }) else {
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
        handle: MeetingCaptureHandle,
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
        handle: MeetingCaptureHandle,
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

    private func checkpointMeetingRevision(
        _ handle: MeetingCaptureHandle,
        sequence: Int,
        stage: CapturePipelineStage,
        startOffset: TimeInterval,
        duration: TimeInterval,
        text: String,
        segmentsJSON: String?,
        languageCode: String?,
        at timestamp: Date
    ) throws -> UUID {
        guard sequence >= 0, startOffset >= 0, duration >= 0 else {
            throw CaptureSessionStoreError.meetingTranscriptionRevisionConflict(sequence: sequence, stage: stage)
        }
        let context = ModelContext(modelContainer)
        _ = try fetchOwnedMeeting(for: handle, in: context)
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
                existing.languageCode == languageCode
            else {
                throw CaptureSessionStoreError.meetingTranscriptionRevisionConflict(
                    sequence: sequence,
                    stage: stage
                )
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
            createdAt: timestamp
        )
        context.insert(revision)
        try save(context)
        return revision.id
    }

    private func makeMeetingRecoverySnapshot(
        handle: MeetingCaptureHandle,
        session: CaptureSession,
        chunks: [CaptureChunkModel],
        revisions: [CaptureTranscriptRevisionModel],
        failures: [CaptureFailureRecordModel],
        reservedTranscriptionRecordID: UUID?
    ) -> MeetingRecoverySnapshot {
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
        return MeetingRecoverySnapshot(
            handle: handle,
            state: session.state,
            recoveryTarget: session.recoveryTarget,
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

    private func finalASRCheckpoint(
        from revision: CaptureTranscriptRevisionModel
    ) -> MeetingTranscriptionCheckpoint? {
        guard
            revision.sourceID == nil,
            revision.stageRawValue == CapturePipelineStage.finalTranscription.rawValue,
            revision.statusRawValue == "completed"
        else {
            return nil
        }
        return MeetingTranscriptionCheckpoint(
            sequence: revision.sequence,
            startOffset: revision.startOffset,
            duration: revision.duration,
            text: revision.text,
            segmentsJSON: revision.segmentsJSON,
            languageCode: revision.languageCode
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
    private func persistedAssignment(
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

    private func fetchAssignmentSession(
        id: UUID,
        in context: ModelContext
    ) throws -> CaptureSessionModel {
        do {
            return try fetchSession(id: id, in: context)
        } catch CaptureSessionStoreError.sessionNotFound {
            throw CaptureSessionStoreError.assignmentSessionNotFound(id)
        }
    }

    private func fetchAssignmentSnapshots(
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

    private func fetchOwnedMeeting(
        for handle: MeetingCaptureHandle,
        in context: ModelContext
    ) throws -> OwnedMeeting {
        let session = try fetchSession(id: handle.sessionID, in: context)
        guard session.modeRawValue == CaptureSessionMode.meeting.rawValue else {
            throw CaptureSessionStoreError.sessionModeMismatch(
                sessionID: handle.sessionID,
                expected: .meeting,
                actualRawValue: session.modeRawValue
            )
        }
        let microphoneSource = try fetchOwnedSource(
            id: handle.microphoneSourceID,
            sessionID: handle.sessionID,
            kind: .microphone,
            in: context
        )
        let systemAudioSource = try fetchOwnedSource(
            id: handle.systemAudioSourceID,
            sessionID: handle.sessionID,
            kind: .systemAudio,
            in: context
        )
        return OwnedMeeting(
            session: session,
            microphoneSource: microphoneSource,
            systemAudioSource: systemAudioSource
        )
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

    private func validateFinalTranscriptRevision(
        _ revision: CaptureTranscriptRevisionModel,
        for handle: VoiceNoteCaptureHandle,
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
        guard
            parent.sessionID == handle.sessionID,
            parent.sourceID == handle.microphoneSourceID,
            parent.parentRevisionID == nil,
            revision.sequence == parent.sequence + 1
        else {
            throw CaptureSessionStoreError.invalidFinalTranscriptRevision(revision.id)
        }
    }

    private func fetchOwnedSession(
        for handle: VoiceNoteCaptureHandle,
        in context: ModelContext
    ) throws -> CaptureSessionModel {
        let session = try fetchSession(id: handle.sessionID, in: context)
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
    private func fetchSources(
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

    private func fetchTranscriptRevisions(
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

    private func fetchSession(id: UUID, in context: ModelContext) throws -> CaptureSessionModel {
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

    private func fetchNote(id: UUID, in context: ModelContext) throws -> Note? {
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

    private func save(_ context: ModelContext) throws {
        do {
            try context.save()
        } catch {
            throw CaptureSessionStoreError.saveFailed(error.localizedDescription)
        }
    }
}
