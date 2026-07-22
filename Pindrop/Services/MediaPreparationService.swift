//
//  MediaPreparationService.swift
//  Pindrop
//
//  macOS-only ffmpeg fallback for PindropMedia.MediaPreparationService.
//  AVFoundation preparation lives in the package; this file owns Process.
//

import Darwin
import Foundation
import PindropCore
import PindropMedia

/// Host-injected ffmpeg transcoder used when AVFoundation cannot open a media file.
///
/// Discovers `ffmpeg` on PATH (or uses an injected path) and writes a 16 kHz mono
/// PCM WAV to the package-owned destination URL. Cancellation terminates the
/// process (SIGTERM, then SIGKILL after a grace period), resumes the waiter
/// immediately, and only removes residual destination output after the child
/// has fully exited, so a SIGTERM-ignoring ffmpeg cannot recreate a leaked file.
struct MacFFmpegFallbackTranscoder: MediaFallbackTranscoding, Sendable {
    private let ffmpegPath: String?
    private let toolPathResolver: @Sendable (String) -> String?
    private static let targetSampleRate: Double = 16_000

    init(
        ffmpegPath: String? = nil,
        toolPathResolver: @escaping @Sendable (String) -> String? = MacFFmpegFallbackTranscoder.defaultDirectToolPath(named:)
    ) {
        self.ffmpegPath = ffmpegPath
        self.toolPathResolver = toolPathResolver
    }

    func transcodeToPCM(sourceURL: URL, destinationURL: URL) async throws {
        let executablePath = try resolveFFmpegPath()

        if FileManager.default.fileExists(atPath: destinationURL.path) {
            try? FileManager.default.removeItem(at: destinationURL)
        }

        // 16 kHz mono signed 16-bit PCM WAV - matches what AVAudioFile handles
        // most reliably. The package upconverts floats via AVAudioConverter afterwards.
        let arguments = [
            "-nostdin",
            "-y",
            "-hide_banner",
            "-loglevel", "error",
            "-i", sourceURL.path,
            "-vn",
            "-ac", "1",
            "-ar", String(Int(Self.targetSampleRate)),
            "-acodec", "pcm_s16le",
            "-f", "wav",
            destinationURL.path
        ]

        Log.app.info(
            "MacFFmpegFallback: launching ffmpeg for \(sourceURL.lastPathComponent) → \(destinationURL.lastPathComponent)"
        )

        // On cancellation the package leaves `destinationURL` in place so a
        // SIGTERM-ignoring child can finish its in-flight write. This adapter
        // owns residual cleanup and only unlinks after the process is reaped.
        let outputCleanup = DeferredProcessOutputCleanup(outputURL: destinationURL)
        do {
            let (status, stderr) = try await runProcess(
                executablePath: executablePath,
                arguments: arguments,
                onExit: { @Sendable in outputCleanup.processDidExit() }
            )
            if status != 0 {
                outputCleanup.scheduleCleanup()
                throw MediaPreparationError.exportFailed("ffmpeg exited \(status): \(stderr.prefix(500))")
            }
            guard FileManager.default.fileExists(atPath: destinationURL.path) else {
                outputCleanup.scheduleCleanup()
                throw MediaPreparationError.exportFailed("ffmpeg reported success but produced no output file.")
            }
            outputCleanup.relinquishOwnership()
        } catch {
            outputCleanup.scheduleCleanup()
            throw error
        }
    }

    // MARK: - Path resolution

    private func resolveFFmpegPath() throws -> String {
        if let ffmpegPath, !ffmpegPath.isEmpty {
            return URL(fileURLWithPath: ffmpegPath).resolvingSymlinksInPath().path
        }

        if let directPath = toolPathResolver("ffmpeg") {
            return URL(fileURLWithPath: directPath).resolvingSymlinksInPath().path
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        process.arguments = ["ffmpeg"]
        process.environment = ["PATH": Self.toolSearchPath]

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            throw MediaPreparationError.exportFailed("Failed to locate ffmpeg: \(error.localizedDescription)")
        }

        guard process.terminationStatus == 0 else {
            throw MediaPreparationError.exportFailed(
                "ffmpeg is not available. Install ffmpeg on PATH for broader media format support."
            )
        }

        let path = String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !path.isEmpty else {
            throw MediaPreparationError.exportFailed("ffmpeg resolution returned an empty path.")
        }
        return URL(fileURLWithPath: path).resolvingSymlinksInPath().path
    }

    nonisolated private static func defaultDirectToolPath(named tool: String) -> String? {
        for directory in toolSearchDirectories {
            let candidateURL = directory.appendingPathComponent(tool)
            if FileManager.default.isExecutableFile(atPath: candidateURL.path) {
                return candidateURL.path
            }
        }
        return nil
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

    // MARK: - Process runner (cancel → SIGTERM → SIGKILL)

    private func runProcess(
        executablePath: String,
        arguments: [String],
        onExit: @escaping @Sendable () -> Void
    ) async throws -> (Int32, String) {
        let state = ProcessCompletionState(didExit: onExit)
        return try await withTaskCancellationHandler(operation: {
            let result = try await withCheckedThrowingContinuation { continuation in
                let process = Process()
                let stderrPipe = Pipe()
                let stderrCollector = ProcessStandardErrorCollector()

                process.executableURL = URL(fileURLWithPath: executablePath)
                process.arguments = arguments
                process.standardOutput = FileHandle.nullDevice
                process.standardError = stderrPipe
                stderrPipe.fileHandleForReading.readabilityHandler = { handle in
                    stderrCollector.append(handle.availableData)
                }
                process.terminationHandler = { proc in
                    stderrPipe.fileHandleForReading.readabilityHandler = nil
                    stderrCollector.append(stderrPipe.fileHandleForReading.readDataToEndOfFile())
                    state.processDidExit(with: .success((proc.terminationStatus, stderrCollector.string)))
                }

                state.launch(process, continuation: continuation)
            }
            try Task.checkCancellation()
            return result
        }, onCancel: {
            state.cancel()
        })
    }
}

// MARK: - Process helpers

private final class ProcessStandardErrorCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    func append(_ newData: Data) {
        guard !newData.isEmpty else { return }
        lock.withLock {
            data.append(newData)
        }
    }

    var string: String {
        lock.withLock {
            String(data: data, encoding: .utf8) ?? ""
        }
    }
}

/// Removes a process-owned destination only after the child has exited.
///
/// Cancellation resumes the waiter immediately (so callers can tear down) but
/// must not unlink the partial output while a SIGTERM-ignoring child can still
/// write to it. `scheduleCleanup()` records the intent; `processDidExit()`
/// performs the unlink once the process is fully reaped.
private final class DeferredProcessOutputCleanup: @unchecked Sendable {
    private let lock = NSLock()
    private let fileManager: FileManager
    private let outputURL: URL
    private var processExited = false
    private var cleanupScheduled = false
    private var ownsOutput = true

    init(fileManager: FileManager = .default, outputURL: URL) {
        self.fileManager = fileManager
        self.outputURL = outputURL
    }

    func scheduleCleanup() {
        let shouldRemove = lock.withLock { () -> Bool in
            cleanupScheduled = true
            return processExited && ownsOutput
        }
        if shouldRemove {
            try? fileManager.removeItem(at: outputURL)
        }
    }

    func processDidExit() {
        let shouldRemove = lock.withLock { () -> Bool in
            processExited = true
            return cleanupScheduled && ownsOutput
        }
        if shouldRemove {
            try? fileManager.removeItem(at: outputURL)
        }
    }

    func relinquishOwnership() {
        lock.withLock {
            ownsOutput = false
        }
    }
}

private final class ProcessCompletionState: @unchecked Sendable {
    typealias Result = Swift.Result<(Int32, String), Error>
    private static let terminationGraceNanoseconds: UInt64 = 1_000_000_000

    private let lock = NSLock()
    private let didExit: @Sendable () -> Void
    private var continuation: CheckedContinuation<(Int32, String), Error>?
    private var result: Result?
    private var process: Process?
    private var cancellationRequested = false

    init(didExit: @escaping @Sendable () -> Void) {
        self.didExit = didExit
    }

    func launch(_ process: Process, continuation: CheckedContinuation<(Int32, String), Error>) {
        lock.lock()
        if let result {
            lock.unlock()
            didExit()
            continuation.resume(with: result)
            return
        }
        self.process = process
        self.continuation = continuation

        guard !cancellationRequested else {
            lock.unlock()
            complete(.failure(CancellationError()))
            didExit()
            clearProcess()
            return
        }

        do {
            try process.run()
            lock.unlock()
        } catch {
            lock.unlock()
            complete(.failure(error))
            didExit()
            clearProcess()
        }
    }

    func cancel() {
        let process = lock.withLock { () -> Process? in
            cancellationRequested = true
            return self.process
        }
        guard let process else {
            // Not launched yet (or already cleared): fail any waiter immediately.
            complete(.failure(CancellationError()))
            return
        }
        if process.isRunning {
            process.terminate()
            scheduleForcedTermination()
        }
        // Resume immediately so the package can surface CancellationError while
        // the child is still draining. Residual output is removed only after
        // `processDidExit` / forced SIGKILL reaps the process.
        complete(.failure(CancellationError()))
    }

    func processDidExit(with result: Result) {
        let wasCancelled = lock.withLock { cancellationRequested }
        if !wasCancelled {
            // Success/failure path: deliver the real termination status.
            complete(result)
        }
        // Cancel path already resumed the waiter; still notify exit so deferred
        // output cleanup can run after the child is fully reaped.
        didExit()
        clearProcess()
    }

    func complete(_ result: Result) {
        let continuation = lock.withLock { () -> CheckedContinuation<(Int32, String), Error>? in
            guard self.result == nil else { return nil }
            self.result = result
            defer { self.continuation = nil }
            return self.continuation
        }
        continuation?.resume(with: result)
    }

    func clearProcess() {
        lock.withLock {
            process = nil
        }
    }

    private func scheduleForcedTermination() {
        Task.detached { [weak self] in
            try? await Task.sleep(nanoseconds: Self.terminationGraceNanoseconds)
            self?.forceTerminateIfNecessary()
        }
    }

    private func forceTerminateIfNecessary() {
        let processIdentifier = lock.withLock { () -> pid_t? in
            guard let process, process.isRunning else { return nil }
            return process.processIdentifier
        }
        guard let processIdentifier, processIdentifier > 0 else { return }
        Darwin.kill(processIdentifier, SIGKILL)
    }
}
