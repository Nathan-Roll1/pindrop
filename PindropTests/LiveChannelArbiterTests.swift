//
//  LiveChannelArbiterTests.swift
//  PindropTests
//
//  Created on 2026-08-31.
//

import Foundation
import Testing
@testable import Pindrop
import PindropCore
import PindropSpeech

// MARK: - Synthetic channels

/// Room tone. Under every gate, and the level a quiet channel's floor settles at.
private let roomTone: Float = 0.0008

/// Syllabic speech: 0.40 s of voice, then 0.20 s of breath, repeating.
///
/// Real speech carries that dynamic range, and the whole point of an adaptive
/// floor is that it reads the range rather than an absolute level. A flat tone
/// carries none, which is what `continuousMedia` is for.
private func speech(
    at time: TimeInterval,
    level: Float = 0.05,
    from start: TimeInterval,
    until end: TimeInterval = .greatestFiniteMagnitude
) -> Float {
    guard time >= start, time < end else { return roomTone }
    let phase = (time - start).truncatingRemainder(dividingBy: 0.6)
    return phase < 0.4 ? level : roomTone
}

private func silence(at time: TimeInterval) -> Float { roomTone }

/// Call audio that never stops: music on hold, a shared video, room tone from a
/// far end. Loud, and with far too little dynamic range for a gate to call it
/// speech.
private func continuousMedia(at time: TimeInterval, level: Float = 0.03) -> Float {
    level * (1 + 0.25 * Float(sin(2 * Double.pi * time / 0.7)))
}

/// Drives an arbiter with synthetic per-buffer RMS on both channels, at one
/// fixed cadence, and keeps every decision it gave back.
private final class ChannelFeeder {
    let step: TimeInterval
    private(set) var time: TimeInterval = 0
    private(set) var microphoneDecisions: [LiveChannelDecision] = []
    private(set) var systemAudioDecisions: [LiveChannelDecision] = []
    private(set) var handovers: [(source: CaptureSourceKind, time: TimeInterval)] = []

    private let sut: LiveChannelArbiter
    private let channels: Set<CaptureSourceKind>

    init(
        sut: LiveChannelArbiter,
        channels: Set<CaptureSourceKind> = [.microphone, .systemAudio],
        step: TimeInterval = 0.02
    ) {
        self.sut = sut
        self.channels = channels
        self.step = step
    }

    func feed(
        seconds: TimeInterval,
        microphone: (TimeInterval) -> Float = silence,
        systemAudio: (TimeInterval) -> Float = silence
    ) {
        let stepCount = Int((seconds / step).rounded())
        for _ in 0..<stepCount {
            if channels.contains(.microphone) {
                record(sut.admit(source: .microphone, rms: microphone(time), captureTime: time), .microphone)
            }
            if channels.contains(.systemAudio) {
                record(sut.admit(source: .systemAudio, rms: systemAudio(time), captureTime: time), .systemAudio)
            }
            time += step
        }
    }

    private func record(_ decision: LiveChannelDecision, _ source: CaptureSourceKind) {
        switch source {
        case .microphone: microphoneDecisions.append(decision)
        case .systemAudio: systemAudioDecisions.append(decision)
        }
        if case .handoverPending(let incoming) = decision {
            handovers.append((source: incoming, time: time))
        }
    }
}

/// A gate that records every question asked of it. Rule 1 says a single-source
/// capture asks none.
private final class CountingGate: LiveSpeechGating {
    private(set) var updateCount = 0
    private(set) var isSpeaking = false

    @discardableResult
    func update(rms: Float, timeStep: TimeInterval) -> Bool {
        updateCount += 1
        return false
    }

    func reset() {}
}

@Suite
struct LiveChannelArbiterTests {
    private func makeArbiter(
        profile: StreamingChunkProfile = .standard,
        sources: Set<CaptureSourceKind> = [.microphone, .systemAudio]
    ) -> LiveChannelArbiter {
        LiveChannelArbiter(sources: sources, chunkProfile: profile)
    }

    /// The microphone owns the engine, then falls quiet while the call audio
    /// starts talking. The scenario every handover test is built on.
    private func makeHandoverScenario() -> (sut: LiveChannelArbiter, feeder: ChannelFeeder) {
        let sut = makeArbiter()
        let feeder = ChannelFeeder(sut: sut)
        feeder.feed(seconds: 1.0)
        feeder.feed(
            seconds: 3.0,
            microphone: { speech(at: $0, from: 1.0, until: 4.0) }
        )
        feeder.feed(
            seconds: 2.0,
            microphone: { speech(at: $0, from: 1.0, until: 4.0) },
            systemAudio: { speech(at: $0, from: 4.0) }
        )
        return (sut, feeder)
    }

    // MARK: Ownership

    @Test func theFirstChannelWithSpeechTakesTheEngine() {
        let sut = makeArbiter()
        let feeder = ChannelFeeder(sut: sut)

        feeder.feed(seconds: 1.0)
        #expect(sut.currentOwner == nil)

        feeder.feed(seconds: 1.0, microphone: { speech(at: $0, from: 1.0) })

        #expect(sut.currentOwner == .microphone)
        #expect(feeder.microphoneDecisions.last == .forward)
        // Nothing was spoken on the call, so the call audio never reaches the
        // engine and never displaces the person recording.
        #expect(feeder.systemAudioDecisions.allSatisfy { $0 == .drop })
        #expect(feeder.handovers.isEmpty)
    }

    @Test func bothChannelsSpeakingAtOnceGivesTheEngineToSystemAudio() {
        let sut = makeArbiter()
        let feeder = ChannelFeeder(sut: sut)

        feeder.feed(seconds: 1.0)
        feeder.feed(
            seconds: 2.0,
            microphone: { speech(at: $0, from: 1.0) },
            systemAudio: { speech(at: $0, level: 0.04, from: 1.0) }
        )

        #expect(sut.currentOwner == .systemAudio)
        #expect(feeder.microphoneDecisions.allSatisfy { $0 == .drop })
        #expect(feeder.handovers.isEmpty)
    }

    @Test func theOwnerKeepsTheEngineThroughCrossTalk() {
        let sut = makeArbiter()
        let feeder = ChannelFeeder(sut: sut)

        feeder.feed(seconds: 1.0)
        feeder.feed(seconds: 2.0, microphone: { speech(at: $0, from: 1.0) })
        #expect(sut.currentOwner == .microphone)

        // Someone on the call talks over the person recording, for seconds.
        feeder.feed(
            seconds: 3.0,
            microphone: { speech(at: $0, from: 1.0) },
            systemAudio: { speech(at: $0, level: 0.06, from: 3.0) }
        )

        #expect(sut.currentOwner == .microphone)
        #expect(feeder.handovers.isEmpty)
        #expect(sut.pendingHandover == nil)
    }

    @Test func aChallengerWaitsForTheOwnerToGoQuiet() throws {
        let (sut, feeder) = makeHandoverScenario()

        #expect(feeder.handovers.count == 1)
        let handover = try #require(feeder.handovers.first)
        #expect(handover.source == .systemAudio)
        // The microphone's last speech buffer is at 3.78, and the call audio's
        // gate opened at 4.00. The claim window alone would have handed the
        // engine over at 4.26.
        #expect(handover.time >= 3.78 + LiveChannelArbiter.holdWindow)
        #expect(handover.time < 5.2)
        #expect(sut.currentOwner == .systemAudio)
    }

    @Test func aShortNoiseBurstNeverTakesTheEngine() {
        let sut = makeArbiter()
        let feeder = ChannelFeeder(sut: sut)

        feeder.feed(seconds: 1.0)
        feeder.feed(seconds: 3.0, microphone: { speech(at: $0, from: 1.0, until: 4.0) })
        #expect(sut.currentOwner == .microphone)

        // A door, a keyboard, a notification: 0.15 s, under the claim window.
        feeder.feed(
            seconds: 2.0,
            systemAudio: { time in (5.0..<5.15).contains(time) ? 0.06 : roomTone }
        )
        #expect(feeder.handovers.isEmpty)
        #expect(sut.currentOwner == .microphone)

        // The same channel, speaking rather than banging, does take it.
        feeder.feed(seconds: 2.0, systemAudio: { speech(at: $0, level: 0.06, from: 6.0) })
        #expect(feeder.handovers.count == 1)
        #expect(sut.currentOwner == .systemAudio)
    }

    @Test func continuousRoomToneDoesNotLatchTheEngineToSystemAudio() {
        let sut = makeArbiter()
        let feeder = ChannelFeeder(sut: sut)

        // Call audio that never drops below a fixed floor: the far end's room
        // tone, 22 dB above the microphone's room tone the whole time. With one
        // absolute floor for both channels this takes the engine on the first
        // buffer and never gives it back.
        feeder.feed(seconds: 3.0, systemAudio: { _ in 0.01 })
        #expect(sut.currentOwner == nil)

        feeder.feed(
            seconds: 2.0,
            microphone: { speech(at: $0, from: 3.0) },
            systemAudio: { _ in 0.01 }
        )

        #expect(sut.currentOwner == .microphone)
        #expect(feeder.systemAudioDecisions.allSatisfy { $0 == .drop })
    }

    @Test func theMicrophoneDoesNotTakeTheEngineWhenItIsHearingTheSpeakers() {
        // Built-in speakers, no echo cancellation anywhere in the tree: the
        // microphone carries the call audio, four times louder than the system
        // channel reads it, over a microphone floor pinned low by a quiet room.
        let hearing = makeArbiter()
        let hearingFeeder = ChannelFeeder(sut: hearing)
        hearingFeeder.feed(seconds: 4.0, systemAudio: { continuousMedia(at: $0) })
        hearingFeeder.feed(
            seconds: 4.0,
            microphone: { 4 * continuousMedia(at: $0) },
            systemAudio: { continuousMedia(at: $0) }
        )

        #expect(hearing.currentOwner == nil)
        #expect(hearingFeeder.handovers.isEmpty)
        #expect(hearingFeeder.microphoneDecisions.allSatisfy { $0 == .drop })

        // The same levels, but the microphone is carrying a person rather than
        // the speakers. Its envelope does not track the call audio, so the claim
        // stands.
        let speaking = makeArbiter()
        let speakingFeeder = ChannelFeeder(sut: speaking)
        speakingFeeder.feed(seconds: 4.0, systemAudio: { continuousMedia(at: $0) })
        speakingFeeder.feed(
            seconds: 4.0,
            microphone: { speech(at: $0, level: 0.12, from: 4.0) },
            systemAudio: { continuousMedia(at: $0) }
        )

        #expect(speaking.currentOwner == .microphone)
    }

    // MARK: Handovers

    @Test func noHandoverHappensInsideOneAsrChunk() throws {
        #expect(abs(LiveChannelArbiter.minimumOwnershipSeconds(for: .standard) - 1.52) < 0.001)
        #expect(abs(LiveChannelArbiter.minimumOwnershipSeconds(for: .lowLatency) - 0.96) < 0.001)

        /// The call audio says one short word at 1.00 and stops. The person
        /// recording answers from 1.20 and keeps going. Everything except the
        /// minimum ownership is satisfied from 2.06.
        func handoverTime(profile: StreamingChunkProfile) -> TimeInterval? {
            let sut = makeArbiter(profile: profile)
            let feeder = ChannelFeeder(sut: sut)
            feeder.feed(seconds: 1.0)
            feeder.feed(
                seconds: 3.0,
                microphone: { speech(at: $0, from: 1.2) },
                systemAudio: { time in (1.0..<1.05).contains(time) ? 0.05 : roomTone }
            )
            #expect(feeder.handovers.count == 1)
            return feeder.handovers.first?.time
        }

        let standard = try #require(handoverTime(profile: .standard))
        let lowLatency = try #require(handoverTime(profile: .lowLatency))

        // Ownership started at 1.00 on both.
        #expect(standard >= 1.0 + LiveChannelArbiter.minimumOwnershipSeconds(for: .standard))
        #expect(lowLatency >= 1.0 + LiveChannelArbiter.minimumOwnershipSeconds(for: .lowLatency))
        #expect(lowLatency < standard)
    }

    @Test func aPendingHandoverWaitsForAnEngineBoundary() {
        let (sut, feeder) = makeHandoverScenario()
        #expect(sut.pendingHandover == .systemAudio)

        // The engine has produced no boundary yet. Nothing about more audio
        // arriving applies the handover.
        feeder.feed(seconds: 2.0, systemAudio: { speech(at: $0, from: 4.0) })
        #expect(sut.pendingHandover == .systemAudio)
        #expect(feeder.handovers.count == 1)

        #expect(sut.applyPendingHandover() == .systemAudio)
        #expect(sut.pendingHandover == nil)
    }

    @Test func aPendingHandoverForceFlushesAtTheCeiling() throws {
        let (sut, feeder) = makeHandoverScenario()
        let since = try #require(feeder.handovers.first?.time)

        #expect(sut.needsForcedFlush(at: since + LiveChannelArbiter.handoverCeilingSeconds - 0.01) == false)
        #expect(sut.needsForcedFlush(at: since + LiveChannelArbiter.handoverCeilingSeconds))

        // The pad is exactly the remainder of the open chunk: one decode, no
        // more. 17920 samples is the 1120 ms chunk at 16 kHz.
        #expect(LiveChannelArbiter.forcedFlushSilenceSamples(fedSamples: 20000, chunkSamples: 17920) == 15840)
        #expect(LiveChannelArbiter.forcedFlushSilenceSamples(fedSamples: 17920, chunkSamples: 17920) == 17920)

        sut.applyPendingHandover()
        #expect(sut.needsForcedFlush(at: since + 10) == false)
    }

    @Test func aHandoverEmitsExactlyOneChannelChangeApplication() {
        let (sut, feeder) = makeHandoverScenario()
        feeder.feed(seconds: 3.0, systemAudio: { speech(at: $0, from: 4.0) })

        #expect(feeder.handovers.count == 1)
        #expect(sut.applyPendingHandover() == .systemAudio)
        // A second boundary must not replay the same channel change.
        #expect(sut.applyPendingHandover() == nil)
    }

    // MARK: Dropped speech

    @Test func aDroppedChannelProducesAVisibleGapMarker() {
        let sut = makeArbiter()
        let feeder = ChannelFeeder(sut: sut)

        feeder.feed(seconds: 1.0)
        // The call audio holds the engine, and the person recording talks over
        // it for well over a second.
        feeder.feed(
            seconds: 5.0,
            microphone: { speech(at: $0, from: 2.0, until: 3.4) },
            systemAudio: { speech(at: $0, level: 0.06, from: 1.0) }
        )
        #expect(sut.currentOwner == .systemAudio)

        let intervals = sut.takeDroppedSpeechIntervals()
        #expect(intervals.count == 1)
        #expect(intervals.first?.source == .microphone)
        #expect(abs((intervals.first?.startCaptureTime ?? 0) - 2.0) < 0.05)
        #expect((intervals.first?.duration ?? 0) >= LiveChannelArbiter.droppedSpeechSeconds)
        // Draining is not a copy: the consumer will not draw it twice.
        #expect(sut.takeDroppedSpeechIntervals().isEmpty)
    }

    @Test func adjacentDroppedIntervalsCoalesceIntoOneMarker() {
        let sut = makeArbiter()
        let feeder = ChannelFeeder(sut: sut)

        feeder.feed(seconds: 1.0)
        // Two stretches of lost speech 1.2 s apart, inside one long overlap.
        feeder.feed(
            seconds: 8.0,
            microphone: { time in
                if time < 3.4 { return speech(at: time, from: 2.0) }
                return speech(at: time, from: 4.6, until: 6.0)
            },
            systemAudio: { speech(at: $0, level: 0.06, from: 1.0) }
        )

        let intervals = sut.takeDroppedSpeechIntervals()
        #expect(intervals.count == 1)
        #expect(abs((intervals.first?.startCaptureTime ?? 0) - 2.0) < 0.05)
        #expect((intervals.first?.duration ?? 0) > 3.5)
    }

    // MARK: Single-source captures

    @Test func aMicrophoneOnlyCaptureNeverEmitsAHandover() {
        let sut = makeArbiter(sources: [.microphone])
        let feeder = ChannelFeeder(sut: sut, channels: [.microphone])

        #expect(sut.currentOwner == .microphone)
        feeder.feed(seconds: 4.0, microphone: { speech(at: $0, from: 0.5) })

        #expect(feeder.microphoneDecisions.allSatisfy { $0 == .forward })
        #expect(feeder.handovers.isEmpty)
        #expect(sut.pendingHandover == nil)
        #expect(sut.flushDroppedSpeech().isEmpty)
        #expect(sut.currentOwner == .microphone)
    }

    @Test func aSingleSourceCaptureNeverConsultsTheSpeakerGate() {
        let gate = CountingGate()
        var builtGates = 0
        let sut = LiveChannelArbiter(
            sources: [.microphone],
            chunkProfile: .standard,
            makeGate: { _ in
                builtGates += 1
                return gate
            }
        )
        let feeder = ChannelFeeder(sut: sut, channels: [.microphone])

        feeder.feed(seconds: 4.0, microphone: { speech(at: $0, from: 0.5) })

        #expect(builtGates == 0)
        #expect(gate.updateCount == 0)
    }
}
