//
//  MediaLibraryManaging.swift
//  PindropMedia
//
//  Created on 2026-07-22.
//

import Foundation
import PindropCore

/// Errors from managed-media storage, import, and direct HTTP download paths.
public enum MediaLibraryError: Error, LocalizedError, Sendable {
    case localFileImportFailed(String)
    case downloadedMediaMissing
    case downloadFailed(String)
    case captureSourceStorageUnsupported
    case captureSourceStorageContentConflict(relativePath: String)
    case captureSourceStorageFailed(String)

    public var errorDescription: String? {
        switch self {
        case .localFileImportFailed(let message):
            return "Media import failed: \(message)"
        case .downloadedMediaMissing:
            return "Download finished but no playable media file was found."
        case .downloadFailed(let message):
            return "Media download failed: \(message)"
        case .captureSourceStorageUnsupported:
            return "Capture source storage is not supported by this media library."
        case .captureSourceStorageContentConflict(let relativePath):
            return "Capture source storage content conflicts with the existing artifact at \(relativePath)."
        case .captureSourceStorageFailed(let message):
            return "Capture source storage failed: \(message)"
        }
    }
}

/// Durable metadata for one source-separated PCM capture chunk.
///
/// `relativePath` is relative to the media-library root. Resolve it against
/// the media library's `baseURL`; do not treat it as an input file path.
public struct ManagedCaptureSourceArtifact: Equatable, Sendable {
    public let sessionID: UUID
    public let sourceID: UUID
    public let chunkSequence: Int
    public let relativePath: String
    public let byteCount: Int64
    public let sha256: String

    /// Persistence-facing spelling used by capture-chunk ledger models.
    public var managedMediaPath: String {
        relativePath
    }

    public init(
        sessionID: UUID,
        sourceID: UUID,
        chunkSequence: Int,
        relativePath: String,
        byteCount: Int64,
        sha256: String
    ) {
        self.sessionID = sessionID
        self.sourceID = sourceID
        self.chunkSequence = chunkSequence
        self.relativePath = relativePath
        self.byteCount = byteCount
        self.sha256 = sha256
    }
}

/// Durable metadata for a derived mixed PCM meeting chunk.
public struct ManagedMixedMeetingChunkArtifact: Equatable, Sendable {
    public let sessionID: UUID
    public let sequence: Int
    public let relativePath: String
    public let byteCount: Int64
    public let sha256: String

    public init(
        sessionID: UUID,
        sequence: Int,
        relativePath: String,
        byteCount: Int64,
        sha256: String
    ) {
        self.sessionID = sessionID
        self.sequence = sequence
        self.relativePath = relativePath
        self.byteCount = byteCount
        self.sha256 = sha256
    }
}

/// The kind of a recoverable meeting-artifact problem found while scanning a source spool.
public enum MeetingArtifactRecoveryFailureKind: String, Equatable, Sendable {
    /// The source directory disappeared after its spool plan was created.
    case sourceUnavailable
    /// A file claiming to be a chunk does not use the canonical chunk filename.
    case malformedFileName
    /// More than one file claims the same source and sequence.
    case duplicateArtifact
    /// A source sequence has no artifact on disk.
    case missingSequence
    /// A canonical artifact cannot be used as PCM for this spool plan.
    case invalidFormat
    /// Sealed and in-progress artifacts for one sequence disagree.
    case contentConflict
}

/// A recoverable, scoped problem found while rebuilding a meeting's source inventory.
///
/// `sourceUnavailable` applies to the entire source. Other failures apply only to
/// `sequence` when present; a malformed filename is diagnostic-only because it
/// cannot be matched to a persisted sequence.
public struct MeetingArtifactRecoveryFailure: Equatable, Sendable {
    public let kind: MeetingArtifactRecoveryFailureKind
    public let sourceID: UUID
    public let sequence: Int?
    public let relativePath: String?
    public let message: String
    public let isRetryable: Bool

    public init(
        kind: MeetingArtifactRecoveryFailureKind,
        sourceID: UUID,
        sequence: Int? = nil,
        relativePath: String? = nil,
        message: String,
        isRetryable: Bool = true
    ) {
        self.kind = kind
        self.sourceID = sourceID
        self.sequence = sequence
        self.relativePath = relativePath
        self.message = message
        self.isRetryable = isRetryable
    }
}

/// The verified inventory and recoverable diagnostics produced by a spool scan.
public struct MeetingArtifactRecoveryResult: Equatable, Sendable {
    public let sealedChunks: [SealedAudioSourceChunk]
    public let failures: [MeetingArtifactRecoveryFailure]

    public init(
        sealedChunks: [SealedAudioSourceChunk],
        failures: [MeetingArtifactRecoveryFailure]
    ) {
        self.sealedChunks = sealedChunks
        self.failures = failures
    }
}

/// Portable storage surface for job directories, local imports, recorded audio, and finalized downloads.
public protocol MediaLibraryManaging: AnyObject, Sendable {
    func makeJobDirectory(for jobID: UUID) throws -> URL
    func importLocalFile(at sourceURL: URL, jobID: UUID) async throws -> ManagedMediaAsset
    func storeRecordedAudio(
        _ audioData: Data,
        jobID: UUID,
        displayName: String,
        sourceKind: MediaSourceKind
    ) throws -> ManagedMediaAsset
    func finalizeDownloadedAsset(
        in directoryURL: URL,
        sourceURL: String,
        suggestedTitle: String?
    ) async throws -> ManagedMediaAsset
    func storeCapturePCMFile(
        at sourceURL: URL,
        sessionID: UUID,
        sourceID: UUID,
        chunkSequence: Int
    ) throws -> ManagedCaptureSourceArtifact
    func makeMeetingCaptureSpoolPlan(
        sessionID: UUID,
        microphoneSourceID: UUID,
        systemAudioSourceID: UUID
    ) throws -> MeetingCaptureSpoolPlan
    func recoverMeetingArtifacts(for plan: MeetingCaptureSpoolPlan) throws -> MeetingArtifactRecoveryResult
    func resolveArtifactURL(for chunk: SealedAudioSourceChunk) throws -> URL
    func makeMixedMeetingChunk(
        sessionID: UUID,
        sequence: Int,
        microphone: SealedAudioSourceChunk?,
        systemAudio: SealedAudioSourceChunk?
    ) throws -> ManagedMixedMeetingChunkArtifact
    func removeMixedMeetingChunk(_ artifact: ManagedMixedMeetingChunkArtifact) throws
    func removeMixedMeetingChunks(for sessionID: UUID) throws
}

public extension MediaLibraryManaging {
    func storeCapturePCMFile(
        at sourceURL: URL,
        sessionID: UUID,
        sourceID: UUID,
        chunkSequence: Int
    ) throws -> ManagedCaptureSourceArtifact {
        throw MediaLibraryError.captureSourceStorageUnsupported
    }

    func makeMeetingCaptureSpoolPlan(
        sessionID: UUID,
        microphoneSourceID: UUID,
        systemAudioSourceID: UUID
    ) throws -> MeetingCaptureSpoolPlan {
        throw MediaLibraryError.captureSourceStorageUnsupported
    }

    func recoverMeetingArtifacts(for plan: MeetingCaptureSpoolPlan) throws -> MeetingArtifactRecoveryResult {
        throw MediaLibraryError.captureSourceStorageUnsupported
    }

    func resolveArtifactURL(for chunk: SealedAudioSourceChunk) throws -> URL {
        throw MediaLibraryError.captureSourceStorageUnsupported
    }

    func makeMixedMeetingChunk(
        sessionID: UUID,
        sequence: Int,
        microphone: SealedAudioSourceChunk?,
        systemAudio: SealedAudioSourceChunk?
    ) throws -> ManagedMixedMeetingChunkArtifact {
        throw MediaLibraryError.captureSourceStorageUnsupported
    }

    func removeMixedMeetingChunk(_ artifact: ManagedMixedMeetingChunkArtifact) throws {
        throw MediaLibraryError.captureSourceStorageUnsupported
    }

    func removeMixedMeetingChunks(for sessionID: UUID) throws {
        throw MediaLibraryError.captureSourceStorageUnsupported
    }
}
