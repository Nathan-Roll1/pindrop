//
//  TranscriptionServiceAppAdapterTests.swift
//  PindropTests
//
//  macOS adapter cases that depend on app-only WorkspaceFileIndexService /
//  StreamingSessionController seams. Portable TranscriptionService coverage lives
//  in PindropSpeechTests.
//

import Foundation
import Testing
@testable import Pindrop
import PindropSpeech

@MainActor
@Suite
private struct WorkspaceFileIndexTimeoutTests {
    @Test func buildIndexReturnsAtDeadlineWhenEnumerationIgnoresCancellation() async throws {
        let fileSystem = NonCooperativeFileSystemProvider()
        let index = WorkspaceFileIndexService(
            fileSystem: fileSystem,
            buildTimeout: .milliseconds(20)
        )
        let started = ContinuousClock.now

        do {
            _ = try await index.buildIndex(roots: ["/workspace"])
            Issue.record("Expected workspace indexing to time out")
        } catch WorkspaceFileIndexError.enumerationFailed {
            let elapsed = started.duration(to: .now)
            #expect(elapsed < .milliseconds(250))
            #expect(index.fileCount == 0)
        }
    }
}

private final class NonCooperativeFileSystemProvider: FileSystemProvider, @unchecked Sendable {
    func enumerateFiles(under root: String) throws -> [String] {
        Thread.sleep(forTimeInterval: 0.5)
        return ["\(root)/late.swift"]
    }

    func directoryExists(at path: String) -> Bool { true }
}

@Suite
private struct StreamingFinalizeTimeoutTests {
    @Test func finalizeTimeoutReturnsAtDeadlineWhenOperationIgnoresCancellation() async {
        let started = ContinuousClock.now
        do {
            _ = try await StreamingSessionController.withFinalizeTimeout(nanoseconds: 20_000_000) {
                await withCheckedContinuation { continuation in
                    DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) {
                        continuation.resume()
                    }
                }
                return "late result"
            }
            Issue.record("Expected finalize step to time out")
        } catch {
            let elapsed = started.duration(to: .now)
            #expect(elapsed < .milliseconds(250))
        }
    }
}

@Suite
private struct StreamingAudioBackpressureTests {
    @Test func bufferingNewestRetainsOnlyMostRecentAudioWindow() async {
        let limit = StreamingSessionController.maximumBufferedAudioBuffers
        let (stream, continuation) = AsyncStream.makeStream(
            of: Int.self,
            bufferingPolicy: .bufferingNewest(limit)
        )

        for value in 0...limit {
            continuation.yield(value)
        }
        continuation.finish()

        var received: [Int] = []
        for await value in stream {
            received.append(value)
        }

        #expect(received == Array(1...limit))
    }
}

