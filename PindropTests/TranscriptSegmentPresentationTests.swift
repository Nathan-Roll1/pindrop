//
//  TranscriptSegmentPresentationTests.swift
//  PindropTests
//
//  Created on 2026-08-22.
//

import Foundation
import Testing
import PindropCore
@testable import Pindrop

@Suite("Transcript segment presentation (WP5)")
struct TranscriptSegmentPresentationTests {

    private let locale = Locale(identifier: "en")

    private func segment(
        id: String,
        speakerKey: String?,
        label: String?,
        number: Int? = nil,
        isCurrentUser: Bool = false,
        text: String,
        start: TimeInterval
    ) -> TranscriptSegmentSnapshot {
        TranscriptSegmentSnapshot(
            id: id,
            revisionID: UUID(),
            speakerKey: speakerKey,
            speakerLabel: label,
            speakerNumber: number,
            isCurrentUser: isCurrentUser,
            text: text,
            startOffset: start,
            duration: 2
        )
    }

    private var conversation: [TranscriptSegmentSnapshot] {
        [
            segment(id: "a", speakerKey: "s1", label: "You", isCurrentUser: true,
                    text: "Let us start with the migration.", start: 0),
            segment(id: "b", speakerKey: "s1", label: "You", isCurrentUser: true,
                    text: "The store rebuild worries me.", start: 5),
            segment(id: "c", speakerKey: "s2", label: "Speaker 2", number: 2,
                    text: "We can stage the migration behind a flag.", start: 12)
        ]
    }

    // MARK: - Grouping

    @Test func consecutiveSpansOfOneSpeakerBecomeOneTurnOfTwoParagraphs() throws {
        let presentation = TranscriptSegmentPresentation.make(
            segments: conversation,
            locale: locale
        )

        #expect(presentation.turns.count == 2)
        let first = try #require(presentation.turns.first)
        #expect(first.displayName == "You")
        #expect(first.paragraphs.map(\.id) == ["a", "b"])
        #expect(first.paragraphs.map(\.startOffset) == [0, 5])
        #expect(first.text == "Let us start with the migration.\nThe store rebuild worries me.")

        let second = try #require(presentation.turns.last)
        #expect(second.displayName == "Speaker 2")
        #expect(second.paragraphs.count == 1)
    }

    @Test func aTurnIsStampedWithItsFirstWord() throws {
        let presentation = TranscriptSegmentPresentation.make(
            segments: conversation,
            locale: locale
        )
        let first = try #require(presentation.turns.first)
        #expect(first.startOffset == 0)
        #expect(first.timestampText == "00:00")

        let second = try #require(presentation.turns.last)
        #expect(second.timestampText == "00:12")
    }

    @Test func timestampsReadAsMinutesAndHoursTheSameWayTheCaptureBarDoes() {
        #expect(TranscriptSegmentPresentation.timestampText(0) == "00:00")
        #expect(TranscriptSegmentPresentation.timestampText(243) == "04:03")
        #expect(TranscriptSegmentPresentation.timestampText(3723) == "1:02:03")
    }

    @Test func unattributedSpansGroupTogetherAndKeepAName() throws {
        let presentation = TranscriptSegmentPresentation.make(
            segments: [
                segment(id: "a", speakerKey: nil, label: nil, text: "One.", start: 0),
                segment(id: "b", speakerKey: nil, label: nil, text: "Two.", start: 2)
            ],
            locale: locale
        )
        #expect(presentation.turns.count == 1)
        let turn = try #require(presentation.turns.first)
        #expect(turn.speakerKey == "_")
        #expect(turn.displayName == "Speaker")
    }

    @Test func speakerColorsFollowTheSameKeyTheTranscriptPipelineGroupsBy() {
        // One rule for the key, so a turn header and the Library footer cannot
        // give one speaker two colors.
        #expect(
            LibrarySpeakerColor.canonicalKey(speakerId: "", speakerLabel: "Alice")
                == DiarizedTranscriptSegment.canonicalSpeakerKey(
                    speakerId: "",
                    speakerLabel: "Alice"
                )
        )
        #expect(LibrarySpeakerColor.canonicalKey(speakerId: " ", speakerLabel: " ") == "_")
        #expect(LibrarySpeakerColor.canonicalKey(speakerId: "s1", speakerLabel: "Alice") == "s1")
    }

    // MARK: - Solo notes (Round B, board 67)

    /// One person, recorded alone: the spans are pause breaks, not turns.
    private var soloNote: [TranscriptSegmentSnapshot] {
        [
            segment(id: "a", speakerKey: "self", label: "You", isCurrentUser: true,
                    text: "First thought here.", start: 0),
            segment(id: "b", speakerKey: "self", label: "You", isCurrentUser: true,
                    text: "Second thought here.", start: 30),
            segment(id: "c", speakerKey: "self", label: "You", isCurrentUser: true,
                    text: "Third thought here.", start: 61)
        ]
    }

    @Test func aSoloNoteIsOneTurnOfSeveralTimeCodedBlocks() throws {
        let presentation = TranscriptSegmentPresentation.make(
            segments: soloNote,
            locale: locale
        )

        #expect(presentation.turns.count == 1)
        let turn = try #require(presentation.turns.first)
        #expect(turn.isSolo)
        #expect(turn.displayName == "You")
        #expect(turn.paragraphs.count == 3)
        #expect(turn.paragraphs.map(\.timestampText) == ["00:00", "00:30", "01:01"])
    }

    @Test func aSoloTurnHeaderReadsTheWholeLengthNotTheStart() throws {
        let presentation = TranscriptSegmentPresentation.make(
            segments: soloNote,
            locale: locale
        )
        let turn = try #require(presentation.turns.first)

        // The last block starts at 61 and runs 2 seconds.
        #expect(turn.timestampText == "01:03")
    }

    @Test func aConversationKeepsTheSpeakerTurnLayout() throws {
        let presentation = TranscriptSegmentPresentation.make(
            segments: conversation,
            locale: locale
        )

        #expect(presentation.turns.allSatisfy { !$0.isSolo })
        let first = try #require(presentation.turns.first)
        #expect(first.timestampText == "00:00")
    }

    @Test func oneTurnFromSomebodyElseIsNotASoloNote() throws {
        let presentation = TranscriptSegmentPresentation.make(
            segments: [
                segment(id: "a", speakerKey: "s2", label: "Speaker 2", number: 2,
                        text: "One.", start: 0),
                segment(id: "b", speakerKey: "s2", label: "Speaker 2", number: 2,
                        text: "Two.", start: 4)
            ],
            locale: locale
        )
        let turn = try #require(presentation.turns.first)
        #expect(!turn.isSolo)
    }

    @Test func searchingASoloNoteKeepsItASoloNote() throws {
        let presentation = TranscriptSegmentPresentation.make(
            segments: soloNote,
            query: "Second",
            locale: locale
        )
        let turn = try #require(presentation.turns.first)

        #expect(turn.isSolo)
        #expect(turn.paragraphs.map(\.id) == ["b"])
        #expect(turn.timestampText == "01:03")
    }

    // MARK: - Nothing to read

    @Test func anEmptyTranscriptSaysSoInsteadOfDrawingAnEmptyColumn() {
        let presentation = TranscriptSegmentPresentation.make(segments: [], locale: locale)
        #expect(presentation.turns.isEmpty)
        #expect(presentation.emptyMessage == "Nothing was transcribed yet.")
        #expect(!presentation.isSearching)
        #expect(presentation.resultsText == nil)
    }

    // MARK: - Search

    @Test func anUnsearchedTranscriptIsOnePlainRunPerParagraph() throws {
        let presentation = TranscriptSegmentPresentation.make(
            segments: conversation,
            query: "   ",
            locale: locale
        )
        #expect(!presentation.isSearching)
        #expect(presentation.resultsText == nil)
        #expect(presentation.turns.count == 2)
        let runs = try #require(presentation.turns.first?.paragraphs.first?.runs)
        #expect(runs.count == 1)
        #expect(runs.first?.isMatch == false)
    }

    @Test func searchKeepsOnlyTheParagraphsThatMatched() throws {
        let presentation = TranscriptSegmentPresentation.make(
            segments: conversation,
            query: "migration",
            locale: locale
        )
        #expect(presentation.isSearching)
        #expect(presentation.turns.count == 2)
        // "The store rebuild worries me." never says migration.
        #expect(presentation.turns.first?.paragraphs.map(\.id) == ["a"])
        #expect(presentation.turns.last?.paragraphs.map(\.id) == ["c"])
        #expect(presentation.emptyMessage == nil)
    }

    @Test func everyOccurrenceCounts() {
        let presentation = TranscriptSegmentPresentation.make(
            segments: [
                segment(id: "a", speakerKey: "s1", label: "You", isCurrentUser: true,
                        text: "Plan the plan before the plan.", start: 0)
            ],
            query: "plan",
            locale: locale
        )
        #expect(presentation.matchCount == 3)
        #expect(presentation.resultsText == "3 results")
    }

    @Test func oneMatchReadsAsOneResult() {
        let presentation = TranscriptSegmentPresentation.make(
            segments: conversation,
            query: "rebuild",
            locale: locale
        )
        #expect(presentation.matchCount == 1)
        #expect(presentation.resultsText == "1 result")
    }

    @Test func aSearchThatFindsNothingSaysWhatToDoNext() {
        let presentation = TranscriptSegmentPresentation.make(
            segments: conversation,
            query: "kubernetes",
            locale: locale
        )
        #expect(presentation.turns.isEmpty)
        #expect(presentation.matchCount == 0)
        #expect(presentation.resultsText == "0 results")
        #expect(presentation.emptyMessage == "No results. Try another word.")
    }

    @Test func searchingIgnoresCaseAndAccents() {
        let segments = [
            segment(id: "a", speakerKey: "s1", label: "You", isCurrentUser: true,
                    text: "Send the résumé today.", start: 0)
        ]
        #expect(
            TranscriptSegmentPresentation
                .make(segments: segments, query: "RESUME", locale: locale)
                .matchCount == 1
        )
        #expect(
            TranscriptSegmentPresentation
                .make(segments: segments, query: "Today", locale: locale)
                .matchCount == 1
        )
    }

    @Test func matchedAndPlainRunsRebuildTheOriginalLine() throws {
        let text = "Plan the plan before the plan."
        let runs = TranscriptSegmentPresentation.runs(in: text, query: "plan")

        #expect(runs.map(\.text).joined() == text)
        #expect(runs.filter(\.isMatch).count == 3)
        // Alternating, and never two matches in a row for a non-empty gap.
        #expect(runs.map(\.isMatch) == [true, false, true, false, true, false])
        // Highlighting is what the person typed, in the transcript's own case.
        #expect(runs.filter(\.isMatch).map(\.text) == ["Plan", "plan", "plan"])
        #expect(runs.map(\.id) == Array(0..<runs.count))
    }

    @Test func aParagraphWithNoMatchHasNoRunsAndIsDroppedByTheFilter() {
        #expect(TranscriptSegmentPresentation.runs(in: "Nothing here", query: "zzz").isEmpty)
        #expect(TranscriptSegmentPresentation.runs(in: "", query: nil).isEmpty)
    }

    // MARK: - Live text

    @Test func committedTextSplitsIntoSentencesAndTheLastOneIsCurrent() throws {
        let lines = TranscriptSegmentPresentation.liveLines(
            committed: "We shipped the migration. The store held. What is next?"
        )
        #expect(lines.map(\.text) == [
            "We shipped the migration.",
            "The store held.",
            "What is next?"
        ])
        #expect(lines.map(\.isCurrent) == [false, false, true])
        #expect(lines.allSatisfy { $0.tentativeTail == nil })
        #expect(lines.map(\.id) == [0, 1, 2])
    }

    @Test func theTentativeTailHangsOffTheNewestLineOnly() throws {
        let lines = TranscriptSegmentPresentation.liveLines(
            committed: "We shipped the migration.",
            tentative: "and the store"
        )
        #expect(lines.count == 1)
        let line = try #require(lines.first)
        #expect(line.text == "We shipped the migration.")
        #expect(line.tentativeTail == "and the store")
        #expect(line.isCurrent)
    }

    @Test func theFirstWordsOfACaptureAreAllTentative() throws {
        let lines = TranscriptSegmentPresentation.liveLines(committed: "", tentative: "so I think")
        #expect(lines.count == 1)
        let line = try #require(lines.first)
        #expect(line.text.isEmpty)
        #expect(line.tentativeTail == "so I think")
        #expect(line.isCurrent)
    }

    @Test func aCaptureThatHasHeardNothingHasNoLines() {
        #expect(TranscriptSegmentPresentation.liveLines(committed: "", tentative: "").isEmpty)
        #expect(TranscriptSegmentPresentation.liveLines(committed: "   ").isEmpty)
    }

    @Test func aRunOfTerminatorsAndNewlinesStaysWithItsOwnLine() {
        let lines = TranscriptSegmentPresentation.liveLines(
            committed: "Really?! Yes.\nSecond paragraph"
        )
        #expect(lines.map(\.text) == ["Really?!", "Yes.", "Second paragraph"])
    }

    @Test func textWithNoTerminatorStaysOneLine() {
        let lines = TranscriptSegmentPresentation.liveLines(
            committed: "one long thought with no full stop"
        )
        #expect(lines.map(\.text) == ["one long thought with no full stop"])
        #expect(lines.first?.isCurrent == true)
    }

    @Test func theCollapsedRowShowsTheNewestLineAndItsTail() {
        #expect(
            TranscriptSegmentPresentation.collapsedLine(
                committed: "First sentence. Second sentence.",
                tentative: "and then",
                locale: locale
            ) == "Second sentence. and then"
        )
        #expect(
            TranscriptSegmentPresentation.collapsedLine(
                committed: "",
                tentative: "so I think",
                locale: locale
            ) == "so I think"
        )
    }

    @Test func aSilentCaptureSaysItIsListeningRatherThanShowingAnEmptyRow() {
        #expect(
            TranscriptSegmentPresentation.collapsedLine(committed: "", locale: locale)
                == "Listening…"
        )
    }

    @Test func theSheetFollowsLiveUntilTheReaderScrollsUp() {
        #expect(TranscriptSegmentPresentation.followsLive(distanceFromBottom: 0))
        #expect(TranscriptSegmentPresentation.followsLive(distanceFromBottom: 24))
        #expect(!TranscriptSegmentPresentation.followsLive(distanceFromBottom: 25))
        #expect(!TranscriptSegmentPresentation.followsLive(distanceFromBottom: 400))
    }
}

@Suite("Live transcript sheet geometry (WP5)")
struct TranscriptSheetGeometryTests {

    private func height(_ detent: TranscriptSheetDetent, _ canvas: CGFloat) -> CGFloat {
        TranscriptSheetGeometry.height(for: detent, canvasHeight: canvas)
    }

    @Test func theCollapsedSheetIsOneRowWhateverTheWindowDoes() {
        #expect(height(.collapsed, 900) == 36)
        #expect(height(.collapsed, 200) == 36)
    }

    @Test func theSnapPointsAreFractionsOfTheCanvas() {
        // The design's default window: 40% is 300, 70% is 525.
        #expect(height(.medium, 750) == 300)
        #expect(height(.expanded, 750) == 525)
    }

    @Test func aShortWindowGetsTheFloorRatherThanASliver() {
        // 40% of the minimum window is exactly the floor, and nothing goes under it.
        #expect(height(.medium, 650) == 260)
        #expect(height(.medium, 400) == 260)
        #expect(height(.expanded, 400) == 280)
    }

    @Test func noSnapPointEverExceedsTheCanvas() {
        for canvas in stride(from: CGFloat(120), through: 1200, by: 40) {
            for detent in TranscriptSheetDetent.allCases {
                #expect(height(detent, canvas) <= max(36, canvas))
            }
            #expect(height(.collapsed, canvas) <= height(.medium, canvas))
            #expect(height(.medium, canvas) <= height(.expanded, canvas))
        }
    }

    @Test func aDraggedSheetLandsOnTheNearestSnapPoint() {
        let canvas: CGFloat = 750
        #expect(TranscriptSheetGeometry.nearestDetent(toHeight: 40, canvasHeight: canvas) == .collapsed)
        #expect(TranscriptSheetGeometry.nearestDetent(toHeight: 280, canvasHeight: canvas) == .medium)
        #expect(TranscriptSheetGeometry.nearestDetent(toHeight: 500, canvasHeight: canvas) == .expanded)
        #expect(TranscriptSheetGeometry.nearestDetent(toHeight: 9_000, canvasHeight: canvas) == .expanded)
    }

    @Test func aTieSettlesOnTheSmallerSheet() {
        // Exactly between collapsed (36) and medium (300) at a 750 canvas.
        #expect(TranscriptSheetGeometry.nearestDetent(toHeight: 168, canvasHeight: 750) == .collapsed)
    }

    @Test func onlyAnOpenSheetCountsAsOpen() {
        #expect(!TranscriptSheetDetent.collapsed.isOpen)
        #expect(TranscriptSheetDetent.medium.isOpen)
        #expect(TranscriptSheetDetent.expanded.isOpen)
    }
}
