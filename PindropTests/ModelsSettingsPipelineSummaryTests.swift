//
//  ModelsSettingsPipelineSummaryTests.swift
//  PindropTests
//
//  Created on 2026-08-21.
//

import Foundation
import Testing
@testable import Pindrop
import PindropAI
import PindropCore
import PindropSpeech

@MainActor
@Suite(.serialized)
struct ModelsSettingsPipelineSummaryTests {
    @MainActor
    private struct Fixture {
        let settings: SettingsStore
        let modelManager: ModelManager
        let root: URL

        func cleanup() {
            settings.resetAllSettings()
            try? FileManager.default.removeItem(at: root)
        }
    }

    private func makeFixture() throws -> Fixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("pindrop-assignment-preview-\(UUID().uuidString)", isDirectory: true)
        let applicationSupportRoot = root.appendingPathComponent("Pindrop", isDirectory: true)
        let modelsRoot = root.appendingPathComponent("FluidAudio/Models", isDirectory: true)
        try FileManager.default.createDirectory(at: applicationSupportRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: modelsRoot, withIntermediateDirectories: true)

        let settings = SettingsStore()
        settings.resetAllSettings()
        let modelManager = ModelManager(
            storageLocations: ModelStorageLocations(
                pindropApplicationSupportRoot: applicationSupportRoot,
                fluidAudioModelsRoot: modelsRoot
            )
        )

        return Fixture(settings: settings, modelManager: modelManager, root: root)
    }

    private func previews(for fixture: Fixture) -> [CaptureStageAssignmentPreview] {
        CaptureStageAssignmentResolver.previewAssignments(
            settings: fixture.settings,
            modelManager: fixture.modelManager,
            activeBatchModelName: nil
        )
    }

    private func preview(
        for stage: CapturePipelineStage,
        in previews: [CaptureStageAssignmentPreview]
    ) throws -> CaptureStageAssignmentPreview {
        try #require(previews.first(where: { $0.stage == stage }))
    }

    @Test func resolverPreviewMatchesDefaultNextSessionConfiguration() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }

        let assignmentPreviews = previews(for: fixture)

        #expect(assignmentPreviews.map(\.stage) == [
            .liveTranscription,
            .finalTranscription,
            .diarization,
            .noteGeneration,
        ])
        #expect(try preview(for: .liveTranscription, in: assignmentPreviews).state == .disabled)
        #expect(try preview(for: .finalTranscription, in: assignmentPreviews).state == .unavailable)
        #expect(try preview(for: .diarization, in: assignmentPreviews).state == .disabled)
        #expect(try preview(for: .noteGeneration, in: assignmentPreviews).state == .disabled)
    }

    @Test func finalPreviewMarksAnInvalidConfiguredModelUnavailable() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        fixture.settings.selectedModel = "not-a-catalog-model"

        let finalPreview = try preview(for: .finalTranscription, in: previews(for: fixture))

        #expect(finalPreview.state == .unavailable)
        #expect(finalPreview.value == "not-a-catalog-model")
    }

    @Test func livePreviewMarksAMissingStreamingVariantUnavailable() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        fixture.settings.streamingFeatureEnabled = true
        fixture.settings.selectedTranscriptionBackend = .parakeet

        let livePreview = try preview(for: .liveTranscription, in: previews(for: fixture))

        #expect(livePreview.state == .unavailable)
    }

    @Test func notePreviewMarksAMissingProviderCredentialUnavailable() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let provider = ProviderConfig(kind: .openai, displayName: "Private OpenAI")
        fixture.settings.upsertProvider(provider)
        fixture.settings.setAssignment(
            ModelAssignment(providerID: provider.id, modelID: "gpt-4o-mini"),
            for: .noteEnhancement
        )

        let notePreview = try preview(for: .noteGeneration, in: previews(for: fixture))

        #expect(notePreview.state == .unavailable)
        #expect(notePreview.value == "Private OpenAI · gpt-4o-mini")
    }

    @Test func notePreviewRemainsReadyWithoutExposingPromptOrCredential() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let provider = ProviderConfig(kind: .openai, displayName: "Private OpenAI")
        let prompt = "Internal note prompt"
        let credential = "note-secret"
        fixture.settings.upsertProvider(provider)
        try fixture.settings.saveProviderAPIKey(credential, forProviderID: provider.id)
        fixture.settings.setAssignment(
            ModelAssignment(
                providerID: provider.id,
                modelID: "gpt-4o-mini",
                promptOverride: prompt
            ),
            for: .noteEnhancement
        )

        let notePreview = try preview(for: .noteGeneration, in: previews(for: fixture))

        #expect(notePreview.state == .ready)
        #expect(notePreview.value == "Private OpenAI · gpt-4o-mini")
        #expect(notePreview.value?.contains(prompt) == false)
        #expect(notePreview.value?.contains(credential) == false)
    }

    @Test func diarizationPreviewMarksAnUndownloadedModelUnavailable() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        fixture.settings.diarizationFeatureEnabled = true

        let diarizationPreview = try preview(for: .diarization, in: previews(for: fixture))

        #expect(diarizationPreview.state == .unavailable)
    }

    @Test func finalPreviewUsesTheRealSettingsDefaultModel() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }

        let finalPreview = try preview(for: .finalTranscription, in: previews(for: fixture))
        let selectedModel = try #require(
            fixture.modelManager.availableModels.first { $0.name == SettingsStore.Defaults.selectedModel }
        )

        #expect(fixture.settings.selectedModel == SettingsStore.Defaults.selectedModel)
        #expect(finalPreview.value == selectedModel.displayName)
    }
}
