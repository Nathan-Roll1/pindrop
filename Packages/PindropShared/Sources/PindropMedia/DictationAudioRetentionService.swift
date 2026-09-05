//
//  DictationAudioRetentionService.swift
//  PindropMedia
//
//  Created on 2026-07-09.
//

import Foundation
import PindropCore
import PindropData

public struct DictationAudioDiskUsage: Equatable, Sendable {
    public let totalBytes: Int64
    public let snippetCount: Int

    public init(totalBytes: Int64, snippetCount: Int) {
        self.totalBytes = totalBytes
        self.snippetCount = snippetCount
    }
}

public struct DictationAudioSweepResult: Equatable, Sendable {
    public let deletedCount: Int
    public let freedBytes: Int64

    public init(deletedCount: Int, freedBytes: Int64) {
        self.deletedCount = deletedCount
        self.freedBytes = freedBytes
    }
}

/// Owns the daily sweep `Timer` and in-flight maintenance `Task` so `deinit` can
/// tear them down without reading MainActor-isolated stored properties.
private final class DictationAudioRetentionResources: @unchecked Sendable {
    private let lock = NSLock()
    private var sweepTimer: Timer?
    private var maintenanceTask: Task<Void, Never>?

    /// Installs a new timer, invalidating any previous one. Idempotent if called
    /// repeatedly with successive timers.
    func installTimer(_ timer: Timer) {
        lock.lock()
        let previous = sweepTimer
        sweepTimer = timer
        lock.unlock()
        previous?.invalidate()
    }

    /// Invalidates and clears the sweep timer only.
    func clearTimer() {
        lock.lock()
        let previous = sweepTimer
        sweepTimer = nil
        lock.unlock()
        previous?.invalidate()
    }

    /// Replaces the in-flight maintenance task, cancelling any previous one.
    func replaceMaintenanceTask(_ task: Task<Void, Never>) {
        lock.lock()
        let previous = maintenanceTask
        maintenanceTask = task
        lock.unlock()
        previous?.cancel()
    }

    /// Idempotent: invalidate timer and cancel maintenance task.
    func tearDown() {
        lock.lock()
        let timer = sweepTimer
        let task = maintenanceTask
        sweepTimer = nil
        maintenanceTask = nil
        lock.unlock()
        timer?.invalidate()
        task?.cancel()
    }
}

/// Persists dictation audio off the insertion hot path, sweeps expired files, and
/// reports disk usage for the DictationAudio area. Applies only to `voiceRecording`.
@MainActor
public final class DictationAudioRetentionService {
    public static let sweepInterval: TimeInterval = 24 * 60 * 60
    /// Allow the daily timer to slip substantially so macOS can coalesce wake-ups.
    public static let sweepTimerTolerance: TimeInterval = 60 * 60
    /// Main-context mutation batch size for async maintenance.
    public static let maintenanceBatchSize = 32

    private struct PendingMediaDeletion: Sendable {
        let recordID: UUID
        let mediaPath: String
        let freedBytes: Int64
        /// Only true when media + peaks are confirmed absent (removed or already gone).
        let shouldClearPath: Bool
        /// True when a non-empty media path was confirmed fully removed this pass.
        let didConfirmDeletion: Bool
    }

    private struct RemovalOutcome: Sendable {
        let freedBytes: Int64
        /// Both the media file and peaks sidecar are confirmed absent.
        let didConfirmRemoval: Bool
    }

    private let historyStore: HistoryStore
    private let retentionPolicyProvider: @MainActor @Sendable () -> DictationAudioRetention
    private let fileManager: FileManager
    private let now: () -> Date
    private let directoryURL: URL
    /// Nonisolated resource ownership so `deinit` can release timer/task without
    /// touching MainActor-isolated stored properties.
    private let resources = DictationAudioRetentionResources()
    /// Generation counters let superseded persist tasks avoid clearing a newer slot.
    private var pendingPersistTasks: [UUID: (generation: UInt64, task: Task<Void, Never>)] = [:]
    private var persistGenerations: [UUID: UInt64] = [:]

    public init(
        historyStore: HistoryStore,
        directoryURL: URL,
        retentionPolicyProvider: @escaping @MainActor @Sendable () -> DictationAudioRetention,
        fileManager: FileManager = .default,
        now: @escaping () -> Date = { Date() }
    ) {
        self.historyStore = historyStore
        self.directoryURL = directoryURL
        self.retentionPolicyProvider = retentionPolicyProvider
        self.fileManager = fileManager
        self.now = now
    }

    deinit {
        resources.tearDown()
    }

    // MARK: - Persistence (async, off hot path)

    /// Save the history record first, then call this with the captured PCM data.
    /// Encode + peaks run off the main actor; the record is updated when ready.
    /// When retention is `.off`, does nothing.
    public func schedulePersist(
        pcmFloatData: Data,
        sampleRate: Double = DictationAudioEncoder.inputSampleRate,
        recordID: UUID
    ) {
        guard retentionPolicyProvider() != .off else {
            Log.audio.debug("Dictation audio persistence skipped (retention=off) record=\(recordID)")
            return
        }
        guard !pcmFloatData.isEmpty else {
            Log.audio.debug("Dictation audio persistence skipped (empty buffer) record=\(recordID)")
            return
        }

        let previous = pendingPersistTasks[recordID]
        previous?.task.cancel()

        let generation = (persistGenerations[recordID] ?? 0) &+ 1
        persistGenerations[recordID] = generation

        let destinationDirectory = directoryURL
        let audioData = pcmFloatData

        let ownedTask = Task { [weak self] in
            // Serialize superseding work: cancel then await the prior job so two
            // encodes cannot race on the same destination path.
            if let previous {
                await previous.task.value
            }
            guard !Task.isCancelled else {
                self?.clearPendingPersistTask(for: recordID, generation: generation)
                return
            }
            guard let self else { return }
            defer { self.clearPendingPersistTask(for: recordID, generation: generation) }

            do {
                let encodeTask = Task.detached(priority: .utility) {
                    try Task.checkCancellation()
                    return try Self.encodeAndWritePeaks(
                        pcmFloatData: audioData,
                        sampleRate: sampleRate,
                        recordID: recordID,
                        directoryURL: destinationDirectory
                    )
                }
                let mediaURL = try await withTaskCancellationHandler {
                    try await encodeTask.value
                } onCancel: {
                    encodeTask.cancel()
                }

                guard !Task.isCancelled else {
                    Self.removeUnlinkedMedia(at: mediaURL)
                    return
                }

                let didAttach = try self.historyStore.updateManagedMediaPath(
                    for: recordID,
                    path: mediaURL.path
                )
                if didAttach {
                    Log.audio.info(
                        "Persisted dictation audio for \(recordID.uuidString) -> \(mediaURL.lastPathComponent)"
                    )
                } else {
                    // Record was deleted (or otherwise missing) while encode ran - drop orphans.
                    Self.removeUnlinkedMedia(at: mediaURL)
                    Log.audio.info(
                        "Discarded dictation audio for missing record \(recordID.uuidString)"
                    )
                }
            } catch is CancellationError {
                // Superseded or cancelled - nothing to report.
            } catch {
                Log.audio.error(
                    "Failed to persist dictation audio for \(recordID.uuidString): \(error.localizedDescription)"
                )
            }
        }

        pendingPersistTasks[recordID] = (generation: generation, task: ownedTask)
    }

    /// Ownership of `pcmFloatFileURL` transfers to this service. It is always
    /// removed after the background encoder finishes (or immediately when
    /// retention is disabled).
    public func schedulePersist(
        pcmFloatFileURL: URL,
        sampleRate: Double,
        recordID: UUID
    ) {
        guard retentionPolicyProvider() != .off else {
            try? FileManager.default.removeItem(at: pcmFloatFileURL)
            return
        }

        let previous = pendingPersistTasks[recordID]
        previous?.task.cancel()

        let generation = (persistGenerations[recordID] ?? 0) &+ 1
        persistGenerations[recordID] = generation

        let destinationDirectory = directoryURL

        let ownedTask = Task { [weak self] in
            if let previous {
                await previous.task.value
            }
            defer { try? FileManager.default.removeItem(at: pcmFloatFileURL) }
            guard !Task.isCancelled else {
                self?.clearPendingPersistTask(for: recordID, generation: generation)
                return
            }
            guard let self else { return }
            defer { self.clearPendingPersistTask(for: recordID, generation: generation) }

            do {
                let encodeTask = Task.detached(priority: .utility) {
                    try Task.checkCancellation()
                    return try Self.encodeFileAndWritePeaks(
                        pcmFloatFileURL: pcmFloatFileURL,
                        sampleRate: sampleRate,
                        recordID: recordID,
                        directoryURL: destinationDirectory
                    )
                }
                let mediaURL = try await withTaskCancellationHandler {
                    try await encodeTask.value
                } onCancel: {
                    encodeTask.cancel()
                }
                guard !Task.isCancelled else {
                    Self.removeUnlinkedMedia(at: mediaURL)
                    return
                }
                if try self.historyStore.updateManagedMediaPath(for: recordID, path: mediaURL.path) {
                    Log.audio.info("Persisted dictation audio for \(recordID.uuidString) -> \(mediaURL.lastPathComponent)")
                } else {
                    Self.removeUnlinkedMedia(at: mediaURL)
                }
            } catch is CancellationError {
                // Superseded or cancelled.
            } catch {
                Log.audio.error("Failed to persist dictation audio for \(recordID.uuidString): \(error.localizedDescription)")
            }
        }
        pendingPersistTasks[recordID] = (generation: generation, task: ownedTask)
    }

    /// Synchronous encode used by tests and the detached persistence path.
    public nonisolated static func encodeAndWritePeaks(
        pcmFloatData: Data,
        sampleRate: Double = DictationAudioEncoder.inputSampleRate,
        recordID: UUID,
        directoryURL: URL
    ) throws -> URL {
        try Task.checkCancellation()
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)

        let mediaURL = directoryURL
            .appendingPathComponent(recordID.uuidString)
            .appendingPathExtension("m4a")

        do {
            try DictationAudioEncoder.encodePCMFloatData(
                pcmFloatData,
                to: mediaURL,
                inputSampleRate: sampleRate
            )

            try Task.checkCancellation()
            do {
                let peaks = try WaveformPeaks.extract(
                    fromPCMFloatData: pcmFloatData,
                    sampleRate: sampleRate
                )
                try Task.checkCancellation()
                try WaveformPeaks.writeSidecar(peaks, for: mediaURL)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                Log.audio.warning(
                    "Waveform peaks extraction failed for \(recordID.uuidString): \(error.localizedDescription)"
                )
            }

            try Task.checkCancellation()
            return mediaURL
        } catch is CancellationError {
            removeUnlinkedMedia(at: mediaURL)
            throw CancellationError()
        }
    }

    public nonisolated static func encodeFileAndWritePeaks(
        pcmFloatFileURL: URL,
        sampleRate: Double,
        recordID: UUID,
        directoryURL: URL
    ) throws -> URL {
        try Task.checkCancellation()
        let mediaURL = directoryURL
            .appendingPathComponent(recordID.uuidString)
            .appendingPathExtension("m4a")
        do {
            try DictationAudioEncoder.encodePCMFloatFile(
                pcmFloatFileURL,
                to: mediaURL,
                inputSampleRate: sampleRate
            )
            try Task.checkCancellation()
            do {
                let peaks = try WaveformPeaks.extract(
                    fromPCMFloatFile: pcmFloatFileURL,
                    sampleRate: sampleRate
                )
                try Task.checkCancellation()
                try WaveformPeaks.writeSidecar(peaks, for: mediaURL)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                Log.audio.warning(
                    "Waveform peaks extraction failed for \(recordID.uuidString): \(error.localizedDescription)"
                )
            }
            try Task.checkCancellation()
            return mediaURL
        } catch is CancellationError {
            removeUnlinkedMedia(at: mediaURL)
            throw CancellationError()
        }
    }

    /// Removes a just-written media file and its peaks sidecar when they will never be linked.
    public nonisolated static func removeUnlinkedMedia(at mediaURL: URL) {
        try? FileManager.default.removeItem(at: mediaURL)
        WaveformPeaks.removeSidecar(for: mediaURL)
    }

    // MARK: - Retention sweep

    /// Deletes expired dictation audio + peaks sidecars and clears `managedMediaPath`.
    /// Transcript text is preserved. Imported / media-backed records are never touched.
    ///
    /// Synchronous API retained for tests and explicit callers. Launch / timer paths use
    /// `performMaintenanceAsync()` so startup never blocks on filesystem deletion.
    @discardableResult
    public func sweepExpired() throws -> DictationAudioSweepResult {
        let retention = retentionPolicyProvider()
        guard let interval = retention.retentionInterval, interval > 0 else {
            // `.off` and `.forever` do not expire existing files via the windowed sweeper.
            // `.off` only prevents new persistence; existing files remain until manual delete
            // or a later retention change that re-enables a finite window.
            if retention == .forever || retention == .off {
                Log.audio.debug("Dictation audio sweep skipped (retention=\(retention.rawValue))")
            }
            return DictationAudioSweepResult(deletedCount: 0, freedBytes: 0)
        }

        let cutoff = now().addingTimeInterval(-interval)
        var deletedCount = 0
        var freedBytes: Int64 = 0

        while true {
            let candidates = try historyStore.fetchExpiredDictationMediaCandidates(
                olderThan: cutoff,
                limit: Self.maintenanceBatchSize
            )
            if candidates.isEmpty { break }

            var clearableIDs: [UUID] = []
            clearableIDs.reserveCapacity(candidates.count)

            for candidate in candidates {
                if candidate.mediaPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    // Empty/whitespace path is already unlinked; clear the stale field.
                    clearableIDs.append(candidate.recordID)
                    continue
                }

                let mediaURL = URL(fileURLWithPath: candidate.mediaPath)
                let outcome = removeAudioAndSidecar(at: mediaURL)
                if outcome.didConfirmRemoval {
                    clearableIDs.append(candidate.recordID)
                    freedBytes += outcome.freedBytes
                    deletedCount += 1
                }
            }

            if !clearableIDs.isEmpty {
                _ = try historyStore.clearManagedMediaPaths(for: clearableIDs)
            }

            // Stop when the page is short, or when nothing could be cleared (transient
            // filesystem failures leave links for a later retry - avoid a tight loop).
            if candidates.count < Self.maintenanceBatchSize { break }
            if clearableIDs.isEmpty { break }
        }

        Log.audio.info(
            "Dictation audio retention sweep: deleted \(deletedCount) file(s), freed \(freedBytes) bytes (retention=\(retention.rawValue))"
        )
        return DictationAudioSweepResult(deletedCount: deletedCount, freedBytes: freedBytes)
    }

    /// Non-blocking maintenance used at launch and by the daily timer.
    /// Queries only expired eligible records, deletes files off-main, then applies
    /// model path clears in bounded main-context batches.
    @discardableResult
    public func performMaintenanceAsync() async -> DictationAudioSweepResult {
        let retention = retentionPolicyProvider()
        guard let interval = retention.retentionInterval, interval > 0 else {
            if retention == .forever || retention == .off {
                Log.audio.debug("Dictation audio maintenance skipped (retention=\(retention.rawValue))")
            }
            return DictationAudioSweepResult(deletedCount: 0, freedBytes: 0)
        }

        let cutoff = now().addingTimeInterval(-interval)
        var deletedCount = 0
        var freedBytes: Int64 = 0

        do {
            while !Task.isCancelled {
                let candidates = try historyStore.fetchExpiredDictationMediaCandidates(
                    olderThan: cutoff,
                    limit: Self.maintenanceBatchSize
                )
                if candidates.isEmpty { break }

                // Detached deletes do not inherit cancellation. Await them fully,
                // clear model paths only for confirmed removals, then decide
                // whether to continue the maintenance loop.
                let deleteTask = Task.detached(priority: .utility) { [fileManager] () -> [PendingMediaDeletion] in
                    var results: [PendingMediaDeletion] = []
                    results.reserveCapacity(candidates.count)
                    for candidate in candidates {
                        if candidate.mediaPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            results.append(
                                PendingMediaDeletion(
                                    recordID: candidate.recordID,
                                    mediaPath: candidate.mediaPath,
                                    freedBytes: 0,
                                    shouldClearPath: true,
                                    didConfirmDeletion: false
                                )
                            )
                            continue
                        }

                        let mediaURL = URL(fileURLWithPath: candidate.mediaPath)
                        let outcome = Self.removeAudioAndSidecarStatic(
                            at: mediaURL,
                            fileManager: fileManager
                        )
                        results.append(
                            PendingMediaDeletion(
                                recordID: candidate.recordID,
                                mediaPath: candidate.mediaPath,
                                freedBytes: outcome.freedBytes,
                                shouldClearPath: outcome.didConfirmRemoval,
                                didConfirmDeletion: outcome.didConfirmRemoval
                            )
                        )
                    }
                    return results
                }
                let deletions = await deleteTask.value

                let clearableIDs = deletions.compactMap { deletion in
                    deletion.shouldClearPath ? deletion.recordID : nil
                }
                if !clearableIDs.isEmpty {
                    _ = try historyStore.clearManagedMediaPaths(for: clearableIDs)
                }

                deletedCount += deletions.reduce(into: 0) { count, deletion in
                    if deletion.didConfirmDeletion { count += 1 }
                }
                freedBytes += deletions.reduce(into: Int64(0)) { $0 += $1.freedBytes }

                if Task.isCancelled { break }
                if candidates.count < Self.maintenanceBatchSize { break }
                // No progress this page (all transient failures) - stop and retry later.
                if clearableIDs.isEmpty { break }
            }
        } catch is CancellationError {
            // Expected when a newer maintenance pass supersedes this one.
        } catch {
            Log.audio.error("Dictation audio maintenance failed: \(error.localizedDescription)")
        }

        if deletedCount > 0 {
            Log.audio.info(
                "Dictation audio retention maintenance: deleted \(deletedCount) file(s), freed \(freedBytes) bytes (retention=\(retention.rawValue))"
            )
        }
        return DictationAudioSweepResult(deletedCount: deletedCount, freedBytes: freedBytes)
    }

    /// Launch-time non-blocking sweep + optional 24h repeating timer for finite policies.
    /// Startup never waits for the sweep. Disabled/forever policies install no timer.
    public func startPeriodicSweep() {
        scheduleMaintenance(runImmediately: true)
    }

    /// Install or tear down the daily timer and optionally kick an immediate async sweep
    /// when the retention policy changes.
    public func applyRetentionPolicyChange() {
        scheduleMaintenance(runImmediately: true)
    }

    public func stopPeriodicSweep() {
        resources.tearDown()
    }

    // MARK: - Disk usage

    /// Aggregate size + count of audio files under the DictationAudio directory
    /// (`.m4a` only; peaks sidecars are not counted as snippets).
    public func diskUsage() throws -> DictationAudioDiskUsage {
        guard fileManager.fileExists(atPath: directoryURL.path) else {
            return DictationAudioDiskUsage(totalBytes: 0, snippetCount: 0)
        }

        let items = try fileManager.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        )

        var totalBytes: Int64 = 0
        var snippetCount = 0

        for url in items {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values.isRegularFile == true else { continue }
            let size = Int64(values.fileSize ?? 0)
            totalBytes += size
            if url.pathExtension.lowercased() == "m4a" {
                snippetCount += 1
            }
        }

        return DictationAudioDiskUsage(totalBytes: totalBytes, snippetCount: snippetCount)
    }

    /// Deletes all dictation audio files + peaks and clears `managedMediaPath` on
    /// voiceRecording records. Transcripts are kept.
    public func deleteAllDictationAudio() throws {
        let voiceRaw = MediaSourceKind.voiceRecording.rawValue
        let records = try historyStore.fetchAll()

        for record in records {
            let kind = record.sourceKindRawValue ?? voiceRaw
            guard kind == voiceRaw else { continue }
            if let path = record.managedMediaPath,
               !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                _ = removeAudioAndSidecar(at: URL(fileURLWithPath: path))
            }
            record.managedMediaPath = nil
        }

        try historyStore.saveContext()

        // Remove any orphaned files left in the DictationAudio directory.
        if fileManager.fileExists(atPath: directoryURL.path) {
            let items = try fileManager.contentsOfDirectory(
                at: directoryURL,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )
            for url in items {
                try? fileManager.removeItem(at: url)
            }
        }

        Log.audio.info("Deleted all dictation audio under \(directoryURL.path)")
    }

    // MARK: - Helpers

    private func scheduleMaintenance(runImmediately: Bool) {
        let retention = retentionPolicyProvider()
        let hasFiniteWindow = (retention.retentionInterval ?? 0) > 0

        resources.clearTimer()

        if hasFiniteWindow {
            let timer = Timer(
                timeInterval: Self.sweepInterval,
                repeats: true
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.kickMaintenancePass()
                }
            }
            timer.tolerance = Self.sweepTimerTolerance
            RunLoop.main.add(timer, forMode: .common)
            resources.installTimer(timer)
        }

        if runImmediately {
            if hasFiniteWindow {
                kickMaintenancePass()
            } else if retention == .forever || retention == .off {
                Log.audio.debug("Dictation audio periodic timer not installed (retention=\(retention.rawValue))")
            }
        }
    }

    private func kickMaintenancePass() {
        let task = Task { [weak self] in
            guard let self else { return }
            _ = await self.performMaintenanceAsync()
        }
        resources.replaceMaintenanceTask(task)
    }

    private func clearPendingPersistTask(for recordID: UUID, generation: UInt64) {
        guard pendingPersistTasks[recordID]?.generation == generation else { return }
        pendingPersistTasks[recordID] = nil
        if persistGenerations[recordID] == generation {
            persistGenerations[recordID] = nil
        }
    }

    @discardableResult
    private func removeAudioAndSidecar(at mediaURL: URL) -> RemovalOutcome {
        Self.removeAudioAndSidecarStatic(at: mediaURL, fileManager: fileManager)
    }

    nonisolated private static func removeAudioAndSidecarStatic(
        at mediaURL: URL,
        fileManager: FileManager = .default
    ) -> RemovalOutcome {
        var freed: Int64 = 0
        var mediaAbsent = !fileManager.fileExists(atPath: mediaURL.path)

        if !mediaAbsent {
            let size = (try? mediaURL.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
            do {
                try fileManager.removeItem(at: mediaURL)
                freed += size
                mediaAbsent = true
            } catch {
                Log.audio.warning("Failed to delete dictation audio at \(mediaURL.path): \(error.localizedDescription)")
            }
        }

        let sidecar = WaveformPeaks.sidecarURL(for: mediaURL)
        var sidecarAbsent = !fileManager.fileExists(atPath: sidecar.path)

        if !sidecarAbsent {
            let size = (try? sidecar.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
            do {
                try fileManager.removeItem(at: sidecar)
                freed += size
                sidecarAbsent = true
            } catch {
                Log.audio.warning("Failed to delete peaks sidecar at \(sidecar.path): \(error.localizedDescription)")
            }
        }

        // Only count freed bytes when both artifacts are confirmed gone; a partial
        // delete must leave the record linked so a later retry can finish the job.
        let didConfirmRemoval = mediaAbsent && sidecarAbsent
        return RemovalOutcome(
            freedBytes: didConfirmRemoval ? freed : 0,
            didConfirmRemoval: didConfirmRemoval
        )
    }
}
