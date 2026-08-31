//
//  LivePartialLatencyMonitorTests.swift
//  PindropTests
//
//  Created on 2026-08-31.
//
//  The runtime kill switch for live speaker labels.
//
//  This is the risk section 4.8 calls the one that actually matters: two CoreML
//  models sharing the Neural Engine can push partials behind real time, and a
//  late transcript costs a reader more than a missing label does. The arithmetic
//  below decides when labels are given up, so it is asserted directly rather
//  than through a capture.
//

import Foundation
import Testing
@testable import Pindrop

@Suite
struct LivePartialLatencyMonitorTests {

    /// One synthetic clock, so a window costs no wall time.
    private func fillWindow(
        _ sut: inout LivePartialLatencyMonitor,
        staleness: TimeInterval,
        samples: Int,
        from start: TimeInterval
    ) -> LivePartialLatencyMonitor.Outcome {
        var outcome = LivePartialLatencyMonitor.Outcome.measuring
        for index in 0..<samples {
            // The last arrival lands past the window's end and closes it.
            let isLast = index == samples - 1
            let wallTime = start
                + (isLast ? LivePartialLatencyMonitor.windowSeconds : TimeInterval(index))
            outcome = sut.record(staleness: staleness, at: wallTime)
        }
        return outcome
    }

    @Test func anOpenWindowReportsNothing() {
        var sut = LivePartialLatencyMonitor()
        #expect(sut.record(staleness: 9, at: 0) == .measuring)
        #expect(sut.record(staleness: 9, at: 1) == .measuring)
        #expect(sut.record(staleness: 9, at: 2) == .measuring)
    }

    /// Silence says nothing about a percentile: no partials arrive while nobody
    /// talks, and a window of one late arrival is not evidence of a regression.
    @Test func aWindowWithTooFewPartialsIsNotJudged() {
        var sut = LivePartialLatencyMonitor()
        let outcome = fillWindow(
            &sut,
            staleness: 9,
            samples: LivePartialLatencyMonitor.minimumSamplesPerWindow - 1,
            from: 0
        )
        #expect(outcome == .measuring)
    }

    @Test func aWindowInsideTheBudgetReportsHealthy() {
        var sut = LivePartialLatencyMonitor()
        let outcome = fillWindow(&sut, staleness: 0.4, samples: 8, from: 0)
        #expect(outcome == .healthy)
    }

    /// Three in a row, not two: one contended window is a hiccup, and giving up
    /// the labels is not reversible inside a capture.
    @Test func threeConsecutiveOverBudgetWindowsFireTheSwitch() {
        var sut = LivePartialLatencyMonitor()
        let over = LivePartialLatencyMonitor.budgetSeconds + 1
        var start: TimeInterval = 0

        #expect(fillWindow(&sut, staleness: over, samples: 8, from: start) == .overBudget)
        start += LivePartialLatencyMonitor.windowSeconds
        #expect(fillWindow(&sut, staleness: over, samples: 8, from: start) == .overBudget)
        start += LivePartialLatencyMonitor.windowSeconds
        #expect(fillWindow(&sut, staleness: over, samples: 8, from: start) == .limitReached)
    }

    @Test func aHealthyWindowClearsTheConsecutiveCount() {
        var sut = LivePartialLatencyMonitor()
        let over = LivePartialLatencyMonitor.budgetSeconds + 1
        var start: TimeInterval = 0

        #expect(fillWindow(&sut, staleness: over, samples: 8, from: start) == .overBudget)
        start += LivePartialLatencyMonitor.windowSeconds
        #expect(fillWindow(&sut, staleness: over, samples: 8, from: start) == .overBudget)
        start += LivePartialLatencyMonitor.windowSeconds
        #expect(fillWindow(&sut, staleness: 0.2, samples: 8, from: start) == .healthy)
        start += LivePartialLatencyMonitor.windowSeconds
        // The count restarted, so this over-budget window is the first again.
        #expect(fillWindow(&sut, staleness: over, samples: 8, from: start) == .overBudget)
    }

    /// A handover is not evidence that the engine caught up, so the open window
    /// goes and the consecutive count stays.
    @Test func resetDropsTheOpenWindowAndKeepsTheCount() {
        var sut = LivePartialLatencyMonitor()
        let over = LivePartialLatencyMonitor.budgetSeconds + 1
        var start: TimeInterval = 0

        #expect(fillWindow(&sut, staleness: over, samples: 8, from: start) == .overBudget)
        start += LivePartialLatencyMonitor.windowSeconds
        #expect(fillWindow(&sut, staleness: over, samples: 8, from: start) == .overBudget)

        sut.reset()
        start += LivePartialLatencyMonitor.windowSeconds
        #expect(fillWindow(&sut, staleness: over, samples: 8, from: start) == .limitReached)
    }

    /// The percentile is taken over the whole window, so one stall among many
    /// healthy arrivals must not close a window over budget on its own.
    @Test func oneStallInAHealthyWindowDoesNotCloseItOverBudget() {
        var sut = LivePartialLatencyMonitor()
        for index in 0..<40 {
            let staleness: TimeInterval = index == 7
                ? LivePartialLatencyMonitor.budgetSeconds + 3
                : 0.3
            let outcome = sut.record(staleness: staleness, at: TimeInterval(index) * 0.4)
            if index < 39 { #expect(outcome != .limitReached) }
        }
        let closing = sut.record(
            staleness: 0.3,
            at: LivePartialLatencyMonitor.windowSeconds + 1
        )
        #expect(closing == .healthy)
    }
}
