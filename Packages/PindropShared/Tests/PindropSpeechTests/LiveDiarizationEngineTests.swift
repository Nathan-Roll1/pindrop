//
//  LiveDiarizationEngineTests.swift
//  PindropSpeechTests
//
//  Created on 2026-08-31.
//

import FluidAudio
import Foundation
import Testing
@testable import PindropSpeech

@Suite struct LiveDiarizationEngineTests {

    // MARK: - Batching

    @Test func theEngineBatchesAudioToTheModelStepSize() async throws {
        let script = FakeDiarizerScript()
        let sut = try await makeLoadedEngine(script: script)

        // 0.256 s per buffer: the real system tap cadence. Two buffers clear the
        // 0.48 s step, so the model must see one call per pair, not per buffer.
        var captureTime: TimeInterval = 0
        for _ in 0..<4 {
            await sut.ingest(silence(seconds: 0.256)[...], captureTime: captureTime)
            captureTime += 0.256
        }

        #expect(script.processCallCount == 2)
        #expect(script.addAudioSampleCounts == [8192, 8192])
    }

    // MARK: - Segment reporting

    @Test func aFinalizedSlotChangeIsReportedOnce() async throws {
        let script = FakeDiarizerScript()
        let sut = try await makeLoadedEngine(script: script)
        let firstSegment = segment(speaker: 0, startFrame: 0, endFrame: 6)
        script.enqueue(update(finalized: [firstSegment]))
        // The timeline re-emits a finalized segment whose span did not grow. The
        // reader must not see a second boundary for the same speech.
        script.enqueue(update(finalized: [firstSegment, segment(speaker: 1, startFrame: 6, endFrame: 12)]))

        await ingestSteps(2, into: sut)

        let drained = await sut.drainSegments()
        #expect(drained.count == 2)
        #expect(drained.filter { $0.slotIndex == 0 }.count == 1)
    }

    @Test func slotNumbersAreAssignedInFirstSpeechOrder() async throws {
        let script = FakeDiarizerScript()
        let sut = try await makeLoadedEngine(script: script)
        // Sortformer hands out arbitrary output tracks. Slot 3 speaking first must
        // still read as Speaker 1 in the transcript.
        script.enqueue(update(finalized: [segment(speaker: 3, startFrame: 0, endFrame: 6)]))
        script.enqueue(update(finalized: [segment(speaker: 1, startFrame: 6, endFrame: 12)]))
        script.enqueue(update(finalized: [segment(speaker: 3, startFrame: 12, endFrame: 18)]))

        await ingestSteps(3, into: sut)

        let drained = await sut.drainSegments()
        #expect(drained.map(\.slotIndex) == [0, 1, 0])
    }

    @Test func segmentTimesAreReportedInCaptureTime() async throws {
        let script = FakeDiarizerScript()
        let sut = try await makeLoadedEngine(script: script)
        script.enqueue(update(finalized: [segment(speaker: 0, startFrame: 3, endFrame: 9)]))

        await ingestSteps(1, into: sut)

        let drained = await sut.drainSegments()
        let first = try #require(drained.first)
        #expect(abs(first.startCaptureTime - 0.24) < 0.0001)
        #expect(abs(first.endCaptureTime - 0.72) < 0.0001)
    }

    // MARK: - Frame clock

    @Test func aDroppedSystemBufferDoesNotShiftLaterSegmentTimes() async throws {
        let script = FakeDiarizerScript()
        let sut = try await makeLoadedEngine(script: script)
        script.enqueue(nil)
        script.enqueue(update(finalized: [segment(speaker: 0, startFrame: 12, endFrame: 18)]))

        await sut.ingest(silence(seconds: 0.48)[...], captureTime: 0)
        // 0.48 s of system audio never arrived. The next buffer starts at 0.96 s.
        await sut.ingest(silence(seconds: 0.48)[...], captureTime: 0.96)

        let fed = await sut.diarizerFedSeconds
        #expect(abs(fed - 1.44) < 0.0001)
        #expect(script.addAudioSampleCounts.reduce(0, +) == 23_040)

        let drained = await sut.drainSegments()
        let first = try #require(drained.first)
        // Frame 12 is 0.96 s only because the gap was zero filled to its exact
        // duration. Without the fill it would land at 0.48 s and stay wrong.
        #expect(abs(first.startCaptureTime - 0.96) < 0.0001)
    }

    // MARK: - Ring

    @Test func theRingReturnsNilForARangeThatAgedOut() async throws {
        let script = FakeDiarizerScript()
        let sut = try await makeLoadedEngine(script: script)

        var captureTime: TimeInterval = 0
        for _ in 0..<100 {
            await sut.ingest(silence(seconds: 0.5)[...], captureTime: captureTime)
            captureTime += 0.5
        }

        #expect(await sut.clip(from: 0, to: 1) == nil)
        let recent = await sut.clip(from: 48, to: 49)
        #expect(recent?.count == 16_000)
    }

    // MARK: - Back pressure

    @Test func aFallingBehindEngineStopsFeedingAndKeepsItsLabels() async throws {
        let clock = TestClock()
        let script = FakeDiarizerScript()
        let sut = try await makeLoadedEngine(script: script, now: { clock.now })
        script.enqueue(update(finalized: [segment(speaker: 0, startFrame: 0, endFrame: 6)]))
        // Every step costs more wall time than the audio it covers.
        script.onProcess = { clock.advance(by: 0.6) }

        var captureTime: TimeInterval = 0
        for _ in 0..<5 {
            await sut.ingest(silence(seconds: 0.48)[...], captureTime: captureTime)
            captureTime += 0.48
        }
        #expect(await sut.isPaused)

        let addAudioCallsAtPause = script.addAudioSampleCounts.count
        for _ in 0..<5 {
            await sut.ingest(silence(seconds: 0.48)[...], captureTime: captureTime)
            captureTime += 0.48
        }
        #expect(script.addAudioSampleCounts.count == addAudioCallsAtPause)

        // Labels earned before the pause survive it.
        let drained = await sut.drainSegments()
        #expect(drained.count == 1)
        #expect(drained.first?.slotIndex == 0)
    }

    @Test func aFallingBehindDiarizerNeverDelaysTheAsrConsumer() async throws {
        let script = FakeDiarizerScript()
        let sut = try await makeLoadedEngine(script: script)
        let gate = DispatchSemaphore(value: 0)
        script.onProcess = { _ = gate.wait(timeout: .now() + 10) }

        let ingest = Task { await sut.ingest(silence(seconds: 0.5)[...], captureTime: 0) }
        while script.processCallCount == 0 {
            try await Task.sleep(nanoseconds: 1_000_000)
        }

        // The ASR consumer lives on its own stream and its own task. A wedged
        // diarizer holds its private queue thread, not the shared pool.
        let consumer = AsrConsumerDouble()
        for _ in 0..<50 {
            await consumer.consume()
        }
        #expect(await consumer.count == 50)
        #expect(script.processReturnCount == 0)

        gate.signal()
        await ingest.value
    }

    // MARK: - Load

    @Test func loadRunsOneWarmUpInferenceBeforeReportingReady() async throws {
        let script = FakeDiarizerScript()
        let sut = try makeEngine(script: script)

        #expect(await sut.isLoaded == false)
        try await sut.load()

        #expect(await sut.isLoaded)
        #expect(script.processCallCount == 1)
        #expect(script.addAudioSampleCounts == [19_200])
        // The warm-up advances the model's own frame clock, so the session has to
        // start from zero or every later segment time is 1.2 s late.
        #expect(script.resetCallCount == 1)
        #expect(await sut.diarizerFedSeconds == 0)
    }

    @Test func aMissingBundleDegradesInsteadOfDownloading() async throws {
        let script = FakeDiarizerScript()
        let emptyRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("pindrop-live-diar-empty-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: emptyRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: emptyRoot) }

        let sut = LiveDiarizationEngine(
            modelsDirectory: emptyRoot,
            makeDiarizer: { FakeDiarizer(script: script) }
        )

        await #expect(throws: LiveDiarizationEngine.LiveDiarizationError.self) {
            try await sut.load()
        }
        #expect(script.makeCount == 0)
        #expect(script.addAudioSampleCounts.isEmpty)
        #expect(await sut.isLoaded == false)
    }

    // MARK: - Fixtures

    /// Loads the engine, then clears the warm-up traffic from the script so a test
    /// only ever sees its own steps.
    private func makeLoadedEngine(
        script: FakeDiarizerScript,
        now: (@Sendable () -> TimeInterval)? = nil
    ) async throws -> LiveDiarizationEngine {
        let sut = try makeEngine(script: script, now: now)
        try await sut.load()
        script.reset()
        return sut
    }

    private func makeEngine(
        script: FakeDiarizerScript,
        now: (@Sendable () -> TimeInterval)? = nil
    ) throws -> LiveDiarizationEngine {
        let root = try Self.makeReadyModelsRoot()
        if let now {
            return LiveDiarizationEngine(
                modelsDirectory: root,
                makeDiarizer: { FakeDiarizer(script: script) },
                now: now
            )
        }
        return LiveDiarizationEngine(
            modelsDirectory: root,
            makeDiarizer: { FakeDiarizer(script: script) }
        )
    }

    /// A bundle directory with content in it: exactly what `ModelManager`'s
    /// readiness rule accepts, so `load()` never reaches a download.
    private static func makeReadyModelsRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("pindrop-live-diar-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("FluidAudio/Models", isDirectory: true)
        let bundle = root
            .appendingPathComponent(FeatureModelType.liveDiarization.repoFolderName, isDirectory: true)
            .appendingPathComponent(LiveDiarizationPreset.bundleFileName, isDirectory: true)
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        try Data("stub".utf8).write(to: bundle.appendingPathComponent("coremldata.bin"))
        return root
    }

    private func silence(seconds: TimeInterval) -> [Float] {
        [Float](repeating: 0, count: Int(seconds * 16_000))
    }

    /// One `ingest` per model step, at the exact step size.
    private func ingestSteps(_ count: Int, into engine: LiveDiarizationEngine) async {
        var captureTime: TimeInterval = 0
        for _ in 0..<count {
            await engine.ingest(silence(seconds: 0.48)[...], captureTime: captureTime)
            captureTime += 0.48
        }
    }

    private func segment(
        speaker: Int,
        startFrame: Int,
        endFrame: Int,
        finalized: Bool = true
    ) -> DiarizerSegment {
        DiarizerSegment(
            speakerIndex: speaker,
            startFrame: startFrame,
            endFrame: endFrame,
            finalized: finalized,
            frameDurationSeconds: 0.08,
            activity: 0.9
        )
    }

    private func update(
        finalized: [DiarizerSegment] = [],
        tentative: [DiarizerSegment] = []
    ) -> DiarizerTimelineUpdate {
        DiarizerTimelineUpdate(
            finalizedSegments: finalized,
            tentativeSegments: tentative,
            chunkResult: DiarizerChunkResult(finalizedPredictions: [], finalizedFrameCount: 0)
        )
    }
}

// MARK: - Doubles

/// Monotonic clock stand-in. The fall-behind rule compares wall time against step
/// duration, and a real 2.5 s of sleeping would buy the suite nothing.
final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: TimeInterval = 0

    var now: TimeInterval {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func advance(by seconds: TimeInterval) {
        lock.lock()
        value += seconds
        lock.unlock()
    }
}

/// Stands in for the streaming ASR consumer: a separate task on a separate
/// stream, which is the whole point of the independence test.
actor AsrConsumerDouble {
    private(set) var count = 0

    func consume() {
        count += 1
    }
}

/// Shared record of what the engine asked of its diarizer.
///
/// `FakeDiarizer` itself is built inside the actor by the factory, so the test
/// observes it through this lock-guarded script instead of holding the instance.
final class FakeDiarizerScript: @unchecked Sendable {
    private let lock = NSLock()
    private var queuedUpdates: [DiarizerTimelineUpdate?] = []
    private var _addAudioSampleCounts: [Int] = []
    private var _processCallCount = 0
    private var _processReturnCount = 0
    private var _resetCallCount = 0
    private var _makeCount = 0
    private var _onProcess: (@Sendable () -> Void)?

    var addAudioSampleCounts: [Int] {
        lock.lock(); defer { lock.unlock() }
        return _addAudioSampleCounts
    }

    var processCallCount: Int {
        lock.lock(); defer { lock.unlock() }
        return _processCallCount
    }

    var processReturnCount: Int {
        lock.lock(); defer { lock.unlock() }
        return _processReturnCount
    }

    var resetCallCount: Int {
        lock.lock(); defer { lock.unlock() }
        return _resetCallCount
    }

    var makeCount: Int {
        lock.lock(); defer { lock.unlock() }
        return _makeCount
    }

    var onProcess: (@Sendable () -> Void)? {
        get {
            lock.lock(); defer { lock.unlock() }
            return _onProcess
        }
        set {
            lock.lock(); _onProcess = newValue; lock.unlock()
        }
    }

    func enqueue(_ update: DiarizerTimelineUpdate?) {
        lock.lock(); queuedUpdates.append(update); lock.unlock()
    }

    /// Clears both the counters and the queued updates.
    func reset() {
        lock.lock()
        queuedUpdates.removeAll()
        _addAudioSampleCounts.removeAll()
        _processCallCount = 0
        _processReturnCount = 0
        _resetCallCount = 0
        lock.unlock()
    }

    /// Clears the counters only, so warm-up traffic does not count against a test.
    func resetCounters() {
        lock.lock()
        _addAudioSampleCounts.removeAll()
        _processCallCount = 0
        _processReturnCount = 0
        _resetCallCount = 0
        lock.unlock()
    }

    fileprivate func recordMake() {
        lock.lock(); _makeCount += 1; lock.unlock()
    }

    fileprivate func recordAddAudio(_ count: Int) {
        lock.lock(); _addAudioSampleCounts.append(count); lock.unlock()
    }

    fileprivate func recordReset() {
        lock.lock(); _resetCallCount += 1; lock.unlock()
    }

    fileprivate func recordProcess() -> (DiarizerTimelineUpdate?, (@Sendable () -> Void)?) {
        lock.lock()
        _processCallCount += 1
        let hook = _onProcess
        let next = queuedUpdates.isEmpty ? nil : queuedUpdates.removeFirst()
        lock.unlock()
        return (next, hook)
    }

    fileprivate func recordProcessReturn() {
        lock.lock(); _processReturnCount += 1; lock.unlock()
    }
}

/// Minimal `Diarizer` that never touches CoreML.
final class FakeDiarizer: Diarizer {
    private let script: FakeDiarizerScript

    init(script: FakeDiarizerScript) {
        self.script = script
        script.recordMake()
    }

    var isAvailable: Bool { true }
    var numFramesProcessed: Int { 0 }
    var targetSampleRate: Int? { 16_000 }
    var modelFrameHz: Double? { 12.5 }
    var numSpeakers: Int? { 4 }
    let timeline = DiarizerTimeline(config: .sortformerDefault)

    func addAudio<C: Collection>(_ samples: C, sourceSampleRate: Double?) throws
    where C.Element == Float {
        script.recordAddAudio(samples.count)
    }

    func process() throws -> DiarizerTimelineUpdate? {
        let (next, hook) = script.recordProcess()
        hook?()
        script.recordProcessReturn()
        return next
    }

    func process<C: Collection>(samples: C, sourceSampleRate: Double?) throws -> DiarizerTimelineUpdate?
    where C.Element == Float {
        try addAudio(samples, sourceSampleRate: sourceSampleRate)
        return try process()
    }

    func processComplete<C: Collection>(
        _ samples: C,
        sourceSampleRate: Double?,
        keepingEnrolledSpeakers keepSpeakers: Bool?,
        finalizeOnCompletion: Bool,
        progressCallback: ((Int, Int, Int) -> Void)?
    ) throws -> DiarizerTimeline where C.Element == Float {
        timeline
    }

    func processComplete(
        audioFileURL: URL,
        keepingEnrolledSpeakers keepSpeakers: Bool?,
        finalizeOnCompletion: Bool,
        progressCallback: ((Int, Int, Int) -> Void)?
    ) throws -> DiarizerTimeline {
        timeline
    }

    func reset() {
        script.recordReset()
    }

    func cleanup() {}

    func enrollSpeaker<C: Collection>(
        withAudio samples: C,
        sourceSampleRate: Double?,
        named name: String?,
        overwritingAssignedSpeakerName overwriteAssignedSpeakerName: Bool
    ) throws -> DiarizerSpeaker? where C.Element == Float {
        nil
    }

    @discardableResult
    func finalizeSession() throws -> DiarizerTimelineUpdate? {
        try process()
    }
}
