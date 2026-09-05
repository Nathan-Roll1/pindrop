//
//  SharedDomainPresentation.swift
//  Pindrop
//
//  Created on 2026-07-22.
//
//  Presentation-only helpers for domain types owned by PindropCore.
//  Compiles after final import wiring brings PindropCore into the app target.
//

import Foundation
import PindropCore
import PindropData

// MARK: - AppLanguage

extension AppLanguage {
    var displayName: String {
        displayName(locale: .autoupdatingCurrent)
    }

    var pickerLabel: String {
        pickerLabel(locale: .autoupdatingCurrent)
    }

    func displayName(locale: Locale) -> String {
        localized(displayKey, locale: locale)
    }

    func pickerLabel(locale: Locale) -> String {
        let name = displayName(locale: locale)
        guard !isSelectable else { return name }
        return String(format: localized("%@ (Coming Soon)", locale: locale), name)
    }

    /// The language name rendered in its own locale (e.g. "Français" for French).
    /// Returns `nil` for `.automatic` since there is no single native representation.
    func nativeDisplayName(currentLocale: Locale) -> String? {
        guard self != .automatic else { return nil }
        let native = displayName(locale: self.locale)
        let current = displayName(locale: currentLocale)
        // Only show the native label when it actually differs from the current-locale label.
        guard native != current else { return nil }
        return native
    }
}

// MARK: - AppLocale

extension AppLocale {
    func displayName(locale: Locale) -> String {
        guard self != .automatic else {
            return localized("Automatic (Follow System)", locale: locale)
        }

        return locale.localizedString(forIdentifier: rawValue)
            ?? locale.localizedString(forLanguageCode: rawValue)
            ?? rawValue
    }

    func pickerLabel(locale: Locale) -> String {
        displayName(locale: locale)
    }

    func nativeDisplayName(currentLocale: Locale) -> String? {
        guard self != .automatic else { return nil }
        let native = displayName(locale: self.locale)
        let current = displayName(locale: currentLocale)
        guard native != current else { return nil }
        return native
    }
}

// MARK: - TranscriptionBackend

extension TranscriptionBackend {
    var displayNameKey: String {
        switch self {
        case .parakeet: return "Nemotron (default)"
        case .appleSpeechTranscriber: return "Apple SpeechTranscriber (macOS 26+)"
        }
    }
}

// MARK: - AIProvider / CustomProviderType icons

extension AIProvider {
    var icon: Icon {
        switch self {
        case .openai: return .openai
        case .google: return .google
        case .anthropic: return .anthropic
        case .openrouter: return .openrouter
        case .apple: return .sparkles
        case .custom: return .server
        }
    }
}

extension CustomProviderType {
    var icon: Icon {
        switch self {
        case .custom:
            return .server
        case .ollama, .lmStudio:
            return .hardDrive
        }
    }
}

// MARK: - NotesGrouping

extension NotesGrouping.SectionKey {
    /// English fallback titles used in tests and as localization keys.
    /// Day sections return a medium-style date string for the section day.
    var localizationKey: String {
        switch self {
        case .pinned:
            return "Pinned"
        case .today:
            return "Today"
        case .yesterday:
            return "Yesterday"
        case .day(let date):
            return NotesGroupingPresentation.dayFormatter.string(from: date)
        }
    }
}

private enum NotesGroupingPresentation {
    static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter
    }()
}

// MARK: - TranscriptionRecord meeting metadata

extension TranscriptionRecord {
    /// Formatted meeting metadata line, e.g. `"3 speakers · diarized · summary ready"`.
    /// Builds from localized parts; returns an empty string when nothing applies.
    func meetingMetadataString(locale: Locale) -> String {
        var parts: [String] = []

        let count = speakerCount
        if count > 0 {
            if count == 1 {
                parts.append(localized("1 speaker", locale: locale))
            } else {
                parts.append(
                    String(format: localized("%d speakers", locale: locale), count)
                )
            }
        }

        if isDiarized {
            parts.append(localized("diarized", locale: locale))
        }

        if hasSummary {
            parts.append(localized("summary ready", locale: locale))
        }

        return parts.joined(separator: " · ")
    }
}

// MARK: - Bundle version metadata

extension Bundle {
    var appShortVersionString: String {
        infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
    }

    var appBuildVersionString: String {
        infoDictionary?["CFBundleVersion"] as? String ?? "0"
    }
}
