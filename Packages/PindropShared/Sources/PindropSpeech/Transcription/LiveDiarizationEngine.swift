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

    /// True once the fall-behind rule fired. Never clears inside a capture: the
    /// consumer shows the paused chip and the labels stay frozen where they are.
    public private(set) var isPaused = false

    public var isLoaded: Bool { diarizer != nil }

    /// Sortformer emits 6 frames of 0.08 s per step, so a step needs about
    /// half a second of audio. Batch to that before calling `process()`.
    private static let processBatchSeconds: TimeInterval = 0.48
    private static let ringSeconds: TimeInterval = 45
    private static let warmUpSeconds: TimeInterval = 1.2
    private static let loadTimeoutSeconds: TimeInterval = 3
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

        let gapSamples = Int(((captureTime - diarizerFedSeconds) * Self.sampleRate).rounded())
        if gapSamples > 0 {
            ring.appendZeros(gapSamples)
            pendingSamples.append(contentsOf: repeatElement(0, count: gapSamples))
            diarizerFedSeconds += Double(gapSamples) / Self.sampleRate
        }

        ring.append(samples)
        pendingSamples.append(contentsOf: samples)
        diarizerFedSeconds += Double(samples.count) / Self.sampleRate

        if Double(pendingSamples.count) / Self.sampleRate >= Self.processBatchSeconds {
            let batch = pendingSamples
            pendingSamples.removeAll(keepingCapacity: true)
            step(diarizer, batch: batch)
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
    public func clip(from start: TimeInterval, to end: TimeInterval) -> [Float]? {
        ring.samples(
            fromSample: Int((start * Self.sampleRate).rounded()),
            toSample: Int((end * Self.sampleRate).rounded())
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

    /// Frame time equals capture time because `ingest` zero fills every gap.
    private func slotSegment(
        from segment: DiarizerSegment,
        slotIndex: Int,
        isFinalized: Bool
    ) -> SlotSegment {
        let frameDuration = TimeInterval(segment.frameDurationSeconds)
        return SlotSegment(
            slotIndex: slotIndex,
            startCaptureTime: TimeInterval(segment.startFrame) * frameDuration,
            endCaptureTime: TimeInterval(segment.endFrame) * frameDuration,
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
        let loadTask = Task.detached(priority: .utility) {
            LoadedSortformerModels(
                models: try await SortformerModels.loadFromHuggingFace(
                    config: LiveDiarizationPreset.config,
                    cacheDirectory: cacheDirectory,
                    computeUnits: .cpuAndNeuralEngine,
                    progressHandler: nil
                )
            )
        }
        let deadline = Task.detached(priority: .utility) { [timeout = Self.loadTimeoutSeconds] in
            try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            loadTask.cancel()
        }
        defer { deadline.cancel() }

        do {
            return try await loadTask.value.models
        } catch is CancellationError {
            Log.transcription.error(
                "LiveDiarization: load exceeded \(Self.loadTimeoutSeconds)s, degrading to channel labels"
            )
            throw LiveDiarizationError.modelLoadFailed("Loading exceeded the \(Int(Self.loadTimeoutSeconds)) s bound.")
        } catch {
            Log.transcription.error("LiveDiarization: load failed: \(error.localizedDescription)")
            throw LiveDiarizationError.modelLoadFailed(error.localizedDescription)
        }
    }

    private func resetSessionState() {
        pendingSamples.removeAll(keepingCapacity: true)
        diarizerFedSeconds = 0
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

    mutating func appendZeros(_ count: Int) {
        guard count > 0 else { return }
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
