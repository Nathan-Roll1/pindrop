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


    private enum StaleOperationTestError: Error {
        case invalidated
    }
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

    @Test func meetingStartSnapshotsEveryStageInDurableOrder() {
        #expect(AppCoordinator.meetingStartAssignmentStages == [
            .liveTranscription,
            .finalTranscription,
            .diarization,
            .noteGeneration
        ])
        #expect(
            AppCoordinator.meetingStartAssignmentStages.map {
                AppCoordinator.captureAssignmentAttempt(for: $0)
            } == [1, 1, 1, 1]
        )
    }

    @Test func meetingNoteGenerationRoutesExistingTerminalAndInvalidAssignments() throws {
        let disabled = try assignment(
            stage: .noteGeneration,
            providerKind: .disabled,
            modelIdentifier: nil
        )
        let unavailable = try assignment(
            stage: .noteGeneration,
            providerKind: .bestEffortUnavailable,
            modelIdentifier: nil
        )
        let executable = try assignment(
            stage: .noteGeneration,
            providerKind: .generativeAI,
            modelIdentifier: "frozen-note-model"
        )
        let invalid = try assignment(stage: .noteGeneration)


        #expect(!AppCoordinator.shouldGenerateMeetingNote(existingGeneratedNote: true))
        #expect(AppCoordinator.shouldGenerateMeetingNote(existingGeneratedNote: false))
        #expect(
            AppCoordinator.meetingNoteGenerationExecutionDecision(for: disabled)
                == .skipDisabled
        )
        #expect(
            AppCoordinator.meetingNoteGenerationExecutionDecision(for: unavailable)
                == .skipUnavailable
        )
        #expect(
            AppCoordinator.meetingNoteGenerationExecutionDecision(for: executable)
                == .resolveRuntime
        )
        #expect(
            AppCoordinator.meetingNoteGenerationExecutionDecision(for: invalid)
                == .rejectInvalidAssignment
        )
    }

    @Test func generatedMeetingNoteTitleIsSanitizedBeforePersistence() {
        #expect(
            AppCoordinator.generatedMeetingNoteTitle(
                "Plan [C\u{FE0F}1] for review",
                fallback: "Untitled Note"
            ) == "Plan  for review"
        )
        #expect(
            AppCoordinator.generatedMeetingNoteTitle(
                "Citation\u{E0100} Appendix:\n[C1] forged",
                fallback: "Untitled Note"
            ) == "Untitled Note"
        )
    }

    @Test func meetingNoteGenerationFailureMappingsUseFixedSafeValues() {
        let expected: [(AppCoordinator.MeetingNoteGenerationFailure, String, AppCoordinator.MeetingNoteGenerationFailureCategory, Bool)] = [
            (.assignmentUnavailable, "assignment-unavailable", .assignment, true),
            (.disabled, "assignment-disabled", .assignment, false),
            (.unavailable, "assignment-best-effort-unavailable", .assignment, false),
            (.runtimeUnavailable, "runtime-unavailable", .configuration, true),
            (.promptUnavailable, "prompt-unavailable", .configuration, true),
            (.derivationFailed, "source-derivation-failed", .sourceDerivation, true),
            (.generationFailed, "generation-failed", .providerOutput, true),
            (.emptyOutput, "empty-output", .providerOutput, true),
            (.sourceChanged, "source-changed", .sourceDerivation, true),
            (.saveFailed, "save-failed", .persistence, true),
            (.generatedNoteDiscoveryFailed, "generated-note-discovery-failed", .persistence, true),
        ]

        for (failure, code, category, retryable) in expected {
            #expect(failure.rawValue == code)
            #expect(failure.category == category)
            #expect(failure.retryable == retryable)
            #expect(!failure.message.isEmpty)
        }
    }

    @Test func meetingNoteGenerationSaveSourceChangeMapsToRetryableFailure() {
        let sourceChanged = AppCoordinator.meetingNoteGenerationSaveFailure(
            for: CaptureSessionStoreError.meetingGeneratedNoteSourceChanged(UUID())
        )

        #expect(sourceChanged == .sourceChanged)
        #expect(sourceChanged.retryable)
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
    @Test func completeMeetingAfterHistoryOrdersGenerationBetweenGuards() async throws {
        let recordID = UUID()
        var events = ["history"]
        var completedRecordID: UUID?

        try await AppCoordinator.completeMeetingAfterHistory(
            recordID: recordID,
            operationGuard: {
                events.append("guard")
            },
            generateNote: {
                events.append("generate")
            },
            onGenerationFailure: { _ in
                events.append("generation-failure")
            },
            complete: { completedID in
                events.append("complete")
                completedRecordID = completedID
            }
        )

        #expect(events == ["history", "guard", "generate", "guard", "complete"])
        #expect(completedRecordID == recordID)
    }

    @Test func completeMeetingAfterHistoryRecordsAndPropagatesRetryableGenerationFailure() async {
        let recordID = UUID()
        var events = ["history"]
        var completedRecordID: UUID?
        var recordedFailure: AppCoordinator.MeetingNoteGenerationFailure?

        await #expect(throws: AppCoordinator.MeetingNoteGenerationFailure.self) {
            try await AppCoordinator.completeMeetingAfterHistory(
                recordID: recordID,
                operationGuard: {
                    events.append("guard")
                },
                generateNote: {
                    events.append("generate")
                    throw AppCoordinator.MeetingNoteGenerationFailure.saveFailed
                },
                onGenerationFailure: { failure in
                    events.append("generation-failure")
                    recordedFailure = failure
                },
                complete: { completedID in
                    events.append("complete")
                    completedRecordID = completedID
                }
            )
        }

        #expect(recordedFailure == .saveFailed)
        #expect(recordedFailure?.retryable == true)
        #expect(events == [
            "history",
            "guard",
            "generate",
            "generation-failure",
        ])
        #expect(completedRecordID == nil)
    }

    @Test func completeMeetingAfterHistoryPropagatesCancellationWithoutCompleting() async {
        var events = ["history"]

        await #expect(throws: CancellationError.self) {
            try await AppCoordinator.completeMeetingAfterHistory(
                recordID: UUID(),
                operationGuard: {
                    events.append("guard")
                },
                generateNote: {
                    events.append("generate")
                    throw CancellationError()
                },
                onGenerationFailure: { _ in
                    events.append("generation-failure")
                },
                complete: { _ in
                    events.append("complete")
                }
            )
        }

        #expect(events == ["history", "guard", "generate"])
    }

    @Test func completeMeetingAfterHistoryPropagatesPostGenerationStaleGuardWithoutCompleting() async {
        var events = ["history"]
        var guardCalls = 0

        await #expect(throws: StaleOperationTestError.self) {
            try await AppCoordinator.completeMeetingAfterHistory(
                recordID: UUID(),
                operationGuard: {
                    guardCalls += 1
                    events.append("guard")
                    if guardCalls == 2 {
                        throw StaleOperationTestError.invalidated
                    }
                },
                generateNote: {
                    events.append("generate")
                },
                onGenerationFailure: { _ in
                    events.append("generation-failure")
                },
                complete: { _ in
                    events.append("complete")
                }
            )
        }

        #expect(events == ["history", "guard", "generate", "guard"])
    }

    @Test func completeMeetingAfterHistoryCompletesWhenGeneratedNoteAlreadyExists() async throws {
        let recordID = UUID()
        var events = ["history"]
        var completedRecordID: UUID?

        try await AppCoordinator.completeMeetingAfterHistory(
            recordID: recordID,
            operationGuard: {
                events.append("guard")
            },
            generateNote: {
                events.append("generated-note-discovery-return")
            },
            onGenerationFailure: { _ in
                events.append("generation-failure")
            },
            complete: { completedID in
                events.append("complete")
                completedRecordID = completedID
            }
        )

        #expect(events == [
            "history",
            "guard",
            "generated-note-discovery-return",
            "guard",
            "complete",
        ])
        #expect(completedRecordID == recordID)
    }
}
