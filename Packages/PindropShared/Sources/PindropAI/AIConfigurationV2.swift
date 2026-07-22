//
//  AIConfigurationV2.swift
//  PindropAI
//
//  Created on 2026-04-16.
//
//  V2 AI configuration: separates provider credentials from per-purpose model assignments.
//  Replaces the legacy singleton aiProvider/aiModel/aiEnhancementEnabled/aiEnhancementPrompt
//  pattern with [ProviderConfig] (non-secret, persisted as JSON in AppStorage) + secrets
//  stored in Keychain under UUID-keyed accounts, joined to [EnhancementPurpose:
//  ModelAssignment] so different features can use different providers and models.
//
//  Credentials are never owned here. The host resolves Keychain values into
//  `ResolvedAssignment.apiKey` / `endpoint` before calling PindropAI services.
//

import Foundation
import PindropCore

// MARK: - ProviderConfig

/// A user-configured AI provider. Non-secret; persisted as JSON in `@AppStorage`.
/// API key and endpoint live in Keychain keyed by `id.uuidString` (host-owned).
public struct ProviderConfig: Codable, Identifiable, Equatable, Hashable, Sendable {
    public let id: UUID
    public var kind: AIProvider
    public var customKind: CustomProviderType?
    public var displayName: String

    public init(
        id: UUID = UUID(),
        kind: AIProvider,
        customKind: CustomProviderType? = nil,
        displayName: String
    ) {
        self.id = id
        self.kind = kind
        self.customKind = (kind == .custom) ? (customKind ?? .custom) : nil
        self.displayName = displayName
    }

    // MARK: Codable

    enum CodingKeys: String, CodingKey {
        case id
        case kind
        case customKind
        case displayName
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(UUID.self, forKey: .id)
        let kindRaw = try container.decode(String.self, forKey: .kind)
        self.kind = AIProvider(rawValue: kindRaw) ?? .openai
        if let customRaw = try container.decodeIfPresent(String.self, forKey: .customKind) {
            self.customKind = CustomProviderType(rawValue: customRaw)
        } else {
            self.customKind = nil
        }
        self.displayName = try container.decode(String.self, forKey: .displayName)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(kind.rawValue, forKey: .kind)
        try container.encodeIfPresent(customKind?.rawValue, forKey: .customKind)
        try container.encode(displayName, forKey: .displayName)
    }
}

// MARK: - EnhancementPurpose

/// Every AI use-case in the app. Each purpose may (or may not) have a ModelAssignment.
public enum EnhancementPurpose: String, Codable, CaseIterable, Hashable, Sendable {
    /// Post-stop holistic transcription cleanup. Runs when live refinement is off (or all failed).
    case transcriptionEnhancement

    /// Live mid-utterance refinement driven by Parakeet EOU. When assigned, suppresses the
    /// post-stop holistic pass for that session.
    case streamingRefinement

    /// Note body enhancement (quick capture, standalone notes).
    case noteEnhancement

    /// Note metadata generation (title, tags) - previously hardcoded to the same model as
    /// noteEnhancement; now independently addressable.
    case noteMetadata

    /// Transcription metadata generation (not currently called from AppCoordinator, reserved
    /// for future use).
    case transcriptionMetadata

    /// Whether the user can pick a preset or author a custom prompt for this purpose via the
    /// Settings UI. `false` means the purpose uses a built-in prompt tuned for a specific
    /// output shape (e.g. `@Generable` schema, diff-friendly edit list) that a user-supplied
    /// prompt could silently break. Locked purposes: streaming refinement (tightly coupled
    /// to the coordinator diff + edit-list schema) and the two metadata generators (which
    /// rely on `@Generable` schemas inside AppleFoundationModelsEnhancer).
    public var supportsUserPrompt: Bool {
        switch self {
        case .transcriptionEnhancement, .noteEnhancement:
            return true
        case .streamingRefinement, .noteMetadata, .transcriptionMetadata:
            return false
        }
    }
}

// MARK: - ModelAssignment

/// Which provider + model to use for a given purpose, with an optional prompt customization.
/// Persisted as JSON in `@AppStorage` inside a `[EnhancementPurpose: ModelAssignment]` map.
public struct ModelAssignment: Codable, Equatable, Hashable, Sendable {
    public var providerID: UUID
    public var modelID: String
    /// Stable identifier of a built-in or user preset. `nil` means "use the built-in default
    /// preset for this purpose" (resolved by the caller).
    public var promptPresetID: String?
    /// Inline override. When non-nil, takes precedence over the preset.
    public var promptOverride: String?

    public init(
        providerID: UUID,
        modelID: String,
        promptPresetID: String? = nil,
        promptOverride: String? = nil
    ) {
        self.providerID = providerID
        self.modelID = modelID
        self.promptPresetID = promptPresetID
        self.promptOverride = promptOverride
    }
}

// MARK: - ResolvedAssignment

/// Output of the host's assignment resolver (e.g. `SettingsStore.resolveAssignment(for:)`).
/// Carries everything a call site needs to make an AI call without peeking at settings.
/// `apiKey` and `endpoint` are already resolved by the host at resolution time; `prompt` is
/// resolved from override → preset → purpose default. PindropAI never reads Keychain.
public struct ResolvedAssignment: Sendable {
    public let purpose: EnhancementPurpose
    public let providerID: UUID
    public let kind: AIProvider
    public let customKind: CustomProviderType?
    public let displayName: String
    public let modelID: String
    public let endpoint: String?
    public let apiKey: String?
    public let prompt: String?
    /// Raw `promptPresetID` the assignment pointed at; callers can use this to surface which
    /// preset was in effect (e.g. for telemetry, history rows).
    public let promptPresetID: String?

    public init(
        purpose: EnhancementPurpose,
        providerID: UUID,
        kind: AIProvider,
        customKind: CustomProviderType?,
        displayName: String,
        modelID: String,
        endpoint: String?,
        apiKey: String?,
        prompt: String?,
        promptPresetID: String?
    ) {
        self.purpose = purpose
        self.providerID = providerID
        self.kind = kind
        self.customKind = customKind
        self.displayName = displayName
        self.modelID = modelID
        self.endpoint = endpoint
        self.apiKey = apiKey
        self.prompt = prompt
        self.promptPresetID = promptPresetID
    }
}
