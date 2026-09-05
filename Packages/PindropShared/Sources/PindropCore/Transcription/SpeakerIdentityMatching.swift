//
//  SpeakerIdentityMatching.swift
//  PindropCore
//
//  Created on 2026-07-22.
//

import Foundation

/// Result of matching an embedding against known speaker profiles.
public struct SpeakerIdentityMatch: Equatable, Sendable {
    public let profileID: UUID
    public let displayName: String
    public let similarity: Float

    public init(profileID: UUID, displayName: String, similarity: Float) {
        self.profileID = profileID
        self.displayName = displayName
        self.similarity = similarity
    }
}

/// Matching-only port used by speech engines.
///
/// Profile CRUD and training live on the broader `SpeakerIdentityManaging`
/// protocol in PindropData, which refines this port.
@MainActor
public protocol SpeakerIdentityMatching: AnyObject {
    func bestMatch(for embedding: [Float]) throws -> SpeakerIdentityMatch?
    func bestMatches(for embeddings: [[Float]]) throws -> [SpeakerIdentityMatch?]
}

extension SpeakerIdentityMatching {
    /// Compatibility default for test doubles and older callers: sequential single matches.
    public func bestMatches(for embeddings: [[Float]]) throws -> [SpeakerIdentityMatch?] {
        try embeddings.map { try bestMatch(for: $0) }
    }
}
