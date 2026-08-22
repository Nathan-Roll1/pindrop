//
//  TestSupport.swift
//  PindropTests
//
//  Created on 2026-03-21.
//

import Foundation
import PindropAI
@testable import Pindrop

/// Stubs the one seam `AIEnhancementService` already has for tests: its
/// `URLSessionProtocol`. Request shaping and response parsing stay real, so a
/// test asserts on what the provider would actually have been sent.
final class StubEnhancementProviderSession: URLSessionProtocol, @unchecked Sendable {
    var responseContent = "Decisions: ship on Friday."
    var error: Error?
    private(set) var requestCount = 0
    private(set) var lastRequest: URLRequest?

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        requestCount += 1
        lastRequest = request
        if let error {
            throw error
        }
        let payload = """
        {"choices": [{"message": {"content": \(Self.jsonString(responseContent))}}]}
        """
        let response = HTTPURLResponse(
            url: request.url ?? URL(string: "https://example.invalid")!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: nil
        )!
        return (Data(payload.utf8), response)
    }

    /// JSON-escapes one string and returns it with its quotes, so any content
    /// can be embedded in the stubbed response body.
    private static func jsonString(_ value: String) -> String {
        guard let data = try? JSONSerialization.data(
            withJSONObject: [value],
            options: [.fragmentsAllowed]
        ) else {
            return "\"\""
        }
        let encoded = String(decoding: data, as: UTF8.self)
        return String(encoded.dropFirst().dropLast())
    }
}

final class ManualTaskScheduler: TaskScheduling {
    private struct PendingTask {
        let sequence: Int
        let fireAt: Date
        let operation: @MainActor () -> Void
        let token: Token
    }

    final class Token: ScheduledTask {
        fileprivate var isCancelled = false

        func cancel() {
            isCancelled = true
        }
    }

    private(set) var now: Date
    private var pendingTasks: [PendingTask] = []
    private var nextSequence = 0

    init(now: Date = Date(timeIntervalSince1970: 0)) {
        self.now = now
    }

    func schedule(after delay: TimeInterval, operation: @escaping @MainActor () -> Void) -> ScheduledTask {
        let token = Token()
        let task = PendingTask(
            sequence: nextSequence,
            fireAt: now.addingTimeInterval(delay),
            operation: operation,
            token: token
        )
        nextSequence += 1
        pendingTasks.append(task)
        return token
    }

    func advance(by interval: TimeInterval) {
        now = now.addingTimeInterval(interval)
        runDueTasks()
    }

    private func runDueTasks() {
        while let nextIndex = nextDueTaskIndex() {
            let task = pendingTasks.remove(at: nextIndex)
            guard !task.token.isCancelled else { continue }
            MainActor.assumeIsolated {
                task.operation()
            }
        }
    }

    private func nextDueTaskIndex() -> Int? {
        pendingTasks
            .enumerated()
            .filter { $0.element.fireAt <= now }
            .min {
                if $0.element.fireAt == $1.element.fireAt {
                    return $0.element.sequence < $1.element.sequence
                }
                return $0.element.fireAt < $1.element.fireAt
            }?
            .offset
    }
}
