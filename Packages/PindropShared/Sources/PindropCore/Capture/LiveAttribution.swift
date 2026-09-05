//
//  LiveAttribution.swift
//  PindropCore
//
//  Created on 2026-08-31.
//
//  What a live transcript knows about who is talking, while it is still
//  talking. Live attribution is provisional by construction: the offline pass
//  at finalize is the record, and it replaces every label written here.
//

import Foundation

/// How much a live speaker label is worth.
///
/// The tiers are ordered. A label may move up a tier during a capture. It never
/// moves down: a name that was shown once is not taken away mid-recording.
public enum LiveSpeakerTier: String, Codable, Sendable, Equatable, Comparable {
    /// Attributed only by the capture channel the audio arrived on.
    case channel
    /// Attributed to one streaming-diarizer slot with no name yet.
    case provisional
    /// Matched to a participant profile.
    case named

    private var rank: Int {
        switch self {
        case .channel: 0
        case .provisional: 1
        case .named: 2
        }
    }

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rank < rhs.rank }
}

/// Who one piece of live text belongs to.
///
/// `key` groups every span of one speaker within one capture. It is stable for
/// the life of the capture even when the tier or the display name changes, so
/// the interface can promote a label in place instead of splitting a turn.
public struct LiveSpeakerRef: Codable, Sendable, Equatable, Hashable, Identifiable {
    public var id: String { key }

    public let key: String
    public let tier: LiveSpeakerTier
    /// True only for the microphone channel of the person recording.
    public let isCurrentUser: Bool
    /// The streaming-diarizer slot, 1-based, when the tier is `.provisional`
    /// or `.named`. The interface prints "Speaker \(slotNumber)" in its own
    /// language rather than trusting a model-supplied English string.
    public let slotNumber: Int?
    public let profileID: UUID?
    /// A profile's name. Nil at every tier below `.named`.
    public let displayName: String?
    /// When this reference last moved up a tier, and what it used to read.
    /// Both are nil until the first promotion. They are the whole state the
    /// interface needs to draw the relabel cue: the cue is *derived* from a
    /// time window against `promotedAt`, never stored as a one-shot flag,
    /// because SwiftUI cannot deliver "true for exactly one render pass".
    public let promotedAt: Date?
    public let previousDisplayName: String?

    public init(
        key: String,
        tier: LiveSpeakerTier,
        isCurrentUser: Bool = false,
        slotNumber: Int? = nil,
        profileID: UUID? = nil,
        displayName: String? = nil,
        promotedAt: Date? = nil,
        previousDisplayName: String? = nil
    ) {
        self.key = key
        self.tier = tier
        self.isCurrentUser = isCurrentUser
        self.slotNumber = slotNumber
        self.profileID = profileID
        self.displayName = displayName
        self.promotedAt = promotedAt
        self.previousDisplayName = previousDisplayName
    }

    /// The person recording. Their channel is known from the first sample, so
    /// this reference never changes during a capture.
    public static let currentUser = LiveSpeakerRef(
        key: "channel.microphone",
        tier: .channel,
        isCurrentUser: true
    )

    /// Everything arriving on the system-audio channel before any model has
    /// separated it. One reference covers every remote voice.
    public static let systemChannel = LiveSpeakerRef(
        key: "channel.systemAudio",
        tier: .channel
    )

    public static func channel(for source: CaptureSourceKind) -> LiveSpeakerRef {
        switch source {
        case .microphone: .currentUser
        case .systemAudio: .systemChannel
        }
    }
}

/// Why one span of live text ended.
public enum LiveTurnBoundaryReason: String, Codable, Sendable, Equatable {
    /// The other capture channel took the engine.
    case channelChange
    /// The non-owning channel spoke for long enough that the loss is worth
    /// showing. Closes the open span so the marker sits where the speech was.
    case crossTalkDropped
    /// The streaming diarizer reported a different speaker on the same channel.
    case speakerChange
    /// The engine reported a finished utterance.
    case endOfUtterance
    /// Nobody spoke for long enough to end a paragraph.
    case idlePause
    /// The capture stopped.
    case sessionEnd

    /// True for the two boundaries the streaming engine produces on its own.
    /// At one of these the engine has just flushed and committed a chunk, so a
    /// pending handover may land on it and "everything committed belongs to the
    /// outgoing channel" is exact by ordering. Every other reason is written by
    /// the app onto text the engine already settled, and splicing a channel
    /// there would put two voices inside one decoded chunk.
    public var isEngineProduced: Bool {
        switch self {
        case .endOfUtterance, .idlePause: true
        case .channelChange, .crossTalkDropped, .speakerChange, .sessionEnd: false
        }
    }
}

/// What one entry in the live transcript is.
public enum LiveSpanKind: String, Codable, Sendable, Equatable {
    /// Words the live engine decoded.
    case text
    /// Speech the live engine never heard, because the other channel owned the
    /// engine. It carries no text. The durable spool has the audio and the
    /// finished note has the words, and the reader is told so rather than
    /// shown a transcript that reads as continuous.
    case droppedSpeech
}

/// One settled paragraph of live text with the speaker it belongs to, or one
/// marker for speech the live engine missed.
///
/// The live counterpart of `TranscriptSegmentSnapshot`. Times are capture time:
/// seconds since the capture's first audio buffer.
public struct LiveTranscriptSpan: Sendable, Equatable, Identifiable {
    /// Ordinal within the capture. Stable across relabels.
    public let id: Int
    public let kind: LiveSpanKind
    public let speaker: LiveSpeakerRef
    /// Always empty when `kind` is `.droppedSpeech`.
    public let text: String
    public let startOffset: TimeInterval
    public let duration: TimeInterval
    public let boundaryReason: LiveTurnBoundaryReason

    public var isText: Bool { kind == .text }

    public init(
        id: Int,
        kind: LiveSpanKind = .text,
        speaker: LiveSpeakerRef,
        text: String,
        startOffset: TimeInterval,
        duration: TimeInterval,
        boundaryReason: LiveTurnBoundaryReason
    ) {
        self.id = id
        self.kind = kind
        self.speaker = speaker
        self.text = text
        self.startOffset = startOffset
        self.duration = duration
        self.boundaryReason = boundaryReason
    }
}

/// The tail the engine may still rewrite, with the speaker it is being
/// attributed to right now. Drawn in the quiet ink.
public struct LiveTentativeSpan: Sendable, Equatable {
    public let speaker: LiveSpeakerRef
    public let text: String

    public init(speaker: LiveSpeakerRef, text: String) {
        self.speaker = speaker
        self.text = text
    }
}
