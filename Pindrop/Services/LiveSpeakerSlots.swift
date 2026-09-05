//
//  LiveSpeakerSlots.swift
//  Pindrop
//
//  Created on 2026-08-31.
//
//  What the streaming diarizer's output means for the live transcript: which
//  remote voice is talking, when the label may change, and which slot a stretch
//  of capture time belongs to.
//
//  Deliberately a value type with no dependencies on the recorder, the engine,
//  or the clock. Everything here is arithmetic over segments the diarizer
//  already produced, so the rules that decide what a reader sees can be checked
//  without audio.
//

import Foundation
import PindropCore
import PindropSpeech

/// One remote voice, for the life of one capture.
///
/// The number is 1-based and handed out in the order slots first produce
/// finalized speech, so a reader never meets Speaker 4 before Speaker 2. It is
/// never the model's own track number, which is arbitrary.
struct LiveSpeakerSlot: Equatable {
    let number: Int
    /// Ranges of finalized speech, in capture time, oldest first.
    private(set) var finalizedRanges: [ClosedRange<TimeInterval>] = []
    /// The reference every span of this slot carries. Promoted in place, so the
    /// interface can change a name without splitting a turn.
    var speaker: LiveSpeakerRef

    init(number: Int) {
        self.number = number
        self.speaker = LiveSpeakerRef(
            key: LiveSpeakerSlot.key(for: number),
            tier: .provisional,
            slotNumber: number
        )
    }

    /// Seconds of finalized speech behind this slot.
    var finalizedSeconds: TimeInterval {
        finalizedRanges.reduce(0) { $0 + ($1.upperBound - $1.lowerBound) }
    }

    mutating func add(_ range: ClosedRange<TimeInterval>) {
        finalizedRanges.append(range)
    }

    /// Seconds of this slot's finalized speech inside `range`.
    func overlap(with range: ClosedRange<TimeInterval>) -> TimeInterval {
        finalizedRanges.reduce(0) { total, owned in
            let low = max(owned.lowerBound, range.lowerBound)
            let high = min(owned.upperBound, range.upperBound)
            return total + max(0, high - low)
        }
    }

    /// The stable key every span of this slot is grouped by. It never changes,
    /// including across a promotion to a real name.
    static func key(for number: Int) -> String { "slot.\(number)" }
}

/// Turns diarizer segments into live speaker labels and speaker-change
/// boundaries.
struct LiveSlotAttributor {

    /// A finalized segment shorter than this never opens a slot. Breaths, key
    /// clicks, and codec artifacts finalize as very short segments, and one of
    /// them opening "Speaker 3" puts a person on screen who never spoke.
    static let noiseGateSeconds: TimeInterval = 0.35

    /// A slot must hold the floor this long before its change may cut a
    /// paragraph.
    static let minimumSlotTurnSeconds: TimeInterval = 1.00

    /// And it must have this much finalized speech behind it.
    static let minimumSlotFinalizedSeconds: TimeInterval = 0.40

    /// Sortformer separates at most four voices, so a fifth track cannot open a
    /// slot. The local user is a free fifth speaker on their own channel.
    static let maximumSlots = 4

    /// One speaker change the live transcript should show.
    struct Boundary: Equatable {
        let speaker: LiveSpeakerRef
        /// Capture time the new voice started at, not the time the diarizer got
        /// around to saying so.
        let captureTime: TimeInterval
    }

    /// Slots by number, 1-based and dense.
    private(set) var slots: [Int: LiveSpeakerSlot] = [:]
    /// The model's own track number to our slot number.
    private var slotNumberForTrack: [Int: Int] = [:]
    /// The slot the transcript is currently pointed at, whoever owns the engine.
    private(set) var currentSlotNumber: Int?
    /// Capture time of the last boundary that was actually taken, which is where
    /// the hysteresis window is measured from.
    private var lastBoundaryCaptureTime: TimeInterval?
    /// A change waiting for the window to open. The last one wins, so overlapped
    /// speech produces one boundary instead of a paragraph per word.
    private var pendingChange: (slotNumber: Int, captureTime: TimeInterval)?
    /// True once all four slots exist, which the live sheet states as a
    /// capability and never as a headcount.
    var isAtSlotCapacity: Bool { slots.count >= Self.maximumSlots }

    init() {}

    /// The label the transcript should carry right now. `Call audio` until the
    /// diarizer has resolved anyone, which is honest rather than confident.
    var currentSpeaker: LiveSpeakerRef {
        guard let currentSlotNumber, let slot = slots[currentSlotNumber] else {
            return .systemChannel
        }
        return slot.speaker
    }

    /// Folds newly drained segments in and reports the one boundary they justify.
    ///
    /// `owner` is the channel that owns the streaming engine. A speaker change is
    /// applied only while the system channel owns it: the diarizer hears the
    /// system stream whoever owns the engine, so applying a change during the
    /// user's own sentence would head it `Speaker 3`. The change is still
    /// recorded, and the next channel change to system audio carries it.
    mutating func ingest(
        _ segments: [LiveDiarizationEngine.SlotSegment],
        owner: CaptureSourceKind
    ) -> Boundary? {
        for segment in segments.filter(\.isFinalized).sorted(by: { $0.startCaptureTime < $1.startCaptureTime }) {
            let duration = segment.endCaptureTime - segment.startCaptureTime
            guard duration > 0 else { continue }
            guard let number = slotNumber(forTrack: segment.slotIndex, duration: duration) else {
                continue
            }
            slots[number]?.add(segment.startCaptureTime...segment.endCaptureTime)
            if number != currentSlotNumber {
                pendingChange = (number, segment.startCaptureTime)
            }
        }
        return resolvePendingChange(owner: owner)
    }

    /// The slot with the most finalized speech inside the range, with a tie
    /// broken toward `previousSlotNumber`.
    ///
    /// A marginal lead is not evidence. Flipping the header on one would leave a
    /// reader watching the name above a paragraph change while nobody moved.
    func attributedSpeaker(
        from start: TimeInterval,
        to end: TimeInterval,
        previousSlotNumber: Int?
    ) -> LiveSpeakerRef {
        guard end > start else { return speaker(forSlotNumber: previousSlotNumber) }
        let range = start...end

        var bestNumber = previousSlotNumber
        var bestOverlap = previousSlotNumber
            .flatMap { slots[$0] }
            .map { $0.overlap(with: range) } ?? 0

        for number in slots.keys.sorted() {
            guard number != previousSlotNumber, let slot = slots[number] else { continue }
            let overlap = slot.overlap(with: range)
            guard overlap > bestOverlap else { continue }
            bestOverlap = overlap
            bestNumber = number
        }

        guard bestOverlap > 0 else { return .systemChannel }
        return speaker(forSlotNumber: bestNumber)
    }

    /// The label a handover back to the system channel should carry: whoever has
    /// been talking since the last boundary.
    func speakerForChannelChange(at captureTime: TimeInterval) -> LiveSpeakerRef {
        attributedSpeaker(
            from: lastBoundaryCaptureTime ?? 0,
            to: captureTime,
            previousSlotNumber: currentSlotNumber
        )
    }

    /// Replaces one slot's reference. Tiers only go up: a name that was shown
    /// once is never taken away mid-recording.
    @discardableResult
    mutating func promote(slotNumber: Int, to replacement: LiveSpeakerRef) -> Bool {
        guard var slot = slots[slotNumber], replacement.tier > slot.speaker.tier else {
            return false
        }
        slot.speaker = replacement
        slots[slotNumber] = slot
        return true
    }

    /// Slots that could still earn a name, in slot order. A named slot is never
    /// re-checked, so it is not here.
    func slotsBelowNamedTier() -> [LiveSpeakerSlot] {
        slots.keys.sorted().compactMap { slots[$0] }.filter { $0.speaker.tier < .named }
    }

    func speaker(forSlotNumber number: Int?) -> LiveSpeakerRef {
        guard let number, let slot = slots[number] else { return .systemChannel }
        return slot.speaker
    }

    // MARK: - Private

    /// The slot for one model track, opening it at its first finalized segment
    /// past the noise gate.
    ///
    /// Identity is assigned at the first finalized segment rather than after
    /// sustained speech, because a turn ends when the speaker key changes. Held
    /// back, every short turn ("yeah", "no, next week") would share the one
    /// `Call audio` key and collapse under a single header, which is one
    /// person's words filed under another's.
    private mutating func slotNumber(forTrack track: Int, duration: TimeInterval) -> Int? {
        if let existing = slotNumberForTrack[track] { return existing }
        guard duration >= Self.noiseGateSeconds else { return nil }
        guard slots.count < Self.maximumSlots else { return nil }
        let number = slots.count + 1
        slotNumberForTrack[track] = number
        slots[number] = LiveSpeakerSlot(number: number)
        return number
    }

    private mutating func resolvePendingChange(owner: CaptureSourceKind) -> Boundary? {
        guard let change = pendingChange, let slot = slots[change.slotNumber] else { return nil }
        guard slot.finalizedSeconds >= Self.minimumSlotFinalizedSeconds else { return nil }
        if let last = lastBoundaryCaptureTime,
           change.captureTime - last < Self.minimumSlotTurnSeconds {
            return nil
        }

        pendingChange = nil
        currentSlotNumber = change.slotNumber
        lastBoundaryCaptureTime = change.captureTime
        guard owner == .systemAudio else { return nil }
        return Boundary(speaker: slot.speaker, captureTime: change.captureTime)
    }
}
