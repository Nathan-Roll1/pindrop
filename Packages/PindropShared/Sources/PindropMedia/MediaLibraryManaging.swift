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
}
