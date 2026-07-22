//
//  ContributionCaptureMetadata.swift
//  PindropData
//
//  Created on 2026-07-22.
//

import Foundation

/// Host-supplied snapshot of contribution capture settings.
///
/// Resolved once per capture by `ContributionService` so PindropData never
/// depends on `SettingsStore` or `Bundle`.
public struct ContributionCaptureMetadata: Equatable, Sendable {
    public let isEnabled: Bool
    public let languageRawValue: String
    public let localeIdentifier: String
    public let appVersion: String

    public init(
        isEnabled: Bool,
        languageRawValue: String,
        localeIdentifier: String,
        appVersion: String
    ) {
        self.isEnabled = isEnabled
        self.languageRawValue = languageRawValue
        self.localeIdentifier = localeIdentifier
        self.appVersion = appVersion
    }
}
