//
//  DictationAudioRetention.swift
//  PindropCore
//
//  Created on 2026-07-22.
//

import Foundation

/// How long dictation (`voiceRecording`) audio files are retained on disk.
/// Imported / media-backed audio is never governed by this setting.
///
/// Picker labels live in the app target.
public enum DictationAudioRetention: String, CaseIterable, Sendable, Identifiable {
    case off
    case days7
    case days30
    case forever

    public var id: String { rawValue }

    /// Calendar-day window before audio is eligible for deletion.
    /// `nil` means never expire; `0` means do not persist.
    public var retentionDays: Int? {
        switch self {
        case .off: return 0
        case .days7: return 7
        case .days30: return 30
        case .forever: return nil
        }
    }

    /// Time interval for expiry checks. `nil` = forever; `.off` returns `0`.
    public var retentionInterval: TimeInterval? {
        guard let days = retentionDays else { return nil }
        return TimeInterval(days) * 24 * 60 * 60
    }
}
