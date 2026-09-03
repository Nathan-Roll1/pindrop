//
//  ConferenceAudioMonitor.swift
//  Pindrop
//
//  Created on 2026-09-03.
//
//  Decides whether a conference call is in progress from audio process state.
//

import AudioToolbox
import CoreAudio
import Foundation
import PindropCore

// MARK: - Values

/// The conference call the monitor is currently reporting.
struct DetectedConferenceCall: Equatable, Sendable {
    /// The catalog app holding the microphone and the speakers at the same time.
    let bundleIdentifier: String
    /// When both flags first read true, not when the call was reported. The
    /// ten-second hold is a reporting delay, not part of the call.
    let startedAt: Date
}

// MARK: - Scheduling seams

/// A poll or a property listener the monitor can tear down.
protocol ConferenceAudioMonitorSession: AnyObject {
    func invalidate()
}

/// Asks the monitor to read the process list again.
typealias ConferenceAudioMonitorTick = @Sendable @MainActor () async -> Void

/// Starts a repeating poll. The monitor owns the returned session.
typealias ConferenceAudioPollScheduler =
    @MainActor (TimeInterval, @escaping ConferenceAudioMonitorTick) -> any ConferenceAudioMonitorSession

/// Watches the audio process list for processes appearing and disappearing.
///
/// The contract includes one tick at install time, so the monitor learns the
/// current list without a read of its own. That keeps `start()` free of a
/// detached task, which is what makes the monitor's tests deterministic.
typealias ConferenceAudioProcessListObserver =
    @MainActor (@escaping ConferenceAudioMonitorTick) -> any ConferenceAudioMonitorSession

// MARK: - Monitor

/// Reports when a conference call is in progress, from audio process state alone.
///
/// The rule: a catalog app holding **both** `isRunningInput` and
/// `isRunningOutput`, continuously, for ten seconds. Requiring the microphone is
/// what makes the browser entries in `ConferenceAppCatalog` safe.
///
/// The monitor is only ever started when system audio capture is available.
/// That is the single availability answer for the whole meeting feature: below
/// macOS 14.2 there is no call to record, and on 14.2 and 14.3 the process list
/// read simply fails, which this monitor reports as no call.
@MainActor
@Observable
final class ConferenceAudioMonitor {
    /// Both flags must hold this long before a call is reported.
    static let callConfirmationInterval: TimeInterval = 10
    /// The running flags change without changing the list, so a poll is the only
    /// way to see them. It runs only while a catalog app is in the list.
    static let pollInterval: TimeInterval = 5

    /// The call in progress, or nil.
    ///
    /// Audio process state is the only signal this phase has. A calendar source
    /// would attach here, as a second input to this same value, and it would
    /// bring permission state, a refresh cadence, and conference-link parsing
    /// with it. That is why there is no protocol for it yet: a seam shaped now
    /// would be the wrong shape then.
    private(set) var detectedCall: DetectedConferenceCall?

    /// True between `start()` and `stop()`. The Watch-for-calls setting owns this.
    private(set) var isWatching = false

    /// Called on every change of `detectedCall`, including back to nil.
    ///
    /// A list, not one slot: two surfaces follow a call, the menu bar rows and
    /// the invitation controller, and a single slot lets the second one silently
    /// replace the first.
    private var detectedCallObservers: [(DetectedConferenceCall?) -> Void] = []

    private let probe: any ConferenceAudioProcessProbe
    private let now: () -> Date
    private let pollScheduler: ConferenceAudioPollScheduler
    private let processListObserver: ConferenceAudioProcessListObserver

    private var pollSession: (any ConferenceAudioMonitorSession)?
    private var listSession: (any ConferenceAudioMonitorSession)?
    /// The catalog app holding both flags, with the time it first held them.
    private var candidate: DetectedConferenceCall?
    private var isRefreshing = false
    private var needsAnotherRefresh = false
    private var didLogReadFailure = false

    init(
        probe: any ConferenceAudioProcessProbe = CoreAudioConferenceProcessProbe(),
        now: @escaping () -> Date = Date.init,
        pollScheduler: @escaping ConferenceAudioPollScheduler = conferenceAudioDefaultPollScheduler,
        processListObserver: @escaping ConferenceAudioProcessListObserver =
            conferenceAudioDefaultProcessListObserver
    ) {
        self.probe = probe
        self.now = now
        self.pollScheduler = pollScheduler
        self.processListObserver = processListObserver
    }

    deinit {
        // Sessions release their framework resources in their own deinit.
        // `stop()` stays the explicit teardown path.
    }

    // MARK: Control

    /// Follows every change of `detectedCall`. Observers are never removed:
    /// each one lives as long as the app does.
    func addDetectedCallObserver(_ observer: @escaping (DetectedConferenceCall?) -> Void) {
        detectedCallObservers.append(observer)
    }

    func start() {
        guard !isWatching else { return }
        isWatching = true
        didLogReadFailure = false
        listSession = processListObserver { [weak self] in
            await self?.refresh()
        }
    }

    func stop() {
        guard isWatching else { return }
        isWatching = false
        setPolling(enabled: false)
        listSession?.invalidate()
        listSession = nil
        candidate = nil
        publish(nil)
    }

    /// Reads the process list now and applies the detection rule.
    ///
    /// Both seams call this, and tests call it directly to step time.
    func refresh() async {
        guard !isRefreshing else {
            // A tick that arrives during a read is not dropped, it is coalesced.
            needsAnotherRefresh = true
            return
        }
        isRefreshing = true
        defer { isRefreshing = false }
        repeat {
            needsAnotherRefresh = false
            await performRefresh()
        } while needsAnotherRefresh
    }

    // MARK: Detection

    private func performRefresh() async {
        guard isWatching else { return }

        let states: [ConferenceAudioProcessState]
        do {
            states = try await probe.readProcessStates()
        } catch {
            // macOS 14.2 and 14.3 have no process object list. A failed read is
            // no call detected: no crash, and no new availability axis.
            if !didLogReadFailure {
                didLogReadFailure = true
                Log.audio.debug(
                    "Conference detection: process list read failed (\(error)); reporting no call"
                )
            }
            setPolling(enabled: false)
            clearCandidate()
            return
        }

        // Ownership can be dropped across the read.
        guard isWatching else { return }

        let catalogStates = states.filter { ConferenceAppCatalog.contains($0.bundleIdentifier) }
        // No catalog app in the list means nothing to poll for. Idle cost is
        // then one property listener and no timer at all.
        setPolling(enabled: !catalogStates.isEmpty)

        let inCall = catalogStates.filter { $0.isRunningInput && $0.isRunningOutput }
        // Keep the standing candidate while it still holds both flags, so two
        // conference apps open at once cannot flap the reported identifier.
        let held = inCall.first { $0.bundleIdentifier == candidate?.bundleIdentifier } ?? inCall.first

        guard let held else {
            clearCandidate()
            return
        }

        let timestamp = now()
        let current: DetectedConferenceCall
        if let candidate, candidate.bundleIdentifier == held.bundleIdentifier {
            current = candidate
        } else {
            current = DetectedConferenceCall(
                bundleIdentifier: held.bundleIdentifier,
                startedAt: timestamp
            )
        }
        candidate = current

        let heldFor = timestamp.timeIntervalSince(current.startedAt)
        publish(heldFor >= Self.callConfirmationInterval ? current : nil)
    }

    private func clearCandidate() {
        candidate = nil
        publish(nil)
    }

    private func publish(_ call: DetectedConferenceCall?) {
        guard detectedCall != call else { return }
        detectedCall = call
        if let call {
            Log.audio.info("Conference call detected in \(call.bundleIdentifier)")
        }
        for observer in detectedCallObservers {
            observer(call)
        }
    }

    private func setPolling(enabled: Bool) {
        if enabled {
            guard pollSession == nil else { return }
            pollSession = pollScheduler(Self.pollInterval) { [weak self] in
                await self?.refresh()
            }
        } else {
            pollSession?.invalidate()
            pollSession = nil
        }
    }
}

// MARK: - Production seams

@MainActor
func conferenceAudioDefaultPollScheduler(
    interval: TimeInterval,
    tick: @escaping ConferenceAudioMonitorTick
) -> any ConferenceAudioMonitorSession {
    ConferenceAudioTimerSession(interval: interval, tick: tick)
}

@MainActor
func conferenceAudioDefaultProcessListObserver(
    tick: @escaping ConferenceAudioMonitorTick
) -> any ConferenceAudioMonitorSession {
    ConferenceAudioProcessListSession(tick: tick)
}

private final class ConferenceAudioTimerSession: ConferenceAudioMonitorSession {
    private var timer: Timer?

    @MainActor
    init(interval: TimeInterval, tick: @escaping ConferenceAudioMonitorTick) {
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { _ in
            Task { @MainActor in await tick() }
        }
    }

    deinit {
        timer?.invalidate()
    }

    func invalidate() {
        timer?.invalidate()
        timer = nil
    }
}

/// A property listener on `kAudioHardwarePropertyProcessObjectList`.
///
/// The listener block runs on its own queue, never on the main actor, because
/// the HAL delivers it from `coreaudiod`'s reply path.
private final class ConferenceAudioProcessListSession:
    ConferenceAudioMonitorSession, @unchecked Sendable {
    private let listenerQueue = DispatchQueue(label: "tech.watzon.pindrop.conference-process-list")
    private let lock = NSLock()
    private var listenerBlock: AudioObjectPropertyListenerBlock?

    /// Computed, not stored: `AudioObjectGetPropertyData` and friends take the
    /// address `inout`, so each call needs its own copy.
    private static var address: AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
    }

    @MainActor
    init(tick: @escaping ConferenceAudioMonitorTick) {
        let block: AudioObjectPropertyListenerBlock = { _, _ in
            Task { @MainActor in await tick() }
        }
        var address = Self.address
        let status = AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            listenerQueue,
            block
        )
        if status == noErr {
            lock.withLock { listenerBlock = block }
        } else {
            // 14.2 and 14.3 refuse this property. The read fails the same way,
            // and the monitor already reports that as no call.
            Log.audio.debug("Conference detection: no process list listener (status=\(status))")
        }
        // The install-time read, so the monitor sees a call that started before
        // the setting was turned on.
        Task { @MainActor in await tick() }
    }

    deinit {
        removeListener()
    }

    func invalidate() {
        removeListener()
    }

    private func removeListener() {
        let block = lock.withLock { () -> AudioObjectPropertyListenerBlock? in
            defer { listenerBlock = nil }
            return listenerBlock
        }
        guard let block else { return }
        var address = Self.address
        AudioObjectRemovePropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            listenerQueue,
            block
        )
    }
}
