import Foundation
import PindropCore

/// A stable reference to a precise source span used to generate a meeting note.
public struct MeetingNoteCitation: Codable, Sendable, Equatable {
    public let identifier: String
    public let transcriptRevisionID: UUID
    public let startTime: TimeInterval
    public let endTime: TimeInterval
    public let speakerLabel: String?
    public let text: String

    public init(
        identifier: String,
        transcriptRevisionID: UUID,
        startTime: TimeInterval,
        endTime: TimeInterval,
        speakerLabel: String?,
        text: String
    ) {
        self.identifier = identifier
        self.transcriptRevisionID = transcriptRevisionID
        self.startTime = startTime
        self.endTime = endTime
        self.speakerLabel = speakerLabel
        self.text = text
    }
}

/// Deterministic evidence used to generate an auditable meeting note.
public struct MeetingNoteSourceBundle: Sendable, Equatable {
    public let evidenceInput: String
    public let citations: [MeetingNoteCitation]
    public let sourceTranscriptRevisionIDs: [UUID]

    public init(
        evidenceInput: String,
        citations: [MeetingNoteCitation],
        sourceTranscriptRevisionIDs: [UUID]
    ) {
        self.evidenceInput = evidenceInput
        self.citations = citations
        self.sourceTranscriptRevisionIDs = sourceTranscriptRevisionIDs
    }
}

public enum MeetingNoteDerivationError: Error, Equatable, LocalizedError {
    case invalidCheckpoint(sequence: Int)
    case duplicateCheckpointSequence(Int)
    case duplicateTranscriptRevisionID(UUID)
    case noTranscriptSources

    public var errorDescription: String? {
        switch self {
        case .invalidCheckpoint(let sequence):
            "The transcription checkpoint at sequence \(sequence) is invalid."
        case .duplicateCheckpointSequence(let sequence):
            "The transcription checkpoint sequence \(sequence) is duplicated."
        case .duplicateTranscriptRevisionID(let revisionID):
            "The transcript revision \(revisionID.uuidString) is duplicated."
        case .noTranscriptSources:
            "At least one transcription checkpoint is required."
        }
    }
}

/// Derives citation-marked evidence from finalized meeting chunks.
public enum MeetingNoteDerivation {
    private static let posixLocale = Locale(identifier: "en_US_POSIX")
    private static let citationAppendixPattern = #"(?im)^\h*(?:#{1,6}\h*)?[CcСсΣσςϹϲᏟ][IiІіΙιı][TtТтΤτ][AaАаΑα][TtТтΤτ][IiІіΙιı][OoОоΟο][Nn]\h+[AaАаΑα][PpРрΡρ][PpРрΡρ][EeЕеΕε][Nn][DdԀԁ][IiІіΙιı][XxХхΧχ]\h*:?[^\r\n]*(?:\r\n|\r|\n)?[\s\S]*"#
    private static let citationMarkerPattern = #"\[\h*[CcСсΣσςϹϲᏟ]\h*[\p{Nd}lLIiІіΙιı|](?:\h*[\p{Nd}lLIiІіΙιı|])*\h*\]"#

    public static func make(
        humanNoteContent: String,
        checkpoints: [MeetingTranscriptionCheckpoint]
    ) throws -> MeetingNoteSourceBundle {
        guard !checkpoints.isEmpty else {
            throw MeetingNoteDerivationError.noTranscriptSources
        }

        let orderedCheckpoints = checkpoints.sorted {
            if $0.sequence != $1.sequence {
                return $0.sequence < $1.sequence
            }
            return $0.revisionID.uuidString < $1.revisionID.uuidString
        }

        var seenSequences = Set<Int>()
        var seenRevisionIDs = Set<UUID>()
        var citations: [MeetingNoteCitation] = []
        var sourceTranscriptRevisionIDs: [UUID] = []
        citations.reserveCapacity(orderedCheckpoints.count)
        sourceTranscriptRevisionIDs.reserveCapacity(orderedCheckpoints.count)

        for checkpoint in orderedCheckpoints {
            guard seenSequences.insert(checkpoint.sequence).inserted else {
                throw MeetingNoteDerivationError.duplicateCheckpointSequence(checkpoint.sequence)
            }
            guard seenRevisionIDs.insert(checkpoint.revisionID).inserted else {
                throw MeetingNoteDerivationError.duplicateTranscriptRevisionID(checkpoint.revisionID)
            }
            guard isValid(checkpoint) else {
                throw MeetingNoteDerivationError.invalidCheckpoint(sequence: checkpoint.sequence)
            }

            sourceTranscriptRevisionIDs.append(checkpoint.revisionID)
            let checkpointCitations = makeCitations(for: checkpoint, startingAt: citations.count + 1)
            citations.append(contentsOf: checkpointCitations)
        }

        return MeetingNoteSourceBundle(
            evidenceInput: evidence(
                humanNoteContent: humanNoteContent,
                citations: citations
            ),
            citations: citations,
            sourceTranscriptRevisionIDs: sourceTranscriptRevisionIDs
        )
    }

    /// Removes model-generated content that could impersonate the application's citations.
    public static func sanitizingGeneratedContent(_ generatedContent: String) -> String {
        let normalized = normalizedForReservedMarkerDetection(generatedContent)
        let withoutForgedAppendix = normalized.replacingOccurrences(
            of: citationAppendixPattern,
            with: "",
            options: .regularExpression
        )
        return withoutForgedAppendix
            .replacingOccurrences(
                of: citationMarkerPattern,
                with: "",
                options: .regularExpression
            )
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Renders a citation as a single safe display line for trusted structural UI.
    public static func citationPresentationLine(_ citation: MeetingNoteCitation) -> String {
        let identifier = quotedSourceDisplay(citation.identifier)
        let speaker = quotedSourceDisplay(citation.speakerLabel ?? "(none)")
        let text = quotedSourceDisplay(citation.text)
        return "Source \(identifier) [\(timestamp(citation.startTime))–\(timestamp(citation.endTime))] Speaker: \(speaker) | \(text)"
    }

    /// Renders untrusted source text as a single quoted display line.
    public static func sourcePresentationText(_ source: String) -> String {
        quotedSourceDisplay(source)
    }

    private static func isValid(_ checkpoint: MeetingTranscriptionCheckpoint) -> Bool {
        guard
            checkpoint.sequence >= 0,
            checkpoint.startOffset.isFinite,
            checkpoint.startOffset >= 0,
            checkpoint.duration.isFinite,
            checkpoint.duration > 0,
            !checkpoint.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            return false
        }
        return (checkpoint.startOffset + checkpoint.duration).isFinite
    }

    /// The diarized spans that describe one checkpoint exactly, or nil when the
    /// whole checkpoint has to be read as a single un-attributed span.
    ///
    /// The evidence a note is generated from and the transcript a person reads
    /// must agree span for span, so both resolve their spans here. Segments are
    /// accepted only when every one of them fits inside the checkpoint, they run
    /// in order without overlapping, and their joined text is the checkpoint's
    /// text. Anything else is enrichment this build cannot trust.
    public static func usableDiarizedSegments(
        for checkpoint: MeetingTranscriptionCheckpoint
    ) -> [DiarizedTranscriptSegment]? {
        guard
            let segments = DiarizedTranscriptSegment.decodeSegments(
                fromJSON: checkpoint.segmentsJSON
            ),
            !segments.isEmpty,
            segments.allSatisfy({ isValid($0, within: checkpoint) }),
            areOrderedAndNonOverlapping(segments),
            normalizedTranscriptText(segments.map(\.text).joined(separator: " "))
                == normalizedTranscriptText(checkpoint.text)
        else {
            return nil
        }
        return segments
    }

    private static func makeCitations(
        for checkpoint: MeetingTranscriptionCheckpoint,
        startingAt identifierNumber: Int
    ) -> [MeetingNoteCitation] {
        guard let segments = usableDiarizedSegments(for: checkpoint) else {
            return [wholeChunkCitation(for: checkpoint, identifierNumber: identifierNumber)]
        }

        return segments.enumerated().map { offset, segment in
            MeetingNoteCitation(
                identifier: citationIdentifier(identifierNumber + offset),
                transcriptRevisionID: checkpoint.revisionID,
                startTime: checkpoint.startOffset + segment.startTime,
                endTime: checkpoint.startOffset + segment.endTime,
                speakerLabel: normalizedSpeakerLabel(segment.speakerLabel),
                text: segment.text
            )
        }
    }

    private static func isValid(
        _ segment: DiarizedTranscriptSegment,
        within checkpoint: MeetingTranscriptionCheckpoint
    ) -> Bool {
        guard
            segment.startTime.isFinite,
            segment.endTime.isFinite,
            segment.startTime >= 0,
            segment.endTime > segment.startTime,
            segment.endTime <= checkpoint.duration,
            !segment.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            return false
        }

        return (checkpoint.startOffset + segment.endTime).isFinite
    }

    private static func areOrderedAndNonOverlapping(
        _ segments: [DiarizedTranscriptSegment]
    ) -> Bool {
        zip(segments, segments.dropFirst()).allSatisfy { previous, current in
            previous.endTime <= current.startTime
        }
    }

    private static func normalizedTranscriptText(_ text: String) -> String {
        text.precomposedStringWithCompatibilityMapping
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func wholeChunkCitation(
        for checkpoint: MeetingTranscriptionCheckpoint,
        identifierNumber: Int
    ) -> MeetingNoteCitation {
        MeetingNoteCitation(
            identifier: citationIdentifier(identifierNumber),
            transcriptRevisionID: checkpoint.revisionID,
            startTime: checkpoint.startOffset,
            endTime: checkpoint.startOffset + checkpoint.duration,
            speakerLabel: nil,
            text: checkpoint.text
        )
    }

    private static func evidence(
        humanNoteContent: String,
        citations: [MeetingNoteCitation]
    ) -> String {
        let humanNotes = escapingEvidenceContent(humanNoteContent)
        let sourceLines = citations.map(evidenceSourceLine).joined(separator: "\n")
        return """
        <untrusted-human-notes>
        \(humanNotes)
        </untrusted-human-notes>

        <untrusted-transcript-sources>
        \(sourceLines)
        </untrusted-transcript-sources>
        """
    }

    private static func evidenceSourceLine(_ citation: MeetingNoteCitation) -> String {
        let speaker = escapingEvidenceContent(
            quotedSourceDisplay(citation.speakerLabel ?? "(none)")
        )
        let text = escapingEvidenceContent(quotedSourceDisplay(citation.text))
        return "Source \(citation.identifier.dropFirst()) [\(timestamp(citation.startTime))–\(timestamp(citation.endTime))] Speaker: \(speaker) | \(text)"
    }

    private static func normalizedForReservedMarkerDetection(_ content: String) -> String {
        content.precomposedStringWithCompatibilityMapping.unicodeScalars.reduce(into: "") {
            normalized, scalar in
            guard
                scalar.properties.generalCategory != .format,
                scalar.value != 0x034F,
                !isVariationSelector(scalar)
            else {
                return
            }
            normalized.unicodeScalars.append(scalar)
        }
    }

    private static func isVariationSelector(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x180B...0x180D, 0x180F, 0xFE00...0xFE0F, 0xE0100...0xE01EF:
            return true
        default:
            return false
        }
    }

    private static func escapingEvidenceContent(_ source: String) -> String {
        source
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    private static func quotedSourceDisplay(_ source: String) -> String {
        var quoted = "\""
        for scalar in source.unicodeScalars {
            switch scalar.value {
            case 0x08:
                quoted += "\\b"
            case 0x09:
                quoted += "\\t"
            case 0x0A:
                quoted += "\\n"
            case 0x0C:
                quoted += "\\f"
            case 0x0D:
                quoted += "\\r"
            case 0x22:
                quoted += "\\\""
            case 0x5C:
                quoted += "\\\\"
            default:
                switch scalar.properties.generalCategory {
                case .control, .format, .lineSeparator, .paragraphSeparator:
                    quoted += escapedUnicodeScalar(scalar)
                default:
                    quoted.unicodeScalars.append(scalar)
                }
            }
        }
        quoted += "\""
        return quoted
    }

    private static func escapedUnicodeScalar(_ scalar: Unicode.Scalar) -> String {
        let value = scalar.value
        guard value > 0xFFFF else {
            return String(format: "\\u%04X", locale: posixLocale, arguments: [value])
        }

        let surrogateValue = value - 0x1_0000
        let highSurrogate = 0xD800 + (surrogateValue >> 10)
        let lowSurrogate = 0xDC00 + (surrogateValue & 0x3FF)
        return String(
            format: "\\u%04X\\u%04X",
            locale: posixLocale,
            arguments: [highSurrogate, lowSurrogate]
        )
    }

    private static func citationIdentifier(_ number: Int) -> String {
        "C\(number)"
    }

    private static func normalizedSpeakerLabel(_ speakerLabel: String) -> String? {
        speakerLabel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : speakerLabel
    }

    private static func timestamp(_ time: TimeInterval) -> String {
        let milliseconds = (time * 1_000).rounded()
        guard
            milliseconds.isFinite,
            milliseconds >= Double(Int64.min),
            milliseconds < Double(Int64.max)
        else {
            return String(format: "%.3f", locale: posixLocale, arguments: [time])
        }

        let totalMilliseconds = Int64(milliseconds)
        let hours = totalMilliseconds / 3_600_000
        let minutes = (totalMilliseconds / 60_000) % 60
        let seconds = (totalMilliseconds / 1_000) % 60
        let remainderMilliseconds = totalMilliseconds % 1_000
        return String(
            format: "%02lld:%02lld:%02lld.%03lld",
            locale: posixLocale,
            arguments: [hours, minutes, seconds, remainderMilliseconds]
        )
    }
}
