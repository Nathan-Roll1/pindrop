//
//  MediaIngestionService.swift
//  Pindrop
//
//  macOS-only external-tool media ingestion. Shared storage, local import,
//  recorded-audio write, and direct HTTP download live in PindropMedia.
//

import Foundation
import PindropCore
import PindropMedia

// MARK: - Tooling / process contracts (macOS)

struct MediaToolingStatus: Equatable, Sendable {
    let ytDLPPath: String?
    let ffmpegPath: String?

    var isReady: Bool {
        ytDLPPath != nil && ffmpegPath != nil
    }

    var missingToolsDescription: String {
        let missing = [
            ytDLPPath == nil ? "yt-dlp" : nil,
            ffmpegPath == nil ? "ffmpeg" : nil
        ]
        .compactMap { $0 }
        .joined(separator: ", ")

        return "To transcribe web links, install \(missing)."
    }
}

private struct ResolvedMediaTooling: Equatable, Sendable {
    let ytDLPURL: URL
    let ffmpegURL: URL
}

struct ProcessExecutionResult: Sendable {
    let terminationStatus: Int32
    let standardOutput: String
    let standardError: String
}

protocol ProcessRunning: Sendable {
    func run(
        executableURL: URL,
        arguments: [String],
        currentDirectoryURL: URL?,
        environment: [String: String]?,
        lineHandler: (@Sendable (String) -> Void)?
    ) async throws -> ProcessExecutionResult
}

enum MediaIngestionError: Error, LocalizedError {
    case unsupportedInput(String)
    case toolingUnavailable(String)
    case downloadFailed(String)
    case localFileImportFailed(String)
    case downloadedMediaMissing
    case metadataLookupFailed(String)
    case captureSourceStorageFailed(String)
    case captureSourceStorageUnsupported
    case captureSourceStorageContentConflict(String)
    var errorDescription: String? {
        switch self {
        case .unsupportedInput(let message):
            return "Unsupported media input: \(message)"
        case .toolingUnavailable(let message):
            return message
        case .downloadFailed(let message):
            return "Media download failed: \(message)"
        case .localFileImportFailed(let message):
            return "Media import failed: \(message)"
        case .downloadedMediaMissing:
            return "Download finished but no playable media file was found."
        case .metadataLookupFailed(let message):
            return "Failed to inspect media link: \(message)"
        case .captureSourceStorageFailed(let message):
            return "Capture source storage failed: \(message)"
        case .captureSourceStorageUnsupported:
            return "Capture source storage is not supported by this media library."
        case .captureSourceStorageContentConflict(let relativePath):
            return "Capture source storage content conflicts with the existing artifact at \(relativePath)."
    }
    }


    /// Maps package storage/download errors into the app-facing ingestion surface.
    static func fromMediaLibraryError(_ error: MediaLibraryError) -> MediaIngestionError {
        switch error {
        case .localFileImportFailed(let message):
            return .localFileImportFailed(message)
        case .downloadedMediaMissing:
            return .downloadedMediaMissing
        case .downloadFailed(let message):
            return .downloadFailed(message)
        case .captureSourceStorageUnsupported:
            return .captureSourceStorageUnsupported
        case .captureSourceStorageContentConflict(let relativePath):
            return .captureSourceStorageContentConflict(relativePath)
        case .captureSourceStorageFailed(let message):
            return .captureSourceStorageFailed(message)
        }
    }
}

private final class ProcessOutputCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var stdoutData = Data()
    private var stderrData = Data()
    private var stdoutRemainder = ""
    private var stderrRemainder = ""
    private let lineHandler: (@Sendable (String) -> Void)?

    init(lineHandler: (@Sendable (String) -> Void)?) {
        self.lineHandler = lineHandler
    }

    func appendStdout(_ data: Data) {
        append(data, isStdout: true)
    }

    func appendStderr(_ data: Data) {
        append(data, isStdout: false)
    }

    func consumeStdoutRemainder() {
        flushRemainder(isStdout: true)
    }

    func consumeStderrRemainder() {
        flushRemainder(isStdout: false)
    }

    func result(terminationStatus: Int32) -> ProcessExecutionResult {
        lock.lock()
        defer { lock.unlock() }
        return ProcessExecutionResult(
            terminationStatus: terminationStatus,
            standardOutput: String(data: stdoutData, encoding: .utf8) ?? "",
            standardError: String(data: stderrData, encoding: .utf8) ?? ""
        )
    }

    private func append(_ data: Data, isStdout: Bool) {
        guard !data.isEmpty else { return }

        lock.lock()
        defer { lock.unlock() }

        if isStdout {
            stdoutData.append(data)
        } else {
            stderrData.append(data)
        }

        let string = String(data: data, encoding: .utf8) ?? ""
        if isStdout {
            stdoutRemainder += string
            emitCompleteLines(from: &stdoutRemainder)
        } else {
            stderrRemainder += string
            emitCompleteLines(from: &stderrRemainder)
        }
    }

    private func flushRemainder(isStdout: Bool) {
        lock.lock()
        defer { lock.unlock() }

        if isStdout, !stdoutRemainder.isEmpty {
            lineHandler?(stdoutRemainder)
            stdoutRemainder = ""
        } else if !isStdout, !stderrRemainder.isEmpty {
            lineHandler?(stderrRemainder)
            stderrRemainder = ""
        }
    }

    private func emitCompleteLines(from remainder: inout String) {
        while let newlineRange = remainder.range(of: "\n") {
            let line = String(remainder[..<newlineRange.lowerBound])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !line.isEmpty {
                lineHandler?(line)
            }
            remainder.removeSubrange(...newlineRange.lowerBound)
        }
    }
}

struct DefaultProcessRunner: ProcessRunning {
    func run(
        executableURL: URL,
        arguments: [String],
        currentDirectoryURL: URL? = nil,
        environment: [String: String]? = nil,
        lineHandler: (@Sendable (String) -> Void)? = nil
    ) async throws -> ProcessExecutionResult {
        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        process.currentDirectoryURL = currentDirectoryURL
        process.environment = environment

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let collector = ProcessOutputCollector(lineHandler: lineHandler)
        stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            collector.appendStdout(data)
        }
        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            collector.appendStderr(data)
        }

        return try await withTaskCancellationHandler(operation: {
            try process.run()
            let status = await withCheckedContinuation { continuation in
                process.terminationHandler = { finishedProcess in
                    continuation.resume(returning: finishedProcess.terminationStatus)
                }
            }

            stdoutPipe.fileHandleForReading.readabilityHandler = nil
            stderrPipe.fileHandleForReading.readabilityHandler = nil

            collector.appendStdout(stdoutPipe.fileHandleForReading.readDataToEndOfFile())
            collector.appendStderr(stderrPipe.fileHandleForReading.readDataToEndOfFile())
            collector.consumeStdoutRemainder()
            collector.consumeStderrRemainder()

            return collector.result(terminationStatus: status)
        }, onCancel: {
            if process.isRunning {
                process.terminate()
            }
        })
    }
}

private struct YTDLPMetadata: Decodable {
    let title: String?
    let webpageURL: String?

    private enum CodingKeys: String, CodingKey {
        case title
        case webpageURL = "webpage_url"
    }
}

private struct MediaDownloadAttempt {
    let format: String
    let extractorArgs: String?
    let mergeOutputFormat: String?
    let logLabel: String
}

// MARK: - MediaIngestionService

@MainActor
final class MediaIngestionService {
    /// Preserved on-disk root: Application Support/Pindrop/MediaLibrary.
    static var defaultMediaLibraryBaseURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Pindrop", isDirectory: true)
            .appendingPathComponent("MediaLibrary", isDirectory: true)
    }

    private let processRunner: any ProcessRunning
    private let mediaLibrary: any MediaLibraryManaging
    private let directDownloader: DirectMediaDownloader
    private let toolPathResolver: (String) -> String?

    init(
        processRunner: any ProcessRunning = DefaultProcessRunner(),
        mediaLibrary: (any MediaLibraryManaging)? = nil,
        directDownloader: DirectMediaDownloader? = nil,
        toolPathResolver: @escaping (String) -> String? = MediaIngestionService.defaultDirectToolPath(named:)
    ) {
        let resolvedLibrary = mediaLibrary
            ?? ManagedMediaLibrary(baseURL: Self.defaultMediaLibraryBaseURL)
        self.processRunner = processRunner
        self.mediaLibrary = resolvedLibrary
        self.directDownloader = directDownloader
            ?? DirectMediaDownloader(mediaLibrary: resolvedLibrary)
        self.toolPathResolver = toolPathResolver
    }

    func checkTooling() async -> MediaToolingStatus {
        async let ytDLPPath = locateTool(named: "yt-dlp")
        async let ffmpegPath = locateTool(named: "ffmpeg")

        let status = await MediaToolingStatus(
            ytDLPPath: ytDLPPath,
            ffmpegPath: ffmpegPath
        )

        Log.app.info(
            "Media tooling check completed. yt-dlp=\(status.ytDLPPath ?? "missing"), " +
            "ffmpeg=\(status.ffmpegPath ?? "missing"), searchPath=\(Self.toolSearchPath)"
        )

        return status
    }

    func storeRecordedAudio(
        _ audioData: Data,
        jobID: UUID,
        displayName: String,
        sourceKind: MediaSourceKind
    ) async throws -> ManagedMediaAsset {
        let mediaLibrary = mediaLibrary

        do {
            return try await Task.detached {
                try mediaLibrary.storeRecordedAudio(
                    audioData,
                    jobID: jobID,
                    displayName: displayName,
                    sourceKind: sourceKind
                )
            }.value
        } catch let error as MediaLibraryError {
            throw MediaIngestionError.fromMediaLibraryError(error)
        }
    }

    func storeRecordedAudio(
        _ audioData: Data,
        jobID: UUID,
        displayName: String,
        sourceKind: MediaSourceKind
    ) throws -> ManagedMediaAsset {
        do {
            return try mediaLibrary.storeRecordedAudio(
                audioData,
                jobID: jobID,
                displayName: displayName,
                sourceKind: sourceKind
            )
        } catch let error as MediaLibraryError {
            throw MediaIngestionError.fromMediaLibraryError(error)
        }
    }

    func storeCapturePCMFile(
        at sourceURL: URL,
        sessionID: UUID,
        sourceID: UUID,
        chunkSequence: Int
    ) async throws -> ManagedCaptureSourceArtifact {
        let mediaLibrary = mediaLibrary

        do {
            return try await Task.detached {
                try mediaLibrary.storeCapturePCMFile(
                    at: sourceURL,
                    sessionID: sessionID,
                    sourceID: sourceID,
                    chunkSequence: chunkSequence
                )
            }.value
        } catch let error as MediaLibraryError {
            throw MediaIngestionError.fromMediaLibraryError(error)
        }
    }

    func makeMeetingCaptureSpoolPlan(
        sessionID: UUID,
        microphoneSourceID: UUID,
        systemAudioSourceID: UUID
    ) async throws -> MeetingCaptureSpoolPlan {
        let mediaLibrary = mediaLibrary

        do {
            return try await Task.detached {
                try mediaLibrary.makeMeetingCaptureSpoolPlan(
                    sessionID: sessionID,
                    microphoneSourceID: microphoneSourceID,
                    systemAudioSourceID: systemAudioSourceID
                )
            }.value
        } catch let error as MediaLibraryError {
            throw MediaIngestionError.fromMediaLibraryError(error)
        }
    }

    func recoverMeetingArtifacts(
        for plan: MeetingCaptureSpoolPlan
    ) async throws -> MeetingArtifactRecoveryResult {
        let mediaLibrary = mediaLibrary

        do {
            return try await Task.detached {
                try mediaLibrary.recoverMeetingArtifacts(for: plan)
            }.value
        } catch let error as MediaLibraryError {
            throw MediaIngestionError.fromMediaLibraryError(error)
        }
    }

    func resolveArtifactURL(for chunk: SealedAudioSourceChunk) async throws -> URL {
        let mediaLibrary = mediaLibrary

        do {
            return try await Task.detached {
                try mediaLibrary.resolveArtifactURL(for: chunk)
            }.value
        } catch let error as MediaLibraryError {
            throw MediaIngestionError.fromMediaLibraryError(error)
        }
    }

    func makeMixedMeetingChunk(
        sessionID: UUID,
        sequence: Int,
        microphone: SealedAudioSourceChunk?,
        systemAudio: SealedAudioSourceChunk?
    ) async throws -> ManagedMixedMeetingChunkArtifact {
        let mediaLibrary = mediaLibrary

        do {
            return try await Task.detached {
                try mediaLibrary.makeMixedMeetingChunk(
                    sessionID: sessionID,
                    sequence: sequence,
                    microphone: microphone,
                    systemAudio: systemAudio
                )
            }.value
        } catch let error as MediaLibraryError {
            throw MediaIngestionError.fromMediaLibraryError(error)
        }
    }

    func removeMixedMeetingChunk(
        _ artifact: ManagedMixedMeetingChunkArtifact
    ) async throws {
        let mediaLibrary = mediaLibrary

        do {
            try await Task.detached {
                try mediaLibrary.removeMixedMeetingChunk(artifact)
            }.value
        } catch let error as MediaLibraryError {
            throw MediaIngestionError.fromMediaLibraryError(error)
        }
    }

    func removeMixedMeetingChunks(for sessionID: UUID) async throws {
        let mediaLibrary = mediaLibrary

        do {
            try await Task.detached {
                try mediaLibrary.removeMixedMeetingChunks(for: sessionID)
            }.value
        } catch let error as MediaLibraryError {
            throw MediaIngestionError.fromMediaLibraryError(error)
        }
    }

    func storeCapturePCMFile(
        at sourceURL: URL,
        sessionID: UUID,
        sourceID: UUID,
        chunkSequence: Int
    ) throws -> ManagedCaptureSourceArtifact {
        do {
            return try mediaLibrary.storeCapturePCMFile(
                at: sourceURL,
                sessionID: sessionID,
                sourceID: sourceID,
                chunkSequence: chunkSequence
            )
        } catch let error as MediaLibraryError {
            throw MediaIngestionError.fromMediaLibraryError(error)
        }
    }

    func ingest(
        request: MediaTranscriptionRequest,
        jobID: UUID,
        progressHandler: @escaping @MainActor (Double?, String) -> Void
    ) async throws -> ManagedMediaAsset {
        do {
            switch request {
            case .file(let url):
                return try await mediaLibrary.importLocalFile(at: url, jobID: jobID)
            case .link(let string):
                guard let url = URL(string: string),
                      let scheme = url.scheme?.lowercased(),
                      ["http", "https"].contains(scheme) else {
                    throw MediaIngestionError.unsupportedInput("Only http and https links are supported.")
                }

                if Self.isDirectMediaURL(url) {
                    return try await downloadDirectMedia(
                        from: url,
                        jobID: jobID,
                        progressHandler: progressHandler
                    )
                } else {
                    let tooling = await checkTooling()
                    guard tooling.isReady else {
                        throw MediaIngestionError.toolingUnavailable(
                            "This link requires yt-dlp to download. \(tooling.missingToolsDescription)"
                        )
                    }
                    let resolvedTooling = try resolvedTooling(from: tooling)
                    return try await downloadLinkedMedia(
                        from: string,
                        tooling: resolvedTooling,
                        jobID: jobID,
                        progressHandler: progressHandler
                    )
                }
            case .manualCapture:
                throw MediaIngestionError.unsupportedInput(
                    "Manual capture uses the live recording flow instead of media ingestion."
                )
            }
        } catch let error as MediaIngestionError {
            throw error
        } catch let error as MediaLibraryError {
            throw MediaIngestionError.fromMediaLibraryError(error)
        }
    }

    private func locateTool(named tool: String) async -> String? {
        if let directPath = toolPathResolver(tool) {
            let resolvedPath = URL(fileURLWithPath: directPath).resolvingSymlinksInPath().path
            Log.app.debug("Resolved \(tool) via known directories: \(resolvedPath)")
            return resolvedPath
        }

        do {
            let result = try await processRunner.run(
                executableURL: URL(fileURLWithPath: "/usr/bin/which"),
                arguments: [tool],
                currentDirectoryURL: nil,
                environment: ["PATH": Self.toolSearchPath],
                lineHandler: nil
            )
            guard result.terminationStatus == 0 else {
                let stderr = result.standardError.trimmingCharacters(in: .whitespacesAndNewlines)
                Log.app.debug(
                    "Failed to resolve \(tool) with /usr/bin/which. status=\(result.terminationStatus), stderr=\(stderr)"
                )
                return nil
            }
            let path = result.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !path.isEmpty else {
                Log.app.debug("Resolved \(tool) with /usr/bin/which but received an empty path")
                return nil
            }

            let resolvedPath = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
            Log.app.debug("Resolved \(tool) with /usr/bin/which: \(resolvedPath)")
            return resolvedPath
        } catch {
            Log.app.error("Failed to resolve \(tool): \(error.localizedDescription)")
            return nil
        }
    }

    // MARK: - Direct media URL detection

    private static let directMediaExtensions: Set<String> = [
        "mp3", "mp4", "m4a", "wav", "aac", "flac", "ogg", "webm",
        "mov", "m4v", "mkv", "avi", "opus", "wma", "aiff", "aif", "mp2"
    ]

    private static func isDirectMediaURL(_ url: URL) -> Bool {
        Self.directMediaExtensions.contains(url.pathExtension.lowercased())
    }

    // MARK: - Direct HTTP download (package)

    private func downloadDirectMedia(
        from url: URL,
        jobID: UUID,
        progressHandler: @escaping @MainActor (Double?, String) -> Void
    ) async throws -> ManagedMediaAsset {
        try await directDownloader.download(
            from: url,
            jobID: jobID,
            progressHandler: { progress, detail in
                Task { @MainActor in
                    progressHandler(progress, detail)
                }
            }
        )
    }

    // MARK: - yt-dlp download

    private func downloadLinkedMedia(
        from urlString: String,
        tooling: ResolvedMediaTooling,
        jobID: UUID,
        progressHandler: @escaping @MainActor (Double?, String) -> Void
    ) async throws -> ManagedMediaAsset {
        // URL is pre-validated by ingest() before reaching this path.
        let url = URL(string: urlString)!
        let directoryURL = try mediaLibrary.makeJobDirectory(for: jobID)
        let metadata = try await fetchMetadata(for: urlString, tooling: tooling)
        let progressParser = MediaDownloadProgressParser()
        let attempts = downloadAttempts(for: url)
        var finalFailureMessage: String?

        for (index, attempt) in attempts.enumerated() {
            let downloadResult = try await processRunner.run(
                executableURL: tooling.ytDLPURL,
                arguments: downloadArguments(
                    for: urlString,
                    tooling: tooling,
                    attempt: attempt
                ),
                currentDirectoryURL: directoryURL,
                environment: processEnvironment(for: tooling),
                lineHandler: { line in
                    let progress = progressParser.progress(from: line)
                    let detail = progressParser.detail(from: line) ?? "Resolving media"
                    Task { @MainActor in
                        progressHandler(progress, detail)
                    }
                }
            )

            guard downloadResult.terminationStatus != 0 else {
                return try await mediaLibrary.finalizeDownloadedAsset(
                    in: directoryURL,
                    sourceURL: urlString,
                    suggestedTitle: metadata.title
                )
            }

            let output = [downloadResult.standardError, downloadResult.standardOutput]
                .joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            finalFailureMessage = output.isEmpty
                ? "yt-dlp exited with status \(downloadResult.terminationStatus)"
                : output

            let isLastAttempt = index == attempts.index(before: attempts.endIndex)
            guard !isLastAttempt, shouldRetryYouTubeDownload(for: url, output: output) else {
                break
            }

            Log.app.warning(
                "yt-dlp \(attempt.logLabel) download attempt failed for \(url.host(percentEncoded: false) ?? "link"); retrying with compatibility fallback"
            )
        }

        throw MediaIngestionError.downloadFailed(
            userFacingDownloadErrorMessage(for: url, output: finalFailureMessage ?? "")
        )
    }

    private func fetchMetadata(
        for urlString: String,
        tooling: ResolvedMediaTooling
    ) async throws -> YTDLPMetadata {
        let result = try await processRunner.run(
            executableURL: tooling.ytDLPURL,
            arguments: [
                "--dump-single-json",
                "--no-playlist",
                "--ffmpeg-location", tooling.ffmpegURL.deletingLastPathComponent().path,
                urlString
            ],
            currentDirectoryURL: nil,
            environment: processEnvironment(for: tooling),
            lineHandler: nil
        )

        guard result.terminationStatus == 0 else {
            throw MediaIngestionError.metadataLookupFailed(
                result.standardError.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }

        guard let data = result.standardOutput.data(using: .utf8) else {
            throw MediaIngestionError.metadataLookupFailed("yt-dlp did not return valid metadata.")
        }

        do {
            return try JSONDecoder().decode(YTDLPMetadata.self, from: data)
        } catch {
            throw MediaIngestionError.metadataLookupFailed(error.localizedDescription)
        }
    }

    private func resolvedTooling(from status: MediaToolingStatus) throws -> ResolvedMediaTooling {
        guard let ytDLPPath = status.ytDLPPath,
              let ffmpegPath = status.ffmpegPath else {
            throw MediaIngestionError.toolingUnavailable(status.missingToolsDescription)
        }

        return ResolvedMediaTooling(
            ytDLPURL: URL(fileURLWithPath: ytDLPPath),
            ffmpegURL: URL(fileURLWithPath: ffmpegPath)
        )
    }

    private func downloadAttempts(for url: URL) -> [MediaDownloadAttempt] {
        let standardAttempt = MediaDownloadAttempt(
            format: "bestvideo*+bestaudio/best",
            extractorArgs: nil,
            mergeOutputFormat: "mp4",
            logLabel: "standard"
        )

        guard isYouTubeURL(url) else {
            return [standardAttempt]
        }

        let compatibilityAttempt = MediaDownloadAttempt(
            format: "best[ext=mp4]/best",
            extractorArgs: "youtube:player_client=default,-web,-web_safari,-web_creator",
            mergeOutputFormat: nil,
            logLabel: "compatibility"
        )

        return [standardAttempt, compatibilityAttempt]
    }

    private func downloadArguments(
        for urlString: String,
        tooling: ResolvedMediaTooling,
        attempt: MediaDownloadAttempt
    ) -> [String] {
        var arguments = [
            "--no-playlist",
            "--newline",
            "--progress"
        ]

        if let extractorArgs = attempt.extractorArgs {
            arguments += ["--extractor-args", extractorArgs]
        }

        arguments += [
            "--format", attempt.format
        ]

        if let mergeOutputFormat = attempt.mergeOutputFormat {
            arguments += ["--merge-output-format", mergeOutputFormat]
        }

        arguments += [
            "--ffmpeg-location", tooling.ffmpegURL.deletingLastPathComponent().path,
            "--write-thumbnail",
            "--convert-thumbnails", "png",
            "-o", "media.%(ext)s",
            urlString
        ]

        return arguments
    }

    private func shouldRetryYouTubeDownload(for url: URL, output: String) -> Bool {
        guard isYouTubeURL(url) else { return false }

        let normalizedOutput = output.lowercased()
        return normalizedOutput.contains("sabr streaming")
            || normalizedOutput.contains("http error 403")
            || normalizedOutput.contains("missing a url")
    }

    private func userFacingDownloadErrorMessage(for url: URL, output: String) -> String {
        guard isYouTubeURL(url) else { return output }

        let normalizedOutput = output.lowercased()
        if normalizedOutput.contains("sign in to confirm you’re not a bot")
            || normalizedOutput.contains("sign in to confirm you're not a bot")
            || normalizedOutput.contains("--cookies-from-browser")
            || normalizedOutput.contains("po token") {
            return """
            YouTube blocked anonymous access for this video. Try updating yt-dlp, or retry after exporting browser cookies for YouTube. Original error:
            \(output)
            """
        }

        return output
    }

    private func isYouTubeURL(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        return host == "youtube.com"
            || host == "www.youtube.com"
            || host == "m.youtube.com"
            || host == "youtu.be"
    }

    nonisolated private static func defaultDirectToolPath(named tool: String) -> String? {
        for directory in Self.toolSearchDirectories {
            let candidateURL = directory.appendingPathComponent(tool)
            if FileManager.default.isExecutableFile(atPath: candidateURL.path) {
                return candidateURL.path
            }
        }
        return nil
    }

    private func processEnvironment(for tooling: ResolvedMediaTooling) -> [String: String] {
        var environment = ProcessInfo.processInfo.environment

        var directories = Self.toolSearchDirectories.map(\.path)
        directories.append(tooling.ytDLPURL.deletingLastPathComponent().path)
        directories.append(tooling.ffmpegURL.deletingLastPathComponent().path)

        if let existingPath = environment["PATH"], !existingPath.isEmpty {
            directories.append(contentsOf: existingPath.split(separator: ":").map(String.init))
        }

        environment["PATH"] = Array(NSOrderedSet(array: directories))
            .compactMap { $0 as? String }
            .joined(separator: ":")
        return environment
    }

    nonisolated private static var toolSearchDirectories: [URL] {
        let homeDirectory = FileManager.default.homeDirectoryForCurrentUser
        let baseDirectories = [
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "/opt/local/bin",
            "/usr/bin",
            "/bin",
            "/usr/sbin",
            "/sbin"
        ].map { URL(fileURLWithPath: $0, isDirectory: true) } + [
            homeDirectory.appendingPathComponent(".local/bin", isDirectory: true),
            homeDirectory.appendingPathComponent("bin", isDirectory: true),
            homeDirectory.appendingPathComponent("homebrew/bin", isDirectory: true)
        ]

        let pathDirectories = (ProcessInfo.processInfo.environment["PATH"] ?? "")
            .split(separator: ":")
            .map { URL(fileURLWithPath: String($0), isDirectory: true) }

        return Array(NSOrderedSet(array: baseDirectories + pathDirectories))
            .compactMap { $0 as? URL }
    }

    nonisolated private static var toolSearchPath: String {
        toolSearchDirectories.map(\.path).joined(separator: ":")
    }
}

private struct MediaDownloadProgressParser {
    func progress(from line: String) -> Double? {
        let pattern = #"\[download\]\s+(\d+(?:\.\d+)?)%"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(line.startIndex..<line.endIndex, in: line)
        guard let match = regex.firstMatch(in: line, range: range),
              let valueRange = Range(match.range(at: 1), in: line),
              let percent = Double(line[valueRange]) else {
            return nil
        }
        return max(0, min(percent / 100.0, 1.0))
    }

    func detail(from line: String) -> String? {
        if line.contains("Destination:") {
            return "Preparing download"
        }
        if line.contains("[download]") {
            return "Downloading media"
        }
        if line.contains("[Merger]") || line.contains("[ffmpeg]") {
            return "Finalizing media"
        }
        return nil
    }
}
