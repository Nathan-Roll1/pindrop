//
//  LiveSpeakerPromotionTests.swift
//  PindropTests
//
//  Created on 2026-08-31.
//

import Foundation
import PindropCore
import PindropData
import PindropSpeech
import Testing

@testable import Pindrop

/// When a live slot earns a real name, and every way it must not get one.
@Suite
struct LiveSpeakerPromotionTests {

    // MARK: Doubles

    /// Stands in for the offline embedding pass. Nil is the honest answer for a
    /// missing model, a budget overrun, or audio with no speech in it.
    private final class FakeEmbedder: LiveSpeakerEmbedding, @unchecked Sendable {
        var embedding: [Float]?
        private(set) var embedCallCount = 0
        private(set) var unloadCallCount = 0

        init(embedding: [Float]? = [0.1, 0.2, 0.3]) {
            self.embedding = embedding
        }

        func embed(_ samples: [Float]) async -> [Float]? {
            embedCallCount += 1
            return embedding
        }

        func unload() async { unloadCallCount += 1 }
    }

    private struct EmbeddingSpaceMismatch: Error {}

    @MainActor
    private final class FakeMatcher: LiveSpeakerProfileMatching {
        var ranked: [SpeakerIdentityMatch] = []
        var ensureError: Error?
        private(set) var rankedCallCount = 0

        func ensureCurrentEmbeddingSpace() throws {
            if let ensureError { throw ensureError }
        }

        func rankedMatches(for embedding: [Float], limit: Int) throws -> [SpeakerIdentityMatch] {
            rankedCallCount += 1
            return Array(ranked.prefix(limit))
        }
    }

    /// Records what the coordinator settled on, in the order it settled.
    @MainActor
    private final class RecordingCommitObserver: StreamingRefinementCommitObserver {
        private(set) var spanUpdates: [[LiveTranscriptSpan]] = []

        func streamingRefinementCoordinator(
            _ coordinator: StreamingRefinementCoordinator,
            didCommitText committedText: String,
            spans: [LiveTranscriptSpan],
            reachedEngineBoundary: Bool
        ) {
            spanUpdates.append(spans)
        }

        var latestSpans: [LiveTranscriptSpan] { spanUpdates.last ?? [] }
    }

    // MARK: Fixtures

    private static let now = Date(timeIntervalSinceReferenceDate: 800_000)

    private static func segment(
        slot engineIndex: Int,
        from start: TimeInterval,
        to end: TimeInterval
    ) -> LiveDiarizationEngine.SlotSegment {
        LiveDiarizationEngine.SlotSegment(
            slotIndex: engineIndex,
            startCaptureTime: start,
            endCaptureTime: end,
            activity: 0.9,
            isFinalized: true
        )
    }

    /// One slot with `seconds` of finalized speech behind it.
    private static func slot(number: Int, finalizedSeconds: TimeInterval) -> LiveSpeakerSlot {
        var slot = LiveSpeakerSlot(number: number)
        slot.add(0...finalizedSeconds)
        return slot
    }

    private static func match(_ name: String, _ similarity: Float) -> SpeakerIdentityMatch {
        SpeakerIdentityMatch(profileID: UUID(), displayName: name, similarity: similarity)
    }

    @MainActor
    private static func makeSut(
        embedder: FakeEmbedder,
        matcher: FakeMatcher,
        clipSamples: [Float]? = [0.5, 0.5, 0.5],
        at instant: Date = LiveSpeakerPromotionTests.now
    ) -> LiveSpeakerPromoter {
        LiveSpeakerPromoter(
            embedder: embedder,
            matcher: matcher,
            clip: { _, _ in clipSamples },
            previousDisplayName: { "Speaker \($0.slotNumber ?? 0)" },
            now: { instant }
        )
    }

    // MARK: - Slot identity

    @Test func theFirstFinalizedSegmentMakesASlotProvisional() {
        var sut = LiveSlotAttributor()

        _ = sut.ingest([Self.segment(slot: 0, from: 0, to: 0.5)], owner: .systemAudio)

        // Identity is not withheld until a slot has spoken for a while: a short
        // turn that stayed on the channel key would share one header with
        // whoever spoke next.
        #expect(sut.currentSpeaker.tier == .provisional)
        #expect(sut.currentSpeaker.slotNumber == 1)
    }

    @Test func twoShortSlotsDoNotShareATurn() {
        var sut = LiveSlotAttributor()

        _ = sut.ingest([Self.segment(slot: 4, from: 0, to: 0.4)], owner: .systemAudio)
        let first = sut.currentSpeaker
        _ = sut.ingest([Self.segment(slot: 9, from: 1.2, to: 1.6)], owner: .systemAudio)
        let second = sut.currentSpeaker

        // Turn grouping keys on the speaker key, so two people sharing one key
        // is one person's words filed under another's name.
        #expect(first.key != second.key)
        #expect(first.key != LiveSpeakerRef.systemChannel.key)
        #expect(second.key != LiveSpeakerRef.systemChannel.key)
    }

    @Test func aSegmentBelowTheNoiseGateDoesNotOpenASlot() {
        var sut = LiveSlotAttributor()

        let boundary = sut.ingest([Self.segment(slot: 0, from: 0, to: 0.2)], owner: .systemAudio)

        // A breath or a key click is not a speaker.
        #expect(boundary == nil)
        #expect(sut.currentSpeaker == .systemChannel)
    }

    @MainActor
    @Test func aChannelTierSpanIsNeverBulkRelabelled() async {
        let observer = RecordingCommitObserver()
        let coordinator = StreamingRefinementCoordinator(idleCommitNanoseconds: 0)
        coordinator.beginSession(
            commitObserver: observer,
            preservesArtifactParagraphs: true,
            initialSpeaker: .systemChannel
        )
        await coordinator.ingestFinal("before any slot existed", captureTime: 2)

        // One channel key can cover several people, so repointing it at the
        // first slot to appear would assert an attribution nobody made.
        await coordinator.relabelSpeaker(
            slotKey: LiveSpeakerRef.systemChannel.key,
            to: LiveSpeakerRef(key: "slot.1", tier: .provisional, slotNumber: 1)
        )

        #expect(observer.latestSpans.allSatisfy { $0.speaker == .systemChannel })
        coordinator.endSession()
    }

    // MARK: - Matching

    @MainActor
    @Test func aProfileMatchAboveThresholdPromotesEveryPastSpanOfThatSlot() async throws {
        let embedder = FakeEmbedder()
        let matcher = FakeMatcher()
        matcher.ranked = [Self.match("Dana", 0.91), Self.match("Sam", 0.40)]
        let sut = Self.makeSut(embedder: embedder, matcher: matcher)

        let promoted = await sut.promotion(for: Self.slot(number: 2, finalizedSeconds: 4))
        let dana = try #require(promoted)

        #expect(dana.tier == .named)
        #expect(dana.displayName == "Dana")
        #expect(dana.key == "slot.2")

        let observer = RecordingCommitObserver()
        let coordinator = StreamingRefinementCoordinator(idleCommitNanoseconds: 0)
        let slotSpeaker = LiveSpeakerRef(key: "slot.2", tier: .provisional, slotNumber: 2)
        coordinator.beginSession(
            commitObserver: observer,
            preservesArtifactParagraphs: true,
            initialSpeaker: slotSpeaker
        )
        await coordinator.ingestFinal("first thought", captureTime: 1)
        await coordinator.ingestFinal("first thought second thought", captureTime: 3)

        await coordinator.relabelSpeaker(slotKey: dana.key, to: dana)

        // A slot is promoted, not a span: a name that starts partway down the
        // transcript reads as two people.
        #expect(observer.latestSpans.count == 2)
        #expect(observer.latestSpans.allSatisfy { $0.speaker == dana })
        coordinator.endSession()
    }

    @MainActor
    @Test func aProfileMatchBelowTheLiveMarginDoesNotPromote() async {
        let embedder = FakeEmbedder()
        let matcher = FakeMatcher()
        // Both would pass the offline gate (0.72 similarity, 0.08 margin). The
        // live thresholds are higher because a 3 to 6 second slice of
        // conference audio scores differently from a whole recording.
        matcher.ranked = [Self.match("Dana", 0.85), Self.match("Sam", 0.75)]
        let sut = Self.makeSut(embedder: embedder, matcher: matcher)

        let promoted = await sut.promotion(for: Self.slot(number: 2, finalizedSeconds: 4))

        #expect(promoted == nil)
    }

    @MainActor
    @Test func anEmbeddingSpaceMismatchNeverPromotes() async {
        let embedder = FakeEmbedder()
        let matcher = FakeMatcher()
        matcher.ranked = [Self.match("Dana", 0.99)]
        matcher.ensureError = EmbeddingSpaceMismatch()
        let sut = Self.makeSut(embedder: embedder, matcher: matcher)

        let promoted = await sut.promotion(for: Self.slot(number: 2, finalizedSeconds: 4))

        // Stored centroids are versioned by embedding space. Scoring across two
        // spaces produces a confidently wrong name.
        #expect(promoted == nil)
        #expect(matcher.rankedCallCount == 0)
    }

    @MainActor
    @Test func aMissingOfflineModelLeavesSlotsProvisional() async {
        let embedder = FakeEmbedder(embedding: nil)
        let matcher = FakeMatcher()
        matcher.ranked = [Self.match("Dana", 0.99)]
        let sut = Self.makeSut(embedder: embedder, matcher: matcher)

        let promoted = await sut.promotion(for: Self.slot(number: 2, finalizedSeconds: 4))

        // "Speaker 2" is already an honest label, so this degrades quietly.
        #expect(promoted == nil)
        #expect(matcher.rankedCallCount == 0)
    }

    @Test func aNamedSlotIsNeverDemoted() {
        var sut = LiveSlotAttributor()
        _ = sut.ingest([Self.segment(slot: 0, from: 0, to: 1.2)], owner: .systemAudio)
        let dana = LiveSpeakerRef(
            key: LiveSpeakerSlot.key(for: 1),
            tier: .named,
            slotNumber: 1,
            displayName: "Dana"
        )
        let named = sut.promote(slotNumber: 1, to: dana)
        #expect(named)

        let demoted = sut.promote(
            slotNumber: 1,
            to: LiveSpeakerRef(key: LiveSpeakerSlot.key(for: 1), tier: .provisional, slotNumber: 1)
        )

        #expect(demoted == false)
        #expect(sut.currentSpeaker.displayName == "Dana")
    }

    @MainActor
    @Test func aNamedSlotIsNotReMatched() async {
        let embedder = FakeEmbedder()
        let matcher = FakeMatcher()
        matcher.ranked = [Self.match("Dana", 0.99)]
        let sut = Self.makeSut(embedder: embedder, matcher: matcher)

        var named = Self.slot(number: 2, finalizedSeconds: 40)
        named.speaker = LiveSpeakerRef(
            key: LiveSpeakerSlot.key(for: 2),
            tier: .named,
            slotNumber: 2,
            displayName: "Dana"
        )
        _ = await sut.promotion(for: named)

        // A named slot costs nothing to leave alone, and re-checking it can only
        // produce a contradiction the reader would have to live with.
        #expect(embedder.embedCallCount == 0)

        // Below the named tier a slot is re-checked, but not more than once
        // every 15 s: the clock in this fixture does not move.
        let provisional = Self.slot(number: 3, finalizedSeconds: 40)
        matcher.ranked = [Self.match("Sam", 0.10)]
        _ = await sut.promotion(for: provisional)
        _ = await sut.promotion(for: provisional)
        #expect(embedder.embedCallCount == 1)
    }

    // MARK: - The promotion cue

    @MainActor
    @Test func promotionKeepsAWasNameAffixForTheRestOfTheCapture() async throws {
        let embedder = FakeEmbedder()
        let matcher = FakeMatcher()
        matcher.ranked = [Self.match("Dana", 0.95)]
        let sut = Self.makeSut(embedder: embedder, matcher: matcher)

        let dana = try #require(await sut.promotion(for: Self.slot(number: 2, finalizedSeconds: 4)))

        #expect(dana.promotedAt == Self.now)
        #expect(dana.previousDisplayName == "Speaker 2")

        let spans = [
            LiveTranscriptSpan(
                id: 0,
                speaker: dana,
                text: "We shipped it.",
                startOffset: 0,
                duration: 0,
                boundaryReason: .endOfUtterance
            )
        ]
        // Ten minutes later the reader still learns who "Speaker 2" turned out
        // to be, because the cue is derived from `promotedAt` rather than
        // delivered once.
        let entry = TranscriptSegmentPresentation.liveEntries(
            spans: spans,
            tentative: nil,
            now: Self.now.addingTimeInterval(600)
        ).first?.turn
        #expect(entry?.promotion?.previousDisplayName == "Speaker 2")
    }

    @MainActor
    @Test func theRelabelEmphasisWindowExpiresButTheAffixDoesNot() async throws {
        let embedder = FakeEmbedder()
        let matcher = FakeMatcher()
        matcher.ranked = [Self.match("Dana", 0.95)]
        let sut = Self.makeSut(embedder: embedder, matcher: matcher)

        let dana = try #require(await sut.promotion(for: Self.slot(number: 2, finalizedSeconds: 4)))
        let spans = [
            LiveTranscriptSpan(
                id: 0,
                speaker: dana,
                text: "We shipped it.",
                startOffset: 0,
                duration: 0,
                boundaryReason: .endOfUtterance
            )
        ]

        let fresh = try #require(
            TranscriptSegmentPresentation
                .liveEntries(spans: spans, tentative: nil, now: Self.now.addingTimeInterval(0.5))
                .first?.turn
        )
        let later = try #require(
            TranscriptSegmentPresentation
                .liveEntries(spans: spans, tentative: nil, now: Self.now.addingTimeInterval(5))
                .first?.turn
        )

        #expect(fresh.promotion?.isRecent == true)
        #expect(later.promotion?.isRecent == false)
        #expect(later.promotion?.previousDisplayName == "Speaker 2")
    }
}
