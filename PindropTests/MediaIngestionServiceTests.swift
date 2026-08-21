//
//  MediaIngestionServiceTests.swift
//  PindropTests
//
//  macOS process/yt-dlp/ffmpeg adapter coverage. Portable direct-download and
//  managed-library behavior lives in PindropMediaTests.
//

import Foundation
import Testing
import PindropCore
import PindropMedia
@testable import Pindrop

@MainActor
@Suite
struct MediaIngestionServiceTests {
    private let fakeYTDLPPath = "/tmp/pindrop-test-yt-dlp"
    private let fakeFFmpegPath = "/tmp/pindrop-test-ffmpeg"

    @Test func testIngestFileDelegatesToMediaLibrary() async throws {
        let expectedAsset = ManagedMediaAsset(
            directoryURL: URL(fileURLWithPath: "/tmp/job"),
            mediaURL: URL(fileURLWithPath: "/tmp/job/media.mp4"),
            thumbnailURL: nil,
            sourceKind: .importedFile,
            displayName: "media.mp4",
            hasSourceMetadataTitle: false,
            originalSourceURL: nil
        )
        let library = MockMediaLibrary()
        library.importedAsset = expectedAsset
        let sut = MediaIngestionService(
            processRunner: MockProcessRunner(),
            mediaLibrary: library
        )
        let fileURL = URL(fileURLWithPath: "/tmp/source.mov")

        let asset = try await sut.ingest(
            request: .file(fileURL),
            jobID: UUID(),
            progressHandler: { _, _ in }
        )

        #expect(asset == expectedAsset)
        #expect(library.importedSourceURL == fileURL)
    }

    @Test func testStoreCapturePCMFileDelegatesToMediaLibrary() throws {
        let sessionID = UUID()
        let sourceID = UUID()
        let sourceURL = URL(fileURLWithPath: "/tmp/microphone.pcm")
        let expectedArtifact = ManagedCaptureSourceArtifact(
            sessionID: sessionID,
            sourceID: sourceID,
            chunkSequence: 0,
            relativePath: CaptureSourceArtifactPath.relativePath(
                sessionID: sessionID,
                sourceID: sourceID,
                chunkSequence: 0
            ),
            byteCount: 32_768,
            sha256: "deadbeef"
        )
        let library = MockMediaLibrary()
        library.captureSourceArtifact = expectedArtifact
        let sut = MediaIngestionService(
            processRunner: MockProcessRunner(),
            mediaLibrary: library
        )

        let artifact = try sut.storeCapturePCMFile(
            at: sourceURL,
            sessionID: sessionID,
            sourceID: sourceID,
            chunkSequence: 0
        )

        #expect(artifact == expectedArtifact)
        #expect(library.captureSourceURL == sourceURL)
        #expect(library.captureSourceSessionID == sessionID)
        #expect(library.captureSourceID == sourceID)
        #expect(library.captureSourceChunkSequence == 0)
    }

    @Test func testStoreCapturePCMFileAsyncDelegatesToMediaLibrary() async throws {
        let sessionID = UUID()
        let sourceID = UUID()
        let sourceURL = URL(fileURLWithPath: "/tmp/microphone.pcm")
        let expectedArtifact = ManagedCaptureSourceArtifact(
            sessionID: sessionID,
            sourceID: sourceID,
            chunkSequence: 0,
            relativePath: CaptureSourceArtifactPath.relativePath(
                sessionID: sessionID,
                sourceID: sourceID,
                chunkSequence: 0
            ),
            byteCount: 32_768,
            sha256: "deadbeef"
        )
        let library = MockMediaLibrary()
        library.captureSourceArtifact = expectedArtifact
        let sut = MediaIngestionService(
            processRunner: MockProcessRunner(),
            mediaLibrary: library
        )

        let artifact = try await sut.storeCapturePCMFile(
            at: sourceURL,
            sessionID: sessionID,
            sourceID: sourceID,
            chunkSequence: 0
        )

        #expect(artifact == expectedArtifact)
        #expect(library.captureSourceURL == sourceURL)
        #expect(library.captureSourceSessionID == sessionID)
        #expect(library.captureSourceID == sourceID)
        #expect(library.captureSourceChunkSequence == 0)
    }

    @Test func testStoreRecordedAudioAsyncDelegatesToMediaLibrary() async throws {
        let audioData = Data([0, 1, 2, 3])
        let jobID = UUID()
        let library = MockMediaLibrary()
        let sut = MediaIngestionService(
            processRunner: MockProcessRunner(),
            mediaLibrary: library
        )

        let asset = try await sut.storeRecordedAudio(
            audioData,
            jobID: jobID,
            displayName: "Voice recording",
            sourceKind: .voiceRecording
        )

        #expect(library.storedRecordedAudio == audioData)
        #expect(asset.directoryURL == library.directoryURL)
        #expect(asset.mediaURL == library.directoryURL.appendingPathComponent("media.caf"))
        #expect(asset.sourceKind == .voiceRecording)
        #expect(asset.displayName == "Voice recording")
    }


    @Test func testStoreCapturePCMFileWrapsMediaLibraryStorageError() throws {
        let library = MockMediaLibrary()
        library.captureSourceStorageError = .captureSourceStorageFailed("disk full")
        let sut = MediaIngestionService(
            processRunner: MockProcessRunner(),
            mediaLibrary: library
        )

        do {
            _ = try sut.storeCapturePCMFile(
                at: URL(fileURLWithPath: "/tmp/microphone.pcm"),
                sessionID: UUID(),
                sourceID: UUID(),
                chunkSequence: 0
            )
            Issue.record("Expected capture-source storage error")
        } catch let error as MediaIngestionError {
            guard case .captureSourceStorageFailed(let message) = error else {
                Issue.record("Expected capture-source storage error, got \(error)")
                return
            }
            #expect(message == "disk full")
        }
    }

    @Test func testStoreCapturePCMFileAsyncPreservesContentConflict() async throws {
        let sessionID = UUID()
        let sourceID = UUID()
        let relativePath = CaptureSourceArtifactPath.relativePath(
            sessionID: sessionID,
            sourceID: sourceID,
            chunkSequence: 0
        )
        let library = MockMediaLibrary()
        library.captureSourceStorageError = .captureSourceStorageContentConflict(relativePath: relativePath)
        let sut = MediaIngestionService(
            processRunner: MockProcessRunner(),
            mediaLibrary: library
        )

        do {
            _ = try await sut.storeCapturePCMFile(
                at: URL(fileURLWithPath: "/tmp/microphone.pcm"),
                sessionID: sessionID,
                sourceID: sourceID,
                chunkSequence: 0
            )
            Issue.record("Expected capture-source content conflict")
        } catch let error as MediaIngestionError {
            guard case .captureSourceStorageContentConflict(let actualPath) = error else {
                Issue.record("Expected capture-source content conflict, got \(error)")
                return
            }
            #expect(actualPath == relativePath)
        }
    }
    @Test func testIngestLinkThrowsWhenRequiredToolingIsMissing() async throws {
        let processRunner = MockProcessRunner()
        processRunner.responses = [
            .which(tool: "yt-dlp", result: ProcessExecutionResult(terminationStatus: 0, standardOutput: "\(fakeYTDLPPath)\n", standardError: "")),
            .which(tool: "ffmpeg", result: ProcessExecutionResult(terminationStatus: 1, standardOutput: "", standardError: ""))
        ]
        processRunner.expectedYTDLPPath = fakeYTDLPPath
        processRunner.expectedFFmpegPath = fakeFFmpegPath
        let sut = MediaIngestionService(
            processRunner: processRunner,
            mediaLibrary: MockMediaLibrary(),
            toolPathResolver: { _ in nil }
        )

        do {
            _ = try await sut.ingest(
                request: .link("https://example.com/video"),
                jobID: UUID(),
                progressHandler: { _, _ in }
            )
            Issue.record("Expected toolingUnavailable error")
        } catch {
            if case MediaIngestionError.toolingUnavailable(let message) = error {
                #expect(message == "This link requires yt-dlp to download. To transcribe web links, install ffmpeg.")
            } else {
                Issue.record("Expected toolingUnavailable error, got \(error)")
            }
        }
    }
    @Test func testIngestLinkDownloadsMediaAndReportsProgress() async throws {
        let jobID = UUID()
        let directoryURL = FileManager.default.temporaryDirectory.appendingPathComponent(jobID.uuidString, isDirectory: true)
        let finalizedAsset = ManagedMediaAsset(
            directoryURL: directoryURL,
            mediaURL: directoryURL.appendingPathComponent("media.mp4"),
            thumbnailURL: directoryURL.appendingPathComponent("thumbnail.png"),
            sourceKind: .webLink,
            displayName: "Example title",
            hasSourceMetadataTitle: true,
            originalSourceURL: "https://example.com/video"
        )
        let processRunner = MockProcessRunner()
        processRunner.responses = [
            .which(tool: "yt-dlp", result: ProcessExecutionResult(terminationStatus: 0, standardOutput: "\(fakeYTDLPPath)\n", standardError: "")),
            .which(tool: "ffmpeg", result: ProcessExecutionResult(terminationStatus: 0, standardOutput: "\(fakeFFmpegPath)\n", standardError: "")),
            .metadata(
                url: "https://example.com/video",
                result: ProcessExecutionResult(
                    terminationStatus: 0,
                    standardOutput: #"{"title":"Example title","webpage_url":"https://example.com/video"}"#,
                    standardError: ""
                )
            ),
            .download(
                url: "https://example.com/video",
                result: ProcessExecutionResult(terminationStatus: 0, standardOutput: "", standardError: ""),
                emittedLines: [
                    "[download] Destination: media.mp4",
                    "[download] 42.0% of 10.00MiB at 1.00MiB/s ETA 00:06"
                ]
            )
        ]
        processRunner.expectedYTDLPPath = fakeYTDLPPath
        processRunner.expectedFFmpegPath = fakeFFmpegPath
        let library = MockMediaLibrary()
        library.directoryURL = directoryURL
        library.finalizedAsset = finalizedAsset
        let sut = MediaIngestionService(
            processRunner: processRunner,
            mediaLibrary: library,
            toolPathResolver: { _ in nil }
        )
        var reportedProgress: [(Double?, String)] = []

        let asset = try await sut.ingest(
            request: .link("https://example.com/video"),
            jobID: jobID,
            progressHandler: { progress, detail in
                reportedProgress.append((progress, detail))
            }
        )

        #expect(asset == finalizedAsset)
        #expect(library.makeJobDirectoryCallCount == 1)
        #expect(library.finalizeDirectoryURL == directoryURL)
        #expect(library.finalizeSourceURL == "https://example.com/video")
        #expect(library.finalizeSuggestedTitle == "Example title")
        #expect(reportedProgress.contains(where: { $0.1 == "Preparing download" }))
        #expect(reportedProgress.contains(where: { ($0.0 ?? 0) == 0.42 && $0.1 == "Downloading media" }))
    }
    @Test func testIngestYouTubeLinkRetriesWithCompatibilityFallbackAfter403() async throws {
        let jobID = UUID()
        let youtubeURL = "https://www.youtube.com/watch?v=abc123"
        let directoryURL = FileManager.default.temporaryDirectory.appendingPathComponent(jobID.uuidString, isDirectory: true)
        let finalizedAsset = ManagedMediaAsset(
            directoryURL: directoryURL,
            mediaURL: directoryURL.appendingPathComponent("media.mp4"),
            thumbnailURL: directoryURL.appendingPathComponent("thumbnail.png"),
            sourceKind: .webLink,
            displayName: "Example video",
            hasSourceMetadataTitle: true,
            originalSourceURL: youtubeURL
        )

        let processRunner = MockProcessRunner()
        processRunner.responses = [
            .which(tool: "yt-dlp", result: ProcessExecutionResult(terminationStatus: 0, standardOutput: "\(fakeYTDLPPath)\n", standardError: "")),
            .which(tool: "ffmpeg", result: ProcessExecutionResult(terminationStatus: 0, standardOutput: "\(fakeFFmpegPath)\n", standardError: "")),
            .metadata(
                url: youtubeURL,
                result: ProcessExecutionResult(
                    terminationStatus: 0,
                    standardOutput: #"{"title":"Example video","webpage_url":"https://www.youtube.com/watch?v=abc123"}"#,
                    standardError: ""
                )
            ),
            .download(
                url: youtubeURL,
                strategy: .standard,
                result: ProcessExecutionResult(
                    terminationStatus: 1,
                    standardOutput: "",
                    standardError: "ERROR: unable to download video data: HTTP Error 403: Forbidden\nWARNING: Some web client https formats have been skipped as they are missing a url."
                ),
                emittedLines: []
            ),
            .download(
                url: youtubeURL,
                strategy: .youtubeCompatibility,
                result: ProcessExecutionResult(terminationStatus: 0, standardOutput: "", standardError: ""),
                emittedLines: [
                    "[download] Destination: media.mp4"
                ]
            )
        ]
        processRunner.expectedYTDLPPath = fakeYTDLPPath
        processRunner.expectedFFmpegPath = fakeFFmpegPath

        let library = MockMediaLibrary()
        library.directoryURL = directoryURL
        library.finalizedAsset = finalizedAsset

        let sut = MediaIngestionService(
            processRunner: processRunner,
            mediaLibrary: library,
            toolPathResolver: { _ in nil }
        )

        let asset = try await sut.ingest(
            request: .link(youtubeURL),
            jobID: jobID,
            progressHandler: { _, _ in }
        )

        #expect(asset == finalizedAsset)
        #expect(library.finalizeSourceURL == youtubeURL)
        #expect(library.finalizeSuggestedTitle == "Example video")
    }
}

private final class MockMediaLibrary: MediaLibraryManaging, @unchecked Sendable {
    var importedSourceURL: URL?
    var importedAsset = ManagedMediaAsset(
        directoryURL: URL(fileURLWithPath: "/tmp/job"),
        mediaURL: URL(fileURLWithPath: "/tmp/job/media.mp4"),
        thumbnailURL: nil,
        sourceKind: .importedFile,
        displayName: "media.mp4",
        hasSourceMetadataTitle: false,
        originalSourceURL: nil
    )
    var directoryURL = URL(fileURLWithPath: "/tmp/job", isDirectory: true)
    var finalizedAsset = ManagedMediaAsset(
        directoryURL: URL(fileURLWithPath: "/tmp/job"),
        mediaURL: URL(fileURLWithPath: "/tmp/job/media.mp4"),
        thumbnailURL: nil,
        sourceKind: .webLink,
        displayName: "media.mp4",
        hasSourceMetadataTitle: false,
        originalSourceURL: nil
    )
    var storedRecordedAudio: Data?
    var makeJobDirectoryCallCount = 0
    var finalizeDirectoryURL: URL?
    var finalizeSourceURL: String?
    var finalizeSuggestedTitle: String?
    var captureSourceURL: URL?
    var captureSourceSessionID: UUID?
    var captureSourceID: UUID?
    var captureSourceChunkSequence: Int?
    var captureSourceStorageError: MediaLibraryError?
    var captureSourceArtifact = ManagedCaptureSourceArtifact(
        sessionID: UUID(),
        sourceID: UUID(),
        chunkSequence: 0,
        relativePath: "CaptureSessions/test/Sources/test/chunk-00000.pcm",
        byteCount: 0,
        sha256: ""
    )


    func makeJobDirectory(for jobID: UUID) throws -> URL {
        makeJobDirectoryCallCount += 1
        return directoryURL
    }

    func importLocalFile(at sourceURL: URL, jobID: UUID) async throws -> ManagedMediaAsset {
        importedSourceURL = sourceURL
        return importedAsset
    }

    func storeRecordedAudio(
        _ audioData: Data,
        jobID: UUID,
        displayName: String,
        sourceKind: MediaSourceKind
    ) throws -> ManagedMediaAsset {
        storedRecordedAudio = audioData
        return ManagedMediaAsset(
            directoryURL: directoryURL,
            mediaURL: directoryURL.appendingPathComponent("media.caf"),
            thumbnailURL: nil,
            sourceKind: sourceKind,
            displayName: displayName,
            hasSourceMetadataTitle: false,
            originalSourceURL: nil
        )
    }
    func storeCapturePCMFile(
        at sourceURL: URL,
        sessionID: UUID,
        sourceID: UUID,
        chunkSequence: Int
    ) throws -> ManagedCaptureSourceArtifact {
        if let captureSourceStorageError {
            throw captureSourceStorageError
        }
        captureSourceURL = sourceURL
        captureSourceSessionID = sessionID
        captureSourceID = sourceID
        captureSourceChunkSequence = chunkSequence
        return captureSourceArtifact
    }

    func finalizeDownloadedAsset(
        in directoryURL: URL,
        sourceURL: String,
        suggestedTitle: String?
    ) async throws -> ManagedMediaAsset {
        finalizeDirectoryURL = directoryURL
        finalizeSourceURL = sourceURL
        finalizeSuggestedTitle = suggestedTitle
        return finalizedAsset
    }
}

private final class MockProcessRunner: ProcessRunning, @unchecked Sendable {
    enum DownloadStrategy {
        case standard
        case youtubeCompatibility
    }

    enum Response {
        case which(tool: String, result: ProcessExecutionResult)
        case metadata(url: String, result: ProcessExecutionResult)
        case download(url: String, strategy: DownloadStrategy = .standard, result: ProcessExecutionResult, emittedLines: [String])
    }

    private let lock = NSLock()
    private var _responses: [Response] = []
    var expectedYTDLPPath = "/tmp/pindrop-test-yt-dlp"
    var expectedFFmpegPath = "/tmp/pindrop-test-ffmpeg"

    /// Thread-safe response queue. Set from tests before concurrent `run` calls.
    var responses: [Response] {
        get {
            lock.lock()
            defer { lock.unlock() }
            return _responses
        }
        set {
            lock.lock()
            defer { lock.unlock() }
            _responses = newValue
        }
    }

    /// Match + dequeue under lock so concurrent tool probes cannot race `remove(at:)`.
    private func dequeueMatchingResponse(
        executableURL: URL,
        arguments: [String]
    ) -> Response? {
        lock.lock()
        defer { lock.unlock() }
        guard let responseIndex = _responses.firstIndex(where: { response in
            matches(response: response, executableURL: executableURL, arguments: arguments)
        }) else {
            return nil
        }
        return _responses.remove(at: responseIndex)
    }


    func run(
        executableURL: URL,
        arguments: [String],
        currentDirectoryURL: URL?,
        environment: [String : String]?,
        lineHandler: (@Sendable (String) -> Void)?
    ) async throws -> ProcessExecutionResult {
        guard let response = dequeueMatchingResponse(
            executableURL: executableURL,
            arguments: arguments
        ) else {
            Issue.record("Unexpected process invocation: \(executableURL.path) \(arguments.joined(separator: " "))")
            return ProcessExecutionResult(terminationStatus: 1, standardOutput: "", standardError: "Unexpected process call")
        }

        switch response {
        case .which(let tool, let result):
            #expect(executableURL.path == "/usr/bin/which")
            #expect(arguments == [tool])
            #expect(environment?["PATH"] != nil)
            return result

        case .metadata(let url, let result):
            #expect(executableURL.path == expectedYTDLPPath)
            #expect(arguments == [
                "--dump-single-json",
                "--no-playlist",
                "--ffmpeg-location", URL(fileURLWithPath: expectedFFmpegPath).deletingLastPathComponent().path,
                url
            ])
            #expect(environment?["PATH"]?.contains(URL(fileURLWithPath: expectedFFmpegPath).deletingLastPathComponent().path) == true)
            return result

        case .download(let url, let strategy, let result, let emittedLines):
            #expect(executableURL.path == expectedYTDLPPath)
            #expect(arguments == expectedDownloadArguments(for: url, strategy: strategy))
            #expect(environment?["PATH"]?.contains(URL(fileURLWithPath: expectedFFmpegPath).deletingLastPathComponent().path) == true)
            emittedLines.forEach { lineHandler?($0) }
            return result
        }
    }

    private func matches(response: Response, executableURL: URL, arguments: [String]) -> Bool {
        switch response {
        case .which(let tool, _):
            return executableURL.path == "/usr/bin/which" && arguments == [tool]
        case .metadata(let url, _):
            return executableURL.path == expectedYTDLPPath
                && arguments == [
                    "--dump-single-json",
                    "--no-playlist",
                    "--ffmpeg-location", URL(fileURLWithPath: expectedFFmpegPath).deletingLastPathComponent().path,
                    url
                ]
        case .download(let url, let strategy, _, _):
            return executableURL.path == expectedYTDLPPath
                && arguments == expectedDownloadArguments(for: url, strategy: strategy)
        }
    }

    private func expectedDownloadArguments(for url: String, strategy: DownloadStrategy) -> [String] {
        let ffmpegDirectory = URL(fileURLWithPath: expectedFFmpegPath).deletingLastPathComponent().path

        switch strategy {
        case .standard:
            return [
                "--no-playlist",
                "--newline",
                "--progress",
                "--format", "bestvideo*+bestaudio/best",
                "--merge-output-format", "mp4",
                "--ffmpeg-location", ffmpegDirectory,
                "--write-thumbnail",
                "--convert-thumbnails", "png",
                "-o", "media.%(ext)s",
                url
            ]
        case .youtubeCompatibility:
            return [
                "--no-playlist",
                "--newline",
                "--progress",
                "--extractor-args", "youtube:player_client=default,-web,-web_safari,-web_creator",
                "--format", "best[ext=mp4]/best",
                "--ffmpeg-location", ffmpegDirectory,
                "--write-thumbnail",
                "--convert-thumbnails", "png",
                "-o", "media.%(ext)s",
                url
            ]
        }
    }
}
