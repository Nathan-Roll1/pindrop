//
//  AppLanguage.swift
//  PindropCore
//
//  Created on 2026-07-22.
//

import Foundation

/// Dictation / transcription language preference.
///
/// Localization and picker presentation helpers live in the app target
/// (`SharedDomainPresentation.swift`). Core keeps only stable raw values and
/// semantic capabilities used by shared engines.
public enum AppLanguage: String, CaseIterable, Sendable, Identifiable {
    case automatic = "auto"
    case english = "en"
    case russian = "ru"
    case ukrainian = "uk"
    case simplifiedChinese = "zh-Hans"
    case spanish = "es"
    case french = "fr"
    case german = "de"
    case turkish = "tr"
    case japanese = "ja"
    case portugueseBrazil = "pt-BR"
    case italian = "it"
    case dutch = "nl"
    case korean = "ko"
    case hindi = "hi"
    case malayalam = "ml"
    case polish = "pl"

    public var id: String { rawValue }

    /// English source key used by the app target for localized display names.
    /// Not localized here - presentation resolves via `localized(_:locale:)`.
    public var displayKey: String {
        switch self {
        case .automatic: return "Automatic (Follow System)"
        case .english: return "English"
        case .russian: return "Russian"
        case .ukrainian: return "Ukrainian"
        case .simplifiedChinese: return "Simplified Chinese"
        case .spanish: return "Spanish"
        case .french: return "French"
        case .german: return "German"
        case .turkish: return "Turkish"
        case .japanese: return "Japanese"
        case .portugueseBrazil: return "Portuguese (Brazil)"
        case .italian: return "Italian"
        case .dutch: return "Dutch"
        case .korean: return "Korean"
        case .hindi: return "Hindi"
        case .malayalam: return "Malayalam"
        case .polish: return "Polish"
        }
    }

    public var isSelectable: Bool {
        switch self {
        case .automatic, .english, .russian, .ukrainian, .simplifiedChinese,
             .spanish, .french, .german, .turkish, .japanese, .portugueseBrazil,
             .italian, .dutch, .korean, .hindi, .malayalam, .polish:
            return true
        }
    }

    public var isEnglish: Bool { self == .english }

    public var locale: Locale {
        guard let identifier = localeIdentifier else { return .autoupdatingCurrent }
        return Locale(identifier: identifier)
    }

    /// Whisper / engine language code. `nil` for automatic (follow system).
    public var whisperLanguageCode: String? {
        switch self {
        case .automatic: return nil
        case .english: return "en"
        case .russian: return "ru"
        case .ukrainian: return "uk"
        case .simplifiedChinese: return "zh"
        case .spanish: return "es"
        case .french: return "fr"
        case .german: return "de"
        case .turkish: return "tr"
        case .japanese: return "ja"
        case .portugueseBrazil: return "pt"
        case .italian: return "it"
        case .dutch: return "nl"
        case .korean: return "ko"
        case .hindi: return "hi"
        case .malayalam: return "ml"
        case .polish: return "pl"
        }
    }

    private var localeIdentifier: String? {
        switch self {
        case .automatic: return nil
        case .english: return "en"
        case .russian: return "ru"
        case .ukrainian: return "uk"
        case .simplifiedChinese: return "zh-Hans"
        case .spanish: return "es"
        case .french: return "fr"
        case .german: return "de"
        case .turkish: return "tr"
        case .japanese: return "ja"
        case .portugueseBrazil: return "pt-BR"
        case .italian: return "it"
        case .dutch: return "nl"
        case .korean: return "ko"
        case .hindi: return "hi"
        case .malayalam: return "ml"
        case .polish: return "pl"
        }
    }
}
