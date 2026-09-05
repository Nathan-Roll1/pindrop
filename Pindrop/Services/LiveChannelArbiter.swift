//
//  LiveChannelArbiter.swift
//  Pindrop
//
//  Created on 2026-08-31.
//
//  Which capture channel owns the one live streaming engine, decided per
//  buffer on the capture thread.
//
//  The app runs a single streaming engine. Splicing a second channel into a
//  partly filled decode chunk puts two voices inside one decoded string, and no
//  clock can separate them afterwards, so ownership is exclusive and a handover
//  is only ever announced here. The consumer applies it at a boundary the
//  engine itself produced.
//

import Accelerate
import Foundation
import PindropCore
import PindropSpeech

/// How many short-term RMS values one channel keeps. At the fastest tap cadence
/// this still spans well over the correlation window plus its lag ceiling.
private let envelopeHistoryCapacity = 256

// MARK: - Speaker gate

/// Speech detection for one capture channel.
///
/// A seam, not a hardware boundary: it exists so a single-source capture can be
/// tested for never consulting a gate at all.
protocol LiveSpeechGating: AnyObject {
    /// Advances this channel's noise floor by `timeStep` and reports whether
    /// `rms` reads as speech against it.
    @discardableResult
    func update(rms: Float, timeStep: TimeInterval) -> Bool

    /// The last answer `update` gave.
    var isSpeaking: Bool { get }

    func reset()
}

/// Speech detection against one channel's own adaptive noise floor.
///
/// A fixed absolute floor cannot work here. Microphone level depends on device
/// gain, system-audio level depends on app volume, and a conference call's far
/// end streams continuous room tone that never drops below any fixed floor. One
/// constant cannot mean the same thing on both channels, and with a fixed floor
/// the system channel would take the engine on its first frame and never
/// release it.
///
/// The floor is a slow running minimum of short-term RMS: it follows the signal
/// down fast, so a new quiet is conceded within `floorAttackSeconds`, and it
/// creeps up slowly, so sustained noise stops counting as speech after about
/// `floorReleaseSeconds`. Speech is RMS above that floor by `speechMarginDB`.
///
/// Instances are not thread safe. The arbiter owns them and only ever touches
/// them under its own lock.
final class LiveSpeakerGate: LiveSpeechGating {
    /// Digital silence would make every ratio infinite. The floor never reads
    /// below this, which is far under any real capture's noise.
    static let minimumFloor: Float = 1e-5

    private let marginRatio: Float
    private let attackSeconds: TimeInterval
    private let releaseSeconds: TimeInterval

    /// Nil until the first buffer. Seeding the floor with the first RMS is what
    /// keeps a capture that starts inside continuous media from reading that
    /// media as speech.
    private var floor: Float?

    private(set) var isSpeaking = false

    init(
        speechMarginDB: Float = LiveChannelArbiter.speechMarginDB,
        floorAttackSeconds: TimeInterval = LiveChannelArbiter.floorAttackSeconds,
        floorReleaseSeconds: TimeInterval = LiveChannelArbiter.floorReleaseSeconds
    ) {
        marginRatio = pow(10, speechMarginDB / 20)
        attackSeconds = floorAttackSeconds
        releaseSeconds = floorReleaseSeconds
    }

    @discardableResult
    func update(rms: Float, timeStep: TimeInterval) -> Bool {
        let level = max(rms, Self.minimumFloor)
        guard let reference = floor else {
            floor = level
            isSpeaking = false
            return false
        }

        // Decided against the floor this channel had before the buffer, then the
        // floor moves. Deciding against the updated floor would let a long
        // steady burst partly hide inside its own floor rise.
        isSpeaking = level >= reference * marginRatio

        let tau = level < reference ? attackSeconds : releaseSeconds
        let step = max(0, timeStep)
        let coefficient = tau > 0 ? Float(1 - exp(-step / tau)) : 1
        floor = max(Self.minimumFloor, reference + (level - reference) * coefficient)
        return isSpeaking
    }

    func reset() {
        floor = nil
        isSpeaking = false
    }
}

// MARK: - Arbiter results

/// What the arbiter says about one capture buffer.
enum LiveChannelDecision: Equatable {
    /// This channel owns the engine. Feed the buffer.
    case forward
    /// Another channel owns the engine. The durable spool still has this audio
    /// and the offline pass at finalize still transcribes it.
    case drop
    /// Ownership just moved. The consumer holds this pending and applies it at
    /// the next boundary the engine produced, or force-flushes at
    /// `handoverCeilingSeconds`. The buffer that carried this decision belongs
    /// to the incoming channel and is forwarded.
    case handoverPending(to: CaptureSourceKind)
}

/// Speech the live engine never heard, because the other channel owned it.
///
/// Times are capture time: seconds since the capture's first audio buffer.
struct LiveDroppedSpeechInterval: Equatable {
    let source: CaptureSourceKind
    let startCaptureTime: TimeInterval
    let duration: TimeInterval
}

// MARK: - Arbiter

/// Exclusive ownership of the one live streaming engine, decided per buffer.
///
/// Every rule reads the speaker gates. No rule reads a raw level, because no
/// single absolute level means the same thing on both channels.
///
/// Locking: this type keeps its own lock over scalar state only. It never takes
/// a capture backend's state lock, which is also held from the main actor
/// during teardown, and a realtime IO thread blocking behind main-actor
/// teardown is a dropout. Nothing here logs or allocates per buffer for the
/// same reason: the consumer logs handovers from the pump instead.
final class LiveChannelArbiter: @unchecked Sendable {

    // MARK: Constants

    /// How far above a channel's own tracked noise floor counts as speech.
    static let speechMarginDB: Float = 9
    /// How fast each channel's noise floor follows the signal down and back up.
    static let floorAttackSeconds: TimeInterval = 0.20
    static let floorReleaseSeconds: TimeInterval = 3.00

    static let holdWindow: TimeInterval = 0.60
    static let releaseWindow: TimeInterval = 0.50
    static let claimWindow: TimeInterval = 0.25

    /// Never hand over inside one ASR chunk. Derived from the active profile,
    /// not guessed: 1.52 s at `.standard`, 0.96 s at `.lowLatency`.
    ///
    /// This also caps the handover rate at one per 1.52 s at `.standard`, so the
    /// worst-case forced-flush cost is under one chunk of silence per 1.5 s, and
    /// it is paid only when no natural boundary arrived. An unbounded pad rate
    /// would let the live stream's bounded ring drop real speech.
    static func minimumOwnershipSeconds(for profile: StreamingChunkProfile) -> TimeInterval {
        profile.nemotronChunkSeconds + 0.40
    }

    /// How long a pending handover waits for a natural engine boundary before
    /// the consumer force-flushes a partial chunk of silence.
    static let handoverCeilingSeconds: TimeInterval = 3.00

    /// The microphone may not claim the engine while it is hearing the speakers.
    static let echoCorrelationCeiling: Float = 0.55
    static let micDominanceMarginDB: Float = 6

    /// Unowned speech longer than this is reported as a visible gap.
    static let droppedSpeechSeconds: TimeInterval = 1.00
    /// Dropped intervals closer together than this are one marker, so a long
    /// overlap does not draw a wall of them.
    static let droppedSpeechCoalesceGap: TimeInterval = 2.00

    /// Two mic-only runs separated by no more than this much shared silence are
    /// one range: the breath between two sentences is not a change of who is
    /// talking. A coalesce never bridges an interval where the system gate was
    /// open, whatever this is set to, because that interval is exactly what a
    /// mic-only range has to exclude.
    static let micOnlyCoalesceGap: TimeInterval = 1.00
    /// Mic-only runs shorter than this are not recorded. A gate blip on one
    /// buffer carries no evidence about who owns the microphone.
    static let micOnlySeconds: TimeInterval = 0.35

    /// The echo correlation reads the two channels' recent RMS envelopes over
    /// this much history, and takes the best match across this lag window. The
    /// lag covers the acoustic path from the speakers back into the microphone.
    static let echoWindowSeconds: TimeInterval = 0.50
    static let echoLagCeilingSeconds: TimeInterval = 0.100
    /// Both envelopes are read onto one fixed grid, so the correlation does not
    /// depend on either channel's buffer cadence and a lag is an integer step.
    static let echoGridStep: TimeInterval = 0.010

    /// Every constant above, injectable as one value so a test can move one
    /// without restating the rest.
    struct Tuning {
        var speechMarginDB = LiveChannelArbiter.speechMarginDB
        var floorAttackSeconds = LiveChannelArbiter.floorAttackSeconds
        var floorReleaseSeconds = LiveChannelArbiter.floorReleaseSeconds
        var holdWindow = LiveChannelArbiter.holdWindow
        var releaseWindow = LiveChannelArbiter.releaseWindow
        var claimWindow = LiveChannelArbiter.claimWindow
        var handoverCeilingSeconds = LiveChannelArbiter.handoverCeilingSeconds
        var echoCorrelationCeiling = LiveChannelArbiter.echoCorrelationCeiling
        var micDominanceMarginDB = LiveChannelArbiter.micDominanceMarginDB
        var droppedSpeechSeconds = LiveChannelArbiter.droppedSpeechSeconds
        var droppedSpeechCoalesceGap = LiveChannelArbiter.droppedSpeechCoalesceGap
        var micOnlyCoalesceGap = LiveChannelArbiter.micOnlyCoalesceGap
        var micOnlySeconds = LiveChannelArbiter.micOnlySeconds

        init() {}
    }

    // MARK: State

    private final class ChannelState {
        let gate: LiveSpeechGating
        var envelope = EnvelopeHistory()
        var lastCaptureTime: TimeInterval?
        /// When the gate last opened, cleared the moment it shuts.
        var gateOpenSince: TimeInterval?
        var lastSpeechTime: TimeInterval?

        init(gate: LiveSpeechGating) {
            self.gate = gate
        }
    }

    private struct OpenDroppedRun {
        var source: CaptureSourceKind
        var start: TimeInterval
        var end: TimeInterval
    }

    private let sources: Set<CaptureSourceKind>
    private let tuning: Tuning
    private let minimumOwnership: TimeInterval
    private let dominanceRatio: Float

    private let lock = NSLock()
    private let microphone: ChannelState
    private let systemAudio: ChannelState

    private var owner: CaptureSourceKind?
    private var ownershipStart: TimeInterval = 0
    private var pending: (to: CaptureSourceKind, since: TimeInterval)?

    private var openDroppedRun: OpenDroppedRun?
    private var settledDropped: [LiveDroppedSpeechInterval] = []

    private var openMicOnlyRun: (start: TimeInterval, end: TimeInterval)?
    private var settledMicOnly: [MicOnlyRange] = []

    /// Grid scratch, reused so a claim evaluation allocates nothing on the
    /// capture thread. Only ever touched under `lock`.
    private var microphoneGrid: [Float]
    private var systemAudioGrid: [Float]
    private var centeredLeft: [Float]
    private var centeredRight: [Float]

    /// True when more than one channel can reach the engine. A capture with one
    /// channel needs no gate, no echo check, and no arbitration at all.
    private var isArbitrated: Bool { sources.count > 1 }

    init(
        sources: Set<CaptureSourceKind>,
        chunkProfile: StreamingChunkProfile,
        tuning: Tuning = Tuning(),
        makeGate: (CaptureSourceKind) -> LiveSpeechGating = { _ in LiveSpeakerGate() }
    ) {
        self.sources = sources
        self.tuning = tuning
        minimumOwnership = Self.minimumOwnershipSeconds(for: chunkProfile)
        dominanceRatio = pow(10, tuning.micDominanceMarginDB / 20)

        if sources.count > 1 {
            microphone = ChannelState(gate: makeGate(.microphone))
            systemAudio = ChannelState(gate: makeGate(.systemAudio))
        } else {
            // A single-source capture never reads these, and building real gates
            // for them would be the one thing a gate-free path must not do.
            microphone = ChannelState(gate: NeverConsultedGate())
            systemAudio = ChannelState(gate: NeverConsultedGate())
        }

        let gridPoints = Int((Self.echoWindowSeconds / Self.echoGridStep).rounded(.up)) + 1
        let lagPoints = Int((Self.echoLagCeilingSeconds / Self.echoGridStep).rounded())
        microphoneGrid = [Float](repeating: 0, count: gridPoints)
        systemAudioGrid = [Float](repeating: 0, count: gridPoints + lagPoints)
        centeredLeft = [Float](repeating: 0, count: gridPoints)
        centeredRight = [Float](repeating: 0, count: gridPoints)

        // Rule 1: with one channel it owns the engine for the whole session, so
        // the consumer can read the speaker before a single buffer arrives.
        owner = sources.count == 1 ? sources.first : nil
    }

    // MARK: Reading state

    /// Every channel that can reach the engine in this capture. Fixed for the
    /// life of the arbiter, so it needs no lock.
    var liveSources: Set<CaptureSourceKind> { sources }

    /// The channel that owns the engine right now, nil before anyone has spoken.
    var currentOwner: CaptureSourceKind? {
        lock.withLock { owner }
    }

    /// The handover the consumer has not applied yet.
    var pendingHandover: CaptureSourceKind? {
        lock.withLock { pending?.to }
    }

    // MARK: Admitting buffers

    /// The one capture-thread entry point.
    ///
    /// `rms` is this buffer's short-term RMS and `captureTime` is seconds since
    /// the capture's first audio buffer. Both are computed by the caller outside
    /// every lock.
    func admit(
        source: CaptureSourceKind,
        rms: Float,
        captureTime: TimeInterval
    ) -> LiveChannelDecision {
        // Rule 1: one channel owns the engine for the whole session.
        guard isArbitrated else {
            return sources.contains(source) ? .forward : .drop
        }

        return lock.withLock {
            let state = channel(source)
            let timeStep = state.lastCaptureTime.map { captureTime - $0 } ?? 0
            let isSpeech = state.gate.update(rms: rms, timeStep: timeStep)
            state.lastCaptureTime = captureTime
            state.envelope.append(rms, at: captureTime)

            if isSpeech {
                if state.gateOpenSince == nil { state.gateOpenSince = captureTime }
                state.lastSpeechTime = captureTime
            } else {
                state.gateOpenSince = nil
            }

            settleDroppedRunLocked(now: captureTime)
            accrueMicOnlyRunLocked(now: captureTime)

            if owner == source { return .forward }

            if owner == nil {
                if isSpeech, canClaimUnownedLocked(source, now: captureTime) {
                    owner = source
                    ownershipStart = captureTime
                    return .forward
                }
            } else if canTakeOverLocked(challenger: source, now: captureTime) {
                owner = source
                ownershipStart = captureTime
                pending = (to: source, since: captureTime)
                return .handoverPending(to: source)
            }

            // Rule 5: during cross talk the current owner keeps the engine.
            // Flapping mid-sentence produces worse text than losing an
            // interjection, so the loss is recorded instead of avoided.
            if isSpeech { accrueDroppedRunLocked(source: source, now: captureTime) }
            return .drop
        }
    }

    /// Rule 2: ownership starts unowned and the first channel whose gate opens
    /// takes it. Returns true when this channel may have it.
    ///
    /// When both gates open in the same buffer system audio wins, because a
    /// remote voice is the harder loss. That falls out of the two claims rather
    /// than needing a tie-break: the system channel claims the instant its gate
    /// opens, and a microphone claim waits for the claim window and both echo
    /// checks first.
    private func canClaimUnownedLocked(_ source: CaptureSourceKind, now: TimeInterval) -> Bool {
        switch source {
        case .systemAudio: true
        case .microphone: microphoneClaimSurvivesLocked(now: now)
        }
    }

    /// Rule 4: every condition a challenger has to meet, in one place.
    private func canTakeOverLocked(challenger: CaptureSourceKind, now: TimeInterval) -> Bool {
        // One handover at a time. A second one before the consumer applied the
        // first would put two channel changes behind one engine boundary.
        guard pending == nil else { return false }
        guard let currentOwner = owner, currentOwner != challenger else { return false }

        let ownerState = channel(currentOwner)
        guard !ownerState.gate.isSpeaking else { return false }
        guard let ownerLastSpeech = ownerState.lastSpeechTime else { return false }

        // Rule 3 holds the engine through `holdWindow`, rule 4 asks for
        // `releaseWindow` of quiet. Both are checked because both are
        // independently injectable.
        let ownerQuietFor = now - ownerLastSpeech
        guard ownerQuietFor >= tuning.holdWindow, ownerQuietFor >= tuning.releaseWindow else {
            return false
        }
        guard now - ownershipStart >= minimumOwnership else { return false }

        let challengerState = channel(challenger)
        guard let openSince = challengerState.gateOpenSince,
              now - openSince >= tuning.claimWindow else { return false }

        guard challenger == .microphone else { return true }
        return microphoneClaimSurvivesLocked(now: now)
    }

    // MARK: The echo gate

    /// Both echo checks. The microphone hears the speakers on the common meeting
    /// setup, and there is no echo cancellation anywhere in the tree, so without
    /// this the arbiter prints the other person's words under the header `You`.
    ///
    /// The window is the challenger's open run, capped at `echoWindowSeconds`.
    /// Reading a fixed half second would drag the silence before the run into
    /// the estimate, where the onset step alone decides the answer.
    private func microphoneClaimSurvivesLocked(now: TimeInterval) -> Bool {
        guard let openSince = microphone.gateOpenSince else { return false }
        let openFor = now - openSince
        // Sustained for the whole claim window, so a claim is never granted on
        // one loud buffer.
        guard openFor >= tuning.claimWindow else { return false }

        // The system channel has produced no audio at all, so there is nothing
        // for the microphone to be hearing.
        guard systemAudio.envelope.isPopulated else { return true }

        let windowSeconds = min(Self.echoWindowSeconds, openFor)
        let pointCount = min(microphoneGrid.count, max(2, Int(windowSeconds / Self.echoGridStep) + 1))
        let lagPoints = systemAudioGrid.count - microphoneGrid.count

        guard fillGridsLocked(now: now, pointCount: pointCount, lagPoints: lagPoints) else {
            return false
        }

        guard microphoneDominatesLocked(pointCount: pointCount, lagPoints: lagPoints) else {
            return false
        }
        let correlation = echoCorrelationLocked(pointCount: pointCount, lagPoints: lagPoints)
        return correlation < tuning.echoCorrelationCeiling
    }

    /// Reads both envelopes onto the shared grid. The system grid reaches
    /// `lagPoints` further back so every lag can be read without resampling.
    private func fillGridsLocked(now: TimeInterval, pointCount: Int, lagPoints: Int) -> Bool {
        guard microphone.envelope.isPopulated, systemAudio.envelope.isPopulated else { return false }
        microphone.envelope.sample(
            into: &microphoneGrid,
            count: pointCount,
            endingAt: now,
            step: Self.echoGridStep
        )
        systemAudio.envelope.sample(
            into: &systemAudioGrid,
            count: pointCount + lagPoints,
            endingAt: now,
            step: Self.echoGridStep
        )
        return true
    }

    /// Microphone RMS above system-audio RMS by `micDominanceMarginDB`,
    /// sustained for the whole claim window.
    private func microphoneDominatesLocked(pointCount: Int, lagPoints: Int) -> Bool {
        let claimPoints = min(pointCount, max(1, Int(tuning.claimWindow / Self.echoGridStep)))
        for index in (pointCount - claimPoints)..<pointCount {
            let systemLevel = max(systemAudioGrid[index + lagPoints], LiveSpeakerGate.minimumFloor)
            if microphoneGrid[index] < systemLevel * dominanceRatio { return false }
        }
        return true
    }

    /// Normalized cross-correlation of the two envelopes, taken at its best lag
    /// from 0 to `echoLagCeilingSeconds`.
    ///
    /// Means are removed first. RMS envelopes are strictly positive, so an
    /// uncentred correlation reads near 1.0 for any two channels and would deny
    /// every microphone claim. A channel with no variance across the window
    /// carries no evidence either way and scores 0.
    private func echoCorrelationLocked(pointCount: Int, lagPoints: Int) -> Float {
        var best: Float = 0
        microphoneGrid.withUnsafeBufferPointer { microphonePoints in
            systemAudioGrid.withUnsafeBufferPointer { systemPoints in
                centeredLeft.withUnsafeMutableBufferPointer { left in
                    centeredRight.withUnsafeMutableBufferPointer { right in
                        guard let microphoneBase = microphonePoints.baseAddress,
                              let systemBase = systemPoints.baseAddress,
                              let leftBase = left.baseAddress,
                              let rightBase = right.baseAddress else { return }
                        let count = vDSP_Length(pointCount)
                        centre(microphoneBase, into: leftBase, count: count)
                        for lag in 0...lagPoints {
                            centre(systemBase + (lagPoints - lag), into: rightBase, count: count)
                            var dot: Float = 0
                            var leftEnergy: Float = 0
                            var rightEnergy: Float = 0
                            vDSP_dotpr(leftBase, 1, rightBase, 1, &dot, count)
                            vDSP_svesq(leftBase, 1, &leftEnergy, count)
                            vDSP_svesq(rightBase, 1, &rightEnergy, count)
                            let scale = (leftEnergy * rightEnergy).squareRoot()
                            guard scale > .leastNormalMagnitude else { continue }
                            best = max(best, dot / scale)
                        }
                    }
                }
            }
        }
        return best.isFinite ? best : 0
    }

    private func centre(
        _ values: UnsafePointer<Float>,
        into destination: UnsafeMutablePointer<Float>,
        count: vDSP_Length
    ) {
        var mean: Float = 0
        vDSP_meanv(values, 1, &mean, count)
        var negatedMean = -mean
        vDSP_vsadd(values, 1, &negatedMean, destination, 1, count)
    }

    // MARK: Dropped speech

    /// Speech the live engine never heard, settled and ready to draw.
    ///
    /// An interval settles once its channel has been quiet for
    /// `droppedSpeechCoalesceGap`, which is what makes a long overlap one
    /// marker instead of a wall of them.
    func takeDroppedSpeechIntervals() -> [LiveDroppedSpeechInterval] {
        lock.withLock {
            let intervals = settledDropped
            settledDropped.removeAll(keepingCapacity: true)
            return intervals
        }
    }

    /// Everything dropped, including a run still open. For the stop sequence,
    /// where nothing more will arrive to settle it.
    func flushDroppedSpeech() -> [LiveDroppedSpeechInterval] {
        lock.withLock {
            if let run = openDroppedRun {
                recordDroppedRunLocked(run)
                openDroppedRun = nil
            }
            let intervals = settledDropped
            settledDropped.removeAll(keepingCapacity: true)
            return intervals
        }
    }

    private func accrueDroppedRunLocked(source: CaptureSourceKind, now: TimeInterval) {
        if var run = openDroppedRun,
           run.source == source,
           now - run.end < tuning.droppedSpeechCoalesceGap {
            run.end = now
            openDroppedRun = run
            return
        }
        if let run = openDroppedRun { recordDroppedRunLocked(run) }
        openDroppedRun = OpenDroppedRun(source: source, start: now, end: now)
    }

    private func settleDroppedRunLocked(now: TimeInterval) {
        guard let run = openDroppedRun, now - run.end >= tuning.droppedSpeechCoalesceGap else {
            return
        }
        recordDroppedRunLocked(run)
        openDroppedRun = nil
    }

    private func recordDroppedRunLocked(_ run: OpenDroppedRun) {
        let duration = run.end - run.start
        guard duration >= tuning.droppedSpeechSeconds else { return }
        settledDropped.append(
            LiveDroppedSpeechInterval(
                source: run.source,
                startCaptureTime: run.start,
                duration: duration
            )
        )
    }

    // MARK: Mic-only ranges

    /// Where the microphone gate was open and the system gate was shut, in
    /// capture time.
    ///
    /// The same pair of signals the echo gate reads, so this costs the capture
    /// path nothing beyond two comparisons, and it excludes the intervals where
    /// the microphone is hearing the speakers. Finalization writes these into
    /// the note's diarization payload: the offline pass has strictly less
    /// information than the microphone channel has here, and a cluster that
    /// mostly lands inside these ranges is the person recording, with no
    /// profile match needed.
    ///
    /// Reading is not draining. Finalization runs once, after the capture is
    /// over, and a second reader must see the same answer.
    func micOnlyRanges() -> [MicOnlyRange] {
        lock.withLock {
            var ranges = settledMicOnly
            if let run = openMicOnlyRun, run.end - run.start >= tuning.micOnlySeconds {
                ranges.append(MicOnlyRange(startTime: run.start, endTime: run.end))
            }
            return ranges
        }
    }

    /// Reached only from the arbitrated path of `admit`. A single-source capture
    /// consults no gate and so records no ranges, which is right: nothing else
    /// was recorded, and the note view names its one speaker without them.
    private func accrueMicOnlyRunLocked(now: TimeInterval) {
        guard microphone.gate.isSpeaking, !systemAudio.gate.isSpeaking else {
            if systemAudio.gate.isSpeaking {
                // The far end is talking. The run ends here and the next one
                // starts fresh: coalescing across this would claim the far
                // end's speech for the person recording, which is the one
                // mistake these ranges exist to prevent.
                closeMicOnlyRunLocked()
            } else if let run = openMicOnlyRun, now - run.end >= tuning.micOnlyCoalesceGap {
                closeMicOnlyRunLocked()
            }
            return
        }

        if var run = openMicOnlyRun, now - run.end < tuning.micOnlyCoalesceGap {
            run.end = now
            openMicOnlyRun = run
            return
        }
        closeMicOnlyRunLocked()
        openMicOnlyRun = (start: now, end: now)
    }

    private func closeMicOnlyRunLocked() {
        guard let run = openMicOnlyRun else { return }
        openMicOnlyRun = nil
        guard run.end - run.start >= tuning.micOnlySeconds else { return }
        settledMicOnly.append(MicOnlyRange(startTime: run.start, endTime: run.end))
    }

    // MARK: Handovers

    /// Called by the consumer at the engine boundary it applied the handover at.
    /// Returns the incoming channel once, then nil: the consumer cannot double
    /// apply one channel change.
    @discardableResult
    func applyPendingHandover() -> CaptureSourceKind? {
        lock.withLock {
            let applied = pending?.to
            pending = nil
            return applied
        }
    }

    /// True once a pending handover has waited `handoverCeilingSeconds` without
    /// the engine producing a boundary of its own.
    func needsForcedFlush(at captureTime: TimeInterval) -> Bool {
        lock.withLock {
            guard let pending else { return false }
            return captureTime - pending.since >= tuning.handoverCeilingSeconds
        }
    }

    /// The silence that forces one decode: exactly the remainder of the open
    /// chunk. An aligned accumulator takes a whole chunk, which is the shortest
    /// pad that still guarantees a decode.
    static func forcedFlushSilenceSamples(fedSamples: Int, chunkSamples: Int) -> Int {
        guard chunkSamples > 0 else { return 0 }
        return chunkSamples - (max(0, fedSamples) % chunkSamples)
    }

    // MARK: Helpers

    private func channel(_ source: CaptureSourceKind) -> ChannelState {
        switch source {
        case .microphone: microphone
        case .systemAudio: systemAudio
        }
    }
}

// MARK: - Envelope history

/// A fixed-capacity ring of one channel's recent short-term RMS values.
///
/// Fixed capacity because it is written from a Core Audio IO thread, where a
/// reallocation is a dropout.
private struct EnvelopeHistory {
    private var times = [TimeInterval](repeating: 0, count: envelopeHistoryCapacity)
    private var values = [Float](repeating: 0, count: envelopeHistoryCapacity)
    private var count = 0
    private var next = 0

    var isPopulated: Bool { count > 0 }

    mutating func append(_ value: Float, at time: TimeInterval) {
        times[next] = time
        values[next] = value
        next = (next + 1) % envelopeHistoryCapacity
        count = min(count + 1, envelopeHistoryCapacity)
    }

    /// Reads `count` points onto `grid`, spaced by `step` and ending at `now`.
    /// Each point holds the most recent value at or before its own time, and the
    /// oldest value held for a time that predates the history.
    ///
    /// One backwards walk over the ring, not one per point. The grid times fall
    /// monotonically as the index falls, so the read cursor never has to go back
    /// up. Per-point searching made this quadratic in the history, paid on a
    /// realtime IO thread while holding the lock the other IO thread needs.
    func sample(
        into grid: inout [Float],
        count pointCount: Int,
        endingAt now: TimeInterval,
        step: TimeInterval
    ) {
        guard pointCount > 0, count > 0 else { return }
        var index = (next - 1 + envelopeHistoryCapacity) % envelopeHistoryCapacity
        var remaining = count
        var oldest = values[index]

        for position in stride(from: pointCount - 1, through: 0, by: -1) {
            let time = now - TimeInterval(pointCount - 1 - position) * step
            while remaining > 0, times[index] > time {
                oldest = values[index]
                remaining -= 1
                if remaining > 0 {
                    index = (index - 1 + envelopeHistoryCapacity) % envelopeHistoryCapacity
                }
            }
            grid[position] = remaining > 0 ? values[index] : oldest
        }
    }
}

// MARK: - Single-source placeholder

/// The gate a single-source capture holds and never calls. Rule 1 says such a
/// capture pays nothing for arbitration, and this makes that testable rather
/// than promised.
private final class NeverConsultedGate: LiveSpeechGating {
    private(set) var isSpeaking = false

    @discardableResult
    func update(rms: Float, timeStep: TimeInterval) -> Bool {
        assertionFailure("A single-source capture must never consult a speaker gate.")
        return false
    }

    func reset() {}
}
