//
//  LiveDiarizationIntegrationTests.swift
//  PindropSpeechTests
//
//  Created on 2026-08-31.
//
//  The only test that proves the streaming CoreML path works at all. Everything
//  else in `LiveDiarizationEngineTests` runs against a fake `Diarizer`.
//
//  Gated because it needs the real Sortformer bundle on disk. Nothing here
//  downloads it: `LiveDiarizationEngine.load()` refuses to fetch, so the gate
//  below reports the bundle as missing and the suite is skipped instead.
//

import AVFoundation
import Foundation
import Testing
@testable import PindropSpeech

private enum LiveDiarizationIntegrationSupport {

    nonisolated static var fixtureRoot: URL {
        if let configured = ProcessInfo.processInfo.environment["PINDROP_DIARIZATION_FIXTURE_ROOT"] {
            return URL(fileURLWithPath: configured, isDirectory: true)
        }
        return Bundle.module.resourceURL!
            .appendingPathComponent("Fixtures/Diarization/Generated", isDirectory: true)
    }

    /// The real download location, because the bundle this test needs is the one
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

private let liveDiarizationIntegrationPrerequisitesAvailable: Bool = {
    guard ProcessInfo.processInfo.environment["PINDROP_RUN_INTEGRATION_TESTS"] == "1" else { return false }
    let audio = LiveDiarizationIntegrationSupport.fixtureRoot
        .appendingPathComponent("ami-en2002a-0-60.wav")
    guard FileManager.default.fileExists(atPath: audio.path) else { return false }
    return ModelManager.isLiveDiarizationModelsReady(at: LiveDiarizationIntegrationSupport.modelsRoot)
}()

@Suite(
    .serialized,
    .enabled(
        if: liveDiarizationIntegrationPrerequisitesAvailable,
        "Live diarization fixtures or the Sortformer bundle are unavailable"
    )
)
struct LiveDiarizationIntegrationTests {

    /// How quickly a slot has to earn its first finalized speech. Past this the
    /// live label lands after the text it belongs to and the feature reads broken.
    private static let firstSlotFinalizedBudget: TimeInterval = 2.0

    @Test func theRealBundleLabelsTwoSpeakersWithinTheLatencyBudget() async throws {
        let samples = try Self.readMono16kWAV(
            LiveDiarizationIntegrationSupport.fixtureRoot
                .appendingPathComponent("ami-en2002a-0-60.wav")
        )

        let sut = LiveDiarizationEngine(modelsDirectory: LiveDiarizationIntegrationSupport.modelsRoot)
        try await sut.load()

        // 0.256 s per buffer: the cadence the system tap actually delivers.
        let bufferSamples = Int(0.256 * LiveDiarizationEngine.sampleRate)
        var collected: [LiveDiarizationEngine.SlotSegment] = []
        var offset = 0
        while offset < samples.count {
            let end = min(offset + bufferSamples, samples.count)
            let captureTime = TimeInterval(offset) / LiveDiarizationEngine.sampleRate
            await sut.ingest(samples[offset..<end], captureTime: captureTime)
            collected.append(contentsOf: await sut.drainSegments())
            offset = end
        }
        collected.append(contentsOf: await sut.finish())
        await sut.unload()

        let finalized = collected.filter(\.isFinalized)
        let slots = Set(finalized.map(\.slotIndex))
        #expect(slots.count >= 2, "slots=\(slots.sorted())")

        let firstSlotSegment = try #require(
            finalized.filter { $0.slotIndex == 0 }.min { $0.endCaptureTime < $1.endCaptureTime }
        )
        #expect(firstSlotSegment.endCaptureTime < Self.firstSlotFinalizedBudget)
    }

    private static func readMono16kWAV(_ url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
        let frameCount = AVAudioFrameCount(file.length)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount)!
        try file.read(into: buffer)
        guard let channel = buffer.floatChannelData?[0] else { return [] }
        return Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
    }
}
