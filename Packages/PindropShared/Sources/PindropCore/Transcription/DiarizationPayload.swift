//
//  DiarizationPayload.swift
//  PindropCore
//
//  Created on 2026-08-31.
//
//  Everything a finished capture knows about who was talking, inside the one
//  JSON attribute that already carries its speaker segments.
//
//  Persistence is frozen: no `@Model` gains a field for any of this. The blob
//  was a bare array of segments and still is written that way whenever there is
//  nothing else to say, so a build that predates these keys keeps reading every
//  ordinary note this one writes. When there is something else to say the blob
//  becomes an object with the segments under `segments`, and an older build
//  reads that as a malformed payload and degrades to no attribution, which is
//  the documented behaviour of `decodeSegments(fromJSON:)`.
//

import Foundation

/// A stretch of capture time where the microphone gate was open and the system
/// gate was shut.
///
/// The two signals the echo gate already reads, so accumulating this costs the
/// capture path nothing. Times are capture time: seconds since the capture's
/// first audio buffer, the same clock the transcript spans are measured on.
public struct MicOnlyRange: Codable, Sendable, Equatable {
    /// The share of one speaker's speech that has to fall inside these ranges
    /// before the speaker is the person recording.
    ///
    /// A majority, not any overlap. The microphone hears the room as well as
    /// its owner, and the far end leaks into it, so a passing overlap is
    /// evidence of leakage while a majority is evidence of ownership.
    public static let recorderMajority: Double = 0.5

    public let startTime: TimeInterval
    public let endTime: TimeInterval

    public init(startTime: TimeInterval, endTime: TimeInterval) {
        self.startTime = startTime
        self.endTime = endTime
    }

    public var duration: TimeInterval {
        max(0, endTime - startTime)
    }

    /// How much of `start..<end` falls inside `ranges`.
    ///
    /// Ranges are accumulated already coalesced, so overlapping ranges cannot
    /// double count here.
    public static func overlap(
        of ranges: [MicOnlyRange],
        withStart start: TimeInterval,
        end: TimeInterval
    ) -> TimeInterval {
        ranges.reduce(0) { total, range in
            total + max(0, min(range.endTime, end) - max(range.startTime, start))
        }
    }
}

/// The whole of `TranscriptionRecord.diarizationSegmentsJSON`, in one value.
public struct DiarizationPayload: Sendable, Equatable {
    public let segments: [DiarizedTranscriptSegment]
    public let micOnlyRanges: [MicOnlyRange]
    /// True when the finished labels disagree with what the live sheet showed.
    /// Drives the one line the note page owes a reader who watched a name for
    /// an hour, and is cleared when they dismiss it.
    public let liveLabelsDiffered: Bool

    public init(
        segments: [DiarizedTranscriptSegment],
        micOnlyRanges: [MicOnlyRange] = [],
        liveLabelsDiffered: Bool = false
    ) {
        self.segments = segments
        self.micOnlyRanges = micOnlyRanges
        self.liveLabelsDiffered = liveLabelsDiffered
    }

    /// True when this payload carries anything the bare segment array cannot.
    public var hasLiveAttribution: Bool {
        !micOnlyRanges.isEmpty || liveLabelsDiffered
    }
}

extension DiarizationPayload: Codable {
    private enum CodingKeys: String, CodingKey {
        case segments
        case micOnlyRanges
        case liveLabelsDiffered
    }

    public init(from decoder: Decoder) throws {
        // The bare array first: it is what every build before these keys wrote,
        // and what this one still writes for an ordinary capture.
        if let container = try? decoder.singleValueContainer(),
           let segments = try? container.decode([DiarizedTranscriptSegment].self) {
            self.init(segments: segments)
            return
        }
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            segments: try container.decode([DiarizedTranscriptSegment].self, forKey: .segments),
            micOnlyRanges: try container.decodeIfPresent([MicOnlyRange].self, forKey: .micOnlyRanges) ?? [],
            liveLabelsDiffered: try container.decodeIfPresent(Bool.self, forKey: .liveLabelsDiffered) ?? false
        )
    }

    public func encode(to encoder: Encoder) throws {
        guard hasLiveAttribution else {
            var container = encoder.singleValueContainer()
            try container.encode(segments)
            return
        }
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(segments, forKey: .segments)
        try container.encode(micOnlyRanges, forKey: .micOnlyRanges)
        try container.encode(liveLabelsDiffered, forKey: .liveLabelsDiffered)
    }
}

extension DiarizationPayload {
    /// Reads the payload persisted beside one transcript revision or record.
    ///
    /// Nil when there is none and when it cannot be read. Speaker attribution
    /// is optional enrichment: a malformed payload degrades to the
    /// un-attributed whole span instead of failing the read that needs it.
    public static func decode(fromJSON json: String?) -> DiarizationPayload? {
        guard let json else { return nil }
        return try? JSONDecoder().decode(DiarizationPayload.self, from: Data(json.utf8))
    }

    /// The stored form. Keys are sorted so one payload has one encoding, which
    /// is what lets a test compare two blobs directly.
    public func encodedJSON() throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return String(decoding: try encoder.encode(self), as: UTF8.self)
    }

    /// The same payload with different segments, keeping everything the live
    /// path recorded. Used by every path that relabels a speaker after the
    /// fact, so a rename cannot silently drop the recorder's own channel.
    public func replacingSegments(_ segments: [DiarizedTranscriptSegment]) -> DiarizationPayload {
        DiarizationPayload(
            segments: segments,
            micOnlyRanges: micOnlyRanges,
            liveLabelsDiffered: liveLabelsDiffered
        )
    }

    /// The same payload with the reconciliation flag cleared.
    ///
    /// The dismissal has to be durable: the line is owed once, not once per
    /// launch. Everything else the payload carries is kept, because the
    /// mic-only ranges are still what makes the recorder "You".
    public func clearingLiveLabelsDiffered() -> DiarizationPayload {
        DiarizationPayload(
            segments: segments,
            micOnlyRanges: micOnlyRanges,
            liveLabelsDiffered: false
        )
    }
}
