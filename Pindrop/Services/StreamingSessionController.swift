//
//  StreamingSessionController.swift
//  Pindrop
//
//  Created on 2026-07-06.
//
//  Owns the live-transcription session lifecycle that previously sprawled through
//  AppCoordinator: engine callbacks, the serialized audio-buffer forwarding queue,
//  the StreamingRefinementCoordinator + overlay-sink pair, and the post-stop
//  finalize pipeline (drain → dictionary replacements → offline re-transcription →
//  optional LLM enhancement → single atomic paste, each stage bounded by a
//  timeout). AppCoordinator keeps what is genuinely app-level: the availability
//  gate for the session, recording UI transitions, no-speech messaging, and
//  history persistence.
//

import Foundation
import AVFoundation
import PindropCore
import PindropAI
import PindropData
import PindropSpeech

@MainActor
final class StreamingSessionController: StreamingRefinementCommitObserver {

    // MARK: - Outcome

    /// What the finalize pipeline produced, for the coordinator to persist/report.
    struct FinalizeOutcome {
        /// Final text after replacements/refinement/enhancement. Empty when the
        /// session produced no effective speech (the overlay was collapsed without
        /// pasting; the coordinator surfaces the no-speech message).
        let finalText: String
        /// The pre-enhancement text when the LLM pass rewrote it, nil otherwise.
        let originalStreamedText: String?
        /// Model ID of the post-stop enhancement when applied.
        let enhancedWithModel: String?
        /// Dictionary replacements applied to the text that was pasted.
        let appliedReplacements: [(original: String, replacement: String)]
        let outputSucceeded: Bool
        /// Frontmost app at insert/copy time (from OutputManager).
        let destinationAppName: String?
        let destinationAppBundleID: String?
        /// True when the paste keystroke landed (not clipboard-only fallback).
        let didPaste: Bool
        /// Stage latencies + enhancement usage collected during finalize. The
        /// coordinator adds the stages it owns (audio stop, total) before persisting.
        var pipelineMetrics: PipelineMetrics = PipelineMetrics(kind: .streaming)

        var isEffectivelyEmpty: Bool { finalText.isEmpty }
    }

    /// Result of the coordinator's post-stop LLM pass, including the observability
    /// data recorded on the transcription's pipeline metrics.
    struct PostStopEnhanceOutcome {
        let enhancedText: String
        let modelID: String
        let providerKind: String?
        let usage: AIEnhancementService.EnhancementUsage?
        let requestSeconds: Double?
    }

    // MARK: - Timeouts

    /// Bounds for the offline finalize re-transcription. The bound scales with the
    /// recording length — batch decode is usually much faster than realtime, but on
    /// slow hardware a long dictation can legitimately approach realtime, and a
    /// flat cap would discard a *succeeding* high-quality pass. The floor keeps
    /// short sessions snappy; the ceiling keeps a wedged engine from pinning the
    /// overlay in "Enhancing…" forever.
    static let offlineRetranscriptionTimeoutFloor: TimeInterval = 30
    static let offlineRetranscriptionTimeoutCeiling: TimeInterval = 120

    static func offlineRetranscriptionTimeout(recordingDuration: TimeInterval) -> TimeInterval {
        min(offlineRetranscriptionTimeoutCeiling,
            max(offlineRetranscriptionTimeoutFloor, recordingDuration * 1.5))
    }

    /// Upper bound on the post-stop LLM enhancement call (network + inference).
    static let postStopEnhanceTimeoutNanoseconds: UInt64 = 20_000_000_000
    /// How long live transcription may run alongside a durable capture. The spool is
    /// the product; the live transcript is a convenience. Past this bound the
    /// controller stops feeding the streaming engine rather than let an all-day
    /// capture keep a decoder resident behind the durable writer. Generous by
    /// design: ordinary meetings never reach it.
    static let defaultArtifactLiveTranscriptionLimit: TimeInterval = 2 * 60 * 60
    /// Keep the live path close to real time under a slow decoder. On overflow,
    /// discard the oldest pending buffers and retain the newest 32 (~8 seconds at
    /// a 4,096-frame 16 kHz tap), while the file-backed recorder still retains the
    /// complete waveform for offline finalization.
    nonisolated static let maximumBufferedAudioBuffers = 32

    private struct FinalizeStepTimedOut: Error {}

    // MARK: - Dependencies

    private let transcriptionService: TranscriptionService
    private let settingsStore: SettingsStore
    private let dictionaryStore: DictionaryStore
    private let outputManager: OutputManager
    private let toastService: ToastService
    private let liveTranscriptState: LiveTranscriptState
    private let audioRecorder: AudioRecorder
    private let captureSessionStore: CaptureSessionStore

    private let normalizeText: (String) -> String
    private let isEffectivelyEmptyText: (String) -> Bool
    private let artifactLiveTranscriptionLimit: TimeInterval

    /// The coordinator's post-stop LLM pass (it needs prompt presets and the
    /// enhancement service, which stay app-level). Wired via `configure` after
    /// AppCoordinator finishes initializing; nil means "no enhancement".
    private var postStopEnhance: (@MainActor (String, [String]) async -> PostStopEnhanceOutcome?)?

    // MARK: - Session state

    struct SessionToken: Sendable, Equatable {
        let rawValue: UInt64
    }

    private var nextSessionToken: UInt64 = 0
    private var activeSessionToken: SessionToken?
    var isSessionActive: Bool { activeSessionToken != nil }
    private(set) var isArtifactCaptureActive = false

    /// A session may be generic dictation or a voice-note artifact capture. Callers
    /// that must tear down the audio pump use this unified predicate so neither mode
    /// can leave direct engine work running behind a recorder failure.
    var hasActiveStreamingSession: Bool {
        activeSessionToken != nil || isArtifactCaptureActive
    }

    private var artifactCaptureHandle: NoteCaptureHandle?
    /// Retains the artifact display sink: the coordinator holds its sink weakly.
    private var artifactDisplaySink: ArtifactDisplaySink?
    private var artifactAssignment: CaptureStageAssignment?
    private var artifactPersistenceDisabled = false
    private var artifactFailureRecorded = false
    /// True once a durable capture ran past `artifactLiveTranscriptionLimit` and the
    /// controller stopped feeding the streaming engine. The durable spool keeps
    /// running; only the live transcript stops growing. UI reads this to explain why.
    private(set) var isArtifactLiveTranscriptionStopped = false
    private var artifactLiveTranscriptionLimitTask: Task<Void, Never>?

    /// Observer for the cumulative committed text of an artifact capture. This
    /// is how the note UI sees what the live engine has decided so far, and it
    /// reports exactly what the durable checkpoints record.
    var onArtifactLiveTextChanged: ((String) -> Void)?

    /// Observer for the tail the engine has not settled on yet. The note page
    /// draws it in a quieter ink, so a person can tell a guess from a decision.
    /// Nothing else consumes it: artifact capture still inserts no text anywhere.
    var onArtifactTentativeTextChanged: ((String) -> Void)?

    /// True when live transcription for the active artifact capture stopped
    /// growing: the duration bound elapsed, or checkpoint persistence failed.
    /// The durable spool is unaffected; only the live text is incomplete.
    var isArtifactLiveTranscriptDegraded: Bool {
        isArtifactLiveTranscriptionStopped || artifactPersistenceDisabled
    }

    /// Direct engine handle for the audio pump. Captured once per session so the
    /// per-buffer path never hops through the @MainActor TranscriptionService.
    private var pumpEngine: (any PindropSpeech.StreamingTranscriptionEngine)?
    private var audioStreamContinuation: AsyncStream<LiveAudioPacket>.Continuation?
    private var audioConsumerTask: Task<Void, Never>?
    /// Published to the pump's consumer whenever the engine reaches a commit
    /// boundary, which is where a pending channel handover may be applied.
    private var engineBoundarySignal: LiveEngineBoundarySignal?
    /// Retains asynchronous cancellation until its direct engine consumer exits.
    /// A subsequent begin waits here before it can prepare a new engine session.
    private var teardownTask: Task<Void, Never>?
    private var teardownGeneration = 0
    private var refinementCoordinator: StreamingRefinementCoordinator?
    /// Strongly retained here — `StreamingRefinementCoordinator` holds its sink weakly.
    private var overlaySink: OverlayStreamingSink?
    /// Test-only override for the final paste step so races with cancellation can be exercised
    /// without depending on Accessibility/KeySimulation hardware paths.
    private var finalInsertionOverrideForTesting: ((String) async throws -> OutputManager.OutputResult)?
    /// Test-only signal emitted immediately before a successor begins awaiting the
    /// detached teardown tail.
    private var beginTeardownWaitObserverForTesting: (() -> Void)?

    init(
        transcriptionService: TranscriptionService,
        settingsStore: SettingsStore,
        dictionaryStore: DictionaryStore,
        outputManager: OutputManager,
        toastService: ToastService,
        liveTranscriptState: LiveTranscriptState,
        audioRecorder: AudioRecorder,
        captureSessionStore: CaptureSessionStore,

        normalizeText: @escaping (String) -> String,
        isEffectivelyEmptyText: @escaping (String) -> Bool,
        artifactLiveTranscriptionLimit: TimeInterval = StreamingSessionController
            .defaultArtifactLiveTranscriptionLimit
    ) {
        self.artifactLiveTranscriptionLimit = artifactLiveTranscriptionLimit
        self.transcriptionService = transcriptionService
        self.settingsStore = settingsStore
        self.dictionaryStore = dictionaryStore
        self.outputManager = outputManager
        self.toastService = toastService
        self.liveTranscriptState = liveTranscriptState
        self.audioRecorder = audioRecorder
        self.captureSessionStore = captureSessionStore

        self.normalizeText = normalizeText
        self.isEffectivelyEmptyText = isEffectivelyEmptyText
    }

    func configure(
        postStopEnhance: @escaping @MainActor (String, [String]) async -> PostStopEnhanceOutcome?
    ) {
        self.postStopEnhance = postStopEnhance
    }

    // MARK: - Lifecycle

    /// Starts one generic dictation lifecycle. The owner token is assigned before
    /// service start so a late start can never consume fallback state for a successor.
    func begin() async -> SessionToken? {
        guard !hasActiveStreamingSession else { return nil }
        let session = SessionToken(rawValue: nextSessionToken)
        nextSessionToken &+= 1
        activeSessionToken = session
        if teardownTask != nil {
            beginTeardownWaitObserverForTesting?()
        }
        await awaitPriorTeardown()
        guard owns(session) else { return nil }
        do {
            setEngineCallbacks(for: session)
            try await transcriptionService.startStreaming()
            guard owns(session) else { return nil }
            let usedAppleBackendFallback = transcriptionService.consumeAppleBackendFallbackFlag()
            if usedAppleBackendFallback {
                toastService.show(
                    ToastPayload(
                        message: localized(
                            "Apple SpeechTranscriber unavailable — using Nemotron",
                            locale: .autoupdatingCurrent
                        ),
                        style: .standard
                    )
                )
            }

            let coord = StreamingRefinementCoordinator()
            coord.beginSession(outputSink: ensureOverlaySink())
            refinementCoordinator = coord
            pumpEngine = transcriptionService.activeStreamingEngine
            attachAudioForwarding()
            Log.transcription.info("Streaming transcription enabled for current session")
            return session
        } catch {
            guard owns(session) else { return nil }
            Log.transcription.error("Streaming transcription unavailable, falling back to batch: \(error)")
            await cancel(session: session)
            return nil
        }
    }

    /// Begins a note-capture-only live session that writes stable cumulative text to
    /// capture artifacts. Unlike generic dictation, this has no display or output
    /// sink. A system-audio capture previews that source live, while durable capture
    /// keeps microphone and system audio separate for final transcription.
    @discardableResult
    func beginArtifactCapture(
        for handle: NoteCaptureHandle,
        assignment: CaptureStageAssignment
    ) async -> Bool {
        await awaitPriorTeardown()
        guard
            !hasActiveStreamingSession,
            assignment.stage == .liveTranscription,
            assignment.providerKind == .streamingSpeech,
            assignment.modelIdentifier != nil
        else {
            return false
        }

        isArtifactCaptureActive = true
        artifactCaptureHandle = handle
        artifactAssignment = assignment
        artifactPersistenceDisabled = false
        artifactFailureRecorded = false
        isArtifactLiveTranscriptionStopped = false
        setEngineCallbacks()

        do {
            try await transcriptionService.startStreaming()
            guard isArtifactCaptureCurrent(handle) else {
                return false
            }
            // Artifact workflows are intentionally silent. Consume the per-start
            // fallback state only while this exact capture still owns it, so a stale
            // artifact attempt cannot consume or leak fallback state for a later
            // generic dictation session.
            _ = transcriptionService.consumeAppleBackendFallbackFlag()
            guard
                let expectedIdentity = artifactStreamingEngineIdentity(for: assignment),
                transcriptionService.activeStreamingEngineIdentity == expectedIdentity
            else {
                recordArtifactFailure(
                    code: "streaming-engine-identity-mismatch",
                    message: "The prepared live transcription engine did not match the capture assignment."
                )
                await cancelArtifactCapture(for: handle)
                return false
            }

            let coordinator = StreamingRefinementCoordinator()
            // The sink exists only to carry the unsettled tail to the note page.
            // Committed text still arrives through the commit observer, which is
            // the path the durable checkpoints follow.
            let displaySink = ArtifactDisplaySink { [weak self] tentative in
                self?.onArtifactTentativeTextChanged?(tentative)
            }
            artifactDisplaySink = displaySink
            coordinator.beginSession(
                outputSink: displaySink,
                commitObserver: self,
                preservesArtifactParagraphs: true
            )
            refinementCoordinator = coordinator
            pumpEngine = transcriptionService.activeStreamingEngine
            attachAudioForwarding()
            scheduleArtifactLiveTranscriptionLimit(for: handle)
            Log.transcription.info("Artifact live transcription enabled for current note capture")
            return true
        } catch {
            guard isArtifactCaptureCurrent(handle) else {
                return false
            }
            // Apple can set its fallback flag before throwing. Consume it only after
            // confirming that this artifact lifecycle still owns the service state.
            _ = transcriptionService.consumeAppleBackendFallbackFlag()
            recordArtifactFailure(
                code: "streaming-engine-unavailable",
                message: "The assigned live transcription engine could not be started."
            )
            Log.transcription.warning("Artifact live transcription unavailable: \(error.localizedDescription)")
            await cancelArtifactCapture(for: handle)
            return false
        }
    }

    /// Drains the live audio pump and commits the engine's final cumulative text.
    /// Artifact capture intentionally never invokes the dictation finalize pipeline.
    func finishArtifactCapture(for handle: NoteCaptureHandle) async {
        await awaitPriorTeardown()
        guard isArtifactCaptureCurrent(handle) else { return }

        await flushPendingAudioWork()
        guard isArtifactCaptureCurrent(handle) else { return }

        transcriptionService.setStreamingCallbacks(onPartial: nil, onFinalUtterance: nil)
        let coordinator = refinementCoordinator

        do {
            let finalText = try await transcriptionService.stopStreaming()
            guard isArtifactCaptureCurrent(handle) else { return }
            if !finalText.isEmpty {
                await coordinator?.ingestFinal(finalText)
                guard isArtifactCaptureCurrent(handle) else { return }
            }
            _ = await coordinator?.awaitFinalTextAndDrain()
            guard isArtifactCaptureCurrent(handle) else { return }
        } catch {
            guard isArtifactCaptureCurrent(handle) else { return }
            recordArtifactFailure(
                code: "streaming-engine-stop-failed",
                message: "The assigned live transcription engine could not be stopped cleanly."
            )
            Log.transcription.warning("Artifact live transcription stop failed: \(error.localizedDescription)")
            cancelArtifactCaptureDetached(for: handle)
            await awaitPriorTeardown()
            return
        }

        // No suspension follows this ownership check, so teardown cannot be redirected
        // to a successor that began while this operation was suspended above.
        guard isArtifactCaptureCurrent(handle) else { return }
        coordinator?.endSession()
        refinementCoordinator = nil
        detachEngineCallbacks()
        clearArtifactCaptureState()
    }

    /// Cancels only the artifact capture that owns `handle`; a stale note-capture
    /// operation must never tear down a newer capture's streaming engine.
    func cancelArtifactCapture(for handle: NoteCaptureHandle) async {
        await awaitPriorTeardown()
        cancelArtifactCaptureDetached(for: handle)
        await awaitPriorTeardown()
    }

    /// Synchronously aborts only the artifact capture that owns `handle`.
    func cancelArtifactCaptureDetached(for handle: NoteCaptureHandle) {
        guard isArtifactCaptureCurrent(handle) else { return }
        cancelDetached()
    }

    /// Drops inactive generic callback state without disturbing a live owner.
    func deactivate() {
        guard !hasActiveStreamingSession else { return }
        detachEngineCallbacks()
    }

    func cancel(session: SessionToken) async {
        cancelDetached(session: session)
        await awaitPriorTeardown()
    }

    func cancelDetached(session: SessionToken) {
        guard owns(session) else { return }
        cancelDetached()
    }

    /// Synchronous abort for artifact and generic cancellation paths.
    func cancelDetached() {
        let priorTeardownTask = teardownTask
        let hadArtifactCapture = isArtifactCaptureActive
        let coordinator = refinementCoordinator
        refinementCoordinator = nil
        let consumerTask = detachAudioForwarding(cancelPendingWork: true)
        activeSessionToken = nil
        if hadArtifactCapture {
            clearArtifactCaptureState()
        }

        teardownGeneration &+= 1
        let generation = teardownGeneration
        let transcriptionService = transcriptionService
        let overlaySink = overlaySink
        teardownTask = Task { @MainActor in
            await priorTeardownTask?.value
            await consumerTask?.value
            await transcriptionService.cancelStreaming()
            if let coordinator {
                await coordinator.cancelSession()
            } else if !hadArtifactCapture {
                await overlaySink?.cancelStreamingInsertion()
            }
            Log.transcription.debug("Streaming teardown barrier completed (generation=\(generation))")
        }
    }
    /// Drains and stops the engine, then runs the finalize pipeline: dictionary
    /// replacements → offline re-transcription (timeout-bounded, scaled to the
    /// recording length) → optional post-stop LLM enhancement (timeout-bounded) →
    /// single atomic paste via the overlay sink.
    /// Throws when the engine fails to stop (after cancelling the session).
    func finalize(
        recordedAudioData: Data,
        recordingDuration: TimeInterval,
        session: SessionToken
    ) async throws -> FinalizeOutcome {
        try requireExactOwner(session)
        // Keep the coordinator that belongs to this session. A later begin can install
        // a successor while any await below is suspended; this finalize must never end it.
        let coordinator = refinementCoordinator
        let pipelineClock = ContinuousClock()
        var pipelineMetrics = PipelineMetrics(kind: .streaming)

        await flushPendingAudioWork()
        try requireExactOwner(session)
        transcriptionService.setStreamingCallbacks(onPartial: nil, onFinalUtterance: nil)

        let finalStreamedText: String
        do {
            finalStreamedText = try await transcriptionService.stopStreaming()
            try requireExactOwner(session)
            Log.transcription.info("Streaming transcription finalized")
        } catch {
            await cancel(session: session)
            if Self.isCancellationError(error) {
                throw CancellationError()
            }
            Log.transcription.error("Failed to stop streaming transcription: \(error)")
            throw error
        }

        // Live/refinement text first. Empty live transcripts short-circuit before the
        // offline re-transcription pass (and its Enhancing affordance), matching the
        // pre-dictionary-semantics finalize ordering.
        var candidateRawText = finalStreamedText
        if let coordinator {
            // Coordinator text is what is currently displayed; use it as the stream
            // fallback when offline re-transcription is unavailable.
            candidateRawText = await coordinator.awaitFinalTextAndDrain()
            try requireExactOwner(session)
        }

        // Preview apply without usage tracking so a later offline winner does not
        // double-count, and empty sessions do not pay for offline re-transcription.
        var (textAfterReplacements, appliedReplacements) =
            try dictionaryStore.applyReplacements(to: candidateRawText, trackUsage: false)
        textAfterReplacements = normalizeText(textAfterReplacements)
        if !appliedReplacements.isEmpty {
            Log.app.info("Applied \(appliedReplacements.count) dictionary replacements")
        }

        guard !isEffectivelyEmptyText(textAfterReplacements) else {
            // `finishStreamingInsertion` returns synchronously for empty text. Check
            // immediately before and after it so an old empty finalize cannot collapse
            // a successor's overlay or controller state.
            try requireExactOwner(session)
            try? await overlaySink?.finishStreamingInsertion(
                finalText: "",
                appendTrailingSpace: false
            )
            try requireExactOwner(session)
            coordinator?.endSession()
            refinementCoordinator = nil
            activeSessionToken = nil
            return FinalizeOutcome(
                finalText: "",
                originalStreamedText: nil,
                enhancedWithModel: nil,
                appliedReplacements: appliedReplacements,
                outputSucceeded: false,
                destinationAppName: nil,
                destinationAppBundleID: nil,
                didPaste: false
            )
        }

        // Offline finalize pass: re-transcribe the recorded audio with the batch model.
        // Streaming RNNT decoding is append-only — punctuation the model doesn't emit
        // in the moment can never be inserted retroactively, so pause-dependent
        // punctuation is unreliable live. The batch model decodes the whole waveform
        // (pauses included) with full bidirectional context and places punctuation
        // correctly. The streamed text remains the live overlay preview and the
        // fallback whenever the offline pass fails, stalls, or comes back empty.
        // Parakeet/Nemotron does not support vocabulary biasing. Forwarding the
        // dictionary into the fallback Whisper prompt or post-stop enhancer can
        // hallucinate unrelated vocabulary terms into otherwise valid speech.
        let vocabularyWords: [String]
        if settingsStore.resolvedTranscriptionBackend == .parakeet {
            vocabularyWords = []
        } else {
            vocabularyWords =
                (try? dictionaryStore.fetchAllVocabularyWords().map(\.word)) ?? []
        }

        if !recordedAudioData.isEmpty {
            try requireExactOwner(session)
            liveTranscriptState.beginEnhancing()
            do {
                let language = settingsStore.selectedAppLanguage
                let timeout = Self.offlineRetranscriptionTimeout(recordingDuration: recordingDuration)
                let transcriptionStart = pipelineClock.now
                let refinedText = try await Self.withFinalizeTimeout(
                    nanoseconds: UInt64(timeout * 1_000_000_000)
                ) { [transcriptionService, settingsStore] in
                    try await transcriptionService.transcribe(
                        audioData: recordedAudioData,
                        diarizationEnabled: false,
                        options: TranscriptionOptions(
                            language: language,
                            vocabularyBiasWords: vocabularyWords,
                            audioPreprocessingMode: AppCoordinator.audioPreprocessingMode(
                                for: .dictation,
                                voiceIsolationEnabled: settingsStore.voiceIsolationEnabled
                            )
                        )
                    ).text
                }
                try requireExactOwner(session)
                pipelineMetrics.transcriptionSeconds = transcriptionStart.duration(to: pipelineClock.now).pipelineSeconds
                let normalizedRefined = normalizeText(refinedText)
                if !isEffectivelyEmptyText(normalizedRefined) {
                    candidateRawText = refinedText
                    Log.transcription.info(
                        "Streaming finalize: offline re-transcription applied (\(normalizedRefined.count) chars)"
                    )
                } else {
                    Log.transcription.info(
                        "Streaming finalize: offline re-transcription was empty; keeping streamed text"
                    )
                }
            } catch is FinalizeStepTimedOut {
                try requireExactOwner(session)
                // The detached batch operation may ignore cancellation. Drop its
                // engine generation before fallback so it cannot leave the shared
                // service stuck in `.transcribing` or mutate a later session.
                transcriptionService.invalidateTimedOutTranscription()
                Log.transcription.warning(
                    "Streaming finalize: offline re-transcription timed out, keeping streamed text"
                )
            } catch {
                if Self.isCancellationError(error) {
                    throw CancellationError()
                }
                try requireExactOwner(session)
                Log.transcription.warning(
                    "Streaming finalize: offline re-transcription failed, keeping streamed text: \(error.localizedDescription)"
                )
            }
        }

        // Authoritative apply on the winning raw text: single usage-count batch.
        try requireExactOwner(session)
        (textAfterReplacements, appliedReplacements) =
            try dictionaryStore.applyReplacements(to: candidateRawText, trackUsage: true)
        textAfterReplacements = normalizeText(textAfterReplacements)
        if !appliedReplacements.isEmpty {
            Log.app.info("Applied \(appliedReplacements.count) dictionary replacements")
        }
        try dictionaryStore.recordVocabularyHits(in: textAfterReplacements)

        // A configured transcription-enhancement assignment owns the post-stop LLM pass.
        // Streaming text is only the live preview and fallback; the authoritative offline
        // transcription still receives the same enhancement as the batch pipeline.
        var originalStreamedText: String? = nil
        var enhancedWithModel: String? = nil
        if let postStopEnhance {
            try requireExactOwner(session)
            // Surface the enhancement wait in the overlay: the transcript stays visible
            // with an "Enhancing…" affordance until the rewritten text is pasted.
            liveTranscriptState.beginEnhancing()
            let textForEnhance = textAfterReplacements
            var enhanceOutcome: PostStopEnhanceOutcome?
            let enhancementStart = pipelineClock.now
            do {
                enhanceOutcome = try await Self.withFinalizeTimeout(
                    nanoseconds: Self.postStopEnhanceTimeoutNanoseconds
                ) {
                    await postStopEnhance(textForEnhance, vocabularyWords)
                }
                try requireExactOwner(session)
            } catch {
                if Self.isCancellationError(error) {
                    throw CancellationError()
                }
                try requireExactOwner(session)
                Log.aiEnhancement.warning(
                    "Streaming post-stop enhancement timed out; keeping deterministic text"
                )
                enhanceOutcome = nil
            }
            if let result = enhanceOutcome {
                originalStreamedText = textAfterReplacements
                textAfterReplacements = result.enhancedText
                enhancedWithModel = result.modelID
                pipelineMetrics.enhancementSeconds = enhancementStart.duration(to: pipelineClock.now).pipelineSeconds
                pipelineMetrics.enhancementRequestSeconds = result.requestSeconds
                pipelineMetrics.enhancementProvider = result.providerKind
                pipelineMetrics.enhancementModel = result.modelID
                if let usage = result.usage {
                    pipelineMetrics.enhancementPromptTokens = usage.promptTokens
                    pipelineMetrics.enhancementCompletionTokens = usage.completionTokens
                    pipelineMetrics.enhancementReasoningTokens = usage.reasoningTokens
                    pipelineMetrics.enhancementTotalTokens = usage.totalTokens
                }
                Log.transcription.info(
                    "Streaming post-stop enhancement applied: \(originalStreamedText?.count ?? 0) → \(result.enhancedText.count) chars (model=\(result.modelID))"
                )
            }
        }

        // Optional local paragraph formatting for long dictation. Runs once after any
        // enhancement and before paste/persist so history and clipboard share the result.
        textAfterReplacements = ProgrammaticTranscriptFormatter.formatIfEnabled(
            textAfterReplacements,
            enabled: settingsStore.programmaticFormattingEnabled
        )
        textAfterReplacements = normalizeText(textAfterReplacements)

        let outputStart = pipelineClock.now
        let insertion = try await performFinalStreamingInsertion(
            finalText: textAfterReplacements,
            session: session
        )
        pipelineMetrics.outputSeconds = outputStart.duration(to: pipelineClock.now).pipelineSeconds
        if insertion.outputSucceeded {
            Log.transcription.debug("Applied final streaming transcription output")
            // A committed output remains a valid historic outcome if cancellation or a
            // successor arrived during insertion. Only clean up when this exact token
            // still owns controller state.
            if owns(session) {
                coordinator?.endSession()
                refinementCoordinator = nil
                activeSessionToken = nil
            }
        } else {
            try requireExactOwner(session)
            coordinator?.endSession()
            refinementCoordinator = nil
            activeSessionToken = nil
        }

        return FinalizeOutcome(
            finalText: textAfterReplacements,
            originalStreamedText: originalStreamedText,
            enhancedWithModel: enhancedWithModel,
            appliedReplacements: appliedReplacements,
            outputSucceeded: insertion.outputSucceeded,
            destinationAppName: insertion.outputResult?.destinationAppName,
            destinationAppBundleID: insertion.outputResult?.destinationAppBundleID,
            didPaste: insertion.outputResult?.didPaste == true,
            pipelineMetrics: pipelineMetrics
        )
    }

    /// Installs a test-only final paste implementation used by `performFinalStreamingInsertion`.
    func setFinalInsertionOverrideForTesting(
        _ override: ((String) async throws -> OutputManager.OutputResult)?
    ) {
        finalInsertionOverrideForTesting = override
    }

    /// Installs a test-only signal for the point at which `begin()` waits for a
    /// detached teardown tail.
    func setBeginTeardownWaitObserverForTesting(_ observer: (() -> Void)?) {
        beginTeardownWaitObserverForTesting = observer
    }

    /// Test seam for cancel-safe final insertion. Calls the same production path.
    func finalizeInsertionForTesting(finalText: String) async throws -> FinalizeOutcome {
        let insertion = try await performFinalStreamingInsertion(finalText: finalText, session: nil)
        return FinalizeOutcome(
            finalText: finalText,
            originalStreamedText: nil,
            enhancedWithModel: nil,
            appliedReplacements: [],
            outputSucceeded: insertion.outputSucceeded,
            destinationAppName: insertion.outputResult?.destinationAppName,
            destinationAppBundleID: insertion.outputResult?.destinationAppBundleID,
            didPaste: insertion.outputResult?.didPaste == true
        )
    }

    private struct FinalStreamingInsertionResult {
        let outputSucceeded: Bool
        let outputResult: OutputManager.OutputResult?
    }

    /// Single production path for post-finalize paste/clipboard fallback.
    /// Production `finalize` and the test seam both call this exact method.
    private func performFinalStreamingInsertion(
        finalText: String,
        session: SessionToken?
    ) async throws -> FinalStreamingInsertionResult {
        if let session {
            try requireExactOwner(session)
        } else {
            try ensureNotCancelled()
        }
        do {
            // Single atomic insertion into the target app; the sink collapses the
            // overlay whether or not the paste succeeds.
            let outputResult: OutputManager.OutputResult
            if let override = finalInsertionOverrideForTesting {
                let text = settingsStore.addTrailingSpace ? finalText + " " : finalText
                outputResult = try await override(text)
            } else {
                let sink = ensureOverlaySink()
                let ownerValidation: @MainActor () throws -> Void
                if let session {
                    ownerValidation = { [weak self] in
                        guard let self else { throw CancellationError() }
                        try self.requireExactOwner(session)
                    }
                } else {
                    ownerValidation = { try Task.checkCancellation() }
                }
                guard let result = try await sink.finishStreamingInsertionReturningResult(
                    finalText: finalText,
                    appendTrailingSpace: settingsStore.addTrailingSpace,
                    ownerValidation: ownerValidation
                ) else {
                    return FinalStreamingInsertionResult(outputSucceeded: false, outputResult: nil)
                }
                outputResult = result
            }
            // No cancellation/ownership check here: the output landed in the target
            // app, so it remains a valid committed outcome for history persistence.
            return FinalStreamingInsertionResult(
                outputSucceeded: true,
                outputResult: outputResult
            )
        } catch {
            // Prefer current cancellation and ownership over the thrown error so a
            // stale failing insertion can never copy or toast for a successor.
            if let session {
                try requireExactOwner(session)
            } else {
                try ensureNotCancelled()
            }
            if Self.isCancellationError(error) {
                throw CancellationError()
            }
            Log.output.error("Final streaming insertion failed: \(error)")
            // The paste never landed — put the transcript on the clipboard so the
            // session's text is recoverable, and tell the user what happened.
            if let session {
                try requireExactOwner(session)
            } else {
                try ensureNotCancelled()
            }
            if (try? outputManager.copyToClipboard(finalText)) != nil {
                toastService.show(
                    ToastPayload(
                        message: localized(
                            "Paste failed. Transcript copied to clipboard.",
                            locale: settingsStore.selectedAppLocale.locale
                        ),
                        style: .error
                    )
                )
            }
            return FinalStreamingInsertionResult(outputSucceeded: false, outputResult: nil)
        }
    }

    // MARK: - Private — engine plumbing

    private func owns(_ session: SessionToken) -> Bool {
        activeSessionToken == session
    }
    /// Validates that an async continuation still belongs to the captured generic
    /// session before it can mutate controller, output, or fallback state.
    private func requireExactOwner(_ session: SessionToken) throws {
        try Task.checkCancellation()
        guard owns(session) else { throw CancellationError() }
    }

    private func setEngineCallbacks(for session: SessionToken? = nil) {
        transcriptionService.setStreamingCallbacks(
            onPartial: { [weak self] text in
                guard let self else { return }
                if let session, !self.owns(session) { return }
                await self.refinementCoordinator?.ingestPartial(text)
            },
            onFinalUtterance: { [weak self] text in
                guard let self else { return }
                if let session, !self.owns(session) { return }
                await self.refinementCoordinator?.ingestFinal(text)
                // An end-of-utterance final is one of the two boundaries the
                // engine produces on its own, so a pending handover may land on
                // it. The idle commit is the other one, reported through the
                // commit observer's trailing paragraph boundary.
                self.engineBoundarySignal?.signal()
            }
        )
    }

    // MARK: - Artifact commit observer

    func streamingRefinementCoordinator(
        _ coordinator: StreamingRefinementCoordinator,
        didCommitText committedText: String
    ) {
        guard refinementCoordinator === coordinator, isArtifactCaptureActive else { return }
        // A trailing newline means the engine closed a paragraph, which happens
        // only at an end-of-utterance final or an idle commit. Both are boundaries
        // the engine produced itself, so a pending handover may land on one.
        if committedText.hasSuffix("\n") {
            engineBoundarySignal?.signal()
        }
        // The observer sees every commit, including ones this controller can no
        // longer checkpoint: the words were still decoded, so the note UI shows
        // them and flags the transcript as degraded instead of losing them.
        if !committedText.isEmpty {
            onArtifactLiveTextChanged?(committedText)
        }
        guard
            !artifactPersistenceDisabled,
            !committedText.isEmpty,
            let handle = artifactCaptureHandle,
            let assignment = artifactAssignment,
            let expectedIdentity = artifactStreamingEngineIdentity(for: assignment)
        else {
            return
        }

        guard transcriptionService.activeStreamingEngineIdentity == expectedIdentity else {
            recordArtifactFailure(
                code: "streaming-engine-identity-mismatch",
                message: "The active live transcription engine no longer matched the capture assignment."
            )
            Task { @MainActor [weak self] in
                await self?.cancelArtifactCapture(for: handle)
            }
            return
        }

        do {
            // Live text remains one preview revision chain even when its audio comes
            // from the system source. Final transcription uses both durable streams.
            try captureSessionStore.checkpointVoiceNoteLiveTranscript(
                for: handle,
                committedText: committedText,
                assignmentAttempt: assignment.attempt
            )
        } catch {
            artifactPersistenceDisabled = true
            recordArtifactFailure(
                code: "live-transcript-checkpoint-failed",
                message: "Unable to persist the live transcript checkpoint."
            )
            Log.transcription.warning(
                "Artifact live transcript checkpoint failed: \(error.localizedDescription)"
            )
        }
    }

    private func artifactStreamingEngineIdentity(
        for assignment: CaptureStageAssignment
    ) -> StreamingEngineIdentity? {
        guard
            assignment.stage == .liveTranscription,
            assignment.providerKind == .streamingSpeech,
            let modelIdentifier = assignment.modelIdentifier
        else {
            return nil
        }
        return StreamingEngineIdentity(
            providerIdentifier: assignment.providerIdentifier,
            modelIdentifier: modelIdentifier
        )
    }

    private func recordArtifactFailure(code: String, message: String) {
        guard
            !artifactFailureRecorded,
            let handle = artifactCaptureHandle,
            let assignment = artifactAssignment
        else {
            return
        }
        artifactFailureRecorded = true
        do {
            try captureSessionStore.recordStageFailure(
                sessionID: handle.sessionID,
                stage: .liveTranscription,
                attempt: assignment.attempt,
                domain: "streaming-artifact",
                code: code,
                message: message,
                retryable: true
            )
        } catch {
            Log.transcription.warning(
                "Unable to record artifact live transcription failure: \(error.localizedDescription)"
            )
        }
    }

    private func isArtifactCaptureCurrent(_ handle: NoteCaptureHandle) -> Bool {
        isArtifactCaptureActive && artifactCaptureHandle == handle
    }

    private func clearArtifactCaptureState() {
        artifactLiveTranscriptionLimitTask?.cancel()
        artifactLiveTranscriptionLimitTask = nil
        isArtifactCaptureActive = false
        artifactCaptureHandle = nil
        artifactAssignment = nil
        artifactPersistenceDisabled = false
        artifactFailureRecorded = false
        isArtifactLiveTranscriptionStopped = false
        artifactDisplaySink = nil
        onArtifactTentativeTextChanged?("")
    }

    /// Arms the live-transcription duration bound for one durable capture.
    private func scheduleArtifactLiveTranscriptionLimit(for handle: NoteCaptureHandle) {
        artifactLiveTranscriptionLimitTask?.cancel()
        artifactLiveTranscriptionLimitTask = nil
        let limit = artifactLiveTranscriptionLimit
        guard limit > 0, limit.isFinite else { return }
        artifactLiveTranscriptionLimitTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(limit))
            guard !Task.isCancelled else { return }
            self?.stopArtifactLiveTranscription(for: handle, afterSeconds: limit)
        }
    }

    /// Stops feeding the streaming engine while the durable capture keeps spooling.
    /// Buffers stop at the recorder tap, so the writer behind `startMeetingRecording`
    /// is untouched; the engine still stops normally at `finishArtifactCapture`, so
    /// the text decoded before the bound is kept and checkpointed.
    private func stopArtifactLiveTranscription(
        for handle: NoteCaptureHandle,
        afterSeconds: TimeInterval
    ) {
        guard isArtifactCaptureCurrent(handle), !isArtifactLiveTranscriptionStopped else { return }
        isArtifactLiveTranscriptionStopped = true
        audioRecorder.onLivePacket = nil
        audioRecorder.onDiarizationBuffer = nil
        audioStreamContinuation?.finish()
        audioStreamContinuation = nil
        Log.transcription.warning(
            "Live transcription stopped after \(Int(afterSeconds))s; durable recording continues"
        )
    }

    /// Packets flow: capture thread → AsyncStream → one detached consumer → engine
    /// actor. No main-actor hops anywhere in the per-buffer path: with the orb
    /// rendering at 30fps, main-actor hops throttle to ~10/sec while audio arrives
    /// at ~50/sec, so live partials stall and burst out only at stop. Applying a
    /// handover or reporting dropped speech is one hop each, a few per minute.
    private func attachAudioForwarding() {
        guard let engine = pumpEngine else { return }

        let (stream, continuation) = AsyncStream.makeStream(
            of: LiveAudioPacket.self,
            bufferingPolicy: .bufferingNewest(Self.maximumBufferedAudioBuffers)
        )
        audioStreamContinuation = continuation
        let boundarySignal = LiveEngineBoundarySignal()
        engineBoundarySignal = boundarySignal
        let arbiter = audioRecorder.liveChannelArbiter
        let chunkSeconds = settingsStore.streamingChunkProfile.nemotronChunkSeconds
        let onHandoverApplied = handoverApplicationHandler()
        let onDroppedSpeech = droppedSpeechHandler()
        audioConsumerTask = Task.detached(priority: .userInitiated) {
            let pump = LiveAudioPump(
                engine: engine,
                arbiter: arbiter,
                boundarySignal: boundarySignal,
                chunkSeconds: chunkSeconds,
                onHandoverApplied: onHandoverApplied,
                onDroppedSpeech: onDroppedSpeech
            )
            for await packet in stream {
                if Task.isCancelled { break }
                await pump.ingest(packet)
            }
        }
        // The continuation is captured directly (it is Sendable); going through
        // self would re-enter the main actor from the capture thread.
        audioRecorder.onLivePacket = { packet in
            if case .dropped = continuation.yield(packet) {
                Log.transcription.warning("Streaming audio buffer backlog exceeded \(Self.maximumBufferedAudioBuffers); dropped oldest buffer")
            }
        }
    }

    /// What the pump does when a handover takes effect. Phase 1 only records the
    /// channel that owns the live text from here on.
    private func handoverApplicationHandler() -> @Sendable (CaptureSourceKind) -> Void {
        { source in
            Log.transcription.debug("Live transcript now follows \(source.rawValue)")
        }
    }

    /// What the pump does with speech the live engine never heard.
    private func droppedSpeechHandler() -> @Sendable (CaptureSourceKind, TimeInterval, TimeInterval) -> Void {
        { source, startCaptureTime, duration in
            Log.transcription.debug(
                "Live transcript missed \(String(format: "%.1f", duration))s of \(source.rawValue) at \(String(format: "%.1f", startCaptureTime))s"
            )
        }
    }

    private func flushPendingAudioWork() async {
        audioRecorder.onLivePacket = nil
        audioRecorder.onDiarizationBuffer = nil
        audioStreamContinuation?.finish()
        audioStreamContinuation = nil
        let consumerTask = audioConsumerTask
        audioConsumerTask = nil
        await consumerTask?.value
        pumpEngine = nil
        engineBoundarySignal = nil
    }

    /// Makes the recorder unable to enqueue another buffer before any asynchronous
    /// engine work starts to unwind. The returned task is deliberately retained by
    /// the caller until it is awaited ahead of an engine reset.
    private func detachAudioForwarding(cancelPendingWork: Bool) -> Task<Void, Never>? {
        audioRecorder.onLivePacket = nil
        audioRecorder.onDiarizationBuffer = nil
        detachEngineCallbacks()
        audioStreamContinuation?.finish()
        audioStreamContinuation = nil
        let consumerTask = audioConsumerTask
        audioConsumerTask = nil
        if cancelPendingWork {
            consumerTask?.cancel()
        }
        pumpEngine = nil
        engineBoundarySignal = nil
        return consumerTask
    }

    private func detachEngineCallbacks() {
        transcriptionService.setStreamingCallbacks(onPartial: nil, onFinalUtterance: nil)
    }

    private func awaitPriorTeardown() async {
        guard let teardownTask else { return }
        let generation = teardownGeneration
        await teardownTask.value
        if teardownGeneration == generation {
            self.teardownTask = nil
        }
    }

    /// Lazily builds the long-lived overlay sink; reused across sessions.
    private func ensureOverlaySink() -> OverlayStreamingSink {
        if let overlaySink {
            return overlaySink
        }
        let sink = OverlayStreamingSink(
            transcriptState: liveTranscriptState,
            finalOutput: { [outputManager] text, ownerValidation in
                try await outputManager.output(text, validatingOwnership: ownerValidation)
            },
            onClipboardFallback: { [weak self] result in
                self?.showClipboardFallbackToast(for: result)
            }
        )
        overlaySink = sink
        return sink
    }

    /// Copy fallbacks are not all failures: in copy-only mode or without Accessibility
    /// permission the copy IS the intended output (surface "Copied" with Undo), while
    /// a failed paste that fell back to the clipboard is an error worth flagging.
    private func showClipboardFallbackToast(for result: OutputManager.OutputResult) {
        let locale = settingsStore.selectedAppLocale.locale
        switch result.clipboardFallbackReason {
        case .copyOnlyMode, .accessibilityUnavailable:
            var actions: [ToastAction] = []
            if let snapshot = result.previousClipboardSnapshot {
                actions.append(
                    ToastAction(title: localized("Undo", locale: locale), role: .primary) { [weak self] in
                        let restored = self?.outputManager.restoreClipboardSnapshot(snapshot) ?? false
                        if restored {
                            Log.output.info("Restored clipboard after copy undo")
                        } else {
                            Log.output.error("Failed to restore clipboard after copy undo")
                        }
                    }
                )
            }
            toastService.show(
                ToastPayload(
                    message: localized("Copied to clipboard", locale: locale),
                    actions: actions,
                    variant: .copied
                )
            )
        case .pasteFailed, nil:
            toastService.show(
                ToastPayload(
                    message: localized(
                        "Paste failed. Transcript copied to clipboard.",
                        locale: locale
                    ),
                    style: .error
                )
            )
        }
    }


    /// True when `error` is cooperative task cancellation (or URLSession cancel).
    nonisolated static func isCancellationError(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        if let urlError = error as? URLError, urlError.code == .cancelled { return true }
        let nsError = error as NSError
        return nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled
    }

    private func ensureNotCancelled() throws {
        try Task.checkCancellation()
    }

    // MARK: - Private — timeout

    /// Bounds a finalize-path step: whichever of `operation` or the deadline finishes
    /// first wins, and the loser is cancelled. Callers catch the timeout and fall back
    /// to the text they already have — the paste must never wait indefinitely.
    nonisolated static func withFinalizeTimeout<T: Sendable>(
        nanoseconds: UInt64,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        let state = FinalizeTimeoutState<T>()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard state.activate(continuation) else { return }

                let operationTask = Task.detached {
                    do {
                        state.resolve(.success(try await operation()))
                    } catch {
                        state.resolve(.failure(error))
                    }
                }
                state.setOperationTask(operationTask)

                let timeoutTask = Task.detached {
                    try? await Task.sleep(nanoseconds: nanoseconds)
                    guard !Task.isCancelled else { return }
                    state.resolve(.failure(FinalizeStepTimedOut()))
                }
                state.setTimeoutTask(timeoutTask)
            }
        } onCancel: {
            state.resolve(.failure(CancellationError()))
        }
    }
}

/// Coordinates independently owned operation/deadline tasks so a deadline can
/// resume its caller even when the operation ignores cooperative cancellation.
/// The first result wins; late operation results are intentionally suppressed.
private final class FinalizeTimeoutState<Output>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Output, Error>?
    private var operationTask: Task<Void, Never>?
    private var timeoutTask: Task<Void, Never>?
    private var pendingResult: Result<Output, Error>?
    private var isResolved = false

    func activate(_ continuation: CheckedContinuation<Output, Error>) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if let pendingResult {
            self.pendingResult = nil
            continuation.resume(with: pendingResult)
            return false
        }
        guard !isResolved else {
            continuation.resume(throwing: CancellationError())
            return false
        }
        self.continuation = continuation
        return true
    }

    func setOperationTask(_ task: Task<Void, Never>) { set(task, asOperation: true) }
    func setTimeoutTask(_ task: Task<Void, Never>) { set(task, asOperation: false) }

    private func set(_ task: Task<Void, Never>, asOperation: Bool) {
        lock.lock()
        let shouldCancel = isResolved
        if !shouldCancel {
            if asOperation { operationTask = task } else { timeoutTask = task }
        }
        lock.unlock()
        if shouldCancel { task.cancel() }
    }

    func resolve(_ result: Result<Output, Error>) {
        lock.lock()
        guard !isResolved else { lock.unlock(); return }
        isResolved = true
        let continuation = self.continuation
        self.continuation = nil
        let operationTask = self.operationTask
        self.operationTask = nil
        let timeoutTask = self.timeoutTask
        self.timeoutTask = nil
        if continuation == nil { pendingResult = result }
        lock.unlock()

        operationTask?.cancel()
        timeoutTask?.cancel()
        continuation?.resume(with: result)
    }
}

// MARK: - Live audio pump

/// An engine-produced commit boundary, published from the main actor and read by
/// the pump's detached consumer.
///
/// A handover may only be applied where the engine itself just flushed and
/// committed, so "everything committed belongs to the outgoing channel" is exact
/// by ordering with no timestamp involved. Two things produce such a boundary: an
/// end-of-utterance final, and an idle commit. Both close an artifact paragraph.
final class LiveEngineBoundarySignal: @unchecked Sendable {
    private let lock = NSLock()
    private var isPending = false

    /// Main actor. Records that the engine reached a boundary.
    func signal() {
        lock.withLock { isPending = true }
    }

    /// Consumer task. Returns true once per signalled boundary.
    func consume() -> Bool {
        lock.withLock {
            defer { isPending = false }
            return isPending
        }
    }
}

/// Feeds one streaming engine from the live packet stream, on one detached task.
///
/// The consumer, not the arbiter, decides when a handover takes effect. Splicing
/// a second channel into a partly filled decode chunk puts two voices inside one
/// decoded string, and no clock can separate them afterwards, so while a handover
/// is pending nothing is fed at all. The switch lands at the engine's own next
/// boundary; if none arrives within `handoverCeilingSeconds` the pump feeds
/// exactly the remainder of the open chunk as silence to force one decode, then
/// applies it behind that decode.
///
/// The incoming channel's speech between the decision and the application is not
/// in the live preview. The durable spool still holds it and the offline pass at
/// finalize still transcribes it.
private final class LiveAudioPump {

    private let engine: any PindropSpeech.StreamingTranscriptionEngine
    private let arbiter: LiveChannelArbiter?
    private let boundarySignal: LiveEngineBoundarySignal
    private let chunkSeconds: TimeInterval
    private let onHandoverApplied: @Sendable (CaptureSourceKind) -> Void
    private let onDroppedSpeech: @Sendable (CaptureSourceKind, TimeInterval, TimeInterval) -> Void

    /// Samples handed to the engine, including forced-flush silence. The engine
    /// decodes on whole chunks, so this is what says how much of the open chunk
    /// is still unfilled.
    private var fedSamples = 0
    /// The channel whose buffers currently reach the engine.
    private var admittedSource: CaptureSourceKind?
    private var pendingHandover: (to: CaptureSourceKind, atCaptureTime: TimeInterval)?

    init(
        engine: any PindropSpeech.StreamingTranscriptionEngine,
        arbiter: LiveChannelArbiter?,
        boundarySignal: LiveEngineBoundarySignal,
        chunkSeconds: TimeInterval,
        onHandoverApplied: @escaping @Sendable (CaptureSourceKind) -> Void,
        onDroppedSpeech: @escaping @Sendable (CaptureSourceKind, TimeInterval, TimeInterval) -> Void
    ) {
        self.engine = engine
        self.arbiter = arbiter
        self.boundarySignal = boundarySignal
        self.chunkSeconds = chunkSeconds
        self.onHandoverApplied = onHandoverApplied
        self.onDroppedSpeech = onDroppedSpeech
    }

    func ingest(_ packet: LiveAudioPacket) async {
        switch packet {
        case .handoverPending(let target, let captureTime):
            guard pendingHandover == nil else { return }
            pendingHandover = (to: target, atCaptureTime: captureTime)
        case .droppedSpeech(let source, let startCaptureTime, let duration):
            onDroppedSpeech(source, startCaptureTime, duration)
        case .buffer(let buffer, let source, let captureTime):
            await ingestBuffer(buffer, from: source, at: captureTime)
        }
    }

    private func ingestBuffer(
        _ buffer: AVAudioPCMBuffer,
        from source: CaptureSourceKind,
        at captureTime: TimeInterval
    ) async {
        if pendingHandover != nil {
            await resolvePendingHandover(sampleRate: buffer.format.sampleRate, now: captureTime)
        }
        guard pendingHandover == nil else { return }

        if admittedSource == nil {
            // The first claim needs no boundary in the engine: nothing has been
            // committed yet, so pointing the transcript at this channel is exact.
            admittedSource = source
            onHandoverApplied(source)
        }
        guard admittedSource == source else { return }

        do {
            try await engine.processAudioBuffer(buffer)
            fedSamples += Int(buffer.frameLength)
        } catch {
            Log.transcription.error("Streaming audio buffer processing failed: \(error)")
        }
    }

    /// Applies the pending handover if the engine reached a boundary, or forces
    /// one at the ceiling.
    private func resolvePendingHandover(sampleRate: Double, now: TimeInterval) async {
        guard let pending = pendingHandover else { return }
        if boundarySignal.consume() {
            apply(pending.to)
            return
        }
        guard now - pending.atCaptureTime >= LiveChannelArbiter.handoverCeilingSeconds else {
            return
        }
        await forceFlush(sampleRate: sampleRate)
        apply(pending.to)
    }

    /// Feeds exactly the remainder of the open chunk as silence, which forces one
    /// decode. An aligned accumulator takes a whole chunk, the shortest pad that
    /// still guarantees a decode.
    private func forceFlush(sampleRate: Double) async {
        guard sampleRate > 0 else { return }
        let chunkSamples = Int((chunkSeconds * sampleRate).rounded())
        let silenceSamples = LiveChannelArbiter.forcedFlushSilenceSamples(
            fedSamples: fedSamples,
            chunkSamples: chunkSamples
        )
        guard silenceSamples > 0,
              let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1),
              let silence = AVAudioPCMBuffer(
                pcmFormat: format,
                frameCapacity: AVAudioFrameCount(silenceSamples)
              )
        else {
            return
        }
        silence.frameLength = AVAudioFrameCount(silenceSamples)
        if let channelData = silence.floatChannelData {
            channelData[0].update(repeating: 0, count: silenceSamples)
        }
        do {
            try await engine.processAudioBuffer(silence)
            fedSamples += silenceSamples
        } catch {
            Log.transcription.error("Streaming handover flush failed: \(error)")
        }
    }

    private func apply(_ target: CaptureSourceKind) {
        pendingHandover = nil
        admittedSource = target
        // Tells the arbiter one channel change cleared, so it may decide another.
        arbiter?.applyPendingHandover()
        onHandoverApplied(target)
        Log.transcription.debug("Live channel handover applied to \(target.rawValue)")
    }
}

// MARK: - Artifact display sink

/// The display half of an artifact capture.
///
/// A note capture inserts text nowhere, so this sink types nothing and outputs
/// nothing. It exists for one fact the commit observer cannot carry: the tail
/// the engine has not settled on yet, which the note page draws in a quieter ink.
@MainActor
final class ArtifactDisplaySink: StreamingRefinementOutputSink {

    private let onTentativeChanged: (String) -> Void

    init(onTentativeChanged: @escaping (String) -> Void) {
        self.onTentativeChanged = onTentativeChanged
    }

    func beginStreamingInsertion() {
        onTentativeChanged("")
    }

    func updateStreamingInsertion(committed: String, tentative: String) async throws {
        onTentativeChanged(tentative)
    }

    func finishStreamingInsertion(finalText: String, appendTrailingSpace: Bool) async throws {
        onTentativeChanged("")
    }

    func cancelStreamingInsertion() async {
        onTentativeChanged("")
    }
}
