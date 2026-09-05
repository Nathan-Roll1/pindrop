//
//  MarkdownBlockGrammar.swift
//  Pindrop
//
//  Created on 2026-08-22.
//
//  Block classification for the note body, kept apart from the text view.
//
//  The editor stores raw Markdown and always will: what changes is how a line is
//  drawn, not what it holds. Deciding "this line is a level two bullet, its
//  marker runs to here, its text starts there" is a pure reading of the string,
//  so it lives here where it can be tested without a window, a font, or a run
//  loop. `MarkdownTextView` turns these answers into fonts, indents, and glyphs.
//

import Foundation

/// One source line of a note body, classified for drawing.
struct MarkdownLine: Equatable {

    /// What the line is. Levels are 1-based: the first bullet level is 1.
    enum Kind: Equatable {
        /// Nothing but whitespace. Blank lines are the gaps between blocks, so
        /// they are drawn as a fixed gap instead of a full empty text line.
        case blank
        /// `#` through `######`.
        case heading(level: Int)
        case bullet(level: Int)
        /// The marker is kept verbatim ("3.") so a list is never renumbered.
        case ordered(level: Int, marker: String)
        case task(level: Int, isChecked: Bool)
        case quote
        /// A line inside a fenced code block, the fences themselves included.
        case code
        case paragraph

        /// The nesting level of a list line, or nil for everything else.
        var listLevel: Int? {
            switch self {
            case .bullet(let level), .ordered(let level, _), .task(let level, _):
                level
            case .blank, .heading, .quote, .code, .paragraph:
                nil
            }
        }

        var isListItem: Bool { listLevel != nil }
    }

    /// The whole line, without its newline.
    let range: NSRange
    let kind: Kind
    /// The raw marker to collapse: indent, marker, and the spaces after it. Empty
    /// when the line has no marker to hide (a paragraph, a blank line, code).
    let collapsedMarkerRange: NSRange
    /// What is left after the marker.
    let contentRange: NSRange
}

/// Reads a note body into drawable lines.
///
/// Fenced code wins over everything: a `#` inside a fence is text, not a
/// heading, so fences are resolved in one forward pass before any other rule.
enum MarkdownBlockGrammar {

    /// Points of indent added per list level. The marker sits one step left of
    /// the text, so a level-one bullet is drawn on the text axis.
    static let listIndentStep: CGFloat = 20

    /// Every line of `text`, in order.
    static func lines(in text: String) -> [MarkdownLine] {
        let nsText = text as NSString
        guard nsText.length > 0 else { return [] }

        var lines: [MarkdownLine] = []
        var isInsideFence = false
        var location = 0
        while location <= nsText.length {
            let lineRange = nsText.lineRange(for: NSRange(location: location, length: 0))
            let contentRange = nsText.rangeOfLine(excludingTerminatorIn: lineRange)
            let lineText = nsText.substring(with: contentRange)

            if isFenceDelimiter(lineText) {
                lines.append(
                    MarkdownLine(
                        range: contentRange,
                        kind: .code,
                        collapsedMarkerRange: NSRange(location: contentRange.location, length: 0),
                        contentRange: contentRange
                    )
                )
                isInsideFence.toggle()
            } else if isInsideFence {
                lines.append(
                    MarkdownLine(
                        range: contentRange,
                        kind: .code,
                        collapsedMarkerRange: NSRange(location: contentRange.location, length: 0),
                        contentRange: contentRange
                    )
                )
            } else {
                lines.append(classify(lineText, at: contentRange))
            }

            if lineRange.length == 0 {
                break
            }
            location = NSMaxRange(lineRange)
            // A trailing newline ends the text; there is no empty line after it.
            if location >= nsText.length {
                break
            }
        }
        return lines
    }

    /// Consecutive runs of code lines, each as one range covering whole lines.
    /// Used to paint one card behind a fenced block instead of one per line.
    static func codeBlockRanges(_ lines: [MarkdownLine]) -> [NSRange] {
        blockRanges(lines) { $0.kind == .code }
    }

    /// Consecutive runs of quote lines, for the bar drawn beside them.
    static func quoteBlockRanges(_ lines: [MarkdownLine]) -> [NSRange] {
        blockRanges(lines) { $0.kind == .quote }
    }

    /// The glyph drawn in place of a hidden list marker, or nil when the line
    /// keeps its own text (a paragraph, a heading, a task item).
    static func renderedMarker(for kind: MarkdownLine.Kind) -> String? {
        switch kind {
        case .bullet(let level):
            level.isMultiple(of: 2) ? "◦" : "•"
        case .ordered(_, let marker):
            marker
        case .blank, .heading, .task, .quote, .code, .paragraph:
            nil
        }
    }

    /// Where a line's text starts, measured from the text axis.
    static func textIndent(for kind: MarkdownLine.Kind) -> CGFloat {
        switch kind {
        case .bullet(let level), .ordered(let level, _), .task(let level, _):
            CGFloat(level) * listIndentStep
        case .quote:
            quoteTextIndent
        case .blank, .heading, .code, .paragraph:
            0
        }
    }

    /// Where a list marker is drawn, measured from the text axis. One step left
    /// of the text, so the first level sits on the axis itself.
    static func markerIndent(for kind: MarkdownLine.Kind) -> CGFloat {
        guard let level = kind.listLevel else { return 0 }
        return CGFloat(level - 1) * listIndentStep
    }

    /// Left padding of a blockquote, leaving room for its bar.
    static let quoteTextIndent: CGFloat = 14

    // MARK: - Line classification

    private static func classify(_ line: String, at range: NSRange) -> MarkdownLine {
        let empty = NSRange(location: range.location, length: 0)
        guard !line.trimmingCharacters(in: .whitespaces).isEmpty else {
            return MarkdownLine(
                range: range,
                kind: .blank,
                collapsedMarkerRange: empty,
                contentRange: range
            )
        }

        let nsLine = line as NSString
        let indentLength = leadingWhitespaceLength(nsLine)
        let body = nsLine.substring(from: indentLength)

        if let heading = headingMatch(body) {
            // Heading markers are hidden inline and drawn in the gutter, so the
            // indent counts as part of the marker.
            let markerLength = indentLength + heading.markerLength
            return MarkdownLine(
                range: range,
                kind: .heading(level: heading.level),
                collapsedMarkerRange: NSRange(location: range.location, length: markerLength),
                contentRange: NSRange(
                    location: range.location + markerLength,
                    length: range.length - markerLength
                )
            )
        }

        if let quoteMarkerLength = quoteMarkerLength(body) {
            let markerLength = indentLength + quoteMarkerLength
            return MarkdownLine(
                range: range,
                kind: .quote,
                collapsedMarkerRange: NSRange(location: range.location, length: markerLength),
                contentRange: NSRange(
                    location: range.location + markerLength,
                    length: range.length - markerLength
                )
            )
        }

        if let list = listMatch(body, indentWidth: indentWidth(nsLine, upTo: indentLength)) {
            let markerLength = indentLength + list.markerLength
            return MarkdownLine(
                range: range,
                kind: list.kind,
                collapsedMarkerRange: NSRange(location: range.location, length: markerLength),
                contentRange: NSRange(
                    location: range.location + markerLength,
                    length: range.length - markerLength
                )
            )
        }

        return MarkdownLine(
            range: range,
            kind: .paragraph,
            collapsedMarkerRange: empty,
            contentRange: range
        )
    }

    private static func isFenceDelimiter(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~")
    }

    private static func leadingWhitespaceLength(_ line: NSString) -> Int {
        var index = 0
        while index < line.length {
            let character = line.character(at: index)
            guard character == 32 || character == 9 else { break }
            index += 1
        }
        return index
    }

    /// Indent measured in spaces, counting a tab as four. Two spaces make one
    /// list level, which is what the editor's own list continuation writes.
    private static func indentWidth(_ line: NSString, upTo length: Int) -> Int {
        var width = 0
        for index in 0..<length {
            width += line.character(at: index) == 9 ? 4 : 1
        }
        return width
    }

    private static func headingMatch(_ body: String) -> (level: Int, markerLength: Int)? {
        let nsBody = body as NSString
        var hashes = 0
        while hashes < nsBody.length, nsBody.character(at: hashes) == UInt16(UnicodeScalar("#").value) {
            hashes += 1
        }
        guard hashes >= 1, hashes <= 6, hashes < nsBody.length else { return nil }
        var spaces = 0
        while hashes + spaces < nsBody.length {
            let character = nsBody.character(at: hashes + spaces)
            guard character == 32 || character == 9 else { break }
            spaces += 1
        }
        guard spaces >= 1 else { return nil }
        return (hashes, hashes + spaces)
    }

    private static func quoteMarkerLength(_ body: String) -> Int? {
        let nsBody = body as NSString
        guard nsBody.length >= 1, nsBody.character(at: 0) == UInt16(UnicodeScalar(">").value) else {
            return nil
        }
        var spaces = 0
        while 1 + spaces < nsBody.length {
            let character = nsBody.character(at: 1 + spaces)
            guard character == 32 || character == 9 else { break }
            spaces += 1
        }
        return 1 + spaces
    }

    private static func listMatch(
        _ body: String,
        indentWidth: Int
    ) -> (kind: MarkdownLine.Kind, markerLength: Int)? {
        let level = indentWidth / 2 + 1
        let nsBody = body as NSString
        guard nsBody.length >= 2 else { return nil }

        let first = nsBody.substring(to: 1)
        if first == "-" || first == "*" || first == "+" {
            var spaces = 0
            while 1 + spaces < nsBody.length {
                let character = nsBody.character(at: 1 + spaces)
                guard character == 32 || character == 9 else { break }
                spaces += 1
            }
            guard spaces >= 1 else { return nil }

            let afterMarker = nsBody.substring(from: 1 + spaces)
            if let isChecked = taskState(afterMarker) {
                // Only the bullet is hidden. The `[ ]` stays in the text so it
                // keeps its own styling and stays clickable.
                return (.task(level: level, isChecked: isChecked), 1 + spaces)
            }
            return (.bullet(level: level), 1 + spaces)
        }

        var digits = 0
        while digits < nsBody.length, isDigit(nsBody.character(at: digits)) {
            digits += 1
        }
        guard digits >= 1, digits < nsBody.length else { return nil }
        let delimiter = nsBody.character(at: digits)
        guard delimiter == UInt16(UnicodeScalar(".").value)
            || delimiter == UInt16(UnicodeScalar(")").value)
        else {
            return nil
        }
        var spaces = 0
        while digits + 1 + spaces < nsBody.length {
            let character = nsBody.character(at: digits + 1 + spaces)
            guard character == 32 || character == 9 else { break }
            spaces += 1
        }
        guard spaces >= 1 else { return nil }
        return (
            .ordered(level: level, marker: nsBody.substring(to: digits + 1)),
            digits + 1 + spaces
        )
    }

    /// Whether the text following a bullet marker opens with `[ ]` or `[x]`.
    private static func taskState(_ afterMarker: String) -> Bool? {
        let nsText = afterMarker as NSString
        guard nsText.length >= 3,
              nsText.substring(to: 1) == "[",
              nsText.substring(with: NSRange(location: 2, length: 1)) == "]"
        else {
            return nil
        }
        switch nsText.substring(with: NSRange(location: 1, length: 1)) {
        case " ": return false
        case "x", "X": return true
        default: return nil
        }
    }

    private static func isDigit(_ character: unichar) -> Bool {
        character >= 48 && character <= 57
    }

    private static func blockRanges(
        _ lines: [MarkdownLine],
        where predicate: (MarkdownLine) -> Bool
    ) -> [NSRange] {
        var ranges: [NSRange] = []
        var current: NSRange?
        for line in lines {
            if predicate(line) {
                if let existing = current {
                    current = NSUnionRange(existing, line.range)
                } else {
                    current = line.range
                }
            } else if let existing = current {
                ranges.append(existing)
                current = nil
            }
        }
        if let existing = current {
            ranges.append(existing)
        }
        return ranges
    }
}

private extension NSString {
    /// The line without its newline characters.
    func rangeOfLine(excludingTerminatorIn lineRange: NSRange) -> NSRange {
        var content = lineRange
        while content.length > 0 {
            let last = character(at: NSMaxRange(content) - 1)
            guard last == 10 || last == 13 else { break }
            content.length -= 1
        }
        return content
    }
}
