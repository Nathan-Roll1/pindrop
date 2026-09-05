//
//  PromptRoutingSignal.swift
//  PindropCore
//
//  Created on 2026-07-22.
//

import Foundation

/// Normalized signal extracted from context that downstream systems can use
/// to select prompt presets or profiles automatically.
/// This is a foundation type; no auto-switch behavior is implemented yet.
public struct PromptRoutingSignal: Sendable, Equatable {
    public let appBundleIdentifier: String?
    public let appName: String?
    public let windowTitle: String?
    public let workspacePath: String?
    public let browserDomain: String?
    public let isCodeEditorContext: Bool
    public let terminalProviderIdentifier: String?

    public init(
        appBundleIdentifier: String?,
        appName: String?,
        windowTitle: String?,
        workspacePath: String?,
        browserDomain: String?,
        isCodeEditorContext: Bool,
        terminalProviderIdentifier: String? = nil
    ) {
        self.appBundleIdentifier = appBundleIdentifier
        self.appName = appName
        self.windowTitle = windowTitle
        self.workspacePath = workspacePath
        self.browserDomain = browserDomain
        self.isCodeEditorContext = isCodeEditorContext
        self.terminalProviderIdentifier = terminalProviderIdentifier
    }

    public static let empty = PromptRoutingSignal(
        appBundleIdentifier: nil,
        appName: nil,
        windowTitle: nil,
        workspacePath: nil,
        browserDomain: nil,
        isCodeEditorContext: false,
        terminalProviderIdentifier: nil
    )
}
