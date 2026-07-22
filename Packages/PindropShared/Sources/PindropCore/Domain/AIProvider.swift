//
//  AIProvider.swift
//  PindropCore
//
//  Created on 2026-07-22.
//

import Foundation

/// Remote / on-device AI provider identity used by configuration and enhancement.
///
/// Icon and localized UI labels live in the app target
/// (`SharedDomainPresentation.swift`). Core keeps raw values plus semantic
/// endpoint, credential, and capability behavior.
public enum AIProvider: String, CaseIterable, Sendable, Identifiable {
    case openai = "OpenAI"
    case google = "Google"
    case anthropic = "Anthropic"
    case openrouter = "OpenRouter"
    case apple = "Apple"
    case custom = "Custom"

    public var id: String { rawValue }

    /// Stable English display name (not localized). UI localization stays in the app.
    public var displayName: String {
        switch self {
        case .apple:
            return "Apple Intelligence"
        case .custom:
            return "Custom/Local"
        default:
            return rawValue
        }
    }

    public var defaultEndpoint: String {
        switch self {
        case .openai: return "https://api.openai.com/v1/chat/completions"
        case .google: return "https://generativelanguage.googleapis.com/v1beta"
        case .anthropic: return "https://api.anthropic.com/v1/messages"
        case .openrouter: return "https://openrouter.ai/api/v1/chat/completions"
        case .apple: return ""
        case .custom: return ""
        }
    }

    public var apiKeyPlaceholder: String {
        switch self {
        case .openai: return "sk-..."
        case .google: return "AIza..."
        case .anthropic: return "sk-ant-..."
        case .openrouter: return "sk-or-..."
        case .apple: return "Not required"
        case .custom: return "Enter API key"
        }
    }

    /// Whether this provider requires API credentials (key + endpoint) to operate.
    public var requiresAPICredentials: Bool {
        switch self {
        case .apple: return false
        default: return true
        }
    }

    public var isImplemented: Bool {
        switch self {
        case .openai, .openrouter, .custom, .anthropic, .apple: return true
        default: return false
        }
    }
}

/// Concrete custom / local provider flavor when `AIProvider.custom` is selected.
///
/// Icon properties live in the app target. Core keeps storage keys, endpoints,
/// and model-listing capability.
public enum CustomProviderType: String, CaseIterable, Sendable, Identifiable {
    case custom = "Custom"
    case ollama = "Ollama"
    case lmStudio = "LM Studio"

    public var id: String { rawValue }

    public var storageKey: String {
        switch self {
        case .custom:
            return "custom"
        case .ollama:
            return "ollama"
        case .lmStudio:
            return "lm-studio"
        }
    }

    public var requiresAPIKey: Bool {
        self == .custom
    }

    public var supportsModelListing: Bool {
        self != .custom
    }

    public var defaultEndpoint: String {
        switch self {
        case .custom:
            return ""
        case .ollama:
            return "http://localhost:11434/v1/chat/completions"
        case .lmStudio:
            return "http://localhost:1234/v1/chat/completions"
        }
    }

    public var defaultModelsEndpoint: String? {
        switch self {
        case .custom:
            return nil
        case .ollama:
            return "http://localhost:11434/v1/models"
        case .lmStudio:
            return "http://localhost:1234/v1/models"
        }
    }

    public var apiKeyPlaceholder: String {
        switch self {
        case .custom:
            return "Enter API key"
        case .ollama:
            return "Optional (usually not needed)"
        case .lmStudio:
            return "Optional unless auth is enabled"
        }
    }

    public var endpointPlaceholder: String {
        switch self {
        case .custom:
            return "https://your-api.com/v1/chat/completions"
        case .ollama:
            return defaultEndpoint
        case .lmStudio:
            return defaultEndpoint
        }
    }

    public var modelPlaceholder: String {
        switch self {
        case .custom:
            return "e.g., gpt-4o"
        case .ollama:
            return "e.g., llama3.2"
        case .lmStudio:
            return "e.g., local-model"
        }
    }
}
