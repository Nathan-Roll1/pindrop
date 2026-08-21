//
//  CaptureSession.swift
//  PindropCore
//
//  Created on 2026-08-20.
//

import Foundation

public enum CaptureSessionMode: String, Codable, Sendable {
    case dictate
    case voiceNote
    case meeting
}

public enum CaptureSourceKind: String, Codable, Sendable {
    case microphone
    case systemAudio
}

public enum CaptureNoteRole: String, Codable, Sendable {
    case humanAnchor
    case generated
}

public enum CaptureArtifactKind: String, Codable, Sendable {
    case sourceAudio
    case audioChunk
    case transcriptRevision
    case humanNote
    case derivedNote
}

public enum CapturePipelineStage: String, Codable, Sendable {
    case liveTranscription
    case finalTranscription
    case diarization
    case noteGeneration
}

public enum CaptureSessionState: String, Codable, Sendable {
    case created
    case capturing
    case interrupted
    case finalizing
    case completed
    case failed
    case cancelled
}

public enum CaptureRecoveryTarget: String, Codable, Sendable {
    case capturing
    case finalizing
}

public enum CaptureFailureDisposition: String, Codable, Sendable {
    case recoverable
    case terminal
}

public struct CaptureFailure: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public let sessionID: UUID
    public let disposition: CaptureFailureDisposition
    public let occurredAt: Date
    public let code: String
    public let message: String
    public let stage: CapturePipelineStage?
    public let sourceID: UUID?

    public init(
        id: UUID = UUID(),
        sessionID: UUID,
        disposition: CaptureFailureDisposition,
        occurredAt: Date,
        code: String,
        message: String,
        stage: CapturePipelineStage? = nil,
        sourceID: UUID? = nil
    ) {
        self.id = id
        self.sessionID = sessionID
        self.disposition = disposition
        self.occurredAt = occurredAt
        self.code = code
        self.message = message
        self.stage = stage
        self.sourceID = sourceID
    }
}

public enum CaptureSessionError: Error, Codable, Sendable, Equatable, LocalizedError {
    case terminalStateAlreadyReached(CaptureSessionState)
    case illegalTransition(from: CaptureSessionState, to: CaptureSessionState)
    case failureSessionMismatch(expected: UUID, actual: UUID)
    case failureDispositionMismatch(
        expected: CaptureFailureDisposition,
        actual: CaptureFailureDisposition
    )
    case timestampOutOfOrder(previous: Date, attempted: Date)
    case missingRecoveryTarget
    case invalidPersistedState
    case revisionOverflow

    public var errorDescription: String? {
        switch self {
        case .terminalStateAlreadyReached(let state):
            "Capture session has already reached terminal state \(state.rawValue)."
        case .illegalTransition(let from, let to):
            "Capture session cannot transition from \(from.rawValue) to \(to.rawValue)."
        case .failureSessionMismatch:
            "Capture failure belongs to a different session."
        case .failureDispositionMismatch(let expected, let actual):
            "Capture failure disposition \(actual.rawValue) does not match expected \(expected.rawValue)."
        case .timestampOutOfOrder:
            "Capture session timestamps must not move backward."
        case .missingRecoveryTarget:
            "Interrupted capture session is missing its recovery target."
        case .invalidPersistedState:
            "Persisted capture session state is invalid."
        case .revisionOverflow:
            "Capture session revision cannot be incremented further."
        }
    }
}

public struct CaptureSession: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public let mode: CaptureSessionMode
    public private(set) var state: CaptureSessionState
    public private(set) var revision: Int
    public let createdAt: Date
    public private(set) var updatedAt: Date
    public private(set) var startedAt: Date?
    public private(set) var endedAt: Date?
    public private(set) var recoveryTarget: CaptureRecoveryTarget?
    public private(set) var latestFailureID: UUID?

    public init(
        id: UUID = UUID(),
        mode: CaptureSessionMode,
        createdAt: Date = Date(),
        revision: Int = 0
    ) throws {
        try self.init(
            restoring: id,
            mode: mode,
            state: .created,
            revision: revision,
            createdAt: createdAt,
            updatedAt: createdAt,
            startedAt: nil,
            endedAt: nil,
            recoveryTarget: nil,
            latestFailureID: nil
        )
    }

    public init(
        restoring id: UUID,
        mode: CaptureSessionMode,
        state: CaptureSessionState,
        revision: Int,
        createdAt: Date,
        updatedAt: Date,
        startedAt: Date?,
        endedAt: Date?,
        recoveryTarget: CaptureRecoveryTarget?,
        latestFailureID: UUID?
    ) throws {
        guard Self.isValid(
            state: state,
            revision: revision,
            createdAt: createdAt,
            updatedAt: updatedAt,
            startedAt: startedAt,
            endedAt: endedAt,
            recoveryTarget: recoveryTarget,
            latestFailureID: latestFailureID
        ) else {
            throw CaptureSessionError.invalidPersistedState
        }

        self.id = id
        self.mode = mode
        self.state = state
        self.revision = revision
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.recoveryTarget = recoveryTarget
        self.latestFailureID = latestFailureID
    }

    public mutating func start(at timestamp: Date = Date()) throws {
        try transition(to: .capturing, at: timestamp)
        startedAt = timestamp
    }

    public mutating func beginFinalization(at timestamp: Date = Date()) throws {
        try transition(to: .finalizing, at: timestamp)
    }

    public mutating func interrupt(
        with failure: CaptureFailure,
        at timestamp: Date = Date()
    ) throws {
        guard state == .capturing || state == .finalizing else {
            try rejectTransition(to: .interrupted)
            return
        }
        try validate(failure: failure, expectedDisposition: .recoverable)
        try validateTimestamp(timestamp)
        try incrementRevision()

        recoveryTarget = state == .capturing ? .capturing : .finalizing
        state = .interrupted
        updatedAt = timestamp
        latestFailureID = failure.id
    }

    public mutating func recover(at timestamp: Date = Date()) throws {
        guard state == .interrupted else {
            try rejectTransition(to: .capturing)
            return
        }
        guard let recoveryTarget else {
            throw CaptureSessionError.missingRecoveryTarget
        }
        try validateTimestamp(timestamp)
        try incrementRevision()

        state = recoveryTarget.sessionState
        self.recoveryTarget = nil
        updatedAt = timestamp
    }

    public mutating func complete(at timestamp: Date = Date()) throws {
        try transition(to: .completed, at: timestamp)
        endedAt = timestamp
    }

    public mutating func fail(
        with failure: CaptureFailure,
        at timestamp: Date = Date()
    ) throws {
        if state.isTerminal {
            throw CaptureSessionError.terminalStateAlreadyReached(state)
        }
        try validate(failure: failure, expectedDisposition: .terminal)
        try transition(to: .failed, at: timestamp)
        endedAt = timestamp
        latestFailureID = failure.id
    }

    public mutating func cancel(at timestamp: Date = Date()) throws {
        try transition(to: .cancelled, at: timestamp)
        endedAt = timestamp
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case mode
        case state
        case revision
        case createdAt
        case updatedAt
        case startedAt
        case endedAt
        case recoveryTarget
        case latestFailureID
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            restoring: container.decode(UUID.self, forKey: .id),
            mode: container.decode(CaptureSessionMode.self, forKey: .mode),
            state: container.decode(CaptureSessionState.self, forKey: .state),
            revision: container.decode(Int.self, forKey: .revision),
            createdAt: container.decode(Date.self, forKey: .createdAt),
            updatedAt: container.decode(Date.self, forKey: .updatedAt),
            startedAt: container.decodeIfPresent(Date.self, forKey: .startedAt),
            endedAt: container.decodeIfPresent(Date.self, forKey: .endedAt),
            recoveryTarget: container.decodeIfPresent(CaptureRecoveryTarget.self, forKey: .recoveryTarget),
            latestFailureID: container.decodeIfPresent(UUID.self, forKey: .latestFailureID)
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(mode, forKey: .mode)
        try container.encode(state, forKey: .state)
        try container.encode(revision, forKey: .revision)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(updatedAt, forKey: .updatedAt)
        try container.encodeIfPresent(startedAt, forKey: .startedAt)
        try container.encodeIfPresent(endedAt, forKey: .endedAt)
        try container.encodeIfPresent(recoveryTarget, forKey: .recoveryTarget)
        try container.encodeIfPresent(latestFailureID, forKey: .latestFailureID)
    }

    private mutating func transition(
        to nextState: CaptureSessionState,
        at timestamp: Date
    ) throws {
        try validateTransition(to: nextState)
        try validateTimestamp(timestamp)
        try incrementRevision()

        state = nextState
        recoveryTarget = nil
        updatedAt = timestamp
    }

    private func validateTransition(to nextState: CaptureSessionState) throws {
        if state.isTerminal {
            throw CaptureSessionError.terminalStateAlreadyReached(state)
        }

        guard state.canTransition(to: nextState) else {
            throw CaptureSessionError.illegalTransition(from: state, to: nextState)
        }
    }

    private func rejectTransition(to nextState: CaptureSessionState) throws {
        if state.isTerminal {
            throw CaptureSessionError.terminalStateAlreadyReached(state)
        }
        throw CaptureSessionError.illegalTransition(from: state, to: nextState)
    }

    private func validate(failure: CaptureFailure, expectedDisposition: CaptureFailureDisposition) throws {
        guard failure.sessionID == id else {
            throw CaptureSessionError.failureSessionMismatch(
                expected: id,
                actual: failure.sessionID
            )
        }
        guard failure.disposition == expectedDisposition else {
            throw CaptureSessionError.failureDispositionMismatch(
                expected: expectedDisposition,
                actual: failure.disposition
            )
        }
    }

    private func validateTimestamp(_ timestamp: Date) throws {
        guard timestamp >= updatedAt else {
            throw CaptureSessionError.timestampOutOfOrder(
                previous: updatedAt,
                attempted: timestamp
            )
        }
    }

    private mutating func incrementRevision() throws {
        guard revision < Int.max else {
            throw CaptureSessionError.revisionOverflow
        }
        revision += 1
    }

    private static func isValid(
        state: CaptureSessionState,
        revision: Int,
        createdAt: Date,
        updatedAt: Date,
        startedAt: Date?,
        endedAt: Date?,
        recoveryTarget: CaptureRecoveryTarget?,
        latestFailureID: UUID?
    ) -> Bool {
        guard createdAt <= updatedAt else {
            return false
        }

        if let startedAt {
            guard createdAt <= startedAt && startedAt <= updatedAt else {
                return false
            }
            if let endedAt, startedAt > endedAt {
                return false
            }
        }

        if let endedAt, !(createdAt <= endedAt && endedAt <= updatedAt) {
            return false
        }

        switch state {
        case .created:
            return revision == 0 &&
                createdAt == updatedAt &&
                startedAt == nil &&
                endedAt == nil &&
                recoveryTarget == nil &&
                latestFailureID == nil
        case .capturing:
            return revision >= 1 &&
                !revision.isMultiple(of: 2) &&
                startedAt != nil &&
                endedAt == nil &&
                recoveryTarget == nil &&
                (revision == 1 ? latestFailureID == nil : latestFailureID != nil)
        case .finalizing:
            return revision >= 2 &&
                revision.isMultiple(of: 2) &&
                startedAt != nil &&
                endedAt == nil &&
                recoveryTarget == nil &&
                (revision == 2 ? latestFailureID == nil : latestFailureID != nil)
        case .interrupted:
            guard startedAt != nil, endedAt == nil, latestFailureID != nil else {
                return false
            }
            switch recoveryTarget {
            case .capturing:
                return revision >= 2 && revision.isMultiple(of: 2)
            case .finalizing:
                return revision >= 3 && !revision.isMultiple(of: 2)
            case nil:
                return false
            }
        case .completed:
            guard let endedAt, endedAt == updatedAt else {
                return false
            }
            return revision >= 3 &&
                !revision.isMultiple(of: 2) &&
                startedAt != nil &&
                recoveryTarget == nil &&
                (revision == 3 ? latestFailureID == nil : latestFailureID != nil)
        case .failed:
            guard let endedAt, endedAt == updatedAt else {
                return false
            }
            return revision >= 1 &&
                recoveryTarget == nil &&
                latestFailureID != nil &&
                (revision == 1 ? startedAt == nil : startedAt != nil)
        case .cancelled:
            guard let endedAt, endedAt == updatedAt, revision >= 1, recoveryTarget == nil else {
                return false
            }
            switch revision {
            case 1:
                return startedAt == nil && latestFailureID == nil
            case 2:
                return startedAt != nil && latestFailureID == nil
            case 3:
                return startedAt != nil
            default:
                return startedAt != nil && latestFailureID != nil
            }
        }
    }
}

private extension CaptureSessionState {
    var isTerminal: Bool {
        switch self {
        case .completed, .failed, .cancelled:
            true
        case .created, .capturing, .interrupted, .finalizing:
            false
        }
    }


    func canTransition(to nextState: CaptureSessionState) -> Bool {
        switch (self, nextState) {
        case (.created, .capturing),
             (.capturing, .finalizing),
             (.finalizing, .completed),
             (.created, .failed),
             (.capturing, .failed),
             (.interrupted, .failed),
             (.finalizing, .failed),
             (.created, .cancelled),
             (.capturing, .cancelled),
             (.interrupted, .cancelled),
             (.finalizing, .cancelled):
            true
        default:
            false
        }
    }
}

private extension CaptureRecoveryTarget {
    var sessionState: CaptureSessionState {
        switch self {
        case .capturing:
            .capturing
        case .finalizing:
            .finalizing
        }
    }
}
