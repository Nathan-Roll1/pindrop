//
//  LiveDiarizationEngine.swift
//  PindropSpeech
//
//  Created on 2026-08-31.
//
//  Streaming speaker labels for the system-audio channel.
//
//  Deliberately an actor and deliberately not @MainActor: per-buffer audio
//  must never queue behind UI work. The orb renders at 30fps; a main-actor hop
//  per buffer starves live output and only bursts at stop.
//
//  Deliberately on its own serial executor, not the shared cooperative pool.
//  `SortformerDiarizer.process()` is a synchronous CoreML call that blocks
//  whatever thread runs it. Twice a second it would occupy a cooperative-pool
//  thread while the Nemotron engine actor holds another and the audio consumer
//  needs a third. That is the same starvation class as the shipped regression
//  fixed in 312f23a.
//
//  Live labels are provisional. FluidAudio's own benchmarks put streaming
//  diarization 10 to 15 DER points behind the offline pass, so the offline
//  pass at finalize stays the record and replaces everything written here.
//

import CoreML
import FluidAudio
import Foundation
import PindropCore

/// Hands pre-loaded CoreML models to a real `SortformerDiarizer`.
///
/// FluidAudio's `Diarizer` protocol has no entry point for this, and the engine
/// needs one because the load has to be gated, bounded, and pinned to
/// `.cpuAndNeuralEngine` before the diarizer sees it. Test fakes deliberately do
/// not conform, which is what keeps the CoreML path out of unit tests.
protocol LiveDiarizerModelSink: AnyObject {
    func initialize(models: SortformerModels)
}

extension SortformerDiarizer: LiveDiarizerModelSink {}

public actor LiveDiarizationEngine {

    public enum LiveDiarizationError: Error, LocalizedError {
        case modelUnavailable
        case modelLoadFailed(String)
        case processingFailed(String)

        public var errorDescription: String? {
            switch self {
            case .modelUnavailable:
                return "The live speaker model is not downloaded."
            case .modelLoadFailed(let message):
                return "The live speaker model could not be loaded: \(message)"
            case .processingFailed(let message):
                return "Live speaker labelling failed: \(message)"
            }
        }
    }

    /// One slot's newly settled speech on the system channel, in capture time.
    public struct SlotSegment: Sendable, Equatable {
        public let slotIndex: Int
        public let startCaptureTime: TimeInterval
        public let endCaptureTime: TimeInterval
        public let activity: Float
        public let isFinalized: Bool

        public init(
            slotIndex: Int,
            startCaptureTime: TimeInterval,
            endCaptureTime: TimeInterval,
            activity: Float,
            isFinalized: Bool
        ) {
            self.slotIndex = slotIndex
            self.startCaptureTime = startCaptureTime
            self.endCaptureTime = endCaptureTime
            self.activity = activity
            self.isFinalized = isFinalized
        }
    }

    /// `SortformerDiarizer` is a non-Sendable final class, so it cannot cross
    /// an actor boundary as an initializer argument. Tests inject a factory
    /// that runs inside the actor instead, which is also the only form strict
    /// concurrency accepts. The package is `swift-tools-version: 6.0` with
    /// `swiftLanguageModes: [.v5]`, so passing the instance directly would only
    /// warn today and break on the next language-mode bump.
    private let makeDiarizer: @Sendable () -> any Diarizer

    /// Wall clock for the fall-behind rule. Injected so the back-pressure test
    /// does not have to spend real seconds proving arithmetic.
    private let now: @Sendable () -> TimeInterval

    /// Keeps `process()` off the shared cooperative pool.
    private let queue = DispatchSerialQueue(label: "com.pindrop.live-diarization", qos: .utility)
    public nonisolated var unownedExecutor: UnownedSerialExecutor { queue.asUnownedSerialExecutor() }

    private let modelsDirectory: URL
    private var diarizer: (any Diarizer)?
    /// The most recent system audio, kept so a slot can be cut out and embedded
    /// for profile matching. Sized to `ringSeconds`.
    private var ring: LiveAudioRing
    private var pendingSamples: [Float] = []
    /// Seconds the diarizer has actually consumed. The frame clock is only
    /// equal to capture time while this keeps up with the system tap, so any
    /// gap is filled with exactly its own duration of zeros before the next
    /// real audio is fed (see the `ingest` contract below).
    public private(set) var diarizerFedSeconds: TimeInterval = 0
    /// Capture time of the first sample the engine was handed. Every frame time
    /// the model reports is relative to it, so it is added back on the way out.
    private var frameTimeOffset: TimeInterval = 0
    private var hasIngested = false

    /// True once the fall-behind rule fired. Never clears inside a capture: the
    /// consumer shows the paused chip and the labels stay frozen where they are.
    public private(set) var isPaused = false

    public var isLoaded: Bool { diarizer != nil }

    /// Sortformer emits 6 frames of 0.08 s per step, so a step needs about
    /// half a second of audio. Batch to that before calling `process()`.
    private static let processBatchSeconds: TimeInterval = 0.48
    private static let ringSeconds: TimeInterval = 45
    private static let warmUpSeconds: TimeInterval = 1.2
    /// Measured on an M5 Pro against the balanced v2.1 bundle already on disk:
    /// 3.120 s and 3.145 s for a warm load alone, and 62.998 s for the first
    /// call that also downloaded. The design's original 3 s bound was under the
    /// warm load, so every capture timed out and degraded to channel labels. A
    /// 10 s bound then tripped in the gated run whenever a Nemotron load ran at
    /// the same time, which is what a cold first capture looks like, and the
    /// reader would have been told the model could not be loaded. 30 s absorbs
    /// that contention and still sits well under the measured download, which
    /// is the one load this bound exists to refuse. The load runs concurrently
    /// with capture start, so a slow load only delays labels; it never delays
    /// audio. Readiness is what keeps downloads off the capture path; this is a
    /// backstop.
    private static let loadTimeoutSeconds: TimeInterval = 30
    /// Consecutive over-budget steps before the engine gives up feeding.
    private static let fallBehindStepLimit = 5

    /// The model's own rate. Callers resample the system tap to this before
    /// `ingest`, because `addAudio` is handed `sourceSampleRate: nil`.
    public nonisolated static let sampleRate: Double = 16_000

    // Slot bookkeeping. `slotForSpeaker` is what turns Sortformer's arbitrary
    // output track numbers into first-speech order.
    private var slotForSpeaker: [Int: Int] = [:]
    private var nextSlotIndex = 0
    private var reportedFinalized: Set<FinalizedKey> = []
    private var pendingFinalized: [SlotSegment] = []
    /// Only the newest tentative set is worth reporting: the next step replaces it.
    private var latestTentative: [SlotSegment] = []
    private var consecutiveSlowSteps = 0

    private struct FinalizedKey: Hashable {
        let slotIndex: Int
        let startFrame: Int
        let endFrame: Int
    }

    /// `SortformerModels` is not `Sendable` and the timeout race has to carry it
    /// out of a detached task. Only this actor ever touches the value once the
    /// race resolves, so the wrapper is a narrow escape hatch and not a claim
    /// about the type.
    private struct LoadedSortformerModels: @unchecked Sendable {
        let models: SortformerModels
    }

    public init(
        modelsDirectory: URL,
        makeDiarizer: @escaping @Sendable () -> any Diarizer = {
            SortformerDiarizer(config: LiveDiarizationPreset.config)
        },
        now: @escaping @Sendable () -> TimeInterval = {
            ProcessInfo.processInfo.systemUptime
        }
    ) {
        self.modelsDirectory = modelsDirectory
        self.makeDiarizer = makeDiarizer
        self.now = now
        self.ring = LiveAudioRing(
            capacity: Int(Self.ringSeconds * Self.sampleRate)
        )
    }

    /// The engine one capture runs, with the shipping Sortformer factory.
    ///
    /// The factory is resolved here rather than through the initializer's
    /// default argument on purpose: a default argument that builds a FluidAudio
    /// type is emitted into every calling module, so the app target would have
    /// to link FluidAudio itself to construct this.
    public static func forCapture(modelsDirectory: URL) -> LiveDiarizationEngine {
        LiveDiarizationEngine(modelsDirectory: modelsDirectory)
    }

    // MARK: - Lifecycle

    /// Loads the CoreML bundle and runs one silent warm-up inference.
    ///
    /// Throws `.modelUnavailable` when the bundle is absent or incomplete, before
    /// any FluidAudio call is made. `loadFromHuggingFace` fetches when the bundle
    /// is missing or partial, and a fetch from the capture path is how a partial
    /// bundle gets re-downloaded mid-recording. Downloads belong to
    /// `ModelManager` and nowhere else.
    public func load() async throws {
        guard diarizer == nil else { return }

        guard ModelManager.isLiveDiarizationModelsReady(at: modelsDirectory) else {
            Log.transcription.info("LiveDiarization: bundle not ready, staying on channel labels")
            throw LiveDiarizationError.modelUnavailable
        }

        let created = makeDiarizer()

        if let sink = created as? LiveDiarizerModelSink {
            let models = try await loadModelsWithinBudget()
            sink.initialize(models: models)
        }

        guard created.isAvailable else {
            throw LiveDiarizationError.modelLoadFailed("The diarizer reported itself unavailable.")
        }

        warmUp(created)

        diarizer = created
        resetSessionState()
    }

    /// New capture, same loaded model.
    public func reset() {
        diarizer?.reset()
        resetSessionState()
    }

    /// Releases the bundle and the ring. Called at step 7 of the stop sequence.
    public func unload() {
        diarizer?.cleanup()
        diarizer = nil
        resetSessionState()
        ring = LiveAudioRing(capacity: Int(Self.ringSeconds * Self.sampleRate))
    }

    // MARK: - Streaming

    /// Appends to the ring and to `pendingSamples`, then runs one model step once
    /// `pendingSamples` reaches the step size.
    ///
    /// If `captureTime` is ahead of `diarizerFedSeconds`, exactly that gap is fed
    /// in zeros first. The stream's newest-wins buffering, the fall-behind rule,
    /// and system tap glitches all drop audio, and every drop shifts frame time
    /// against capture time permanently and cumulatively. Padding the gap keeps
    /// the two clocks equal by construction instead of by assumption.
    public func ingest(_ samples: ArraySlice<Float>, captureTime: TimeInterval) {
        guard let diarizer, !isPaused else { return }

        // The engine's clock starts at the first audio it is handed, not at the
        // capture's first buffer. The sink is only armed once the model load
        // returns, so anchoring at zero would make every capture open by
        // padding the whole load duration with zeros and pushing all of it
        // through the model in one call. The offset is constant for the
        // session, so frame time still equals capture time.
        if !hasIngested {
            hasIngested = true
            frameTimeOffset = max(0, captureTime)
            diarizerFedSeconds = frameTimeOffset
        }

        let gapSamples = Int(((captureTime - diarizerFedSeconds) * Self.sampleRate).rounded())
        if gapSamples > 0 {
            ring.appendZeros(gapSamples)
            pendingSamples.append(contentsOf: repeatElement(0, count: gapSamples))
            diarizerFedSeconds += Double(gapSamples) / Self.sampleRate
        }

        ring.append(samples)
        pendingSamples.append(contentsOf: samples)
        diarizerFedSeconds += Double(samples.count) / Self.sampleRate

        // One model step per batch, never a several-second burst in one call.
        // A single oversized `process()` also defeats the fall-behind rule,
        // which compares a step's wall time against the audio that step covered.
        let batchSamples = Int(Self.processBatchSeconds * Self.sampleRate)
        while pendingSamples.count >= batchSamples {
            let batch = Array(pendingSamples.prefix(batchSamples))
            pendingSamples.removeFirst(batchSamples)
            step(diarizer, batch: batch)
            if isPaused { return }
        }
    }

    /// Returns and clears the segments produced since the last drain.
    public func drainSegments() -> [SlotSegment] {
        let drained = (pendingFinalized + latestTentative)
            .sorted { $0.startCaptureTime < $1.startCaptureTime }
        pendingFinalized.removeAll(keepingCapacity: true)
        latestTentative.removeAll(keepingCapacity: true)
        return drained
    }

    /// Cuts a range out of the ring for profile matching. Nil when it aged out.
    ///
    /// The ring's first sample is the first one the engine was handed, so a
    /// capture-time range is shifted by the same offset the segment times carry.
    public func clip(from start: TimeInterval, to end: TimeInterval) -> [Float]? {
        ring.samples(
            fromSample: Int(((start - frameTimeOffset) * Self.sampleRate).rounded()),
            toSample: Int(((end - frameTimeOffset) * Self.sampleRate).rounded())
        )
    }

    /// Finalizes the session, then drains one last time.
    public func finish() -> [SlotSegment] {
        guard let diarizer, !isPaused else { return drainSegments() }

        if !pendingSamples.isEmpty {
            try? diarizer.addAudio(pendingSamples, sourceSampleRate: nil)
            pendingSamples.removeAll(keepingCapacity: true)
        }
        do {
            if let update = try diarizer.finalizeSession() {
                record(update)
            }
        } catch {
            Log.transcription.error("LiveDiarization: finalize failed: \(error.localizedDescription)")
        }
        return drainSegments()
    }

    // MARK: - Steps

    private func step(_ diarizer: any Diarizer, batch: [Float]) {
        let stepSeconds = Double(batch.count) / Self.sampleRate
        let startedAt = now()

        do {
            try diarizer.addAudio(batch, sourceSampleRate: nil)
            if let update = try diarizer.process() {
                record(update)
            }
        } catch {
            Log.transcription.error("LiveDiarization: step failed: \(error.localizedDescription)")
        }

        let elapsed = now() - startedAt
        guard elapsed > stepSeconds else {
            consecutiveSlowSteps = 0
            return
        }

        consecutiveSlowSteps += 1
        guard consecutiveSlowSteps >= Self.fallBehindStepLimit else { return }

        isPaused = true
        Log.transcription.error(
            """
            LiveDiarization: paused after \(Self.fallBehindStepLimit) steps slower \
            than real time. Existing labels stay, ASR is on its own stream and \
            was never at risk.
            """
        )
    }

    private func record(_ update: DiarizerTimelineUpdate) {
        latestTentative.removeAll(keepingCapacity: true)

        for segment in update.finalizedSegments.sorted(by: { $0.startFrame < $1.startFrame }) {
            let slotIndex = slot(for: segment.speakerIndex)
            let key = FinalizedKey(
                slotIndex: slotIndex,
                startFrame: segment.startFrame,
                endFrame: segment.endFrame
            )
            guard reportedFinalized.insert(key).inserted else { continue }
            pendingFinalized.append(slotSegment(from: segment, slotIndex: slotIndex, isFinalized: true))
        }

        for segment in update.tentativeSegments.sorted(by: { $0.startFrame < $1.startFrame }) {
            let slotIndex = slot(for: segment.speakerIndex)
            latestTentative.append(slotSegment(from: segment, slotIndex: slotIndex, isFinalized: false))
        }
    }

    /// Sortformer's output track numbers are arbitrary. Slots are handed out in
    /// first-speech order so the reader never meets Speaker 4 before Speaker 2.
    private func slot(for speakerIndex: Int) -> Int {
        if let existing = slotForSpeaker[speakerIndex] { return existing }
        let assigned = nextSlotIndex
        slotForSpeaker[speakerIndex] = assigned
        nextSlotIndex += 1
        return assigned
    }

    /// Frame time equals capture time because `ingest` zero fills every gap
    /// after the first sample and offsets everything by where that sample sat.
    private func slotSegment(
        from segment: DiarizerSegment,
        slotIndex: Int,
        isFinalized: Bool
    ) -> SlotSegment {
        let frameDuration = TimeInterval(segment.frameDurationSeconds)
        return SlotSegment(
            slotIndex: slotIndex,
            startCaptureTime: frameTimeOffset + TimeInterval(segment.startFrame) * frameDuration,
            endCaptureTime: frameTimeOffset + TimeInterval(segment.endFrame) * frameDuration,
            activity: segment.activity,
            isFinalized: isFinalized
        )
    }

    // MARK: - Load helpers

    /// The first inference after a CoreML load is slow enough to be visible, and
    /// session start is exactly when it must not be. The warm-up advances the
    /// model's own frame clock by its own duration, so the diarizer is reset
    /// afterwards or every later segment time lands 1.2 s late.
    private func warmUp(_ diarizer: any Diarizer) {
        let zeros = [Float](repeating: 0, count: Int(Self.warmUpSeconds * Self.sampleRate))
        do {
            try diarizer.addAudio(zeros, sourceSampleRate: nil)
            _ = try diarizer.process()
        } catch {
            Log.transcription.error("LiveDiarization: warm-up failed: \(error.localizedDescription)")
        }
        diarizer.reset()
    }

    /// A load that runs longer than the bound is downloading, and it must not be.
    ///
    /// `SortformerModels.load(config:mainModelPath:configuration:)` accepts a
    /// configuration and then ignores it, building its own with
    /// `computeUnits = .all`. That is the GPU-contention pattern behind a shipped
    /// bug, so the HuggingFace entry point is the only one used here: it is the
    /// one that threads `computeUnits` through.
    private func loadModelsWithinBudget() async throws -> SortformerModels {
        let cacheDirectory = modelsDirectory
        // Raced, not cancelled. The CoreML load is synchronous and polls no
        // cancellation flag, so a bound built on `cancel()` plus `await
        // task.value` would still wait out the whole load and report success
        // whenever it happened to finish.
        let outcome = await withWallDeadline(seconds: Self.loadTimeoutSeconds) {
            LoadedSortformerModels(
                models: try await SortformerModels.loadFromHuggingFace(
                    config: LiveDiarizationPreset.config,
                    cacheDirectory: cacheDirectory,
                    computeUnits: .cpuAndNeuralEngine,
                    progressHandler: nil
                )
            )
        }

        switch outcome {
        case .value(let loaded):
            return loaded.models
        case .timedOut:
            // The abandoned load keeps running and releases its own models when
            // it finishes. Waiting for it is what this bound exists to refuse.
            Log.transcription.error(
                "LiveDiarization: load exceeded \(Self.loadTimeoutSeconds)s, degrading to channel labels"
            )
            throw LiveDiarizationError.modelLoadFailed(
                "Loading exceeded the \(Int(Self.loadTimeoutSeconds)) s bound."
            )
        case .failure(let error):
            Log.transcription.error("LiveDiarization: load failed: \(error.localizedDescription)")
            throw LiveDiarizationError.modelLoadFailed(error.localizedDescription)
        }
    }

    private func resetSessionState() {
        pendingSamples.removeAll(keepingCapacity: true)
        diarizerFedSeconds = 0
        frameTimeOffset = 0
        hasIngested = false
        isPaused = false
        consecutiveSlowSteps = 0
        slotForSpeaker.removeAll()
        nextSlotIndex = 0
        reportedFinalized.removeAll()
        pendingFinalized.removeAll()
        latestTentative.removeAll()
        ring.clear()
    }
}

// MARK: - Ring

/// Fixed-size window of the most recent system audio.
///
/// Absolute sample index maps straight onto storage because writing always starts
/// at zero and never skips: `index % capacity` is the slot. That is what lets a
/// capture-time range be cut out without a second timeline to keep in sync.
struct LiveAudioRing {
    private var storage: [Float]
    private(set) var totalSamplesWritten = 0
    let capacity: Int

    init(capacity: Int) {
        self.capacity = max(1, capacity)
        self.storage = [Float](repeating: 0, count: max(1, capacity))
    }

    mutating func append<C: Collection>(_ samples: C) where C.Element == Float {
        for sample in samples {
            storage[totalSamplesWritten % capacity] = sample
            totalSamplesWritten += 1
        }
    }

    /// A gap longer than the window overwrites every slot, so it is filled once
    /// and the index is advanced by the whole gap. Writing it sample by sample
    /// would cost the gap's whole length for a window of zeros either way.
    mutating func appendZeros(_ count: Int) {
        guard count > 0 else { return }
        guard count < capacity else {
            for index in storage.indices { storage[index] = 0 }
            totalSamplesWritten += count
            return
        }
        for _ in 0..<count {
            storage[totalSamplesWritten % capacity] = 0
            totalSamplesWritten += 1
        }
    }

    /// Nil when the range aged out, is not yet written, or is empty. Failing here
    /// is the point: embedding whatever happens to sit in the buffer would name
    /// the wrong person.
    func samples(fromSample from: Int, toSample to: Int) -> [Float]? {
        guard from >= 0, to > from, to <= totalSamplesWritten else { return nil }
        let oldestAvailable = max(0, totalSamplesWritten - capacity)
        guard from >= oldestAvailable else { return nil }
        return (from..<to).map { storage[$0 % capacity] }
    }

    mutating func clear() {
        totalSamplesWritten = 0
    }
}
