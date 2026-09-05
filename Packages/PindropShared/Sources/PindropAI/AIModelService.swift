//
//  AIModelService.swift
//  PindropAI
//
//  Created on 2026-02-14.
//
//  Lists remote / local provider models and caches results under an injected
//  storage base URL. Construction performs no network I/O; callers invoke
//  fetch/refresh explicitly. Credentials are supplied per call by the host.
//

import Foundation
import PindropCore

@MainActor
public final class AIModelService {
    public struct AIModel: Codable, Identifiable, Equatable, Sendable {
        public let id: String
        public let name: String
        public let provider: AIProvider
        public let description: String?
        public let contextLength: Int?

        private enum CodingKeys: String, CodingKey {
            case id
            case name
            case provider
            case description
            case contextLength
        }

        public init(
            id: String,
            name: String,
            provider: AIProvider,
            description: String? = nil,
            contextLength: Int? = nil
        ) {
            self.id = id
            self.name = name
            self.provider = provider
            self.description = description
            self.contextLength = contextLength
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decode(String.self, forKey: .id)
            name = try container.decode(String.self, forKey: .name)
            let providerRaw = try container.decode(String.self, forKey: .provider)
            guard let provider = AIProvider(rawValue: providerRaw) else {
                throw ModelError.invalidProvider(providerRaw)
            }
            self.provider = provider
            description = try container.decodeIfPresent(String.self, forKey: .description)
            contextLength = try container.decodeIfPresent(Int.self, forKey: .contextLength)
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(id, forKey: .id)
            try container.encode(name, forKey: .name)
            try container.encode(provider.rawValue, forKey: .provider)
            try container.encodeIfPresent(description, forKey: .description)
            try container.encodeIfPresent(contextLength, forKey: .contextLength)
        }
    }

    public struct AIModelCache: Codable, Equatable, Sendable {
        public let models: [AIModel]
        public let fetchedAt: Date

        public init(models: [AIModel], fetchedAt: Date) {
            self.models = models
            self.fetchedAt = fetchedAt
        }
    }

    public enum ModelError: Error, LocalizedError, Equatable, Sendable {
        case invalidEndpoint
        case invalidResponse
        case apiError(String)
        case missingAPIKey
        case unsupportedProvider
        case cacheWriteFailed(String)
        case invalidProvider(String)

        public var errorDescription: String? {
            switch self {
            case .invalidEndpoint:
                return "Invalid API endpoint URL"
            case .invalidResponse:
                return "Invalid response from API"
            case .apiError(let message):
                return "API error: \(message)"
            case .missingAPIKey:
                return "Missing API key"
            case .unsupportedProvider:
                return "Unsupported AI provider"
            case .cacheWriteFailed(let message):
                return "Failed to write model cache: \(message)"
            case .invalidProvider(let provider):
                return "Invalid AI provider: \(provider)"
            }
        }
    }

    private static let cacheStaleInterval: TimeInterval = 60 * 60 * 24 * 7

    /// Directory that holds `ai-model-cache-*.json` files.
    /// Hosts pass the platform sandbox location (macOS:
    /// `Application Support/Pindrop/AIModels`).
    private let storageBaseURL: URL
    private let session: URLSessionProtocol
    private let fileManager: FileManager

    /// - Parameters:
    ///   - storageBaseURL: Directory used for on-disk model list caches. Must be
    ///     provided by the host; this type never reconstructs Application Support.
    ///   - session: Network session used only when fetch/refresh is called.
    ///   - fileManager: File manager for cache read/write.
    /// Construction performs no network I/O.
    public init(
        storageBaseURL: URL,
        session: URLSessionProtocol = URLSession.shared,
        fileManager: FileManager = .default
    ) {
        self.storageBaseURL = storageBaseURL
        self.session = session
        self.fileManager = fileManager
    }

    public func fetchModels(
        for provider: AIProvider,
        apiKey: String?,
        endpointOverride: String? = nil,
        customLocalProvider: CustomProviderType = .custom
    ) async throws -> [AIModel] {
        do {
            switch provider {
            case .openrouter:
                return try await fetchOpenRouterModels()
            case .openai:
                return try await fetchOpenAIModels(apiKey: apiKey)
            case .anthropic:
                return fetchAnthropicModels()
            case .custom:
                return try await fetchCustomProviderModels(
                    endpointOverride: endpointOverride,
                    apiKey: apiKey,
                    customLocalProvider: customLocalProvider
                )
            default:
                throw ModelError.unsupportedProvider
            }
        } catch let error as ModelError {
            throw error
        } catch {
            throw ModelError.apiError(error.localizedDescription)
        }
    }

    public func refreshModels(
        for provider: AIProvider,
        apiKey: String?,
        endpointOverride: String? = nil,
        customLocalProvider: CustomProviderType = .custom
    ) async throws -> [AIModel] {
        let models = try await fetchModels(
            for: provider,
            apiKey: apiKey,
            endpointOverride: endpointOverride,
            customLocalProvider: customLocalProvider
        )
        try saveCache(
            AIModelCache(models: models, fetchedAt: Date()),
            for: provider,
            customLocalProvider: customLocalProvider
        )
        return models
    }

    public func getCachedModels(
        for provider: AIProvider,
        customLocalProvider: CustomProviderType = .custom
    ) -> [AIModel]? {
        guard let cache = loadCache(for: provider, customLocalProvider: customLocalProvider) else {
            return nil
        }
        guard !isCacheStale(cache) else {
            return nil
        }
        return cache.models
    }

    public func isCacheStale(
        for provider: AIProvider,
        customLocalProvider: CustomProviderType = .custom
    ) -> Bool {
        guard let cache = loadCache(for: provider, customLocalProvider: customLocalProvider) else {
            return true
        }
        return isCacheStale(cache)
    }

    private func isCacheStale(_ cache: AIModelCache) -> Bool {
        Date().timeIntervalSince(cache.fetchedAt) > Self.cacheStaleInterval
    }

    private func cacheFileURL(
        for provider: AIProvider,
        customLocalProvider: CustomProviderType = .custom
    ) -> URL {
        let slug: String
        switch provider {
        case .custom:
            slug = "custom-\(customLocalProvider.storageKey)"
        default:
            slug = provider.rawValue.lowercased().replacingOccurrences(of: " ", with: "-")
        }
        return storageBaseURL.appendingPathComponent("ai-model-cache-\(slug).json", isDirectory: false)
    }

    private func loadCache(
        for provider: AIProvider,
        customLocalProvider: CustomProviderType = .custom
    ) -> AIModelCache? {
        let url = cacheFileURL(for: provider, customLocalProvider: customLocalProvider)
        guard fileManager.fileExists(atPath: url.path) else {
            return nil
        }
        do {
            let data = try Data(contentsOf: url)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode(AIModelCache.self, from: data)
        } catch {
            Log.aiEnhancement.warning("Failed to read model cache for \(provider.rawValue): \(error.localizedDescription)")
            return nil
        }
    }

    private func saveCache(
        _ cache: AIModelCache,
        for provider: AIProvider,
        customLocalProvider: CustomProviderType = .custom
    ) throws {
        let url = cacheFileURL(for: provider, customLocalProvider: customLocalProvider)
        do {
            try fileManager.createDirectory(at: storageBaseURL, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(cache)
            try data.write(to: url, options: [.atomic])
            Log.aiEnhancement.info("Saved model cache for \(provider.rawValue) (\(cache.models.count) models)")
        } catch {
            Log.aiEnhancement.error("Failed to write model cache for \(provider.rawValue): \(error.localizedDescription)")
            throw ModelError.cacheWriteFailed(error.localizedDescription)
        }
    }

    private func fetchOpenRouterModels() async throws -> [AIModel] {
        Log.aiEnhancement.info("Fetching OpenRouter models")
        let request = try buildRequest(urlString: "https://openrouter.ai/api/v1/models", apiKey: nil)
        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw ModelError.invalidResponse
        }

        guard httpResponse.statusCode == 200 else {
            throw parseHTTPError(from: data, statusCode: httpResponse.statusCode)
        }

        do {
            let decoder = JSONDecoder()
            let payload = try decoder.decode(OpenRouterResponse.self, from: data)
            let models = payload.data.map {
                AIModel(
                    id: $0.id,
                    name: $0.name ?? $0.id,
                    provider: .openrouter,
                    description: $0.description,
                    contextLength: $0.contextLength
                )
            }
            return models.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        } catch {
            throw ModelError.invalidResponse
        }
    }

    private func fetchOpenAIModels(apiKey: String?) async throws -> [AIModel] {
        guard let apiKey = apiKey?.trimmingCharacters(in: .whitespacesAndNewlines), !apiKey.isEmpty else {
            throw ModelError.missingAPIKey
        }

        Log.aiEnhancement.info("Fetching OpenAI models")
        return try await fetchOpenAICompatibleModels(
            urlString: "https://api.openai.com/v1/models",
            provider: .openai,
            apiKey: apiKey
        )
    }

    private func fetchCustomProviderModels(
        endpointOverride: String?,
        apiKey: String?,
        customLocalProvider: CustomProviderType
    ) async throws -> [AIModel] {
        guard customLocalProvider.supportsModelListing else {
            throw ModelError.unsupportedProvider
        }

        let modelsURL = try modelsURLString(
            from: endpointOverride,
            customLocalProvider: customLocalProvider
        )
        let normalizedAPIKey = apiKey?.trimmingCharacters(in: .whitespacesAndNewlines)

        Log.aiEnhancement.info("Fetching \(customLocalProvider.rawValue) models")
        return try await fetchOpenAICompatibleModels(
            urlString: modelsURL,
            provider: .custom,
            apiKey: normalizedAPIKey
        )
    }

    private func fetchAnthropicModels() -> [AIModel] {
        [
            AIModel(id: "claude-haiku-4-5", name: "Claude Haiku 4.5", provider: .anthropic,
                    description: "Fast and affordable", contextLength: 200_000),
            AIModel(id: "claude-sonnet-4-6", name: "Claude Sonnet 4.6", provider: .anthropic,
                    description: "Balanced performance", contextLength: 1_000_000),
            AIModel(id: "claude-opus-4-6", name: "Claude Opus 4.6", provider: .anthropic,
                    description: "Most capable", contextLength: 1_000_000),
        ]
    }

    private func fetchOpenAICompatibleModels(
        urlString: String,
        provider: AIProvider,
        apiKey: String?
    ) async throws -> [AIModel] {
        let normalizedAPIKey = apiKey?.trimmingCharacters(in: .whitespacesAndNewlines)
        let request = try buildRequest(urlString: urlString, apiKey: normalizedAPIKey?.isEmpty == false ? normalizedAPIKey : nil)
        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw ModelError.invalidResponse
        }

        guard httpResponse.statusCode == 200 else {
            throw parseHTTPError(from: data, statusCode: httpResponse.statusCode)
        }

        do {
            let decoder = JSONDecoder()
            let payload = try decoder.decode(OpenAIResponse.self, from: data)
            let models = payload.data.map {
                AIModel(
                    id: $0.id,
                    name: $0.id,
                    provider: provider,
                    description: nil,
                    contextLength: nil
                )
            }
            return models.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        } catch {
            throw ModelError.invalidResponse
        }
    }

    private func modelsURLString(
        from endpointOverride: String?,
        customLocalProvider: CustomProviderType
    ) throws -> String {
        if let endpointOverride = endpointOverride?.trimmingCharacters(in: .whitespacesAndNewlines),
           !endpointOverride.isEmpty
        {
            if endpointOverride.hasSuffix("/models") {
                return endpointOverride
            }
            if endpointOverride.hasSuffix("/chat/completions") {
                return String(endpointOverride.dropLast("/chat/completions".count)) + "/models"
            }
            if endpointOverride.hasSuffix("/completions") {
                return String(endpointOverride.dropLast("/completions".count)) + "/models"
            }
            if endpointOverride.hasSuffix("/responses") {
                return String(endpointOverride.dropLast("/responses".count)) + "/models"
            }
            if endpointOverride.hasSuffix("/v1") {
                return endpointOverride + "/models"
            }
            if endpointOverride.contains("/v1/") {
                guard let url = URL(string: endpointOverride), var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
                    throw ModelError.invalidEndpoint
                }
                components.path = "/v1/models"
                guard let rebuiltURL = components.url else {
                    throw ModelError.invalidEndpoint
                }
                return rebuiltURL.absoluteString
            }
            return endpointOverride + "/models"
        }

        guard let defaultModelsEndpoint = customLocalProvider.defaultModelsEndpoint else {
            throw ModelError.invalidEndpoint
        }
        return defaultModelsEndpoint
    }

    private func buildRequest(urlString: String, apiKey: String?) throws -> URLRequest {
        guard let url = URL(string: urlString) else {
            throw ModelError.invalidEndpoint
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Pindrop/1.0", forHTTPHeaderField: "X-Title")
        if let apiKey {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        return request
    }

    private func parseHTTPError(from data: Data, statusCode: Int) -> ModelError {
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let error = json["error"] as? [String: Any],
           let message = error["message"] as? String {
            return .apiError(message)
        }
        return .apiError("HTTP \(statusCode)")
    }
}

// MARK: - Wire formats (internal)

private struct OpenRouterResponse: Decodable {
    struct Model: Decodable {
        let id: String
        let name: String?
        let description: String?
        let contextLength: Int?

        private enum CodingKeys: String, CodingKey {
            case id
            case name
            case description
            case contextLength = "context_length"
        }
    }

    let data: [Model]
}

private struct OpenAIResponse: Decodable {
    struct Model: Decodable {
        let id: String
        let object: String?
        let created: Int?
    }

    let data: [Model]
}
