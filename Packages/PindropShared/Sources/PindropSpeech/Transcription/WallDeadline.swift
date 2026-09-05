//
//  WallDeadline.swift
//  PindropSpeech
//
//  Created on 2026-08-31.
//
//  A wall-clock bound on one CoreML call.
//
//  Cancellation cannot express this bound. `MLModel(contentsOf:)` and
//  `OfflineDiarizerManager.process(audio:)` are synchronous, so a cancelled task
//  runs to completion anyway, and `await task.value` neither shortens the child
//  nor returns when the awaiting task is cancelled. A task group has the same
//  problem from the other side: it waits for every child before it returns, so
//  the group would sit out the very load it is meant to bound.
//
//  So the two outcomes race through a one-shot gate and the loser's result is
//  dropped. A load that loses is left to finish and release its own models.
//

import Foundation

/// What a bounded call produced.
enum WallDeadlineOutcome<Value: Sendable>: @unchecked Sendable {
    case value(Value)
    /// `any Error` carries no static `Sendable` guarantee. The errors that cross
    /// here are FluidAudio and Foundation values with no shared mutable state,
    /// and only the awaiting isolation ever reads one.
    case failure(any Error)
    case timedOut
}

/// Runs `work` on its own detached task and gives up on it after `seconds`.
///
/// The work is cancelled on timeout as a courtesy to any part of it that does
/// poll cancellation. The bound does not depend on that.
func withWallDeadline<Value: Sendable>(
    seconds: TimeInterval,
    _ work: @escaping @Sendable () async throws -> Value
) async -> WallDeadlineOutcome<Value> {
    let gate = WallDeadlineGate<Value>()
    let workTask = Task.detached(priority: .utility) {
        do {
            await gate.settle(.value(try await work()))
        } catch {
            await gate.settle(.failure(error))
        }
    }
    let deadlineTask = Task.detached(priority: .utility) {
        try? await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
        await gate.settle(.timedOut)
    }
    defer { deadlineTask.cancel() }

    let outcome = await gate.outcome()
    if case .timedOut = outcome { workTask.cancel() }
    return outcome
}

/// Resolves once, for whichever racer arrives first.
private actor WallDeadlineGate<Value: Sendable> {
    private var settled: WallDeadlineOutcome<Value>?
    private var waiters: [CheckedContinuation<WallDeadlineOutcome<Value>, Never>] = []

    func settle(_ outcome: WallDeadlineOutcome<Value>) {
        guard settled == nil else { return }
        settled = outcome
        let pending = waiters
        waiters.removeAll()
        for waiter in pending { waiter.resume(returning: outcome) }
    }

    func outcome() async -> WallDeadlineOutcome<Value> {
        if let settled { return settled }
        return await withCheckedContinuation { continuation in
            if let settled {
                continuation.resume(returning: settled)
            } else {
                waiters.append(continuation)
            }
        }
    }
}
