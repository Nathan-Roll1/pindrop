//
//  ContextSessionTransition.swift
//  PindropCore
//
//  Created on 2026-07-22.
//

import Foundation

public struct ContextSessionTransition: Sendable, Equatable {
    public static let maxSelectedTextPreviewLength = 160

    public let timestamp: Date
    public let trigger: ContextSessionUpdateTrigger
    public let appBundleIdentifier: String?
    public let appName: String?
    public let windowTitle: String?
    public let focusedElementRole: String?
    public let documentPath: String?
    public let selectedTextPreview: String?
    public let activeFilePath: String?
    public let activeFileConfidence: Double?
    public let workspacePath: String?
    public let workspaceConfidence: Double?
    public let outputMode: String?
    public let contextTags: [String]
    public let transitionSignature: String?

    public init(
        timestamp: Date = Date(),
        trigger: ContextSessionUpdateTrigger,
        appBundleIdentifier: String? = nil,
        appName: String? = nil,
        windowTitle: String? = nil,
        focusedElementRole: String? = nil,
        documentPath: String? = nil,
        selectedText: String? = nil,
        activeFilePath: String? = nil,
        activeFileConfidence: Double? = nil,
        workspacePath: String? = nil,
        workspaceConfidence: Double? = nil,
        outputMode: String? = nil,
        contextTags: [String] = [],
        transitionSignature: String? = nil
    ) {
        self.timestamp = timestamp
        self.trigger = trigger
        self.appBundleIdentifier = appBundleIdentifier
        self.appName = appName
        self.windowTitle = windowTitle
        self.focusedElementRole = focusedElementRole
        self.documentPath = documentPath
        self.activeFilePath = activeFilePath
        self.activeFileConfidence = activeFileConfidence.flatMap(Self.normalizedConfidence)
        self.workspacePath = workspacePath
        self.workspaceConfidence = workspaceConfidence.flatMap(Self.normalizedConfidence)
        self.outputMode = outputMode
        self.contextTags = contextTags
        self.transitionSignature = transitionSignature
        if let selectedText,
           selectedText.count > Self.maxSelectedTextPreviewLength {
            self.selectedTextPreview = String(selectedText.prefix(Self.maxSelectedTextPreviewLength)) + "…"
        } else {
            self.selectedTextPreview = selectedText
        }
    }
    private static func normalizedConfidence(_ confidence: Double) -> Double? {
        guard confidence.isFinite else { return nil }
        return min(max(confidence, 0), 1)
    }
}
