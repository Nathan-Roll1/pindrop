//
//  NoteCaptureControllerTests.swift
//  PindropTests
//
//  Created on 2026-08-22.
//

import AVFoundation
import Foundation
import PindropAI
import PindropCore
import PindropData
import PindropMedia
import PindropSpeech
import SwiftData
import Testing

@testable import Pindrop

@MainActor
@Suite(.serialized)
struct NoteCaptureControllerTests {

    // MARK: - Stub arbiter

    /// Records what the controller asked the shell to do, and lets a test make
    /// the capture busy or invalidate a claim mid-start.
    private final class StubCaptureArbiter: CaptureArbiter {
        var isCaptureBusy = false
        var isCaptureHostStopping = false
        var activeBatchModelName: String?
        /// Number of `isClaimCurrent` calls after which the claim goes stale.
        var invalidateClaimAfterChecks: Int?
        var claimError: Error?

        private(set) var claimCount = 0
        private(set) var releaseCount = 0
        private(set) var claimCurrentChecks = 0
        private(set) var didBeginAt: Date?
        private(set) var didEnterProcessing = false
        private(set) var endMessages: [String?] = []
        private(set) var createdNoteIDs: [UUID] = []
        private(set) var producedRecordIDs: [UUID] = []
        private(set) var observedErrors: [Error] = []
        private(set) var noSpeechReports = 0
        private(set) var progressDetails: [String] = []
        private(set) var activatedModels: [String] = []
        private var nextClaimID: UInt64 = 0

        func claimCapture() throws -> CaptureClaim {
            if let claimError { throw claimError }
            guard !isCaptureBusy else { throw CaptureArbiterError.captureBusy }
            claimCount += 1
            nextClaimID &+= 1
            return CaptureClaim(id: nextClaimID)
        }

        func release(_ claim: CaptureClaim) { releaseCount += 1 }

        func isClaimCurrent(_ claim: CaptureClaim) -> Bool {
            claimCurrentChecks += 1
            if let limit = invalidateClaimAfterChecks, claimCurrentChecks > limit {
                return false
            }
            return !isCaptureHostStopping
        }

        func captureDidBegin(startedAt: Date) { didBeginAt = startedAt }
        func captureDidEnterProcessing() { didEnterProcessing = true }
        func captureDidEnd(message: String?) { endMessages.append(message) }
        func captureDidFinishWithoutSpeech() { noSpeechReports += 1 }

        func activateBatchModel(named name: String, providerIdentifier: String) async throws {
            activatedModels.append(name)
        }

        func captureTranscriptionOptions() -> TranscriptionOptions {
            TranscriptionOptions(language: .english)
        }

        func captureDidReportProgress(
            stage: NoteCaptureState.FinalizationStage,
            detail: String,
            errorMessage: String?
        ) {
            progressDetails.append(detail)
        }

        func captureDidCreateNote(id: UUID) { createdNoteIDs.append(id) }
        func captureDidProduceRecord(id: UUID) { producedRecordIDs.append(id) }
        func captureDidObserveError(_ error: Error) { observedErrors.append(error) }
    }

    // MARK: - Fixture


    // MARK: - Auto naming

    private func configureNoteMetadataAssignment(in settings: SettingsStore) throws {
        let provider = ProviderConfig(kind: .openai, displayName: "Test OpenAI")
        settings.upsertProvider(provider)
        try settings.saveProviderAPIKey("metadata-secret", forProviderID: provider.id)
        try settings.saveProviderEndpoint(
            "https://api.example.invalid/v1/chat/completions",
            forProviderID: provider.id
        )
        settings.setAssignment(
            ModelAssignment(providerID: provider.id, modelID: "gpt-4o-mini"),
            for: .noteMetadata
        )
    }

    private func makeUntitledAnchoredHandle(
        in fixture: Fixture
    ) throws -> (PindropCore.NoteCaptureHandle, UUID) {
        let handle = try fixture.captureSessionStore.startNoteCapture(
            includeSystemAudio: false,
            intent: CaptureIntentRequest(destination: .newNote, origin: .mainWindow)
        )
        let anchor = try fixture.captureSessionStore.ensureMeetingHumanAnchor(
            handle,
            title: "Untitled Note"
        )
        return (handle, anchor.noteID)
    }

    @Test func autoNamingUsesTheAIMetadataTitleWhenTheAssignmentResolves() async throws {
        let fixture = try makeFixture()
        let (handle, noteID) = try makeUntitledAnchoredHandle(in: fixture)
        try configureNoteMetadataAssignment(in: fixture.settingsStore)
        fixture.enhancementSession.responseContent =
            #"{"title": "Roof repair plan", "tags": []}"#

        await fixture.controller.autoNameNoteIfUntitled(
            handle,
            finalText: "the roof needs replacing before winter"
        )

        let note = try fixture.notesStore.fetch(id: noteID)
        #expect(note.title == "Roof repair plan")
        #expect(fixture.enhancementSession.requestCount == 1)
    }

    @Test func autoNamingFallsBackToTheDerivedTitleWithoutAnAssignment() async throws {
        let fixture = try makeFixture()
        let (handle, noteID) = try makeUntitledAnchoredHandle(in: fixture)
        let text = "the roof needs replacing before winter"

        await fixture.controller.autoNameNoteIfUntitled(handle, finalText: text)

        let expected = AIEnhancementService(session: StubEnhancementProviderSession())
            .generateFallbackTitle(from: text)
        let note = try fixture.notesStore.fetch(id: noteID)
        #expect(note.title == expected)
        #expect(note.title != "Untitled Note")
        #expect(fixture.enhancementSession.requestCount == 0)
    }

    @Test func autoNamingFallsBackToTheDerivedTitleWhenTheProviderFails() async throws {
        let fixture = try makeFixture()
        let (handle, noteID) = try makeUntitledAnchoredHandle(in: fixture)
        try configureNoteMetadataAssignment(in: fixture.settingsStore)
        fixture.enhancementSession.error = URLError(.timedOut)
        let text = "the roof needs replacing before winter"

        await fixture.controller.autoNameNoteIfUntitled(handle, finalText: text)

        let expected = AIEnhancementService(session: StubEnhancementProviderSession())
            .generateFallbackTitle(from: text)
        let note = try fixture.notesStore.fetch(id: noteID)
        #expect(note.title == expected)
    }

    @Test func autoNamingNeverTouchesATitleThePersonTyped() async throws {
        let fixture = try makeFixture()
        let (handle, noteID) = try makeUntitledAnchoredHandle(in: fixture)
        let note = try fixture.notesStore.fetch(id: noteID)
        note.title = "Winter prep"
        try fixture.notesStore.update(note)
        try configureNoteMetadataAssignment(in: fixture.settingsStore)

        await fixture.controller.autoNameNoteIfUntitled(
            handle,
            finalText: "the roof needs replacing before winter"
        )

        let after = try fixture.notesStore.fetch(id: noteID)
        #expect(after.title == "Winter prep")
        #expect(fixture.enhancementSession.requestCount == 0)
    }

    @Test func autoNamingIgnoresAnEmptyTranscript() async throws {
        let fixture = try makeFixture()
        let (handle, noteID) = try makeUntitledAnchoredHandle(in: fixture)
        try configureNoteMetadataAssignment(in: fixture.settingsStore)

        await fixture.controller.autoNameNoteIfUntitled(handle, finalText: "   ")

        let note = try fixture.notesStore.fetch(id: noteID)
        #expect(note.title == "Untitled Note")
        #expect(fixture.enhancementSession.requestCount == 0)
    }

    private struct Fixture {
        let controller: NoteCaptureController
        let arbiter: StubCaptureArbiter
        let settingsStore: SettingsStore
        let enhancementSession: StubEnhancementProviderSession
        let state: NoteCaptureState
        let captureSessionStore: CaptureSessionStore
        let notesStore: NotesStore
        let historyStore: HistoryStore
        let audioRecorder: AudioRecorder
        let microphoneBackend: MockAudioCaptureBackend
        let systemAudioBackend: MockAudioCaptureBackend
        let container: ModelContainer
        let libraryRoot: URL
    }

    private func makeFixture() throws -> Fixture {
        let container = try PindropModelContainerFactory.makeInMemoryContainer()
        let captureSessionStore = CaptureSessionStore(modelContext: ModelContext(container))
        let notesStore = NotesStore(
            modelContext: ModelContext(container),
            metadataGenerator: { _, _ in nil }
        )
        let historyStore = HistoryStore(modelContext: ModelContext(container))
        let microphoneBackend = MockAudioCaptureBackend(identifier: "microphone")
        let systemAudioBackend = MockAudioCaptureBackend(identifier: "system")
        let audioRecorder = try AudioRecorder(
            permissionManager: MockPermissionProvider(),
            captureBackend: microphoneBackend,
            systemAudioCaptureBackend: systemAudioBackend
        )
        let libraryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("pindrop-note-capture-\(UUID().uuidString)", isDirectory: true)
        let mediaIngestionService = MediaIngestionService(
            mediaLibrary: ManagedMediaLibrary(baseURL: libraryRoot)
        )
        let settingsStore = SettingsStore()
        settingsStore.resetAllSettings()
        // Apple Speech needs no download, so start-time assignment resolution
        // succeeds on a machine with no models fetched.
        settingsStore.selectedModel = "apple_speech_on_device"
        let modelStorage = ModelStorageLocations(
            pindropApplicationSupportRoot: libraryRoot.appendingPathComponent("Pindrop", isDirectory: true),
            fluidAudioModelsRoot: libraryRoot.appendingPathComponent("FluidAudio", isDirectory: true)
        )
        let modelManager = ModelManager(storageLocations: modelStorage)
        let transcriptionService = TranscriptionService(storageLocations: modelStorage)
        let toastService = ToastService(presenter: SilentToastPresenter())
        let dictionaryStore = DictionaryStore(modelContext: ModelContext(container))
        let streamingSession = StreamingSessionController(
            transcriptionService: transcriptionService,
            settingsStore: settingsStore,
            dictionaryStore: dictionaryStore,
            outputManager: OutputManager(
                outputMode: .clipboard,
                clipboard: SilentClipboard(),
                accessibilityPermissionChecker: { false }
            ),
            toastService: toastService,
            liveTranscriptState: LiveTranscriptState(),
            audioRecorder: audioRecorder,
            captureSessionStore: captureSessionStore,
            normalizeText: { NoteCaptureController.normalizedText($0) },
            isEffectivelyEmptyText: { NoteCaptureController.isEffectivelyEmpty($0) }
        )
        let arbiter = StubCaptureArbiter()
        let state = NoteCaptureState()
        let assignmentResolver = CaptureStageAssignmentResolver(
            settings: settingsStore,
            modelManager: modelManager,
            promptPresetStore: PromptPresetStore(modelContext: ModelContext(container))
        )
        let enhancementSession = StubEnhancementProviderSession()
        let aiEnhancementService = AIEnhancementService(session: enhancementSession)
        let noteEnhancementService = NoteEnhancementService(
            captureSessionStore: captureSessionStore,
            notesStore: notesStore,
            promptPresetStore: PromptPresetStore(modelContext: ModelContext(container)),
            assignmentResolver: assignmentResolver,
            aiEnhancementService: aiEnhancementService,
            settingsStore: settingsStore
        )
        let controller = NoteCaptureController(
            audioRecorder: audioRecorder,
            streamingSession: streamingSession,
            captureSessionStore: captureSessionStore,
            notesStore: notesStore,
            historyStore: historyStore,
            mediaIngestionService: mediaIngestionService,
            assignmentResolver: assignmentResolver,
            aiEnhancementService: aiEnhancementService,
            noteEnhancementService: noteEnhancementService,
            transcriptionService: transcriptionService,
            settingsStore: settingsStore,
            toastService: toastService,
            arbiter: arbiter,
            state: state
        )
        return Fixture(
            controller: controller,
            arbiter: arbiter,
            settingsStore: settingsStore,
            enhancementSession: enhancementSession,
            state: state,
            captureSessionStore: captureSessionStore,
            notesStore: notesStore,
            historyStore: historyStore,
            audioRecorder: audioRecorder,
            microphoneBackend: microphoneBackend,
            systemAudioBackend: systemAudioBackend,
            container: container,
            libraryRoot: libraryRoot
        )
    }

    private final class SilentToastPresenter: ToastPresenting, @unchecked Sendable {
        func show(
            payload: ToastPayload,
            onAction: @escaping (UUID) -> Void,
            onHoverChange: @escaping (Bool) -> Void
        ) {}
        func hide() {}
    }

    private final class SilentClipboard: ClipboardProtocol, @unchecked Sendable {
        func copyToClipboard(_ text: String) -> Bool { true }
        func captureSnapshot() -> ClipboardSnapshot { .empty }
        func currentChangeCount() -> Int { 0 }
        func currentStringContent() -> String? { nil }
        func restoreSnapshot(_ snapshot: ClipboardSnapshot) -> Bool { true }
    }

    private func sessions(in container: ModelContainer) throws -> [CaptureSessionModel] {
        try ModelContext(container).fetch(FetchDescriptor<CaptureSessionModel>())
    }

    private func sources(in container: ModelContainer) throws -> [CaptureSourceModel] {
        try ModelContext(container).fetch(FetchDescriptor<CaptureSourceModel>())
    }

    // MARK: - Admission

    @Test func startIsRejectedWhileAnotherCaptureOwnsTheArbiter() async throws {
        let fixture = try makeFixture()
        fixture.arbiter.isCaptureBusy = true

        await #expect(throws: CaptureArbiterError.captureBusy) {
            try await fixture.controller.startNote(
                request: NoteCaptureRequest(includeSystemAudio: false),
                origin: .mainWindow
            )
        }

        #expect(try sessions(in: fixture.container).isEmpty)
        #expect(!fixture.controller.isActive)
        // A rejected start must not blank the note page: the arbiter owns the
        // "already busy" message, and this state stays untouched.
        #expect(fixture.state.phase == .idle)
    }

    @Test func startIsRejectedWhileThisControllerAlreadyHasACapture() async throws {
        let fixture = try makeFixture()
        _ = try await fixture.controller.startNote(
            request: NoteCaptureRequest(includeSystemAudio: false),
            origin: .mainWindow
        )

        await #expect(throws: NoteCaptureController.NoteCaptureError.captureAlreadyActive) {
            try await fixture.controller.startNote(
                request: NoteCaptureRequest(includeSystemAudio: false),
                origin: .mainWindow
            )
        }
        #expect(try sessions(in: fixture.container).count == 1)
        #expect(fixture.arbiter.claimCount == 1)
    }

    // MARK: - Start

    @Test func micOnlyStartCreatesOneMicrophoneSourceAndBindsItsIntentToTheNote() async throws {
        let fixture = try makeFixture()

        let noteID = try await fixture.controller.startNote(
            request: NoteCaptureRequest(includeSystemAudio: false),
            origin: .menuBar
        )

        let handle = try #require(fixture.controller.activeHandle)
        #expect(handle.systemAudioSourceID == nil)
        let sourceRows = try sources(in: fixture.container)
        #expect(sourceRows.count == 1)
        #expect(sourceRows[0].kindRawValue == CaptureSourceKind.microphone.rawValue)
        #expect(fixture.systemAudioBackend.configuredMeetingSources.isEmpty)

        let intent = try #require(
            try fixture.captureSessionStore.fetchCaptureIntent(sessionID: handle.sessionID)
        )
        // Binding a `newNote` intent rewrites it to name the note it created.
        #expect(intent.destination == .existingNote)
        #expect(intent.destinationNoteID == noteID)
        #expect(intent.origin == .menuBar)
        #expect(intent.requestedSourceKinds == [.microphone])
        #expect(fixture.arbiter.createdNoteIDs == [noteID])
    }

    @Test func systemAudioStartCreatesBothSourceRows() async throws {
        let fixture = try makeFixture()

        _ = try await fixture.controller.startNote(
            request: NoteCaptureRequest(includeSystemAudio: true),
            origin: .mainWindow
        )

        let handle = try #require(fixture.controller.activeHandle)
        #expect(handle.systemAudioSourceID != nil)
        #expect(try sources(in: fixture.container).count == 2)
        #expect(fixture.state.includesSystemAudio)
    }

    @Test func startBindsACaptureToTheNoteTheRequestNames() async throws {
        let fixture = try makeFixture()
        let existing = try await fixture.notesStore.create(title: "Standup", content: "agenda")

        let noteID = try await fixture.controller.startNote(
            request: NoteCaptureRequest(noteID: existing.id, includeSystemAudio: false),
            origin: .mainWindow
        )

        #expect(noteID == existing.id)
        let handle = try #require(fixture.controller.activeHandle)
        let anchor = try #require(try fixture.captureSessionStore.meetingHumanAnchor(handle))
        #expect(anchor.noteID == existing.id)
        #expect(anchor.content == "agenda")
    }

    @Test func stateReachesCapturingOnlyAfterTheRecorderStarted() async throws {
        let fixture = try makeFixture()
        #expect(fixture.state.phase == .idle)

        _ = try await fixture.controller.startNote(
            request: NoteCaptureRequest(includeSystemAudio: false),
            origin: .mainWindow
        )

        #expect(fixture.state.phase == .capturing)
        #expect(fixture.state.startedAt != nil)
        #expect(fixture.state.noteID != nil)
        #expect(!fixture.state.canPause)
        #expect(fixture.arbiter.didBeginAt != nil)
        #expect(fixture.microphoneBackend.configuredMeetingSources == [.microphone])
    }

    // MARK: - Cancel during start

    @Test func aStartCancelledMidFlightTerminallyCancelsItsDurableSession() async throws {
        let fixture = try makeFixture()
        // The claim goes stale right after the first ownership check, which is
        // before the recorder is asked to start.
        fixture.arbiter.invalidateClaimAfterChecks = 1

        await #expect(throws: CancellationError.self) {
            try await fixture.controller.startNote(
                request: NoteCaptureRequest(includeSystemAudio: false),
                origin: .mainWindow
            )
        }

        let sessionRows = try sessions(in: fixture.container)
        #expect(sessionRows.count == 1)
        #expect(sessionRows[0].stateRawValue == CaptureSessionState.cancelled.rawValue)
        #expect(!fixture.controller.isActive)
        #expect(fixture.microphoneBackend.startCaptureCallCount == 0)
        // A cancelled session must not come back as recoverable work.
        #expect(try fixture.captureSessionStore.noteCaptureRecoveryCandidates().isEmpty)
    }

    @Test func explicitCancelRemovesTheCaptureWithoutLeavingRecoverableWork() async throws {
        let fixture = try makeFixture()
        _ = try await fixture.controller.startNote(
            request: NoteCaptureRequest(includeSystemAudio: false),
            origin: .mainWindow
        )

        await fixture.controller.cancel()

        let sessionRows = try sessions(in: fixture.container)
        #expect(sessionRows[0].stateRawValue == CaptureSessionState.cancelled.rawValue)
        #expect(!fixture.controller.isActive)
        #expect(fixture.state.phase == .idle)
        #expect(try fixture.captureSessionStore.noteCaptureRecoveryCandidates().isEmpty)
    }

    // MARK: - Termination

    @Test func terminationMidCaptureLeavesARecoverableSessionCarryingItsIntent() async throws {
        let fixture = try makeFixture()
        let noteID = try await fixture.controller.startNote(
            request: NoteCaptureRequest(includeSystemAudio: false),
            origin: .mainWindow
        )

        await fixture.controller.checkpointForTermination()

        #expect(!fixture.controller.isActive)
        let candidates = try fixture.captureSessionStore.noteCaptureRecoveryCandidates()
        #expect(candidates.count == 1)
        let candidate = try #require(candidates.first)
        #expect(candidate.mode == .note)
        #expect(candidate.handle.systemAudioSourceID == nil)
        #expect(candidate.intent?.destinationNoteID == noteID)
        #expect(candidate.recoveryTarget != nil)
    }

    @Test func synchronousShutdownStillLeavesTheCaptureRecoverable() async throws {
        let fixture = try makeFixture()
        _ = try await fixture.controller.startNote(
            request: NoteCaptureRequest(includeSystemAudio: false),
            origin: .mainWindow
        )

        fixture.controller.checkpointForSynchronousShutdown()

        #expect(!fixture.controller.isActive)
        #expect(try fixture.captureSessionStore.noteCaptureRecoveryCandidates().count == 1)
    }

    // MARK: - Stop and finalization

    @Test func stopWithoutACaptureReportsNotRecording() async {
        guard let fixture = try? makeFixture() else {
            Issue.record("fixture unavailable")
            return
        }
        await #expect(throws: AudioRecorderError.notRecording) {
            try await fixture.controller.stop()
        }
    }

    @Test func stopSupersededMidFinalizeCompletesNothingAndKeepsItsCapture() async throws {
        let fixture = try makeFixture()
        _ = try await fixture.controller.startNote(
            request: NoteCaptureRequest(includeSystemAudio: false),
            origin: .mainWindow
        )

        // A guard that always throws is a superseded operation: whoever
        // superseded it owns the capture, so this stop must not finish or
        // cancel it behind their back.
        await #expect(throws: CancellationError.self) {
            try await fixture.controller.stop(operationGuard: { throw CancellationError() })
        }

        let session = try #require(try sessions(in: fixture.container).first)
        #expect(session.stateRawValue != CaptureSessionState.completed.rawValue)
        #expect(session.transcriptionRecordID == nil)
        #expect(fixture.controller.isActive)
        #expect(fixture.arbiter.producedRecordIDs.isEmpty)
    }

    @Test func stopCancelledByItsOwnTaskTerminallyCancelsTheCapture() async throws {
        let fixture = try makeFixture()
        _ = try await fixture.controller.startNote(
            request: NoteCaptureRequest(includeSystemAudio: false),
            origin: .mainWindow
        )
        // The host is stopping, so the controller's own currency check throws
        // while the operation itself is still the current one.
        fixture.arbiter.isCaptureHostStopping = true

        await #expect(throws: CancellationError.self) {
            try await fixture.controller.stop()
        }
        #expect(fixture.state.phase == .idle)
        #expect(fixture.arbiter.endMessages.count == 1)
    }

    @Test func micOnlyFinalizationWithoutBatchASRKeepsTheLiveTextAndLinksARecord() async throws {
        let fixture = try makeFixture()
        let handle = try fixture.captureSessionStore.startNoteCapture(
            includeSystemAudio: false,
            intent: CaptureIntentRequest(destination: .newNote, origin: .mainWindow)
        )
        let anchor = try fixture.captureSessionStore.ensureMeetingHumanAnchor(
            handle,
            title: "Untitled Note"
        )
        try freezeAssignments(in: fixture.captureSessionStore, sessionID: handle.sessionID)
        try fixture.captureSessionStore.checkpointVoiceNoteLiveTranscript(
            for: handle,
            committedText: "the roof needs replacing before winter"
        )
        try fixture.captureSessionStore.beginMeetingFinalization(handle)
        try fixture.captureSessionStore.recordSealedMeetingChunk(
            handle,
            checkpoint: MeetingChunkCheckpoint(
                sourceID: handle.microphoneSourceID,
                sequence: 0,
                startOffset: 0,
                duration: MeetingCaptureSpoolPlan.chunkDuration,
                managedMediaPath: CaptureSourceArtifactPath.relativePath(
                    sessionID: handle.sessionID,
                    sourceID: handle.microphoneSourceID,
                    chunkSequence: 0
                ),
                byteCount: MeetingCaptureSpoolPlan.defaultChunkByteCount,
                sha256: String(format: "%064x", 1),
                sealedAt: .now
            )
        )
        try fixture.captureSessionStore.finishMeetingSources(handle, sourceFailures: [])

        try await fixture.controller.finalize(
            handle,
            spoolPlan: MeetingCaptureSpoolPlan(
                libraryRootURL: fixture.libraryRoot,
                sessionID: handle.sessionID,
                microphoneSourceID: handle.microphoneSourceID,
                systemAudioSourceID: nil
            ),
            expectedSpeakerCount: nil,
            operationGuard: {}
        )

        let sessionRows = try sessions(in: fixture.container)
        let session = try #require(sessionRows.first { $0.id == handle.sessionID })
        #expect(session.stateRawValue == CaptureSessionState.completed.rawValue)
        let recordID = try #require(session.transcriptionRecordID)
        let record = try #require(try fixture.historyStore.fetchRecord(with: recordID))
        #expect(record.text == "the roof needs replacing before winter")
        #expect(record.diarizationSegmentsJSON == nil)
        let sourceRows = try sources(in: fixture.container)
            .filter { $0.sessionID == handle.sessionID }
        #expect(sourceRows.count == 1)
        #expect(sourceRows.allSatisfy { $0.kindRawValue == CaptureSourceKind.microphone.rawValue })
        #expect(anchor.noteID != recordID)
    }

    // MARK: - Enhanced panel on finish

    /// Assigns a note-enhancement model so the finish path has something to
    /// generate with. The stubbed session answers the request.
    private func configureNoteEnhancement(_ fixture: Fixture) throws {
        let provider = ProviderConfig(kind: .openai, displayName: "Test OpenAI")
        fixture.settingsStore.upsertProvider(provider)
        try fixture.settingsStore.saveProviderAPIKey("note-secret", forProviderID: provider.id)
        try fixture.settingsStore.saveProviderEndpoint(
            "https://api.example.invalid/v1/chat/completions",
            forProviderID: provider.id
        )
        fixture.settingsStore.setAssignment(
            ModelAssignment(
                providerID: provider.id,
                modelID: "gpt-4o-mini",
                promptPresetID: BuiltInPresetID.noteFormatting
            ),
            for: .noteEnhancement
        )
    }

    @Test func finishingARecordedNoteGeneratesItsEnhancedPanel() async throws {
        let fixture = try makeFixture()
        defer { fixture.settingsStore.resetAllSettings() }
        try configureNoteEnhancement(fixture)
        fixture.enhancementSession.responseContent = "Decisions: ship on Friday."
        let handle = try fixture.captureSessionStore.startNoteCapture(
            includeSystemAudio: false,
            intent: CaptureIntentRequest(destination: .newNote, origin: .mainWindow)
        )
        let anchor = try fixture.captureSessionStore.ensureMeetingHumanAnchor(
            handle,
            title: "Untitled Note"
        )
        try freezeAssignments(in: fixture.captureSessionStore, sessionID: handle.sessionID)
        try fixture.captureSessionStore.checkpointVoiceNoteLiveTranscript(
            for: handle,
            committedText: "the roof needs replacing before winter"
        )
        try fixture.captureSessionStore.beginMeetingFinalization(handle)
        try recordOneSealedChunk(in: fixture.captureSessionStore, handle: handle)
        try fixture.captureSessionStore.finishMeetingSources(handle, sourceFailures: [])

        try await fixture.controller.finalize(
            handle,
            spoolPlan: makeSpoolPlan(fixture, handle: handle),
            expectedSpeakerCount: nil,
            operationGuard: {}
        )

        let panels = try fixture.captureSessionStore.currentPanels(noteID: anchor.noteID)
        #expect(panels.count == 1)
        #expect(panels[0].content == "Decisions: ship on Friday.")
        #expect(fixture.enhancementSession.requestCount == 1)
        // Panels only: a finished capture no longer files a second note row.
        #expect(try fixture.notesStore.fetchAll().count == 1)
        let session = try #require(try sessions(in: fixture.container).first { $0.id == handle.sessionID })
        #expect(session.stateRawValue == CaptureSessionState.completed.rawValue)
    }

    @Test func aFailedPanelGenerationStillCompletesTheCapture() async throws {
        let fixture = try makeFixture()
        defer { fixture.settingsStore.resetAllSettings() }
        try configureNoteEnhancement(fixture)
        fixture.enhancementSession.error = URLError(.timedOut)
        let handle = try fixture.captureSessionStore.startNoteCapture(
            includeSystemAudio: false,
            intent: CaptureIntentRequest(destination: .newNote, origin: .mainWindow)
        )
        let anchor = try fixture.captureSessionStore.ensureMeetingHumanAnchor(
            handle,
            title: "Untitled Note"
        )
        try freezeAssignments(in: fixture.captureSessionStore, sessionID: handle.sessionID)
        try fixture.captureSessionStore.checkpointVoiceNoteLiveTranscript(
            for: handle,
            committedText: "the roof needs replacing before winter"
        )
        try fixture.captureSessionStore.beginMeetingFinalization(handle)
        try recordOneSealedChunk(in: fixture.captureSessionStore, handle: handle)
        try fixture.captureSessionStore.finishMeetingSources(handle, sourceFailures: [])

        try await fixture.controller.finalize(
            handle,
            spoolPlan: makeSpoolPlan(fixture, handle: handle),
            expectedSpeakerCount: nil,
            operationGuard: {}
        )

        // The recording is what matters: the session completed and its
        // transcript is linked even though no panel could be generated.
        let session = try #require(try sessions(in: fixture.container).first { $0.id == handle.sessionID })
        #expect(session.stateRawValue == CaptureSessionState.completed.rawValue)
        #expect(session.transcriptionRecordID != nil)
        #expect(try fixture.captureSessionStore.enhancedPanels(noteID: anchor.noteID).isEmpty)
        let failures = try ModelContext(fixture.container)
            .fetch(FetchDescriptor<CaptureFailureRecordModel>())
            .filter { $0.sessionID == handle.sessionID }
        #expect(failures.contains { $0.errorCode == "generation-failed" })
    }

    // MARK: - Quick capture delivery

    @Test func quickCaptureWritesItsTranscriptIntoTheNoteItCreated() async throws {
        let fixture = try makeFixture()
        let handle = try fixture.captureSessionStore.startNoteCapture(
            includeSystemAudio: false,
            intent: CaptureIntentRequest(destination: .newNote, origin: .hotkey)
        )
        let anchor = try fixture.captureSessionStore.ensureMeetingHumanAnchor(
            handle,
            title: "Untitled Note"
        )
        try freezeAssignments(in: fixture.captureSessionStore, sessionID: handle.sessionID)
        try fixture.captureSessionStore.checkpointVoiceNoteLiveTranscript(
            for: handle,
            committedText: "call the roofer back on Tuesday"
        )
        try fixture.captureSessionStore.beginMeetingFinalization(handle)
        try recordOneSealedChunk(in: fixture.captureSessionStore, handle: handle)
        try fixture.captureSessionStore.finishMeetingSources(handle, sourceFailures: [])

        try await fixture.controller.finalize(
            handle,
            spoolPlan: makeSpoolPlan(fixture, handle: handle),
            expectedSpeakerCount: nil,
            operationGuard: {}
        )
        // At runtime naming runs as a detached follow-up so it cannot delay
        // completion; run it to completion here to assert the end state.
        await fixture.controller.autoNameNoteIfUntitled(
            handle,
            finalText: "call the roofer back on Tuesday"
        )

        let note = try fixture.notesStore.fetch(id: anchor.noteID)
        #expect(note.content == "call the roofer back on Tuesday")
        // The default title is replaced so the note is findable in the list.
        #expect(note.title != "Untitled Note")
        #expect(!note.title.isEmpty)
    }

    @Test func quickCaptureDeliveryNeverOverwritesWhatSomebodyTyped() async throws {
        let fixture = try makeFixture()
        let typed = try await fixture.notesStore.create(
            title: "Roof",
            content: "quotes are due friday"
        )
        let handle = try fixture.captureSessionStore.startNoteCapture(
            includeSystemAudio: false,
            intent: CaptureIntentRequest(
                destination: .existingNote,
                destinationNoteID: typed.id,
                origin: .hotkey
            )
        )
        _ = try fixture.captureSessionStore.ensureMeetingHumanAnchor(handle, noteID: typed.id)
        try freezeAssignments(in: fixture.captureSessionStore, sessionID: handle.sessionID)
        try fixture.captureSessionStore.checkpointVoiceNoteLiveTranscript(
            for: handle,
            committedText: "call the roofer back on Tuesday"
        )
        try fixture.captureSessionStore.beginMeetingFinalization(handle)
        try recordOneSealedChunk(in: fixture.captureSessionStore, handle: handle)
        try fixture.captureSessionStore.finishMeetingSources(handle, sourceFailures: [])

        try await fixture.controller.finalize(
            handle,
            spoolPlan: makeSpoolPlan(fixture, handle: handle),
            expectedSpeakerCount: nil,
            operationGuard: {}
        )

        let note = try fixture.notesStore.fetch(id: typed.id)
        #expect(note.content == "quotes are due friday")
        #expect(note.title == "Roof")
    }

    @Test func aSilentQuickCaptureLeavesNoNoteAndNoErrorToDismiss() async throws {
        let fixture = try makeFixture()
        let noteID = try await fixture.controller.startNote(
            request: NoteCaptureRequest(includeSystemAudio: false),
            origin: .hotkey
        )
        #expect(try fixture.notesStore.contains(id: noteID))

        // Nothing was recorded, so finalization finds no transcript. That is not
        // a failure the person has to dismiss: it is one line, and the note the
        // capture made for itself goes away with it.
        try await fixture.controller.stop()

        #expect(!(try fixture.notesStore.contains(id: noteID)))
        #expect(fixture.arbiter.noSpeechReports == 1)
        #expect(fixture.arbiter.endMessages == [nil])
        #expect(fixture.state.phase == .idle)
        #expect(fixture.state.noteID == nil)
        #expect(!fixture.controller.isActive)
    }

    @Test func aSilentMainWindowCaptureKeepsItsNoteAndReportsTheFailure() async throws {
        let fixture = try makeFixture()
        let noteID = try await fixture.controller.startNote(
            request: NoteCaptureRequest(includeSystemAudio: false),
            origin: .mainWindow
        )

        await #expect(throws: NoteCaptureController.NoteCaptureError.noRetainedSources) {
            try await fixture.controller.stop()
        }

        // The note is on screen and may already hold typed notes, so it stays.
        #expect(try fixture.notesStore.contains(id: noteID))
        #expect(fixture.arbiter.noSpeechReports == 0)
        #expect(fixture.state.failureMessage != nil)
    }

    // MARK: - Startup recovery

    @Test func recoveryCurrencyIsGenerationAndHandleExact() {
        let activeHandle = NoteCaptureHandle(
            sessionID: UUID(),
            microphoneSourceID: UUID(),
            systemAudioSourceID: UUID()
        )
        let differentHandle = NoteCaptureHandle(
            sessionID: activeHandle.sessionID,
            microphoneSourceID: activeHandle.microphoneSourceID,
            systemAudioSourceID: UUID()
        )

        #expect(NoteCaptureController.isRecoveryCurrent(
            activeGeneration: 4,
            candidateGeneration: 4,
            activeHandle: activeHandle,
            candidateHandle: activeHandle
        ))
        #expect(!NoteCaptureController.isRecoveryCurrent(
            activeGeneration: 4,
            candidateGeneration: 3,
            activeHandle: activeHandle,
            candidateHandle: activeHandle
        ))
        #expect(!NoteCaptureController.isRecoveryCurrent(
            activeGeneration: 4,
            candidateGeneration: 4,
            activeHandle: activeHandle,
            candidateHandle: differentHandle
        ))
    }

    @Test func cancelledRecoveryAfterAwaitCannotMutateStore() {
        let handle = NoteCaptureHandle(
            sessionID: UUID(),
            microphoneSourceID: UUID(),
            systemAudioSourceID: UUID()
        )

        #expect(!NoteCaptureController.shouldApplyRecoveryMutation(
            isCancelled: true,
            isHostStopping: false,
            activeGeneration: 8,
            candidateGeneration: 8,
            activeHandle: handle,
            candidateHandle: handle
        ))
        #expect(!NoteCaptureController.shouldApplyRecoveryMutation(
            isCancelled: false,
            isHostStopping: true,
            activeGeneration: 8,
            candidateGeneration: 8,
            activeHandle: handle,
            candidateHandle: handle
        ))
        #expect(NoteCaptureController.shouldApplyRecoveryMutation(
            isCancelled: false,
            isHostStopping: false,
            activeGeneration: 8,
            candidateGeneration: 8,
            activeHandle: handle,
            candidateHandle: handle
        ))
    }

    @Test func recoveryContinuesPastCorruptCandidateButStopsForCancellation() {
        struct CorruptArtifact: Error {}

        #expect(NoteCaptureController.shouldContinueRecovery(after: CorruptArtifact()))
        #expect(!NoteCaptureController.shouldContinueRecovery(after: CancellationError()))
    }

    @Test func recoveryLeavesMicrophoneOnlyCapturesForTheirDeliveryStep() async throws {
        let fixture = try makeFixture()
        _ = try await fixture.controller.startNote(
            request: NoteCaptureRequest(includeSystemAudio: false),
            origin: .hotkey
        )
        await fixture.controller.checkpointForTermination()
        #expect(try fixture.captureSessionStore.noteCaptureRecoveryCandidates().count == 1)

        await fixture.controller.recoverInterruptedCaptures()

        // Delivering a recovered microphone-only note is P7's job. Until then the
        // session stays interrupted rather than being finalized with nowhere
        // agreed to put its transcript.
        let session = try #require(try sessions(in: fixture.container).first)
        #expect(session.stateRawValue == CaptureSessionState.interrupted.rawValue)
        #expect(try fixture.captureSessionStore.noteCaptureRecoveryCandidates().count == 1)
    }

    // MARK: - Observable state

    // MARK: - Live transcript

    @Test func aMeetingCaptureShowsBothChannelsInTheLiveTranscript() async throws {
        let fixture = try makeFixture()
        var pumpedSources: [CaptureSourceKind] = []
        fixture.audioRecorder.onLivePacket = { packet in
            guard case .buffer(_, let source, _) = packet else { return }
            pumpedSources.append(source)
        }
        let plan = MeetingCaptureSpoolPlan(
            libraryRootURL: fixture.libraryRoot,
            sessionID: UUID(),
            microphoneSourceID: UUID(),
            systemAudioSourceID: UUID()
        )

        try await fixture.audioRecorder.startMeetingRecording(spoolPlan: plan) { _ in }
        // Room tone first: each channel reads speech against its own tracked
        // floor, and neither has a floor before its first buffer.
        try feedLiveBuffers(fixture, microphoneAmplitude: 0.001, systemAmplitude: 0.001, count: 3)
        // The far end talks, then stops and the person recording answers.
        try feedLiveBuffers(fixture, microphoneAmplitude: 0.001, systemAmplitude: 0.5, count: 20)
        try feedLiveBuffers(fixture, microphoneAmplitude: 0.5, systemAmplitude: 0.001, count: 12)
        _ = try await fixture.audioRecorder.stopMeetingRecording()
        fixture.audioRecorder.onLivePacket = nil

        #expect(pumpedSources.contains(.systemAudio))
        // The regression this phase exists to fix: with system audio running, the
        // microphone used to be excluded from the live path entirely.
        #expect(pumpedSources.contains(.microphone))
    }

    /// Feeds one interleaved run of buffers to both capture children, at the
    /// amplitudes each channel is meant to carry. One buffer is 100 ms.
    private func feedLiveBuffers(
        _ fixture: Fixture,
        microphoneAmplitude: Float,
        systemAmplitude: Float,
        count: Int
    ) throws {
        for _ in 0..<count {
            let microphoneBuffer = try #require(
                MockAudioCaptureBackend.makeSynthesizedBuffer(
                    format: fixture.microphoneBackend.targetFormat,
                    amplitude: microphoneAmplitude
                )
            )
            let systemBuffer = try #require(
                MockAudioCaptureBackend.makeSynthesizedBuffer(
                    format: fixture.systemAudioBackend.targetFormat,
                    frequency: 220,
                    amplitude: systemAmplitude
                )
            )
            fixture.microphoneBackend.capturedOnBuffer?(microphoneBuffer)
            fixture.systemAudioBackend.capturedOnBuffer?(systemBuffer)
        }
    }

    @Test func stateWalksIdleToCapturingToFinalizingToCompleted() {
        let state = NoteCaptureState()
        #expect(state.phase == .idle)
        #expect(!state.isActive)

        state.beginStarting(includesSystemAudio: false, origin: .mainWindow)
        #expect(state.phase == .starting)
        #expect(state.origin == .mainWindow)
        state.beginCapturing(startedAt: .now)
        #expect(state.phase == .capturing)
        #expect(state.isActive)

        state.beginFinalizing(.sealingAudio)
        #expect(state.phase == .finalizing(.sealingAudio))
        state.beginFinalizing(.transcribing(0.5))
        #expect(state.phase == .finalizing(.transcribing(0.5)))
        state.beginFinalizing(.diarizing(nil))
        #expect(state.phase == .finalizing(.diarizing(nil)))
        state.beginFinalizing(.assembling)
        state.beginEnhancing()
        #expect(state.phase == .enhancing)

        state.complete()
        #expect(state.phase == .completed)
        #expect(!state.isActive)
    }

    @Test func stateKeepsFailureTextAndDegradedLiveTranscriptFlag() {
        let state = NoteCaptureState()
        state.beginStarting(includesSystemAudio: true, origin: .hotkey)
        state.updateLiveTranscript("half a sentence")
        state.markLiveTranscriptDegraded()

        #expect(state.liveTranscript == "half a sentence")
        #expect(state.isLiveTranscriptDegraded)

        state.fail("The recorder did not start.")
        #expect(state.failureMessage == "The recorder did not start.")
        #expect(state.audioLevel == 0)
    }

    @Test func stateKeepsAPanelFailureWithoutFailingTheCapture() {
        let state = NoteCaptureState()
        state.beginStarting(includesSystemAudio: false, origin: .mainWindow)
        let sessionID = UUID()
        state.bindSession(id: sessionID)
        state.beginCapturing(startedAt: Date(timeIntervalSinceReferenceDate: 100_000))
        state.beginFinalizing(.assembling)
        state.beginEnhancing()
        #expect(state.enhancementFailureMessage == nil)

        state.recordEnhancementFailure("The enhanced note could not be generated. Try again.")
        state.complete()

        // The capture completed: only the panel is missing, and the note page
        // has the text that says why.
        #expect(state.phase == .completed)
        #expect(state.failureMessage == nil)
        #expect(
            state.enhancementFailureMessage
                == "The enhanced note could not be generated. Try again."
        )

        state.clearEnhancementFailure(for: UUID())
        #expect(state.enhancementFailureMessage != nil)

        state.clearEnhancementFailure(for: sessionID)
        #expect(state.enhancementFailureMessage == nil)
    }

    // MARK: - Helpers

    private func makeSpoolPlan(
        _ fixture: Fixture,
        handle: NoteCaptureHandle
    ) -> MeetingCaptureSpoolPlan {
        MeetingCaptureSpoolPlan(
            libraryRootURL: fixture.libraryRoot,
            sessionID: handle.sessionID,
            microphoneSourceID: handle.microphoneSourceID,
            systemAudioSourceID: handle.systemAudioSourceID
        )
    }

    /// One sealed microphone chunk, so finalization has a source window to work
    /// against without any audio existing on disk.
    private func recordOneSealedChunk(
        in store: CaptureSessionStore,
        handle: NoteCaptureHandle
    ) throws {
        try store.recordSealedMeetingChunk(
            handle,
            checkpoint: MeetingChunkCheckpoint(
                sourceID: handle.microphoneSourceID,
                sequence: 0,
                startOffset: 0,
                duration: MeetingCaptureSpoolPlan.chunkDuration,
                managedMediaPath: CaptureSourceArtifactPath.relativePath(
                    sessionID: handle.sessionID,
                    sourceID: handle.microphoneSourceID,
                    chunkSequence: 0
                ),
                byteCount: MeetingCaptureSpoolPlan.defaultChunkByteCount,
                sha256: String(format: "%064x", 1),
                sealedAt: .now
            )
        )
    }

    /// Freezes the four start assignments so finalization runs without asking
    /// settings for a provider. The final-transcription stage is deliberately
    /// disabled, which is the "batch ASR cannot run" case.
    private func freezeAssignments(
        in store: CaptureSessionStore,
        sessionID: UUID
    ) throws {
        _ = try store.resolveAssignment(
            sessionID: sessionID,
            stage: .liveTranscription,
            attempt: 1
        ) {
            try CaptureStageAssignment(
                stage: .liveTranscription,
                providerKind: .streamingSpeech,
                providerIdentifier: TranscriptionBackend.parakeet.rawValue,
                modelIdentifier: "streaming-model",
                prompt: nil,
                selectedAt: .now,
                attempt: 1
            )
        }
        for stage in [CapturePipelineStage.finalTranscription, .diarization, .noteGeneration] {
            _ = try store.resolveAssignment(sessionID: sessionID, stage: stage, attempt: 1) {
                try CaptureStageAssignment(
                    stage: stage,
                    providerKind: .disabled,
                    providerIdentifier: "disabled",
                    modelIdentifier: nil,
                    prompt: nil,
                    selectedAt: .now,
                    attempt: 1
                )
            }
        }
    }
}
