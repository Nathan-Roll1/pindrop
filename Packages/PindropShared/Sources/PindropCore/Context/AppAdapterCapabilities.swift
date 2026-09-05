//
//  AppAdapterCapabilities.swift
//  PindropCore
//
//  Created on 2026-07-22.
//

import Foundation

/// Explicit capabilities that an app adapter declares.
/// Used by downstream consumers (mention formatter, prompt builder) to decide
/// what context features are available for a given app.
public struct AppAdapterCapabilities: Equatable, Sendable {
    public let supportsFileMentions: Bool
    public let supportsCodeContext: Bool
    public let supportsDocsMentions: Bool
    public let supportsDiffContext: Bool
    public let supportsWebContext: Bool
    public let supportsChatHistory: Bool
    public let mentionPrefix: String
    /// Must contain "{path}".
    public let mentionTemplate: String
    public let displayName: String

    public init(
        supportsFileMentions: Bool,
        supportsCodeContext: Bool,
        supportsDocsMentions: Bool,
        supportsDiffContext: Bool,
        supportsWebContext: Bool,
        supportsChatHistory: Bool,
        mentionPrefix: String,
        mentionTemplate: String,
        displayName: String
    ) {
        self.supportsFileMentions = supportsFileMentions
        self.supportsCodeContext = supportsCodeContext
        self.supportsDocsMentions = supportsDocsMentions
        self.supportsDiffContext = supportsDiffContext
        self.supportsWebContext = supportsWebContext
        self.supportsChatHistory = supportsChatHistory
        self.mentionPrefix = mentionPrefix
        self.mentionTemplate = mentionTemplate
        self.displayName = displayName
    }

    public static let none = AppAdapterCapabilities(
        supportsFileMentions: false,
        supportsCodeContext: false,
        supportsDocsMentions: false,
        supportsDiffContext: false,
        supportsWebContext: false,
        supportsChatHistory: false,
        mentionPrefix: "@",
        mentionTemplate: "@{path}",
        displayName: "Unknown App"
    )

    public func renderMention(relativePath: String) -> String {
        mentionTemplate.replacingOccurrences(of: MentionTemplateCatalog.pathToken, with: relativePath)
    }

    public func renderMention(path: String) -> String {
        renderMention(relativePath: path)
    }

    public func withMentionFormatting(mentionPrefix: String, mentionTemplate: String) -> AppAdapterCapabilities {
        AppAdapterCapabilities(
            supportsFileMentions: supportsFileMentions,
            supportsCodeContext: supportsCodeContext,
            supportsDocsMentions: supportsDocsMentions,
            supportsDiffContext: supportsDiffContext,
            supportsWebContext: supportsWebContext,
            supportsChatHistory: supportsChatHistory,
            mentionPrefix: mentionPrefix,
            mentionTemplate: mentionTemplate,
            displayName: displayName
        )
    }

    public func withMentionFormatting(prefix: String, template: String) -> AppAdapterCapabilities {
        withMentionFormatting(mentionPrefix: prefix, mentionTemplate: template)
    }
}
