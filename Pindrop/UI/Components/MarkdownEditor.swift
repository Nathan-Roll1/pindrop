//
//  MarkdownEditor.swift
//  Pindrop
//
//  Created on 2026-01-29.
//
//  Raw Markdown in, drawn Markdown out.
//
//  The text storage always holds exactly what the person typed: undo, selection,
//  and every export read the same string they see themselves editing. What the
//  grammar upgrade changes is presentation only. Markers that carry no meaning
//  once a line is drawn (`# `, `- `, `> `) are collapsed to a hairline font and
//  redrawn as glyphs at the right place, so the text column keeps one axis and
//  the raw characters stay editable underneath.
//

import SwiftUI
import AppKit
import PindropCore

/// Where a query matches, using the transcript search's rule.
///
/// The note page searches the editor and the transcript with one field, so the
/// two must agree on what counts as a hit. The rule is mirrored here rather
/// than imported: `TranscriptSegmentPresentation` builds SwiftUI runs, which an
/// `NSTextView` cannot use.
enum MarkdownSearchMatching {

    /// Ranges of `query` in `text`, in reading order, as UTF-16 ranges the text
    /// storage can address.
    ///
    /// Matching ignores case and diacritics: a person searching "resume" should
    /// find "résumé", and nobody types the note's capitalization back.
    static func ranges(in text: String, query: String) -> [NSRange] {
        guard !query.isEmpty, !text.isEmpty else { return [] }

        var ranges: [NSRange] = []
        var index = text.startIndex
        while index < text.endIndex,
              let match = text.range(
                of: query,
                options: [.caseInsensitive, .diacriticInsensitive],
                range: index..<text.endIndex
              ) {
            ranges.append(NSRange(match, in: text))
            // A query that matches an empty range would never advance.
            index = match.upperBound > match.lowerBound
                ? match.upperBound
                : text.index(after: match.lowerBound)
        }
        return ranges
    }
}

struct MarkdownEditor: NSViewRepresentable {
    @Binding var text: String

    /// False on the note page: the editor grows with its text and the page
    /// scrolls. True everywhere else, where the editor owns a scroll view.
    var isScrollable: Bool = true

    /// The note page's search text. Empty means no highlight.
    var searchQuery: String = ""

    /// Which match the reader is standing on, counted from zero in reading
    /// order. It wears the stronger wash and is scrolled into view.
    var currentMatchIndex: Int?

    /// Reports how many matches the text holds, so the page can draw "n of m".
    var onMatchCountChange: ((Int) -> Void)?

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSView {
        let textView = MarkdownTextView()

        textView.delegate = context.coordinator
        textView.isRichText = false
        textView.allowsUndo = true
        textView.isEditable = true
        textView.isSelectable = true
        textView.drawsBackground = false
        // Left inset is the marker gutter: `#` markers for headings are
        // collapsed inline and drawn dimmed in the gutter instead. The title and
        // the body therefore share one left edge.
        textView.textContainerInset = NSSize(width: MarkdownTextView.headingMarginWidth, height: 8)
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        // Inter 13/21 body (design spec, "Markdown editor grammar").
        textView.font = FontLoader.nsFont(family: .inter, size: 13, weight: .regular)
        textView.textColor = NSColor(AppColors.textPrimary)
        textView.onCheckboxToggle = { [weak coordinator = context.coordinator] newText in
            coordinator?.parent.text = newText
        }

        guard isScrollable else {
            // No scroll view at all: an NSScrollView eats the wheel even with
            // its scrollers hidden, and the page behind this editor is what
            // must scroll. The text view sizes itself instead (see
            // `sizeThatFits`), so the container height is unbounded and the
            // width is driven from the frame rather than tracked by AppKit.
            textView.autoGrows = true
            textView.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
            textView.textContainer?.widthTracksTextView = false
            textView.isHorizontallyResizable = false
            textView.isVerticallyResizable = true

            context.coordinator.textView = textView
            textView.applyMarkdownStyling()

            return textView
        }

        let scrollView = NSScrollView()

        textView.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = true
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]

        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = false
        scrollView.verticalScroller?.controlSize = .mini
        scrollView.drawsBackground = false

        context.coordinator.textView = textView
        textView.applyMarkdownStyling()

        return scrollView
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard let textView = Self.markdownTextView(in: nsView) else { return }
        // The coordinator outlives this struct, so it needs the current
        // bindings and callbacks before anything can fire them back.
        context.coordinator.parent = self

        let searchChanged = textView.searchQuery != searchQuery
            || textView.currentSearchMatchIndex != currentMatchIndex
        textView.searchQuery = searchQuery
        textView.currentSearchMatchIndex = currentMatchIndex

        if textView.string != text {
            let selectedRanges = textView.selectedRanges
            textView.string = text
            textView.applyMarkdownStyling()
            textView.selectedRanges = selectedRanges
        } else if searchChanged {
            textView.applyMarkdownStyling()
        }

        context.coordinator.reportMatchCount(textView.searchMatchRanges.count)
        if searchChanged {
            context.coordinator.scrollToCurrentMatch(in: textView)
        }
    }

    /// The editor's own height for a proposed width. Nil in the scrollable
    /// mode, where the scroll view takes whatever height it is given.
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSView, context: Context) -> CGSize? {
        guard !isScrollable, let textView = nsView as? MarkdownTextView else { return nil }
        guard let width = proposal.width, width > 0 else { return nil }
        return CGSize(width: width, height: textView.fittingHeight(forWidth: width))
    }

    private static func markdownTextView(in nsView: NSView) -> MarkdownTextView? {
        if let textView = nsView as? MarkdownTextView { return textView }
        return (nsView as? NSScrollView)?.documentView as? MarkdownTextView
    }

    class Coordinator: NSObject, NSTextViewDelegate {
        var parent: MarkdownEditor
        weak var textView: MarkdownTextView?
        private var reportedMatchCount = 0

        init(_ parent: MarkdownEditor) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? MarkdownTextView else { return }
            parent.text = textView.string
            textView.applyMarkdownStyling()
            reportMatchCount(textView.searchMatchRanges.count)
        }

        /// Announces a new count once. The stored count is written before the
        /// hop to the next pass, so a re-entrant update sees the new value and
        /// stops rather than looping.
        func reportMatchCount(_ count: Int) {
            guard count != reportedMatchCount else { return }
            reportedMatchCount = count
            let report = parent.onMatchCountChange
            guard let report else { return }
            // State the note page owns cannot be written inside a view update.
            DispatchQueue.main.async { report(count) }
        }

        func scrollToCurrentMatch(in textView: MarkdownTextView) {
            guard let index = parent.currentMatchIndex,
                  textView.searchMatchRanges.indices.contains(index) else { return }
            let range = textView.searchMatchRanges[index]
            DispatchQueue.main.async { textView.scrollRangeToVisible(range) }
        }
    }
}

class MarkdownTextView: NSTextView {

    /// Width of the left gutter where heading markers are drawn. Matches the
    /// text container's left inset so body text starts at the content column.
    static let headingMarginWidth: CGFloat = 28

    var onCheckboxToggle: ((String) -> Void)?

    // MARK: - Auto-growing mode

    /// True when the editor has no scroll view of its own: it reports the
    /// height its text needs and lets the page scroll.
    var autoGrows = false

    /// Room kept above and below a range scrolled into view.
    private static let scrollMargin: CGFloat = 24

    /// The height this text needs at `width`, including both insets.
    func fittingHeight(forWidth width: CGFloat) -> CGFloat {
        guard let layoutManager, let textContainer else { return textContainerInset.height * 2 }
        useContainerWidth(forFrameWidth: width)
        layoutManager.ensureLayout(for: textContainer)
        return ceil(layoutManager.usedRect(for: textContainer).height) + textContainerInset.height * 2
    }

    /// AppKit tracks the container width for us only inside a scroll view, so
    /// the auto-growing mode sets it from the frame instead.
    @discardableResult
    private func useContainerWidth(forFrameWidth frameWidth: CGFloat) -> Bool {
        guard let textContainer else { return false }
        let contentWidth = max(0, frameWidth - textContainerInset.width * 2)
        guard abs(textContainer.size.width - contentWidth) > 0.5 else { return false }
        textContainer.size = NSSize(width: contentWidth, height: CGFloat.greatestFiniteMagnitude)
        return true
    }

    override var intrinsicContentSize: NSSize {
        guard autoGrows else { return super.intrinsicContentSize }
        return NSSize(width: NSView.noIntrinsicMetric, height: fittingHeight(forWidth: bounds.width))
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        guard autoGrows, useContainerWidth(forFrameWidth: newSize.width) else { return }
        // A new width rewraps the text, so the height the page reserved is stale.
        invalidateIntrinsicContentSize()
    }

    override func scrollWheel(with event: NSEvent) {
        guard autoGrows else {
            super.scrollWheel(with: event)
            return
        }
        // Nothing here scrolls. Hand the wheel to the page.
        nextResponder?.scrollWheel(with: event)
    }

    override func scrollRangeToVisible(_ range: NSRange) {
        guard autoGrows else {
            super.scrollRangeToVisible(range)
            return
        }
        guard let layoutManager, let textContainer else { return }
        let glyphRange = layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        let rect = layoutManager.boundingRect(forGlyphRange: glyphRange, in: textContainer)
        let origin = textContainerOrigin
        // The nearest clip view is the page's, so this asks the page to scroll.
        scrollToVisible(
            rect.offsetBy(dx: origin.x, dy: origin.y).insetBy(dx: 0, dy: -Self.scrollMargin)
        )
    }

    // MARK: - Search highlighting

    /// The note page's search text. Set before `applyMarkdownStyling()`.
    var searchQuery: String = ""

    /// The match the reader is standing on, counted from zero.
    var currentSearchMatchIndex: Int?

    /// Where the query matches, rebuilt on every styling pass.
    private(set) var searchMatchRanges: [NSRange] = []

    // MARK: - Type ramp (design spec, "Markdown editor grammar")

    private let baseFont = FontLoader.nsFont(family: .inter, size: 13, weight: .regular)
    private static let bodyLineHeight: CGFloat = 21
    /// A blank line is a gap between blocks, not a line of text.
    private static let blockGap: CGFloat = 10
    /// Extra room above a heading, on top of the block gap.
    private static let headingSpacingBefore: CGFloat = 8
    /// Distance between items of one list.
    private static let listItemSpacing: CGFloat = 3.5
    /// Distance from the gutter's right edge to the heading marker.
    private static let gutterMarkerPadding: CGFloat = 5

    private struct HeadingStyle {
        let font: NSFont
        let lineHeight: CGFloat
        let markerFont: NSFont
        let markerTracking: CGFloat
    }

    private let headingStyles: [HeadingStyle] = [
        HeadingStyle(
            font: FontLoader.nsFont(family: .newsreader, size: 24, weight: .medium),
            lineHeight: 30,
            markerFont: FontLoader.nsFont(family: .newsreader, size: 17, weight: .regular),
            markerTracking: 0
        ),
        HeadingStyle(
            font: FontLoader.nsFont(family: .newsreader, size: 20, weight: .medium),
            lineHeight: 26,
            markerFont: FontLoader.nsFont(family: .newsreader, size: 15, weight: .regular),
            markerTracking: 0
        ),
        HeadingStyle(
            font: FontLoader.nsFont(family: .newsreader, size: 17, weight: .medium),
            lineHeight: 23,
            markerFont: FontLoader.nsFont(family: .newsreader, size: 12, weight: .regular),
            markerTracking: -0.02 * 12
        ),
        HeadingStyle(
            font: FontLoader.nsFont(family: .inter, size: 15, weight: .semibold),
            lineHeight: 20,
            markerFont: FontLoader.nsFont(family: .newsreader, size: 11, weight: .regular),
            markerTracking: -0.02 * 11
        ),
        HeadingStyle(
            font: FontLoader.nsFont(family: .inter, size: 14, weight: .semibold),
            lineHeight: 19,
            markerFont: FontLoader.nsFont(family: .newsreader, size: 11, weight: .regular),
            markerTracking: -0.02 * 11
        ),
        HeadingStyle(
            font: FontLoader.nsFont(family: .inter, size: 13, weight: .semibold),
            lineHeight: 18,
            markerFont: FontLoader.nsFont(family: .newsreader, size: 11, weight: .regular),
            markerTracking: -0.02 * 11
        )
    ]

    private let quoteFont = FontLoader.nsFont(family: .newsreader, size: 15, weight: .regular, italic: true)
    private static let quoteLineHeight: CGFloat = 22
    private let codeFont = FontLoader.nsFont(family: .jetbrainsMono, size: 11, weight: .regular)
    private static let codeLineHeight: CGFloat = 17
    private static let codeBlockPadding = NSSize(width: 14, height: 10)
    private let markerFont = FontLoader.nsFont(family: .inter, size: 13, weight: .regular)
    /// Marker collapse: a 1 pt font makes the inline `# ` effectively zero-width
    /// while keeping the characters editable and undo-safe.
    private let collapsedMarkerFont = NSFont.systemFont(ofSize: 1)

    // MARK: - Draw instructions rebuilt on every styling pass

    /// A marker drawn outside the text: a heading's hashes in the gutter, or a
    /// list bullet on the text axis.
    private struct DrawnMarker {
        let lineRange: NSRange
        let text: String
        let font: NSFont
        let tracking: CGFloat
        let color: NSColor
        /// Distance from the text axis. Negative values sit in the gutter.
        let indent: CGFloat
        /// The font the marker is baseline-aligned to.
        let alignsTo: NSFont
        let isRightAligned: Bool
    }

    private var drawnMarkers: [DrawnMarker] = []
    private var codeBlockRanges: [NSRange] = []
    private var quoteBlockRanges: [NSRange] = []
    private var inlineCodeRanges: [NSRange] = []

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if let layoutManager, let textContainer {
            let glyphIndex = layoutManager.glyphIndex(for: point, in: textContainer, fractionOfDistanceThroughGlyph: nil)
            let charIndex = layoutManager.characterIndexForGlyph(at: glyphIndex)
            if let toggled = MarkdownCheckbox.toggle(in: string, utf16Offset: charIndex),
               toggled != string {
                let selected = selectedRanges
                string = toggled
                applyMarkdownStyling()
                selectedRanges = selected
                onCheckboxToggle?(toggled)
                delegate?.textDidChange?(Notification(name: NSText.didChangeNotification, object: self))
                return
            }
        }
        super.mouseDown(with: event)
    }

    func applyMarkdownStyling() {
        guard let textStorage = textStorage else { return }

        let fullRange = NSRange(location: 0, length: textStorage.length)
        let text = textStorage.string

        textStorage.beginEditing()

        textStorage.setAttributes([
            .font: baseFont,
            .foregroundColor: NSColor(AppColors.textPrimary),
            .paragraphStyle: paragraphStyle(lineHeight: Self.bodyLineHeight)
        ], range: fullRange)

        drawnMarkers = []
        inlineCodeRanges = []

        let lines = MarkdownBlockGrammar.lines(in: text)
        applyBlocks(lines, to: textStorage)

        applyBold(to: textStorage, text: text)
        applyItalic(to: textStorage, text: text)
        applyBoldItalic(to: textStorage, text: text)
        applyInlineCode(to: textStorage, text: text)
        applyStrikethrough(to: textStorage, text: text)
        applyLinks(to: textStorage, text: text)
        applyTaskCheckboxes(to: textStorage, text: text)

        // Fenced code is literal: inline rules that matched inside it are undone
        // here so a fence shows the characters it contains.
        codeBlockRanges = MarkdownBlockGrammar.codeBlockRanges(lines)
        quoteBlockRanges = MarkdownBlockGrammar.quoteBlockRanges(lines)
        reapplyCodeBlocks(lines, to: textStorage)

        // Last, because every pass above resets or strips attributes over the
        // ranges a highlight covers.
        searchMatchRanges = MarkdownSearchMatching.ranges(in: text, query: searchQuery)
        applySearchHighlights(to: textStorage)

        textStorage.endEditing()

        // Markers and block decoration are painted in draw(_:) / drawBackground(in:).
        needsDisplay = true

        if autoGrows {
            invalidateIntrinsicContentSize()
        }
    }

    /// Washes the matches. Only the background is painted: the foreground still
    /// carries markdown meaning (link, code, dimmed marker), which a highlight
    /// must not overwrite.
    private func applySearchHighlights(to textStorage: NSTextStorage) {
        guard !searchMatchRanges.isEmpty else { return }

        let match = NSColor(AppColors.accentBackground)
        let current = NSColor(AppColors.accent.opacity(0.28))
        let length = textStorage.length

        for (index, range) in searchMatchRanges.enumerated()
        where range.length > 0 && NSMaxRange(range) <= length {
            textStorage.addAttribute(
                .backgroundColor,
                value: index == currentSearchMatchIndex ? current : match,
                range: range
            )
        }
    }

    // MARK: - Block pass

    private func applyBlocks(_ lines: [MarkdownLine], to textStorage: NSTextStorage) {
        for (index, line) in lines.enumerated() {
            let nextKind = index + 1 < lines.count ? lines[index + 1].kind : nil
            let previousKind = index > 0 ? lines[index - 1].kind : nil

            switch line.kind {
            case .blank:
                textStorage.addAttribute(
                    .paragraphStyle,
                    value: paragraphStyle(lineHeight: Self.blockGap),
                    range: line.range
                )

            case .heading(let level):
                let style = headingStyles[min(max(level - 1, 0), headingStyles.count - 1)]
                let paragraph = paragraphStyle(lineHeight: style.lineHeight)
                paragraph.paragraphSpacingBefore = Self.headingSpacingBefore
                textStorage.addAttribute(.paragraphStyle, value: paragraph, range: line.range)
                collapse(line.collapsedMarkerRange, in: textStorage)
                if line.contentRange.length > 0 {
                    textStorage.addAttributes([
                        .font: style.font,
                        .foregroundColor: NSColor(AppColors.textPrimary)
                    ], range: line.contentRange)
                }
                let marker = String(repeating: "#", count: level)
                drawnMarkers.append(
                    DrawnMarker(
                        lineRange: line.range,
                        text: marker,
                        font: style.markerFont,
                        tracking: style.markerTracking,
                        color: NSColor(AppColors.textTertiary).withAlphaComponent(0.6),
                        indent: 0,
                        alignsTo: style.font,
                        isRightAligned: true
                    )
                )

            case .quote:
                let paragraph = paragraphStyle(lineHeight: Self.quoteLineHeight)
                paragraph.firstLineHeadIndent = MarkdownBlockGrammar.quoteTextIndent
                paragraph.headIndent = MarkdownBlockGrammar.quoteTextIndent
                textStorage.addAttribute(.paragraphStyle, value: paragraph, range: line.range)
                collapse(line.collapsedMarkerRange, in: textStorage)
                if line.contentRange.length > 0 {
                    textStorage.addAttributes([
                        .font: quoteFont,
                        .foregroundColor: NSColor(AppColors.textSecondary)
                    ], range: line.contentRange)
                }

            case .code:
                let paragraph = paragraphStyle(lineHeight: Self.codeLineHeight)
                paragraph.firstLineHeadIndent = Self.codeBlockPadding.width
                paragraph.headIndent = Self.codeBlockPadding.width
                if previousKind != .code {
                    paragraph.paragraphSpacingBefore = Self.codeBlockPadding.height
                }
                if nextKind != .code {
                    paragraph.paragraphSpacing = Self.codeBlockPadding.height
                }
                textStorage.addAttributes([
                    .font: codeFont,
                    .foregroundColor: NSColor(AppColors.textSecondary),
                    .paragraphStyle: paragraph
                ], range: line.range)

            case .bullet, .ordered, .task:
                let textIndent = MarkdownBlockGrammar.textIndent(for: line.kind)
                let paragraph = paragraphStyle(lineHeight: Self.bodyLineHeight)
                paragraph.firstLineHeadIndent = textIndent
                paragraph.headIndent = textIndent
                if nextKind?.isListItem == true {
                    paragraph.paragraphSpacing = Self.listItemSpacing
                }
                textStorage.addAttribute(.paragraphStyle, value: paragraph, range: line.range)
                collapse(line.collapsedMarkerRange, in: textStorage)
                if let marker = MarkdownBlockGrammar.renderedMarker(for: line.kind) {
                    drawnMarkers.append(
                        DrawnMarker(
                            lineRange: line.range,
                            text: marker,
                            font: markerFont,
                            tracking: 0,
                            color: NSColor(AppColors.textTertiary),
                            indent: MarkdownBlockGrammar.markerIndent(for: line.kind),
                            alignsTo: baseFont,
                            isRightAligned: false
                        )
                    )
                }

            case .paragraph:
                break
            }
        }
    }

    /// Hides a raw marker without deleting it: 1 pt and clear, still selectable.
    private func collapse(_ range: NSRange, in textStorage: NSTextStorage) {
        guard range.length > 0 else { return }
        textStorage.addAttributes([
            .font: collapsedMarkerFont,
            .foregroundColor: NSColor.clear
        ], range: range)
    }

    private func reapplyCodeBlocks(_ lines: [MarkdownLine], to textStorage: NSTextStorage) {
        for line in lines where line.kind == .code && line.range.length > 0 {
            textStorage.addAttributes([
                .font: codeFont,
                .foregroundColor: NSColor(AppColors.textSecondary)
            ], range: line.range)
            textStorage.removeAttribute(.strikethroughStyle, range: line.range)
            textStorage.removeAttribute(.underlineStyle, range: line.range)
            textStorage.removeAttribute(.backgroundColor, range: line.range)
        }
        inlineCodeRanges = inlineCodeRanges.filter { candidate in
            !lines.contains { $0.kind == .code && NSIntersectionRange($0.range, candidate).length > 0 }
        }
    }

    private func paragraphStyle(lineHeight: CGFloat) -> NSMutableParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.minimumLineHeight = lineHeight
        style.maximumLineHeight = lineHeight
        return style
    }

    // MARK: - Block decoration

    private func drawCodeBlockCards() {
        guard !codeBlockRanges.isEmpty, let layoutManager, let textContainer else { return }
        let origin = textContainerOrigin
        let fill = NSColor(AppColors.windowBackground)
        let stroke = NSColor(AppColors.border)

        for range in codeBlockRanges {
            let glyphRange = layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            var bounds = layoutManager.boundingRect(forGlyphRange: glyphRange, in: textContainer)
            bounds.origin.x = 0
            bounds.size.width = textContainer.size.width
            let card = bounds.offsetBy(dx: origin.x, dy: origin.y).insetBy(dx: 1, dy: 0)
            let path = NSBezierPath(roundedRect: card, xRadius: 8, yRadius: 8)
            fill.setFill()
            path.fill()
            stroke.setStroke()
            path.lineWidth = 1
            path.stroke()
        }
    }

    private func drawQuoteBars() {
        guard !quoteBlockRanges.isEmpty, let layoutManager, let textContainer else { return }
        let origin = textContainerOrigin
        NSColor(AppColors.border).setFill()

        for range in quoteBlockRanges {
            let glyphRange = layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            let bounds = layoutManager.boundingRect(forGlyphRange: glyphRange, in: textContainer)
            let bar = NSRect(
                x: origin.x,
                y: origin.y + bounds.minY,
                width: 2,
                height: bounds.height
            )
            NSBezierPath(roundedRect: bar, xRadius: 1, yRadius: 1).fill()
        }
    }

    private func drawInlineCodeChips() {
        guard !inlineCodeRanges.isEmpty, let layoutManager, let textContainer else { return }
        let origin = textContainerOrigin
        let fill = NSColor(AppColors.windowBackground)
        let stroke = NSColor(AppColors.border)

        for range in inlineCodeRanges {
            let glyphRange = layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            layoutManager.enumerateEnclosingRects(
                forGlyphRange: glyphRange,
                withinSelectedGlyphRange: NSRange(location: NSNotFound, length: 0),
                in: textContainer
            ) { rect, _ in
                let chip = NSRect(
                    x: origin.x + rect.minX - 4,
                    y: origin.y + rect.minY + 2,
                    width: rect.width + 8,
                    height: max(0, rect.height - 4)
                )
                let path = NSBezierPath(roundedRect: chip, xRadius: 4, yRadius: 4)
                fill.setFill()
                path.fill()
                stroke.setStroke()
                path.lineWidth = 1
                path.stroke()
            }
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        // Block decoration is painted first so glyphs land on top of it. The
        // view draws no background of its own, so nothing erases these.
        drawCodeBlockCards()
        drawQuoteBars()
        drawInlineCodeChips()

        super.draw(dirtyRect)

        // NSTextView leaves the text-container clip installed after glyph
        // drawing; reset it so gutter markers (outside the container inset)
        // are not clipped away.
        let context = NSGraphicsContext.current?.cgContext
        context?.saveGState()
        context?.resetClip()
        drawMarkers()
        context?.restoreGState()
    }

    /// Paints heading hashes in the gutter and list bullets on the text axis.
    ///
    /// Layout-manager rects are in container coordinates, so the container
    /// origin (the inset) is added to reach view space.
    private func drawMarkers() {
        guard !drawnMarkers.isEmpty, let layoutManager else { return }

        let origin = textContainerOrigin

        for marker in drawnMarkers {
            let glyphRange = layoutManager.glyphRange(
                forCharacterRange: marker.lineRange,
                actualCharacterRange: nil
            )
            guard glyphRange.location < layoutManager.numberOfGlyphs else { continue }
            let lineRect = layoutManager.lineFragmentRect(
                forGlyphAt: glyphRange.location,
                effectiveRange: nil
            )
            var attributes: [NSAttributedString.Key: Any] = [
                .font: marker.font,
                .foregroundColor: marker.color
            ]
            if marker.tracking != 0 {
                attributes[.kern] = marker.tracking
            }
            let markerSize = (marker.text as NSString).size(withAttributes: attributes)
            // Baseline-align to the line's own text, then lift the marker onto
            // that baseline rather than the top of its own box.
            let baselineY = origin.y + lineRect.minY
                + (lineRect.height - marker.alignsTo.ascender + marker.alignsTo.descender) / 2
                + marker.alignsTo.ascender
            let x: CGFloat
            if marker.isRightAligned {
                x = max(1, origin.x - Self.gutterMarkerPadding - markerSize.width)
            } else {
                x = origin.x + marker.indent
            }
            (marker.text as NSString).draw(
                at: NSPoint(x: x, y: baselineY - marker.font.ascender),
                withAttributes: attributes
            )
        }
    }

    // MARK: - Inline passes

    private func applyBold(to textStorage: NSTextStorage, text: String) {
        let pattern = "\\*\\*(?!\\*)(.+?)\\*\\*(?!\\*)"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return }

        let matches = regex.matches(in: text, range: NSRange(text.startIndex..., in: text))
        for match in matches {
            let fullRange = match.range(at: 0)
            let contentRange = match.range(at: 1)

            let syntaxStart = NSRange(location: fullRange.location, length: 2)
            let syntaxEnd = NSRange(location: fullRange.location + fullRange.length - 2, length: 2)

            textStorage.addAttributes([
                .foregroundColor: NSColor(AppColors.textTertiary).withAlphaComponent(0.5)
            ], range: syntaxStart)
            textStorage.addAttributes([
                .foregroundColor: NSColor(AppColors.textTertiary).withAlphaComponent(0.5)
            ], range: syntaxEnd)

            textStorage.addAttributes([
                .font: FontLoader.nsFont(family: .inter, size: 13, weight: .semibold)
            ], range: contentRange)
        }
    }

    private func applyItalic(to textStorage: NSTextStorage, text: String) {
        let pattern = "(?<!\\*)\\*(?!\\*)(.+?)(?<!\\*)\\*(?!\\*)"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return }

        let matches = regex.matches(in: text, range: NSRange(text.startIndex..., in: text))
        for match in matches {
            let fullRange = match.range(at: 0)
            let contentRange = match.range(at: 1)

            let syntaxStart = NSRange(location: fullRange.location, length: 1)
            let syntaxEnd = NSRange(location: fullRange.location + fullRange.length - 1, length: 1)

            textStorage.addAttributes([
                .foregroundColor: NSColor(AppColors.textTertiary).withAlphaComponent(0.5)
            ], range: syntaxStart)
            textStorage.addAttributes([
                .foregroundColor: NSColor(AppColors.textTertiary).withAlphaComponent(0.5)
            ], range: syntaxEnd)

            textStorage.addAttributes([
                .font: NSFontManager.shared.convert(baseFont, toHaveTrait: .italicFontMask)
            ], range: contentRange)
        }
    }

    private func applyBoldItalic(to textStorage: NSTextStorage, text: String) {
        let pattern = "\\*\\*\\*(.+?)\\*\\*\\*"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return }

        let matches = regex.matches(in: text, range: NSRange(text.startIndex..., in: text))
        for match in matches {
            let fullRange = match.range(at: 0)
            let contentRange = match.range(at: 1)

            let syntaxStart = NSRange(location: fullRange.location, length: 3)
            let syntaxEnd = NSRange(location: fullRange.location + fullRange.length - 3, length: 3)

            textStorage.addAttributes([
                .foregroundColor: NSColor(AppColors.textTertiary).withAlphaComponent(0.5)
            ], range: syntaxStart)
            textStorage.addAttributes([
                .foregroundColor: NSColor(AppColors.textTertiary).withAlphaComponent(0.5)
            ], range: syntaxEnd)

            let boldItalicFont = NSFontManager.shared.convert(
                FontLoader.nsFont(family: .inter, size: 13, weight: .semibold),
                toHaveTrait: .italicFontMask
            )
            textStorage.addAttributes([
                .font: boldItalicFont
            ], range: contentRange)
        }
    }

    private func applyInlineCode(to textStorage: NSTextStorage, text: String) {
        let pattern = "`([^`\n]+)`"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return }

        let matches = regex.matches(in: text, range: NSRange(text.startIndex..., in: text))
        for match in matches {
            let fullRange = match.range(at: 0)
            let contentRange = match.range(at: 1)

            let syntaxStart = NSRange(location: fullRange.location, length: 1)
            let syntaxEnd = NSRange(location: fullRange.location + fullRange.length - 1, length: 1)

            textStorage.addAttributes([
                .foregroundColor: NSColor(AppColors.textTertiary).withAlphaComponent(0.5)
            ], range: syntaxStart)
            textStorage.addAttributes([
                .foregroundColor: NSColor(AppColors.textTertiary).withAlphaComponent(0.5)
            ], range: syntaxEnd)

            textStorage.addAttributes([
                .font: codeFont,
                .foregroundColor: NSColor(AppColors.textSecondary)
            ], range: contentRange)
            inlineCodeRanges.append(contentRange)
        }
    }

    private func applyStrikethrough(to textStorage: NSTextStorage, text: String) {
        let pattern = "~~(.+?)~~"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return }

        let matches = regex.matches(in: text, range: NSRange(text.startIndex..., in: text))
        for match in matches {
            let fullRange = match.range(at: 0)
            let contentRange = match.range(at: 1)

            let syntaxStart = NSRange(location: fullRange.location, length: 2)
            let syntaxEnd = NSRange(location: fullRange.location + fullRange.length - 2, length: 2)

            textStorage.addAttributes([
                .foregroundColor: NSColor(AppColors.textTertiary).withAlphaComponent(0.5)
            ], range: syntaxStart)
            textStorage.addAttributes([
                .foregroundColor: NSColor(AppColors.textTertiary).withAlphaComponent(0.5)
            ], range: syntaxEnd)

            textStorage.addAttributes([
                .strikethroughStyle: NSUnderlineStyle.single.rawValue,
                .strikethroughColor: NSColor(AppColors.textSecondary)
            ], range: contentRange)
        }
    }

    private func applyLinks(to textStorage: NSTextStorage, text: String) {
        let pattern = "\\[([^\\]]+)\\]\\(([^)]+)\\)"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return }

        let matches = regex.matches(in: text, range: NSRange(text.startIndex..., in: text))
        for match in matches {
            let fullRange = match.range(at: 0)
            let textRange = match.range(at: 1)

            textStorage.addAttributes([
                .foregroundColor: NSColor(AppColors.accent),
                .underlineStyle: NSUnderlineStyle.single.rawValue
            ], range: textRange)

            let bracketStart = NSRange(location: fullRange.location, length: 1)
            let bracketEnd = NSRange(location: textRange.location + textRange.length, length: 1)
            let urlPart = NSRange(location: bracketEnd.location + 1, length: fullRange.length - textRange.length - 3)

            textStorage.addAttributes([
                .foregroundColor: NSColor(AppColors.textTertiary).withAlphaComponent(0.5)
            ], range: bracketStart)
            textStorage.addAttributes([
                .foregroundColor: NSColor(AppColors.textTertiary).withAlphaComponent(0.5)
            ], range: bracketEnd)
            textStorage.addAttributes([
                .foregroundColor: NSColor(AppColors.textTertiary).withAlphaComponent(0.5)
            ], range: urlPart)
        }
    }

    private func applyTaskCheckboxes(to textStorage: NSTextStorage, text: String) {
        for match in MarkdownCheckbox.matches(in: text) {
            let glyph = match.isChecked ? "☑" : "☐"
            // Style the markdown marker to look like a checkbox glyph (content stays markdown).
            textStorage.addAttributes([
                .foregroundColor: NSColor(AppColors.accent),
                .font: FontLoader.nsFont(family: .inter, size: 13, weight: .medium),
                .toolTip: glyph
            ], range: match.markerRange)

            if match.isChecked, match.contentRange.length > 0 {
                textStorage.addAttributes([
                    .strikethroughStyle: NSUnderlineStyle.single.rawValue,
                    .strikethroughColor: NSColor(AppColors.textSecondary),
                    .foregroundColor: NSColor(AppColors.textSecondary)
                ], range: match.contentRange)
            }
        }
    }
}

#Preview {
    MarkdownEditor(text: .constant("""
    # Heading 1
    ## Heading 2

    This is **bold** and this is *italic* and this is ***bold italic***.

    Here's some `inline code` in a sentence.

    ~~Strikethrough text~~

    [Link text](https://example.com)

    > This is a blockquote

    - List item 1
      - Nested item
    - List item 2

    - [ ] Unchecked task
    - [x] Checked task

    1. Numbered item
    2. Another numbered

    ```
    let code = "block"
    ```
    """))
    .frame(width: 500, height: 400)
    .padding()
}
