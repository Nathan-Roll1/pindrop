//
//  MediaIngestionServiceTests.swift
//  PindropMediaTests
//
//  Portable direct-download and managed-library coverage.
//  yt-dlp/ffmpeg/Process adapter cases remain in PindropTests.
//

import Foundation
import Testing
import PindropCore
@testable import PindropMedia

@MainActor
@Suite
struct MediaIngestionPortableTests {
    @Test func testDirectDownloadDelegateRetainsImmediateSuccess() async throws {
        let sourceURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("mp3")
        try Data("audio-data".utf8).write(to: sourceURL)

        let delegate = DirectDownloadDelegate(onProgress: { _, _ in })
        let session = URLSession(configuration: .ephemeral)
        let task = session.downloadTask(with: URL(string: "https://example.com/audio.mp3")!)
        defer { session.invalidateAndCancel() }

        delegate.urlSession(session, downloadTask: task, didFinishDownloadingTo: sourceURL)

        var didStart = false
        let downloadedURL = try await delegate.waitForCompletion {
            didStart = true
        }

        #expect(!didStart)
        #expect(try Data(contentsOf: downloadedURL) == Data("audio-data".utf8))
        try? FileManager.default.removeItem(at: downloadedURL)
    }

    @Test func testDirectDownloadDelegateRetainsImmediateFailure() async {
        let delegate = DirectDownloadDelegate(onProgress: { _, _ in })
        let session = URLSession(configuration: .ephemeral)
        let task = session.downloadTask(with: URL(string: "https://example.com/audio.mp3")!)
        defer { session.invalidateAndCancel() }

        delegate.urlSession(session, task: task, didCompleteWithError: URLError(.cannotConnectToHost))

        var didStart = false
        do {
            _ = try await delegate.waitForCompletion {
                didStart = true
            }
            Issue.record("Expected immediate download failure")
        } catch let error as URLError {
            #expect(error.code == .cannotConnectToHost)
        } catch {
            Issue.record("Expected URLError, got \(error)")
        }
        #expect(!didStart)
    }

    @Test func testDirectDownloadDelegateRetainsCancellation() async {
        let delegate = DirectDownloadDelegate(onProgress: { _, _ in })
        delegate.cancel()

        var didStart = false
        do {
            _ = try await delegate.waitForCompletion {
                didStart = true
            }
            Issue.record("Expected cancellation")
        } catch is CancellationError {
            #expect(!didStart)
        } catch {
            Issue.record("Expected CancellationError, got \(error)")
        }
    }

    @Test func testDirectDownloadDelegateRemovesTempFileWhenCancellationWins() throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        let sourceURL = temporaryDirectory.appendingPathComponent("download.mp3")
        try Data("audio-data".utf8).write(to: sourceURL)

        let delegate = DirectDownloadDelegate(temporaryDirectory: temporaryDirectory, onProgress: { _, _ in })
        let session = URLSession(configuration: .ephemeral)
        let task = session.downloadTask(with: URL(string: "https://example.com/audio.mp3")!)
        defer { session.invalidateAndCancel() }

        delegate.cancel()
        delegate.urlSession(session, downloadTask: task, didFinishDownloadingTo: sourceURL)

        #expect(try FileManager.default.contentsOfDirectory(atPath: temporaryDirectory.path).isEmpty)
    }

    @Test func testImportLocalFileCopiesIntoManagedLibrary() async throws {
        let baseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("pindrop-media-lib-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: baseURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: baseURL) }

        let sourceURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("mp3")
        try Data("audio-data".utf8).write(to: sourceURL)
        defer { try? FileManager.default.removeItem(at: sourceURL) }

        let library = ManagedMediaLibrary(baseURL: baseURL)
        let asset = try await library.importLocalFile(at: sourceURL, jobID: UUID())

        #expect(asset.sourceKind == .importedFile)
        #expect(asset.displayName == sourceURL.lastPathComponent)
        #expect(FileManager.default.fileExists(atPath: asset.mediaURL.path))
        #expect(try Data(contentsOf: asset.mediaURL) == Data("audio-data".utf8))
        #expect(asset.directoryURL.path.hasPrefix(baseURL.path))
        #expect(!baseURL.path.contains("Application Support"))
    }

    @Test func managedLibraryUsesInjectedBaseURLNotApplicationSupport() throws {
        let baseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("pindrop-media-root-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: baseURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: baseURL) }

        let library = ManagedMediaLibrary(baseURL: baseURL)
        let jobID = UUID()
        let directory = try library.makeJobDirectory(for: jobID)

        #expect(directory.path.hasPrefix(baseURL.path))
        #expect(directory.lastPathComponent == jobID.uuidString)
        #expect(!directory.path.contains("Application Support"))
        #expect(library.dictationAudioDirectoryURL.path == baseURL.appendingPathComponent("DictationAudio").path)
    }
}
