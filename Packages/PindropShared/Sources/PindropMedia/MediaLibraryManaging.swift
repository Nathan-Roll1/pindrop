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

    public var errorDescription: String? {
        switch self {
        case .localFileImportFailed(let message):
            return "Media import failed: \(message)"
        case .downloadedMediaMissing:
            return "Download finished but no playable media file was found."
        case .downloadFailed(let message):
            return "Media download failed: \(message)"
        }
    }
}

/// Portable storage surface for job directories, local imports, recorded audio, and finalized downloads.
public protocol MediaLibraryManaging: AnyObject {
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
}
