//
//  ManagedMediaLibrary.swift
//  PindropMedia
//
//  Created on 2026-07-22.
//

import AVFoundation
import CryptoKit
import Foundation
import ImageIO
import PindropCore
import UniformTypeIdentifiers

/// File-backed managed media library rooted at an injected base URL.
///
/// Hosts supply the root (for example Application Support/Pindrop/MediaLibrary on macOS,
/// or a sandbox container path on iOS). This type never reconstructs Application Support.
public final class ManagedMediaLibrary: MediaLibraryManaging, @unchecked Sendable {
    private let fileManager: FileManager
    private static let captureSourceStorageLock = NSLock()

    /// Root directory for job folders and derived areas such as DictationAudio.
    public let baseURL: URL

    /// `baseURL/DictationAudio` - ordinary voice dictation audio.
    public var dictationAudioDirectoryURL: URL {
        baseURL.appendingPathComponent("DictationAudio", isDirectory: true)
    }

    /// Alias for `baseURL` kept for call-site clarity at composition roots.
    public var libraryBaseURL: URL {
        baseURL
    }

    /// Resolves a durable capture artifact's library-relative path.
    public func captureSourceURL(for artifact: ManagedCaptureSourceArtifact) -> URL {
        baseURL.appendingPathComponent(artifact.relativePath)
    }

    public init(baseURL: URL, fileManager: FileManager = .default) {
        self.baseURL = baseURL
        self.fileManager = fileManager
    }

    public func makeJobDirectory(for jobID: UUID) throws -> URL {
        let directory = baseURL.appendingPathComponent(jobID.uuidString, isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    /// Ensures the DictationAudio area exists and returns its URL.
    public func ensureDictationAudioDirectory() throws -> URL {
        let directory = dictationAudioDirectoryURL
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    public func importLocalFile(at sourceURL: URL, jobID: UUID) async throws -> ManagedMediaAsset {
        let directoryURL = try makeJobDirectory(for: jobID)
        let destinationURL = directoryURL.appendingPathComponent("media").appendingPathExtension(sourceURL.pathExtension)

        do {
            if fileManager.fileExists(atPath: destinationURL.path) {
                try fileManager.removeItem(at: destinationURL)
            }
            try fileManager.copyItem(at: sourceURL, to: destinationURL)
        } catch {
            throw MediaLibraryError.localFileImportFailed(error.localizedDescription)
        }

        let thumbnailURL = try? await generateThumbnailIfPossible(for: destinationURL, in: directoryURL)

        return ManagedMediaAsset(
            directoryURL: directoryURL,
            mediaURL: destinationURL,
            thumbnailURL: thumbnailURL,
            sourceKind: .importedFile,
            displayName: sourceURL.lastPathComponent,
            hasSourceMetadataTitle: false,
            originalSourceURL: sourceURL.absoluteString
        )
    }

    public func storeRecordedAudio(
        _ audioData: Data,
        jobID: UUID,
        displayName: String,
        sourceKind: MediaSourceKind
    ) throws -> ManagedMediaAsset {
        let directoryURL = try makeJobDirectory(for: jobID)
        let destinationURL = directoryURL.appendingPathComponent("media").appendingPathExtension("caf")

        if fileManager.fileExists(atPath: destinationURL.path) {
            try fileManager.removeItem(at: destinationURL)
        }

        let format = AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1)
            ?? AVAudioFormat()
        guard format.sampleRate > 0,
              let buffer = AVAudioPCMBuffer(
                pcmFormat: format,
                frameCapacity: AVAudioFrameCount(audioData.count / MemoryLayout<Float>.size)
              ),
              let channelData = buffer.floatChannelData else {
            throw MediaLibraryError.localFileImportFailed("Unable to prepare recorded audio for storage.")
        }

        let samples = audioData.count / MemoryLayout<Float>.size
        buffer.frameLength = AVAudioFrameCount(samples)
        audioData.withUnsafeBytes { rawBuffer in
            guard let source = rawBuffer.bindMemory(to: Float.self).baseAddress else { return }
            channelData[0].update(from: source, count: samples)
        }

        do {
            let outputFile = try AVAudioFile(forWriting: destinationURL, settings: format.settings)
            try outputFile.write(from: buffer)
        } catch {
            throw MediaLibraryError.localFileImportFailed(error.localizedDescription)
        }

        return ManagedMediaAsset(
            directoryURL: directoryURL,
            mediaURL: destinationURL,
            thumbnailURL: nil,
            sourceKind: sourceKind,
            displayName: displayName,
            hasSourceMetadataTitle: false,
            originalSourceURL: nil
        )
    }

    public func storeCapturePCMFile(
        at sourceURL: URL,
        sessionID: UUID,
        sourceID: UUID,
        chunkSequence: Int
    ) throws -> ManagedCaptureSourceArtifact {
        guard chunkSequence >= 0 else {
            throw MediaLibraryError.captureSourceStorageFailed("Chunk sequence must not be negative.")
        }

        let relativePath = CaptureSourceArtifactPath.relativePath(
            sessionID: sessionID,
            sourceID: sourceID,
            chunkSequence: chunkSequence
        )
        let destinationURL = baseURL.appendingPathComponent(relativePath)
        let partialURL = destinationURL
            .appendingPathExtension("partial-\(UUID().uuidString)")

        Self.captureSourceStorageLock.lock()
        defer { Self.captureSourceStorageLock.unlock() }

        var shouldRemovePartial = false
        defer {
            if shouldRemovePartial {
                try? fileManager.removeItem(at: partialURL)
            }
        }

        do {
            try fileManager.createDirectory(
                at: destinationURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            guard fileManager.createFile(atPath: partialURL.path, contents: nil) else {
                throw MediaLibraryError.captureSourceStorageFailed("Unable to create staging file.")
            }
            shouldRemovePartial = true

            try streamPCMFile(at: sourceURL, to: partialURL)
            let stagedMetadata = try captureSourceMetadata(at: partialURL)

            if fileManager.fileExists(atPath: destinationURL.path) {
                let destinationMetadata = try captureSourceMetadata(at: destinationURL)
                guard destinationMetadata == stagedMetadata else {
                    throw MediaLibraryError.captureSourceStorageContentConflict(relativePath: relativePath)
                }

                return ManagedCaptureSourceArtifact(
                    sessionID: sessionID,
                    sourceID: sourceID,
                    chunkSequence: chunkSequence,
                    relativePath: relativePath,
                    byteCount: destinationMetadata.byteCount,
                    sha256: destinationMetadata.sha256
                )
            }

            try fileManager.moveItem(at: partialURL, to: destinationURL)
            shouldRemovePartial = false
            let destinationMetadata = try captureSourceMetadata(at: destinationURL)
            return ManagedCaptureSourceArtifact(
                sessionID: sessionID,
                sourceID: sourceID,
                chunkSequence: chunkSequence,
                relativePath: relativePath,
                byteCount: destinationMetadata.byteCount,
                sha256: destinationMetadata.sha256
            )
        } catch let error as MediaLibraryError {
            throw error
        } catch {
            throw MediaLibraryError.captureSourceStorageFailed(error.localizedDescription)
        }
    }

    private func streamPCMFile(
        at sourceURL: URL,
        to destinationURL: URL
    ) throws {
        let sourceHandle = try FileHandle(forReadingFrom: sourceURL)
        defer { try? sourceHandle.close() }
        let destinationHandle = try FileHandle(forWritingTo: destinationURL)
        defer { try? destinationHandle.close() }

        while let data = try sourceHandle.read(upToCount: 64 * 1024), !data.isEmpty {
            try destinationHandle.write(contentsOf: data)
        }
    }

    private func captureSourceMetadata(at url: URL) throws -> (byteCount: Int64, sha256: String) {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        var hasher = SHA256()
        var byteCount: Int64 = 0

        while let data = try handle.read(upToCount: 64 * 1024), !data.isEmpty {
            hasher.update(data: data)
            byteCount += Int64(data.count)
        }

        return (
            byteCount: byteCount,
            sha256: hasher.finalize().map { String(format: "%02x", $0) }.joined()
        )
    }

    public func makeMeetingCaptureSpoolPlan(
        sessionID: UUID,
        microphoneSourceID: UUID,
        systemAudioSourceID: UUID?
    ) throws -> MeetingCaptureSpoolPlan {
        guard microphoneSourceID != systemAudioSourceID else {
            throw MediaLibraryError.captureSourceStorageFailed("Meeting sources must have distinct identifiers.")
        }

        Self.captureSourceStorageLock.lock()
        defer { Self.captureSourceStorageLock.unlock() }

        let plan = MeetingCaptureSpoolPlan(
            libraryRootURL: baseURL,
            sessionID: sessionID,
            microphoneSourceID: microphoneSourceID,
            systemAudioSourceID: systemAudioSourceID
        )
        try ensureMeetingDirectories(for: plan)
        return plan
    }

    public func recoverMeetingArtifacts(for plan: MeetingCaptureSpoolPlan) throws -> MeetingArtifactRecoveryResult {
        try validate(plan: plan)
        Self.captureSourceStorageLock.lock()
        defer { Self.captureSourceStorageLock.unlock() }

        var sealedChunks: [SealedAudioSourceChunk] = []
        var failures: [MeetingArtifactRecoveryFailure] = []
        for sourceID in sourceIDs(in: plan) {
            let directory = sourceDirectoryURL(sessionID: plan.sessionID, sourceID: sourceID)
            if !fileManager.fileExists(atPath: directory.path) {
                failures.append(MeetingArtifactRecoveryFailure(
                    kind: .sourceUnavailable,
                    sourceID: sourceID,
                    relativePath: recoveryRelativePath(for: directory),
                    message: "Meeting source directory is unavailable."
                ))
            }
        }
        try ensureMeetingDirectories(for: plan)

        for sourceID in sourceIDs(in: plan) {
            let sourceResult = try recoverMeetingArtifacts(for: sourceID, plan: plan)
            sealedChunks.append(contentsOf: sourceResult.sealedChunks)
            failures.append(contentsOf: sourceResult.failures)
        }
        sealedChunks.sort {
            ($0.sourceID.uuidString, $0.sequence) < ($1.sourceID.uuidString, $1.sequence)
        }
        failures.sort {
            if $0.sourceID != $1.sourceID {
                return $0.sourceID.uuidString < $1.sourceID.uuidString
            }
            if $0.sequence != $1.sequence {
                return ($0.sequence ?? -1) < ($1.sequence ?? -1)
            }
            return ($0.relativePath ?? "") < ($1.relativePath ?? "")
        }
        return MeetingArtifactRecoveryResult(sealedChunks: sealedChunks, failures: failures)
    }

    public func resolveArtifactURL(for chunk: SealedAudioSourceChunk) throws -> URL {
        guard chunk.sequence >= 0,
              chunk.byteCount > 0,
              chunk.byteCount % Int64(MeetingCaptureSpoolPlan.bytesPerSample) == 0 else {
            throw MediaLibraryError.captureSourceStorageFailed("Meeting artifact metadata is invalid.")
        }

        let expectedRelativePath = CaptureSourceArtifactPath.relativePath(
            sessionID: chunk.sessionID,
            sourceID: chunk.sourceID,
            chunkSequence: chunk.sequence
        )
        guard chunk.relativePath == expectedRelativePath else {
            throw MediaLibraryError.captureSourceStorageFailed("Meeting artifact path is not canonical.")
        }

        let url = CaptureSourceArtifactPath.sourceURL(
            libraryRootURL: baseURL,
            sessionID: chunk.sessionID,
            sourceID: chunk.sourceID,
            chunkSequence: chunk.sequence
        )
        try assertSafeExistingPath(url, isDirectory: false)
        let metadata = try captureSourceMetadata(at: url)
        guard metadata.byteCount == chunk.byteCount, metadata.sha256 == chunk.sha256 else {
            throw MediaLibraryError.captureSourceStorageContentConflict(relativePath: chunk.relativePath)
        }
        return url
    }

    public func makeMixedMeetingChunk(
        sessionID: UUID,
        sequence: Int,
        microphone: SealedAudioSourceChunk?,
        systemAudio: SealedAudioSourceChunk?
    ) throws -> ManagedMixedMeetingChunkArtifact {
        guard sequence >= 0, microphone != nil || systemAudio != nil else {
            throw MediaLibraryError.captureSourceStorageFailed("A mixed meeting chunk needs a nonnegative sequence and at least one source.")
        }
        for chunk in [microphone, systemAudio].compactMap({ $0 }) {
            guard chunk.sessionID == sessionID, chunk.sequence == sequence else {
                throw MediaLibraryError.captureSourceStorageFailed("Meeting source chunks must match the mixed chunk session and sequence.")
            }
        }

        Self.captureSourceStorageLock.lock()
        defer { Self.captureSourceStorageLock.unlock() }

        let microphoneURL = try microphone.map { try resolveArtifactURL(for: $0) }
        let systemAudioURL = try systemAudio.map { try resolveArtifactURL(for: $0) }
        let destinationURL = CaptureSourceArtifactPath.mixedURL(
            libraryRootURL: baseURL,
            sessionID: sessionID,
            chunkSequence: sequence
        )
        let stagingURL = CaptureSourceArtifactPath.mixedInProgressURL(
            libraryRootURL: baseURL,
            sessionID: sessionID,
            chunkSequence: sequence
        )
        let relativePath = CaptureSourceArtifactPath.mixedRelativePath(
            sessionID: sessionID,
            chunkSequence: sequence
        )

        try ensureSafeDirectory(at: destinationURL.deletingLastPathComponent())
        if fileManager.fileExists(atPath: stagingURL.path) {
            try assertSafeExistingPath(stagingURL, isDirectory: false)
            try fileManager.removeItem(at: stagingURL)
        }
        guard fileManager.createFile(atPath: stagingURL.path, contents: nil) else {
            throw MediaLibraryError.captureSourceStorageFailed("Unable to create mixed chunk staging file.")
        }

        var shouldRemoveStaging = true
        defer {
            if shouldRemoveStaging {
                try? fileManager.removeItem(at: stagingURL)
            }
        }
        let destinationHandle = try FileHandle(forWritingTo: stagingURL)
        defer { try? destinationHandle.close() }

        let stagedMetadata = try streamMixedPCM(
            microphoneURL: microphoneURL,
            systemAudioURL: systemAudioURL,
            destinationHandle: destinationHandle
        )
        if fileManager.fileExists(atPath: destinationURL.path) {
            try assertSafeExistingPath(destinationURL, isDirectory: false)
            let existingMetadata = try captureSourceMetadata(at: destinationURL)
            guard existingMetadata == stagedMetadata else {
                throw MediaLibraryError.captureSourceStorageContentConflict(relativePath: relativePath)
            }
            return ManagedMixedMeetingChunkArtifact(
                sessionID: sessionID,
                sequence: sequence,
                relativePath: relativePath,
                byteCount: existingMetadata.byteCount,
                sha256: existingMetadata.sha256
            )
        }

        do {
            try fileManager.moveItem(at: stagingURL, to: destinationURL)
        } catch {
            throw MediaLibraryError.captureSourceStorageFailed(error.localizedDescription)
        }
        shouldRemoveStaging = false
        let replayedMetadata = try captureSourceMetadata(at: destinationURL)
        guard replayedMetadata == stagedMetadata else {
            throw MediaLibraryError.captureSourceStorageContentConflict(relativePath: relativePath)
        }
        return ManagedMixedMeetingChunkArtifact(
            sessionID: sessionID,
            sequence: sequence,
            relativePath: relativePath,
            byteCount: replayedMetadata.byteCount,
            sha256: replayedMetadata.sha256
        )
    }

    public func removeMeetingCaptureArtifacts(for sessionID: UUID) throws {
        Self.captureSourceStorageLock.lock()
        defer { Self.captureSourceStorageLock.unlock() }

        let directory = meetingCaptureDirectoryURL(sessionID: sessionID)
        guard fileManager.fileExists(atPath: directory.path) else { return }
        try assertSafeExistingPath(directory, isDirectory: true)
        try fileManager.removeItem(at: directory)
    }

    public func removeMixedMeetingChunk(_ artifact: ManagedMixedMeetingChunkArtifact) throws {
        guard artifact.sequence >= 0,
              artifact.relativePath == CaptureSourceArtifactPath.mixedRelativePath(
                sessionID: artifact.sessionID,
                chunkSequence: artifact.sequence
              ) else {
            throw MediaLibraryError.captureSourceStorageFailed("Mixed meeting artifact path is not canonical.")
        }

        Self.captureSourceStorageLock.lock()
        defer { Self.captureSourceStorageLock.unlock() }

        let url = CaptureSourceArtifactPath.mixedURL(
            libraryRootURL: baseURL,
            sessionID: artifact.sessionID,
            chunkSequence: artifact.sequence
        )
        guard fileManager.fileExists(atPath: url.path) else { return }
        try assertSafeExistingPath(url, isDirectory: false)
        let metadata = try captureSourceMetadata(at: url)
        guard metadata.byteCount == artifact.byteCount, metadata.sha256 == artifact.sha256 else {
            throw MediaLibraryError.captureSourceStorageContentConflict(relativePath: artifact.relativePath)
        }
        try fileManager.removeItem(at: url)
    }

    public func removeMixedMeetingChunks(for sessionID: UUID) throws {
        Self.captureSourceStorageLock.lock()
        defer { Self.captureSourceStorageLock.unlock() }

        let directory = meetingCaptureDirectoryURL(sessionID: sessionID)
            .appendingPathComponent("Mixed", isDirectory: true)
        guard fileManager.fileExists(atPath: directory.path) else { return }
        try assertSafeExistingPath(directory, isDirectory: true)
        try fileManager.removeItem(at: directory)
    }

    private func recoverMeetingArtifacts(
        for sourceID: UUID,
        plan: MeetingCaptureSpoolPlan
    ) throws -> MeetingArtifactRecoveryResult {
        let directory = sourceDirectoryURL(sessionID: plan.sessionID, sourceID: sourceID)
        try assertSafeExistingPath(directory, isDirectory: true)
        let files = try fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: []
        )

        var sealedURLs: [Int: URL] = [:]
        var inProgressURLs: [Int: URL] = [:]
        var rejectedSequences = Set<Int>()
        var failures: [MeetingArtifactRecoveryFailure] = []

        func recordFailure(
            _ kind: MeetingArtifactRecoveryFailureKind,
            sequence: Int? = nil,
            relativePath: String? = nil,
            message: String
        ) {
            if let sequence {
                rejectedSequences.insert(sequence)
            }
            failures.append(MeetingArtifactRecoveryFailure(
                kind: kind,
                sourceID: sourceID,
                sequence: sequence,
                relativePath: relativePath,
                message: message
            ))
        }

        for file in files {
            let relativePath = recoveryRelativePath(for: file)
            do {
                try assertSafePath(file)
            } catch let error as MediaLibraryError {
                throw error
            } catch {
                recordFailure(
                    .invalidFormat,
                    relativePath: relativePath,
                    message: error.localizedDescription
                )
                continue
            }
            do {
                let attributes = try fileManager.attributesOfItem(atPath: file.path)
                guard attributes[.type] as? FileAttributeType == .typeRegular else {
                    recordFailure(
                        .invalidFormat,
                        relativePath: relativePath,
                        message: "Meeting artifact is not a regular file."
                    )
                    continue
                }
                guard let (sequence, isInProgress) = meetingChunkFileName(file.lastPathComponent) else {
                    if file.lastPathComponent.hasPrefix("chunk-") {
                        recordFailure(
                            .malformedFileName,
                            relativePath: relativePath,
                            message: "Meeting source directory contains a noncanonical chunk name."
                        )
                    }
                    continue
                }
                if isInProgress {
                    guard inProgressURLs[sequence] == nil else {
                        recordFailure(
                            .duplicateArtifact,
                            sequence: sequence,
                            relativePath: relativePath,
                            message: "Meeting source directory contains duplicate in-progress chunks."
                        )
                        continue
                    }
                    inProgressURLs[sequence] = file
                } else {
                    guard sealedURLs[sequence] == nil else {
                        recordFailure(
                            .duplicateArtifact,
                            sequence: sequence,
                            relativePath: relativePath,
                            message: "Meeting source directory contains duplicate sealed chunks."
                        )
                        continue
                    }
                    sealedURLs[sequence] = file
                }
            } catch {
                recordFailure(
                    .invalidFormat,
                    relativePath: relativePath,
                    message: error.localizedDescription
                )
            }
        }

        let discoveredSequences = Set(sealedURLs.keys).union(inProgressURLs.keys)
        if let highestSequence = discoveredSequences.max() {
            for sequence in 0...highestSequence where !discoveredSequences.contains(sequence) {
                recordFailure(
                    .missingSequence,
                    sequence: sequence,
                    relativePath: CaptureSourceArtifactPath.relativePath(
                        sessionID: plan.sessionID,
                        sourceID: sourceID,
                        chunkSequence: sequence
                    ),
                    message: "Meeting source chunk sequence is missing."
                )
            }
        }

        for sequence in inProgressURLs.keys.sorted() {
            guard let inProgressURL = inProgressURLs[sequence] else { continue }
            let relativePath = recoveryRelativePath(for: inProgressURL)
            do {
                let size = try fileByteCount(at: inProgressURL)
                if size == 0 {
                    try fileManager.removeItem(at: inProgressURL)
                    continue
                }
                guard size <= Int64(plan.chunkByteCount),
                      size % Int64(MeetingCaptureSpoolPlan.bytesPerSample) == 0 else {
                    recordFailure(
                        .invalidFormat,
                        sequence: sequence,
                        relativePath: relativePath,
                        message: "In-progress meeting chunk is oversized or not sample-aligned."
                    )
                    continue
                }

                if let existingURL = sealedURLs[sequence] {
                    let existingMetadata = try captureSourceMetadata(at: existingURL)
                    let inProgressMetadata = try captureSourceMetadata(at: inProgressURL)
                    guard existingMetadata == inProgressMetadata else {
                        recordFailure(
                            .contentConflict,
                            sequence: sequence,
                            relativePath: relativePath,
                            message: "Sealed and in-progress meeting artifacts disagree."
                        )
                        continue
                    }
                    try fileManager.removeItem(at: inProgressURL)
                } else {
                    let finalURL = CaptureSourceArtifactPath.sourceURL(
                        libraryRootURL: baseURL,
                        sessionID: plan.sessionID,
                        sourceID: sourceID,
                        chunkSequence: sequence
                    )
                    let handle = try FileHandle(forWritingTo: inProgressURL)
                    try handle.synchronize()
                    try handle.close()
                    try fileManager.moveItem(at: inProgressURL, to: finalURL)
                    sealedURLs[sequence] = finalURL
                }
            } catch {
                recordFailure(
                    .invalidFormat,
                    sequence: sequence,
                    relativePath: relativePath,
                    message: error.localizedDescription
                )
            }
        }

        let lastSequence = discoveredSequences.max()
        var sealedChunks: [SealedAudioSourceChunk] = []
        for sequence in sealedURLs.keys.sorted() where !rejectedSequences.contains(sequence) {
            guard let url = sealedURLs[sequence] else { continue }
            do {
                let metadata = try captureSourceMetadata(at: url)
                guard metadata.byteCount > 0,
                      metadata.byteCount <= Int64(plan.chunkByteCount),
                      metadata.byteCount % Int64(MeetingCaptureSpoolPlan.bytesPerSample) == 0,
                      sequence == lastSequence || metadata.byteCount == Int64(plan.chunkByteCount) else {
                    recordFailure(
                        .invalidFormat,
                        sequence: sequence,
                        relativePath: recoveryRelativePath(for: url),
                        message: "Meeting source chunk format is invalid."
                    )
                    continue
                }
                let duration = Double(metadata.byteCount)
                    / Double(MeetingCaptureSpoolPlan.sampleRate * MeetingCaptureSpoolPlan.bytesPerSample)
                sealedChunks.append(SealedAudioSourceChunk(
                    sessionID: plan.sessionID,
                    sourceID: sourceID,
                    sequence: sequence,
                    startOffset: Double(sequence * plan.chunkByteCount)
                        / Double(MeetingCaptureSpoolPlan.sampleRate * MeetingCaptureSpoolPlan.bytesPerSample),
                    duration: duration,
                    fileURL: url,
                    relativePath: CaptureSourceArtifactPath.relativePath(
                        sessionID: plan.sessionID,
                        sourceID: sourceID,
                        chunkSequence: sequence
                    ),
                    byteCount: metadata.byteCount,
                    sha256: metadata.sha256
                ))
            } catch {
                recordFailure(
                    .invalidFormat,
                    sequence: sequence,
                    relativePath: recoveryRelativePath(for: url),
                    message: error.localizedDescription
                )
            }
        }
        return MeetingArtifactRecoveryResult(sealedChunks: sealedChunks, failures: failures)
    }

    private func streamMixedPCM(
        microphoneURL: URL?,
        systemAudioURL: URL?,
        destinationHandle: FileHandle
    ) throws -> (byteCount: Int64, sha256: String) {
        let microphoneHandle: FileHandle?
        let microphoneByteCount: Int64
        if let microphoneURL {
            microphoneHandle = try FileHandle(forReadingFrom: microphoneURL)
            microphoneByteCount = try fileByteCount(at: microphoneURL)
        } else {
            microphoneHandle = nil
            microphoneByteCount = 0
        }
        defer { try? microphoneHandle?.close() }

        let systemAudioHandle: FileHandle?
        let systemAudioByteCount: Int64
        if let systemAudioURL {
            systemAudioHandle = try FileHandle(forReadingFrom: systemAudioURL)
            systemAudioByteCount = try fileByteCount(at: systemAudioURL)
        } else {
            systemAudioHandle = nil
            systemAudioByteCount = 0
        }
        defer { try? systemAudioHandle?.close() }
        guard microphoneByteCount % Int64(MeetingCaptureSpoolPlan.bytesPerSample) == 0,
              systemAudioByteCount % Int64(MeetingCaptureSpoolPlan.bytesPerSample) == 0 else {
            throw MediaLibraryError.captureSourceStorageFailed("Meeting source chunks must be Float32 frame aligned.")
        }

        let outputByteCount = max(microphoneByteCount, systemAudioByteCount)
        var remaining = outputByteCount
        var hasher = SHA256()
        while remaining > 0 {
            let count = Int(min(remaining, 64 * 1024))
            let microphoneData = try readPCMBlock(from: microphoneHandle, count: count)
            let systemAudioData = try readPCMBlock(from: systemAudioHandle, count: count)
            let output: Data
            switch (microphoneHandle, systemAudioHandle) {
            case (.some, .none):
                output = microphoneData
            case (.none, .some):
                output = systemAudioData
            case (.some, .some):
                output = mixPCM(
                    microphone: microphoneData,
                    systemAudio: systemAudioData,
                    outputByteCount: count
                )
            case (.none, .none):
                throw MediaLibraryError.captureSourceStorageFailed("Mixed meeting chunks need at least one source.")
            }
            try destinationHandle.write(contentsOf: output)
            hasher.update(data: output)
            remaining -= Int64(output.count)
        }
        try destinationHandle.synchronize()
        return (
            byteCount: outputByteCount,
            sha256: hasher.finalize().map { String(format: "%02x", $0) }.joined()
        )
    }

    private func readPCMBlock(from handle: FileHandle?, count: Int) throws -> Data {
        guard let handle else { return Data() }
        return try handle.read(upToCount: count) ?? Data()
    }

    private func mixPCM(microphone: Data, systemAudio: Data, outputByteCount: Int) -> Data {
        var output = Data(count: outputByteCount)
        microphone.withUnsafeBytes { microphoneBytes in
            systemAudio.withUnsafeBytes { systemAudioBytes in
                output.withUnsafeMutableBytes { outputBytes in
                    for offset in stride(from: 0, to: outputByteCount, by: MeetingCaptureSpoolPlan.bytesPerSample) {
                        let microphoneSample: Float32
                        if offset + MeetingCaptureSpoolPlan.bytesPerSample <= microphoneBytes.count {
                            microphoneSample = Float32(bitPattern: UInt32(littleEndian: microphoneBytes.loadUnaligned(fromByteOffset: offset, as: UInt32.self)))
                        } else {
                            microphoneSample = 0
                        }
                        let systemAudioSample: Float32
                        if offset + MeetingCaptureSpoolPlan.bytesPerSample <= systemAudioBytes.count {
                            systemAudioSample = Float32(bitPattern: UInt32(littleEndian: systemAudioBytes.loadUnaligned(fromByteOffset: offset, as: UInt32.self)))
                        } else {
                            systemAudioSample = 0
                        }
                        let mixed = min(1, max(-1, microphoneSample + systemAudioSample))
                        outputBytes.storeBytes(
                            of: mixed.bitPattern.littleEndian,
                            toByteOffset: offset,
                            as: UInt32.self
                        )
                    }
                }
            }
        }
        return output
    }

    private func validate(plan: MeetingCaptureSpoolPlan) throws {
        guard plan.libraryRootURL.standardizedFileURL.path == baseURL.standardizedFileURL.path,
              plan.microphoneSourceID != plan.systemAudioSourceID,
              plan.chunkByteCount > 0,
              plan.chunkByteCount % MeetingCaptureSpoolPlan.bytesPerSample == 0 else {
            throw MediaLibraryError.captureSourceStorageFailed("Meeting capture spool plan does not belong to this library or is invalid.")
        }
    }

    private func ensureMeetingDirectories(for plan: MeetingCaptureSpoolPlan) throws {
        try validate(plan: plan)
        for sourceID in plan.sourceIDs {
            try ensureSafeDirectory(at: sourceDirectoryURL(
                sessionID: plan.sessionID,
                sourceID: sourceID
            ))
        }
        try ensureSafeDirectory(at: baseURL
            .appendingPathComponent("CaptureSessions", isDirectory: true)
            .appendingPathComponent(plan.sessionID.uuidString, isDirectory: true)
            .appendingPathComponent("Mixed", isDirectory: true))
    }

    private func sourceIDs(in plan: MeetingCaptureSpoolPlan) -> [UUID] {
        plan.sourceIDs
    }

    private func meetingCaptureDirectoryURL(sessionID: UUID) -> URL {
        baseURL
            .appendingPathComponent("CaptureSessions", isDirectory: true)
            .appendingPathComponent(sessionID.uuidString, isDirectory: true)
    }

    private func sourceDirectoryURL(sessionID: UUID, sourceID: UUID) -> URL {
        meetingCaptureDirectoryURL(sessionID: sessionID)
            .appendingPathComponent("Sources", isDirectory: true)
            .appendingPathComponent(sourceID.uuidString, isDirectory: true)
    }

    private func ensureSafeDirectory(at url: URL) throws {
        let root = baseURL.standardizedFileURL
        let destination = url.standardizedFileURL
        guard destination.path == root.path || destination.path.hasPrefix(root.path + "/") else {
            throw MediaLibraryError.captureSourceStorageFailed("Meeting storage path escapes the media library.")
        }

        if !fileManager.fileExists(atPath: root.path) {
            try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        }
        try assertSafeExistingPath(root, isDirectory: true)

        let relativePath = String(destination.path.dropFirst(root.path.count))
        var current = root
        for component in relativePath.split(separator: "/") {
            current.appendPathComponent(String(component), isDirectory: true)
            if fileManager.fileExists(atPath: current.path) {
                try assertSafeExistingPath(current, isDirectory: true)
            } else {
                try fileManager.createDirectory(at: current, withIntermediateDirectories: false)
                try assertSafeExistingPath(current, isDirectory: true)
            }
        }
    }

    private func assertSafeExistingPath(_ url: URL, isDirectory: Bool) throws {
        try assertSafePath(url)
        let attributes = try fileManager.attributesOfItem(atPath: url.path)
        if isDirectory {
            guard attributes[.type] as? FileAttributeType == .typeDirectory else {
                throw MediaLibraryError.captureSourceStorageFailed("Meeting storage directory is not a directory.")
            }
        } else {
            guard attributes[.type] as? FileAttributeType == .typeRegular else {
                throw MediaLibraryError.captureSourceStorageFailed("Meeting artifact is not a regular file.")
            }
        }
    }

    private func assertSafePath(_ url: URL) throws {
        let root = baseURL.standardizedFileURL
        let candidate = url.standardizedFileURL
        guard candidate.path == root.path || candidate.path.hasPrefix(root.path + "/") else {
            throw MediaLibraryError.captureSourceStorageFailed("Meeting storage path escapes the media library.")
        }
        let attributes = try fileManager.attributesOfItem(atPath: candidate.path)
        guard attributes[.type] as? FileAttributeType != .typeSymbolicLink else {
            throw MediaLibraryError.captureSourceStorageFailed("Symbolic links are not valid meeting storage paths.")
        }

        guard candidate.path != root.path else { return }

        var ancestor = candidate.deletingLastPathComponent()
        while ancestor.path != root.path {
            let ancestorAttributes = try fileManager.attributesOfItem(atPath: ancestor.path)
            guard ancestorAttributes[.type] as? FileAttributeType == .typeDirectory else {
                throw MediaLibraryError.captureSourceStorageFailed("Meeting storage path contains an unsafe ancestor.")
            }
            ancestor = ancestor.deletingLastPathComponent()
        }
    }

    private func recoveryRelativePath(for url: URL) -> String? {
        let root = baseURL.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        guard path.hasPrefix(root + "/") else { return nil }
        return String(path.dropFirst(root.count + 1))
    }

    private func meetingChunkFileName(_ fileName: String) -> (sequence: Int, isInProgress: Bool)? {
        let suffix: String
        let isInProgress: Bool
        if fileName.hasSuffix(".pcm.inprogress") {
            suffix = ".pcm.inprogress"
            isInProgress = true
        } else if fileName.hasSuffix(".pcm") {
            suffix = ".pcm"
            isInProgress = false
        } else {
            return nil
        }
        let sequenceString = String(fileName.dropFirst("chunk-".count).dropLast(suffix.count))
        guard fileName.hasPrefix("chunk-"),
              sequenceString.count == 5,
              let sequence = Int(sequenceString),
              String(format: "%05d", sequence) == sequenceString else {
            return nil
        }
        return (sequence, isInProgress)
    }

    private func fileByteCount(at url: URL) throws -> Int64 {
        let attributes = try fileManager.attributesOfItem(atPath: url.path)
        guard let size = attributes[.size] as? NSNumber else {
            throw MediaLibraryError.captureSourceStorageFailed("Unable to read meeting artifact byte count.")
        }
        return size.int64Value
    }
    public func finalizeDownloadedAsset(
        in directoryURL: URL,
        sourceURL: String,
        suggestedTitle: String?
    ) async throws -> ManagedMediaAsset {
        guard let mediaURL = try locatePrimaryMediaFile(in: directoryURL) else {
            throw MediaLibraryError.downloadedMediaMissing
        }

        let thumbnailURL: URL?
        if let existingThumbnail = locateThumbnail(in: directoryURL) {
            thumbnailURL = existingThumbnail
        } else {
            thumbnailURL = try? await generateThumbnailIfPossible(for: mediaURL, in: directoryURL)
        }

        let resolvedTitle = suggestedTitle?.trimmingCharacters(in: .whitespacesAndNewlines)

        return ManagedMediaAsset(
            directoryURL: directoryURL,
            mediaURL: mediaURL,
            thumbnailURL: thumbnailURL,
            sourceKind: .webLink,
            displayName: (resolvedTitle?.isEmpty == false ? resolvedTitle! : mediaURL.lastPathComponent),
            hasSourceMetadataTitle: resolvedTitle?.isEmpty == false,
            originalSourceURL: sourceURL
        )
    }

    private func locatePrimaryMediaFile(in directoryURL: URL) throws -> URL? {
        let items = try fileManager.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        )

        return items
            .filter { url in
                guard let type = UTType(filenameExtension: url.pathExtension.lowercased()) else {
                    return false
                }
                if type.conforms(to: .image) || type.conforms(to: .json) || type.conforms(to: .plainText) {
                    return false
                }
                return type.conforms(to: .audio) || type.conforms(to: .movie) || type.conforms(to: .mpeg4Movie) || type.conforms(to: .video)
            }
            .sorted {
                let leftSize = (try? $0.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                let rightSize = (try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                return leftSize > rightSize
            }
            .first
    }

    private func locateThumbnail(in directoryURL: URL) -> URL? {
        guard let items = try? fileManager.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            return nil
        }

        return items.first { url in
            guard let type = UTType(filenameExtension: url.pathExtension.lowercased()) else {
                return false
            }
            return type.conforms(to: .image)
        }
    }

    private func generateThumbnailIfPossible(for mediaURL: URL, in directoryURL: URL) async throws -> URL? {
        let asset = AVURLAsset(url: mediaURL)
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        guard !videoTracks.isEmpty else { return nil }

        let imageGenerator = AVAssetImageGenerator(asset: asset)
        imageGenerator.appliesPreferredTrackTransform = true

        let duration = try await asset.load(.duration)
        let seconds = max(duration.seconds.isFinite ? duration.seconds : 0, 0.1)
        let cgImage = try imageGenerator.copyCGImage(at: CMTime(seconds: min(1.0, seconds * 0.25), preferredTimescale: 600), actualTime: nil)
        let destinationURL = directoryURL.appendingPathComponent("thumbnail.png")

        guard let destination = CGImageDestinationCreateWithURL(destinationURL as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            return nil
        }

        CGImageDestinationAddImage(destination, cgImage, nil)
        guard CGImageDestinationFinalize(destination) else {
            return nil
        }

        return destinationURL
    }
}
