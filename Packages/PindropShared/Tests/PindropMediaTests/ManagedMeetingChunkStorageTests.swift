//
//  ManagedMeetingChunkStorageTests.swift
//  PindropMediaTests
//

import Foundation
import PindropCore
import Testing
@testable import PindropMedia

@Suite
struct ManagedMeetingChunkStorageTests {
    @Test func canonicalSpoolPlanAndPathsUseTheLibraryRoot() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let library = ManagedMediaLibrary(baseURL: root)
        let sessionID = UUID()
        let microphoneID = UUID()
        let systemAudioID = UUID()

        let plan = try library.makeMeetingCaptureSpoolPlan(
            sessionID: sessionID,
            microphoneSourceID: microphoneID,
            systemAudioSourceID: systemAudioID
        )

        #expect(plan.libraryRootURL == root)
        #expect(plan.chunkByteCount == 19_200_000)
        #expect(CaptureSourceArtifactPath.relativePath(
            sessionID: sessionID,
            sourceID: microphoneID,
            chunkSequence: 7
        ) == "CaptureSessions/\(sessionID.uuidString)/Sources/\(microphoneID.uuidString)/chunk-00007.pcm")
        #expect(CaptureSourceArtifactPath.inProgressRelativePath(
            sessionID: sessionID,
            sourceID: microphoneID,
            chunkSequence: 7
        ).hasSuffix("chunk-00007.pcm.inprogress"))
        #expect(CaptureSourceArtifactPath.mixedRelativePath(
            sessionID: sessionID,
            chunkSequence: 7
        ) == "CaptureSessions/\(sessionID.uuidString)/Mixed/chunk-00007.pcm")
    }

    @Test func recoversNinetyMinuteEquivalentEighteenChunkInventory() throws {
        let (library, plan, root) = try makeFixture(chunkByteCount: 8)
        defer { try? FileManager.default.removeItem(at: root) }

        for sequence in 0..<18 {
            try writePCM([Float32(sequence), Float32(-sequence)], to: sourceURL(plan, sourceID: plan.microphoneSourceID, sequence: sequence))
        }

        let result = try library.recoverMeetingArtifacts(for: plan)

        #expect(result.sealedChunks.count == 18)
        #expect(result.sealedChunks.map(\.sequence) == Array(0..<18))
        #expect(result.sealedChunks.allSatisfy { $0.sourceID == plan.microphoneSourceID })
        #expect(result.sealedChunks.last?.startOffset == Double(17 * 8) / 64_000)
        #expect(result.sealedChunks.allSatisfy { $0.byteCount == 8 })
        #expect(result.failures.isEmpty)
    }

    @Test func recoverySealsAlignedCrashTailAndRemovesEmptyTail() throws {
        let (library, plan, root) = try makeFixture(chunkByteCount: 8)
        defer { try? FileManager.default.removeItem(at: root) }
        try writePCM([1, 2], to: sourceURL(plan, sourceID: plan.microphoneSourceID, sequence: 0))
        let tail = CaptureSourceArtifactPath.inProgressSourceURL(
            libraryRootURL: root,
            sessionID: plan.sessionID,
            sourceID: plan.microphoneSourceID,
            chunkSequence: 1
        )
        try FileManager.default.createDirectory(at: tail.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data([0, 0, 128, 63]).write(to: tail)
        let emptyTail = CaptureSourceArtifactPath.inProgressSourceURL(
            libraryRootURL: root,
            sessionID: plan.sessionID,
            sourceID: plan.systemAudioSourceID,
            chunkSequence: 0
        )
        _ = FileManager.default.createFile(atPath: emptyTail.path, contents: nil)

        let result = try library.recoverMeetingArtifacts(for: plan)

        #expect(result.sealedChunks.count == 2)
        #expect(result.sealedChunks.last?.byteCount == 4)
        #expect(!FileManager.default.fileExists(atPath: tail.path))
        #expect(FileManager.default.fileExists(atPath: tail.deletingPathExtension().path))
        #expect(!FileManager.default.fileExists(atPath: emptyTail.path))
        #expect(result.failures.isEmpty)
    }

    @Test func recoveryPreservesValidSiblingsWhenMiddleChunkIsCorrupt() throws {
        let (library, plan, root) = try makeFixture(chunkByteCount: 8)
        defer { try? FileManager.default.removeItem(at: root) }
        try writePCM([1, 2], to: sourceURL(plan, sourceID: plan.microphoneSourceID, sequence: 0))
        let corruptURL = sourceURL(plan, sourceID: plan.microphoneSourceID, sequence: 1)
        try Data([0, 1, 2]).write(to: corruptURL)
        try writePCM([3, 4], to: sourceURL(plan, sourceID: plan.microphoneSourceID, sequence: 2))
        try writePCM([5, 6], to: sourceURL(plan, sourceID: plan.systemAudioSourceID, sequence: 0))

        let result = try library.recoverMeetingArtifacts(for: plan)

        #expect(result.sealedChunks.count == 3)
        #expect(result.sealedChunks.contains { $0.sourceID == plan.microphoneSourceID && $0.sequence == 0 })
        #expect(result.sealedChunks.contains { $0.sourceID == plan.microphoneSourceID && $0.sequence == 2 })
        #expect(result.sealedChunks.contains { $0.sourceID == plan.systemAudioSourceID && $0.sequence == 0 })
        #expect(result.failures.contains {
            $0.sourceID == plan.microphoneSourceID
                && $0.sequence == 1
                && $0.kind == .invalidFormat
                && $0.isRetryable
        })
        #expect(FileManager.default.fileExists(atPath: corruptURL.path))
    }

    @Test func recoveryReportsMalformedCanonicalFileWithoutDiscardingValidChunks() throws {
        let (library, plan, root) = try makeFixture(chunkByteCount: 8)
        defer { try? FileManager.default.removeItem(at: root) }
        try writePCM([1, 2], to: sourceURL(plan, sourceID: plan.microphoneSourceID, sequence: 0))
        let malformedURL = sourceURL(plan, sourceID: plan.microphoneSourceID, sequence: 1)
            .deletingLastPathComponent()
            .appendingPathComponent("chunk-one.pcm")
        _ = FileManager.default.createFile(atPath: malformedURL.path, contents: Data([0, 1, 2]))

        let result = try library.recoverMeetingArtifacts(for: plan)

        #expect(result.sealedChunks.count == 1)
        #expect(result.sealedChunks.first?.sourceID == plan.microphoneSourceID)
        #expect(result.sealedChunks.first?.sequence == 0)
        #expect(result.failures.contains {
            $0.sourceID == plan.microphoneSourceID
                && $0.sequence == nil
                && $0.kind == .malformedFileName
                && $0.relativePath == "CaptureSessions/\(plan.sessionID.uuidString)/Sources/\(plan.microphoneSourceID.uuidString)/chunk-one.pcm"
        })
        #expect(FileManager.default.fileExists(atPath: malformedURL.path))
    }

    @Test func recoveryReportsLostSourceWithoutDiscardingOtherSource() throws {
        let (library, plan, root) = try makeFixture(chunkByteCount: 8)
        defer { try? FileManager.default.removeItem(at: root) }
        try writePCM([1, 2], to: sourceURL(plan, sourceID: plan.microphoneSourceID, sequence: 0))
        let lostDirectory = sourceURL(plan, sourceID: plan.systemAudioSourceID, sequence: 0)
            .deletingLastPathComponent()
        try FileManager.default.removeItem(at: lostDirectory)

        let result = try library.recoverMeetingArtifacts(for: plan)

        #expect(result.sealedChunks.count == 1)
        #expect(result.sealedChunks.first?.sourceID == plan.microphoneSourceID)
        #expect(result.sealedChunks.first?.sequence == 0)
        #expect(result.failures.contains {
            $0.sourceID == plan.systemAudioSourceID
                && $0.sequence == nil
                && $0.kind == .sourceUnavailable
                && $0.isRetryable
        })
    }

    @Test func recoveryRejectsSymlinksAndPathEscape() throws {
        let (library, plan, root) = try makeFixture(chunkByteCount: 8)
        defer { try? FileManager.default.removeItem(at: root) }
        let sourceDirectory = sourceURL(plan, sourceID: plan.microphoneSourceID, sequence: 0).deletingLastPathComponent()
        let outsideDirectory = root.deletingLastPathComponent().appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: outsideDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outsideDirectory) }
        try FileManager.default.removeItem(at: sourceDirectory)
        try FileManager.default.createSymbolicLink(at: sourceDirectory, withDestinationURL: outsideDirectory)

        #expect(throws: MediaLibraryError.self) {
            try library.recoverMeetingArtifacts(for: plan)
        }

        let escapedChunk = SealedAudioSourceChunk(
            sessionID: plan.sessionID,
            sourceID: plan.microphoneSourceID,
            sequence: 0,
            startOffset: 0,
            duration: 0,
            fileURL: outsideDirectory,
            relativePath: "../../outside.pcm",
            byteCount: 4,
            sha256: "not-a-hash"
        )
        #expect(throws: MediaLibraryError.self) {
            try library.resolveArtifactURL(for: escapedChunk)
        }
    }

    @Test func mixesMicrophoneSystemAndSoleSourceChunksWithPadding() throws {
        let (library, plan, root) = try makeFixture(chunkByteCount: 12)
        defer { try? FileManager.default.removeItem(at: root) }
        try writePCM([0.75, -0.5, 0.25], to: sourceURL(plan, sourceID: plan.microphoneSourceID, sequence: 0))
        try writePCM([0.75], to: sourceURL(plan, sourceID: plan.systemAudioSourceID, sequence: 0))
        let inventory = try library.recoverMeetingArtifacts(for: plan).sealedChunks
        let microphone = try #require(inventory.first { $0.sourceID == plan.microphoneSourceID })
        let systemAudio = try #require(inventory.first { $0.sourceID == plan.systemAudioSourceID })

        let mixed = try library.makeMixedMeetingChunk(
            sessionID: plan.sessionID,
            sequence: 0,
            microphone: microphone,
            systemAudio: systemAudio
        )
        #expect(try readPCM(at: root.appendingPathComponent(mixed.relativePath)) == [1, -0.5, 0.25])

        let soleMixed = try library.makeMixedMeetingChunk(
            sessionID: plan.sessionID,
            sequence: 1,
            microphone: microphoneFor(sequence: 1, values: [0.25, 0.5], plan: plan, library: library),
            systemAudio: nil
        )
        #expect(try readPCM(at: root.appendingPathComponent(soleMixed.relativePath)) == [0.25, 0.5])
    }

    @Test func mixedReplayConflictsAndPartialStagingIsRemoved() throws {
        let (library, plan, root) = try makeFixture(chunkByteCount: 8)
        defer { try? FileManager.default.removeItem(at: root) }
        try writePCM([0.25, 0.5], to: sourceURL(plan, sourceID: plan.microphoneSourceID, sequence: 0))
        let firstChunk = try #require(library.recoverMeetingArtifacts(for: plan).sealedChunks.first)
        let original = try library.makeMixedMeetingChunk(
            sessionID: plan.sessionID,
            sequence: 0,
            microphone: firstChunk,
            systemAudio: nil
        )
        let replay = try library.makeMixedMeetingChunk(
            sessionID: plan.sessionID,
            sequence: 0,
            microphone: firstChunk,
            systemAudio: nil
        )
        #expect(replay == original)

        try writePCM([0.75, 0.5], to: sourceURL(plan, sourceID: plan.microphoneSourceID, sequence: 0))
        let changedChunk = try #require(library.recoverMeetingArtifacts(for: plan).sealedChunks.first)
        #expect(throws: MediaLibraryError.self) {
            try library.makeMixedMeetingChunk(
                sessionID: plan.sessionID,
                sequence: 0,
                microphone: changedChunk,
                systemAudio: nil
            )
        }

        let failingLibrary = ManagedMediaLibrary(baseURL: root, fileManager: FailingMoveFileManager())
        do {
            _ = try failingLibrary.makeMixedMeetingChunk(
                sessionID: plan.sessionID,
                sequence: 1,
                microphone: microphoneFor(sequence: 1, values: [0.25, 0.5], plan: plan, library: library),
                systemAudio: nil
            )
            Issue.record("Expected mixed chunk publication to fail during final rename")
        } catch {
        }
        let stagingURL = CaptureSourceArtifactPath.mixedInProgressURL(
            libraryRootURL: root,
            sessionID: plan.sessionID,
            chunkSequence: 1
        )
        #expect(!FileManager.default.fileExists(atPath: stagingURL.path))

        try library.removeMixedMeetingChunk(original)
        try library.removeMixedMeetingChunks(for: plan.sessionID)
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("CaptureSessions/\(plan.sessionID.uuidString)/Mixed").path))
    }

    @Test func removingMeetingCaptureArtifactsRemovesSourcesAndMixedChunksIdempotently() throws {
        let (library, plan, root) = try makeFixture(chunkByteCount: 8)
        defer { try? FileManager.default.removeItem(at: root) }
        let microphoneURL = sourceURL(plan, sourceID: plan.microphoneSourceID, sequence: 0)
        let systemAudioURL = sourceURL(plan, sourceID: plan.systemAudioSourceID, sequence: 0)
        try writePCM([0.25, 0.5], to: microphoneURL)
        try writePCM([0.5, 0.25], to: systemAudioURL)
        let inventory = try library.recoverMeetingArtifacts(for: plan).sealedChunks
        let microphone = try #require(inventory.first { $0.sourceID == plan.microphoneSourceID })
        let systemAudio = try #require(inventory.first { $0.sourceID == plan.systemAudioSourceID })
        let mixed = try library.makeMixedMeetingChunk(
            sessionID: plan.sessionID,
            sequence: 0,
            microphone: microphone,
            systemAudio: systemAudio
        )
        let sessionDirectory = root
            .appendingPathComponent("CaptureSessions", isDirectory: true)
            .appendingPathComponent(plan.sessionID.uuidString, isDirectory: true)

        #expect(FileManager.default.fileExists(atPath: microphoneURL.path))
        #expect(FileManager.default.fileExists(atPath: systemAudioURL.path))
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent(mixed.relativePath).path))

        try library.removeMeetingCaptureArtifacts(for: plan.sessionID)
        try library.removeMeetingCaptureArtifacts(for: plan.sessionID)

        #expect(!FileManager.default.fileExists(atPath: sessionDirectory.path))
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("CaptureSessions").path))
    }

    @Test func removingMeetingCaptureArtifactsRejectsSessionDirectorySymlinks() throws {
        let (library, plan, root) = try makeFixture(chunkByteCount: 8)
        defer { try? FileManager.default.removeItem(at: root) }
        let sessionDirectory = root
            .appendingPathComponent("CaptureSessions", isDirectory: true)
            .appendingPathComponent(plan.sessionID.uuidString, isDirectory: true)
        let outsideDirectory = root.deletingLastPathComponent().appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: outsideDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outsideDirectory) }
        let outsideFile = outsideDirectory.appendingPathComponent("preserve.pcm")
        _ = FileManager.default.createFile(atPath: outsideFile.path, contents: Data([0, 1]))
        try FileManager.default.removeItem(at: sessionDirectory)
        try FileManager.default.createSymbolicLink(at: sessionDirectory, withDestinationURL: outsideDirectory)

        #expect(throws: MediaLibraryError.self) {
            try library.removeMeetingCaptureArtifacts(for: plan.sessionID)
        }
        #expect(FileManager.default.fileExists(atPath: outsideFile.path))
    }

    private func makeFixture(chunkByteCount: Int) throws -> (ManagedMediaLibrary, MeetingCaptureSpoolPlan, URL) {
        let root = try makeTemporaryDirectory()
        let plan = MeetingCaptureSpoolPlan(
            libraryRootURL: root,
            sessionID: UUID(),
            microphoneSourceID: UUID(),
            systemAudioSourceID: UUID(),
            chunkByteCount: chunkByteCount
        )
        let library = ManagedMediaLibrary(baseURL: root)
        _ = try library.recoverMeetingArtifacts(for: plan)
        return (library, plan, root)
    }

    private func sourceURL(_ plan: MeetingCaptureSpoolPlan, sourceID: UUID, sequence: Int) -> URL {
        CaptureSourceArtifactPath.sourceURL(
            libraryRootURL: plan.libraryRootURL,
            sessionID: plan.sessionID,
            sourceID: sourceID,
            chunkSequence: sequence
        )
    }

    private func microphoneFor(
        sequence: Int,
        values: [Float32],
        plan: MeetingCaptureSpoolPlan,
        library: ManagedMediaLibrary
    ) throws -> SealedAudioSourceChunk {
        try writePCM(values, to: sourceURL(plan, sourceID: plan.microphoneSourceID, sequence: sequence))
        return try #require(library.recoverMeetingArtifacts(for: plan).sealedChunks.first {
            $0.sourceID == plan.microphoneSourceID && $0.sequence == sequence
        })
    }

    private func writePCM(_ samples: [Float32], to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var data = Data(count: samples.count * MemoryLayout<Float32>.size)
        data.withUnsafeMutableBytes { bytes in
            for (index, sample) in samples.enumerated() {
                bytes.storeBytes(of: sample.bitPattern.littleEndian, toByteOffset: index * 4, as: UInt32.self)
            }
        }
        try data.write(to: url)
    }

    private func readPCM(at url: URL) throws -> [Float32] {
        let data = try Data(contentsOf: url)
        return data.withUnsafeBytes { bytes in
            stride(from: 0, to: bytes.count, by: 4).map {
                Float32(bitPattern: UInt32(littleEndian: bytes.loadUnaligned(fromByteOffset: $0, as: UInt32.self)))
            }
        }
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

private final class FailingMoveFileManager: FileManager, @unchecked Sendable {
    override func fileExists(atPath path: String) -> Bool {
        FileManager.default.fileExists(atPath: path)
    }

    override func createDirectory(
        at url: URL,
        withIntermediateDirectories createIntermediates: Bool,
        attributes: [FileAttributeKey: Any]? = nil
    ) throws {
        try FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: createIntermediates,
            attributes: attributes
        )
    }

    override func attributesOfItem(atPath path: String) throws -> [FileAttributeKey: Any] {
        try FileManager.default.attributesOfItem(atPath: path)
    }

    override func contentsOfDirectory(
        at url: URL,
        includingPropertiesForKeys keys: [URLResourceKey]?,
        options mask: FileManager.DirectoryEnumerationOptions = []
    ) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: keys, options: mask)
    }

    override func removeItem(at URL: URL) throws {
        try FileManager.default.removeItem(at: URL)
    }

    override func moveItem(at srcURL: URL, to dstURL: URL) throws {
        throw CocoaError(.fileWriteUnknown)
    }
}
