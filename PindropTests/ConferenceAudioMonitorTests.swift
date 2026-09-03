//
//  ConferenceAudioMonitorTests.swift
//  PindropTests
//
//  Created on 2026-09-03.
//

import CoreAudio
import Foundation
import Testing

@testable import Pindrop

@MainActor
private final class ConferenceMonitorTestClock {
    var current = Date(timeIntervalSinceReferenceDate: 10_000)

    func now() -> Date {
        current
    }

    func advance(by interval: TimeInterval) {
        current = current.addingTimeInterval(interval)
    }
}

/// The detection rule, driven entirely through the probe seam and a synthetic
/// clock. No Core Audio runs here: the real process list depends on whatever the
/// machine is doing, which is the opposite of a test.
@MainActor
@Suite
struct ConferenceAudioMonitorTests {

    private struct Harness {
        let sut: ConferenceAudioMonitor
        let probe: MockConferenceAudioProcessProbe
        let scheduler: TestConferenceAudioScheduler
        let clock: ConferenceMonitorTestClock
    }

    private func makeHarness(states: [ConferenceAudioProcessState]) -> Harness {
        let probe = MockConferenceAudioProcessProbe(states: states)
        let scheduler = TestConferenceAudioScheduler()
        let clock = ConferenceMonitorTestClock()
        let sut = ConferenceAudioMonitor(
            probe: probe,
            now: { clock.now() },
            pollScheduler: scheduler.pollScheduler,
            processListObserver: scheduler.processListObserver
        )
        return Harness(sut: sut, probe: probe, scheduler: scheduler, clock: clock)
    }

    private let confirmation = ConferenceAudioMonitor.callConfirmationInterval

    @Test
    func aConferenceAppWithInputAndOutputIsACall() async {
        let harness = makeHarness(states: [
            conferenceProcess("us.zoom.xos", input: true, output: true)
        ])
        var reported: [String?] = []
        harness.sut.addDetectedCallObserver { reported.append($0?.bundleIdentifier) }

        harness.sut.start()
        await harness.scheduler.tick()
        harness.clock.advance(by: confirmation)
        await harness.scheduler.tick()

        #expect(harness.sut.detectedCall?.bundleIdentifier == "us.zoom.xos")
        // Reported since the flags first held, not since the hold expired.
        #expect(harness.sut.detectedCall?.startedAt == Date(timeIntervalSinceReferenceDate: 10_000))
        #expect(reported == ["us.zoom.xos"])
        // The catalog goes to the probe as a read hint, so the Core Audio
        // conformer can skip the running-flag reads it would discard.
        #expect(harness.probe.requestedBundleIdentifiers == ConferenceAppCatalog.bundleIdentifiers)
    }

    @Test
    func aBrowserPlayingVideoIsNotACall() async {
        // Output with no input is the whole reason browsers are safe to list.
        let harness = makeHarness(states: [
            conferenceProcess("com.google.Chrome", input: false, output: true)
        ])

        harness.sut.start()
        await harness.scheduler.tick()
        harness.clock.advance(by: confirmation * 3)
        await harness.scheduler.tick()

        #expect(harness.sut.detectedCall == nil)
    }

    @Test
    func aNonCatalogAppIsNeverACall() async {
        // Both flags, held for as long as you like, on an app that is not a
        // conference app. The catalog is the authority, not the flags.
        let harness = makeHarness(states: [
            conferenceProcess("com.apple.Music", input: true, output: true)
        ])

        harness.sut.start()
        await harness.scheduler.tick()
        harness.clock.advance(by: confirmation * 3)
        await harness.scheduler.tick()

        #expect(harness.sut.detectedCall == nil)
        // Nothing in the catalog is running, so nothing is polled either.
        #expect(harness.scheduler.activePollCount == 0)
    }

    @Test
    func aCallMustHoldForTenSecondsBeforeItIsReported() async {
        let harness = makeHarness(states: [
            conferenceProcess("com.microsoft.teams", input: true, output: true)
        ])

        harness.sut.start()
        await harness.scheduler.tick()
        #expect(harness.sut.detectedCall == nil)

        harness.clock.advance(by: confirmation - 0.1)
        await harness.scheduler.tick()
        #expect(harness.sut.detectedCall == nil)

        harness.clock.advance(by: 0.1)
        await harness.scheduler.tick()
        #expect(harness.sut.detectedCall?.bundleIdentifier == "com.microsoft.teams")
    }

    @Test
    func aCallEndingClearsTheSignal() async {
        let harness = makeHarness(states: [
            conferenceProcess("us.zoom.xos", input: true, output: true)
        ])

        harness.sut.start()
        await harness.scheduler.tick()
        harness.clock.advance(by: confirmation)
        await harness.scheduler.tick()
        #expect(harness.sut.detectedCall != nil)

        // The call ends: the app stays open, the streams stop.
        harness.probe.setStates([conferenceProcess("us.zoom.xos")])
        await harness.scheduler.tick()
        #expect(harness.sut.detectedCall == nil)

        // The same shape when the read itself stops working, which is what
        // macOS 14.2 and 14.3 do: the signal clears, nothing crashes.
        harness.probe.setStates([conferenceProcess("us.zoom.xos", input: true, output: true)])
        await harness.scheduler.tick()
        harness.clock.advance(by: confirmation)
        await harness.scheduler.tick()
        #expect(harness.sut.detectedCall != nil)

        harness.probe.failReads()
        await harness.scheduler.tick()
        #expect(harness.sut.detectedCall == nil)
    }

    @Test
    func aFailedProcessListReadReportsNoCall() async {
        let harness = makeHarness(states: [
            conferenceProcess("us.zoom.xos", input: true, output: true)
        ])
        harness.probe.failReads(status: OSStatus(kAudioHardwareUnknownPropertyError))

        harness.sut.start()
        await harness.scheduler.tick()
        harness.clock.advance(by: confirmation * 3)
        await harness.scheduler.tick()

        #expect(harness.sut.detectedCall == nil)
        // No availability axis and no busy loop either: a read that cannot work
        // is not worth polling.
        #expect(harness.scheduler.activePollCount == 0)
        #expect(harness.probe.readCount >= 2)
    }
}
