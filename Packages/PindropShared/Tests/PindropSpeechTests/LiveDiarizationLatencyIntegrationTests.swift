//
//  LiveDiarizationLatencyIntegrationTests.swift
//  PindropSpeechTests
//
//  Created on 2026-08-31.
//
//  The section 8.3 latency gate: streaming partial arrival latency with live
//  diarization on and off, over the same fixture.
//
//  Both engines request `.cpuAndNeuralEngine`, so the question this answers is
//  whether Sortformer's twice-a-second inference pushes Nemotron's partials out
//  past their budget. The section 4.8 kill switch is the safety net for that,
//  not the plan, so the number is measured here before Phase 2 merges.
//
//  Gated because it needs both real bundles on disk. Run it with:
//
//      PINDROP_RUN_INTEGRATION_TESTS=1 swift test --package-path Packages/PindropShared \
//          --filter LiveDiarizationLatencyIntegrationTests
//

import AVFoundation
import Foundation
import PindropCore
import Testing

@testable import PindropSpeech

private enum LiveLatencySupport {

    nonisolated static var fixtureRoot: URL {
        if let configured = ProcessInfo.processInfo.environment["PINDROP_DIARIZATION_FIXTURE_ROOT"] {
            return URL(fileURLWithPath: configured, isDirectory: true)
        }
        return Bundle.module.resourceURL!
            .appendingPathComponent("Fixtures/Diarization/Generated", isDirectory: true)
    }

    /// The real download location, because the bundles this needs are the ones
    /// the app itself downloads. Override it to point at a scratch copy.
    nonisolated static var modelsRoot: URL {
        if let configured = ProcessInfo.processInfo.environment["PINDROP_FLUID_AUDIO_MODELS_ROOT"] {
            return URL(fileURLWithPath: configured, isDirectory: true)
        }
        return FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("FluidAudio", isDirectory: true)
            .appendingPathComponent("Models", isDirectory: true)
    }
}

private let liveLatencyPrerequisitesAvailable: Bool = {
    guard ProcessInfo.processInfo.environment["PINDROP_RUN_INTEGRATION_TESTS"] == "1" else { return false }
    let audio = LiveLatencySupport.fixtureRoot.appendingPathComponent("ami-en2002a-0-60.wav")
    guard FileManager.default.fileExists(atPath: audio.path) else { return false }
    guard ModelManager.isLiveDiarizationModelsReady(at: LiveLatencySupport.modelsRoot) else { return false }
    // The streaming bundle is the thing under measurement, so its absence is a
    // skip and never a pass: a run with no ASR reports no latency at all.
    let streaming = LiveLatencySupport.modelsRoot
        .appendingPathComponent(StreamingChunkProfile.standard.repoFolderName, isDirectory: true)
    return FileManager.default.fileExists(atPath: streaming.path)
}()

/// Collects partial arrival latencies across one paced run.
///
/// A plain class behind a lock rather than an actor: the transcription callback
/// is a `@Sendable` closure called from the engine's own executor, and hopping
/// to an actor from there would add the very delay being measured.
private final class LatencyRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [TimeInterval] = []
    private var startTime: TimeInterval = 0

    /// Starts one pass. Samples accumulate across passes: a single 60 s pass
    /// yields about 28 partials, which is too few to read a p95 off.
    func beginPass(at start: TimeInterval) {
        lock.lock()
        startTime = start
        lock.unlock()
    }

    /// `fedSeconds` is the engine's own consumption counter, so the audio behind
    /// this partial was fed at `startTime + fedSeconds` on a real-time paced
    /// feed. Reading a clock at arrival alone would measure the fixture length.
    func record(fedSeconds: TimeInterval, arrivedAt arrival: TimeInterval) {
        lock.lock()
        defer { lock.unlock() }
        guard startTime > 0, fedSeconds > 0 else { return }
        let latency = arrival - (startTime + fedSeconds)
        guard latency.isFinite, latency >= 0 else { return }
        values.append(latency)
    }

    var samples: [TimeInterval] {
        lock.lock()
        defer { lock.unlock() }
        return values
    }
}

@Suite(
    .serialized,
    .enabled(
        if: liveLatencyPrerequisitesAvailable,
        "Live diarization latency fixtures or the model bundles are unavailable"
    )
)
struct LiveDiarizationLatencyIntegrationTests {

    /// 0.256 s per buffer: the cadence the system tap actually delivers.
    private static let bufferSeconds: TimeInterval = 0.256
    /// The budget stated in the pull request: live diarization may cost the p95
    /// partial no more than 100 ms, or 10 percent, whichever is larger.
    private static let absoluteBudgetSeconds: TimeInterval = 0.100
    private static let relativeBudget: Double = 0.10
    /// One 60 s pass yields about 28 partials. Two passes per condition make the
    /// p95 the 54th of 56 rather than the 27th of 28.
    private static let passesPerCondition = 2

    @Test func liveDiarizationKeepsPartialLatencyWithinBudget() async throws {
        let samples = try Self.readMono16kWAV(
            LiveLatencySupport.fixtureRoot.appendingPathComponent("ami-en2002a-0-60.wav")
        )

        let engine = NemotronStreamingEngine(
            chunkProfile: .standard,
            modelsRoot: LiveLatencySupport.modelsRoot
        )
        // Loaded once and reused for both runs. Loading per run would put the
        // cold-start cost in whichever run went first and swamp the difference.
        try await engine.loadModel(name: "")
        defer { Task { await engine.unloadModel() } }

        let baseline = try await Self.measure(samples: samples, engine: engine, diarizer: nil)

        let diarizer = LiveDiarizationEngine(modelsDirectory: LiveLatencySupport.modelsRoot)
        try await diarizer.load()
        let withDiarization = try await Self.measure(samples: samples, engine: engine, diarizer: diarizer)
        await diarizer.unload()

        let budget = max(Self.absoluteBudgetSeconds, baseline.p95 * Self.relativeBudget)
        let delta = withDiarization.p95 - baseline.p95

        print("Live diarization latency gate")
        print("  off: \(baseline.description)")
        print("  on:  \(withDiarization.description)")
        print("  p95 delta=\(delta) budget=\(budget)")

        #expect(baseline.count > 0, "the baseline run produced no partials")
        #expect(withDiarization.count > 0, "the live run produced no partials")
        #expect(
            delta <= budget,
            "p95 partial latency regressed by \(delta) s, budget \(budget) s"
        )
    }

    // MARK: - Measurement

    private struct Summary {
        let count: Int
        let p50: TimeInterval
        let p95: TimeInterval
        let maximum: TimeInterval

        var description: String {
            "n=\(count) p50=\(p50) p95=\(p95) max=\(maximum)"
        }
    }

    /// Runs every pass for one condition and summarises the pooled latencies.
    private static func measure(
        samples: [Float],
        engine: NemotronStreamingEngine,
        diarizer: LiveDiarizationEngine?
    ) async throws -> Summary {
        let recorder = LatencyRecorder()
        for _ in 0..<passesPerCondition {
            try await runOnePass(samples: samples, engine: engine, diarizer: diarizer, into: recorder)
        }
        let values = recorder.samples.sorted()
        return Summary(
            count: values.count,
            p50: percentile(values, 50),
            p95: percentile(values, 95),
            maximum: values.last ?? 0
        )
    }

    /// Feeds the fixture at real-time cadence into whichever engines are active.
    ///
    /// The pacing loop only hands buffers to streams; it never awaits an engine.
    /// Awaiting a decode inside the loop would delay the next feed by exactly the
    /// cost being measured, which hides the regression instead of finding it.
    private static func runOnePass(
        samples: [Float],
        engine: NemotronStreamingEngine,
        diarizer: LiveDiarizationEngine?,
        into recorder: LatencyRecorder
    ) async throws {
        await engine.setTranscriptionCallback { result in
            recorder.record(fedSeconds: result.fedSeconds, arrivedAt: Date().timeIntervalSince1970)
        }
        await engine.reset()
        await diarizer?.reset()
        try await engine.startStreaming()

        // Unbounded for ASR on purpose: a dropping policy would turn a backlog
        // into missing samples instead of the rising latency this gate looks for.
        let (asrStream, asrContinuation) = AsyncStream.makeStream(
            of: [Float].self,
            bufferingPolicy: .unbounded
        )
        // `.bufferingNewest` for the diarizer, matching section 4.2: it may fall
        // behind, and it must never push back on anything else when it does.
        let (diarizationStream, diarizationContinuation) = AsyncStream.makeStream(
            of: ([Float], TimeInterval).self,
            bufferingPolicy: .bufferingNewest(8)
        )

        let asrConsumer = Task.detached(priority: .userInitiated) {
            for await chunk in asrStream {
                try? await engine.processAudioChunk(chunk)
            }
        }
        let diarizationConsumer = Task.detached(priority: .utility) {
            for await (chunk, captureTime) in diarizationStream {
                guard let diarizer else { continue }
                await diarizer.ingest(chunk[...], captureTime: captureTime)
                _ = await diarizer.drainSegments()
            }
        }

        let bufferSampleCount = Int(bufferSeconds * LiveDiarizationEngine.sampleRate)
        let start = Date().timeIntervalSince1970
        recorder.beginPass(at: start)

        var offset = 0
        var index = 0
        while offset < samples.count {
            let end = min(offset + bufferSampleCount, samples.count)
            let chunk = Array(samples[offset..<end])
            let captureTime = TimeInterval(offset) / LiveDiarizationEngine.sampleRate
            offset = end
            index += 1
            // Wait first, then hand it over. A real tap delivers a buffer once
            // its own audio has elapsed, so handing it over at the start of its
            // interval would put the feed a whole buffer ahead of the clock and
            // report every latency as negative.
            let readyAt = start + TimeInterval(index) * bufferSeconds
            let wait = readyAt - Date().timeIntervalSince1970
            if wait > 0 {
                try await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
            }
            asrContinuation.yield(chunk)
            if diarizer != nil {
                diarizationContinuation.yield((chunk, captureTime))
            }
        }

        asrContinuation.finish()
        diarizationContinuation.finish()
        await asrConsumer.value
        await diarizationConsumer.value
        _ = try? await engine.stopStreaming()
        _ = await diarizer?.finish()

    }

    private static func percentile(_ sorted: [TimeInterval], _ point: Double) -> TimeInterval {
        guard !sorted.isEmpty else { return 0 }
        let rank = Int((point / 100 * Double(sorted.count)).rounded(.up)) - 1
        return sorted[min(max(rank, 0), sorted.count - 1)]
    }

    private static func readMono16kWAV(_ url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let format = AVAudioFormat(standardFormatWithSampleRate: LiveDiarizationEngine.sampleRate, channels: 1)!
        let frameCount = AVAudioFrameCount(file.length)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount)!
        try file.read(into: buffer)
        guard let channel = buffer.floatChannelData?[0] else { return [] }
        return Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
    }
}
