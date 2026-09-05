//
//  MockConferenceAudioProcessProbe.swift
//  PindropTests
//
//  Created on 2026-09-03.
//

import CoreAudio
import Foundation

@testable import Pindrop

/// A scripted audio process list, so the monitor's rules can be tested without
/// depending on whatever the test machine happens to be running.
final class MockConferenceAudioProcessProbe: ConferenceAudioProcessProbe, @unchecked Sendable {
    private let lock = NSLock()
    private var states: [ConferenceAudioProcessState] = []
    private var failureStatus: OSStatus?
    private var reads = 0
    private var lastRequestedBundleIdentifiers: Set<String> = []

    init(states: [ConferenceAudioProcessState] = []) {
        self.states = states
    }

    var readCount: Int {
        lock.withLock { reads }
    }

    func setStates(_ states: [ConferenceAudioProcessState]) {
        lock.withLock {
            self.states = states
            self.failureStatus = nil
        }
    }

    /// Every later read throws, the way macOS 14.2 and 14.3 answer.
    func failReads(status: OSStatus = OSStatus(kAudioHardwareUnknownPropertyError)) {
        lock.withLock { failureStatus = status }
    }

    /// What the monitor last passed as its read hint.
    var requestedBundleIdentifiers: Set<String> {
        lock.withLock { lastRequestedBundleIdentifiers }
    }

    /// The hint is deliberately ignored: the monitor still owns the catalog
    /// rule, and a double that filtered here would test itself instead.
    func readProcessStates(
        matching bundleIdentifiers: Set<String>
    ) async throws -> [ConferenceAudioProcessState] {
        let (failureStatus, states) = lock.withLock { () -> (OSStatus?, [ConferenceAudioProcessState]) in
            reads += 1
            lastRequestedBundleIdentifiers = bundleIdentifiers
            return (self.failureStatus, self.states)
        }
        if let failureStatus {
            throw ConferenceAudioProcessReadError(status: failureStatus)
        }
        return states
    }
}

/// Builds one process state. Defaults are the harmless case: present, silent.
func conferenceProcess(
    _ bundleIdentifier: String,
    input: Bool = false,
    output: Bool = false
) -> ConferenceAudioProcessState {
    ConferenceAudioProcessState(
        bundleIdentifier: bundleIdentifier,
        isRunningInput: input,
        isRunningOutput: output
    )
}

/// A poll and a process-list observer the test drives by hand.
@MainActor
final class TestConferenceAudioScheduler {
    final class Session: ConferenceAudioMonitorSession {
        private(set) var isInvalidated = false
        func invalidate() { isInvalidated = true }
    }

    private(set) var pollSessions: [Session] = []
    private(set) var listSessions: [Session] = []
    private(set) var pollInterval: TimeInterval?
    private var pollTick: ConferenceAudioMonitorTick?
    private var listTick: ConferenceAudioMonitorTick?

    /// Poll timers currently alive.
    var activePollCount: Int {
        pollSessions.filter { !$0.isInvalidated }.count
    }

    var pollScheduler: ConferenceAudioPollScheduler {
        { [weak self] interval, tick in
            guard let self else { return Session() }
            self.pollInterval = interval
            self.pollTick = tick
            let session = Session()
            self.pollSessions.append(session)
            return session
        }
    }

    var processListObserver: ConferenceAudioProcessListObserver {
        { [weak self] tick in
            guard let self else { return Session() }
            self.listTick = tick
            let session = Session()
            self.listSessions.append(session)
            return session
        }
    }

    /// Fires the poll if one is running, otherwise the list observer. Either way
    /// the monitor reads the probe once, which is all a test needs to step time.
    func tick() async {
        if activePollCount > 0, let pollTick {
            await pollTick()
        } else if let listTick {
            await listTick()
        }
    }
}
