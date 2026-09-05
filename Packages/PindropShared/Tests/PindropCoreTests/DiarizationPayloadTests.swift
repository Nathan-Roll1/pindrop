//
//  DiarizationPayloadTests.swift
//  PindropCoreTests
//
//  Created on 2026-08-31.
//
//  The blob in `TranscriptionRecord.diarizationSegmentsJSON` is read by builds
//  that predate its live-attribution keys and written by builds that have them,
//  so both directions are asserted here rather than assumed.
//

import Foundation
import PindropCore
import Testing

@Suite
struct DiarizationPayloadTests {

    private func segment(
        speakerId: String = "speaker-1",
        speakerLabel: String = "Speaker 1",
        startTime: TimeInterval = 0,
        endTime: TimeInterval = 4,
        text: String = "Hello"
    ) -> DiarizedTranscriptSegment {
        DiarizedTranscriptSegment(
            speakerId: speakerId,
            speakerLabel: speakerLabel,
            startTime: startTime,
            endTime: endTime,
            confidence: 1,
            text: text
        )
    }

    // MARK: - The old shape

    @Test func aBlobWithoutTheNewKeysDecodesExactlyAsBefore() throws {
        let segments = [segment(), segment(speakerId: "speaker-2", startTime: 4, endTime: 8)]
        let json = String(decoding: try JSONEncoder().encode(segments), as: UTF8.self)

        let decoded = try #require(DiarizedTranscriptSegment.decodeSegments(fromJSON: json))
        #expect(decoded == segments)

        let payload = try #require(DiarizationPayload.decode(fromJSON: json))
        #expect(payload.segments == segments)
        #expect(payload.micOnlyRanges.isEmpty)
        #expect(payload.liveLabelsDiffered == false)
    }

    @Test func aPayloadWithNothingToAddIsStillWrittenAsABareArray() throws {
        let segments = [segment()]
        let json = try DiarizationPayload(segments: segments).encodedJSON()

        // A build that predates these keys decodes the blob as a plain array,
        // so nothing this build writes for an ordinary capture is lost to it.
        let asArray = try JSONDecoder().decode([DiarizedTranscriptSegment].self, from: Data(json.utf8))
        #expect(asArray == segments)
    }

    // MARK: - The new shape

    @Test func micOnlyRangesAndTheDifferedFlagRoundTrip() throws {
        let payload = DiarizationPayload(
            segments: [segment()],
            micOnlyRanges: [MicOnlyRange(startTime: 1, endTime: 3)],
            liveLabelsDiffered: true
        )

        let decoded = try #require(DiarizationPayload.decode(fromJSON: try payload.encodedJSON()))
        #expect(decoded == payload)
    }

    @Test func theNewShapeStillAnswersTheSegmentsQuery() throws {
        let segments = [segment()]
        let json = try DiarizationPayload(
            segments: segments,
            micOnlyRanges: [MicOnlyRange(startTime: 0, endTime: 2)]
        ).encodedJSON()

        #expect(DiarizedTranscriptSegment.decodeSegments(fromJSON: json) == segments)
    }

    // MARK: - Degrading

    @Test func aMalformedPayloadStillDecodesToNil() {
        #expect(DiarizedTranscriptSegment.decodeSegments(fromJSON: "{not json") == nil)
        #expect(DiarizationPayload.decode(fromJSON: "{not json") == nil)
        #expect(DiarizedTranscriptSegment.decodeSegments(fromJSON: nil) == nil)
        #expect(DiarizationPayload.decode(fromJSON: nil) == nil)
    }

    // MARK: - The recorder rule

    @Test func overlapAgainstMicOnlyRangesSumsEveryRange() {
        let ranges = [
            MicOnlyRange(startTime: 0, endTime: 2),
            MicOnlyRange(startTime: 5, endTime: 9)
        ]

        #expect(MicOnlyRange.overlap(of: ranges, withStart: 1, end: 6) == 2)
        #expect(MicOnlyRange.overlap(of: ranges, withStart: 2, end: 5) == 0)
        #expect(MicOnlyRange.overlap(of: [], withStart: 0, end: 10) == 0)
    }
}
