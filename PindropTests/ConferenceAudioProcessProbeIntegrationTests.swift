//
//  ConferenceAudioProcessProbeIntegrationTests.swift
//  PindropTests
//
//  Created on 2026-09-03.
//

import AVFoundation
import Foundation
import Testing

@testable import Pindrop

/// The one test that proves the Core Audio path works at all. Everything else
/// about conference detection runs against a probe double.
@MainActor
@Suite(.enabled(if: ProcessInfo.processInfo.environment["PINDROP_RUN_INTEGRATION_TESTS"] == "1", "Conference process probe integration tests are disabled by default. Run `just test-integration` to execute them."))
struct ConferenceAudioProcessProbeIntegrationTests {

    @Test
    func theRealProcessListReadsOrReportsNoCall() async {
        // The list carries processes that have connected to coreaudiod. A test
        // host that has not touched audio yet would not be on it, so ask the HAL
        // for the output format first.
        let engine = AVAudioEngine()
        _ = engine.outputNode.outputFormat(forBus: 0)

        let probe = CoreAudioConferenceProcessProbe()
        let states: [ConferenceAudioProcessState]
        do {
            states = try await probe.readProcessStates()
        } catch {
            // macOS 14.2 and 14.3 have no process object list. The monitor must
            // report no call, and must not crash.
            let scheduler = TestConferenceAudioScheduler()
            let sut = ConferenceAudioMonitor(
                probe: probe,
                pollScheduler: scheduler.pollScheduler,
                processListObserver: scheduler.processListObserver
            )
            sut.start()
            await sut.refresh()
            #expect(sut.detectedCall == nil)
            sut.stop()
            return
        }

        // Which other apps are running is the machine's business, not the
        // test's. Only our own process is asserted.
        let ownBundleIdentifier = Bundle.main.bundleIdentifier
        #expect(ownBundleIdentifier != nil)
        #expect(states.contains { $0.bundleIdentifier == ownBundleIdentifier })
    }
}
