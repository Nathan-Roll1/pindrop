//
//  MediaSourceKind.swift
//  PindropCore
//
//  Created on 2026-07-22.
//

import Foundation

/// Origin of a transcription record or media job.
public enum MediaSourceKind: String, Codable, CaseIterable, Sendable {
    case voiceRecording
    case manualCapture
    case importedFile
    case webLink

    /// True when the item is backed by managed media rather than ephemeral dictation audio.
    public var isMediaBacked: Bool {
        switch self {
        case .voiceRecording:
            return false
        case .manualCapture, .importedFile, .webLink:
            return true
        }
    }
}
