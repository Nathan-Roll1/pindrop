//
//  AppCoordinatorCaptureAssignmentTests.swift
//  PindropTests
//
//  Created on 2026-08-21.
//

import Foundation
import SwiftData
import Testing

@testable import Pindrop
import PindropCore
import PindropData

@MainActor
@Suite(.serialized)
struct AppCoordinatorCaptureAssignmentTests {
    private func makeStore() throws -> (CaptureSessionStore, VoiceNoteCaptureHandle) {
        let container = try PindropModelContainerFactory.makeInMemoryContainer()
        let store = CaptureSessionStore(modelContext: ModelContext(container))
        let handle = try store.startVoiceNoteCapture(
            startedAt: .now,
            microphoneDisplayName: "Test Microphone"
        )
        return (store, handle)
    }

    private func assignment(
        stage: CapturePipelineStage,
        providerKind: CaptureAssignmentProviderKind = .batchSpeech,
        providerIdentifier: String = "test-provider",
        modelIdentifier: String? = "batch-model",
        prompt: CapturePromptSnapshot? = nil,
        attempt: Int = 1
    ) throws -> CaptureStageAssignment {
        try CaptureStageAssignment(
            stage: stage,
            providerKind: providerKind,
            providerIdentifier: providerIdentifier,
            modelIdentifier: modelIdentifier,
            prompt: prompt,
            selectedAt: .now,
            attempt: attempt
        )
    }

    @Test func assignmentIsDurablyInsertedBeforeTheStageCall() throws {
        let (store, handle) = try makeStore()
        var events: [String] = []

        _ = try store.resolveAssignment(
            sessionID: handle.sessionID,
            stage: .finalTranscription,
            attempt: AppCoordinator.captureAssignmentAttempt(for: .finalTranscription)
        ) {
            events.append("selected")
            return try assignment(stage: .finalTranscription, modelIdentifier: "active-batch")
        }
        let persisted = try store.persistedAssignment(
            sessionID: handle.sessionID,
            stage: .finalTranscription,
            attempt: 1
        )
        #expect(persisted?.modelIdentifier == "active-batch")
        events.append("assignment-persisted")
        events.append("stage-called")

        #expect(events == ["selected", "assignment-persisted", "stage-called"])
    }

    @Test func liveAssignmentIsSelectedBeforeVoiceContextExposure() throws {
        let (store, handle) = try makeStore()
        var events: [String] = []

        let selected = try store.resolveAssignment(
            sessionID: handle.sessionID,
            stage: .liveTranscription,
            attempt: AppCoordinator.captureAssignmentAttempt(for: .liveTranscription)
        ) {
            events.append("assignment-selected")
            return try assignment(
                stage: .liveTranscription,
                providerKind: .streamingSpeech,
                providerIdentifier: "streaming-provider",
                modelIdentifier: "streaming-model"
            )
        }
        let persisted = try store.persistedAssignment(
            sessionID: handle.sessionID,
            stage: .liveTranscription,
            attempt: selected.attempt
        )
        events.append("assignment-persisted")
        events.append("context-exposed")

        #expect(persisted == selected)
        #expect(events == [
            "assignment-selected",
            "assignment-persisted",
            "context-exposed"
        ])
    }

    @Test func persistedAssignmentIsReusedWhenSettingsWouldNowChooseAnotherModel() throws {
        let (store, handle) = try makeStore()
        var settingsModel = "model-selected-at-start"
        var selectorCalls = 0

        let first = try store.resolveAssignment(
            sessionID: handle.sessionID,
            stage: .finalTranscription,
            attempt: 1
        ) {
            selectorCalls += 1
            return try assignment(stage: .finalTranscription, modelIdentifier: settingsModel)
        }
        settingsModel = "model-selected-after-settings-change"
        let recovered = try store.resolveAssignment(
            sessionID: handle.sessionID,
            stage: .finalTranscription,
            attempt: 1
        ) {
            selectorCalls += 1
            return try assignment(stage: .finalTranscription, modelIdentifier: settingsModel)
        }

        #expect(selectorCalls == 1)
        #expect(recovered == first)
        #expect(recovered.modelIdentifier == "model-selected-at-start")
    }

    @Test func recoveryAndChunksUseAttemptOneAndNeverCallBeforeSnapshot() throws {
        let assignment = try assignment(
            stage: .finalTranscription,
            modelIdentifier: "recovery-model"
        )

        #expect(AppCoordinator.captureAssignmentAttempt(for: .finalTranscription) == 1)
        #expect(assignment.attempt == 1)
        #expect(
            AppCoordinator.captureAssignmentExecutionOrder(for: assignment)
                == [.assignmentSnapshot, .stageCall]
        )
    }

    @Test func historyProvenanceUsesTheAssignedActiveFinalModel() throws {
        let assignment = try assignment(
            stage: .finalTranscription,
            modelIdentifier: "actually-loaded-model"
        )

        #expect(
            AppCoordinator.finalHistoryModelIdentifier(from: assignment)
                == "actually-loaded-model"
        )
        #expect(
            AppCoordinator.assignedFinalModelNeedsActivation(
                assignment,
                activeModelName: "different-current-model"
            )
        )
        #expect(
            !AppCoordinator.assignedFinalModelNeedsActivation(
                assignment,
                activeModelName: "actually-loaded-model"
            )
        )
    }

    @Test func disabledOrUnavailableDiarizationNeverInvokesTheStage() throws {
        let disabled = try assignment(
            stage: .diarization,
            providerKind: .disabled,
            modelIdentifier: nil
        )
        let unavailable = try assignment(
            stage: .diarization,
            providerKind: .bestEffortUnavailable,
            modelIdentifier: "pyannote-speaker-diarization-3.1"
        )

        #expect(AppCoordinator.captureAssignmentExecutionDecision(for: disabled) == .skip)
        #expect(AppCoordinator.captureAssignmentExecutionDecision(for: unavailable) == .skip)
        #expect(
            AppCoordinator.captureAssignmentExecutionOrder(for: disabled)
                == [.assignmentSnapshot]
        )
        #expect(
            AppCoordinator.captureAssignmentExecutionOrder(for: unavailable)
                == [.assignmentSnapshot]
        )
    }

    @Test func liveArtifactAdmissionOnlyStartsExecutableStreamingAssignments() throws {
        let executable = try assignment(
            stage: .liveTranscription,
            providerKind: .streamingSpeech,
            providerIdentifier: "streaming-provider",
            modelIdentifier: "streaming-model"
        )
        let disabled = try assignment(
            stage: .liveTranscription,
            providerKind: .disabled,
            modelIdentifier: nil
        )
        let unavailable = try assignment(
            stage: .liveTranscription,
            providerKind: .bestEffortUnavailable,
            modelIdentifier: nil
        )
        let batch = try assignment(
            stage: .liveTranscription,
            providerKind: .batchSpeech
        )

        #expect(
            AppCoordinator.liveArtifactCaptureAdmission(for: executable) == .capture
        )
        #expect(
            AppCoordinator.liveArtifactCaptureAdmission(for: disabled) == .deactivate
        )
        #expect(
            AppCoordinator.liveArtifactCaptureAdmission(for: unavailable) == .deactivate
        )
        #expect(
            AppCoordinator.liveArtifactCaptureAdmission(for: batch) == .deactivate
        )
    }

    @Test func noteGenerationRuntimeUsesFrozenProviderModelAndPromptAfterSettingsDrift() throws {
        let persistedProviderID = UUID()
        let currentSettingsProviderID = UUID()
        let persisted = try assignment(
            stage: .noteGeneration,
            providerKind: .generativeAI,
            providerIdentifier: persistedProviderID.uuidString,
            modelIdentifier: "frozen-note-model",
            prompt: CapturePromptSnapshot(
                presetIdentifier: "frozen-preset",
                resolvedPrompt: "Frozen note prompt"
            )
        )

        let runtimeInput = try #require(
            AppCoordinator.noteGenerationRuntimeAssignment(from: persisted)
        )

        #expect(runtimeInput.providerIdentifier == persistedProviderID.uuidString)
        #expect(runtimeInput.providerIdentifier != currentSettingsProviderID.uuidString)
        #expect(runtimeInput.modelIdentifier == "frozen-note-model")
        #expect(runtimeInput.prompt?.resolvedPrompt == "Frozen note prompt")
    }

    @Test func unavailablePersistedNoteRuntimeRecordsFailureBeforeRawFallback() throws {
        let persisted = try assignment(
            stage: .noteGeneration,
            providerKind: .generativeAI,
            modelIdentifier: "frozen-note-model"
        )

        #expect(
            AppCoordinator.noteGenerationExecutionOrder(
                for: persisted,
                runtimeAvailable: false,
                resolvedPrompt: nil
            ) == [.assignmentSnapshot, .runtimeResolution, .stageFailureRecorded, .rawFallback]
        )
    }

    @Test func unavailablePersistedPromptCannotReachEnhancementButDefaultSnapshotCan() throws {
        let unavailablePrompt = CapturePromptSnapshot(
            presetIdentifier: UUID().uuidString,
            resolvedPrompt: nil
        )
        let defaultPrompt = CapturePromptSnapshot(
            presetIdentifier: nil,
            resolvedPrompt: SettingsStore.Defaults.noteEnhancementPrompt
        )
        let unavailable = try assignment(
            stage: .noteGeneration,
            providerKind: .generativeAI,
            modelIdentifier: "frozen-note-model",
            prompt: unavailablePrompt
        )
        let defaultSelected = try assignment(
            stage: .noteGeneration,
            providerKind: .generativeAI,
            modelIdentifier: "new-note-model",
            prompt: defaultPrompt
        )

        #expect(
            !AppCoordinator.canExecutePersistedNoteGeneration(
                resolvedPrompt: unavailable.prompt?.resolvedPrompt
            )
        )
        #expect(
            AppCoordinator.noteGenerationExecutionOrder(
                for: unavailable,
                runtimeAvailable: true,
                resolvedPrompt: unavailable.prompt?.resolvedPrompt
            ) == [.assignmentSnapshot, .runtimeResolution, .stageFailureRecorded, .rawFallback]
        )
        #expect(
            AppCoordinator.canExecutePersistedNoteGeneration(
                resolvedPrompt: defaultSelected.prompt?.resolvedPrompt
            )
        )
        #expect(
            AppCoordinator.noteGenerationExecutionOrder(
                for: defaultSelected,
                runtimeAvailable: true,
                resolvedPrompt: defaultSelected.prompt?.resolvedPrompt
            ) == [.assignmentSnapshot, .runtimeResolution, .stageCall]
        )
    }
}
