//
//  LiveSpeakerPromoter.swift
//  Pindrop
//
//  Created on 2026-08-31.
//
//  When a live speaker slot has said enough for a name to be worth risking, and
//  every way it must not get one.
//
//  The unacceptable outcome is a wrong name on screen for forty minutes. So the
//  rules here are all one way: a slot only ever moves up a tier, a name is only
//  taken from a match that clears the live thresholds, and every other outcome
//  leaves the reader looking at "Speaker 2", which is honest.
//

import Foundation
import PindropCore
import PindropData
import PindropSpeech

/// The profile matching one promotion attempt needs.
///
/// Narrower than `SpeakerIdentityManaging` on purpose: the live path reads
/// profiles and never writes them. Phase 2 records no training evidence at all,
/// because a label decided from six seconds of conference audio is not evidence.
@MainActor
protocol LiveSpeakerProfileMatching: AnyObject {
    /// Repairs or clears centroids stored in an older embedding space. Called
    /// before every attempt: scoring across two spaces produces a confident
    /// wrong name.
    func ensureCurrentEmbeddingSpace() throws
    /// The closest profiles, best first, with no threshold applied.
    func rankedMatches(for embedding: [Float], limit: Int) throws -> [SpeakerIdentityMatch]
}

extension PindropData.SpeakerIdentityService: LiveSpeakerProfileMatching {}

@MainActor
final class LiveSpeakerPromoter {

    /// Finalized speech a slot needs before a name is worth attempting. Below
    /// this the embedding describes a fragment, not a voice.
    static let minimumFinalizedSecondsForPromotion: TimeInterval = 3.0
    /// Most a clip may carry, most recent first. Longer buys nothing and costs
    /// Neural Engine time the streaming engines are already using.
    static let maximumClipSeconds: TimeInterval = 6.0
    /// A slot below `.named` is re-checked no more often than this.
    static let reMatchIntervalSeconds: TimeInterval = 15.0

    private let embedder: any LiveSpeakerEmbedding
    private let matcher: any LiveSpeakerProfileMatching
    /// Cuts one capture-time range out of the diarizer's ring. Nil when the
    /// range aged out, which fails the attempt rather than embedding whatever
    /// audio happens to sit there.
    private let clip: @Sendable (TimeInterval, TimeInterval) async -> [Float]?
    /// What the header read before the name, for the `was Speaker 2` affix. The
    /// caller owns it because it is localized text.
    private let previousDisplayName: @MainActor (LiveSpeakerRef) -> String
    private let now: @Sendable () -> Date

    private var lastAttemptAt: [Int: Date] = [:]

    init(
        embedder: any LiveSpeakerEmbedding,
        matcher: any LiveSpeakerProfileMatching,
        clip: @escaping @Sendable (TimeInterval, TimeInterval) async -> [Float]?,
        previousDisplayName: @escaping @MainActor (LiveSpeakerRef) -> String,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.embedder = embedder
        self.matcher = matcher
        self.clip = clip
        self.previousDisplayName = previousDisplayName
        self.now = now
    }

    /// The name this slot has earned, or nil to leave it where it is.
    func promotion(for slot: LiveSpeakerSlot) async -> LiveSpeakerRef? {
        // A named slot is never re-checked. A later contradiction could only be
        // acted on by taking a name away, which this design forbids.
        guard slot.speaker.tier < .named else { return nil }
        guard slot.finalizedSeconds >= Self.minimumFinalizedSecondsForPromotion else { return nil }

        let instant = now()
        if let last = lastAttemptAt[slot.number],
           instant.timeIntervalSince(last) < Self.reMatchIntervalSeconds {
            return nil
        }
        lastAttemptAt[slot.number] = instant

        guard let samples = await clipSamples(for: slot), !samples.isEmpty else { return nil }
        guard let embedding = await embedder.embed(samples) else { return nil }

        do {
            try matcher.ensureCurrentEmbeddingSpace()
        } catch {
            Log.transcription.info(
                "Live speaker promotion skipped, the embedding space could not be settled: \(error.localizedDescription)"
            )
            return nil
        }

        let ranked: [SpeakerIdentityMatch]
        do {
            ranked = try matcher.rankedMatches(for: embedding, limit: 2)
        } catch {
            Log.transcription.info(
                "Live speaker promotion skipped, profiles could not be read: \(error.localizedDescription)"
            )
            return nil
        }

        guard let best = ranked.first,
              best.similarity >= SpeakerIdentityService.liveMinimumSimilarityForAutoMatch
        else {
            return nil
        }
        if ranked.count > 1,
           best.similarity - ranked[1].similarity
            < SpeakerIdentityService.liveMinimumSimilarityMarginForAutoMatch {
            // Two profiles this close is not a match. Naming the nearer one is a
            // coin toss the reader cannot see being tossed.
            return nil
        }

        return LiveSpeakerRef(
            key: slot.speaker.key,
            tier: .named,
            slotNumber: slot.number,
            profileID: best.profileID,
            displayName: best.displayName,
            promotedAt: instant,
            previousDisplayName: previousDisplayName(slot.speaker)
        )
    }

    // MARK: - Private

    /// This slot's most recent finalized speech, newest ranges first, up to the
    /// clip bound. Newest first because a voice is best described by what it
    /// just said, and the ring only holds the last 45 s anyway.
    private func clipSamples(for slot: LiveSpeakerSlot) async -> [Float]? {
        var collected: [Float] = []
        var seconds: TimeInterval = 0
        for range in slot.finalizedRanges.reversed() {
            guard seconds < Self.maximumClipSeconds else { break }
            let allowed = min(range.upperBound - range.lowerBound, Self.maximumClipSeconds - seconds)
            guard allowed > 0 else { continue }
            let start = range.upperBound - allowed
            guard let samples = await clip(start, range.upperBound) else { continue }
            // Oldest first in the clip itself, so the audio still reads as
            // speech rather than as reversed turns.
            collected.insert(contentsOf: samples, at: 0)
            seconds += allowed
        }
        return collected.isEmpty ? nil : collected
    }
}
