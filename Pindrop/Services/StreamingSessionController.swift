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
    /// The diarizer's stream is shorter than the ASR one on purpose. Live labels
    /// are provisional and the offline pass replaces them, so a backlog here is
    /// worth dropping rather than working through late; the ASR stream is a
    /// different stream and is never affected by it.
    nonisolated static let maximumBufferedDiarizationBuffers = 16
    /// Seconds of system audio between segment drains. `process()` runs about
    /// twice a second, so draining on that cadence collects every new segment
    /// without a main-actor hop for nothing.
    nonisolated static let diarizationDrainSeconds: TimeInterval = 0.5

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

    /// How a capture gets its streaming diarizer.
    ///
    /// Returns nil when the model bundle is not on disk, which is the readiness
    /// gate that keeps a download off the capture path. Nil means the capture
    /// stays on channel labels for its whole life: `You` and `Call audio`, with
    /// the finished note still naming everyone.
    private let makeLiveDiarizationEngine: (@MainActor () -> LiveDiarizationEngine?)?

    /// How a capture gets its profile embedder. Nil when the offline speaker
    /// bundle is missing, and then slots stop at `.provisional` for the whole
    /// capture: `.named` depends on a second optional model.
    private let makeLiveSpeakerEmbedder: (@MainActor () -> (any LiveSpeakerEmbedding)?)?

    /// Reads participant profiles for a live promotion. Never written to: the
    /// live path records no training evidence.
    private weak var speakerIdentityMatcher: (any LiveSpeakerProfileMatching)?

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

    /// Observer for the settled paragraphs of an artifact capture, each pointed
    /// at the channel that produced it. This is how the note UI sees what the
    /// live engine has decided so far. Joined by newline the spans are exactly
    /// what the durable checkpoints record.
    var onArtifactLiveSpansChanged: (([LiveTranscriptSpan]) -> Void)?

    /// Observer for the tail the engine has not settled on yet. The note page
    /// draws it in a quieter ink, so a person can tell a guess from a decision.
    /// Nothing else consumes it: artifact capture still inserts no text anywhere.
    var onArtifactTentativeChanged: ((LiveTentativeSpan?) -> Void)?

    /// Observer for "this capture records the call, but only the microphone has
    /// ever reached the live engine". The live view says so, because a transcript
    /// that shows one side of a call and never names the missing side reads as
    /// the whole conversation.
    var onArtifactLiveMicrophoneOnlyChanged: ((Bool) -> Void)?

    /// Observer for what the live speaker labels are doing. The note page draws
    /// its setup banner from this; the live sheet draws its chip.
    var onArtifactLiveSpeakerStatusChanged: ((LiveSpeakerLabelStatus) -> Void)?

    /// Observer for "every diarizer slot is in use". Reported once per capture.
    /// The live sheet states it as a capability and never as a headcount.
    var onArtifactLiveSpeakerCapacityReached: (() -> Void)?

    /// The channel the live transcript is following right now. Set from the pump
    /// when a handover is applied, and read when the tentative tail needs a
    /// speaker to be drawn under.
    private var currentLiveSpeaker: LiveSpeakerRef = .currentUser

    /// One contiguous stretch of one channel owning the live engine, held as
    /// three scalars.
    ///
    /// Inside a run the engine's fed seconds advance one for one with that
    /// channel's capture seconds, so a fed watermark maps to capture time by
    /// `captureStart + (fedSeconds - fedStart)`. Only the open run is ever
    /// needed, so there is no splice map and nothing is inverted across history.
    private struct LiveOwnershipRun {
        let source: CaptureSourceKind
        let fedStart: TimeInterval
        let captureStart: TimeInterval
        /// Uptime when the run opened. Inside a run the owner's buffers are
        /// always forwarded, so capture seconds and wall seconds advance
        /// together and the difference is how far behind the engine has fallen.
        var wallStart: TimeInterval

        /// Moves the wall anchor forward past a deficit the engine has already
        /// recovered from.
        ///
        /// Only `wallStart` moves. `fedStart` and `captureStart` are what map an
        /// emission's watermark onto capture time, and moving either would shift
        /// every later speaker boundary.
        func discountingStaleness(_ seconds: TimeInterval) -> LiveOwnershipRun {
            var adjusted = self
            adjusted.wallStart += max(0, seconds)
            return adjusted
        }
    }

    /// The open ownership run, refreshed at every applied handover. Nil until the
    /// first channel claims the engine, and for every session that runs no pump.
    private var liveOwnershipRun: LiveOwnershipRun?

    /// True while this capture includes system audio that has never owned the
    /// live engine. Cleared the first time a handover points at that channel,
    /// and never set again for the life of the capture.
    private var isLiveMicrophoneOnly = false

    /// The last string handed to the durable checkpoint. A label-only span change
    /// reports the same text, and rewriting it would be a store write for nothing.
    private var lastCheckpointedCommittedText = ""

    // MARK: Live speaker labels

    /// The streaming diarizer for the running capture, or nil when this capture
    /// has none. One per capture, unloaded at step 7 of the stop sequence.
    private var liveDiarizationEngine: LiveDiarizationEngine?
    /// The engine's own audio stream, separate from the ASR one on purpose.
    private var diarizationStreamContinuation: AsyncStream<LiveDiarizationSamples>.Continuation?
    private var diarizationConsumerTask: Task<Void, Never>?
    /// Retains the bounded model load so teardown can wait for it rather than
    /// race a load that lands after the capture stopped.
    private var liveDiarizationLoadTask: Task<Void, Never>?
    /// Slots, tiers, and the hysteresis that decides when a label may change.
    private var liveSlotAttributor = LiveSlotAttributor()
    /// True once live speaker labels stopped for this capture: the model was
    /// missing, its load failed, the kill switch fired, or the capture is
    /// stopping. Never clears inside a capture, so degradation is one way.
    private var isLiveDiarizationStopped = false
    /// Watches how far behind real time the live partials are running.
    private var partialLatencyMonitor = LivePartialLatencyMonitor()

    /// The profile embedder for the running capture. Loaded lazily at the first
    /// promotion attempt and released at step 6 of the stop sequence.
    private var liveSpeakerEmbedder: (any LiveSpeakerEmbedding)?
    /// Decides when a slot has earned a name. Nil when this capture cannot
    /// promote anything, which leaves every slot at `Speaker N`.
    private var liveSpeakerPromoter: LiveSpeakerPromoter?
    /// The promotion attempt currently running, or nil.
    ///
    /// One at a time: attempts are bounded but not instant, and two drains
    /// should not queue two passes over the same slots. Held as a task rather
    /// than a flag so the stop sequence can wait for the CoreML pass inside it.
    /// `LiveSpeakerEmbedder.unload()` only drops the model reference, and an
    /// actor is reentrant, so unloading slips in at a suspension point and
    /// returns while the pass is still on the Neural Engine.
    private var promotionTask: Task<Void, Never>?
    /// True once the capacity chip has been asked for. Slots never close, so the
    /// fact is reported once rather than on every drain that follows it.
    private var didReportSlotCapacity = false

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
            .defaultArtifactLiveTranscriptionLimit,
        makeLiveDiarizationEngine: (@MainActor () -> LiveDiarizationEngine?)? = nil,
        makeLiveSpeakerEmbedder: (@MainActor () -> (any LiveSpeakerEmbedding)?)? = nil,
        speakerIdentityMatcher: (any LiveSpeakerProfileMatching)? = nil
    ) {
        self.artifactLiveTranscriptionLimit = artifactLiveTranscriptionLimit
        self.makeLiveDiarizationEngine = makeLiveDiarizationEngine
        self.makeLiveSpeakerEmbedder = makeLiveSpeakerEmbedder
        self.speakerIdentityMatcher = speakerIdentityMatcher
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
                guard let self else { return }
                self.onArtifactTentativeChanged?(
                    tentative.isEmpty
                        ? nil
                        : LiveTentativeSpan(speaker: self.currentLiveSpeaker, text: tentative)
                )
            }
            artifactDisplaySink = displaySink
            currentLiveSpeaker = .currentUser
            // A run belongs to one capture: the engine's fed watermark restarts
            // at zero for every streaming session.
            liveOwnershipRun = nil
            liveSlotAttributor = LiveSlotAttributor()
            partialLatencyMonitor = LivePartialLatencyMonitor()
            isLiveDiarizationStopped = false
            didReportSlotCapacity = false
            coordinator.beginSession(
                outputSink: displaySink,
                commitObserver: self,
                preservesArtifactParagraphs: true,
                initialSpeaker: currentLiveSpeaker
            )
            refinementCoordinator = coordinator
            pumpEngine = transcriptionService.activeStreamingEngine
            attachAudioForwarding()
            attachLiveDiarization(for: handle)
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

    /// Maps an emission's fed watermark onto the capture timeline.
    ///
    /// Nil when no channel has claimed the engine yet, which is every dictation
    /// session: there is nothing to convert against, so nothing is stamped.
    private func liveCaptureTime(forFedSeconds fedSeconds: TimeInterval) -> TimeInterval? {
        guard let run = liveOwnershipRun else { return nil }
        return run.captureStart + (fedSeconds - run.fedStart)
    }

    private func setEngineCallbacks(for session: SessionToken? = nil) {
        transcriptionService.setStreamingCallbacks(
            onPartial: { [weak self] emission in
                guard let self else { return }
                if let session, !self.owns(session) { return }
                let captureTime = self.liveCaptureTime(forFedSeconds: emission.fedSeconds)
                await self.refinementCoordinator?.ingestPartial(
                    emission.text,
                    captureTime: captureTime
                )
                if let captureTime { self.recordPartialArrival(captureTime: captureTime) }
            },
            onFinalUtterance: { [weak self] emission in
                guard let self else { return }
                if let session, !self.owns(session) { return }
                await self.refinementCoordinator?.ingestFinal(
                    emission.text,
                    captureTime: self.liveCaptureTime(forFedSeconds: emission.fedSeconds)
                )
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
        didCommitText committedText: String,
        spans: [LiveTranscriptSpan],
        reachedEngineBoundary: Bool
    ) {
        guard refinementCoordinator === coordinator, isArtifactCaptureActive else { return }
        // The idle commit is one of the two boundaries the engine produces on its
        // own, so a pending handover may land on it. A trailing newline is not
        // the test: a channel change and a dropped-speech marker both append one
        // without the engine having flushed anything.
        if reachedEngineBoundary {
            engineBoundarySignal?.signal()
        }
        // The observer sees every commit, including ones this controller can no
        // longer checkpoint: the words were still decoded, so the note UI shows
        // them and flags the transcript as degraded instead of losing them.
        if !committedText.isEmpty || !spans.isEmpty {
            onArtifactLiveSpansChanged?(spans)
        }
        // A relabel and a dropped-speech marker move the labels without moving one
        // character. Rewriting an unchanged string into the durable checkpoint
        // buys nothing and costs a SwiftData write on the main actor.
        guard committedText != lastCheckpointedCommittedText else { return }
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
            lastCheckpointedCommittedText = committedText
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
        isLiveMicrophoneOnly = false
        lastCheckpointedCommittedText = ""
        onArtifactTentativeChanged?(nil)
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
        audioStreamContinuation?.finish()
        audioStreamContinuation = nil
        // Steps 1 to 7 of the stop sequence for the live path. The durable spool
        // keeps running, and the 45 s ring goes with the engine.
        stopLiveDiarization(releasingEngine: true)
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
        // Said out loud from the first buffer, and withdrawn the moment the call
        // audio reaches the engine. The opposite order would leave a reader
        // believing a one-sided transcript is the whole conversation.
        let liveSources = arbiter?.liveSources ?? []
        if isArtifactCaptureActive,
           liveSources.contains(.systemAudio),
           liveSources.contains(.microphone) {
            isLiveMicrophoneOnly = true
            onArtifactLiveMicrophoneOnlyChanged?(true)
        }
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
            await pump.finish()
        }
        // The continuation is captured directly (it is Sendable); going through
        // self would re-enter the main actor from the capture thread.
        audioRecorder.onLivePacket = { packet in
            if case .dropped = continuation.yield(packet) {
                Log.transcription.warning("Streaming audio buffer backlog exceeded \(Self.maximumBufferedAudioBuffers); dropped oldest buffer")
            }
        }
    }

    // MARK: - Private — live speaker labels

    /// Whether this capture may run live speaker labels at all.
    ///
    /// Three gates: the setting is on, the capture includes system audio (the
    /// microphone channel is already `You` at the highest confidence there is),
    /// and the model bundle is on disk, which the factory checks. They live in
    /// one predicate so a reader of the settings row can find the code it turns
    /// off.
    ///
    /// `liveSpeakerNamesEnabled` is deliberately not `diarizationFeatureEnabled`:
    /// that flag gates the finalize stage, and sharing one would mean turning
    /// live labels off also strips the speakers out of the finished note.
    private var isLiveDiarizationAllowedForCapture: Bool {
        guard let arbiter = audioRecorder.liveChannelArbiter else { return false }
        return Self.allowsLiveSpeakerLabels(
            isEnabledInSettings: settingsStore.liveSpeakerNamesEnabled,
            liveSources: arbiter.liveSources
        )
    }

    /// The two gates that do not need a model on disk, as one decision.
    ///
    /// Static and pure so the rule can be read and tested without a recorder, a
    /// settings store, or a downloaded bundle.
    static func allowsLiveSpeakerLabels(
        isEnabledInSettings: Bool,
        liveSources: Set<CaptureSourceKind>
    ) -> Bool {
        isEnabledInSettings && liveSources.contains(.systemAudio)
    }

    /// Starts the bounded model load for one capture. The load never blocks the
    /// capture starting: it runs on the engine's own executor and wires the audio
    /// stream up only once it succeeds.
    private func attachLiveDiarization(for handle: NoteCaptureHandle) {
        guard isArtifactCaptureActive, !isLiveDiarizationStopped else { return }
        guard isLiveDiarizationAllowedForCapture else { return }
        guard let engine = makeLiveDiarizationEngine?() else {
            // Not an error to the reader. The capture keeps channel labels and
            // the finished note still names everyone. The banner offers the
            // download rather than starting one from the capture path.
            Log.transcription.info(
                "Live speaker labels off for this capture: the streaming speaker model is not ready"
            )
            isLiveDiarizationStopped = true
            onArtifactLiveSpeakerStatusChanged?(.modelMissing)
            return
        }

        liveDiarizationEngine = engine
        onArtifactLiveSpeakerStatusChanged?(.running)
        liveDiarizationLoadTask = Task { @MainActor [weak self] in
            do {
                try await engine.load()
            } catch {
                Log.transcription.error(
                    "Live speaker labels unavailable: \(error.localizedDescription)"
                )
                await engine.unload()
                self?.onArtifactLiveSpeakerStatusChanged?(.loadFailed)
                self?.stopLiveDiarization(releasingEngine: true)
                return
            }
            guard let self,
                  self.isArtifactCaptureCurrent(handle),
                  !self.isLiveDiarizationStopped,
                  self.liveDiarizationEngine === engine
            else {
                await engine.unload()
                return
            }
            self.startDiarizationForwarding(engine: engine)
            self.startSpeakerPromotion(engine: engine)
        }
    }

    /// Arms profile promotion for this capture, if both optional models are
    /// present. Without it, slots stop at `Speaker N`, which the live sheet says
    /// nothing about: it is already an honest label.
    private func startSpeakerPromotion(engine: LiveDiarizationEngine) {
        guard let embedder = makeLiveSpeakerEmbedder?(), let matcher = speakerIdentityMatcher else {
            Log.transcription.info(
                "Live speaker names stay provisional for this capture: no profile embedder"
            )
            return
        }
        liveSpeakerEmbedder = embedder
        let locale = settingsStore.selectedAppLocale.locale
        liveSpeakerPromoter = LiveSpeakerPromoter(
            embedder: embedder,
            matcher: matcher,
            clip: { start, end in await engine.clip(from: start, to: end) },
            previousDisplayName: { NoteCaptureState.speakerName(for: $0, locale: locale) }
        )
    }

    /// Gives every slot that has said enough a chance at a real name.
    ///
    /// A promotion repoints the whole slot at once, so a reader sees one
    /// consistent transcript rather than a name that starts partway down.
    private func attemptLiveSpeakerPromotions() async {
        guard liveSpeakerPromoter != nil, promotionTask == nil else { return }
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.runLiveSpeakerPromotions()
        }
        promotionTask = task
        await task.value
        if promotionTask == task { promotionTask = nil }
    }

    private func runLiveSpeakerPromotions() async {
        guard let promoter = liveSpeakerPromoter else { return }

        for slot in liveSlotAttributor.slotsBelowNamedTier() {
            guard !isLiveDiarizationStopped else { return }
            guard let promoted = await promoter.promotion(for: slot) else { continue }
            guard isArtifactCaptureActive,
                  liveSlotAttributor.promote(slotNumber: slot.number, to: promoted)
            else {
                continue
            }
            if currentLiveSpeaker.key == promoted.key { currentLiveSpeaker = promoted }
            await refinementCoordinator?.relabelSpeaker(slotKey: promoted.key, to: promoted)
            Log.transcription.info("Live speaker slot \(slot.number) promoted to a profile name")
        }
    }

    /// Points the recorder's diarization sink at the engine, through its own
    /// stream and its own detached consumer.
    ///
    /// Two streams, two consumers, on purpose. `SortformerDiarizer.process()` is
    /// a synchronous CoreML call; awaiting it in the ASR consumer would
    /// head-of-line block the next audio buffer by a full inference time, twice
    /// a second, and the ASR stream's newest-wins policy would then drop real
    /// speech out of the live transcript.
    private func startDiarizationForwarding(engine: LiveDiarizationEngine) {
        let (stream, continuation) = AsyncStream.makeStream(
            of: LiveDiarizationSamples.self,
            bufferingPolicy: .bufferingNewest(Self.maximumBufferedDiarizationBuffers)
        )
        diarizationStreamContinuation = continuation
        let onSegments = diarizationSegmentHandler()
        let onFellBehind = diarizationFellBehindHandler()
        let drainSeconds = Self.diarizationDrainSeconds
        diarizationConsumerTask = Task.detached(priority: .utility) {
            var secondsSinceDrain: TimeInterval = 0
            var didReportFallingBehind = false
            for await packet in stream {
                if Task.isCancelled { break }
                await engine.ingest(packet.samples[...], captureTime: packet.captureTime)
                secondsSinceDrain += Double(packet.samples.count) / LiveDiarizationEngine.sampleRate
                guard secondsSinceDrain >= drainSeconds else { continue }
                secondsSinceDrain = 0
                let segments = await engine.drainSegments()
                if !segments.isEmpty { onSegments(segments) }
                // One extra read per drain until the rule fires, then none. The
                // engine stops producing segments once it falls behind, so the
                // pause cannot be learned from the segments themselves.
                guard !didReportFallingBehind, await engine.isPaused else { continue }
                didReportFallingBehind = true
                onFellBehind()
            }
        }
        // Captured directly, like the packet continuation: going through self
        // would re-enter the main actor from the capture thread.
        audioRecorder.onDiarizationBuffer = { buffer, captureTime in
            guard let samples = LiveDiarizationSamples(buffer: buffer, captureTime: captureTime)
            else {
                return
            }
            if case .dropped = continuation.yield(samples) {
                Log.transcription.warning(
                    "Live speaker audio backlog exceeded \(Self.maximumBufferedDiarizationBuffers); dropped oldest buffer"
                )
            }
        }
    }

    /// What the diarizer's consumer does with new segments: one hop to the main
    /// actor per drain, about twice a second, and only when something settled.
    private func diarizationSegmentHandler() -> @Sendable ([LiveDiarizationEngine.SlotSegment]) -> Void {
        { [weak self] segments in
            Task { @MainActor [weak self] in
                await self?.applyDiarizerSegments(segments)
            }
        }
    }

    /// What the consumer does when the engine's own fall-behind rule fires.
    private func diarizationFellBehindHandler() -> @Sendable () -> Void {
        { [weak self] in
            Task { @MainActor [weak self] in
                self?.pauseLiveSpeakerLabels()
            }
        }
    }

    /// Freezes the live speaker labels for the rest of this capture and says so
    /// once.
    ///
    /// Every label already on screen stays exactly where it is: degradation goes
    /// toward a lower tier, never toward losing text and never toward taking a
    /// name back. The finished note still names everyone.
    private func pauseLiveSpeakerLabels() {
        guard !isLiveDiarizationStopped else { return }
        onArtifactLiveSpeakerStatusChanged?(.paused)
        stopLiveDiarization(releasingEngine: true)
    }

    /// Folds newly settled segments into the slot store and applies the one
    /// speaker change they justify.
    private func applyDiarizerSegments(
        _ segments: [LiveDiarizationEngine.SlotSegment]
    ) async {
        guard !isLiveDiarizationStopped else { return }
        await applySlotSegments(segments)
        await attemptLiveSpeakerPromotions()
    }

    /// The same fold without the running-capture gate, so the last segments the
    /// diarizer produces at stop still land.
    private func applySlotSegments(
        _ segments: [LiveDiarizationEngine.SlotSegment]
    ) async {
        guard isArtifactCaptureActive else { return }
        let owner = liveOwnershipRun?.source ?? .microphone
        let boundary = liveSlotAttributor.ingest(segments, owner: owner)
        if !didReportSlotCapacity, liveSlotAttributor.isAtSlotCapacity {
            didReportSlotCapacity = true
            onArtifactLiveSpeakerCapacityReached?()
        }
        guard let boundary else { return }
        currentLiveSpeaker = boundary.speaker
        await refinementCoordinator?.markBoundary(
            .speakerChange,
            speaker: boundary.speaker,
            atCaptureTime: boundary.captureTime
        )
    }

    /// Records how stale the audio behind one emission was, and fires the kill
    /// switch when the live transcript has been trailing for three windows.
    ///
    /// This is the regression that actually matters: two CoreML models sharing
    /// the Neural Engine can push partials behind real time, and a late
    /// transcript costs a reader more than a missing label does. Live labels are
    /// the part that gets dropped, and ASR recovers.
    private func recordPartialArrival(captureTime: TimeInterval) {
        guard !isLiveDiarizationStopped, liveDiarizationEngine != nil else { return }
        guard let run = liveOwnershipRun else { return }
        let now = ProcessInfo.processInfo.systemUptime
        let staleness = (now - run.wallStart) - (captureTime - run.captureStart)
        switch partialLatencyMonitor.record(staleness: staleness, at: now) {
        case .measuring, .overBudget:
            return
        case .healthy:
            // The engine is keeping up now. Audio it never received (a buffer
            // the newest-wins stream dropped, the seconds a pending handover
            // feeds nothing) subtracts from this measure for good, so without
            // this the kill switch would fire on a deficit the transcript
            // recovered from a minute ago.
            liveOwnershipRun = run.discountingStaleness(staleness)
            return
        case .limitReached:
            break
        }
        Log.transcription.error(
            """
            Live speaker labels paused: partial arrival latency stayed over \
            \(LivePartialLatencyMonitor.budgetSeconds)s for \
            \(LivePartialLatencyMonitor.consecutiveWindowLimit) windows. Labels freeze here \
            and the live transcript recovers.
            """
        )
        pauseLiveSpeakerLabels()
    }

    /// Ends live speaker labels for the rest of this capture. Slots freeze where
    /// they are: a label already on screen is never taken away.
    private func stopLiveDiarization(releasingEngine: Bool) {
        isLiveDiarizationStopped = true
        audioRecorder.onDiarizationBuffer = nil
        diarizationStreamContinuation?.finish()
        diarizationStreamContinuation = nil
        guard releasingEngine else { return }
        let consumerTask = diarizationConsumerTask
        diarizationConsumerTask = nil
        let engine = liveDiarizationEngine
        liveDiarizationEngine = nil
        liveSpeakerPromoter = nil
        let embedder = liveSpeakerEmbedder
        liveSpeakerEmbedder = nil
        let promotion = promotionTask
        promotionTask = nil
        guard engine != nil || embedder != nil else { return }
        // Lifecycle teardown, detached so a stop never waits on a model release.
        // The embedder goes first, as it does in the ordered stop sequence, and
        // an in-flight promotion is waited out first: releasing the models while
        // its pass is still running frees nothing.
        Task.detached(priority: .utility) {
            await consumerTask?.value
            await promotion?.value
            await embedder?.unload()
            await engine?.unload()
        }
    }

    /// What the pump does when a handover takes effect: one hop to the main
    /// actor, at the engine boundary the switch landed on, never per buffer.
    private func handoverApplicationHandler() -> @Sendable (CaptureSourceKind, TimeInterval, TimeInterval) async -> Void {
        { [weak self] source, captureTime, fedSeconds in
            await self?.applyLiveChannelChange(
                to: source,
                at: captureTime,
                fedSeconds: fedSeconds
            )
        }
    }

    /// What the pump does with speech the live engine never heard: one hop per
    /// marker, a few per minute.
    private func droppedSpeechHandler() -> @Sendable (CaptureSourceKind, TimeInterval, TimeInterval) async -> Void {
        { [weak self] source, startCaptureTime, duration in
            await self?.refinementCoordinator?.markDroppedSpeech(
                speaker: .channel(for: source),
                startOffset: startCaptureTime,
                duration: duration
            )
        }
    }

    /// Points the live transcript at the channel that just took the engine.
    ///
    /// One main-actor hop, not two. Moving the speaker and recording the boundary
    /// in separate hops lets a commit land between them, which files the incoming
    /// speaker's first paragraph under the outgoing speaker's name.
    private func applyLiveChannelChange(
        to source: CaptureSourceKind,
        at captureTime: TimeInterval,
        fedSeconds: TimeInterval
    ) async {
        // Refreshed before the speaker guard: the first claim of a capture often
        // names the speaker the transcript already points at, and the run still
        // has to start there.
        liveOwnershipRun = LiveOwnershipRun(
            source: source,
            fedStart: fedSeconds,
            captureStart: captureTime,
            wallStart: ProcessInfo.processInfo.systemUptime
        )
        partialLatencyMonitor.reset()
        if source == .systemAudio, isLiveMicrophoneOnly {
            isLiveMicrophoneOnly = false
            onArtifactLiveMicrophoneOnlyChanged?(false)
        }
        // The diarizer keeps labelling the system stream while the microphone
        // owns the engine, so the channel change is what carries the slot that
        // was talking there. Without a slot this is `Call audio`, exactly as it
        // was before live labels existed.
        let speaker = source == .systemAudio && !isLiveDiarizationStopped
            ? liveSlotAttributor.speakerForChannelChange(at: captureTime)
            : LiveSpeakerRef.channel(for: source)
        guard currentLiveSpeaker != speaker else { return }
        currentLiveSpeaker = speaker
        await refinementCoordinator?.markBoundary(
            .channelChange,
            speaker: speaker,
            at: captureTime
        )
    }

    /// The stop sequence, in order.
    ///
    /// The order is the whole point. Get it wrong and two diarizer model
    /// instances are resident and contending for the Neural Engine at exactly
    /// the finalize moment, beside Nemotron's offline retranscription pass.
    private func flushPendingAudioWork() async {
        // 1. No new buffer can be enqueued on either stream.
        audioRecorder.onLivePacket = nil
        audioRecorder.onDiarizationBuffer = nil
        isLiveDiarizationStopped = true

        // 2. Finish the diarizer's stream and wait for its consumer to exit.
        diarizationStreamContinuation?.finish()
        diarizationStreamContinuation = nil
        // Cancelled, never awaited. A first-run CoreML compile can outlast the
        // 3 s bound by a wide margin, and waiting for it here would hold the
        // note at "finalizing" for the remainder with nothing progressing. The
        // load task's own `isLiveDiarizationStopped` guard, which step 1 above
        // already set, unloads whatever it ends up with.
        liveDiarizationLoadTask?.cancel()
        liveDiarizationLoadTask = nil
        let diarizationConsumer = diarizationConsumerTask
        diarizationConsumerTask = nil
        await diarizationConsumer?.value

        // 3. Finalize the diarizer and apply the last speaker change it found.
        if let engine = liveDiarizationEngine {
            await applySlotSegments(engine.finish())
        }

        // 4. Finish the ASR stream and wait for its consumer to exit.
        audioStreamContinuation?.finish()
        audioStreamContinuation = nil
        let consumerTask = audioConsumerTask
        audioConsumerTask = nil
        await consumerTask?.value

        // 5. Close the last paragraph of the capture.
        await closeLiveAttributionTail()

        // 6. Release the profile embedder. This is a stated precondition of the
        //    offline pass, not a best effort: its models and the offline pass's
        //    are the same bundle, and two resident copies contend for the Neural
        //    Engine at exactly the finalize moment. A promotion decided before
        //    step 1 may still be inside its CoreML pass, and `unload()` would
        //    return straight past it, so the pass is waited for and not the
        //    release.
        let promotion = promotionTask
        promotionTask = nil
        await promotion?.value
        liveSpeakerPromoter = nil
        let embedder = liveSpeakerEmbedder
        liveSpeakerEmbedder = nil
        await embedder?.unload()

        // 7. Release the Sortformer bundle and its 45 s ring.
        let engine = liveDiarizationEngine
        liveDiarizationEngine = nil
        await engine?.unload()

        // 8. Then finalize may begin.
        pumpEngine = nil
        engineBoundarySignal = nil
    }

    /// The last thing the live transcript learns about this capture.
    ///
    /// A dropped-speech run settles only once its channel has been quiet for the
    /// coalesce gap, and no buffer arrives after the tap closes, so cross talk in
    /// the final seconds would be dropped with the arbiter. The reader would see a
    /// transcript that reads as continuous across a hole, which is the failure
    /// this phase most needs to avoid. Then the open paragraph is closed.
    private func closeLiveAttributionTail() async {
        guard isArtifactCaptureActive else { return }
        if let arbiter = audioRecorder.liveChannelArbiter {
            for interval in arbiter.flushDroppedSpeech() {
                await refinementCoordinator?.markDroppedSpeech(
                    speaker: .channel(for: interval.source),
                    startOffset: interval.startCaptureTime,
                    duration: interval.duration
                )
            }
        }
        await refinementCoordinator?.markBoundary(.sessionEnd, speaker: currentLiveSpeaker)
    }

    /// Makes the recorder unable to enqueue another buffer before any asynchronous
    /// engine work starts to unwind. The returned task is deliberately retained by
    /// the caller until it is awaited ahead of an engine reset.
    private func detachAudioForwarding(cancelPendingWork: Bool) -> Task<Void, Never>? {
        audioRecorder.onLivePacket = nil
        liveDiarizationLoadTask?.cancel()
        liveDiarizationLoadTask = nil
        diarizationConsumerTask?.cancel()
        stopLiveDiarization(releasingEngine: true)
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

// MARK: - Live diarization plumbing

/// One system-audio buffer on its way to the streaming diarizer.
///
/// Copied to samples on the capture thread rather than carried as an
/// `AVAudioPCMBuffer`: the recorder reuses its buffers, so a queued one can be
/// overwritten before the diarizer reads it. The copy is one pass over a quarter
/// second of 16 kHz mono.
struct LiveDiarizationSamples: Sendable {
    let samples: [Float]
    let captureTime: TimeInterval

    /// Nil for anything the diarizer cannot read at face value. It is fed with
    /// `sourceSampleRate: nil`, so audio at another rate would be labelled at the
    /// wrong times rather than resampled.
    init?(buffer: AVAudioPCMBuffer, captureTime: TimeInterval) {
        guard buffer.format.sampleRate == LiveDiarizationEngine.sampleRate,
              buffer.frameLength > 0,
              let channel = buffer.floatChannelData?[0]
        else {
            return nil
        }
        self.samples = Array(
            UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength))
        )
        self.captureTime = captureTime
    }
}

/// How far behind real time the live partials are running, in windows.
///
/// The number that matters is not how long one partial took but whether the
/// transcript keeps trailing the conversation. One slow partial is a hiccup;
/// three windows of them is a regression the reader can feel, and live speaker
/// labels are what gets dropped to end it.
struct LivePartialLatencyMonitor {

    /// Wall seconds per window. Long enough that a single stall cannot close a
    /// window on its own, short enough that the limit is about a minute of a
    /// visibly late transcript.
    static let windowSeconds: TimeInterval = 20
    /// A window with fewer partials than this says nothing about a percentile.
    static let minimumSamplesPerWindow = 5
    /// The streaming engine reports about 1.1 s behind real time by design.
    /// Past this the transcript is visibly trailing the voices.
    static let budgetSeconds: TimeInterval = 2.5
    /// Consecutive over-budget windows before the kill switch fires.
    static let consecutiveWindowLimit = 3

    private var windowStart: TimeInterval?
    private var staleness: [TimeInterval] = []
    private var consecutiveOverBudgetWindows = 0

    /// What one arrival did to the measurement.
    enum Outcome: Equatable {
        /// The window is still open, or it closed on too few partials to say
        /// anything about a percentile.
        case measuring
        /// A window closed inside the budget. The caller re-anchors on this: the
        /// staleness it reports is a cumulative deficit, so audio the pump never
        /// fed subtracts from it for good, and a healthy window is the evidence
        /// that the deficit is history rather than a live regression.
        case healthy
        case overBudget
        case limitReached
    }

    /// Records one arrival.
    mutating func record(staleness value: TimeInterval, at wallTime: TimeInterval) -> Outcome {
        guard let start = windowStart else {
            windowStart = wallTime
            staleness = [value]
            return .measuring
        }
        staleness.append(value)
        guard wallTime - start >= Self.windowSeconds else { return .measuring }

        let closed = staleness
        windowStart = wallTime
        staleness.removeAll(keepingCapacity: true)

        // Silence is not a regression: no partials arrive while nobody talks.
        guard closed.count >= Self.minimumSamplesPerWindow else {
            consecutiveOverBudgetWindows = 0
            return .measuring
        }
        guard Self.percentile95(of: closed) > Self.budgetSeconds else {
            consecutiveOverBudgetWindows = 0
            return .healthy
        }
        consecutiveOverBudgetWindows += 1
        return consecutiveOverBudgetWindows >= Self.consecutiveWindowLimit ? .limitReached : .overBudget
    }

    /// Drops the open window when the ownership run it was measured against
    /// changes. The consecutive count survives: a handover is not evidence that
    /// the engine caught up.
    mutating func reset() {
        windowStart = nil
        staleness.removeAll(keepingCapacity: true)
    }

    private static func percentile95(of values: [TimeInterval]) -> TimeInterval {
        let sorted = values.sorted()
        let rank = Int((0.95 * Double(sorted.count)).rounded(.up)) - 1
        return sorted[min(max(rank, 0), sorted.count - 1)]
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
///
/// A running count, not a flag. A handover may only be carried by a boundary the
/// engine reached *after* the handover was decided: a boundary from a minute ago
/// says nothing about whether the accumulator is empty now. The consumer records
/// the count when a handover starts pending and applies it once the count moves
/// past that value, so a stale boundary and a boundary the app wrote itself both
/// cost nothing.
final class LiveEngineBoundarySignal: @unchecked Sendable {
    private let lock = NSLock()
    private var count: UInt64 = 0

    /// Main actor. Records that the engine reached a boundary.
    func signal() {
        lock.withLock { count &+= 1 }
    }

    /// Consumer task. How many boundaries the engine has reached so far.
    var boundaryCount: UInt64 {
        lock.withLock { count }
    }
}

/// Feeds one streaming engine from the live packet stream, on one detached task.
///
/// The consumer, not the arbiter, decides when a handover takes effect. Splicing
/// a second channel into a partly filled decode chunk puts two voices inside one
/// decoded string, and no clock can separate them afterwards. While a handover is
/// pending, the incoming channel is held in a bounded buffer. The switch lands at
/// the engine's own next boundary, then the held audio is replayed behind it. If no
/// boundary arrives within `handoverCeilingSeconds`, the pump feeds exactly the
/// remainder of the open chunk as silence to force one decode first. Audio that
/// cannot fit in the bounded handover buffer gets a visible dropped-speech marker;
/// the durable spool still holds it for the offline pass at finalize.
///
/// Internal, not private, so the boundary contract above can be asserted directly
/// rather than inferred from the packets the recorder happened to emit.
final class LiveAudioPump {

    /// Capture callbacks normally arrive about 50 times per second. This keeps
    /// more than one ceiling's worth at that rate, while the duration bound below
    /// remains authoritative for larger buffers.
    private static let maximumPendingAudioBuffers = 256
    private static let pendingAudioDurationTolerance: TimeInterval = 0.000_001

    private let engine: any PindropSpeech.StreamingTranscriptionEngine
    private let arbiter: LiveChannelArbiter?
    private let boundarySignal: LiveEngineBoundarySignal
    private let chunkSeconds: TimeInterval
    private let onHandoverApplied: @Sendable (CaptureSourceKind, TimeInterval, TimeInterval) async -> Void
    private let onDroppedSpeech: @Sendable (CaptureSourceKind, TimeInterval, TimeInterval) async -> Void

    /// Samples handed to the engine, including forced-flush silence. The engine
    /// decodes on whole chunks, so this is what says how much of the open chunk
    /// is still unfilled.
    private var fedSamples = 0
    /// The same audio as `fedSamples`, in seconds, so an applied handover can
    /// report where the engine's own fed watermark stood. It must track the
    /// engine's internal counter: both count exactly the buffers this pump
    /// hands over, and they diverge only across a buffer the engine threw on,
    /// which is logged.
    private var fedSeconds: TimeInterval = 0
    /// The channel whose buffers currently reach the engine.
    private var admittedSource: CaptureSourceKind?
    private var pendingHandover: PendingHandover?
    private var pendingAudio: [PendingAudioBuffer] = []
    private var pendingAudioSeconds: TimeInterval = 0
    private var pendingDroppedAudio: DroppedAudioSpan?

    private struct PendingHandover {
        let to: CaptureSourceKind
        /// Capture time the arbiter awarded the engine. The ceiling starts here,
        /// but the ownership run starts at the first retained incoming buffer.
        let decisionCaptureTime: TimeInterval
        /// The engine's boundary count when this handover was recorded. Only a
        /// boundary past this one can carry the switch.
        let afterBoundaryCount: UInt64
    }

    private struct PendingAudioBuffer {
        let buffer: AVAudioPCMBuffer
        let source: CaptureSourceKind
        let captureTime: TimeInterval
        let duration: TimeInterval
    }

    private struct DroppedAudioSpan {
        let source: CaptureSourceKind
        let startCaptureTime: TimeInterval
        var endCaptureTime: TimeInterval

        var duration: TimeInterval {
            max(0, endCaptureTime - startCaptureTime)
        }
    }

    init(
        engine: any PindropSpeech.StreamingTranscriptionEngine,
        arbiter: LiveChannelArbiter?,
        boundarySignal: LiveEngineBoundarySignal,
        chunkSeconds: TimeInterval,
        onHandoverApplied: @escaping @Sendable (CaptureSourceKind, TimeInterval, TimeInterval) async -> Void,
        onDroppedSpeech: @escaping @Sendable (CaptureSourceKind, TimeInterval, TimeInterval) async -> Void
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
            await beginHandover(to: target, at: captureTime)
        case .droppedSpeech(let source, let startCaptureTime, let duration):
            await flushPendingDroppedAudio()
            await onDroppedSpeech(source, startCaptureTime, duration)
        case .buffer(let buffer, let source, let captureTime):
            await ingestBuffer(buffer, from: source, at: captureTime)
        }
    }

    func finish() async {
        await reportPendingAudioAsDropped()
        await flushPendingDroppedAudio()
        pendingHandover = nil
    }

    private func beginHandover(to target: CaptureSourceKind, at captureTime: TimeInterval) async {
        if let pendingHandover {
            guard pendingHandover.to != target else { return }
            await reportPendingAudioAsDropped()
            self.pendingHandover = nil
        }
        guard target != admittedSource else {
            arbiter?.applyPendingHandover()
            return
        }
        pendingHandover = PendingHandover(
            to: target,
            decisionCaptureTime: captureTime,
            afterBoundaryCount: boundarySignal.boundaryCount
        )
    }

    private func ingestBuffer(
        _ buffer: AVAudioPCMBuffer,
        from source: CaptureSourceKind,
        at captureTime: TimeInterval
    ) async {
        if admittedSource == nil {
            // The first claim needs no boundary in the engine: nothing has been
            // fed yet, so pointing the transcript at whichever channel the
            // arbiter already owns is exact. Adopting a handover the pump never
            // saw is part of that, because the packet carrying it may have been
            // emitted before any consumer was attached.
            let owner = arbiter?.pendingHandover ?? arbiter?.currentOwner ?? source
            admittedSource = owner
            pendingHandover = nil
            arbiter?.applyPendingHandover()
            await onHandoverApplied(owner, captureTime, fedSeconds)
        }
        // Control packets travel in the same bounded ring as the audio, so one can
        // be dropped as the oldest element. Ownership lives in the arbiter, so
        // read it here too: a lost packet then costs latency, never an arbiter
        // wedged behind a handover nobody ever applied.
        if let target = arbiter?.pendingHandover {
            await beginHandover(to: target, at: captureTime)
        }
        if pendingHandover != nil {
            await resolvePendingHandover(
                sampleRate: buffer.format.sampleRate,
                source: source,
                captureTime: captureTime
            )
        }
        if let pendingHandover {
            if source == pendingHandover.to {
                await retainPendingAudio(buffer, from: source, at: captureTime)
            } else {
                await recordDropped(buffer, from: source, at: captureTime)
            }
            return
        }
        guard admittedSource == source else {
            await flushPendingDroppedAudio()
            await onDroppedSpeech(source, captureTime, audioDuration(of: buffer))
            return
        }

        await feed(buffer)
    }

    private func feed(_ buffer: AVAudioPCMBuffer) async {
        // Counted before the call, not after. The engine advances its own fed
        // watermark before it decodes, and rethrows a decode failure, so a
        // buffer it threw on has still moved the clock the emissions report.
        // Counting only successes here would leave this counter behind the
        // engine's by the audio behind every failure, and `fedStart` is read
        // from this one: every later speaker boundary would then cut that far
        // into the outgoing speaker's words, permanently and cumulatively.
        fedSamples += Int(buffer.frameLength)
        let sampleRate = buffer.format.sampleRate
        if sampleRate > 0 {
            fedSeconds += Double(buffer.frameLength) / sampleRate
        }
        do {
            try await engine.processAudioBuffer(buffer)
        } catch {
            Log.transcription.error("Streaming audio buffer processing failed: \(error)")
        }
    }

    /// Applies the pending handover if the engine reached a boundary, or forces
    /// one at the ceiling.
    private func resolvePendingHandover(
        sampleRate: Double,
        source: CaptureSourceKind,
        captureTime: TimeInterval
    ) async {
        guard let pending = pendingHandover else { return }
        let reachedNaturalBoundary = boundarySignal.boundaryCount > pending.afterBoundaryCount
        let reachedCeiling = needsForcedFlush(pending, at: captureTime)
        guard reachedNaturalBoundary || reachedCeiling else { return }
        guard let captureStart = pendingAudio.first?.captureTime
            ?? (source == pending.to ? captureTime : nil)
        else { return }
        if !reachedNaturalBoundary {
            await forceFlush(sampleRate: sampleRate)
        }
        await flushPendingDroppedAudio()
        await apply(pending.to, at: captureStart)
        await replayPendingAudio()
    }

    /// The arbiter owns the ceiling, so a test that moves it moves what ships.
    /// Without an arbiter there is no ownership to hand over and the constant is
    /// the only answer left.
    private func needsForcedFlush(_ pending: PendingHandover, at now: TimeInterval) -> Bool {
        if let arbiter, arbiter.pendingHandover != nil {
            return arbiter.needsForcedFlush(at: now)
        }
        return now - pending.decisionCaptureTime >= LiveChannelArbiter.handoverCeilingSeconds
    }

    private func retainPendingAudio(
        _ buffer: AVAudioPCMBuffer,
        from source: CaptureSourceKind,
        at captureTime: TimeInterval
    ) async {
        let duration = audioDuration(of: buffer)
        while let oldest = pendingAudio.first,
              pendingAudio.count >= Self.maximumPendingAudioBuffers
                || pendingAudioSeconds + duration
                    > LiveChannelArbiter.handoverCeilingSeconds + Self.pendingAudioDurationTolerance {
            pendingAudio.removeFirst()
            pendingAudioSeconds -= oldest.duration
            await recordDropped(
                source: oldest.source,
                startCaptureTime: oldest.captureTime,
                duration: oldest.duration
            )
        }
        guard pendingAudio.count < Self.maximumPendingAudioBuffers,
              duration
                <= LiveChannelArbiter.handoverCeilingSeconds + Self.pendingAudioDurationTolerance
        else {
            await recordDropped(
                source: source,
                startCaptureTime: captureTime,
                duration: duration
            )
            return
        }
        pendingAudio.append(
            PendingAudioBuffer(
                buffer: buffer,
                source: source,
                captureTime: captureTime,
                duration: duration
            )
        )
        pendingAudioSeconds += duration
    }

    private func replayPendingAudio() async {
        let retained = pendingAudio
        pendingAudio.removeAll(keepingCapacity: true)
        pendingAudioSeconds = 0
        for item in retained {
            await feed(item.buffer)
        }
    }

    private func reportPendingAudioAsDropped() async {
        for item in pendingAudio {
            await recordDropped(
                source: item.source,
                startCaptureTime: item.captureTime,
                duration: item.duration
            )
        }
        pendingAudio.removeAll(keepingCapacity: true)
        pendingAudioSeconds = 0
        await flushPendingDroppedAudio()
    }

    private func recordDropped(
        _ buffer: AVAudioPCMBuffer,
        from source: CaptureSourceKind,
        at captureTime: TimeInterval
    ) async {
        await recordDropped(
            source: source,
            startCaptureTime: captureTime,
            duration: audioDuration(of: buffer)
        )
    }

    private func recordDropped(
        source: CaptureSourceKind,
        startCaptureTime: TimeInterval,
        duration: TimeInterval
    ) async {
        let endCaptureTime = startCaptureTime + duration
        if var span = pendingDroppedAudio,
           span.source == source,
           startCaptureTime <= span.endCaptureTime + Self.pendingAudioDurationTolerance {
            span.endCaptureTime = max(span.endCaptureTime, endCaptureTime)
            pendingDroppedAudio = span
            return
        }
        await flushPendingDroppedAudio()
        pendingDroppedAudio = DroppedAudioSpan(
            source: source,
            startCaptureTime: startCaptureTime,
            endCaptureTime: endCaptureTime
        )
    }

    private func flushPendingDroppedAudio() async {
        guard let span = pendingDroppedAudio else { return }
        pendingDroppedAudio = nil
        await onDroppedSpeech(span.source, span.startCaptureTime, span.duration)
    }

    private func audioDuration(of buffer: AVAudioPCMBuffer) -> TimeInterval {
        let sampleRate = buffer.format.sampleRate
        guard sampleRate > 0 else { return 0 }
        return Double(buffer.frameLength) / sampleRate
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
            fedSeconds += Double(silenceSamples) / sampleRate
        } catch {
            Log.transcription.error("Streaming handover flush failed: \(error)")
        }
    }

    private func apply(_ target: CaptureSourceKind, at captureTime: TimeInterval) async {
        pendingHandover = nil
        admittedSource = target
        // Tells the arbiter one channel change cleared, so it may decide another.
        arbiter?.applyPendingHandover()
        await onHandoverApplied(target, captureTime, fedSeconds)
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
