//
//  AppContextInfo.swift
//  PindropCore
//
//  Created on 2026-07-22.
//

import Foundation

/// Structured information about the frontmost application and window,
/// captured via Accessibility APIs when available.
public struct AppContextInfo: Sendable, Equatable {
    public let bundleIdentifier: String?
    public let appName: String
    public let windowTitle: String?
    public let focusedElementRole: String?
    public let focusedElementValue: String?
    public let selectedText: String?
    public let documentPath: String?
    public let browserURL: String?

    public init(
        bundleIdentifier: String?,
        appName: String,
        windowTitle: String?,
        focusedElementRole: String?,
        focusedElementValue: String?,
        selectedText: String?,
        documentPath: String?,
        browserURL: String?
    ) {
        self.bundleIdentifier = bundleIdentifier
        self.appName = appName
        self.windowTitle = windowTitle
        self.focusedElementRole = focusedElementRole
        self.focusedElementValue = focusedElementValue
        self.selectedText = selectedText
        self.documentPath = documentPath
        self.browserURL = browserURL
    }

    /// Whether this context has any meaningful AX-sourced data
    /// beyond just the app name.
    public var hasDetailedContext: Bool {
        windowTitle != nil || focusedElementRole != nil ||
        selectedText != nil || documentPath != nil || browserURL != nil
    }
}
