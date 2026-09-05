//
//  TranscriptionRecordMetadataTests.swift
//  PindropDataTests
//
//  Created on 2026-07-09.
//

import Foundation
import Testing
import PindropCore
@testable import PindropData

@Suite
struct TranscriptionRecordMetadataTests {

    private func makeRecord(
        diarizationJSON: String? = nil,
        aiSummary: String? = nil,
        text: String = "hello"
    ) -> TranscriptionRecord {
        TranscriptionRecord(
            text: text,
            duration: 1.0,
            modelUsed: "base",
            diarizationSegmentsJSON: diarizationJSON,
            aiSummary: aiSummary
        )
    }

    private func segmentsJSON(_ segments: [DiarizedTranscriptSegment]) throws -> String {
        let data = try JSONEncoder().encode(segments)
        return try #require(String(data: data, encoding: .utf8))
    }

    @Test func speakerCountIsZeroWithoutDiarization() {
        let record = makeRecord()
        #expect(record.speakerCount == 0)
        #expect(!record.isDiarized)
        #expect(!record.hasSummary)
    }

    @Test func speakerCountCountsDistinctSpeakerIds() throws {
        let segments = [
            DiarizedTranscriptSegment(
                speakerId: "s1",
                speakerLabel: "Alice",
                startTime: 0,
                endTime: 1,
                confidence: 1,
                text: "Hi"
            ),
            DiarizedTranscriptSegment(
                speakerId: "s2",
                speakerLabel: "Bob",
                startTime: 1,
                endTime: 2,
                confidence: 1,
                text: "Hello"
            ),
            DiarizedTranscriptSegment(
                speakerId: "s1",
                speakerLabel: "Alice",
                startTime: 2,
                endTime: 3,
                confidence: 1,
                text: "Again"
            )
        ]
        let record = makeRecord(diarizationJSON: try segmentsJSON(segments))
        #expect(record.speakerCount == 2)
        #expect(record.isDiarized)
    }

    @Test func hasSummaryRequiresNonEmptyText() {
        #expect(!makeRecord(aiSummary: nil).hasSummary)
        #expect(!makeRecord(aiSummary: "   ").hasSummary)
        #expect(makeRecord(aiSummary: "Roadmap risks").hasSummary)
    }
}
