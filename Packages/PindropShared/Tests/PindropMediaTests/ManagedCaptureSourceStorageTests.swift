//
//  ManagedCaptureSourceStorageTests.swift
//  PindropMediaTests
//

import CryptoKit
import Foundation
import PindropCore
import Testing
@testable import PindropMedia

@Suite
struct ManagedCaptureSourceStorageTests {
    @Test func testStoresLargePCMFileAtDeterministicPathWithoutConsumingInput() throws {
        let directoryURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directoryURL) }

        let sourceURL = directoryURL.appendingPathComponent("source.pcm")
        let expectedByteCount = try writeLargePCMFile(at: sourceURL)
        let expectedSHA256 = try sha256(of: sourceURL)
        let sessionID = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
        let sourceID = UUID(uuidString: "22222222-2222-4222-8222-222222222222")!
        let libraryRootURL = directoryURL.appendingPathComponent("MediaLibrary", isDirectory: true)
        let library = ManagedMediaLibrary(baseURL: libraryRootURL)

        let artifact = try library.storeCapturePCMFile(
            at: sourceURL,
            sessionID: sessionID,
            sourceID: sourceID,
            chunkSequence: 0
        )
        let destinationURL = library.captureSourceURL(for: artifact)
        let expectedRelativePath = CaptureSourceArtifactPath.relativePath(
            sessionID: sessionID,
            sourceID: sourceID,
            chunkSequence: 0
        )

        #expect(artifact.sessionID == sessionID)
        #expect(artifact.sourceID == sourceID)
        #expect(artifact.chunkSequence == 0)
        #expect(artifact.relativePath == expectedRelativePath)
        #expect(artifact.managedMediaPath == expectedRelativePath)
        #expect(artifact.byteCount == expectedByteCount)
        #expect(artifact.sha256 == expectedSHA256)
        #expect(FileManager.default.fileExists(atPath: destinationURL.path))
        #expect(try partialFiles(in: libraryRootURL).isEmpty)
        #expect(FileManager.default.fileExists(atPath: sourceURL.path))
        #expect(try sha256(of: destinationURL) == expectedSHA256)

        let retriedArtifact = try library.storeCapturePCMFile(
            at: sourceURL,
            sessionID: sessionID,
            sourceID: sourceID,
            chunkSequence: 0
        )

        #expect(retriedArtifact == artifact)
        #expect(FileManager.default.fileExists(atPath: sourceURL.path))
        #expect(try partialFiles(in: libraryRootURL).isEmpty)
    }

    @Test func testRejectsDifferentContentForExistingCaptureSourceArtifact() throws {
        let directoryURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directoryURL) }

        let firstSourceURL = directoryURL.appendingPathComponent("first.pcm")
        let secondSourceURL = directoryURL.appendingPathComponent("second.pcm")
        let firstByteCount = try writePCMFile(at: firstSourceURL, bytes: [0, 1, 2, 3])
        _ = try writePCMFile(at: secondSourceURL, bytes: [4, 5, 6, 7])
        let sessionID = UUID()
        let sourceID = UUID()
        let libraryRootURL = directoryURL.appendingPathComponent("MediaLibrary", isDirectory: true)
        let library = ManagedMediaLibrary(baseURL: libraryRootURL)

        let originalArtifact = try library.storeCapturePCMFile(
            at: firstSourceURL,
            sessionID: sessionID,
            sourceID: sourceID,
            chunkSequence: 0
        )

        do {
            _ = try library.storeCapturePCMFile(
                at: secondSourceURL,
                sessionID: sessionID,
                sourceID: sourceID,
                chunkSequence: 0
            )
            Issue.record("Expected a capture-source content conflict")
        } catch let error as MediaLibraryError {
            guard case .captureSourceStorageContentConflict(let relativePath) = error else {
                Issue.record("Expected a capture-source content conflict, got \(error)")
                return
            }
            #expect(relativePath == originalArtifact.relativePath)
        }

        let destinationURL = library.captureSourceURL(for: originalArtifact)
        #expect(try sha256(of: destinationURL) == originalArtifact.sha256)
        #expect(try fileByteCount(at: destinationURL) == firstByteCount)
        #expect(FileManager.default.fileExists(atPath: firstSourceURL.path))
        #expect(FileManager.default.fileExists(atPath: secondSourceURL.path))
        #expect(try partialFiles(in: libraryRootURL).isEmpty)
    }

    @Test func testConcurrentSameKeyCallsReturnIdenticalDestinationMetadata() async throws {
        let directoryURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directoryURL) }

        let sourceURL = directoryURL.appendingPathComponent("source.pcm")
        _ = try writeLargePCMFile(at: sourceURL)
        let sessionID = UUID()
        let sourceID = UUID()
        let libraryRootURL = directoryURL.appendingPathComponent("MediaLibrary", isDirectory: true)
        let library = ManagedMediaLibrary(baseURL: libraryRootURL)

        let artifacts = try await withThrowingTaskGroup(of: ManagedCaptureSourceArtifact.self) { group in
            for _ in 0..<2 {
                group.addTask {
                    try library.storeCapturePCMFile(
                        at: sourceURL,
                        sessionID: sessionID,
                        sourceID: sourceID,
                        chunkSequence: 0
                    )
                }
            }

            var artifacts: [ManagedCaptureSourceArtifact] = []
            for try await artifact in group {
                artifacts.append(artifact)
            }
            return artifacts
        }

        #expect(artifacts.count == 2)
        #expect(artifacts[0] == artifacts[1])
        let destinationURL = library.captureSourceURL(for: artifacts[0])
        #expect(try fileByteCount(at: destinationURL) == artifacts[0].byteCount)
        #expect(try sha256(of: destinationURL) == artifacts[0].sha256)
        #expect(FileManager.default.fileExists(atPath: sourceURL.path))
        #expect(try partialFiles(in: libraryRootURL).isEmpty)
    }

    @Test func testCleansPartialFileWhenAtomicRenameFails() throws {
        let directoryURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directoryURL) }

        let sourceURL = directoryURL.appendingPathComponent("source.pcm")
        _ = try writeLargePCMFile(at: sourceURL)
        let sessionID = UUID(uuidString: "33333333-3333-4333-8333-333333333333")!
        let sourceID = UUID(uuidString: "44444444-4444-4444-8444-444444444444")!
        let libraryRootURL = directoryURL.appendingPathComponent("MediaLibrary", isDirectory: true)
        let fileManager = RenameFailingFileManager()
        let library = ManagedMediaLibrary(baseURL: libraryRootURL, fileManager: fileManager)
        let destinationURL = libraryRootURL.appendingPathComponent(
            CaptureSourceArtifactPath.relativePath(
                sessionID: sessionID,
                sourceID: sourceID,
                chunkSequence: 0
            )
        )
        do {
            _ = try library.storeCapturePCMFile(
                at: sourceURL,
                sessionID: sessionID,
                sourceID: sourceID,
                chunkSequence: 0
            )
            Issue.record("Expected source storage to fail during final rename")
        } catch let error as MediaLibraryError {
            guard case .captureSourceStorageFailed = error else {
                Issue.record("Expected capture-source storage failure, got \(error)")
                return
            }
        }

        #expect(FileManager.default.fileExists(atPath: sourceURL.path))
        #expect(!FileManager.default.fileExists(atPath: destinationURL.path))
        #expect(try partialFiles(in: libraryRootURL).isEmpty)
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        return directoryURL
    }

    private func writeLargePCMFile(at url: URL) throws -> Int64 {
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }

        var byteCount: Int64 = 0
        for byte in UInt8.min...UInt8.max {
            let block = Data(repeating: byte, count: 65_537)
            try handle.write(contentsOf: block)
            byteCount += Int64(block.count)
        }
        try handle.close()
        return byteCount
    }

    private func writePCMFile(at url: URL, bytes: [UInt8]) throws -> Int64 {
        let data = Data(bytes)
        guard FileManager.default.createFile(atPath: url.path, contents: data) else {
            throw CocoaError(.fileWriteUnknown)
        }
        return Int64(data.count)
    }

    private func fileByteCount(at url: URL) throws -> Int64 {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        var byteCount: Int64 = 0
        while let data = try handle.read(upToCount: 64 * 1024), !data.isEmpty {
            byteCount += Int64(data.count)
        }
        return byteCount
    }

    private func partialFiles(in directoryURL: URL) throws -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: directoryURL,
            includingPropertiesForKeys: nil
        ) else {
            return []
        }

        return enumerator.compactMap { $0 as? URL }
            .filter { $0.lastPathComponent.contains(".partial") }
    }

    private func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        var hasher = SHA256()
        while let data = try handle.read(upToCount: 64 * 1024), !data.isEmpty {
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

private final class RenameFailingFileManager: FileManager, @unchecked Sendable {
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

    override func removeItem(at url: URL) throws {
        try FileManager.default.removeItem(at: url)
    }

    override func moveItem(at srcURL: URL, to dstURL: URL) throws {
        throw CocoaError(.fileWriteUnknown)
    }
}
