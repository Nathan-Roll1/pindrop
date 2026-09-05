//
//  ManagedMediaAsset.swift
//  PindropMedia
//
//  Created on 2026-07-22.
//

import Foundation
import PindropCore

/// A media file stored under a managed media library job directory.
public struct ManagedMediaAsset: Equatable, Sendable {
    public let directoryURL: URL
    public let mediaURL: URL
    public let thumbnailURL: URL?
    public let sourceKind: MediaSourceKind
    public let displayName: String
    public let hasSourceMetadataTitle: Bool
    public let originalSourceURL: String?

    public init(
        directoryURL: URL,
        mediaURL: URL,
        thumbnailURL: URL?,
        sourceKind: MediaSourceKind,
        displayName: String,
        hasSourceMetadataTitle: Bool,
        originalSourceURL: String?
    ) {
        self.directoryURL = directoryURL
        self.mediaURL = mediaURL
        self.thumbnailURL = thumbnailURL
        self.sourceKind = sourceKind
        self.displayName = displayName
        self.hasSourceMetadataTitle = hasSourceMetadataTitle
        self.originalSourceURL = originalSourceURL
    }
}
