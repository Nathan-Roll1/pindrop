// Created on 2026-07-22

import Foundation

/// Sync-safe diarization segment without local profile or embedding state.
public struct PortableDiarizationSegment: Codable, Equatable, Sendable {
    public let speakerID: String
    public let speakerLabel: String
    public let startTime: TimeInterval
    public let endTime: TimeInterval
    public let text: String

    public init(
        speakerID: String,
        speakerLabel: String,
        startTime: TimeInterval,
        endTime: TimeInterval,
        text: String
    ) {
        self.speakerID = speakerID
        self.speakerLabel = speakerLabel
        self.startTime = startTime
        self.endTime = endTime
        self.text = text
    }
}
