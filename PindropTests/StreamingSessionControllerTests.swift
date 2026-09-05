//
//  StreamingSessionControllerTests.swift
//  PindropTests
//
//  Created on 2026-07-13.
//

import AVFoundation
import Foundation
import PindropAI
import PindropCore
import PindropData
import PindropSpeech
import SwiftData
import Testing
@testable import Pindrop

@MainActor
@Suite
struct StreamingSessionControllerTests {
    private struct OutputFailure: Error {}

    private final class RecordingClipboard: ClipboardProtocol, @unchecked Sendable {
        private(set) var copied: [String] = []

        func copyToClipboard(_ text: String) -> Bool {
            copied.append(text)
            return true
        }

        func captureSnapshot() -> ClipboardSnapshot { .empty }
        func currentChangeCount() -> Int { copied.count }
        func currentStringContent() -> String? { copied.last }
        func restoreSnapshot(_ snapshot: ClipboardSnapshot) -> Bool { true }
    }

    private final class RecordingToastPresenter: ToastPresenting, @unchecked Sendable {
        private(set) var payloads: [ToastPayload] = []

        func show(
            payload: ToastPayload,
            onAction: @escaping (UUID) -> Void,
            onHoverChange: @escaping (Bool) -> Void
        ) {
            payloads.append(payload)
        }

        func hide() {}
    }

    @MainActor
    private final class BeginTeardownWaitProbe {
        private var arrived = false
        private var waiter: CheckedContinuation<Void, Never>?

        func arrive() {
            arrived = true
            waiter?.resume()
            waiter = nil
        }

        func waitUntilArrived() async {
            if arrived { return }
            await withCheckedContinuation { waiter = $0 }
        }
    }

    private final class ArtifactStreamingEngine: PindropSpeech.StreamingTranscriptionEngine, @unchecked Sendable {
        private(set) var state: StreamingTranscriptionState = .unloaded
        private(set) var startStreamingCallCount = 0
        private(set) var stopCallCount = 0
        var startError: Error?
        var stopResult = ""
        private var transcriptionCallback: StreamingTranscriptionCallback?
        private var finalUtteranceCallback: EndOfUtteranceCallback?

        func loadModel(name: String) async throws {
            state = .ready
        }

        func unloadModel() async {
            state = .unloaded
        }

        func startStreaming() async throws {
            startStreamingCallCount += 1
            if let startError {
                throw startError
            }
            state = .streaming
        }

        func stopStreaming() async throws -> String {
            stopCallCount += 1
            state = .ready
            return stopResult
        }

        func pauseStreaming() async {
            state = .paused
        }

        func resumeStreaming() async throws {
            state = .streaming
        }

        func processAudioChunk(_ samples: [Float]) async throws {}
        func processAudioBuffer(_ buffer: AVAudioPCMBuffer) async throws {}

        func setTranscriptionCallback(_ callback: @escaping StreamingTranscriptionCallback) async {
            transcriptionCallback = callback
        }

        func setEndOfUtteranceCallback(_ callback: @escaping EndOfUtteranceCallback) async {
            finalUtteranceCallback = callback
        }

        func reset() async {
            state = .ready
        }

        func emitFinal(_ text: String, fedSeconds: TimeInterval = 0) {
            finalUtteranceCallback?(
                StreamingTranscriptionEmission(text: text, fedSeconds: fedSeconds)
            )
        }
    }


    private func makeDictionaryStore() throws -> DictionaryStore {
        let schema = Schema([VocabularyWord.self, WordReplacement.self])
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [configuration])
        return DictionaryStore(modelContext: ModelContext(container))
    }

    private func makeCaptureStore() throws -> (CaptureSessionStore, ModelContainer) {
        let container = try PindropModelContainerFactory.makeInMemoryContainer()
        return (CaptureSessionStore(modelContext: ModelContext(container)), container)
    }

    @discardableResult
    private func startNoteCapture(
        in store: CaptureSessionStore,
        includeSystemAudio: Bool = false
    ) throws -> NoteCaptureHandle {
        try store.startNoteCapture(
            includeSystemAudio: includeSystemAudio,
            intent: CaptureIntentRequest(destination: .newNote, origin: .mainWindow)
        )
    }

    private func liveAssignment(
        modelIdentifier: String = StreamingChunkProfile.standard.repoFolderName,
        providerIdentifier: String = TranscriptionBackend.parakeet.rawValue
    ) throws -> CaptureStageAssignment {
        try CaptureStageAssignment(
            stage: .liveTranscription,
            providerKind: .streamingSpeech,
            providerIdentifier: providerIdentifier,
            modelIdentifier: modelIdentifier,
            prompt: nil,
            selectedAt: .now,
            attempt: 1
        )
    }


    private func makeController(
        clipboard: RecordingClipboard,
        toastPresenter: RecordingToastPresenter,
        transcriptionService: TranscriptionService? = nil,
        dictionaryStore: DictionaryStore? = nil,
        captureSessionStore: CaptureSessionStore? = nil,
        audioRecorder: AudioRecorder? = nil,
        transcriptionBackend: TranscriptionBackend = .parakeet,
        voiceIsolationEnabled: Bool = false,
        artifactLiveTranscriptionLimit: TimeInterval = StreamingSessionController
            .defaultArtifactLiveTranscriptionLimit
    ) throws -> StreamingSessionController {
        let settings = SettingsStore()
        settings.resetAllSettings()
        settings.addTrailingSpace = false
        settings.selectedTranscriptionBackend = transcriptionBackend

        settings.voiceIsolationEnabled = voiceIsolationEnabled
        let outputManager = OutputManager(
            outputMode: .clipboard,
            clipboard: clipboard,
            accessibilityPermissionChecker: { false }
        )
        let toastService = ToastService(presenter: toastPresenter)
        let effectiveAudioRecorder = try audioRecorder ?? AudioRecorder(permissionManager: PermissionManager())
        let effectiveDictionaryStore = try dictionaryStore ?? makeDictionaryStore()
        let effectiveCaptureSessionStore = try captureSessionStore ?? makeCaptureStore().0


        return StreamingSessionController(
            transcriptionService: transcriptionService ?? TranscriptionService(
                storageLocations: ModelStorageLocations(
                    pindropApplicationSupportRoot: FileManager.default.temporaryDirectory
                        .appendingPathComponent("pindrop-streaming-session-\(UUID().uuidString)/Pindrop", isDirectory: true),
                    fluidAudioModelsRoot: FileManager.default.temporaryDirectory
                        .appendingPathComponent("pindrop-streaming-session-\(UUID().uuidString)/FluidAudio/Models", isDirectory: true)
                )
            ),
            settingsStore: settings,
            dictionaryStore: effectiveDictionaryStore,
            outputManager: outputManager,
            toastService: toastService,
            liveTranscriptState: LiveTranscriptState(),
            audioRecorder: effectiveAudioRecorder,
            captureSessionStore: effectiveCaptureSessionStore,
            normalizeText: { AppCoordinator.normalizedTranscriptionText($0) },
            isEffectivelyEmptyText: { AppCoordinator.isTranscriptionEffectivelyEmpty($0) },
            artifactLiveTranscriptionLimit: artifactLiveTranscriptionLimit
        )
    }


    @Test func cancelledFinalizeInsertionDoesNotClipboardOrToast() async throws {
        let clipboard = RecordingClipboard()
        let toastPresenter = RecordingToastPresenter()
        let controller = try makeController(clipboard: clipboard, toastPresenter: toastPresenter)

        actor Gate {
            private var isOpen = false
            private var waiters: [CheckedContinuation<Void, Never>] = []

            func open() {
                isOpen = true
                let pending = waiters
                waiters.removeAll()
                for waiter in pending { waiter.resume() }
            }

            func waitUntilOpen() async {
                if isOpen { return }
                await withCheckedContinuation { continuation in
                    waiters.append(continuation)
                }
            }
        }

        let gate = Gate()
        let task = Task { @MainActor in
            await gate.waitUntilOpen()
            return try await controller.finalizeInsertionForTesting(finalText: "hello cancelled")
        }

        // Cancel before the insertion stage runs so cooperative cancellation is observed
        // before any paste/clipboard fallback.
        task.cancel()
        await gate.open()

        await #expect(throws: CancellationError.self) {
            _ = try await task.value
        }

        #expect(clipboard.copied.isEmpty)
        #expect(toastPresenter.payloads.isEmpty)
    }

    @Test func outputErrorRacingCancellationDoesNotClipboardOrToast() async throws {
        let clipboard = RecordingClipboard()
        let toastPresenter = RecordingToastPresenter()
        let controller = try makeController(clipboard: clipboard, toastPresenter: toastPresenter)

        actor Gate {
            private var isOpen = false
            private var arrived = false
            private var waiters: [CheckedContinuation<Void, Never>] = []
            private var arrivalWaiters: [CheckedContinuation<Void, Never>] = []

            func open() {
                isOpen = true
                let pending = waiters
                waiters.removeAll()
                for waiter in pending { waiter.resume() }
            }

            func arriveThenWait() async {
                arrived = true
                let pending = arrivalWaiters
                arrivalWaiters.removeAll()
                for waiter in pending { waiter.resume() }
                if isOpen { return }
                await withCheckedContinuation { continuation in
                    waiters.append(continuation)
                }
            }

            func waitUntilArrived() async {
                if arrived { return }
                await withCheckedContinuation { continuation in
                    arrivalWaiters.append(continuation)
                }
            }
        }

        let gate = Gate()
        // Production path: custom output failure can race with cancellation. The shared
        // performFinalStreamingInsertion catch must prefer task cancellation over
        // clipboard/toast fallback.
        controller.setFinalInsertionOverrideForTesting { _ in
            await gate.arriveThenWait()
            throw OutputFailure()
        }

        let task = Task { @MainActor in
            try await controller.finalizeInsertionForTesting(finalText: "race me")
        }

        // Cancel while insertion is in-flight, then release the failing output.
        await gate.waitUntilArrived()
        task.cancel()
        await gate.open()

        await #expect(throws: CancellationError.self) {
            _ = try await task.value
        }

        #expect(clipboard.copied.isEmpty)
        #expect(toastPresenter.payloads.isEmpty)
    }

    @Test func cancellationAfterSuccessfulInsertionKeepsOutcome() async throws {
        let clipboard = RecordingClipboard()
        let toastPresenter = RecordingToastPresenter()
        let controller = try makeController(clipboard: clipboard, toastPresenter: toastPresenter)

        // The override "lands" the paste and then the operation is cancelled before
        // the controller returns. The committed output must still reach the caller
        // (so history is persisted) instead of collapsing into CancellationError.
        controller.setFinalInsertionOverrideForTesting { _ in
            withUnsafeCurrentTask { $0?.cancel() }
            return .pasted(destinationAppName: "TextEdit", destinationAppBundleID: "com.apple.TextEdit")
        }

        let task = Task { @MainActor in
            try await controller.finalizeInsertionForTesting(finalText: "committed text")
        }
        let outcome = try await task.value

        #expect(outcome.outputSucceeded)
        #expect(outcome.didPaste)
        #expect(outcome.destinationAppName == "TextEdit")
        #expect(clipboard.copied.isEmpty)
        #expect(toastPresenter.payloads.isEmpty)
    }

    @Test func cancellationPolicyRejectsOnlyCancellationErrors() {
        #expect(StreamingSessionController.isCancellationError(CancellationError()))
        #expect(StreamingSessionController.isCancellationError(URLError(.cancelled)))
        #expect(StreamingSessionController.isCancellationError(OutputManagerError.clipboardWriteFailed) == false)
    }

    @Test func beginInstallsCallbacksAndStartsStreamingEngineOnce() async throws {
        let clipboard = RecordingClipboard()
        let toastPresenter = RecordingToastPresenter()

        final class CountingStreamingEngine: PindropSpeech.StreamingTranscriptionEngine, @unchecked Sendable {
            private(set) var state: StreamingTranscriptionState = .unloaded
            private(set) var loadCallCount = 0
            private(set) var startStreamingCallCount = 0
            private(set) var transcriptionCallbackInstallCount = 0
            private(set) var endOfUtteranceCallbackInstallCount = 0
            /// Captured synchronously inside `loadModel` / `startStreaming` so the
            /// assertions are ordering-based, not scheduling-sensitive.
            private(set) var hadBothCallbacksInstalledAtLoad = false
            private(set) var hadBothCallbacksInstalledAtStart = false

            func loadModel(name: String) async throws {
                hadBothCallbacksInstalledAtLoad =
                    transcriptionCallbackInstallCount > 0
                    && endOfUtteranceCallbackInstallCount > 0
                loadCallCount += 1
                state = .ready
            }

            func unloadModel() async {
                state = .unloaded
            }

            func startStreaming() async throws {
                hadBothCallbacksInstalledAtStart =
                    transcriptionCallbackInstallCount > 0
                    && endOfUtteranceCallbackInstallCount > 0
                startStreamingCallCount += 1
                state = .streaming
            }

            func stopStreaming() async throws -> String {
                state = .ready
                return ""
            }

            func pauseStreaming() async {
                state = .paused
            }

            func resumeStreaming() async throws {
                state = .streaming
            }

            func processAudioChunk(_ samples: [Float]) async throws {}
            func processAudioBuffer(_ buffer: AVAudioPCMBuffer) async throws {}

            func setTranscriptionCallback(_ callback: @escaping StreamingTranscriptionCallback) async {
                transcriptionCallbackInstallCount += 1
            }

            func setEndOfUtteranceCallback(_ callback: @escaping EndOfUtteranceCallback) async {
                endOfUtteranceCallbackInstallCount += 1
            }

            func reset() async {
                state = .ready
            }
        }

        let engine = CountingStreamingEngine()
        var factoryCallCount = 0
        var profileProviderCallCount = 0
        var backendProviderCallCount = 0
        let transcriptionService = TranscriptionService(
            storageLocations: ModelStorageLocations(
                pindropApplicationSupportRoot: FileManager.default.temporaryDirectory
                    .appendingPathComponent("pindrop-streaming-engine-\(UUID().uuidString)/Pindrop", isDirectory: true),
                fluidAudioModelsRoot: FileManager.default.temporaryDirectory
                    .appendingPathComponent("pindrop-streaming-engine-\(UUID().uuidString)/FluidAudio/Models", isDirectory: true)
            ),
            streamingEngineFactory: { _, _ in
                factoryCallCount += 1
                return engine
            },
            streamingChunkProfileProvider: {
                profileProviderCallCount += 1
                return .standard
            },
            streamingBackendProvider: {
                backendProviderCallCount += 1
                return .parakeet
            }
        )

        let controller = try makeController(
            clipboard: clipboard,
            toastPresenter: toastPresenter,
            transcriptionService: transcriptionService
        )

        let session = try #require(await controller.begin())

        #expect(controller.isSessionActive)
        // Both engine callbacks must already be installed when load and start run.
        #expect(engine.hadBothCallbacksInstalledAtLoad)
        #expect(engine.hadBothCallbacksInstalledAtStart)
        #expect(engine.transcriptionCallbackInstallCount == 1)
        #expect(engine.endOfUtteranceCallbackInstallCount == 1)
        #expect(engine.loadCallCount == 1)
        #expect(engine.startStreamingCallCount == 1)
        #expect(factoryCallCount == 1)
        // One prepare evaluation only (no explicit prepare + startStreaming prepare).
        #expect(profileProviderCallCount == 1)
        #expect(backendProviderCallCount == 1)
        #expect(engine.state == .streaming)
        #expect(transcriptionService.state == .transcribing)

        await controller.cancel(session: session)
    }

    @Test func detachedTeardownsSerializeDirectPumpBeforeSuccessorBegins() async throws {
        actor DirectPumpGate {
            private var isOpen = false
            private var consumerEntered = false
            private var openWaiters: [CheckedContinuation<Void, Never>] = []
            private var consumerEntryWaiters: [CheckedContinuation<Void, Never>] = []

            func enterAndWait() async {
                consumerEntered = true
                let pendingEntryWaiters = consumerEntryWaiters
                consumerEntryWaiters.removeAll()
                for waiter in pendingEntryWaiters { waiter.resume() }

                if isOpen { return }
                await withCheckedContinuation { openWaiters.append($0) }
            }

            func waitUntilConsumerEntered() async {
                if consumerEntered { return }
                await withCheckedContinuation { consumerEntryWaiters.append($0) }
            }

            func open() {
                isOpen = true
                let pendingOpenWaiters = openWaiters
                openWaiters.removeAll()
                for waiter in pendingOpenWaiters { waiter.resume() }
            }
        }

        final class GatedStreamingEngine: PindropSpeech.StreamingTranscriptionEngine, @unchecked Sendable {
            private(set) var state: StreamingTranscriptionState = .unloaded
            private(set) var startStreamingCallCount = 0
            private(set) var resetCallCount = 0
            private let directPumpGate: DirectPumpGate

            init(directPumpGate: DirectPumpGate) {
                self.directPumpGate = directPumpGate
            }

            func loadModel(name: String) async throws {
                state = .ready
            }

            func unloadModel() async {
                state = .unloaded
            }

            func startStreaming() async throws {
                startStreamingCallCount += 1
                state = .streaming
            }

            func stopStreaming() async throws -> String {
                state = .ready
                return ""
            }

            func pauseStreaming() async {
                state = .paused
            }

            func resumeStreaming() async throws {
                state = .streaming
            }

            func processAudioChunk(_ samples: [Float]) async throws {}

            func processAudioBuffer(_ buffer: AVAudioPCMBuffer) async throws {
                await directPumpGate.enterAndWait()
            }

            func setTranscriptionCallback(_ callback: @escaping StreamingTranscriptionCallback) async {}
            func setEndOfUtteranceCallback(_ callback: @escaping EndOfUtteranceCallback) async {}

            func reset() async {
                resetCallCount += 1
                state = .ready
            }
        }

        let clipboard = RecordingClipboard()
        let toastPresenter = RecordingToastPresenter()
        let audioRecorder = try AudioRecorder(permissionManager: PermissionManager())
        let directPumpGate = DirectPumpGate()
        let engine = GatedStreamingEngine(directPumpGate: directPumpGate)
        let transcriptionService = TranscriptionService(
            storageLocations: ModelStorageLocations(
                pindropApplicationSupportRoot: FileManager.default.temporaryDirectory
                    .appendingPathComponent("pindrop-streaming-teardown-\(UUID().uuidString)/Pindrop", isDirectory: true),
                fluidAudioModelsRoot: FileManager.default.temporaryDirectory
                    .appendingPathComponent("pindrop-streaming-teardown-\(UUID().uuidString)/FluidAudio/Models", isDirectory: true)
            ),
            streamingEngineFactory: { _, _ in engine },
            streamingChunkProfileProvider: { .standard },
            streamingBackendProvider: { .parakeet }
        )
        let controller = try makeController(
            clipboard: clipboard,
            toastPresenter: toastPresenter,
            transcriptionService: transcriptionService,
            audioRecorder: audioRecorder
        )

        _ = try #require(await controller.begin())
        let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1)!
        buffer.frameLength = 1
        audioRecorder.onLivePacket?(.buffer(buffer, source: .microphone, captureTime: 0))
        await directPumpGate.waitUntilConsumerEntered()

        controller.cancelDetached() // T1: waits for the direct consumer.
        controller.cancelDetached() // T2: must await T1 even without an active session.

        let beginWaitProbe = BeginTeardownWaitProbe()
        controller.setBeginTeardownWaitObserverForTesting { beginWaitProbe.arrive() }
        let successorBegin = Task { @MainActor in
            await controller.begin()
        }
        await beginWaitProbe.waitUntilArrived()

        // C reached begin but must remain behind T2 while T1's direct pump is blocked.
        #expect(engine.startStreamingCallCount == 1)

        await directPumpGate.open()
        let successorSession = try #require(await successorBegin.value)

        // T1 reset before C started; it cannot arrive late and cancel C.
        #expect(engine.resetCallCount == 2)
        #expect(engine.startStreamingCallCount == 2)
        #expect(engine.state == .streaming)

        await controller.cancel(session: successorSession)
    }
    @Test func concurrentBeginReturnsNilWhileExactFirstSessionStarts() async throws {
        actor StartGate {
            private var hasStarted = false
            private var isOpen = false
            private var startWaiters: [CheckedContinuation<Void, Never>] = []
            private var openWaiter: CheckedContinuation<Void, Never>?

            func arriveThenWait() async {
                hasStarted = true
                let waiters = startWaiters
                startWaiters.removeAll()
                for waiter in waiters {
                    waiter.resume()
                }
                guard !isOpen else { return }
                await withCheckedContinuation { openWaiter = $0 }
            }

            func waitUntilStarted() async {
                guard !hasStarted else { return }
                await withCheckedContinuation { startWaiters.append($0) }
            }

            func open() {
                isOpen = true
                openWaiter?.resume()
                openWaiter = nil
            }
        }

        final class GatedStreamingEngine: PindropSpeech.StreamingTranscriptionEngine, @unchecked Sendable {
            private(set) var state: StreamingTranscriptionState = .unloaded
            private(set) var startStreamingCallCount = 0
            private(set) var stopCallCount = 0
            let startGate: StartGate

            init(startGate: StartGate) {
                self.startGate = startGate
            }

            func loadModel(name: String) async throws {
                state = .ready
            }

            func unloadModel() async {
                state = .unloaded
            }

            func startStreaming() async throws {
                startStreamingCallCount += 1
                await startGate.arriveThenWait()
                state = .streaming
            }

            func stopStreaming() async throws -> String {
                stopCallCount += 1
                state = .ready
                return ""
            }

            func pauseStreaming() async {
                state = .paused
            }

            func resumeStreaming() async throws {
                state = .streaming
            }

            func processAudioChunk(_ samples: [Float]) async throws {}
            func processAudioBuffer(_ buffer: AVAudioPCMBuffer) async throws {}
            func setTranscriptionCallback(_ callback: @escaping StreamingTranscriptionCallback) async {}
            func setEndOfUtteranceCallback(_ callback: @escaping EndOfUtteranceCallback) async {}

            func reset() async {
                state = .ready
            }
        }

        let clipboard = RecordingClipboard()
        let toastPresenter = RecordingToastPresenter()
        let startGate = StartGate()
        let engine = GatedStreamingEngine(startGate: startGate)
        let transcriptionService = TranscriptionService(
            storageLocations: ModelStorageLocations(
                pindropApplicationSupportRoot: FileManager.default.temporaryDirectory
                    .appendingPathComponent("generic-exact-owner-\(UUID().uuidString)/Pindrop", isDirectory: true),
                fluidAudioModelsRoot: FileManager.default.temporaryDirectory
                    .appendingPathComponent("generic-exact-owner-\(UUID().uuidString)/FluidAudio/Models", isDirectory: true)
            ),
            streamingEngineFactory: { _, _ in engine },
            streamingChunkProfileProvider: { .standard },
            streamingBackendProvider: { .parakeet }
        )
        let controller = try makeController(
            clipboard: clipboard,
            toastPresenter: toastPresenter,
            transcriptionService: transcriptionService
        )

        let firstBegin = Task { await controller.begin() }
        await startGate.waitUntilStarted()

        #expect(await controller.begin() == nil)
        await startGate.open()

        let session = try #require(await firstBegin.value)
        #expect(engine.startStreamingCallCount == 1)
        await controller.cancel(session: session)
        #expect(transcriptionService.state == .ready)
        #expect(!controller.isSessionActive)
    }

    @Test func staleGenericCancelAndFinalizeDoNotAffectSuccessor() async throws {
        let clipboard = RecordingClipboard()
        let toastPresenter = RecordingToastPresenter()
        let engine = ArtifactStreamingEngine()
        let transcriptionService = TranscriptionService(
            storageLocations: ModelStorageLocations(
                pindropApplicationSupportRoot: FileManager.default.temporaryDirectory
                    .appendingPathComponent("generic-stale-owner-\(UUID().uuidString)/Pindrop", isDirectory: true),
                fluidAudioModelsRoot: FileManager.default.temporaryDirectory
                    .appendingPathComponent("generic-stale-owner-\(UUID().uuidString)/FluidAudio/Models", isDirectory: true)
            ),
            streamingEngineFactory: { _, _ in engine },
            streamingChunkProfileProvider: { .standard },
            streamingBackendProvider: { .parakeet }
        )
        let controller = try makeController(
            clipboard: clipboard,
            toastPresenter: toastPresenter,
            transcriptionService: transcriptionService
        )

        let first = try #require(await controller.begin())
        await controller.cancel(session: first)
        let successor = try #require(await controller.begin())

        controller.cancelDetached(session: first)
        #expect(controller.isSessionActive)

        await #expect(throws: CancellationError.self) {
            _ = try await controller.finalize(
                recordedAudioData: Data(),
                recordingDuration: 0,
                session: first
            )
        }

        #expect(controller.isSessionActive)
        await controller.cancel(session: successor)
    }


    @Test func artifactCancellationClearsUnifiedActivityBeforeAnotherArtifactOrGenericSession() async throws {
        let clipboard = RecordingClipboard()
        let toastPresenter = RecordingToastPresenter()
        let engine = ArtifactStreamingEngine()
        let transcriptionService = TranscriptionService(
            storageLocations: ModelStorageLocations(
                pindropApplicationSupportRoot: FileManager.default
                    .temporaryDirectory

                    .appendingPathComponent("artifact-restart-\(UUID().uuidString)/Pindrop", isDirectory: true),
                fluidAudioModelsRoot: FileManager.default
                    .temporaryDirectory
                    .appendingPathComponent("artifact-restart-\(UUID().uuidString)/FluidAudio/Models", isDirectory: true)
            ),
            streamingEngineFactory: { _, _ in engine },
            streamingChunkProfileProvider: { .standard },
            streamingBackendProvider: { .parakeet }
        )
        let (store, _) = try makeCaptureStore()
        let assignment = try liveAssignment()
        let firstHandle = try startNoteCapture(in: store)
        let secondHandle = try startNoteCapture(in: store)
        let controller = try makeController(
            clipboard: clipboard,
            toastPresenter: toastPresenter,
            transcriptionService: transcriptionService,
            captureSessionStore: store
        )

        #expect(await controller.beginArtifactCapture(for: firstHandle, assignment: assignment))
        #expect(controller.hasActiveStreamingSession)
        controller.cancelDetached()
        #expect(!controller.hasActiveStreamingSession)

        #expect(await controller.beginArtifactCapture(for: secondHandle, assignment: assignment))
        #expect(controller.hasActiveStreamingSession)
        await controller.finishArtifactCapture(for: secondHandle)
        #expect(!controller.hasActiveStreamingSession)

        let session = try #require(await controller.begin())
        #expect(controller.hasActiveStreamingSession)
        await controller.cancel(session: session)
        #expect(!controller.hasActiveStreamingSession)
    }

    @Test func staleArtifactHandleCancelAndFinishDoNotAffectSuccessor() async throws {
        let clipboard = RecordingClipboard()
        let toastPresenter = RecordingToastPresenter()
        let engine = ArtifactStreamingEngine()
        let transcriptionService = TranscriptionService(
            storageLocations: ModelStorageLocations(
                pindropApplicationSupportRoot: FileManager.default.temporaryDirectory
                    .appendingPathComponent("artifact-stale-owner-\(UUID().uuidString)/Pindrop", isDirectory: true),
                fluidAudioModelsRoot: FileManager.default.temporaryDirectory
                    .appendingPathComponent("artifact-stale-owner-\(UUID().uuidString)/FluidAudio/Models", isDirectory: true)
            ),
            streamingEngineFactory: { _, _ in engine },
            streamingChunkProfileProvider: { .standard },
            streamingBackendProvider: { .parakeet }
        )
        let (store, _) = try makeCaptureStore()
        let firstHandle = try startNoteCapture(in: store)
        let secondHandle = try startNoteCapture(in: store)
        let controller = try makeController(
            clipboard: clipboard,
            toastPresenter: toastPresenter,
            transcriptionService: transcriptionService,
            captureSessionStore: store
        )
        let assignment = try liveAssignment()

        #expect(await controller.beginArtifactCapture(for: firstHandle, assignment: assignment))
        await controller.cancelArtifactCapture(for: firstHandle)
        #expect(await controller.beginArtifactCapture(for: secondHandle, assignment: assignment))

        await controller.cancelArtifactCapture(for: firstHandle)
        await controller.finishArtifactCapture(for: firstHandle)

        #expect(controller.isArtifactCaptureActive)
        #expect(engine.stopCallCount == 0)
        await controller.finishArtifactCapture(for: secondHandle)
        #expect(!controller.isArtifactCaptureActive)
        #expect(engine.stopCallCount == 1)
    }

    @Test func artifactFallbackStartFailureDoesNotLeakToastIntoNextGenericSession() async throws {
        let clipboard = RecordingClipboard()
        let toastPresenter = RecordingToastPresenter()
        let engine = ArtifactStreamingEngine()
        engine.startError = OutputFailure()
        var requestedBackend: TranscriptionBackend = .appleSpeechTranscriber
        let transcriptionService = TranscriptionService(
            storageLocations: ModelStorageLocations(
                pindropApplicationSupportRoot: FileManager.default.temporaryDirectory
                    .appendingPathComponent("artifact-fallback-isolation-\(UUID().uuidString)/Pindrop", isDirectory: true),
                fluidAudioModelsRoot: FileManager.default.temporaryDirectory
                    .appendingPathComponent("artifact-fallback-isolation-\(UUID().uuidString)/FluidAudio/Models", isDirectory: true)
            ),
            streamingEngineFactory: { _, _ in engine },
            appleSpeechEngineFactory: { nil },
            streamingChunkProfileProvider: { .standard },
            streamingBackendProvider: { requestedBackend }
        )
        let (store, _) = try makeCaptureStore()
        let handle = try startNoteCapture(in: store)
        let assignment = try liveAssignment(
            providerIdentifier: TranscriptionBackend.appleSpeechTranscriber.rawValue
        )
        let controller = try makeController(
            clipboard: clipboard,
            toastPresenter: toastPresenter,
            transcriptionService: transcriptionService,
            captureSessionStore: store,
            transcriptionBackend: .appleSpeechTranscriber
        )

        #expect(await controller.beginArtifactCapture(for: handle, assignment: assignment) == false)
        #expect(engine.startStreamingCallCount == 1)
        #expect(toastPresenter.payloads.isEmpty)

        engine.startError = nil
        requestedBackend = .parakeet

        let session = try #require(await controller.begin())
        #expect(engine.startStreamingCallCount == 2)
        #expect(toastPresenter.payloads.isEmpty)
        await controller.cancel(session: session)
    }

    @Test func artifactCaptureCheckpointsOnlyExactEffectiveEngineAndFinishesWithoutOutput() async throws {
        let clipboard = RecordingClipboard()
        let toastPresenter = RecordingToastPresenter()
        let engine = ArtifactStreamingEngine()
        engine.stopResult = "hello artifact"
        let transcriptionService = TranscriptionService(
            storageLocations: ModelStorageLocations(
                pindropApplicationSupportRoot: FileManager.default.temporaryDirectory
                    .appendingPathComponent("artifact-exact-\(UUID().uuidString)/Pindrop", isDirectory: true),
                fluidAudioModelsRoot: FileManager.default.temporaryDirectory
                    .appendingPathComponent("artifact-exact-\(UUID().uuidString)/FluidAudio/Models", isDirectory: true)
            ),
            streamingEngineFactory: { _, _ in engine },
            streamingChunkProfileProvider: { .standard },
            streamingBackendProvider: { .parakeet }
        )
        let (store, _) = try makeCaptureStore()
        let handle = try startNoteCapture(in: store)
        let assignment = try liveAssignment()
        _ = try store.resolveAssignment(
            sessionID: handle.sessionID,
            stage: .liveTranscription,
            attempt: assignment.attempt
        ) {
            assignment
        }
        let controller = try makeController(
            clipboard: clipboard,
            toastPresenter: toastPresenter,
            transcriptionService: transcriptionService,
            captureSessionStore: store
        )

        let started = await controller.beginArtifactCapture(for: handle, assignment: assignment)
        #expect(started)
        #expect(controller.isArtifactCaptureActive)
        await controller.finishArtifactCapture(for: handle)
        let recovery = try #require(store.voiceNoteRecoveryCandidates().first)
        // The trailing newline is the paragraph boundary an artifact session
        // closes at every end-of-utterance final. It is what the durable
        // checkpoint holds, and Phase 1's spans are derived from it.
        #expect(recovery.latestLiveCheckpoint?.committedText == "Hello artifact\n")

        #expect(!controller.isArtifactCaptureActive)
        #expect(engine.stopCallCount == 1)
        #expect(transcriptionService.state == .ready)
        #expect(clipboard.copied.isEmpty)
        #expect(toastPresenter.payloads.isEmpty)
    }

    @Test func artifactCaptureMismatchProducesNoRevisionAndOneRetryableFailure() async throws {
        let clipboard = RecordingClipboard()
        let toastPresenter = RecordingToastPresenter()
        let engine = ArtifactStreamingEngine()
        let transcriptionService = TranscriptionService(
            storageLocations: ModelStorageLocations(
                pindropApplicationSupportRoot: FileManager.default.temporaryDirectory
                    .appendingPathComponent("artifact-mismatch-\(UUID().uuidString)/Pindrop", isDirectory: true),
                fluidAudioModelsRoot: FileManager.default.temporaryDirectory
                    .appendingPathComponent("artifact-mismatch-\(UUID().uuidString)/FluidAudio/Models", isDirectory: true)
            ),
            streamingEngineFactory: { _, _ in engine },
            streamingChunkProfileProvider: { .standard },
            streamingBackendProvider: { .parakeet }
        )
        let (store, container) = try makeCaptureStore()
        let handle = try startNoteCapture(in: store)
        let assignment = try liveAssignment(modelIdentifier: StreamingChunkProfile.lowLatency.repoFolderName)
        let controller = try makeController(
            clipboard: clipboard,
            toastPresenter: toastPresenter,
            transcriptionService: transcriptionService,
            captureSessionStore: store
        )

        let started = await controller.beginArtifactCapture(for: handle, assignment: assignment)
        #expect(!started)
        #expect(!controller.isArtifactCaptureActive)
        #expect(try store.voiceNoteRecoveryCandidates().isEmpty)
        let revisions = try ModelContext(container).fetch(
            FetchDescriptor<CaptureTranscriptRevisionModel>()
        ).filter { $0.sessionID == handle.sessionID }
        #expect(revisions.isEmpty)
        let failures = try ModelContext(container).fetch(FetchDescriptor<CaptureFailureRecordModel>())
            .filter { $0.sessionID == handle.sessionID }
        #expect(failures.count == 1)
        #expect(failures[0].stageRawValue == CapturePipelineStage.liveTranscription.rawValue)
        #expect(failures[0].errorCode == "streaming-engine-identity-mismatch")
        #expect(failures[0].isRetryable)
        #expect(clipboard.copied.isEmpty)
        #expect(toastPresenter.payloads.isEmpty)
    }

    @Test func artifactCheckpointFailureRecordsOnceAndStillFinishes() async throws {
        let clipboard = RecordingClipboard()
        let toastPresenter = RecordingToastPresenter()
        let engine = ArtifactStreamingEngine()
        let transcriptionService = TranscriptionService(
            storageLocations: ModelStorageLocations(
                pindropApplicationSupportRoot: FileManager.default.temporaryDirectory
                    .appendingPathComponent("artifact-checkpoint-\(UUID().uuidString)/Pindrop", isDirectory: true),
                fluidAudioModelsRoot: FileManager.default.temporaryDirectory
                    .appendingPathComponent("artifact-checkpoint-\(UUID().uuidString)/FluidAudio/Models", isDirectory: true)
            ),
            streamingEngineFactory: { _, _ in engine },
            streamingChunkProfileProvider: { .standard },
            streamingBackendProvider: { .parakeet }
        )
        let (store, container) = try makeCaptureStore()
        let handle = try startNoteCapture(in: store)
        let assignment = try liveAssignment()
        let controller = try makeController(
            clipboard: clipboard,
            toastPresenter: toastPresenter,
            transcriptionService: transcriptionService,
            captureSessionStore: store
        )

        let started = await controller.beginArtifactCapture(for: handle, assignment: assignment)
        #expect(started)
        engine.emitFinal("first checkpoint")
        engine.emitFinal("first checkpoint grows")
        try await Task.sleep(for: .milliseconds(10))
        await controller.finishArtifactCapture(for: handle)

        let failures = try ModelContext(container).fetch(FetchDescriptor<CaptureFailureRecordModel>())
            .filter { $0.sessionID == handle.sessionID }
        #expect(failures.count == 1)
        #expect(failures[0].errorCode == "live-transcript-checkpoint-failed")
        #expect(failures[0].isRetryable)
        #expect(!controller.isArtifactCaptureActive)
        #expect(engine.stopCallCount == 1)
        #expect(clipboard.copied.isEmpty)
        #expect(toastPresenter.payloads.isEmpty)
    }

    @Test func twoSourceArtifactCaptureCheckpointsOnTheMicrophoneSourceOnly() async throws {
        let clipboard = RecordingClipboard()
        let toastPresenter = RecordingToastPresenter()
        let engine = ArtifactStreamingEngine()
        engine.stopResult = "hello meeting"
        let transcriptionService = TranscriptionService(
            storageLocations: ModelStorageLocations(
                pindropApplicationSupportRoot: FileManager.default.temporaryDirectory
                    .appendingPathComponent("artifact-two-source-\(UUID().uuidString)/Pindrop", isDirectory: true),
                fluidAudioModelsRoot: FileManager.default.temporaryDirectory
                    .appendingPathComponent("artifact-two-source-\(UUID().uuidString)/FluidAudio/Models", isDirectory: true)
            ),
            streamingEngineFactory: { _, _ in engine },
            streamingChunkProfileProvider: { .standard },
            streamingBackendProvider: { .parakeet }
        )
        let (store, container) = try makeCaptureStore()
        let handle = try startNoteCapture(in: store, includeSystemAudio: true)
        let systemAudioSourceID = try #require(handle.systemAudioSourceID)
        let assignment = try liveAssignment()
        _ = try store.resolveAssignment(
            sessionID: handle.sessionID,
            stage: .liveTranscription,
            attempt: assignment.attempt
        ) {
            assignment
        }
        let controller = try makeController(
            clipboard: clipboard,
            toastPresenter: toastPresenter,
            transcriptionService: transcriptionService,
            captureSessionStore: store
        )

        #expect(await controller.beginArtifactCapture(for: handle, assignment: assignment))
        await controller.finishArtifactCapture(for: handle)

        let revisions = try ModelContext(container).fetch(
            FetchDescriptor<CaptureTranscriptRevisionModel>()
        ).filter { $0.sessionID == handle.sessionID }
        #expect(!revisions.isEmpty)
        #expect(revisions.allSatisfy { $0.sourceID == handle.microphoneSourceID })
        #expect(!revisions.contains { $0.sourceID == systemAudioSourceID })
        #expect(revisions.last?.text == "Hello meeting\n")
        #expect(!controller.isArtifactCaptureActive)
    }

    @Test func artifactCaptureStopsLiveTranscriptionPastTheDurationLimit() async throws {
        let clipboard = RecordingClipboard()
        let toastPresenter = RecordingToastPresenter()
        let engine = ArtifactStreamingEngine()
        let transcriptionService = TranscriptionService(
            storageLocations: ModelStorageLocations(
                pindropApplicationSupportRoot: FileManager.default.temporaryDirectory
                    .appendingPathComponent("artifact-limit-\(UUID().uuidString)/Pindrop", isDirectory: true),
                fluidAudioModelsRoot: FileManager.default.temporaryDirectory
                    .appendingPathComponent("artifact-limit-\(UUID().uuidString)/FluidAudio/Models", isDirectory: true)
            ),
            streamingEngineFactory: { _, _ in engine },
            streamingChunkProfileProvider: { .standard },
            streamingBackendProvider: { .parakeet }
        )
        let (store, _) = try makeCaptureStore()
        let handle = try startNoteCapture(in: store, includeSystemAudio: true)
        let assignment = try liveAssignment()
        let audioRecorder = try AudioRecorder(
            permissionManager: MockPermissionProvider(),
            captureBackend: MockAudioCaptureBackend(identifier: "microphone"),
            systemAudioCaptureBackend: MockAudioCaptureBackend(identifier: "system")
        )
        let controller = try makeController(
            clipboard: clipboard,
            toastPresenter: toastPresenter,
            transcriptionService: transcriptionService,
            captureSessionStore: store,
            audioRecorder: audioRecorder,
            artifactLiveTranscriptionLimit: 0.05
        )

        #expect(await controller.beginArtifactCapture(for: handle, assignment: assignment))
        #expect(audioRecorder.onLivePacket != nil)
        #expect(!controller.isArtifactLiveTranscriptionStopped)

        try await Task.sleep(for: .milliseconds(300))

        // The live transcript stops growing; the capture itself stays active so the
        // durable spool keeps running and the ordinary finish path still applies.
        #expect(controller.isArtifactLiveTranscriptionStopped)
        #expect(audioRecorder.onLivePacket == nil)
        #expect(controller.isArtifactCaptureActive)

        await controller.finishArtifactCapture(for: handle)
        #expect(!controller.isArtifactCaptureActive)
        #expect(!controller.isArtifactLiveTranscriptionStopped)
        #expect(engine.stopCallCount == 1)
    }

    @Test func artifactCaptureKeepsLiveTranscriptionInsideTheDurationLimit() async throws {
        let clipboard = RecordingClipboard()
        let toastPresenter = RecordingToastPresenter()
        let engine = ArtifactStreamingEngine()
        let transcriptionService = TranscriptionService(
            storageLocations: ModelStorageLocations(
                pindropApplicationSupportRoot: FileManager.default.temporaryDirectory
                    .appendingPathComponent("artifact-within-limit-\(UUID().uuidString)/Pindrop", isDirectory: true),
                fluidAudioModelsRoot: FileManager.default.temporaryDirectory
                    .appendingPathComponent("artifact-within-limit-\(UUID().uuidString)/FluidAudio/Models", isDirectory: true)
            ),
            streamingEngineFactory: { _, _ in engine },
            streamingChunkProfileProvider: { .standard },
            streamingBackendProvider: { .parakeet }
        )
        let (store, _) = try makeCaptureStore()
        let handle = try startNoteCapture(in: store)
        let assignment = try liveAssignment()
        let audioRecorder = try AudioRecorder(
            permissionManager: MockPermissionProvider(),
            captureBackend: MockAudioCaptureBackend(identifier: "microphone"),
            systemAudioCaptureBackend: MockAudioCaptureBackend(identifier: "system")
        )
        let controller = try makeController(
            clipboard: clipboard,
            toastPresenter: toastPresenter,
            transcriptionService: transcriptionService,
            captureSessionStore: store,
            audioRecorder: audioRecorder,
            artifactLiveTranscriptionLimit: 600
        )

        #expect(await controller.beginArtifactCapture(for: handle, assignment: assignment))
        try await Task.sleep(for: .milliseconds(300))

        #expect(!controller.isArtifactLiveTranscriptionStopped)
        #expect(audioRecorder.onLivePacket != nil)

        await controller.finishArtifactCapture(for: handle)
        #expect(!controller.isArtifactCaptureActive)
    }


    @Test(arguments: [false, true])
    func parakeetFinalizeOmitsVocabularyAndRecordsEnhancementMetrics(
        voiceIsolationEnabled: Bool
    ) async throws {
        final class FinalizingStreamingEngine: PindropSpeech.StreamingTranscriptionEngine, @unchecked Sendable {
            private(set) var state: StreamingTranscriptionState = .unloaded
            private var finalUtteranceCallback: EndOfUtteranceCallback?

            func loadModel(name: String) async throws {
                state = .ready
            }

            func unloadModel() async {
                state = .unloaded
            }

            func startStreaming() async throws {
                state = .streaming
            }

            func stopStreaming() async throws -> String {
                state = .ready
                return "hello world"
            }

            func pauseStreaming() async {
                state = .paused
            }

            func resumeStreaming() async throws {
                state = .streaming
            }

            func processAudioChunk(_ samples: [Float]) async throws {}
            func processAudioBuffer(_ buffer: AVAudioPCMBuffer) async throws {}
            func setTranscriptionCallback(_ callback: @escaping StreamingTranscriptionCallback) async {}

            func setEndOfUtteranceCallback(_ callback: @escaping EndOfUtteranceCallback) async {
                finalUtteranceCallback = callback
            }

            func reset() async {
                state = .ready
            }

            func emitFinalUtterance(_ text: String, fedSeconds: TimeInterval = 0) {
                finalUtteranceCallback?(
                    StreamingTranscriptionEmission(text: text, fedSeconds: fedSeconds)
                )
            }
        }

        final class RecordingBatchEngine: TranscriptionEngine, @unchecked Sendable {
            private(set) var state: TranscriptionEngineState = .unloaded
            private(set) var receivedOptions: TranscriptionOptions?

            func loadModel(path: String) async throws {
                state = .ready
            }

            func loadModel(name: String, downloadBase: URL?) async throws {
                state = .ready
            }

            func transcribe(
                audioData: Data,
                options: TranscriptionOptions
            ) async throws -> String {
                receivedOptions = options
                return "batch transcript"
            }

            func unloadModel() async {
                state = .unloaded
            }
        }

        let clipboard = RecordingClipboard()
        let toastPresenter = RecordingToastPresenter()
        let engine = FinalizingStreamingEngine()
        let batchEngine = RecordingBatchEngine()
        let transcriptionService = TranscriptionService(
            storageLocations: ModelStorageLocations(
                pindropApplicationSupportRoot: FileManager.default.temporaryDirectory
                    .appendingPathComponent("pindrop-streaming-finalize-\(UUID().uuidString)/Pindrop", isDirectory: true),
                fluidAudioModelsRoot: FileManager.default.temporaryDirectory
                    .appendingPathComponent("pindrop-streaming-finalize-\(UUID().uuidString)/FluidAudio/Models", isDirectory: true)
            ),
            engineFactory: { _ in batchEngine },
            streamingEngineFactory: { _, _ in engine },
            audioPreprocessor: PassthroughAudioPreprocessor()
        )
        try await transcriptionService.loadModel(
            modelName: "openai_whisper-tiny",
            provider: .whisperKit
        )
        let dictionaryStore = try makeDictionaryStore()
        try dictionaryStore.add(VocabularyWord(word: "Fenneko"))
        let controller = try makeController(
            clipboard: clipboard,
            toastPresenter: toastPresenter,
            transcriptionService: transcriptionService,
            dictionaryStore: dictionaryStore,
            voiceIsolationEnabled: voiceIsolationEnabled
        )
        var enhancementInput: String?
        var enhancementCallCount = 0
        var enhancementVocabulary: [String]?
        var insertedText: String?

        controller.configure { text, vocabularyWords in
            enhancementInput = text
            enhancementVocabulary = vocabularyWords
            enhancementCallCount += 1
            return StreamingSessionController.PostStopEnhanceOutcome(
                enhancedText: "Enhanced final text.",
                modelID: "mock-model",
                providerKind: "openai",
                usage: AIEnhancementService.EnhancementUsage(
                    promptTokens: 5,
                    completionTokens: 3,
                    reasoningTokens: 1,
                    totalTokens: 9
                ),
                requestSeconds: 0.01
            )
        }
        controller.setFinalInsertionOverrideForTesting { text in
            insertedText = text
            return .pasted(
                destinationAppName: "TextEdit",
                destinationAppBundleID: "com.apple.TextEdit"
            )
        }

        let session = try #require(await controller.begin())
        engine.emitFinalUtterance("hello world")
        await Task.yield()
        await Task.yield()

        let outcome = try await controller.finalize(
            recordedAudioData: Data(repeating: 0, count: MemoryLayout<Float>.size),
            recordingDuration: 0,
            session: session
        )
        let expectedAudioPreprocessingMode: AudioPreprocessingMode =
            voiceIsolationEnabled ? .voiceIsolation : .none

        #expect(enhancementCallCount == 1)
        #expect(enhancementInput == "batch transcript")
        #expect(enhancementVocabulary == [])
        #expect(batchEngine.receivedOptions?.vocabularyBiasWords == [])
        #expect(batchEngine.receivedOptions?.audioPreprocessingMode == expectedAudioPreprocessingMode)
        #expect(outcome.originalStreamedText == enhancementInput)
        #expect(outcome.finalText == "Enhanced final text.")
        #expect(outcome.enhancedWithModel == "mock-model")
        #expect(outcome.pipelineMetrics.enhancementModel == "mock-model")
        #expect(outcome.pipelineMetrics.enhancementProvider == "openai")
        #expect(outcome.pipelineMetrics.enhancementRequestSeconds == 0.01)
        #expect(outcome.pipelineMetrics.enhancementPromptTokens == 5)
        #expect(outcome.pipelineMetrics.enhancementCompletionTokens == 3)
        #expect(outcome.pipelineMetrics.enhancementReasoningTokens == 1)
        #expect(outcome.pipelineMetrics.enhancementTotalTokens == 9)
        #expect(outcome.pipelineMetrics.enhancementSeconds != nil)
        #expect(insertedText == "Enhanced final text.")
    }

    // MARK: - Live speaker labels

    /// The settings row is the switch: off means the engine is never asked for,
    /// so nothing loads and every label stays at its channel.
    @Test func liveSpeakerLabelsStayOffWhileTheSettingIsOff() {
        #expect(
            !StreamingSessionController.allowsLiveSpeakerLabels(
                isEnabledInSettings: false,
                liveSources: [.microphone, .systemAudio]
            )
        )
    }

    /// A microphone-only capture pays nothing for a feature it cannot use: that
    /// channel is already "You" at the highest confidence there is.
    @Test func liveSpeakerLabelsStayOffWithoutSystemAudio() {
        #expect(
            !StreamingSessionController.allowsLiveSpeakerLabels(
                isEnabledInSettings: true,
                liveSources: [.microphone]
            )
        )
    }

    @Test func liveSpeakerLabelsRunOnAnEnabledCallCapture() {
        #expect(
            StreamingSessionController.allowsLiveSpeakerLabels(
                isEnabledInSettings: true,
                liveSources: [.microphone, .systemAudio]
            )
        )
    }

private struct PassthroughAudioPreprocessor: AudioPreprocessing {
    func process(audioData: Data, mode: AudioPreprocessingMode) async throws -> Data {
        audioData
    }
}

}
