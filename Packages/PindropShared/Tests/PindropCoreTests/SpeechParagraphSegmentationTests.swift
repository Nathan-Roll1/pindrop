//
//  SpeechParagraphSegmentationTests.swift
//  PindropCoreTests
//
//  Created on 2026-08-22.
//

import Foundation
import Testing
@testable import PindropCore

@Suite
struct SpeechParagraphSegmentationTests {

    private typealias Segmentation = SpeechParagraphSegmentation
    private typealias Interval = SpeechParagraphSegmentation.SpeechInterval

    // MARK: - Grouping

    @Test func gapsShorterThanTheThresholdStayInOneParagraph() {
        let groups = Segmentation.paragraphGroups(
            in: [
                Interval(startTime: 0, endTime: 3),
                Interval(startTime: 3.4, endTime: 6)
            ],
            chunkDuration: 10,
            pauseThreshold: Segmentation.paragraphPauseThreshold
        )

        #expect(groups.count == 1)
        #expect(groups[0].startTime == 0)
        #expect(groups[0].endTime == 6)
    }

    @Test func gapsAtOrOverTheThresholdBreakTheParagraph() {
        let groups = Segmentation.paragraphGroups(
            in: [
                Interval(startTime: 0, endTime: 3),
                Interval(startTime: 3 + Segmentation.paragraphPauseThreshold, endTime: 6)
            ],
            chunkDuration: 10,
            pauseThreshold: Segmentation.paragraphPauseThreshold
        )

        #expect(groups.count == 2)
    }

    @Test func intervalsAreClampedSortedAndMergedWhenTheyOverlap() {
        let groups = Segmentation.paragraphGroups(
            in: [
                Interval(startTime: 4, endTime: 12),
                Interval(startTime: -1, endTime: 2),
                Interval(startTime: 4.5, endTime: 5),
                Interval(startTime: 7, endTime: 7)
            ],
            chunkDuration: 10,
            pauseThreshold: 1.2
        )

        #expect(groups.count == 2)
        #expect(groups[0].startTime == 0)
        #expect(groups[0].endTime == 2)
        #expect(groups[1].startTime == 4)
        #expect(groups[1].endTime == 10)
    }

    // MARK: - Paragraph spans

    @Test func pausesBecomeParagraphSpansThatCoverTheChunkInOrder() throws {
        let text = "One two three four. Five six seven eight. Nine ten eleven twelve."
        let segments = try #require(
            Segmentation.paragraphSegments(
                text: text,
                speechIntervals: [
                    Interval(startTime: 0, endTime: 4),
                    Interval(startTime: 6, endTime: 10),
                    Interval(startTime: 12, endTime: 16)
                ],
                chunkDuration: 16
            )
        )

        #expect(segments.count == 3)
        #expect(segments.map(\.text) == [
            "One two three four.",
            "Five six seven eight.",
            "Nine ten eleven twelve."
        ])
        #expect(segments[0].startTime == 0)
        #expect(segments[2].endTime == 16)
        for (previous, current) in zip(segments, segments.dropFirst()) {
            #expect(previous.endTime <= current.startTime)
        }
    }

    @Test func everyParagraphCarriesTheSameSpeakerSoTheReaderSeesOneVoice() throws {
        let segments = try #require(
            Segmentation.paragraphSegments(
                text: "First thought here. Second thought here.",
                speechIntervals: [
                    Interval(startTime: 0, endTime: 3),
                    Interval(startTime: 6, endTime: 9)
                ],
                chunkDuration: 9
            )
        )

        #expect(Set(segments.map(\.speakerId)) == [SpeechParagraphSegmentation.soloSpeakerIdentifier])
        #expect(Set(segments.map(\.speakerLabel)) == [SpeechParagraphSegmentation.soloSpeakerLabel])
    }

    @Test func joinedParagraphTextGivesTheChunkTextBack() throws {
        let text = "Ship the migration first. Then rebuild the store. Tell the team on Friday."
        let segments = try #require(
            Segmentation.paragraphSegments(
                text: text,
                speechIntervals: [
                    Interval(startTime: 0, endTime: 5),
                    Interval(startTime: 8, endTime: 13),
                    Interval(startTime: 16, endTime: 21)
                ],
                chunkDuration: 21
            )
        )

        #expect(segments.map(\.text).joined(separator: " ") == text)
    }

    @Test func spansNeverStartBeforeZeroOrRunPastTheChunk() throws {
        let segments = try #require(
            Segmentation.paragraphSegments(
                text: "Alpha beta. Gamma delta.",
                speechIntervals: [
                    Interval(startTime: -2, endTime: 3),
                    Interval(startTime: 7, endTime: 40)
                ],
                chunkDuration: 12
            )
        )

        #expect(segments.allSatisfy { $0.startTime >= 0 })
        #expect(segments.allSatisfy { $0.endTime <= 12 })
        #expect(segments.allSatisfy { $0.endTime > $0.startTime })
    }

    // MARK: - Reading as one block

    @Test func oneUninterruptedStretchReadsAsOneBlock() {
        #expect(
            Segmentation.paragraphSegments(
                text: "One thought. Another thought.",
                speechIntervals: [Interval(startTime: 0, endTime: 8)],
                chunkDuration: 8
            ) == nil
        )
    }

    @Test func noSpeechIntervalsReadAsOneBlock() {
        #expect(
            Segmentation.paragraphSegments(
                text: "One thought. Another thought.",
                speechIntervals: [],
                chunkDuration: 8
            ) == nil
        )
    }

    @Test func oneSentenceAcrossManyPausesReadsAsOneBlock() {
        #expect(
            Segmentation.paragraphSegments(
                text: "a single run of words with no terminator",
                speechIntervals: [
                    Interval(startTime: 0, endTime: 3),
                    Interval(startTime: 6, endTime: 9)
                ],
                chunkDuration: 9
            ) == nil
        )
    }

    @Test func emptyTextReadsAsOneBlock() {
        #expect(
            Segmentation.paragraphSegments(
                text: "   ",
                speechIntervals: [
                    Interval(startTime: 0, endTime: 3),
                    Interval(startTime: 6, endTime: 9)
                ],
                chunkDuration: 9
            ) == nil
        )
    }

    @Test func aChunkWithNoDurationReadsAsOneBlock() {
        #expect(
            Segmentation.paragraphSegments(
                text: "One. Two.",
                speechIntervals: [
                    Interval(startTime: 0, endTime: 3),
                    Interval(startTime: 6, endTime: 9)
                ],
                chunkDuration: 0
            ) == nil
        )
    }

    // MARK: - Alignment

    @Test func fewerSentencesThanPausesStillCoversEveryPause() throws {
        let segments = try #require(
            Segmentation.paragraphSegments(
                text: "First. Second.",
                speechIntervals: [
                    Interval(startTime: 0, endTime: 2),
                    Interval(startTime: 5, endTime: 7),
                    Interval(startTime: 10, endTime: 12),
                    Interval(startTime: 15, endTime: 17)
                ],
                chunkDuration: 17
            )
        )

        #expect(segments.count <= 2)
        #expect(segments.map(\.text).joined(separator: " ") == "First. Second.")
        #expect(segments[0].startTime == 0)
        #expect(segments[segments.count - 1].endTime == 17)
    }

    @Test func sentencesNeverMoveBackwardsThroughTheParagraphs() {
        let sentences = ["a.", "bbbbbbbbbbbbbbbbbbbb.", "c.", "d."]
        let assignments = Segmentation.assign(
            sentences: sentences,
            to: [
                Interval(startTime: 0, endTime: 1),
                Interval(startTime: 4, endTime: 20),
                Interval(startTime: 24, endTime: 25)
            ]
        )

        #expect(assignments.count == sentences.count)
        for (previous, current) in zip(assignments, assignments.dropFirst()) {
            #expect(current >= previous)
        }
    }

    @Test func voiceSegmentsReadTheirTimesWithoutTouchingSamples() throws {
        let segments = try #require(
            Segmentation.paragraphSegments(
                text: "Start of it. End of it.",
                voiceSegments: [
                    VoiceSegment(startTime: 0, endTime: 3, samples: []),
                    VoiceSegment(startTime: 6, endTime: 9, samples: [])
                ],
                chunkDuration: 9
            )
        )

        #expect(segments.count == 2)
    }

    // MARK: - Sentences

    @Test func sentenceSplittingKeepsTerminatorsAndClosingMarks() {
        #expect(
            Segmentation.sentences(in: #"Really?! He said "yes." Then he left."#)
                == [#"Really?!"#, #"He said "yes.""#, "Then he left."]
        )
    }

    @Test func textWithNoTerminatorStaysOneSentence() {
        #expect(Segmentation.sentences(in: "no terminator here") == ["no terminator here"])
    }
}
