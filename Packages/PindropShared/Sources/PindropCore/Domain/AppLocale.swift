//
//  AppLocale.swift
//  PindropCore
//
//  Created on 2026-07-22.
//

import Foundation

/// Interface (UI) locale preference, separate from dictation `AppLanguage`.
///
/// Localized display helpers live in the app target
/// (`SharedDomainPresentation.swift`).
public enum AppLocale: String, CaseIterable, Sendable, Identifiable {
    case automatic = "auto"
    case arabic = "ar"
    case bengali = "bn"
    case czech = "cs"
    case danish = "da"
    case german = "de"
    case english = "en"
    case greek = "el"
    case spanish = "es"
    case finnish = "fi"
    case french = "fr"
    case hebrew = "he"
    case hindi = "hi"
    case hungarian = "hu"
    case indonesian = "id"
    case italian = "it"
    case japanese = "ja"
    case korean = "ko"
    case malay = "ms"
    case norwegianBokmal = "nb"
    case dutch = "nl"
    case polish = "pl"
    case portugueseBrazil = "pt-BR"
    case romanian = "ro"
    case russian = "ru"
    case swedish = "sv"
    case thai = "th"
    case turkish = "tr"
    case ukrainian = "uk"
    case vietnamese = "vi"
    case traditionalChinese = "zh-Hant"
    case simplifiedChinese = "zh-Hans"

    public var id: String { rawValue }

    public var isSelectable: Bool { true }

    public var locale: Locale {
        guard self != .automatic else { return .autoupdatingCurrent }
        return Locale(identifier: rawValue)
    }
}
