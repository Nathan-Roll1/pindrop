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
    case transcriptionRecordNotFound(UUID)
    case transcriptRevisionNotFound(UUID)
    case transcriptRevisionSessionMismatch(revisionID: UUID, expectedSessionID: UUID, actualSessionID: UUID)
    case transcriptRevisionSourceMismatch(revisionID: UUID, expectedSourceID: UUID, actualSourceID: UUID?)
    case invalidFinalTranscriptRevision(UUID)
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

    public init(modelContext: ModelContext) {
        modelContainer = modelContext.container
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
        let sources = [
            ownedMeeting.microphoneSource,
            ownedMeeting.systemAudioSource
        ]
        let sourceIDs = Set(sources.map(\.id))
        let chunks = try fetchMeetingChunks(sessionID: handle.sessionID, in: context)
        let failures = try fetchMeetingFailures(sessionID: handle.sessionID, in: context)

        for chunk in chunks where !sourceIDs.contains(chunk.sourceID) {
            throw CaptureSessionStoreError.meetingSourceOutcomeForeign(chunk.sourceID)
        }
        for failure in failures {
            guard let sourceID = failure.sourceID else {
                continue
            }
            guard sourceIDs.contains(sourceID) else {
                throw CaptureSessionStoreError.meetingSourceOutcomeForeign(sourceID)
            }
        }

        var completedSourceCount = 0
        for source in sources {
            let sourceChunks = chunks.filter { $0.sourceID == source.id }
            let sourceFailures = failures.filter { $0.sourceID == source.id }

            switch source.stateRawValue {
            case CaptureSourceState.completed.rawValue:
                let expectedPath = CaptureSourceArtifactPath.relativePath(
                    sessionID: handle.sessionID,
                    sourceID: source.id,
                    chunkSequence: 0
                )
                guard
                    sourceChunks.count == 1,
                    sourceChunks[0].sequence == 0,
                    sourceChunks[0].stateRawValue == CaptureChunkState.sealed.rawValue,
                    sourceChunks[0].managedMediaPath == expectedPath,
                    sourceFailures.isEmpty
                else {
                    throw CaptureSessionStoreError.meetingSourceOutcomeMismatch(source.id)
                }
                completedSourceCount += 1
            case CaptureSourceState.failed.rawValue:
                guard sourceChunks.isEmpty, !sourceFailures.isEmpty else {
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
    }

    private func validateMeetingOutcomes(
        retained: [RetainedMeetingSource],
        failures: [FailedMeetingSource],
        for sources: [CaptureSourceModel]
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
        for source in sources where !outcomeSourceIDs.contains(source.id) {
            throw CaptureSessionStoreError.meetingSourceOutcomeMissing(source.id)
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
