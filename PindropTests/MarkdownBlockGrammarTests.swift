//
//  MarkdownBlockGrammarTests.swift
//  PindropTests
//
//  Created on 2026-08-22.
//

import Foundation
import Testing
@testable import Pindrop

@Suite("Markdown block grammar (WP3)")
struct MarkdownBlockGrammarTests {

    private func kinds(_ text: String) -> [MarkdownLine.Kind] {
        MarkdownBlockGrammar.lines(in: text).map(\.kind)
    }

    private func content(_ text: String, at index: Int) -> String {
        let lines = MarkdownBlockGrammar.lines(in: text)
        return (text as NSString).substring(with: lines[index].contentRange)
    }

    private func marker(_ text: String, at index: Int) -> String {
        let lines = MarkdownBlockGrammar.lines(in: text)
        return (text as NSString).substring(with: lines[index].collapsedMarkerRange)
    }

    // MARK: - Lines

    @Test func emptyTextHasNoLines() {
        #expect(MarkdownBlockGrammar.lines(in: "").isEmpty)
    }

    @Test func aTrailingNewlineDoesNotInventALine() {
        #expect(kinds("one\n") == [.paragraph])
        #expect(kinds("one\ntwo") == [.paragraph, .paragraph])
    }

    @Test func blankLinesAreTheirOwnKind() {
        #expect(kinds("one\n\ntwo") == [.paragraph, .blank, .paragraph])
        #expect(kinds("   \nx") == [.blank, .paragraph])
    }

    // MARK: - Headings

    @Test func headingsCarryTheirLevelAndHideTheirHashes() {
        #expect(kinds("## Plan") == [.heading(level: 2)])
        #expect(marker("## Plan", at: 0) == "## ")
        #expect(content("## Plan", at: 0) == "Plan")
        #expect(kinds("###### Deep") == [.heading(level: 6)])
    }

    @Test func sevenHashesIsNotAHeading() {
        #expect(kinds("####### Nope") == [.paragraph])
    }

    @Test func aHashWithNoSpaceIsNotAHeading() {
        #expect(kinds("#hashtag") == [.paragraph])
        #expect(kinds("#") == [.paragraph])
    }

    // MARK: - Bullets

    @Test func bulletsCountTheirLevelFromTheIndent() {
        #expect(kinds("- one") == [.bullet(level: 1)])
        #expect(kinds("  - two") == [.bullet(level: 2)])
        #expect(kinds("    - three") == [.bullet(level: 3)])
        #expect(kinds("\t- tabbed") == [.bullet(level: 3)])
    }

    @Test func everyBulletCharacterCounts() {
        #expect(kinds("* star") == [.bullet(level: 1)])
        #expect(kinds("+ plus") == [.bullet(level: 1)])
    }

    @Test func aDashWithNoSpaceIsProse() {
        #expect(kinds("-notalist") == [.paragraph])
    }

    @Test func theHiddenBulletMarkerIncludesTheIndent() {
        #expect(marker("  - two", at: 0) == "  - ")
        #expect(content("  - two", at: 0) == "two")
    }

    @Test func levelsAlternateBetweenFilledAndHollowGlyphs() {
        #expect(MarkdownBlockGrammar.renderedMarker(for: .bullet(level: 1)) == "•")
        #expect(MarkdownBlockGrammar.renderedMarker(for: .bullet(level: 2)) == "◦")
        #expect(MarkdownBlockGrammar.renderedMarker(for: .bullet(level: 3)) == "•")
    }

    // MARK: - Ordered lists

    @Test func orderedMarkersAreKeptVerbatim() {
        #expect(kinds("3. third") == [.ordered(level: 1, marker: "3.")])
        #expect(kinds("2) second") == [.ordered(level: 1, marker: "2)")])
        #expect(MarkdownBlockGrammar.renderedMarker(for: .ordered(level: 1, marker: "3.")) == "3.")
        #expect(content("3. third", at: 0) == "third")
    }

    @Test func aNumberWithNoDelimiterIsProse() {
        #expect(kinds("2026 was a year") == [.paragraph])
    }

    // MARK: - Tasks

    @Test func taskItemsKeepTheirCheckboxInTheText() {
        #expect(kinds("- [ ] open") == [.task(level: 1, isChecked: false)])
        #expect(kinds("- [x] done") == [.task(level: 1, isChecked: true)])
        #expect(kinds("- [X] done") == [.task(level: 1, isChecked: true)])
        // Only the bullet is hidden, so the checkbox stays clickable.
        #expect(marker("- [ ] open", at: 0) == "- ")
        #expect(content("- [ ] open", at: 0) == "[ ] open")
        #expect(MarkdownBlockGrammar.renderedMarker(for: .task(level: 1, isChecked: false)) == nil)
    }

    @Test func aBracketThatIsNotACheckboxStaysABullet() {
        #expect(kinds("- [see] this") == [.bullet(level: 1)])
    }

    // MARK: - Quotes

    @Test func quotesHideTheirAngleBracket() {
        #expect(kinds("> quoted") == [.quote])
        #expect(marker("> quoted", at: 0) == "> ")
        #expect(content("> quoted", at: 0) == "quoted")
    }

    // MARK: - Fenced code

    @Test func fencesWinOverEveryOtherRule() {
        let text = """
        before
        ```swift
        # not a heading
        - not a bullet
        ```
        after
        """
        #expect(kinds(text) == [.paragraph, .code, .code, .code, .code, .paragraph])
    }

    @Test func anUnterminatedFenceRunsToTheEnd() {
        let text = "```\nstill code\nand more"
        #expect(kinds(text) == [.code, .code, .code])
    }

    @Test func tildeFencesCountToo() {
        #expect(kinds("~~~\nx\n~~~") == [.code, .code, .code])
    }

    @Test func codeBlockRangesGroupConsecutiveLines() {
        let text = "a\n```\nx\n```\nb\n```\ny\n```"
        let lines = MarkdownBlockGrammar.lines(in: text)
        let ranges = MarkdownBlockGrammar.codeBlockRanges(lines)
        #expect(ranges.count == 2)
        let nsText = text as NSString
        #expect(nsText.substring(with: ranges[0]) == "```\nx\n```")
        #expect(nsText.substring(with: ranges[1]) == "```\ny\n```")
    }

    @Test func quoteBlockRangesGroupConsecutiveLines() {
        let text = "> one\n> two\n\n> three"
        let lines = MarkdownBlockGrammar.lines(in: text)
        let ranges = MarkdownBlockGrammar.quoteBlockRanges(lines)
        #expect(ranges.count == 2)
        #expect((text as NSString).substring(with: ranges[0]) == "> one\n> two")
    }

    // MARK: - Indents

    @Test func theMarkerSitsOneStepLeftOfTheText() {
        #expect(MarkdownBlockGrammar.textIndent(for: .bullet(level: 1)) == 20)
        #expect(MarkdownBlockGrammar.markerIndent(for: .bullet(level: 1)) == 0)
        #expect(MarkdownBlockGrammar.textIndent(for: .bullet(level: 2)) == 40)
        #expect(MarkdownBlockGrammar.markerIndent(for: .bullet(level: 2)) == 20)
        #expect(MarkdownBlockGrammar.textIndent(for: .quote) == 14)
        #expect(MarkdownBlockGrammar.textIndent(for: .paragraph) == 0)
        #expect(MarkdownBlockGrammar.textIndent(for: .heading(level: 2)) == 0)
        #expect(MarkdownBlockGrammar.markerIndent(for: .heading(level: 2)) == 0)
    }

    // MARK: - Ranges cover the source

    @Test func markerAndContentAlwaysReconstructTheLine() {
        let text = """
        # Title

        Some prose.
        - one
          - two
        1. first
        - [x] done
        > quoted
        ```
        code
        ```
        """
        let nsText = text as NSString
        for line in MarkdownBlockGrammar.lines(in: text) {
            let marker = nsText.substring(with: line.collapsedMarkerRange)
            let content = nsText.substring(with: line.contentRange)
            #expect(marker + content == nsText.substring(with: line.range))
        }
    }
}

@Suite("Markdown search matching")
struct MarkdownSearchMatchingTests {

    private func matched(_ text: String, _ query: String) -> [String] {
        let nsText = text as NSString
        return MarkdownSearchMatching.ranges(in: text, query: query).map(nsText.substring(with:))
    }

    // MARK: - Nothing to match

    @Test func anEmptyQueryMatchesNothing() {
        #expect(MarkdownSearchMatching.ranges(in: "some prose", query: "").isEmpty)
    }

    @Test func anEmptyTextMatchesNothing() {
        #expect(MarkdownSearchMatching.ranges(in: "", query: "prose").isEmpty)
    }

    @Test func aQueryThatIsAbsentMatchesNothing() {
        #expect(MarkdownSearchMatching.ranges(in: "some prose", query: "verse").isEmpty)
    }

    // MARK: - Positions

    @Test func rangesAreInReadingOrderAndAddressTheSource() {
        let text = "one two one two one"
        let ranges = MarkdownSearchMatching.ranges(in: text, query: "one")
        #expect(ranges == [
            NSRange(location: 0, length: 3),
            NSRange(location: 8, length: 3),
            NSRange(location: 16, length: 3)
        ])
    }

    @Test func matchesCrossLines() {
        let text = "# Title\n\n- note\n- another note"
        #expect(MarkdownSearchMatching.ranges(in: text, query: "note").count == 2)
    }

    // MARK: - Folding, same rule as the transcript search

    @Test func caseIsIgnored() {
        #expect(matched("Resume the RESUME", "resume") == ["Resume", "RESUME"])
    }

    @Test func diacriticsAreIgnored() {
        #expect(matched("résumé", "resume") == ["résumé"])
        #expect(matched("resume", "résumé") == ["resume"])
    }

    @Test func matchingAgreesWithTheTranscriptSearch() {
        let text = "Résumé review, resume writing, RESUME."
        let query = "resume"
        let transcript = TranscriptSegmentPresentation.runs(in: text, query: query)
            .filter(\.isMatch)
            .map(\.text)
        #expect(matched(text, query) == transcript)
    }

    // MARK: - Adjacent and overlapping

    @Test func adjacentMatchesAreAllReported() {
        #expect(matched("aaaa", "aa") == ["aa", "aa"])
    }

    @Test func aMatchNeverOverlapsTheOneBeforeIt() {
        let ranges = MarkdownSearchMatching.ranges(in: "abab", query: "aba")
        #expect(ranges == [NSRange(location: 0, length: 3)])
    }

    // MARK: - Multibyte safety

    @Test func rangesAreUTF16OffsetsThroughEmoji() {
        let text = "🎧 note 🎧 note"
        let ranges = MarkdownSearchMatching.ranges(in: text, query: "note")
        #expect(ranges == [
            NSRange(location: 3, length: 4),
            NSRange(location: 11, length: 4)
        ])
        #expect(matched(text, "note") == ["note", "note"])
    }

    @Test func anEmojiQueryMatchesItsWholeScalar() {
        #expect(matched("a 🎧 b 🎧", "🎧") == ["🎧", "🎧"])
    }
}
