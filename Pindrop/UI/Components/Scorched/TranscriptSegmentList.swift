//
//  TranscriptSegmentList.swift
//  Pindrop
//
//  Created on 2026-08-22.
//
//  The transcript, read as speaker turns (WP5).
//
//  A transcript arrives as spans, one per diarized stretch of speech. Nobody
//  reads spans: a person talking twice in a row is one person talking, so
//  consecutive spans of one speaker collapse into a single turn with its own
//  header. Each span stays a paragraph inside that turn, which is what makes
//  click-to-seek land on the line the person actually clicked.
//
//  Every decision with a right answer lives in `TranscriptSegmentPresentation`,
//  a pure value type: how spans group, what a timestamp says, which turns a
//  search keeps, where the matches are inside them, and how the live text splits
//  into settled and tentative lines. The views draw those answers.
//

import SwiftUI
import Foundation
import PindropCore

// MARK: - Turns

/// Consecutive spans of one speaker, read as one turn.
struct TranscriptTurn: Identifiable, Equatable {
    let id: String
    let speakerKey: String
    let speakerLabel: String?
    let speakerNumber: Int?
    let isCurrentUser: Bool
    let startOffset: TimeInterval
    /// The spans this turn collapsed, in order. Each one reads as a paragraph.
    let spans: [TranscriptSegmentSnapshot]

    /// The whole turn as one string, one paragraph per line. For copy and
    /// export; the list draws the paragraphs separately.
    var text: String {
        spans.map(\.text).joined(separator: "\n")
    }

    func displayName(locale: Locale) -> String {
        TranscriptSegmentPresentation.speakerName(
            isCurrentUser: isCurrentUser,
            speakerNumber: speakerNumber,
            speakerLabel: speakerLabel,
            locale: locale
        )
    }

    /// Groups a transcript into turns. Same speaker back to back reads as one
    /// person talking, not as several disconnected lines.
    static func turns(in segments: [TranscriptSegmentSnapshot]) -> [TranscriptTurn] {
        var turns: [TranscriptTurn] = []
        for segment in segments {
            let key = segment.speakerKey ?? "_"
            if let last = turns.last, last.speakerKey == key {
                turns[turns.count - 1] = TranscriptTurn(
                    id: last.id,
                    speakerKey: last.speakerKey,
                    speakerLabel: last.speakerLabel,
                    speakerNumber: last.speakerNumber,
                    isCurrentUser: last.isCurrentUser,
                    startOffset: last.startOffset,
                    spans: last.spans + [segment]
                )
                continue
            }
            turns.append(
                TranscriptTurn(
                    id: segment.id,
                    speakerKey: key,
                    speakerLabel: segment.speakerLabel,
                    speakerNumber: segment.speakerNumber,
                    isCurrentUser: segment.isCurrentUser,
                    startOffset: segment.startOffset,
                    spans: [segment]
                )
            )
        }
        return turns
    }
}

// MARK: - Presentation values

/// One stretch of a paragraph, either plain or matched by the search.
struct TranscriptTextRun: Identifiable, Equatable, Sendable {
    let id: Int
    let text: String
    let isMatch: Bool
    /// Where this match sits in the whole transcript, counted from zero in
    /// reading order. Nil for plain text. The number is what lets one match out
    /// of many be the current one, so the steppers and the scroll agree.
    let matchIndex: Int?

    init(id: Int, text: String, isMatch: Bool, matchIndex: Int? = nil) {
        self.id = id
        self.text = text
        self.isMatch = isMatch
        self.matchIndex = matchIndex
    }
}

/// One span inside a turn.
struct TranscriptParagraph: Identifiable, Equatable, Sendable {
    /// The span identifier, so a click can seek to this exact line.
    let id: String
    let text: String
    let startOffset: TimeInterval
    /// Zero-padded mm:ss for this block. A solo note prints it in the gutter
    /// beside the block; a speaker turn prints only the turn's own time.
    let timestampText: String
    /// The paragraph cut into plain and matched runs, in order. One plain run
    /// when nothing is being searched.
    let runs: [TranscriptTextRun]

    var matchCount: Int {
        runs.filter(\.isMatch).count
    }
}

/// One speaker turn, as the list draws it.
struct TranscriptTurnPresentation: Identifiable, Equatable, Sendable {
    let id: String
    let speakerKey: String
    let displayName: String
    let isCurrentUser: Bool
    let startOffset: TimeInterval
    /// Zero-padded mm:ss from the start of the recording. A solo note has one
    /// turn covering the whole recording, so its header prints the total length
    /// instead of a start time that is always zero.
    let timestampText: String
    /// True when this is the single turn of a note only the person recording
    /// spoke in. Its blocks are pause breaks, not speaker turns, so each one
    /// carries its own time in a gutter.
    let isSolo: Bool
    let paragraphs: [TranscriptParagraph]

    var matchCount: Int {
        paragraphs.reduce(0) { $0 + $1.matchCount }
    }

    var text: String {
        paragraphs.map(\.text).joined(separator: "\n")
    }
}

/// The whole transcript view, decided once.
struct TranscriptListPresentation: Equatable, Sendable {
    let turns: [TranscriptTurnPresentation]
    /// True while a search is narrowing the list.
    let isSearching: Bool
    /// How many times the search text appears in what is shown.
    let matchCount: Int
    /// The mono count beside the search field. Nil when nothing is searched.
    let resultsText: String?
    /// What to say instead of a list. Nil when there is something to read.
    let emptyMessage: String?
    /// Which match the reader is standing on. It wears the stronger treatment.
    let currentMatchIndex: Int?
    /// The span each match lives in, indexed the same way the matches are. It is
    /// what the page scrolls to when the reader steps to the next one.
    let matchSegmentIDs: [String]

    init(
        turns: [TranscriptTurnPresentation],
        isSearching: Bool,
        matchCount: Int,
        resultsText: String?,
        emptyMessage: String?,
        currentMatchIndex: Int? = nil,
        matchSegmentIDs: [String] = []
    ) {
        self.turns = turns
        self.isSearching = isSearching
        self.matchCount = matchCount
        self.resultsText = resultsText
        self.emptyMessage = emptyMessage
        self.currentMatchIndex = currentMatchIndex
        self.matchSegmentIDs = matchSegmentIDs
    }

    /// The span holding the current match, when there is one.
    var currentMatchSegmentID: String? {
        guard let currentMatchIndex,
              currentMatchIndex >= 0,
              currentMatchIndex < matchSegmentIDs.count
        else {
            return nil
        }
        return matchSegmentIDs[currentMatchIndex]
    }

    static let empty = TranscriptListPresentation(
        turns: [],
        isSearching: false,
        matchCount: 0,
        resultsText: nil,
        emptyMessage: nil
    )
}

/// One line of the live transcript.
struct TranscriptLiveLine: Identifiable, Equatable, Sendable {
    let id: Int
    /// The settled words of this line. Empty when only tentative text exists.
    let text: String
    /// The words the engine may still change. Long tentative text can span
    /// several bounded lines; none of it is presented as settled.
    let tentativeTail: String?
    /// The newest line. It reads in the primary ink; the ones above it settled.
    let isCurrent: Bool
}

// MARK: - Presentation

enum TranscriptSegmentPresentation {

    /// How far from the bottom the live sheet still counts as following the
    /// transcript. One line of slack, so a pixel of scroll inertia does not put
    /// a "Jump to live" pill on screen.
    static let liveFollowTolerance: CGFloat = 24

    // MARK: Static transcript

    static func make(
        segments: [TranscriptSegmentSnapshot],
        query: String = "",
        currentMatchIndex: Int? = nil,
        locale: Locale
    ) -> TranscriptListPresentation {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let turns = TranscriptTurn.turns(in: segments)
        // Decided before any search narrows the list: a solo note stays a solo
        // note while the reader is looking for a word in it.
        let isSolo = isSoloNote(turns)
        let totalDuration = segments.map(\.endOffset).max() ?? 0

        guard !trimmedQuery.isEmpty else {
            let presented = turns.map { turn in
                presentation(
                    for: turn,
                    query: nil,
                    isSolo: isSolo,
                    totalDuration: totalDuration,
                    locale: locale
                )
            }
            return TranscriptListPresentation(
                turns: presented,
                isSearching: false,
                matchCount: 0,
                resultsText: nil,
                emptyMessage: presented.isEmpty
                    ? localized("Nothing was transcribed yet.", locale: locale)
                    : nil
            )
        }

        // A searched list keeps only the paragraphs that matched, so the count
        // beside the field and the lines on screen are the same fact.
        let matched = turns
            .map {
                presentation(
                    for: $0,
                    query: trimmedQuery,
                    isSolo: isSolo,
                    totalDuration: totalDuration,
                    locale: locale
                )
            }
            .filter { $0.matchCount > 0 }
        // Numbering happens after the filter, over exactly the lines on screen:
        // "3 of 12" has to count the matches the reader can actually step to.
        let numbered = numbered(matched)
        let matchCount = numbered.targets.count
        return TranscriptListPresentation(
            turns: numbered.turns,
            isSearching: true,
            matchCount: matchCount,
            resultsText: resultsText(matchCount, locale: locale),
            emptyMessage: numbered.turns.isEmpty
                ? localized("No results. Try another word.", locale: locale)
                : nil,
            currentMatchIndex: clampedMatchIndex(currentMatchIndex, total: matchCount),
            matchSegmentIDs: numbered.targets
        )
    }

    /// A match number that no longer exists is no match at all, so a stale index
    /// leaves the list unmarked instead of ringing an arbitrary word.
    static func clampedMatchIndex(_ index: Int?, total: Int) -> Int? {
        guard let index, total > 0, index >= 0, index < total else { return nil }
        return index
    }

    /// Numbers every match in reading order and records which span each one is
    /// in. One pass over the presented turns, so the numbers and the scroll
    /// targets can never disagree.
    private static func numbered(
        _ turns: [TranscriptTurnPresentation]
    ) -> (turns: [TranscriptTurnPresentation], targets: [String]) {
        var counter = 0
        var targets: [String] = []
        let renumbered = turns.map { turn in
            TranscriptTurnPresentation(
                id: turn.id,
                speakerKey: turn.speakerKey,
                displayName: turn.displayName,
                isCurrentUser: turn.isCurrentUser,
                startOffset: turn.startOffset,
                timestampText: turn.timestampText,
                isSolo: turn.isSolo,
                paragraphs: turn.paragraphs.map { paragraph in
                    TranscriptParagraph(
                        id: paragraph.id,
                        text: paragraph.text,
                        startOffset: paragraph.startOffset,
                        timestampText: paragraph.timestampText,
                        runs: paragraph.runs.map { run in
                            guard run.isMatch else { return run }
                            let index = counter
                            counter += 1
                            targets.append(paragraph.id)
                            return TranscriptTextRun(
                                id: run.id,
                                text: run.text,
                                isMatch: true,
                                matchIndex: index
                            )
                        }
                    )
                }
            )
        }
        return (renumbered, targets)
    }

    /// The name to show for one speaker. One rule, so a turn header, a citation
    /// source, and an export never disagree about who said something.
    static func speakerName(
        isCurrentUser: Bool,
        speakerNumber: Int?,
        speakerLabel: String?,
        locale: Locale
    ) -> String {
        if isCurrentUser {
            return localized("You", locale: locale)
        }
        if let speakerNumber {
            return String(format: localized("Speaker %d", locale: locale), speakerNumber)
        }
        if let speakerLabel, !speakerLabel.isEmpty {
            return speakerLabel
        }
        return localized("Speaker", locale: locale)
    }

    static func resultsText(_ count: Int, locale: Locale) -> String {
        if count == 1 {
            return localized("1 result", locale: locale)
        }
        return String(format: localized("%d results", locale: locale), locale: locale, count)
    }

    /// Zero-padded mm:ss, h:mm:ss past an hour. Same clock as the capture bar.
    static func timestampText(_ offset: TimeInterval) -> String {
        NoteRowPresentation.elapsedText(offset)
    }

    /// True when one person recorded a note alone.
    ///
    /// One turn and that turn is the person recording: nobody else was in the
    /// audio, so its blocks came from pauses rather than from a change of
    /// speaker, and a second speaker name would be a lie.
    static func isSoloNote(_ turns: [TranscriptTurn]) -> Bool {
        turns.count == 1 && turns[0].isCurrentUser
    }

    private static func presentation(
        for turn: TranscriptTurn,
        query: String?,
        isSolo: Bool,
        totalDuration: TimeInterval,
        locale: Locale
    ) -> TranscriptTurnPresentation {
        let paragraphs = turn.spans.enumerated().map { index, span in
            TranscriptParagraph(
                id: span.id.isEmpty ? "\(turn.id)-\(index)" : span.id,
                text: span.text,
                startOffset: span.startOffset,
                timestampText: timestampText(span.startOffset),
                runs: runs(in: span.text, query: query)
            )
        }
        return TranscriptTurnPresentation(
            id: turn.id,
            speakerKey: turn.speakerKey,
            displayName: turn.displayName(locale: locale),
            isCurrentUser: turn.isCurrentUser,
            startOffset: turn.startOffset,
            // A solo header answers "how long is this", because "when did it
            // start" is always the beginning.
            timestampText: timestampText(isSolo ? totalDuration : turn.startOffset),
            isSolo: isSolo,
            paragraphs: query == nil
                ? paragraphs
                : paragraphs.filter { $0.matchCount > 0 }
        )
    }

    /// Cuts one paragraph into alternating plain and matched runs.
    ///
    /// Matching ignores case and diacritics: a person searching "resume" should
    /// find "résumé", and nobody types the transcript's capitalization back.
    static func runs(in text: String, query: String?) -> [TranscriptTextRun] {
        guard let query, !query.isEmpty, !text.isEmpty else {
            return text.isEmpty ? [] : [TranscriptTextRun(id: 0, text: text, isMatch: false)]
        }

        var runs: [TranscriptTextRun] = []
        var index = text.startIndex
        while index < text.endIndex,
              let match = text.range(
                of: query,
                options: [.caseInsensitive, .diacriticInsensitive],
                range: index..<text.endIndex
              ) {
            if match.lowerBound > index {
                runs.append(
                    TranscriptTextRun(
                        id: runs.count,
                        text: String(text[index..<match.lowerBound]),
                        isMatch: false
                    )
                )
            }
            runs.append(
                TranscriptTextRun(id: runs.count, text: String(text[match]), isMatch: true)
            )
            // A query that matches an empty range would never advance.
            index = match.upperBound > match.lowerBound
                ? match.upperBound
                : text.index(after: match.lowerBound)
        }

        guard !runs.isEmpty else { return [] }
        if index < text.endIndex {
            runs.append(
                TranscriptTextRun(id: runs.count, text: String(text[index...]), isMatch: false)
            )
        }
        return runs
    }

    // MARK: Live transcript

    /// The live text as lines: everything the engine settled, plus the tail it
    /// may still rewrite.
    ///
    /// The committed text arrives as one growing paragraph, so it is cut at
    /// sentence ends. The newest line is the one being spoken; the tentative
    /// tail hangs off it rather than pretending to be a line of its own.
    static func liveLines(committed: String, tentative: String = "") -> [TranscriptLiveLine] {
        let settled = committed.trimmingCharacters(in: .whitespacesAndNewlines)
        let pending = tentative.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !settled.isEmpty || !pending.isEmpty else { return [] }

        var lines = self.sentences(in: settled)
            .flatMap(Self.boundedLiveLines)
            .map { TranscriptLiveLine(id: 0, text: $0, tentativeTail: nil, isCurrent: false) }
        let pendingLines = pending.isEmpty ? [] : Self.boundedLiveLines(pending)

        if let firstPending = pendingLines.first, !lines.isEmpty {
            let last = lines.removeLast()
            lines.append(
                TranscriptLiveLine(
                    id: 0,
                    text: last.text,
                    tentativeTail: firstPending,
                    isCurrent: false
                )
            )
        }
        lines.append(contentsOf: pendingLines.dropFirst(lines.isEmpty ? 0 : 1).map {
            TranscriptLiveLine(id: 0, text: "", tentativeTail: $0, isCurrent: false)
        })

        guard !lines.isEmpty else { return [] }
        return lines.enumerated().map { index, line in
            TranscriptLiveLine(
                id: index,
                text: line.text,
                tentativeTail: line.tentativeTail,
                isCurrent: index == lines.count - 1
            )
        }
    }

    /// The one line the collapsed sheet shows: the newest thing Pindrop heard.
    static func collapsedLine(committed: String, tentative: String = "", locale: Locale) -> String {
        guard let last = liveLines(committed: committed, tentative: tentative).last else {
            return localized("Listening…", locale: locale)
        }
        guard let tail = last.tentativeTail else { return last.text }
        return last.text.isEmpty ? tail : last.text + " " + tail
    }

    /// True while the sheet should keep pinning itself to the newest line.
    static func followsLive(distanceFromBottom: CGFloat) -> Bool {
        distanceFromBottom <= liveFollowTolerance
    }

    /// Splits a paragraph at sentence ends, keeping the terminator with the
    /// sentence it closes. Text with no terminator stays one line.
    private static func sentences(in text: String) -> [String] {
        var lines: [String] = []
        var current = ""
        var iterator = text.makeIterator()
        var pending: Character?

        func flush() {
            let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { lines.append(trimmed) }
            current = ""
        }

        while let character = pending ?? iterator.next() {
            pending = nil
            if character.isNewline {
                flush()
                continue
            }
            current.append(character)
            guard isSentenceTerminator(character) else { continue }
            // Keep runs of terminators ("?!") and a closing quote with the line.
            var lookahead = iterator.next()
            while let next = lookahead, isSentenceTerminator(next) || isClosingMark(next) {
                current.append(next)
                lookahead = iterator.next()
            }
            pending = lookahead
            if pending == nil || pending?.isWhitespace == true {
                pending = nil
                flush()
            }
        }
        flush()
        return lines.isEmpty ? [text] : lines
    }

    /// A streaming model can emit a long stretch without punctuation. Keep that
    /// provisional text readable until a pause or the final transcript supplies
    /// semantic boundaries.
    private static func boundedLiveLines(_ text: String) -> [String] {
        let words = text.split(whereSeparator: \Character.isWhitespace)
        let wordLimit = 24
        guard words.count > wordLimit else { return [text] }

        return stride(from: 0, to: words.count, by: wordLimit).map { start in
            let end = min(start + wordLimit, words.count)
            return words[start..<end].joined(separator: " ")
        }
    }

    private static func isSentenceTerminator(_ character: Character) -> Bool {
        character == "." || character == "!" || character == "?" || character == "…"
    }

    private static func isClosingMark(_ character: Character) -> Bool {
        character == "\"" || character == "”" || character == "'" || character == "’"
            || character == ")"
    }
}

// MARK: - Bubble

/// One speaker turn: who said it, when, and what they said.
struct TranscriptSegmentBubble: View {
    /// Newsreader 15/22, the reading face for transcript prose.
    static let bodyMetrics = TypographyRoleMetrics(
        family: .newsreader, size: 15, weight: .regular, lineHeight: 22
    )

    @Environment(\.locale) private var locale

    let turn: TranscriptTurnPresentation
    /// The turn playback is inside right now.
    var isActive = false
    /// Clicking seeks only when there is audio to seek in.
    var canSeek = false
    var onSeek: ((TimeInterval) -> Void)?
    /// The span a citation was just followed to. It wears the accent wash for a
    /// moment so the reader can find the line they were sent to.
    var flashingSegmentID: String?
    /// The match the reader is standing on. It reads stronger than the rest.
    var currentMatchIndex: Int?

    /// The timestamp gutter of a solo note. Wide enough for h:mm:ss, so a long
    /// recording never pushes its blocks out of line.
    static let soloTimestampGutter: CGFloat = 44
    /// The gap between the gutter and the block it labels.
    static let soloTimestampGap: CGFloat = 12
    /// The reading measure of a solo block.
    static let soloBodyWidth: CGFloat = 560
    /// The space between two pause breaks.
    static let soloBlockSpacing: CGFloat = 14

    var body: some View {
        VStack(alignment: .leading, spacing: turn.isSolo ? 12 : 4) {
            header

            VStack(alignment: .leading, spacing: turn.isSolo ? Self.soloBlockSpacing : 4) {
                ForEach(turn.paragraphs) { paragraph in
                    paragraphView(paragraph)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("transcript.turn")
    }

    private var header: some View {
        HStack(spacing: 8) {
            // The dot only repeats the speaker the name beside it already gives.
            Circle()
                .fill(turn.isCurrentUser
                      ? AppColors.accent
                      : LibrarySpeakerColor.color(for: turn.speakerKey))
                .frame(width: 8, height: 8)
                .accessibilityHidden(true)

            Text(turn.displayName)
                .font(AppTypography.labelSemibold)
                .foregroundStyle(AppColors.textPrimary)

            Text(turn.timestampText)
                .font(AppTypography.monoSmall)
                .foregroundStyle(isActive ? AppColors.accent : AppColors.textTertiary)
                .monospacedDigit()
                .environment(\.layoutDirection, .leftToRight)
        }
    }

    @ViewBuilder
    private func paragraphView(_ paragraph: TranscriptParagraph) -> some View {
        let isFlashing = paragraph.id == flashingSegmentID
        let body = paragraphText(paragraph)
            .font(Self.bodyMetrics.font)
            .lineSpacing(Self.bodyMetrics.lineSpacing)

        let line = Group {
            if turn.isSolo {
                HStack(alignment: .firstTextBaseline, spacing: Self.soloTimestampGap) {
                    Text(paragraph.timestampText)
                        .font(AppTypography.monoSmall)
                        .foregroundStyle(AppColors.textTertiary)
                        .monospacedDigit()
                        .environment(\.layoutDirection, .leftToRight)
                        .frame(width: Self.soloTimestampGutter, alignment: .trailing)

                    body.frame(maxWidth: Self.soloBodyWidth, alignment: .leading)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                body
                    .frame(maxWidth: 640, alignment: .leading)
                    .padding(.leading, 16)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }

        Group {
            if canSeek, let onSeek {
                Button { onSeek(paragraph.startOffset) } label: {
                    line.contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .focusRing(.rounded(.sm))
                .help(localized("Jump to this line", locale: locale))
                .accessibilityIdentifier("transcript.turn.seek")
            } else {
                line.textSelection(.enabled)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(AppColors.accentBackground)
                .opacity(isFlashing ? 1 : 0)
                .padding(.horizontal, -6)
                .padding(.vertical, -4)
        )
        // The scroll target of a citation is the span, not the whole turn: a
        // long turn would otherwise leave the cited line off screen.
        .id(paragraph.id)
    }

    /// Matched words take the accent wash; the match the reader is standing on
    /// takes a stronger one and the primary ink, so one match out of twelve is
    /// findable at a glance.
    ///
    /// The runs are attributes of one string rather than separate views: a
    /// paragraph has to wrap as a paragraph, and a row of views would break the
    /// line wherever a match happened to fall.
    private func paragraphText(_ paragraph: TranscriptParagraph) -> Text {
        paragraph.runs.reduce(Text("")) { accumulated, run in
            accumulated + Text(styled(run))
        }
    }

    private func styled(_ run: TranscriptTextRun) -> AttributedString {
        var string = AttributedString(run.text)
        guard run.isMatch else {
            string.foregroundColor = AppColors.textSecondary
            return string
        }
        let isCurrent = run.matchIndex != nil && run.matchIndex == currentMatchIndex
        string.foregroundColor = isCurrent ? AppColors.textPrimary : AppColors.accent
        string.backgroundColor = isCurrent
            ? AppColors.accent.opacity(0.28)
            : AppColors.accentBackground
        return string
    }
}

// MARK: - List

/// The transcript as a column of turns.
struct TranscriptSegmentList: View {
    @Environment(\.locale) private var locale

    let presentation: TranscriptListPresentation
    /// The turn playback is inside, if anything is playing.
    var activeTurnID: String?
    var canSeek = false
    var onSeek: ((TimeInterval) -> Void)?
    /// The span a citation was just followed to. Every span carries its own
    /// scroll identifier, so the page can send a reader straight to it.
    var flashingSegmentID: String?

    var body: some View {
        if let message = presentation.emptyMessage {
            Text(message)
                .font(AppTypography.body)
                .foregroundStyle(AppColors.textSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityIdentifier("transcript.empty")
        } else {
            LazyVStack(alignment: .leading, spacing: 10) {
                ForEach(presentation.turns) { turn in
                    TranscriptSegmentBubble(
                        turn: turn,
                        isActive: turn.id == activeTurnID,
                        canSeek: canSeek,
                        onSeek: onSeek,
                        flashingSegmentID: flashingSegmentID,
                        currentMatchIndex: presentation.currentMatchIndex
                    )
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: - Preview

#Preview("Transcript segments") {
    let locale = Locale(identifier: "en")
    let segments = [
        TranscriptSegmentSnapshot(
            id: "a",
            revisionID: UUID(),
            speakerKey: "self",
            speakerLabel: "You",
            isCurrentUser: true,
            text: "Let us start with the migration plan.",
            startOffset: 0,
            duration: 4
        ),
        TranscriptSegmentSnapshot(
            id: "b",
            revisionID: UUID(),
            speakerKey: "self",
            speakerLabel: "You",
            isCurrentUser: true,
            text: "The store rebuild is the part I worry about.",
            startOffset: 5,
            duration: 4
        ),
        TranscriptSegmentSnapshot(
            id: "c",
            revisionID: UUID(),
            speakerKey: "s2",
            speakerLabel: "Speaker 2",
            speakerNumber: 2,
            text: "We can stage it behind the schema version.",
            startOffset: 12,
            duration: 5
        )
    ]

    return TranscriptSegmentList(
        presentation: TranscriptSegmentPresentation.make(segments: segments, locale: locale),
        canSeek: true,
        onSeek: { _ in }
    )
    .padding(40)
    .frame(width: 760)
    .background(AppColors.contentBackground)
    .environment(\.locale, locale)
    .themeRefresh()
}
