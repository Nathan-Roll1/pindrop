//
//  TranscriptionBackend.swift
//  PindropCore
//
//  Created on 2026-07-22.
//

import Foundation

/// Which streaming transcription engine the user prefers. Availability at runtime may
/// force the service to substitute a different backend - see
/// `SettingsStore.resolvedTranscriptionBackend` for the effective value.
///
/// Presentation (`displayNameKey` / localized labels) lives in the app target.
public enum TranscriptionBackend: String, CaseIterable, Sendable, Identifiable {
    /// Nemotron Speech Streaming 0.6B via FluidAudio. Natively punctuated and
    /// capitalized; available on all supported macOS versions; requires a ~630 MB model
    /// download. (Raw value stays "parakeet" for stored-settings compatibility - the
    /// case predates the Nemotron engine swap.)
    case parakeet = "parakeet"

    /// Apple's on-device `Speech.SpeechTranscriber` (macOS 26+ / iOS 26+). Ships with the OS,
    /// zero download, but locale coverage follows Apple's supported-locales list.
    case appleSpeechTranscriber = "apple"

    public var id: String { rawValue }
}
