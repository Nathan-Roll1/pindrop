//
//  LiveAttributionTests.swift
//  PindropTests
//
//  Created on 2026-08-31.
//

import Foundation
import PindropCore
import PindropSpeech
import Testing

@testable import Pindrop

/// Where diarizer segments meet live text: which slot a stretch of speech
/// belongs to, and where a boundary that arrived a second late cuts.
@Suite
struct LiveAttributionTests {

    // MARK: Fixtures

    private static func segment(
        slot engineIndex: Int,
        from start: TimeInterval,
        to end: TimeInterval,
        finalized: Bool = true
    ) -> LiveDiarizationEngine.SlotSegment {
        LiveDiarizationEngine.SlotSegment(
            slotIndex: engineIndex,
            startCaptureTime: start,
            endCaptureTime: end,
            activity: 0.9,
            isFinalized: finalized
        )
    }

    /// Records what the coordinator settled on, in the order it settled.
    @MainActor
    private final class RecordingCommitObserver: StreamingRefinementCommitObserver {
        private(set) var committedTexts: [String] = []
        private(set) var spanUpdates: [[LiveTranscriptSpan]] = []

        func streamingRefinementCoordinator(
            _ coordinator: StreamingRefinementCoordinator,
            didCommitText committedText: String,
            spans: [LiveTranscriptSpan],
            reachedEngineBoundary: Bool
        ) {
            committedTexts.append(committedText)
            spanUpdates.append(spans)
        }

        var latestSpans: [LiveTranscriptSpan] { spanUpdates.last ?? [] }
    }

    private static func slotSpeaker(_ number: Int) -> LiveSpeakerRef {
        LiveSpeakerRef(key: "slot.\(number)", tier: .provisional, slotNumber: number)
    }

    // MARK: - The overlap query

    @Test func aSpanIsAttributedToTheSlotWithTheLargestOverlap() {
        var sut = LiveSlotAttributor()
        _ = sut.ingest(
            [Self.segment(slot: 7, from: 0, to: 2), Self.segment(slot: 3, from: 2, to: 10)],
            owner: .systemAudio
        )

        // Slot numbers are first-finalized order, not the model's own track
        // numbers: engine track 7 spoke first, so it is Speaker 1.
        let speaker = sut.attributedSpeaker(from: 1, to: 9, previousSlotNumber: 1)

        #expect(speaker.slotNumber == 2)
        #expect(speaker.tier == .provisional)
    }

    @Test func aMarginalOverlapDoesNotFlipTheLabelBack() {
        var sut = LiveSlotAttributor()
        _ = sut.ingest(
            [Self.segment(slot: 0, from: 0, to: 5), Self.segment(slot: 1, from: 5, to: 10)],
            owner: .systemAudio
        )

        // Both slots cover exactly half of the span. Inventing a winner here
        // would flip the header back and forth under real overlapped speech.
        let speaker = sut.attributedSpeaker(from: 0, to: 10, previousSlotNumber: 1)

        #expect(speaker.slotNumber == 1)
    }

    @Test func aSpanWithNoOverlapKeepsTheChannelLabel() {
        var sut = LiveSlotAttributor()
        _ = sut.ingest([Self.segment(slot: 0, from: 0, to: 5)], owner: .systemAudio)

        let speaker = sut.attributedSpeaker(from: 20, to: 25, previousSlotNumber: nil)

        // "Call audio" means the diarizer has not resolved this yet, which is
        // honest. A slot label here would assert something no model said.
        #expect(speaker == .systemChannel)
    }

    // MARK: - Hysteresis and ownership

    @Test func slotChangesInsideTheHysteresisWindowCoalesceIntoOneBoundary() {
        var sut = LiveSlotAttributor()

        let first = sut.ingest([Self.segment(slot: 0, from: 0, to: 0.5)], owner: .systemAudio)
        let inside = sut.ingest([Self.segment(slot: 1, from: 0.6, to: 1.0)], owner: .systemAudio)
        let past = sut.ingest([Self.segment(slot: 2, from: 1.1, to: 1.6)], owner: .systemAudio)

        #expect(first?.speaker.slotNumber == 1)
        // Inside `minimumSlotTurnSeconds` of the last boundary, so it cannot cut
        // a paragraph. Overlapped speech would otherwise shred the transcript
        // into one-word paragraphs.
        #expect(inside == nil)
        // The last change inside the window wins, and only one boundary lands.
        #expect(past?.speaker.slotNumber == 3)
        #expect(past?.captureTime == 1.1)
    }

    @Test func aSpeakerChangeIsIgnoredWhileTheMicrophoneOwnsTheEngine() {
        var sut = LiveSlotAttributor()

        let boundary = sut.ingest([Self.segment(slot: 0, from: 0, to: 1.2)], owner: .microphone)

        // The diarizer hears the system stream whoever owns the engine. Applying
        // its switches while the microphone owns it would head the user's own
        // next sentence "Speaker 1".
        #expect(boundary == nil)
        // Recorded all the same, so the next channel change carries it.
        #expect(sut.currentSpeaker.slotNumber == 1)
    }

    // MARK: - The retroactive split

    @MainActor
    @Test func aSpeakerChangeBoundaryDoesNotStealEarlierText() async {
        let observer = RecordingCommitObserver()
        let coordinator = StreamingRefinementCoordinator(idleCommitNanoseconds: 0)
        coordinator.beginSession(
            commitObserver: observer,
            preservesArtifactParagraphs: true,
            initialSpeaker: .systemChannel
        )

        // LocalAgreement-2 commits inside one open paragraph, which is the only
        // shape a late boundary can cut.
        await coordinator.ingestPartial("one two three four five", captureTime: 1)
        await coordinator.ingestPartial("one two three four five six seven", captureTime: 2)
        await coordinator.ingestPartial(
            "one two three four five six seven eight nine",
            captureTime: 4
        )

        let openBefore = observer.latestSpans
        #expect(openBefore.count == 1)

        await coordinator.markBoundary(
            .speakerChange,
            speaker: Self.slotSpeaker(2),
            atCaptureTime: 3
        )

        let spans = observer.latestSpans
        #expect(spans.count == 2)
        // Text decoded from audio before the switch stays with the speaker who
        // said it, even though the diarizer only reported the switch a second
        // later.
        #expect(spans.first?.speaker == .systemChannel)
        #expect(spans.first?.text == "One two three")
        #expect(spans.first?.boundaryReason == .speakerChange)
        #expect(spans.last?.speaker.slotNumber == 2)
        #expect(spans.last?.text == "four five")
        // Not one character was added, removed, or moved: the durable checkpoint
        // takes every write as an extension of the previous one.
        #expect(observer.committedTexts.last == "One two three four five")
        #expect(
            spans.map(\.text).joined(separator: " ") == observer.committedTexts.last
        )
        coordinator.endSession()
    }

    @MainActor
    @Test func aBoundaryBeforeTheOpenSpanClampsInsteadOfResplittingHistory() async {
        let observer = RecordingCommitObserver()
        let coordinator = StreamingRefinementCoordinator(idleCommitNanoseconds: 0)
        coordinator.beginSession(
            commitObserver: observer,
            preservesArtifactParagraphs: true,
            initialSpeaker: .systemChannel
        )

        await coordinator.ingestFinal("settled paragraph", captureTime: 5)
        await coordinator.ingestPartial("settled paragraph open words here", captureTime: 7)
        await coordinator.ingestPartial(
            "settled paragraph open words here and more",
            captureTime: 9
        )
        let closedText = observer.latestSpans.first?.text

        // Older than everything the open paragraph was decoded from.
        await coordinator.markBoundary(
            .speakerChange,
            speaker: Self.slotSpeaker(2),
            atCaptureTime: 1
        )

        let spans = observer.latestSpans
        #expect(spans.count == 2)
        // The closed paragraph is settled and the reader has already read it
        // under its header, so it is never cut again.
        #expect(spans.first?.text == closedText)
        #expect(spans.first?.speaker == .systemChannel)
        #expect(spans.last?.speaker.slotNumber == 2)
        coordinator.endSession()
    }
}
