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

/// Persists the capture-domain artifacts for the voice-note lifecycle.
///
/// The store uses only stable IDs between SwiftData models. It deliberately does
/// not own history-record or note creation; callers commit those through their
/// dedicated stores before linking their IDs here.
@MainActor
public final class CaptureSessionStore {
    private let modelContainer: ModelContainer

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
            stateRawValue: CaptureSessionState.capturing.rawValue,
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
