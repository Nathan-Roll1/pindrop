//
//  SettingsStoreCaptureAssignmentResolverTests.swift
//  PindropTests
//
//

import Foundation
import PindropAI
import PindropCore
import PindropData
import PindropSpeech

import SwiftData
import Testing
@testable import Pindrop

@MainActor
@Suite(.serialized)
struct SettingsStoreCaptureAssignmentResolverTests {
    @MainActor
    private struct ResolverFixture {
        let settings: SettingsStore
        let modelManager: ModelManager
        let promptPresetStore: PromptPresetStore
        let modelsRoot: URL
        let cleanup: () -> Void

        func makeResolver() -> CaptureStageAssignmentResolver {
            CaptureStageAssignmentResolver(
                settings: settings,
                modelManager: modelManager,
                promptPresetStore: promptPresetStore
            )
        }
    }

    private func makeFixture() throws -> ResolverFixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("pindrop-capture-assignment-\(UUID().uuidString)", isDirectory: true)
        let applicationSupportRoot = root.appendingPathComponent("Pindrop", isDirectory: true)
        let modelsRoot = root.appendingPathComponent("FluidAudio/Models", isDirectory: true)
        try FileManager.default.createDirectory(at: applicationSupportRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: modelsRoot, withIntermediateDirectories: true)

        let settings = SettingsStore()
        settings.resetAllSettings()
        let modelManager = ModelManager(storageLocations: ModelStorageLocations(
            pindropApplicationSupportRoot: applicationSupportRoot,
            fluidAudioModelsRoot: modelsRoot
        ))
        let container = try PindropModelContainerFactory.makeInMemoryContainer()
        let promptPresetStore = PromptPresetStore(modelContext: ModelContext(container))

        return ResolverFixture(
            settings: settings,
            modelManager: modelManager,
            promptPresetStore: promptPresetStore,
            modelsRoot: modelsRoot,
            cleanup: {
                settings.resetAllSettings()
                try? FileManager.default.removeItem(at: root)
            }
        )
    }
    private func preview(
        _ stage: CapturePipelineStage,
        fixture: ResolverFixture,
        activeBatchModelName: String? = nil
    ) throws -> CaptureStageAssignmentPreview {
        try #require(
            CaptureStageAssignmentResolver.previewAssignments(
                settings: fixture.settings,
                modelManager: fixture.modelManager,
                activeBatchModelName: activeBatchModelName
            )
            .first(where: { $0.stage == stage })
        )
    }

    private func makeDiarizationReady(_ fixture: ResolverFixture) throws {
        let coreMLRoot = fixture.modelsRoot.appendingPathComponent(
            FeatureModelType.diarization.repoFolderName,
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: coreMLRoot, withIntermediateDirectories: true)
        for modelName in [
            "Segmentation.mlmodelc",
            "FBank.mlmodelc",
            "Embedding.mlmodelc",
            "PldaRho.mlmodelc",
            "plda-parameters.json",
        ] {
            FileManager.default.createFile(
                atPath: coreMLRoot.appendingPathComponent(modelName).path,
                contents: Data()
            )
        }
    }

    @Test func liveStageUsesOnlyTheConfiguredBackendAndDownloadedProfile() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let resolver = fixture.makeResolver()
        let selectedAt = Date(timeIntervalSinceReferenceDate: 123)

        let disabled = try resolver.select(
            stage: .liveTranscription,
            attempt: 1,
            activeBatchModelName: nil,
            selectedAt: selectedAt
        )
        #expect(disabled.providerKind == .disabled)
        #expect(disabled.providerIdentifier == "streaming-disabled")
        #expect(disabled.modelIdentifier == nil)

        fixture.settings.streamingFeatureEnabled = true
        fixture.settings.selectedTranscriptionBackend = .parakeet
        let unavailable = try resolver.select(
            stage: .liveTranscription,
            attempt: 2,
            activeBatchModelName: nil,
            selectedAt: selectedAt
        )
        #expect(unavailable.providerKind == .bestEffortUnavailable)
        #expect(unavailable.providerIdentifier == TranscriptionBackend.parakeet.rawValue)
        #expect(unavailable.modelIdentifier == StreamingChunkProfile.standard.repoFolderName)

        try FileManager.default.createDirectory(
            at: fixture.modelsRoot.appendingPathComponent(StreamingChunkProfile.standard.repoFolderName),
            withIntermediateDirectories: true
        )
        let selected = try resolver.select(
            stage: .liveTranscription,
            attempt: 3,
            activeBatchModelName: nil,
            selectedAt: selectedAt
        )
        #expect(selected.providerKind == .streamingSpeech)
        #expect(selected.providerIdentifier == TranscriptionBackend.parakeet.rawValue)
        #expect(selected.modelIdentifier == StreamingChunkProfile.standard.repoFolderName)
        #expect(selected.selectedAt == selectedAt)
    }

    @Test func finalStageRejectsUnknownUnavailableUndownloadedAndUncredentialedModels() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let resolver = fixture.makeResolver()

        #expect(throws: CaptureStageAssignmentResolverError.unknownBatchModel("not-a-catalog-model")) {
            try resolver.select(
                stage: .finalTranscription,
                attempt: 1,
                activeBatchModelName: "not-a-catalog-model"
            )
        }
        #expect(throws: CaptureStageAssignmentResolverError.batchModelComingSoon("parakeet-tdt-1.1b")) {
            try resolver.select(
                stage: .finalTranscription,
                attempt: 1,
                activeBatchModelName: "parakeet-tdt-1.1b"
            )
        }
        #expect(throws: CaptureStageAssignmentResolverError.batchModelNotDownloaded("openai_whisper-tiny")) {
            try resolver.select(
                stage: .finalTranscription,
                attempt: 1,
                activeBatchModelName: "openai_whisper-tiny"
            )
        }
        #expect(throws: CaptureStageAssignmentResolverError.missingBatchModelCredential(provider: "OpenAI")) {
            try resolver.select(
                stage: .finalTranscription,
                attempt: 1,
                activeBatchModelName: "openai_gpt-4o-mini-transcribe"
            )
        }

        let system = try resolver.select(
            stage: .finalTranscription,
            attempt: 1,
            activeBatchModelName: "apple_speech_on_device"
        )
        #expect(system.providerKind == .batchSpeech)
        #expect(system.providerIdentifier == ModelManager.ModelProvider.appleSpeech.rawValue)
        #expect(system.modelIdentifier == "apple_speech_on_device")

        try fixture.settings.saveTranscriptionAPIKey("transcription-secret", for: .openAI)
        let cloud = try resolver.select(
            stage: .finalTranscription,
            attempt: 1,
            activeBatchModelName: "openai_gpt-4o-mini-transcribe"
        )
        #expect(cloud.providerKind == .batchSpeech)
        #expect(cloud.providerIdentifier == ModelManager.ModelProvider.openAI.rawValue)
        #expect(cloud.modelIdentifier == "openai_gpt-4o-mini-transcribe")
        #expect(cloud.providerIdentifier != "transcription-secret")
    }

    @Test func diarizationAndNoteStagesCaptureConfiguredSelections() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let resolver = fixture.makeResolver()

        let disabledDiarization = try resolver.select(
            stage: .diarization,
            attempt: 1,
            activeBatchModelName: nil
        )
        #expect(disabledDiarization.providerKind == .disabled)
        #expect(disabledDiarization.providerIdentifier == "user-disabled")

        fixture.settings.diarizationFeatureEnabled = true
        let unavailableDiarization = try resolver.select(
            stage: .diarization,
            attempt: 1,
            activeBatchModelName: nil
        )
        #expect(unavailableDiarization.providerKind == .bestEffortUnavailable)
        #expect(unavailableDiarization.providerIdentifier == FeatureModelType.diarization.rawValue)
        #expect(unavailableDiarization.modelIdentifier == FeatureModelType.diarization.repoFolderName)

        let disabledNote = try resolver.select(
            stage: .noteGeneration,
            attempt: 1,
            activeBatchModelName: nil
        )
        #expect(disabledNote.providerKind == .disabled)
        #expect(disabledNote.providerIdentifier == "note-enhancement-unassigned")

        let provider = ProviderConfig(kind: .openai, displayName: "Private OpenAI")
        fixture.settings.upsertProvider(provider)
        fixture.settings.setAssignment(
            ModelAssignment(
                providerID: provider.id,
                modelID: "gpt-4o-mini",
                promptPresetID: BuiltInPresetID.noteFormatting
            ),
            for: .noteEnhancement
        )

        let noteBeforeCredential = try resolver.select(
            stage: .noteGeneration,
            attempt: 1,
            activeBatchModelName: nil
        )
        #expect(noteBeforeCredential.providerKind == .generativeAI)
        #expect(noteBeforeCredential.providerIdentifier == provider.id.uuidString)
        #expect(noteBeforeCredential.modelIdentifier == "gpt-4o-mini")

        try fixture.settings.saveProviderAPIKey("ai-secret", forProviderID: provider.id)
        try fixture.settings.saveProviderEndpoint("https://private.example/v1", forProviderID: provider.id)

        let note = try resolver.select(
            stage: .noteGeneration,
            attempt: 1,
            activeBatchModelName: nil
        )
        #expect(note.providerKind == .generativeAI)
        #expect(note.providerIdentifier == provider.id.uuidString)
        #expect(note.modelIdentifier == "gpt-4o-mini")
        #expect(note.prompt?.presetIdentifier == BuiltInPresetID.noteFormatting)
        #expect(note.prompt?.resolvedPrompt == SettingsStore.Defaults.noteEnhancementPrompt)
        #expect(note.providerIdentifier != "ai-secret")
        #expect(note.providerIdentifier != "https://private.example/v1")
        #expect(note.prompt?.resolvedPrompt?.contains("ai-secret") == false)
    }

    @Test func noteGenerationPersistsValidUncredentialedSelectionAndLateBindsCredentialAtRuntime() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let resolver = fixture.makeResolver()
        let provider = ProviderConfig(kind: .openai, displayName: "Personal OpenAI")
        let prompt = "Capture this note with the configured instructions."
        fixture.settings.upsertProvider(provider)
        fixture.settings.setAssignment(
            ModelAssignment(
                providerID: provider.id,
                modelID: "gpt-4.1-mini",
                promptOverride: prompt
            ),
            for: .noteEnhancement
        )

        #expect(try preview(.noteGeneration, fixture: fixture).state == .unavailable)
        let persistedAssignment = try resolver.select(
            stage: .noteGeneration,
            attempt: 1,
            activeBatchModelName: nil
        )
        #expect(persistedAssignment.providerKind == .generativeAI)
        #expect(persistedAssignment.providerIdentifier == provider.id.uuidString)
        #expect(persistedAssignment.modelIdentifier == "gpt-4.1-mini")
        #expect(persistedAssignment.prompt?.resolvedPrompt == prompt)

        fixture.settings.setAssignment(
            ModelAssignment(
                providerID: provider.id,
                modelID: "gpt-4.1",
                promptOverride: "Changed after capture"
            ),
            for: .noteEnhancement
        )

        try fixture.settings.saveProviderAPIKey("note-secret", forProviderID: provider.id)

        let runtime = try resolver.resolveNoteGenerationRuntime(for: persistedAssignment)
        #expect(runtime.providerID == provider.id)
        #expect(runtime.modelID == "gpt-4.1-mini")
        #expect(runtime.prompt == prompt)
    }

    @Test func previewsMatchSelectionsForDefaultUnavailableAndReadyStages() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let resolver = fixture.makeResolver()

        #expect(try preview(.liveTranscription, fixture: fixture).state == .disabled)
        #expect(try preview(.diarization, fixture: fixture).state == .disabled)
        #expect(try preview(.noteGeneration, fixture: fixture).state == .disabled)
        #expect(try preview(.finalTranscription, fixture: fixture).state == .unavailable)
        #expect(throws: CaptureStageAssignmentResolverError.batchModelNotDownloaded(
            SettingsStore.Defaults.selectedModel
        )) {
            try resolver.select(
                stage: .finalTranscription,
                attempt: 1,
                activeBatchModelName: nil
            )
        }

        fixture.settings.streamingFeatureEnabled = true
        fixture.settings.selectedTranscriptionBackend = .parakeet
        #expect(try preview(.liveTranscription, fixture: fixture).state == .unavailable)
        try FileManager.default.createDirectory(
            at: fixture.modelsRoot.appendingPathComponent(StreamingChunkProfile.standard.repoFolderName),
            withIntermediateDirectories: true
        )
        let live = try resolver.select(
            stage: .liveTranscription,
            attempt: 1,
            activeBatchModelName: nil
        )
        let livePreview = try preview(.liveTranscription, fixture: fixture)
        #expect(livePreview.state == .ready)
        #expect(livePreview.value == "Nemotron (default) · 1120ms")
        #expect(live.modelIdentifier == StreamingChunkProfile.standard.repoFolderName)
        #expect(try preview(
            .finalTranscription,
            fixture: fixture,
            activeBatchModelName: "not-a-catalog-model"
        ).state == .unavailable)
        #expect(throws: CaptureStageAssignmentResolverError.unknownBatchModel("not-a-catalog-model")) {
            try resolver.select(
                stage: .finalTranscription,
                attempt: 1,
                activeBatchModelName: "not-a-catalog-model"
            )
        }
        fixture.settings.streamingLowLatencyMode = true
        #expect(try preview(.liveTranscription, fixture: fixture).state == .unavailable)
        try FileManager.default.createDirectory(
            at: fixture.modelsRoot.appendingPathComponent(StreamingChunkProfile.lowLatency.repoFolderName),
            withIntermediateDirectories: true
        )
        let lowLatencyLive = try resolver.select(
            stage: .liveTranscription,
            attempt: 1,
            activeBatchModelName: nil
        )
        let lowLatencyPreview = try preview(.liveTranscription, fixture: fixture)
        #expect(lowLatencyPreview.state == .ready)
        #expect(lowLatencyPreview.value == "Nemotron (default) · 560ms")
        #expect(lowLatencyLive.modelIdentifier == StreamingChunkProfile.lowLatency.repoFolderName)
        #expect(try preview(
            .finalTranscription,
            fixture: fixture,
            activeBatchModelName: "parakeet-tdt-1.1b"
        ).state == .unavailable)
        #expect(throws: CaptureStageAssignmentResolverError.batchModelComingSoon("parakeet-tdt-1.1b")) {
            try resolver.select(
                stage: .finalTranscription,
                attempt: 1,
                activeBatchModelName: "parakeet-tdt-1.1b"
            )
        }
        #expect(try preview(
            .finalTranscription,
            fixture: fixture,
            activeBatchModelName: "openai_gpt-4o-mini-transcribe"
        ).state == .unavailable)
        #expect(throws: CaptureStageAssignmentResolverError.missingBatchModelCredential(provider: "OpenAI")) {
            try resolver.select(
                stage: .finalTranscription,
                attempt: 1,
                activeBatchModelName: "openai_gpt-4o-mini-transcribe"
            )
        }
        let final = try resolver.select(
            stage: .finalTranscription,
            attempt: 1,
            activeBatchModelName: "apple_speech_on_device"
        )
        let finalPreview = try preview(
            .finalTranscription,
            fixture: fixture,
            activeBatchModelName: "apple_speech_on_device"
        )
        #expect(finalPreview.state == .ready)
        #expect(finalPreview.value == "Apple Speech")
        #expect(final.modelIdentifier == "apple_speech_on_device")

        fixture.settings.diarizationFeatureEnabled = true
        #expect(try preview(.diarization, fixture: fixture).state == .unavailable)
        try makeDiarizationReady(fixture)
        let diarization = try resolver.select(
            stage: .diarization,
            attempt: 1,
            activeBatchModelName: nil
        )
        #expect(try preview(.diarization, fixture: fixture).state == .ready)
        #expect(diarization.providerKind == .localDiarization)

        let missingProvider = ModelAssignment(
            providerID: UUID(),
            modelID: "missing-model"
        )
        fixture.settings.setAssignment(missingProvider, for: .noteEnhancement)
        let missingProviderPreview = try preview(.noteGeneration, fixture: fixture)
        #expect(missingProviderPreview.state == .unavailable)
        #expect(missingProviderPreview.value == "missing-model")
        let missingProviderNote = try resolver.select(
            stage: .noteGeneration,
            attempt: 1,
            activeBatchModelName: nil
        )
        #expect(missingProviderNote.providerKind == .generativeAI)
        #expect(missingProviderNote.providerIdentifier == missingProvider.providerID.uuidString)
        #expect(missingProviderNote.modelIdentifier == "missing-model")
        #expect(missingProviderNote.prompt?.presetIdentifier == BuiltInPresetID.noteFormatting)
        #expect(missingProviderNote.prompt?.resolvedPrompt == SettingsStore.Defaults.noteEnhancementPrompt)

        let provider = ProviderConfig(kind: .openai, displayName: "Personal OpenAI")
        fixture.settings.upsertProvider(provider)
        fixture.settings.setAssignment(
            ModelAssignment(providerID: provider.id, modelID: "gpt-4.1-mini"),
            for: .noteEnhancement
        )
        let credentialUnavailablePreview = try preview(.noteGeneration, fixture: fixture)
        #expect(credentialUnavailablePreview.state == .unavailable)
        #expect(credentialUnavailablePreview.value == "Personal OpenAI · gpt-4.1-mini")
        try fixture.settings.saveProviderAPIKey("note-secret", forProviderID: provider.id)
        let note = try resolver.select(
            stage: .noteGeneration,
            attempt: 1,
            activeBatchModelName: nil
        )
        let notePreview = try preview(.noteGeneration, fixture: fixture)
        #expect(notePreview.state == .ready)
        #expect(notePreview.value == "Personal OpenAI · gpt-4.1-mini")
        #expect(note.providerKind == .generativeAI)
        #expect(note.prompt?.presetIdentifier == BuiltInPresetID.noteFormatting)
        #expect(note.prompt?.resolvedPrompt == SettingsStore.Defaults.noteEnhancementPrompt)
        #expect(notePreview.value?.contains("note-secret") == false)
        fixture.settings.setAssignment(
            ModelAssignment(providerID: provider.id, modelID: "   "),
            for: .noteEnhancement
        )
        #expect(try preview(.noteGeneration, fixture: fixture).state == .unavailable)
        let modelUnavailableNote = try resolver.select(
            stage: .noteGeneration,
            attempt: 1,
            activeBatchModelName: nil
        )
        #expect(modelUnavailableNote.providerKind == .bestEffortUnavailable)
        fixture.settings.setAssignment(
            ModelAssignment(providerID: provider.id, modelID: "gpt-4.1-mini"),
            for: .noteEnhancement
        )
    }

    @Test func persistedNoteRuntimeLateBindsCurrentSameUUIDProviderConfigAndCredentialWhileKeepingCaptureSelectionFrozen() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let resolver = fixture.makeResolver()
        let capturedProvider = ProviderConfig(kind: .openai, displayName: "Captured OpenAI")
        let currentPurposeProvider = ProviderConfig(kind: .anthropic, displayName: "Current Anthropic")
        fixture.settings.upsertProvider(capturedProvider)
        fixture.settings.upsertProvider(currentPurposeProvider)
        try fixture.settings.saveProviderAPIKey("captured-secret", forProviderID: capturedProvider.id)
        try fixture.settings.saveProviderEndpoint(
            "https://captured.example/v1",
            forProviderID: capturedProvider.id
        )
        try fixture.settings.saveProviderAPIKey("current-secret", forProviderID: currentPurposeProvider.id)
        fixture.settings.setAssignment(
            ModelAssignment(
                providerID: capturedProvider.id,
                modelID: "captured-model",
                promptOverride: "Captured prompt"
            ),
            for: .noteEnhancement
        )
        let persistedAssignment = try resolver.select(
            stage: .noteGeneration,
            attempt: 1,
            activeBatchModelName: nil
        )
        let persistedJSON = String(
            decoding: try JSONEncoder().encode(persistedAssignment),
            as: UTF8.self
        )
        #expect(!persistedJSON.contains("apiKey"))
        #expect(!persistedJSON.contains("endpoint"))
        #expect(!persistedJSON.contains("captured-secret"))
        #expect(!persistedJSON.contains("https://captured.example/v1"))

        let currentSameUUIDProvider = ProviderConfig(
            id: capturedProvider.id,
            kind: .custom,
            customKind: .custom,
            displayName: "Current Custom"
        )
        fixture.settings.upsertProvider(currentSameUUIDProvider)
        try fixture.settings.saveProviderAPIKey("current-same-uuid-secret", forProviderID: capturedProvider.id)
        try fixture.settings.saveProviderEndpoint(
            "https://current-same-uuid.example/v1",
            forProviderID: capturedProvider.id
        )
        fixture.settings.setAssignment(
            ModelAssignment(
                providerID: currentPurposeProvider.id,
                modelID: "current-model",
                promptOverride: "Current prompt"
            ),
            for: .noteEnhancement
        )

        let runtime = try resolver.resolveNoteGenerationRuntime(for: persistedAssignment)
        #expect(runtime.providerID == capturedProvider.id)
        #expect(runtime.providerID != currentPurposeProvider.id)
        #expect(runtime.kind == .custom)
        #expect(runtime.customKind == .custom)
        #expect(runtime.displayName == "Current Custom")
        #expect(runtime.modelID == "captured-model")
        #expect(runtime.modelID != "current-model")
        #expect(runtime.prompt == "Captured prompt")
        #expect(runtime.prompt != "Current prompt")
        #expect(runtime.endpoint == "https://current-same-uuid.example/v1")
        #expect(runtime.apiKey == "current-same-uuid-secret")

        try fixture.settings.deleteProviderAPIKey(forProviderID: capturedProvider.id)
        #expect(throws: CaptureStageAssignmentResolverError.missingPersistedNoteProviderCredential(
            provider: "Current Custom"
        )) {
            try resolver.resolveNoteGenerationRuntime(for: persistedAssignment)
        }
        fixture.settings.removeProvider(withID: capturedProvider.id)
        #expect(throws: CaptureStageAssignmentResolverError.persistedNoteProviderUnavailable(
            capturedProvider.id.uuidString
        )) {
            try resolver.resolveNoteGenerationRuntime(for: persistedAssignment)
        }
    }

    @Test func persistedNoteRuntimeUsesResolvedLegacyPromptText() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let resolver = fixture.makeResolver()
        let provider = ProviderConfig(kind: .openai, displayName: "Captured OpenAI")
        let legacyPresetID = UUID()
        fixture.settings.upsertProvider(provider)
        try fixture.settings.saveProviderAPIKey("captured-secret", forProviderID: provider.id)

        let persistedAssignment = try CaptureStageAssignment(
            stage: .noteGeneration,
            providerKind: .generativeAI,
            providerIdentifier: provider.id.uuidString,
            modelIdentifier: "captured-model",
            prompt: CapturePromptSnapshot(
                presetIdentifier: legacyPresetID.uuidString,
                resolvedPrompt: "Legacy V13 prompt"
            ),
            selectedAt: .now,
            attempt: 1
        )

        let runtime = try resolver.resolveNoteGenerationRuntime(for: persistedAssignment)

        #expect(runtime.promptPresetID == legacyPresetID.uuidString)
        #expect(runtime.prompt == "Legacy V13 prompt")
    }

    @Test func persistedNoteRuntimeRejectsLegacyPromptIdentifierWithoutText() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let resolver = fixture.makeResolver()
        let provider = ProviderConfig(kind: .openai, displayName: "Captured OpenAI")
        let legacyPresetID = UUID()
        fixture.settings.upsertProvider(provider)
        try fixture.settings.saveProviderAPIKey("captured-secret", forProviderID: provider.id)

        let persistedAssignment = try CaptureStageAssignment(
            stage: .noteGeneration,
            providerKind: .generativeAI,
            providerIdentifier: provider.id.uuidString,
            modelIdentifier: "captured-model",
            prompt: CapturePromptSnapshot(
                presetIdentifier: legacyPresetID.uuidString,
                resolvedPrompt: nil
            ),
            selectedAt: .now,
            attempt: 1
        )

        #expect(throws: CaptureStageAssignmentResolverError.persistedNotePromptUnavailable(
            legacyPresetID.uuidString
        )) {
            try resolver.resolveNoteGenerationRuntime(for: persistedAssignment)
        }
    }

    @Test func resetRestoresCaptureStageDefaults() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let resolver = fixture.makeResolver()

        fixture.settings.streamingFeatureEnabled = true
        fixture.settings.streamingLowLatencyMode = true
        fixture.settings.diarizationFeatureEnabled = true
        fixture.settings.selectedTranscriptionBackend = .appleSpeechTranscriber
        fixture.settings.selectedModel = "not-a-catalog-model"
        fixture.settings.resetAllSettings()

        let live = try resolver.select(stage: .liveTranscription, attempt: 1, activeBatchModelName: nil)
        let diarization = try resolver.select(stage: .diarization, attempt: 1, activeBatchModelName: nil)
        let note = try resolver.select(stage: .noteGeneration, attempt: 1, activeBatchModelName: nil)
        #expect(fixture.settings.selectedModel == SettingsStore.Defaults.selectedModel)
        #expect(fixture.settings.selectedTranscriptionBackend == .parakeet)
        #expect(fixture.settings.streamingFeatureEnabled == false)
        #expect(fixture.settings.streamingLowLatencyMode == false)
        #expect(fixture.settings.diarizationFeatureEnabled == false)
        #expect(live.providerKind == .disabled)
        #expect(diarization.providerKind == .disabled)
        #expect(note.providerKind == .disabled)
    }
}
