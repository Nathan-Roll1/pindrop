//
//  CaptureStageAssignmentResolver.swift
//  Pindrop
//
//  Resolves the current supported settings into an immutable capture-stage assignment.
//

import Foundation
import PindropAI
import PindropCore
import PindropData
import PindropSpeech

/// Failures that prevent a required capture stage from being assigned truthfully.
enum CaptureStageAssignmentResolverError: LocalizedError, Equatable {
    case unknownBatchModel(String)
    case batchModelComingSoon(String)
    case batchModelUnavailable(String)
    case batchModelNotDownloaded(String)
    case missingBatchModelCredential(provider: String)
    case notePromptResolutionFailed(identifier: String?, message: String)
    case invalidPersistedNoteGenerationAssignment
    case persistedNoteProviderUnavailable(String)
    case persistedNotePromptUnavailable(String)
    case missingPersistedNoteProviderCredential(provider: String)

    var errorDescription: String? {
        switch self {
        case .unknownBatchModel(let identifier):
            "The selected transcription model '\(identifier)' is not in Pindrop's supported catalog."
        case .batchModelComingSoon(let identifier):
            "The selected transcription model '\(identifier)' is not available yet."
        case .batchModelUnavailable(let identifier):
            "The selected transcription model '\(identifier)' is not available on this Mac."
        case .batchModelNotDownloaded(let identifier):
            "The selected transcription model '\(identifier)' must be downloaded before capture starts."
        case .missingBatchModelCredential(let provider):
            "A transcription API key is required for the selected \(provider) model."
        case .notePromptResolutionFailed(let identifier, let message):
            "The note prompt preset '\(identifier ?? "default")' could not be resolved: \(message)"
        case .invalidPersistedNoteGenerationAssignment:
            "The saved note-generation assignment is not a generative-AI assignment."
        case .persistedNoteProviderUnavailable(let identifier):
            "The saved note-generation provider '\(identifier)' is no longer available."
        case .persistedNotePromptUnavailable(let identifier):
            "The saved note-generation prompt '\(identifier)' is unavailable."
        case .missingPersistedNoteProviderCredential(let provider):
            "The saved note-generation provider \(provider) no longer has a usable API key."
        }
    }
}

/// A non-persisting, non-secret description of the capture assignment a new session would use.
struct CaptureStageAssignmentPreview: Equatable, Sendable, Identifiable {
    enum State: Equatable, Sendable {
        case disabled
        case unavailable
        case ready
    }

    let stage: CapturePipelineStage
    let state: State
    let value: String?

    var id: CapturePipelineStage { stage }
}

/// Resolves capture stages exclusively from the current supported settings and model catalog.
///
/// Returned assignments freeze the logical provider UUID, model, and resolved prompt, never
/// credentials, endpoint URLs, or provider configuration that are late-bound at runtime.
@MainActor
final class CaptureStageAssignmentResolver {
    private struct StageSelection {
        let providerKind: CaptureAssignmentProviderKind
        let providerIdentifier: String
        let modelIdentifier: String?
        let previewValue: String?
        let previewState: CaptureStageAssignmentPreview.State
    }

    private let settings: SettingsStore
    private let modelManager: ModelManager
    private let promptPresetStore: PromptPresetStore

    init(
        settings: SettingsStore,
        modelManager: ModelManager,
        promptPresetStore: PromptPresetStore
    ) {
        self.settings = settings
        self.modelManager = modelManager
        self.promptPresetStore = promptPresetStore
    }

    /// Shows the exact support state for each stage a newly started capture session would select.
    /// This projection contains only catalog identifiers and display labels; credentials and
    /// endpoints remain in Keychain and are never exposed here.
    static func previewAssignments(
        settings: SettingsStore,
        modelManager: ModelManager,
        activeBatchModelName: String?
    ) -> [CaptureStageAssignmentPreview] {
        let live = liveSelection(settings: settings, modelManager: modelManager)
        let diarization = diarizationSelection(settings: settings, modelManager: modelManager)
        let note = noteSelection(settings: settings)
        let selectedBatchModel = activeBatchModelName ?? settings.selectedModel
        let final: CaptureStageAssignmentPreview

        do {
            final = preview(
                stage: .finalTranscription,
                selection: try finalSelection(
                    settings: settings,
                    modelManager: modelManager,
                    activeBatchModelName: activeBatchModelName
                )
            )
        } catch {
            final = CaptureStageAssignmentPreview(
                stage: .finalTranscription,
                state: .unavailable,
                value: modelManager.availableModels
                    .first(where: { $0.name == selectedBatchModel })?
                    .displayName ?? selectedBatchModel
            )
        }

        return [
            preview(stage: .liveTranscription, selection: live),
            final,
            preview(stage: .diarization, selection: diarization),
            preview(stage: .noteGeneration, selection: note),
        ]
    }

    func select(
        stage: CapturePipelineStage,
        attempt: Int,
        activeBatchModelName: String?,
        selectedAt: Date = .now
    ) throws -> CaptureStageAssignment {
        guard attempt >= 1 else {
            throw CaptureStageAssignmentError.invalidAttempt(attempt)
        }
        switch stage {
        case .liveTranscription:
            return try selectLiveTranscription(attempt: attempt, selectedAt: selectedAt)
        case .finalTranscription:
            return try selectFinalTranscription(
                activeBatchModelName: activeBatchModelName,
                attempt: attempt,
                selectedAt: selectedAt
            )
        case .diarization:
            return try selectDiarization(attempt: attempt, selectedAt: selectedAt)
        case .noteGeneration:
            return try selectNoteGeneration(attempt: attempt, selectedAt: selectedAt)
        }
    }

    /// Resolves current runtime provider configuration and Keychain credential for a persisted
    /// logical provider UUID without consulting the current purpose assignment. The persisted
    /// assignment freezes its UUID, model, and resolved prompt; current provider configuration,
    /// endpoint, and credential are intentionally late-bound for in-progress and recovered captures.
    func resolveNoteGenerationRuntime(
        for persistedAssignment: CaptureStageAssignment
    ) throws -> ResolvedAssignment {
        guard persistedAssignment.stage == .noteGeneration,
              persistedAssignment.providerKind == .generativeAI,
              let providerID = UUID(uuidString: persistedAssignment.providerIdentifier),
              let modelIdentifier = persistedAssignment.modelIdentifier,
              !modelIdentifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            throw CaptureStageAssignmentResolverError.invalidPersistedNoteGenerationAssignment
        }
        if let prompt = persistedAssignment.prompt,
           let identifier = prompt.presetIdentifier,
           prompt.resolvedPrompt == nil
        {
            throw CaptureStageAssignmentResolverError.persistedNotePromptUnavailable(identifier)
        }

        guard let provider = settings.provider(withID: providerID) else {
            throw CaptureStageAssignmentResolverError.persistedNoteProviderUnavailable(
                persistedAssignment.providerIdentifier
            )
        }
        guard Self.providerHasUsableCredential(provider, settings: settings) else {
            throw CaptureStageAssignmentResolverError.missingPersistedNoteProviderCredential(
                provider: provider.displayName
            )
        }

        return ResolvedAssignment(
            purpose: .noteEnhancement,
            providerID: provider.id,
            kind: provider.kind,
            customKind: provider.customKind,
            displayName: provider.displayName,
            modelID: modelIdentifier,
            endpoint: Self.resolvedEndpoint(for: provider, settings: settings),
            apiKey: settings.loadProviderAPIKey(forProviderID: provider.id),
            prompt: persistedAssignment.prompt?.resolvedPrompt,
            promptPresetID: persistedAssignment.prompt?.presetIdentifier
        )
    }

    private func selectLiveTranscription(
        attempt: Int,
        selectedAt: Date
    ) throws -> CaptureStageAssignment {
        try assignment(
            stage: .liveTranscription,
            selection: Self.liveSelection(settings: settings, modelManager: modelManager),
            attempt: attempt,
            selectedAt: selectedAt
        )
    }

    private func selectFinalTranscription(
        activeBatchModelName: String?,
        attempt: Int,
        selectedAt: Date
    ) throws -> CaptureStageAssignment {
        try assignment(
            stage: .finalTranscription,
            selection: try Self.finalSelection(
                settings: settings,
                modelManager: modelManager,
                activeBatchModelName: activeBatchModelName
            ),
            attempt: attempt,
            selectedAt: selectedAt
        )
    }

    private func selectDiarization(
        attempt: Int,
        selectedAt: Date
    ) throws -> CaptureStageAssignment {
        try assignment(
            stage: .diarization,
            selection: Self.diarizationSelection(settings: settings, modelManager: modelManager),
            attempt: attempt,
            selectedAt: selectedAt
        )
    }

    private func selectNoteGeneration(
        attempt: Int,
        selectedAt: Date
    ) throws -> CaptureStageAssignment {
        let selection = Self.noteSelection(settings: settings)
        guard selection.providerKind == .generativeAI else {
            return try assignment(
                stage: .noteGeneration,
                selection: selection,
                attempt: attempt,
                selectedAt: selectedAt
            )
        }
        guard let configuredAssignment = settings.assignment(for: .noteEnhancement) else {
            preconditionFailure("A ready note-generation selection requires a configured assignment.")
        }

        let presetIdentifier = configuredAssignment.promptPresetID
        let resolvedPrompt: String
        if let override = BuiltInPresets.normalizedPromptOverride(
            configuredAssignment.promptOverride,
            presetID: presetIdentifier
        ) {
            resolvedPrompt = override
        } else {
            do {
                resolvedPrompt = try promptPresetStore.resolvePrompt(for: presetIdentifier)
                    ?? SettingsStore.Defaults.noteEnhancementPrompt
            } catch {
                throw CaptureStageAssignmentResolverError.notePromptResolutionFailed(
                    identifier: presetIdentifier,
                    message: error.localizedDescription
                )
            }
        }

        return try assignment(
            stage: .noteGeneration,
            selection: selection,
            prompt: CapturePromptSnapshot(
                presetIdentifier: presetIdentifier,
                resolvedPrompt: resolvedPrompt
            ),
            attempt: attempt,
            selectedAt: selectedAt
        )
    }

    private static func liveSelection(
        settings: SettingsStore,
        modelManager: ModelManager
    ) -> StageSelection {
        guard settings.streamingFeatureEnabled else {
            return StageSelection(
                providerKind: .disabled,
                providerIdentifier: "streaming-disabled",
                modelIdentifier: nil,
                previewValue: nil,
                previewState: .disabled
            )
        }

        switch settings.resolvedTranscriptionBackend {
        case .parakeet:
            let profile = settings.streamingChunkProfile
            let modelIdentifier = profile.repoFolderName
            let previewValue = "\(TranscriptionBackend.parakeet.displayNameKey) · \(profile.modelSubdirectory)"
            guard modelManager.isStreamingChunkVariantDownloaded(profile) else {
                return StageSelection(
                    providerKind: .bestEffortUnavailable,
                    providerIdentifier: TranscriptionBackend.parakeet.rawValue,
                    modelIdentifier: modelIdentifier,
                    previewValue: previewValue,
                    previewState: .unavailable
                )
            }
            return StageSelection(
                providerKind: .streamingSpeech,
                providerIdentifier: TranscriptionBackend.parakeet.rawValue,
                modelIdentifier: modelIdentifier,
                previewValue: previewValue,
                previewState: .ready
            )
        case .appleSpeechTranscriber:
            return StageSelection(
                providerKind: .streamingSpeech,
                providerIdentifier: TranscriptionBackend.appleSpeechTranscriber.rawValue,
                modelIdentifier: "apple-speech-transcriber/progressive",
                previewValue: TranscriptionBackend.appleSpeechTranscriber.displayNameKey,
                previewState: .ready
            )
        }
    }

    private static func finalSelection(
        settings: SettingsStore,
        modelManager: ModelManager,
        activeBatchModelName: String?
    ) throws -> StageSelection {
        let modelIdentifier = activeBatchModelName ?? settings.selectedModel
        guard let model = modelManager.availableModels.first(where: { $0.name == modelIdentifier }) else {
            throw CaptureStageAssignmentResolverError.unknownBatchModel(modelIdentifier)
        }

        switch model.availability {
        case .available:
            break
        case .comingSoon:
            throw CaptureStageAssignmentResolverError.batchModelComingSoon(model.name)
        case .requiresSetup:
            throw CaptureStageAssignmentResolverError.batchModelUnavailable(model.name)
        }

        if model.provider.isLocal {
            guard model.provider == .appleSpeech || modelManager.isModelDownloaded(model.name) else {
                throw CaptureStageAssignmentResolverError.batchModelNotDownloaded(model.name)
            }
        } else if !settings.hasTranscriptionAPIKey(for: model.provider) {
            throw CaptureStageAssignmentResolverError.missingBatchModelCredential(provider: model.provider.rawValue)
        }

        return StageSelection(
            providerKind: .batchSpeech,
            providerIdentifier: model.provider.rawValue,
            modelIdentifier: model.name,
            previewValue: model.displayName,
            previewState: .ready
        )
    }

    private static func diarizationSelection(
        settings: SettingsStore,
        modelManager: ModelManager
    ) -> StageSelection {
        let modelIdentifier = FeatureModelType.diarization.repoFolderName
        guard settings.diarizationFeatureEnabled else {
            return StageSelection(
                providerKind: .disabled,
                providerIdentifier: "user-disabled",
                modelIdentifier: nil,
                previewValue: nil,
                previewState: .disabled
            )
        }
        guard modelManager.isOfflineDiarizationReady() else {
            return StageSelection(
                providerKind: .bestEffortUnavailable,
                providerIdentifier: FeatureModelType.diarization.rawValue,
                modelIdentifier: modelIdentifier,
                previewValue: nil,
                previewState: .unavailable
            )
        }
        return StageSelection(
            providerKind: .localDiarization,
            providerIdentifier: FeatureModelType.diarization.rawValue,
            modelIdentifier: modelIdentifier,
            previewValue: nil,
            previewState: .ready
        )
    }

    private static func noteSelection(settings: SettingsStore) -> StageSelection {
        guard let configuredAssignment = settings.assignment(for: .noteEnhancement) else {
            return StageSelection(
                providerKind: .disabled,
                providerIdentifier: "note-enhancement-unassigned",
                modelIdentifier: nil,
                previewValue: nil,
                previewState: .disabled
            )
        }
        let modelIdentifier = configuredAssignment.modelID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !modelIdentifier.isEmpty else {
            return StageSelection(
                providerKind: .bestEffortUnavailable,
                providerIdentifier: configuredAssignment.providerID.uuidString,
                modelIdentifier: configuredAssignment.modelID,
                previewValue: settings.provider(withID: configuredAssignment.providerID)?.displayName,
                previewState: .unavailable
            )
        }

        let provider = settings.provider(withID: configuredAssignment.providerID)
        let previewValue = provider.map { "\($0.displayName) · \(configuredAssignment.modelID)" }
            ?? configuredAssignment.modelID
        let previewState: CaptureStageAssignmentPreview.State
        if let provider, providerHasUsableCredential(provider, settings: settings) {
            previewState = .ready
        } else {
            previewState = .unavailable
        }

        return StageSelection(
            providerKind: .generativeAI,
            providerIdentifier: configuredAssignment.providerID.uuidString,
            modelIdentifier: configuredAssignment.modelID,
            previewValue: previewValue,
            previewState: previewState
        )
    }

    private static func preview(
        stage: CapturePipelineStage,
        selection: StageSelection
    ) -> CaptureStageAssignmentPreview {
        CaptureStageAssignmentPreview(
            stage: stage,
            state: selection.previewState,
            value: selection.previewValue
        )
    }

    private static func providerHasUsableCredential(
        _ provider: ProviderConfig,
        settings: SettingsStore
    ) -> Bool {
        switch provider.kind {
        case .apple:
            return true
        case .custom:
            guard (provider.customKind ?? .custom).requiresAPIKey else { return true }
        default:
            break
        }
        return !(settings.loadProviderAPIKey(forProviderID: provider.id)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty ?? true)
    }

    private static func resolvedEndpoint(
        for provider: ProviderConfig,
        settings: SettingsStore
    ) -> String? {
        if let endpoint = settings.loadProviderEndpoint(forProviderID: provider.id) {
            return endpoint
        }
        switch provider.kind {
        case .apple:
            return nil
        case .custom:
            let endpoint = (provider.customKind ?? .custom).defaultEndpoint
            return endpoint.isEmpty ? nil : endpoint
        default:
            let endpoint = provider.kind.defaultEndpoint
            return endpoint.isEmpty ? nil : endpoint
        }
    }

    private func assignment(
        stage: CapturePipelineStage,
        selection: StageSelection,
        prompt: CapturePromptSnapshot? = nil,
        attempt: Int,
        selectedAt: Date
    ) throws -> CaptureStageAssignment {
        try CaptureStageAssignment(
            stage: stage,
            providerKind: selection.providerKind,
            providerIdentifier: selection.providerIdentifier,
            modelIdentifier: selection.modelIdentifier,
            prompt: prompt,
            selectedAt: selectedAt,
            attempt: attempt
        )
    }
}
