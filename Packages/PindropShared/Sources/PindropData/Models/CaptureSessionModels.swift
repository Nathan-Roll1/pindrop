//
//  CaptureSessionModels.swift
//  PindropData
//
//  Created on 2026-08-20.
//

import Foundation
import PindropCore
import SwiftData

public enum CaptureSessionProjectionError: Error, Equatable, LocalizedError {
    case invalidModeRawValue(String)
    case invalidStateRawValue(String)
    case invalidRecoveryTargetRawValue(String)
    case invalidNoteRoleRawValue(String)
    case invalidPipelineStageRawValue(String)
    case invalidAssignmentProviderKindRawValue(String)
    case stateChangedAtMismatch(expected: Date, actual: Date)
    case invalidPersistedSession
    case invalidPersistedAssignment
    case sessionIDMismatch(expected: UUID, actual: UUID)
    case modeMismatch(expected: CaptureSessionMode, actual: CaptureSessionMode)
    case revisionRegression(current: Int, attempted: Int)

    public var errorDescription: String? {
        switch self {
        case .invalidModeRawValue(let rawValue):
            "Capture session mode '\(rawValue)' is not recognized."
        case .invalidStateRawValue(let rawValue):
            "Capture session state '\(rawValue)' is not recognized."
        case .invalidRecoveryTargetRawValue(let rawValue):
            "Capture session recovery target '\(rawValue)' is not recognized."
        case .invalidNoteRoleRawValue(let rawValue):
            "Capture note reference role '\(rawValue)' is not recognized."
        case .invalidPipelineStageRawValue(let rawValue):
            "Capture pipeline stage '\(rawValue)' is not recognized."
        case .invalidAssignmentProviderKindRawValue(let rawValue):
            "Capture assignment provider kind '\(rawValue)' is not recognized."
        case .stateChangedAtMismatch:
            "Capture session state change time must match its update time."
        case .invalidPersistedSession:
            "Capture session persistence does not describe a valid session."
        case .invalidPersistedAssignment:
            "Capture assignment persistence does not describe a valid assignment."
        case .sessionIDMismatch:
            "Capture session projection cannot be updated from a different session."
        case .modeMismatch:
            "Capture session projection cannot change capture mode."
        case .revisionRegression:
            "Capture session projection cannot move to an earlier revision."
        }
    }
}

@Model
public final class CaptureSessionModel {
    @Attribute(.unique) public private(set) var id: UUID
    public private(set) var modeRawValue: String
    public private(set) var stateRawValue: String
    public private(set) var stateRevision: Int
    public private(set) var stateChangedAt: Date
    public private(set) var createdAt: Date
    public private(set) var updatedAt: Date
    public private(set) var startedAt: Date?
    public private(set) var endedAt: Date?
    public var lastActivityAt: Date?
    public private(set) var recoveryTargetRawValue: String?
    public private(set) var latestFailureID: UUID?
    public var transcriptionRecordID: UUID?

    public init(
        session: CaptureSession,
        lastActivityAt: Date? = nil,
        transcriptionRecordID: UUID? = nil
    ) {
        self.id = session.id
        self.modeRawValue = session.mode.rawValue
        self.stateRawValue = session.state.rawValue
        self.stateRevision = session.revision
        self.stateChangedAt = session.updatedAt
        self.createdAt = session.createdAt
        self.updatedAt = session.updatedAt
        self.startedAt = session.startedAt
        self.endedAt = session.endedAt
        self.lastActivityAt = lastActivityAt
        self.recoveryTargetRawValue = session.recoveryTarget?.rawValue
        self.latestFailureID = session.latestFailureID
        self.transcriptionRecordID = transcriptionRecordID
    }

    public func restoreSession() throws -> CaptureSession {
        guard let mode = CaptureSessionMode(rawValue: modeRawValue) else {
            throw CaptureSessionProjectionError.invalidModeRawValue(modeRawValue)
        }
        guard let state = CaptureSessionState(rawValue: stateRawValue) else {
            throw CaptureSessionProjectionError.invalidStateRawValue(stateRawValue)
        }
        let recoveryTarget: CaptureRecoveryTarget?
        if let recoveryTargetRawValue {
            guard let value = CaptureRecoveryTarget(rawValue: recoveryTargetRawValue) else {
                throw CaptureSessionProjectionError.invalidRecoveryTargetRawValue(recoveryTargetRawValue)
            }
            recoveryTarget = value
        } else {
            recoveryTarget = nil
        }
        guard stateChangedAt == updatedAt else {
            throw CaptureSessionProjectionError.stateChangedAtMismatch(
                expected: updatedAt,
                actual: stateChangedAt
            )
        }

        do {
            return try CaptureSession(
                restoring: id,
                mode: mode,
                state: state,
                revision: stateRevision,
                createdAt: createdAt,
                updatedAt: updatedAt,
                startedAt: startedAt,
                endedAt: endedAt,
                recoveryTarget: recoveryTarget,
                latestFailureID: latestFailureID
            )
        } catch {
            throw CaptureSessionProjectionError.invalidPersistedSession
        }
    }

    public func update(from session: CaptureSession) throws {
        guard id == session.id else {
            throw CaptureSessionProjectionError.sessionIDMismatch(
                expected: id,
                actual: session.id
            )
        }
        guard let mode = CaptureSessionMode(rawValue: modeRawValue) else {
            throw CaptureSessionProjectionError.invalidModeRawValue(modeRawValue)
        }
        guard mode == session.mode else {
            throw CaptureSessionProjectionError.modeMismatch(
                expected: mode,
                actual: session.mode
            )
        }
        guard session.revision >= stateRevision else {
            throw CaptureSessionProjectionError.revisionRegression(
                current: stateRevision,
                attempted: session.revision
            )
        }

        stateRawValue = session.state.rawValue
        stateRevision = session.revision
        stateChangedAt = session.updatedAt
        createdAt = session.createdAt
        updatedAt = session.updatedAt
        startedAt = session.startedAt
        endedAt = session.endedAt
        recoveryTargetRawValue = session.recoveryTarget?.rawValue
        latestFailureID = session.latestFailureID
    }

    init(
        persistedRawID id: UUID,
        modeRawValue: String,
        stateRawValue: String,
        stateRevision: Int,
        stateChangedAt: Date,
        createdAt: Date,
        updatedAt: Date,
        startedAt: Date?,
        endedAt: Date?,
        lastActivityAt: Date?,
        recoveryTargetRawValue: String?,
        latestFailureID: UUID?,
        transcriptionRecordID: UUID?
    ) {
        self.id = id
        self.modeRawValue = modeRawValue
        self.stateRawValue = stateRawValue
        self.stateRevision = stateRevision
        self.stateChangedAt = stateChangedAt
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.lastActivityAt = lastActivityAt
        self.recoveryTargetRawValue = recoveryTargetRawValue
        self.latestFailureID = latestFailureID
        self.transcriptionRecordID = transcriptionRecordID
    }
}

@Model
public final class CaptureSourceModel {
    @Attribute(.unique) public var id: UUID
    public var sessionID: UUID
    public var kindRawValue: String
    public var sequence: Int
    public var stateRawValue: String
    public var displayName: String?
    public var sampleRate: Double?
    public var channelCount: Int?
    public var codecRawValue: String
    public var startedAt: Date?
    public var endedAt: Date?
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        sessionID: UUID,
        kind: CaptureSourceKind,
        sequence: Int,
        stateRawValue: String = "created",
        displayName: String? = nil,
        sampleRate: Double? = nil,
        channelCount: Int? = nil,
        codecRawValue: String = "unknown",
        startedAt: Date? = nil,
        endedAt: Date? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.sessionID = sessionID
        self.kindRawValue = kind.rawValue
        self.sequence = sequence
        self.stateRawValue = stateRawValue
        self.displayName = displayName
        self.sampleRate = sampleRate
        self.channelCount = channelCount
        self.codecRawValue = codecRawValue
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

@Model
public final class CaptureChunkModel {
    @Attribute(.unique) public var id: UUID
    public var sessionID: UUID
    public var sourceID: UUID
    public var sequence: Int
    public var startOffset: TimeInterval
    public var duration: TimeInterval
    public var stateRawValue: String
    public var managedMediaPath: String?
    public var byteCount: Int
    public var sha256: String?
    public var createdAt: Date
    public var sealedAt: Date?

    public init(
        id: UUID = UUID(),
        sessionID: UUID,
        sourceID: UUID,
        sequence: Int,
        startOffset: TimeInterval,
        duration: TimeInterval,
        stateRawValue: String = "created",
        managedMediaPath: String? = nil,
        byteCount: Int = 0,
        sha256: String? = nil,
        createdAt: Date = Date(),
        sealedAt: Date? = nil
    ) {
        self.id = id
        self.sessionID = sessionID
        self.sourceID = sourceID
        self.sequence = sequence
        self.startOffset = startOffset
        self.duration = duration
        self.stateRawValue = stateRawValue
        self.managedMediaPath = managedMediaPath
        self.byteCount = byteCount
        self.sha256 = sha256
        self.createdAt = createdAt
        self.sealedAt = sealedAt
    }
}

@Model
public final class CaptureTranscriptRevisionModel {
    @Attribute(.unique) public var id: UUID
    public var sessionID: UUID
    public var sourceID: UUID?
    public var sequence: Int
    public var parentRevisionID: UUID?
    public var stageRawValue: String
    public var statusRawValue: String
    public var startOffset: TimeInterval
    public var duration: TimeInterval
    public var text: String
    public var segmentsJSON: String?
    public var languageCode: String?
    public var providerSnapshotID: UUID?
    public var createdAt: Date

    public init(
        id: UUID = UUID(),
        sessionID: UUID,
        sourceID: UUID? = nil,
        sequence: Int,
        parentRevisionID: UUID? = nil,
        stage: CapturePipelineStage,
        statusRawValue: String = "pending",
        startOffset: TimeInterval,
        duration: TimeInterval,
        text: String,
        segmentsJSON: String? = nil,
        languageCode: String? = nil,
        providerSnapshotID: UUID? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.sessionID = sessionID
        self.sourceID = sourceID
        self.sequence = sequence
        self.parentRevisionID = parentRevisionID
        self.stageRawValue = stage.rawValue
        self.statusRawValue = statusRawValue
        self.startOffset = startOffset
        self.duration = duration
        self.text = text
        self.segmentsJSON = segmentsJSON
        self.languageCode = languageCode
        self.providerSnapshotID = providerSnapshotID
        self.createdAt = createdAt
    }
}

@Model
public final class CaptureStageProviderSnapshotModel {
    @Attribute(.unique) public private(set) var id: UUID
    public private(set) var sessionID: UUID
    public private(set) var stageRawValue: String
    public private(set) var attempt: Int
    public private(set) var providerKindRawValue: String
    public private(set) var providerIdentifier: String
    public private(set) var modelIdentifier: String?
    public private(set) var promptPresetID: UUID?
    public private(set) var selectedAt: Date

    init(
        id: UUID = UUID(),
        sessionID: UUID,
        stage: CapturePipelineStage,
        attempt: Int,
        providerKindRawValue: String = "unknown",
        providerIdentifier: String,
        modelIdentifier: String? = nil,
        promptPresetID: UUID? = nil,
        selectedAt: Date = Date()
    ) {
        self.id = id
        self.sessionID = sessionID
        self.stageRawValue = stage.rawValue
        self.attempt = attempt
        self.providerKindRawValue = providerKindRawValue
        self.providerIdentifier = providerIdentifier
        self.modelIdentifier = modelIdentifier
        self.promptPresetID = promptPresetID
        self.selectedAt = selectedAt
    }

    convenience init(sessionID: UUID, assignment: CaptureStageAssignment) {
        self.init(
            sessionID: sessionID,
            stage: assignment.stage,
            attempt: assignment.attempt,
            providerKindRawValue: assignment.providerKind.rawValue,
            providerIdentifier: assignment.providerIdentifier,
            modelIdentifier: assignment.modelIdentifier,
            selectedAt: assignment.selectedAt
        )
    }

    public func restoreAssignment() throws -> CaptureStageAssignment {
        guard let stage = CapturePipelineStage(rawValue: stageRawValue) else {
            throw CaptureSessionProjectionError.invalidPipelineStageRawValue(stageRawValue)
        }
        guard let providerKind = CaptureAssignmentProviderKind(rawValue: providerKindRawValue) else {
            throw CaptureSessionProjectionError.invalidAssignmentProviderKindRawValue(providerKindRawValue)
        }

        do {
            return try CaptureStageAssignment(
                stage: stage,
                providerKind: providerKind,
                providerIdentifier: providerIdentifier,
                modelIdentifier: modelIdentifier,
                prompt: nil,
                selectedAt: selectedAt,
                attempt: attempt
            )
        } catch {
            throw CaptureSessionProjectionError.invalidPersistedAssignment
        }
    }
}

@Model
public final class CaptureStagePromptSnapshotModel {
    @Attribute(.unique) public private(set) var id: UUID
    public private(set) var providerSnapshotID: UUID
    public private(set) var sessionID: UUID
    public private(set) var presetIdentifier: String?
    public private(set) var resolvedPrompt: String?

    init(
        id: UUID = UUID(),
        providerSnapshotID: UUID,
        sessionID: UUID,
        presetIdentifier: String?,
        resolvedPrompt: String?
    ) {
        self.id = id
        self.providerSnapshotID = providerSnapshotID
        self.sessionID = sessionID
        self.presetIdentifier = presetIdentifier
        self.resolvedPrompt = resolvedPrompt
    }

    convenience init(
        sessionID: UUID,
        providerSnapshotID: UUID,
        prompt: CapturePromptSnapshot
    ) {
        self.init(
            providerSnapshotID: providerSnapshotID,
            sessionID: sessionID,
            presetIdentifier: prompt.presetIdentifier,
            resolvedPrompt: prompt.resolvedPrompt
        )
    }

    public func restorePrompt() -> CapturePromptSnapshot {
        CapturePromptSnapshot(
            presetIdentifier: presetIdentifier,
            resolvedPrompt: resolvedPrompt
        )
    }
}

@Model
public final class CaptureNoteReferenceModel {
    @Attribute(.unique) public var id: UUID
    public var sessionID: UUID
    public var noteID: UUID
    public private(set) var roleRawValue: String
    public var sourceTranscriptRevisionID: UUID?
    public var providerSnapshotID: UUID?
    public var sourceNoteIDsJSON: String?
    public var citationsJSON: String?
    public var createdAt: Date

    public init(
        id: UUID = UUID(),
        sessionID: UUID,
        noteID: UUID,
        role: CaptureNoteRole,
        sourceTranscriptRevisionID: UUID? = nil,
        providerSnapshotID: UUID? = nil,
        sourceNoteIDsJSON: String? = nil,
        citationsJSON: String? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.sessionID = sessionID
        self.noteID = noteID
        self.roleRawValue = role.rawValue
        self.sourceTranscriptRevisionID = sourceTranscriptRevisionID
        self.providerSnapshotID = providerSnapshotID
        self.sourceNoteIDsJSON = sourceNoteIDsJSON
        self.citationsJSON = citationsJSON
        self.createdAt = createdAt
    }

    public func resolvedRole() throws -> CaptureNoteRole {
        guard let role = CaptureNoteRole(rawValue: roleRawValue) else {
            throw CaptureSessionProjectionError.invalidNoteRoleRawValue(roleRawValue)
        }
        return role
    }

    init(
        persistedRawID id: UUID,
        sessionID: UUID,
        noteID: UUID,
        roleRawValue: String,
        sourceTranscriptRevisionID: UUID? = nil,
        providerSnapshotID: UUID? = nil,
        sourceNoteIDsJSON: String? = nil,
        citationsJSON: String? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.sessionID = sessionID
        self.noteID = noteID
        self.roleRawValue = roleRawValue
        self.sourceTranscriptRevisionID = sourceTranscriptRevisionID
        self.providerSnapshotID = providerSnapshotID
        self.sourceNoteIDsJSON = sourceNoteIDsJSON
        self.citationsJSON = citationsJSON
        self.createdAt = createdAt
    }
}

@Model
public final class CaptureFailureRecordModel {
    @Attribute(.unique) public var id: UUID
    public var sessionID: UUID
    public var sourceID: UUID?
    public var chunkID: UUID?
    public var transcriptRevisionID: UUID?
    public var providerSnapshotID: UUID?
    public var stageRawValue: String?
    public var attempt: Int?
    public var errorDomain: String
    public var errorCode: String?
    public var message: String
    public var isRetryable: Bool
    public var detailsJSON: String?
    public var occurredAt: Date
    public var recoveredAt: Date?
    public var recoveryDispositionRawValue: String

    public init(
        id: UUID = UUID(),
        sessionID: UUID,
        sourceID: UUID? = nil,
        chunkID: UUID? = nil,
        transcriptRevisionID: UUID? = nil,
        providerSnapshotID: UUID? = nil,
        stage: CapturePipelineStage? = nil,
        attempt: Int? = nil,
        errorDomain: String,
        errorCode: String?,
        message: String,
        isRetryable: Bool,
        detailsJSON: String? = nil,
        occurredAt: Date = Date(),
        recoveredAt: Date? = nil,
        recoveryDisposition: CaptureFailureDisposition
    ) {
        self.id = id
        self.sessionID = sessionID
        self.sourceID = sourceID
        self.chunkID = chunkID
        self.transcriptRevisionID = transcriptRevisionID
        self.providerSnapshotID = providerSnapshotID
        self.stageRawValue = stage?.rawValue
        self.attempt = attempt
        self.errorDomain = errorDomain
        self.errorCode = errorCode
        self.message = message
        self.isRetryable = isRetryable
        self.detailsJSON = detailsJSON
        self.occurredAt = occurredAt
        self.recoveredAt = recoveredAt
        self.recoveryDispositionRawValue = recoveryDisposition.rawValue
    }
}
