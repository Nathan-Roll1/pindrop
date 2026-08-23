//
//  EnhancedViewPresentationTests.swift
//  PindropTests
//
//  Created on 2026-08-22.
//

import Foundation
import Testing
import PindropCore
import PindropData
@testable import Pindrop

@Suite("Enhanced view presentation (WP6)")
struct EnhancedViewPresentationTests {

    private let locale = Locale(identifier: "en")
    private let revisionID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
    private let otherRevisionID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!

    // MARK: - Fixtures

    private func segment(
        id: String,
        revisionID: UUID? = nil,
        start: TimeInterval,
        duration: TimeInterval = 4,
        text: String = "The release candidate ships on Friday.",
        speakerLabel: String? = "Speaker 2",
        speakerNumber: Int? = 2,
        isCurrentUser: Bool = false
    ) -> TranscriptSegmentSnapshot {
        TranscriptSegmentSnapshot(
            id: id,
            revisionID: revisionID ?? self.revisionID,
            speakerKey: "s\(speakerNumber ?? 1)",
            speakerLabel: speakerLabel,
            speakerNumber: speakerNumber,
            isCurrentUser: isCurrentUser,
            text: text,
            startOffset: start,
            duration: duration
        )
    }

    private func citation(
        _ identifier: String,
        revisionID: UUID? = nil,
        start: TimeInterval,
        end: TimeInterval,
        speakerLabel: String? = "Speaker 2",
        text: String = "The release candidate ships on Friday."
    ) -> MeetingNoteCitation {
        MeetingNoteCitation(
            identifier: identifier,
            transcriptRevisionID: revisionID ?? self.revisionID,
            startTime: start,
            endTime: end,
            speakerLabel: speakerLabel,
            text: text
        )
    }

    private func makePanel(
        content: String,
        templatePresetIdentifier: String = "summary",
        templateDisplayName: String = "Summary",
        isLegacy: Bool = false,
        id: UUID = UUID()
    ) throws -> CaptureEnhancedPanelSnapshot {
        try CaptureEnhancedPanelSnapshot(
            id: id,
            sessionID: UUID(),
            noteID: UUID(),
            templatePresetIdentifier: templatePresetIdentifier,
            templateDisplayName: templateDisplayName,
            content: content,
            generation: 1,
            assignmentAttempt: 1,
            createdAt: Date(timeIntervalSinceReferenceDate: 1_000),
            isLegacy: isLegacy
        )
    }

    // MARK: - Citation markers

    @Test func aMarkerIsLiftedOutOfTheTextAndIntoAChip() throws {
        let target = segment(id: "span-a", start: 12)
        let blocks = EnhancedViewPresentation.blocks(
            in: "- The migration ships behind the schema version. [C1]",
            targets: ["C1": target]
        )

        #expect(blocks.count == 1)
        // The bullet marker is not text: the view draws its own glyph.
        #expect(blocks[0].text == "The migration ships behind the schema version.")
        #expect(blocks[0].citations.map(\.label) == ["1"])
        #expect(blocks[0].citations.map(\.segmentID) == ["span-a"])
        #expect(blocks[0].citations[0].startOffset == 12)
    }

    @Test func aMarkerThatNamesNoSourceIsDroppedWithItsText() throws {
        // The evidence knows C1 only. A model that writes C9 is naming nothing,
        // so nothing is drawn and the forgery does not survive as text either.
        let blocks = EnhancedViewPresentation.blocks(
            in: "- Ship it. [C9]",
            targets: ["C1": segment(id: "span-a", start: 12)]
        )

        #expect(blocks[0].citations.isEmpty)
        #expect(blocks[0].text == "Ship it.")
    }

    @Test func aHomoglyphMarkerResolvesToTheSourceItImitates() throws {
        // The same grammar the sanitizer strips: a Cyrillic C and a letter l
        // still name C1. It is still only drawn because C1 exists.
        let blocks = EnhancedViewPresentation.blocks(
            in: "- Ship it. [Сl]",
            targets: ["C1": segment(id: "span-a", start: 12)]
        )

        #expect(blocks[0].citations.map(\.identifier) == ["C1"])
        #expect(blocks[0].text == "Ship it.")
    }

    @Test func codeIsQuotedVerbatimAndNeverReadAsACitation() throws {
        let blocks = EnhancedViewPresentation.blocks(
            in: "```\nlet flags = [C1]\n```",
            targets: ["C1": segment(id: "span-a", start: 12)]
        )
        let code = blocks.filter { $0.kind == .code }

        let quotesTheMarkerVerbatim = code.contains(where: { $0.text == "let flags = [C1]" })
        let citesNothing = code.allSatisfy(\.citations.isEmpty)

        #expect(code.count == 3)
        #expect(quotesTheMarkerVerbatim)
        #expect(citesNothing)
    }

    @Test func twoMarkersOnOneLineKeepTheirOrderAndBothIdentities() throws {
        let blocks = EnhancedViewPresentation.blocks(
            in: "- Both agreed. [C1] [C2]",
            targets: [
                "C1": segment(id: "span-a", start: 12),
                "C2": segment(id: "span-b", start: 30)
            ]
        )

        #expect(blocks[0].citations.map(\.identifier) == ["C1", "C2"])
        #expect(blocks[0].citations.map(\.id) == ["0-0", "0-1"])
        #expect(blocks[0].text == "Both agreed.")
    }

    @Test func aPanelWithNoMarkersKeepsItsTextExactly() throws {
        // The shipping path: generation strips markers before a panel is saved,
        // so the body must survive the citation pass untouched.
        let content = "## Decisions\n\n- Ship the migration behind the schema version."
        let blocks = EnhancedViewPresentation.blocks(in: content, targets: [:])

        let texts = blocks.map(\.text)
        let citesNothing = blocks.allSatisfy(\.citations.isEmpty)

        #expect(texts == [
            "Decisions",
            "",
            "Ship the migration behind the schema version."
        ])
        #expect(citesNothing)
    }

    // MARK: - Target resolution

    @Test func aCitationResolvesToTheSpanItWasDerivedFrom() {
        let first = segment(id: "span-a", start: 10)
        let second = segment(id: "span-b", start: 30)

        let resolved = EnhancedViewPresentation.target(
            for: citation("C2", start: 30, end: 34),
            in: [first, second]
        )

        #expect(resolved?.id == "span-b")
    }

    @Test func aCitationFromAnotherRevisionResolvesToNothing() {
        // Same seconds, different transcript revision. Pointing at it would put
        // one recording's words under another's citation.
        let resolved = EnhancedViewPresentation.target(
            for: citation("C1", revisionID: otherRevisionID, start: 10, end: 14),
            in: [segment(id: "span-a", start: 10)]
        )

        #expect(resolved == nil)
    }

    @Test func aCitationWithNoOverlapResolvesToNothing() {
        let resolved = EnhancedViewPresentation.target(
            for: citation("C1", start: 90, end: 94),
            in: [segment(id: "span-a", start: 10), segment(id: "span-b", start: 30)]
        )

        #expect(resolved == nil)
    }

    @Test func aRespannedTranscriptResolvesToTheSpanThatOverlapsMost() {
        let short = segment(id: "span-a", start: 9, duration: 1.5)
        let long = segment(id: "span-b", start: 10.5, duration: 6)

        let resolved = EnhancedViewPresentation.target(
            for: citation("C1", start: 10, end: 14),
            in: [short, long]
        )

        #expect(resolved?.id == "span-b")
    }

    // MARK: - Sources

    @Test func sourcesListEveryCitationThatIsOnScreen() throws {
        let panel = try makePanel(content: "## Decisions\n\n- Ship it.")
        let presentation = EnhancedViewPresentation.make(
            panel: panel,
            citations: [
                citation("C1", start: 10, end: 14),
                citation("C2", start: 30, end: 34)
            ],
            segments: [segment(id: "span-a", start: 10), segment(id: "span-b", start: 30)],
            locale: locale
        )

        #expect(presentation.sources.map(\.label) == ["1", "2"])
        #expect(presentation.sources.map(\.segmentID) == ["span-a", "span-b"])
        #expect(presentation.sources.map(\.timestampText) == ["00:10", "00:30"])
    }

    @Test func aCitationWithNoSpanOnScreenIsNotOfferedAsASource() throws {
        // The transcript was deleted, so nothing can be jumped to. A source
        // that cannot be opened is not a source.
        let panel = try makePanel(content: "- Ship it.")
        let presentation = EnhancedViewPresentation.make(
            panel: panel,
            citations: [citation("C1", start: 10, end: 14)],
            segments: [],
            locale: locale
        )

        #expect(presentation.sources.isEmpty)
    }

    @Test func aSourceCarriesWhatTheSpeakerDotNeeds() throws {
        // Round B draws a speaker dot in the peek, colored by the same key the
        // transcript turns use. The row has to carry it or the dot would invent
        // a color of its own.
        let panel = try makePanel(content: "- Ship it.")
        let presentation = EnhancedViewPresentation.make(
            panel: panel,
            citations: [
                citation("C1", start: 10, end: 14),
                citation("C2", start: 30, end: 34)
            ],
            segments: [
                segment(id: "span-a", start: 10, speakerLabel: "You", speakerNumber: nil, isCurrentUser: true),
                segment(id: "span-b", start: 30)
            ],
            locale: locale
        )

        #expect(presentation.sources[0].isCurrentUser)
        #expect(presentation.sources[0].speakerKey == "s1")
        #expect(!presentation.sources[1].isCurrentUser)
        #expect(presentation.sources[1].speakerKey == "s2")
    }

    @Test func aSourceNamesItsSpeakerTheWayTheTranscriptDoes() throws {
        let panel = try makePanel(content: "- Ship it.")
        let presentation = EnhancedViewPresentation.make(
            panel: panel,
            citations: [
                citation("C1", start: 10, end: 14, speakerLabel: "SPEAKER_01"),
                citation("C2", start: 30, end: 34, speakerLabel: nil)
            ],
            segments: [
                segment(id: "span-a", start: 10, speakerLabel: "You", speakerNumber: nil, isCurrentUser: true),
                segment(id: "span-b", start: 30, speakerLabel: nil, speakerNumber: nil)
            ],
            locale: locale
        )

        #expect(presentation.sources[0].speakerName == "You")
        #expect(presentation.sources[1].speakerName == nil)
    }

    @Test func sourceTextIsQuotedRatherThanShownRaw() throws {
        let panel = try makePanel(content: "- Ship it.")
        let presentation = EnhancedViewPresentation.make(
            panel: panel,
            citations: [citation("C1", start: 10, end: 14, text: "Line one\nLine two")],
            segments: [segment(id: "span-a", start: 10)],
            locale: locale
        )

        #expect(presentation.sources[0].text == "\"Line one\\nLine two\"")
    }

    @Test func aLineIsOnlyPeekableWhenItsSourceResolvedToo() throws {
        // One resolution pass answers the line and the peek, so a panel can
        // never offer a source it cannot open.
        let panel = try makePanel(content: "- Ship it. [C1] [C2]")
        let presentation = EnhancedViewPresentation.make(
            panel: panel,
            citations: [
                citation("C1", start: 10, end: 14),
                citation("C2", revisionID: otherRevisionID, start: 30, end: 34)
            ],
            segments: [segment(id: "span-a", start: 10)],
            locale: locale
        )

        #expect(presentation.sources.map(\.id) == ["C1"])
        #expect(presentation.blocks[0].citations.map(\.identifier) == ["C1"])

        let peek = EnhancedViewPresentation.peekTarget(
            for: presentation.blocks[0],
            in: presentation.sources
        )
        #expect(peek?.id == "C1")
        #expect(peek?.segmentID == "span-a")
    }

    // MARK: - Source peek

    @Test func aLineThatCitesNothingHasNoPeek() throws {
        // The shipping path: generation strips markers, so most lines cite
        // nothing. Those lines get no wash, no magnifier, and nothing to click.
        let panel = try makePanel(content: "- Ship it.")
        let presentation = EnhancedViewPresentation.make(
            panel: panel,
            citations: [citation("C1", start: 10, end: 14)],
            segments: [segment(id: "span-a", start: 10)],
            locale: locale
        )

        #expect(presentation.sources.count == 1)
        #expect(
            EnhancedViewPresentation.peekTarget(
                for: presentation.blocks[0],
                in: presentation.sources
            ) == nil
        )
    }

    @Test func aLineWithTwoMarkersPeeksAtTheFirstThatResolved() throws {
        let panel = try makePanel(content: "- Both agreed. [C1] [C2]")
        let presentation = EnhancedViewPresentation.make(
            panel: panel,
            citations: [
                citation("C1", start: 10, end: 14),
                citation("C2", start: 30, end: 34)
            ],
            segments: [segment(id: "span-a", start: 10), segment(id: "span-b", start: 30)],
            locale: locale
        )

        #expect(
            EnhancedViewPresentation.peekTarget(
                for: presentation.blocks[0],
                in: presentation.sources
            )?.id == "C1"
        )
    }

    @Test func thePeekSaysWhereItCameFromAndHowToGetThere() {
        #expect(EnhancedViewPresentation.peekTitle(locale: locale) == "From the transcript")
        #expect(EnhancedViewPresentation.peekJumpTitle(locale: locale) == "Show in transcript")
    }

    @Test func noPanelIsAnEmptyView() {
        let presentation = EnhancedViewPresentation.make(panel: nil, locale: locale)

        #expect(presentation == .empty)
        #expect(presentation.blocks.isEmpty)
        #expect(presentation.sources.isEmpty)
    }

    // MARK: - Legacy panels

    @Test func aLegacyPanelIsReadOnlyAndSaysSo() throws {
        let panel = try makePanel(
            content: "- Ship it.",
            templatePresetIdentifier: CaptureEnhancedPanelSnapshot.legacyMeetingNoteTemplateIdentifier,
            templateDisplayName: CaptureEnhancedPanelSnapshot.legacyMeetingNoteDisplayName,
            isLegacy: true
        )
        let presentation = EnhancedViewPresentation.make(panel: panel, locale: locale)

        #expect(presentation.isReadOnly)
        #expect(presentation.readOnlyLabel == "Meeting note")
        #expect(!EnhancedViewPresentation.showsTemplateMenu(panel: panel, selection: .enhanced))
    }

    @Test func aGeneratedPanelOffersTheTemplateMenuInTheEnhancedViewOnly() throws {
        let panel = try makePanel(content: "- Ship it.")

        #expect(EnhancedViewPresentation.showsTemplateMenu(panel: panel, selection: .enhanced))
        #expect(!EnhancedViewPresentation.showsTemplateMenu(panel: panel, selection: .transcript))
        #expect(!EnhancedViewPresentation.showsTemplateMenu(panel: panel, selection: .humanNotes))
        #expect(!EnhancedViewPresentation.showsTemplateMenu(panel: nil, selection: .enhanced))
        #expect(EnhancedViewPresentation.make(panel: panel, locale: locale).readOnlyLabel == nil)
    }

    // MARK: - Template menu

    private func preset(
        _ identifier: String,
        _ name: String,
        isBuiltIn: Bool,
        sortOrder: Int
    ) -> TemplateMenuPreset {
        TemplateMenuPreset(
            identifier: identifier,
            name: name,
            isBuiltIn: isBuiltIn,
            sortOrder: sortOrder
        )
    }

    @Test func theMenuListsBuiltInsFirstThenCustomTemplates() {
        let items = EnhancedViewPresentation.templateMenuItems(
            presets: [
                preset("mine", "My format", isBuiltIn: false, sortOrder: 1),
                preset("standup", "Standup", isBuiltIn: true, sortOrder: 2),
                preset("summary", "Summary", isBuiltIn: true, sortOrder: 1),
                preset("theirs", "Client recap", isBuiltIn: false, sortOrder: 0)
            ],
            selected: "summary"
        )

        #expect(items.map(\.name) == ["Summary", "Standup", "Client recap", "My format"])
        #expect(items.map(\.isBuiltIn) == [true, true, false, false])
        #expect(items.filter(\.isSelected).map(\.id) == ["summary"])
    }

    @Test func aTemplateWhosePresetWasDeletedChecksNothing() {
        let items = EnhancedViewPresentation.templateMenuItems(
            presets: [preset("summary", "Summary", isBuiltIn: true, sortOrder: 1)],
            selected: "deleted-preset"
        )

        #expect(items.count == 1)
        #expect(!items[0].isSelected)
    }

    // MARK: - Regenerate versus switch

    @Test func switchingBackToAGeneratedTemplateShowsItInsteadOfGeneratingIt() throws {
        let summary = try makePanel(content: "Summary", templatePresetIdentifier: "summary")
        let standup = try makePanel(content: "Standup", templatePresetIdentifier: "standup")

        let decision = EnhancedViewPresentation.selection(
            of: "summary",
            panels: [standup, summary],
            showing: "standup"
        )

        #expect(decision == .showExisting(panelID: summary.id, templatePresetIdentifier: "summary"))
    }

    @Test func aTemplateWithNoPanelGenerates() throws {
        let summary = try makePanel(content: "Summary", templatePresetIdentifier: "summary")

        #expect(
            EnhancedViewPresentation.selection(
                of: "standup",
                panels: [summary],
                showing: "summary"
            ) == .generate(templatePresetIdentifier: "standup")
        )
    }

    @Test func pickingTheTemplateAlreadyOnScreenDoesNothing() throws {
        let summary = try makePanel(content: "Summary", templatePresetIdentifier: "summary")

        #expect(
            EnhancedViewPresentation.selection(
                of: "summary",
                panels: [summary],
                showing: "summary"
            ) == .alreadyShowing
        )
    }

    @Test func theFirstTemplateOfANoteWithNoPanelsGenerates() {
        #expect(
            EnhancedViewPresentation.selection(of: "summary", panels: [], showing: nil)
                == .generate(templatePresetIdentifier: "summary")
        )
    }

    // MARK: - Copy

    @Test func theWritingMessageNamesTheTemplateWhenItHasAName() {
        #expect(
            EnhancedViewPresentation.generatingMessage(templateName: "Standup", locale: locale)
                == "Writing your enhanced note with Standup."
        )
        #expect(
            EnhancedViewPresentation.generatingMessage(templateName: nil, locale: locale)
                == "Writing your enhanced note."
        )
        #expect(
            EnhancedViewPresentation.generatingMessage(templateName: "", locale: locale)
                == "Writing your enhanced note."
        )
    }

    @Test func aSourceNumberReadsWithoutItsPrefix() {
        #expect(EnhancedViewPresentation.label(for: "C12") == "12")
        #expect(EnhancedViewPresentation.label(for: "C") == "C")
        #expect(EnhancedViewPresentation.label(for: "Chapter") == "Chapter")
    }

    // MARK: - The merged dropdown

    private var dropdownPresets: [TemplateMenuPreset] {
        [
            preset("mine", "Client recap", isBuiltIn: false, sortOrder: 0),
            preset("meeting", "Meeting Notes", isBuiltIn: true, sortOrder: 1),
            preset("bullets", "Bullet Summary", isBuiltIn: true, sortOrder: 0)
        ]
    }

    @Test func theDropdownKeepsTheMenuOrderAndChecksTheTemplateOnScreen() {
        let menu = EnhancedViewPresentation.menu(
            presets: dropdownPresets,
            selected: "meeting",
            locale: locale
        )

        #expect(menu.headerTitle == "Enhanced notes")
        #expect(menu.templatesTitle == "Templates")
        #expect(menu.templates.map(\.title) == ["Bullet Summary", "Meeting Notes", "Client recap"])
        #expect(menu.templates.filter(\.isSelected).map(\.id) == ["meeting"])
        #expect(menu.templates.map(\.action) == [
            .selectTemplate("bullets"),
            .selectTemplate("meeting"),
            .selectTemplate("mine")
        ])
    }

    @Test func theDropdownEndsWithTheTwoWaysIntoTheTemplateSheet() {
        let menu = EnhancedViewPresentation.menu(
            presets: dropdownPresets,
            selected: nil,
            locale: locale
        )

        #expect(menu.actions.map(\.title) == ["All templates…", "New template"])
        #expect(menu.actions.map(\.action) == [.manageTemplates, .newTemplate])
        #expect(menu.actions.allSatisfy { !$0.isSelected })
    }

    @Test func everyTemplateRowCarriesAGlyphAndCustomOnesReadAsDocuments() {
        let menu = EnhancedViewPresentation.menu(
            presets: dropdownPresets,
            selected: nil,
            locale: locale
        )

        #expect(menu.templates.allSatisfy { !$0.systemImage.isEmpty })
        #expect(
            EnhancedViewPresentation.templateGlyph(identifier: "mine", isBuiltIn: false)
                == "doc.text"
        )
        #expect(
            EnhancedViewPresentation.templateGlyph(identifier: "bullets", isBuiltIn: true)
                == "list.bullet"
        )
        // A built-in this build has never heard of still gets a glyph slot.
        #expect(
            EnhancedViewPresentation.templateGlyph(identifier: "future", isBuiltIn: true)
                == "sparkles"
        )
    }

    @Test func aNoteWithNoTemplatesStillOffersTheWayToMakeOne() {
        let menu = EnhancedViewPresentation.menu(presets: [], selected: nil, locale: locale)

        #expect(menu.templates.isEmpty)
        #expect(menu.actions.map(\.action) == [.manageTemplates, .newTemplate])
        #expect(menu.regenerateHelp == "Write this note again")
    }
}
