//
//  CaptureSessionTests.swift
//  PindropCoreTests
//
//  Created on 2026-08-20.
//

import Foundation
import Testing
@testable import PindropCore

@Suite
struct CaptureSessionTests {
    private let createdAt = Date(timeIntervalSinceReferenceDate: 1_000)

    private func makeSession(mode: CaptureSessionMode = .meeting) throws -> CaptureSession {
        try CaptureSession(mode: mode, createdAt: createdAt)
    }

    private func makeFailure(
        sessionID: UUID,
        disposition: CaptureFailureDisposition,
        at timestamp: Date
    ) -> CaptureFailure {
        CaptureFailure(
            sessionID: sessionID,
            disposition: disposition,
            occurredAt: timestamp,
            code: "capture.failed",
            message: "Capture failed"
        )
    }
    private struct PersistedSessionPayload: Encodable {
        let id: UUID
        let mode: String
        let state: String
        let revision: Int
        let createdAt: Date
        let updatedAt: Date
        let startedAt: Date?
        let endedAt: Date?
        let recoveryTarget: String?
        let latestFailureID: UUID?
    }

    private func decodePersistedSession(
        mode: String = CaptureSessionMode.meeting.rawValue,
        state: String,
        revision: Int,
        createdAt: Date,
        updatedAt: Date,
        startedAt: Date?,
        endedAt: Date?,
        recoveryTarget: String?,
        latestFailureID: UUID?
    ) throws -> CaptureSession {
        let payload = PersistedSessionPayload(
            id: UUID(),
            mode: mode,
            state: state,
            revision: revision,
            createdAt: createdAt,
            updatedAt: updatedAt,
            startedAt: startedAt,
            endedAt: endedAt,
            recoveryTarget: recoveryTarget,
            latestFailureID: latestFailureID
        )
        return try JSONDecoder().decode(CaptureSession.self, from: JSONEncoder().encode(payload))
    }


    @Test func normalLifecycleFollowsEveryForwardEdgeAndIncrementsRevision() throws {
        var session = try makeSession(mode: .dictate)
        let startedAt = createdAt.addingTimeInterval(1)
        let finalizingAt = createdAt.addingTimeInterval(2)
        let completedAt = createdAt.addingTimeInterval(3)

        try session.start(at: startedAt)
        #expect(session.state == .capturing)
        #expect(session.revision == 1)
        #expect(session.createdAt == createdAt)
        #expect(session.startedAt == startedAt)
        #expect(session.updatedAt == startedAt)
        #expect(session.endedAt == nil)

        try session.beginFinalization(at: finalizingAt)
        #expect(session.state == .finalizing)
        #expect(session.revision == 2)
        #expect(session.updatedAt == finalizingAt)

        try session.complete(at: completedAt)
        #expect(session.state == .completed)
        #expect(session.revision == 3)
        #expect(session.updatedAt == completedAt)
        #expect(session.endedAt == completedAt)
    }

    @Test func interruptionRecoversToCapturingTarget() throws {
        var session = try makeSession()
        let startedAt = createdAt.addingTimeInterval(1)
        let interruptedAt = createdAt.addingTimeInterval(2)
        let recoveredAt = createdAt.addingTimeInterval(3)

        try session.start(at: startedAt)
        let failure = makeFailure(sessionID: session.id, disposition: .recoverable, at: interruptedAt)
        try session.interrupt(with: failure, at: interruptedAt)

        #expect(session.state == .interrupted)
        #expect(session.recoveryTarget == .capturing)
        #expect(session.latestFailureID == failure.id)
        #expect(session.revision == 2)
        #expect(session.updatedAt == interruptedAt)

        try session.recover(at: recoveredAt)
        #expect(session.state == .capturing)
        #expect(session.recoveryTarget == nil)
        #expect(session.revision == 3)
        #expect(session.updatedAt == recoveredAt)
    }

    @Test func interruptionRecoversToFinalizingTarget() throws {
        var session = try makeSession(mode: .voiceNote)
        let startedAt = createdAt.addingTimeInterval(1)
        let finalizingAt = createdAt.addingTimeInterval(2)
        let interruptedAt = createdAt.addingTimeInterval(3)
        let recoveredAt = createdAt.addingTimeInterval(4)

        try session.start(at: startedAt)
        try session.beginFinalization(at: finalizingAt)
        let failure = makeFailure(sessionID: session.id, disposition: .recoverable, at: interruptedAt)
        try session.interrupt(with: failure, at: interruptedAt)

        #expect(session.state == .interrupted)
        #expect(session.recoveryTarget == .finalizing)
        #expect(session.latestFailureID == failure.id)
        #expect(session.revision == 3)

        try session.recover(at: recoveredAt)
        #expect(session.state == .finalizing)
        #expect(session.recoveryTarget == nil)
        #expect(session.revision == 4)
        #expect(session.updatedAt == recoveredAt)
    }

    @Test func eachNonterminalStateCanFailWithASessionTerminalFailure() throws {
        let failedAt = createdAt.addingTimeInterval(10)

        var created = try makeSession()
        let createdFailure = makeFailure(sessionID: created.id, disposition: .terminal, at: failedAt)
        try created.fail(with: createdFailure, at: failedAt)
        #expect(created.state == .failed)
        #expect(created.latestFailureID == createdFailure.id)
        #expect(created.endedAt == failedAt)

        var capturing = try makeSession()
        try capturing.start(at: createdAt.addingTimeInterval(1))
        let capturingFailure = makeFailure(sessionID: capturing.id, disposition: .terminal, at: failedAt)
        try capturing.fail(with: capturingFailure, at: failedAt)
        #expect(capturing.state == .failed)
        #expect(capturing.latestFailureID == capturingFailure.id)

        var finalizing = try makeSession()
        try finalizing.start(at: createdAt.addingTimeInterval(1))
        try finalizing.beginFinalization(at: createdAt.addingTimeInterval(2))
        let finalizingFailure = makeFailure(sessionID: finalizing.id, disposition: .terminal, at: failedAt)
        try finalizing.fail(with: finalizingFailure, at: failedAt)
        #expect(finalizing.state == .failed)
        #expect(finalizing.latestFailureID == finalizingFailure.id)

        var interrupted = try makeSession()
        try interrupted.start(at: createdAt.addingTimeInterval(1))
        let interruption = makeFailure(
            sessionID: interrupted.id,
            disposition: .recoverable,
            at: createdAt.addingTimeInterval(2)
        )
        try interrupted.interrupt(with: interruption, at: createdAt.addingTimeInterval(2))
        let interruptedFailure = makeFailure(sessionID: interrupted.id, disposition: .terminal, at: failedAt)
        try interrupted.fail(with: interruptedFailure, at: failedAt)
        #expect(interrupted.state == .failed)
        #expect(interrupted.latestFailureID == interruptedFailure.id)
    }

    @Test func eachNonterminalStateCanBeCancelled() throws {
        let cancelledAt = createdAt.addingTimeInterval(10)

        var created = try makeSession()
        try created.cancel(at: cancelledAt)
        #expect(created.state == .cancelled)
        #expect(created.endedAt == cancelledAt)

        var capturing = try makeSession()
        try capturing.start(at: createdAt.addingTimeInterval(1))
        try capturing.cancel(at: cancelledAt)
        #expect(capturing.state == .cancelled)
        #expect(capturing.endedAt == cancelledAt)

        var finalizing = try makeSession()
        try finalizing.start(at: createdAt.addingTimeInterval(1))
        try finalizing.beginFinalization(at: createdAt.addingTimeInterval(2))
        try finalizing.cancel(at: cancelledAt)
        #expect(finalizing.state == .cancelled)
        #expect(finalizing.endedAt == cancelledAt)

        var interrupted = try makeSession()
        try interrupted.start(at: createdAt.addingTimeInterval(1))
        let interruption = makeFailure(
            sessionID: interrupted.id,
            disposition: .recoverable,
            at: createdAt.addingTimeInterval(2)
        )
        try interrupted.interrupt(with: interruption, at: createdAt.addingTimeInterval(2))
        try interrupted.cancel(at: cancelledAt)
        #expect(interrupted.state == .cancelled)
        #expect(interrupted.endedAt == cancelledAt)
    }

    @Test func foreignAndWrongDispositionFailuresAreRejectedWithoutMutation() throws {
        var capturing = try makeSession()
        try capturing.start(at: createdAt.addingTimeInterval(1))
        let capturingSnapshot = capturing
        let foreignRecoverable = makeFailure(
            sessionID: UUID(),
            disposition: .recoverable,
            at: createdAt.addingTimeInterval(2)
        )
        #expect(throws: (any Error).self) {
            try capturing.interrupt(with: foreignRecoverable, at: createdAt.addingTimeInterval(2))
        }
        #expect(capturing == capturingSnapshot)

        let terminalForInterruption = makeFailure(
            sessionID: capturing.id,
            disposition: .terminal,
            at: createdAt.addingTimeInterval(2)
        )
        #expect(throws: (any Error).self) {
            try capturing.interrupt(with: terminalForInterruption, at: createdAt.addingTimeInterval(2))
        }
        #expect(capturing == capturingSnapshot)

        let foreignTerminal = makeFailure(
            sessionID: UUID(),
            disposition: .terminal,
            at: createdAt.addingTimeInterval(2)
        )
        #expect(throws: (any Error).self) {
            try capturing.fail(with: foreignTerminal, at: createdAt.addingTimeInterval(2))
        }
        #expect(capturing == capturingSnapshot)

        let recoverableForFailure = makeFailure(
            sessionID: capturing.id,
            disposition: .recoverable,
            at: createdAt.addingTimeInterval(2)
        )
        #expect(throws: (any Error).self) {
            try capturing.fail(with: recoverableForFailure, at: createdAt.addingTimeInterval(2))
        }
        #expect(capturing == capturingSnapshot)
    }

    @Test func backwardsTimestampIsRejectedWithoutMutation() throws {
        var session = try makeSession()
        try session.start(at: createdAt.addingTimeInterval(2))
        let snapshot = session

        #expect(throws: (any Error).self) {
            try session.beginFinalization(at: createdAt.addingTimeInterval(1))
        }

        #expect(session == snapshot)
    }
    @Test func interruptAndRecoverRejectTimestampAndRevisionFailuresWithoutMutation() throws {
        let startedAt = createdAt.addingTimeInterval(2)
        let earlierAt = createdAt.addingTimeInterval(1)
        let interruptedAt = createdAt.addingTimeInterval(3)

        var interrupting = try makeSession()
        try interrupting.start(at: startedAt)
        let interruptingSnapshot = interrupting
        let interruption = makeFailure(sessionID: interrupting.id, disposition: .recoverable, at: earlierAt)
        #expect(
            throws: CaptureSessionError.timestampOutOfOrder(previous: startedAt, attempted: earlierAt)
        ) {
            try interrupting.interrupt(with: interruption, at: earlierAt)
        }
        #expect(interrupting == interruptingSnapshot)

        var recovering = try makeSession()
        try recovering.start(at: startedAt)
        let recoverableFailure = makeFailure(
            sessionID: recovering.id,
            disposition: .recoverable,
            at: interruptedAt
        )
        try recovering.interrupt(with: recoverableFailure, at: interruptedAt)
        let recoveringSnapshot = recovering
        #expect(
            throws: CaptureSessionError.timestampOutOfOrder(previous: interruptedAt, attempted: earlierAt)
        ) {
            try recovering.recover(at: earlierAt)
        }
        #expect(recovering == recoveringSnapshot)

        var maximumCapturingRevision = try CaptureSession(
            restoring: UUID(),
            mode: .meeting,
            state: .capturing,
            revision: .max,
            createdAt: createdAt,
            updatedAt: startedAt,
            startedAt: startedAt,
            endedAt: nil,
            recoveryTarget: nil,
            latestFailureID: UUID()
        )
        let maximumCapturingSnapshot = maximumCapturingRevision
        let maximumRevisionFailure = makeFailure(
            sessionID: maximumCapturingRevision.id,
            disposition: .recoverable,
            at: interruptedAt
        )
        #expect(throws: CaptureSessionError.revisionOverflow) {
            try maximumCapturingRevision.interrupt(with: maximumRevisionFailure, at: interruptedAt)
        }
        #expect(maximumCapturingRevision == maximumCapturingSnapshot)

        var maximumInterruptedRevision = try CaptureSession(
            restoring: UUID(),
            mode: .meeting,
            state: .interrupted,
            revision: .max,
            createdAt: createdAt,
            updatedAt: interruptedAt,
            startedAt: startedAt,
            endedAt: nil,
            recoveryTarget: .finalizing,
            latestFailureID: UUID()
        )
        let maximumInterruptedSnapshot = maximumInterruptedRevision
        #expect(throws: CaptureSessionError.revisionOverflow) {
            try maximumInterruptedRevision.recover(at: interruptedAt)
        }
        #expect(maximumInterruptedRevision == maximumInterruptedSnapshot)
    }


    @Test func terminalStatesRejectDataBearingOperationsBeforeFailureValidation() throws {
        let terminalAt = createdAt.addingTimeInterval(3)
        let attemptedAt = createdAt.addingTimeInterval(4)

        var completed = try makeSession()
        try completed.start(at: createdAt.addingTimeInterval(1))
        try completed.beginFinalization(at: createdAt.addingTimeInterval(2))
        try completed.complete(at: terminalAt)
        let completedSnapshot = completed
        let completedRecoverable = makeFailure(sessionID: UUID(), disposition: .recoverable, at: attemptedAt)
        let completedTerminal = makeFailure(sessionID: UUID(), disposition: .terminal, at: attemptedAt)
        #expect(throws: CaptureSessionError.terminalStateAlreadyReached(.completed)) {
            try completed.interrupt(with: completedRecoverable, at: attemptedAt)
        }
        #expect(throws: CaptureSessionError.terminalStateAlreadyReached(.completed)) {
            try completed.fail(with: completedTerminal, at: attemptedAt)
        }
        #expect(completed == completedSnapshot)

        var failed = try makeSession()
        try failed.fail(
            with: makeFailure(sessionID: failed.id, disposition: .terminal, at: terminalAt),
            at: terminalAt
        )
        let failedSnapshot = failed
        let failedRecoverable = makeFailure(sessionID: UUID(), disposition: .recoverable, at: attemptedAt)
        let failedTerminal = makeFailure(sessionID: UUID(), disposition: .terminal, at: attemptedAt)
        #expect(throws: CaptureSessionError.terminalStateAlreadyReached(.failed)) {
            try failed.interrupt(with: failedRecoverable, at: attemptedAt)
        }
        #expect(throws: CaptureSessionError.terminalStateAlreadyReached(.failed)) {
            try failed.fail(with: failedTerminal, at: attemptedAt)
        }
        #expect(failed == failedSnapshot)

        var cancelled = try makeSession()
        try cancelled.cancel(at: terminalAt)
        let cancelledSnapshot = cancelled
        let cancelledRecoverable = makeFailure(sessionID: UUID(), disposition: .recoverable, at: attemptedAt)
        let cancelledTerminal = makeFailure(sessionID: UUID(), disposition: .terminal, at: attemptedAt)
        #expect(throws: CaptureSessionError.terminalStateAlreadyReached(.cancelled)) {
            try cancelled.interrupt(with: cancelledRecoverable, at: attemptedAt)
        }
        #expect(throws: CaptureSessionError.terminalStateAlreadyReached(.cancelled)) {
            try cancelled.fail(with: cancelledTerminal, at: attemptedAt)
        }
        #expect(cancelled == cancelledSnapshot)
    }


    @Test func illegalAndSelfTransitionsAreRejectedWithoutMutation() throws {
        var session = try makeSession()
        let createdSnapshot = session
        #expect(throws: (any Error).self) {
            try session.beginFinalization(at: createdAt.addingTimeInterval(1))
        }
        #expect(session == createdSnapshot)

        try session.start(at: createdAt.addingTimeInterval(1))
        let capturingSnapshot = session
        #expect(throws: (any Error).self) {
            try session.start(at: createdAt.addingTimeInterval(2))
        }
        #expect(throws: (any Error).self) {
            try session.complete(at: createdAt.addingTimeInterval(2))
        }
        #expect(session == capturingSnapshot)

        try session.beginFinalization(at: createdAt.addingTimeInterval(2))
        let finalizingSnapshot = session
        #expect(throws: (any Error).self) {
            try session.beginFinalization(at: createdAt.addingTimeInterval(3))
        }
        #expect(session == finalizingSnapshot)
    }

    @Test func legalSessionCodableRoundTripPreservesLifecycleState() throws {
        var session = try makeSession(mode: .voiceNote)
        try session.start(at: createdAt.addingTimeInterval(1))
        try session.beginFinalization(at: createdAt.addingTimeInterval(2))
        let failure = makeFailure(
            sessionID: session.id,
            disposition: .recoverable,
            at: createdAt.addingTimeInterval(3)
        )
        try session.interrupt(with: failure, at: createdAt.addingTimeInterval(3))

        let encoded = try JSONEncoder().encode(session)
        let decoded = try JSONDecoder().decode(CaptureSession.self, from: encoded)

        #expect(decoded == session)
    }

    @Test func customDecodingRejectsMalformedPersistedStates() throws {
        let startedAt = createdAt.addingTimeInterval(1)
        let endedAt = createdAt.addingTimeInterval(2)
        let failureID = UUID()

        let malformedPayloads: [() throws -> CaptureSession] = [
            {
                try self.decodePersistedSession(
                    state: "created",
                    revision: 0,
                    createdAt: self.createdAt,
                    updatedAt: endedAt,
                    startedAt: nil,
                    endedAt: nil,
                    recoveryTarget: nil,
                    latestFailureID: nil
                )
            },
            {
                try self.decodePersistedSession(
                    state: "capturing",
                    revision: 2,
                    createdAt: self.createdAt,
                    updatedAt: startedAt,
                    startedAt: startedAt,
                    endedAt: nil,
                    recoveryTarget: nil,
                    latestFailureID: failureID
                )
            },
            {
                try self.decodePersistedSession(
                    state: "finalizing",
                    revision: 3,
                    createdAt: self.createdAt,
                    updatedAt: endedAt,
                    startedAt: startedAt,
                    endedAt: nil,
                    recoveryTarget: nil,
                    latestFailureID: failureID
                )
            },
            {
                try self.decodePersistedSession(
                    state: "interrupted",
                    revision: 3,
                    createdAt: self.createdAt,
                    updatedAt: endedAt,
                    startedAt: startedAt,
                    endedAt: nil,
                    recoveryTarget: "capturing",
                    latestFailureID: failureID
                )
            },
            {
                try self.decodePersistedSession(
                    state: "interrupted",
                    revision: 2,
                    createdAt: self.createdAt,
                    updatedAt: endedAt,
                    startedAt: startedAt,
                    endedAt: nil,
                    recoveryTarget: "finalizing",
                    latestFailureID: failureID
                )
            },
            {
                try self.decodePersistedSession(
                    state: "completed",
                    revision: 4,
                    createdAt: self.createdAt,
                    updatedAt: endedAt,
                    startedAt: startedAt,
                    endedAt: endedAt,
                    recoveryTarget: nil,
                    latestFailureID: failureID
                )
            },
            {
                try self.decodePersistedSession(
                    state: "cancelled",
                    revision: 2,
                    createdAt: self.createdAt,
                    updatedAt: endedAt,
                    startedAt: nil,
                    endedAt: endedAt,
                    recoveryTarget: nil,
                    latestFailureID: nil
                )
            },
            {
                try self.decodePersistedSession(
                    state: "failed",
                    revision: 1,
                    createdAt: self.createdAt,
                    updatedAt: endedAt,
                    startedAt: startedAt,
                    endedAt: endedAt,
                    recoveryTarget: nil,
                    latestFailureID: failureID
                )
            },
            {
                try self.decodePersistedSession(
                    state: "failed",
                    revision: 2,
                    createdAt: self.createdAt,
                    updatedAt: endedAt,
                    startedAt: startedAt,
                    endedAt: self.createdAt.addingTimeInterval(1.5),
                    recoveryTarget: nil,
                    latestFailureID: failureID
                )
            },
            {
                try self.decodePersistedSession(
                    state: "failed",
                    revision: 1,
                    createdAt: self.createdAt,
                    updatedAt: endedAt,
                    startedAt: nil,
                    endedAt: endedAt,
                    recoveryTarget: nil,
                    latestFailureID: nil
                )
            }
        ]

        for decode in malformedPayloads {
            #expect(throws: CaptureSessionError.invalidPersistedState) {
                try decode()
            }
        }

        #expect(throws: DecodingError.self) {
            try self.decodePersistedSession(
                state: "unknown",
                revision: 0,
                createdAt: self.createdAt,
                updatedAt: self.createdAt,
                startedAt: nil,
                endedAt: nil,
                recoveryTarget: nil,
                latestFailureID: nil
            )
        }
        #expect(throws: DecodingError.self) {
            try self.decodePersistedSession(
                mode: "unknown",
                state: "created",
                revision: 0,
                createdAt: self.createdAt,
                updatedAt: self.createdAt,
                startedAt: nil,
                endedAt: nil,
                recoveryTarget: nil,
                latestFailureID: nil
            )
        }
        #expect(throws: DecodingError.self) {
            try self.decodePersistedSession(
                state: "interrupted",
                revision: 2,
                createdAt: self.createdAt,
                updatedAt: endedAt,
                startedAt: startedAt,
                endedAt: nil,
                recoveryTarget: "unknown",
                latestFailureID: failureID
            )
        }
    }
    @Test func invalidRestoredCombinationsAreRejected() {
        let startedAt = createdAt.addingTimeInterval(1)
        let endedAt = createdAt.addingTimeInterval(2)

        #expect(throws: (any Error).self) {
            try CaptureSession(
                restoring: UUID(),
                mode: .dictate,
                state: .capturing,
                revision: 0,
                createdAt: createdAt,
                updatedAt: createdAt,
                startedAt: nil,
                endedAt: nil,
                recoveryTarget: nil,
                latestFailureID: nil
            )
        }

        #expect(throws: (any Error).self) {
            try CaptureSession(
                restoring: UUID(),
                mode: .dictate,
                state: .interrupted,
                revision: 2,
                createdAt: createdAt,
                updatedAt: endedAt,
                startedAt: startedAt,
                endedAt: nil,
                recoveryTarget: nil,
                latestFailureID: UUID()
            )
        }

        #expect(throws: (any Error).self) {
            try CaptureSession(
                restoring: UUID(),
                mode: .dictate,
                state: .completed,
                revision: 2,
                createdAt: createdAt,
                updatedAt: endedAt,
                startedAt: startedAt,
                endedAt: nil,
                recoveryTarget: nil,
                latestFailureID: nil
            )
        }

        #expect(throws: (any Error).self) {
            try CaptureSession(
                restoring: UUID(),
                mode: .dictate,
                state: .created,
                revision: 0,
                createdAt: createdAt,
                updatedAt: createdAt,
                startedAt: nil,
                endedAt: nil,
                recoveryTarget: .capturing,
                latestFailureID: nil
            )
        }
    }
}
