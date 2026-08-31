//
//  LiveAudioPumpTests.swift
//  PindropTests
//
//  Created on 2026-08-31.
//

import AVFoundation
import Foundation
import PindropCore
import PindropSpeech
import Testing

@testable import Pindrop

/// The contract the whole of Phase 1 rests on: a handover lands on a boundary
/// the engine reached *after* the handover was decided, never on a stale one,
/// and never on a boundary some label-only change invented.
@Suite
struct LiveAudioPumpTests {

    // MARK: Doubles

    private final class RecordingEngine: PindropSpeech.StreamingTranscriptionEngine, @unchecked Sendable {
        var state: StreamingTranscriptionState { .streaming }
        private(set) var fedFrameCounts: [Int] = []

        func loadModel(name: String) async throws {}
        func unloadModel() async {}
        func startStreaming() async throws {}
        func stopStreaming() async throws -> String { "" }
        func pauseStreaming() async {}
        func resumeStreaming() async throws {}
        func processAudioChunk(_ samples: [Float]) async throws {}
        func setTranscriptionCallback(_ callback: @escaping StreamingTranscriptionCallback) async {}
        func setEndOfUtteranceCallback(_ callback: @escaping EndOfUtteranceCallback) async {}
        func reset() async {}

        func processAudioBuffer(_ buffer: AVAudioPCMBuffer) async throws {
            fedFrameCounts.append(Int(buffer.frameLength))
        }
    }

    private final class AppliedHandovers: @unchecked Sendable {
        private(set) var sources: [CaptureSourceKind] = []
        private(set) var captureTimes: [TimeInterval] = []
        /// Where the engine's fed watermark stood when each handover applied.
        /// The consumer's ownership run starts from exactly this pair.
        private(set) var fedSeconds: [TimeInterval] = []

        func record(
            _ source: CaptureSourceKind,
            _ captureTime: TimeInterval,
            _ fed: TimeInterval
        ) {
            sources.append(source)
            captureTimes.append(captureTime)
            fedSeconds.append(fed)
        }
    }

    // MARK: Fixtures

    private static let sampleRate: Double = 16_000

    private static func buffer(frames: Int = 1_600) -> AVAudioPCMBuffer {
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))!
        buffer.frameLength = AVAudioFrameCount(frames)
        buffer.floatChannelData?[0].update(repeating: 0.1, count: frames)
        return buffer
    }

    private static func makeSut(
        engine: RecordingEngine,
        arbiter: LiveChannelArbiter?,
        signal: LiveEngineBoundarySignal,
        applied: AppliedHandovers
    ) -> LiveAudioPump {
        LiveAudioPump(
            engine: engine,
            arbiter: arbiter,
            boundarySignal: signal,
            chunkSeconds: 1.12,
            onHandoverApplied: { source, captureTime, fedSeconds in
                applied.record(source, captureTime, fedSeconds)
            },
            onDroppedSpeech: { _, _, _ in }
        )
    }

    // MARK: Tests

    @Test func aStaleEngineBoundaryDoesNotCarryALaterHandover() async {
        let engine = RecordingEngine()
        let signal = LiveEngineBoundarySignal()
        let applied = AppliedHandovers()
        let sut = Self.makeSut(engine: engine, arbiter: nil, signal: signal, applied: applied)

        await sut.ingest(.buffer(Self.buffer(), source: .microphone, captureTime: 0.1))
        // The engine closed a paragraph long before anyone challenged for it.
        signal.signal()

        await sut.ingest(.handoverPending(to: .systemAudio, atCaptureTime: 5.0))
        await sut.ingest(.buffer(Self.buffer(), source: .systemAudio, captureTime: 5.1))

        #expect(applied.sources == [.microphone])
        // The incoming channel is held out of the engine until a boundary the
        // engine reaches after the decision, so its audio cannot land inside the
        // outgoing channel's open chunk.
        #expect(engine.fedFrameCounts == [1_600])
    }

    @Test func aPendingHandoverAppliesOnTheNextEngineBoundary() async {
        let engine = RecordingEngine()
        let signal = LiveEngineBoundarySignal()
        let applied = AppliedHandovers()
        let sut = Self.makeSut(engine: engine, arbiter: nil, signal: signal, applied: applied)

        await sut.ingest(.buffer(Self.buffer(), source: .microphone, captureTime: 0.1))
        signal.signal()
        await sut.ingest(.handoverPending(to: .systemAudio, atCaptureTime: 5.0))
        await sut.ingest(.buffer(Self.buffer(), source: .systemAudio, captureTime: 5.1))
        #expect(applied.sources == [.microphone])

        // Now the engine itself flushes and commits.
        signal.signal()
        await sut.ingest(.buffer(Self.buffer(), source: .systemAudio, captureTime: 5.2))

        #expect(applied.sources == [.microphone, .systemAudio])
        // The turn is stamped where the incoming channel took the engine, not
        // where the switch happened to land.
        #expect(applied.captureTimes.last == 5.0)
        #expect(engine.fedFrameCounts == [1_600, 1_600])
    }

    @Test func anAppliedHandoverReportsTheAudioAlreadyFedToTheEngine() async {
        let engine = RecordingEngine()
        let signal = LiveEngineBoundarySignal()
        let applied = AppliedHandovers()
        let sut = Self.makeSut(engine: engine, arbiter: nil, signal: signal, applied: applied)

        // The first claim needs no boundary and nothing has been fed yet, so the
        // run it opens starts at watermark zero.
        await sut.ingest(.buffer(Self.buffer(), source: .microphone, captureTime: 0.1))
        #expect(applied.fedSeconds == [0])

        // Two more 0.1 s buffers reach the engine before the switch lands.
        await sut.ingest(.buffer(Self.buffer(), source: .microphone, captureTime: 0.2))
        await sut.ingest(.buffer(Self.buffer(), source: .microphone, captureTime: 0.3))
        await sut.ingest(.handoverPending(to: .systemAudio, atCaptureTime: 0.35))
        signal.signal()
        await sut.ingest(.buffer(Self.buffer(), source: .systemAudio, captureTime: 0.4))

        // Three buffers of 1600 frames at 16 kHz is 0.3 s of audio, and the
        // switch lands behind exactly that. The pair (0.35, 0.3) is the whole
        // ownership run the consumer converts later fed watermarks against.
        #expect(applied.sources == [.microphone, .systemAudio])
        #expect(abs((applied.fedSeconds.last ?? -1) - 0.3) < 0.0001)
        #expect(applied.captureTimes.last == 0.35)
    }

    @Test func aLostHandoverPacketIsRecoveredFromTheArbiter() async {
        let engine = RecordingEngine()
        let signal = LiveEngineBoundarySignal()
        let applied = AppliedHandovers()
        var tuning = LiveChannelArbiter.Tuning()
        tuning.claimWindow = 0.05
        tuning.holdWindow = 0.05
        tuning.releaseWindow = 0.05
        let arbiter = LiveChannelArbiter(
            sources: [.microphone, .systemAudio],
            chunkProfile: .lowLatency,
            tuning: tuning
        )
        let sut = Self.makeSut(engine: engine, arbiter: arbiter, signal: signal, applied: applied)

        // The far end takes the engine, exactly as `LiveChannelArbiter` decides
        // it on the capture thread.
        var time: TimeInterval = 0
        for _ in 0..<4 {
            _ = arbiter.admit(source: .microphone, rms: 0.001, captureTime: time)
            _ = arbiter.admit(source: .systemAudio, rms: 0.001, captureTime: time)
            time += 0.1
        }
        for _ in 0..<20 {
            _ = arbiter.admit(source: .microphone, rms: 0.001, captureTime: time)
            _ = arbiter.admit(source: .systemAudio, rms: 0.5, captureTime: time)
            time += 0.1
        }
        #expect(arbiter.currentOwner == .systemAudio)
        await sut.ingest(.buffer(Self.buffer(), source: .systemAudio, captureTime: time))
        #expect(applied.sources == [.systemAudio])

        // The far end goes quiet and the person recording answers.
        for _ in 0..<20 {
            _ = arbiter.admit(source: .microphone, rms: 0.5, captureTime: time)
            _ = arbiter.admit(source: .systemAudio, rms: 0.0005, captureTime: time)
            time += 0.1
        }
        #expect(arbiter.pendingHandover == .microphone)

        // The `.handoverPending` packet never reached the pump: the bounded ring
        // dropped the oldest element, or no consumer was attached when it was
        // emitted. Ownership still lives in the arbiter, so the pump recovers it.
        await sut.ingest(.buffer(Self.buffer(), source: .microphone, captureTime: time))
        #expect(applied.sources == [.systemAudio])
        signal.signal()
        await sut.ingest(.buffer(Self.buffer(), source: .microphone, captureTime: time + 0.1))

        #expect(applied.sources == [.systemAudio, .microphone])
        // Applying it clears the arbiter, so the next takeover is not wedged
        // behind a handover nobody ever consumed.
        #expect(arbiter.pendingHandover == nil)
    }

    @Test func aPendingHandoverForceFlushesAtTheCeiling() async {
        let engine = RecordingEngine()
        let signal = LiveEngineBoundarySignal()
        let applied = AppliedHandovers()
        let sut = Self.makeSut(engine: engine, arbiter: nil, signal: signal, applied: applied)

        await sut.ingest(.buffer(Self.buffer(frames: 1_000), source: .microphone, captureTime: 0.1))
        await sut.ingest(.handoverPending(to: .systemAudio, atCaptureTime: 1.0))
        await sut.ingest(.buffer(Self.buffer(), source: .systemAudio, captureTime: 2.0))
        #expect(applied.sources == [.microphone])

        await sut.ingest(
            .buffer(
                Self.buffer(),
                source: .systemAudio,
                captureTime: 1.0 + LiveChannelArbiter.handoverCeilingSeconds
            )
        )

        #expect(applied.sources == [.microphone, .systemAudio])
        // Exactly the remainder of the open chunk: 1.12 s at 16 kHz is 17920
        // samples, and 1000 were fed. The buffer the switch landed on belongs to
        // the incoming channel, so it is fed behind the forced decode.
        #expect(engine.fedFrameCounts == [1_000, 16_920, 1_600])
    }
}
