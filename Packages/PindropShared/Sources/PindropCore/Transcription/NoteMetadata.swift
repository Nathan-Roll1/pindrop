//
//  NoteMetadata.swift
//  PindropCore
//
//  Created on 2026-07-22.
//

import Foundation

/// AI-generated note title and tags used by NotesStore metadata generation.
public struct NoteMetadata: Codable, Equatable, Sendable {
    public let title: String
    public let tags: [String]

    public init(title: String, tags: [String]) {
        self.title = title
        self.tags = tags
    }
}

/// AI-generated transcription title/summary pair.
public struct TranscriptionMetadata: Codable, Equatable, Sendable {
    public let title: String?
    public let summary: String

    public init(title: String?, summary: String) {
        self.title = title
        self.summary = summary
    }
}
