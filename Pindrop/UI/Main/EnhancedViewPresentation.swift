//
//  EnhancedViewPresentation.swift
//  Pindrop
//
//  Created on 2026-08-22.
//
//  What the Enhanced view shows, decided once and tested without a window (WP6).
//
//  An enhanced panel is generated text beside evidence the app derived itself.
//  The text is untrusted: a model can write anything, including something that
//  looks like a citation. The evidence is not: every citation in a panel's
//  provenance was built by `MeetingNoteDerivation` from the same checkpoints the
//  transcript view reads, span for span.
//
//  So a citation is drawn only when both halves agree. A marker in the text has
//  to name a citation in the provenance, and that citation has to resolve to a
//  span that is on screen right now. Anything else is dropped rather than shown,
//  which is why nothing here ever invents a source, a number, or a target.
//
//  Note on markers today: `NoteEnhancementService` runs every generation through
//  `MeetingNoteDerivation.sanitizingGeneratedContent`, which strips citation
//  markers outright, and legacy generated notes were stored under the same rule.
//  Stored panels therefore carry no markers, so most lines resolve to no source
//  and are drawn as plain text with no peek. The marker path is implemented and
//  tested for the day content keeps them; it is not a promise that today's
//  panels have any.
//
//  Round B replaced the numeric chips and the "Sources" disclosure with the
//  source peek. Resolution did not change: a line is peekable exactly when a
//  chip would have been drawn on it.
//

import Foundation
import PindropCore
import PindropData

// MARK: - Values

/// One citation chip, drawn after the line that cites it.
struct EnhancedCitationChip: Identifiable, Equatable, Sendable {
    /// Unique inside one panel: the same source can be cited more than once.
    let id: String
    /// The citation identifier, as the evidence wrote it ("C3").
    let identifier: String
    /// What the chip reads ("3").
    let label: String
    /// The transcript span this points at.
    let segmentID: String
    let startOffset: TimeInterval
}

/// One drawn line of an enhanced panel.
struct EnhancedNoteBlock: Identifiable, Equatable, Sendable {
    let id: Int
    let kind: MarkdownLine.Kind
    /// The line with its citation markers removed. The chips carry those.
    let text: String
    let citations: [EnhancedCitationChip]
    /// The line cut into plain and matched runs, in order. Empty when nothing
    /// in the line matched, which is every line while nothing is searched.
    let runs: [TranscriptTextRun]

    /// The scroll identifier of this line. `id` is a position inside one panel
    /// and the page scrolls by string, so the two never get mistaken.
    var blockID: String { "enhanced-block-\(id)" }

    init(
        id: Int,
        kind: MarkdownLine.Kind,
        text: String,
        citations: [EnhancedCitationChip],
        runs: [TranscriptTextRun] = []
    ) {
        self.id = id
        self.kind = kind
        self.text = text
        self.citations = citations
        self.runs = runs
    }
}

/// One resolved source: the words a line of the panel was written from, and the
/// way back to them. Round B draws it as the source peek.
struct EnhancedSourceRow: Identifiable, Equatable, Sendable {
    /// The citation identifier ("C3").
    let id: String
    /// What the number reads ("3").
    let label: String
    /// Zero-padded mm:ss from the start of the recording.
    let timestampText: String
    /// Who said it, resolved the way the transcript resolves it. Nil when the
    /// span carries no speaker attribution.
    let speakerName: String?
    /// The key the shared speaker palette colors the dot by.
    let speakerKey: String?
    let isCurrentUser: Bool
    /// The cited words, quoted for display. Transcript text is untrusted, so it
    /// never reaches a view raw.
    let text: String
    let segmentID: String
    let startOffset: TimeInterval
}

/// The Enhanced view of one note, decided once.
struct EnhancedNotePresentation: Equatable, Sendable {
    let blocks: [EnhancedNoteBlock]
    let sources: [EnhancedSourceRow]
    /// True for a panel an older build generated. It is read only: regenerating
    /// it would have to rewrite rows this build must not touch.
    let isReadOnly: Bool
    /// The quiet label a read-only panel wears where the template menu would be.
    let readOnlyLabel: String?
    /// How many times the search text appears in the panel on screen.
    let matchCount: Int
    /// Which match the reader is standing on. It wears the stronger treatment.
    let currentMatchIndex: Int?
    /// The block each match lives in, indexed the same way the matches are. It
    /// is what the page scrolls to when the reader steps to the next one.
    let matchBlockIDs: [String]

    init(
        blocks: [EnhancedNoteBlock],
        sources: [EnhancedSourceRow],
        isReadOnly: Bool,
        readOnlyLabel: String?,
        matchCount: Int = 0,
        currentMatchIndex: Int? = nil,
        matchBlockIDs: [String] = []
    ) {
        self.blocks = blocks
        self.sources = sources
        self.isReadOnly = isReadOnly
        self.readOnlyLabel = readOnlyLabel
        self.matchCount = matchCount
        self.currentMatchIndex = currentMatchIndex
        self.matchBlockIDs = matchBlockIDs
    }

    /// The block holding the current match, when there is one.
    var currentMatchBlockID: String? {
        guard let currentMatchIndex,
              currentMatchIndex >= 0,
              currentMatchIndex < matchBlockIDs.count
        else {
            return nil
        }
        return matchBlockIDs[currentMatchIndex]
    }

    static let empty = EnhancedNotePresentation(
        blocks: [],
        sources: [],
        isReadOnly: false,
        readOnlyLabel: nil
    )
}

/// One preset offered by the template menu, as plain values.
struct TemplateMenuPreset: Equatable, Sendable {
    /// The identifier a generation is asked for: the built-in identity when the
    /// preset has one, the row identifier otherwise. Same rule the settings
    /// picker writes, so a template picked here and one picked there agree.
    let identifier: String
    let name: String
    let isBuiltIn: Bool
    let sortOrder: Int
}

/// One item of the template menu.
struct TemplateMenuItem: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let isBuiltIn: Bool
    /// The template the panel on screen was generated with.
    let isSelected: Bool
}

/// One row of the merged Enhanced dropdown.
struct EnhancedMenuRow: Identifiable, Equatable, Sendable {

    /// What the row does when it is picked.
    enum Action: Equatable, Sendable {
        /// Show, or write, the panel for this template.
        case selectTemplate(String)
        /// Open the template manager.
        case manageTemplates
        /// Open the template manager on a new template.
        case newTemplate
    }

    let id: String
    let title: String
    /// The glyph in the row's 13pt slot.
    let systemImage: String
    /// The template the panel on screen was generated with.
    let isSelected: Bool
    let action: Action
}

/// The merged Enhanced dropdown, decided once.
struct EnhancedMenuContent: Equatable, Sendable {
    let headerTitle: String
    /// The overline above the template rows.
    let templatesTitle: String
    /// What the panel on screen was written with, when no template wrote it. A
    /// checked row says which template ran; nothing says nothing, so this line
    /// says it instead. Nil when a template is set.
    let emptyTemplateMessage: String?
    let templates: [EnhancedMenuRow]
    /// The rows under the second hairline: manage, and create.
    let actions: [EnhancedMenuRow]
    /// What the regenerate glyph says it will do.
    let regenerateHelp: String
}

/// What picking a template in the menu has to do.
enum EnhancedTemplateSelection: Equatable, Sendable {
    /// The panel on screen was already generated with this template.
    case alreadyShowing
    /// This template has a panel: show it. Nothing is generated.
    case showExisting(panelID: UUID, templatePresetIdentifier: String)
    /// No panel for this template yet.
    case generate(templatePresetIdentifier: String)
}

// MARK: - Presentation

enum EnhancedViewPresentation {

    /// Points of the bullet slot, so the marker sits left of the body text.
    static let bulletSlotWidth: CGFloat = 14

    // MARK: The panel

    static func make(
        panel: CaptureEnhancedPanelSnapshot?,
        citations: [MeetingNoteCitation] = [],
        segments: [TranscriptSegmentSnapshot] = [],
        query: String = "",
        currentMatchIndex: Int? = nil,
        locale: Locale
    ) -> EnhancedNotePresentation {
        guard let panel else { return .empty }

        // One resolution pass answers both surfaces: a citation that names no
        // span on screen is not a chip and not a source either.
        var targets: [String: TranscriptSegmentSnapshot] = [:]
        var rows: [EnhancedSourceRow] = []
        for citation in citations {
            guard let segment = target(for: citation, in: segments) else { continue }
            targets[citation.identifier] = segment
            rows.append(
                EnhancedSourceRow(
                    id: citation.identifier,
                    label: label(for: citation.identifier),
                    timestampText: TranscriptSegmentPresentation.timestampText(segment.startOffset),
                    speakerName: speakerName(for: segment, locale: locale),
                    speakerKey: segment.speakerKey,
                    isCurrentUser: segment.isCurrentUser,
                    text: MeetingNoteDerivation.sourcePresentationText(citation.text),
                    segmentID: segment.id,
                    startOffset: segment.startOffset
                )
            )
        }

        // The search reads the drawn text, so a highlight can never land on a
        // citation marker the reader was never shown.
        let body = searched(
            blocks: bodyBlocks(in: panel.content, targets: targets),
            query: query
        )
        let matchCount = body.matchBlockIDs.count

        return EnhancedNotePresentation(
            blocks: body.blocks,
            sources: rows,
            isReadOnly: !panel.isRegenerable,
            readOnlyLabel: panel.isRegenerable ? nil : localized("Meeting note", locale: locale),
            matchCount: matchCount,
            currentMatchIndex: TranscriptSegmentPresentation.clampedMatchIndex(
                currentMatchIndex,
                total: matchCount
            ),
            matchBlockIDs: body.matchBlockIDs
        )
    }

    // MARK: Source peek

    /// The source a line opens, or nil when the line cites nothing that resolved.
    ///
    /// The peek shows only what the citation path already proved: a marker in
    /// the text that names a citation in the provenance, whose span is on screen.
    /// A line with no such marker is not peekable, and gets no hover wash either.
    static func peekTarget(
        for block: EnhancedNoteBlock,
        in sources: [EnhancedSourceRow]
    ) -> EnhancedSourceRow? {
        for citation in block.citations {
            if let match = sources.first(where: { $0.id == citation.identifier }) {
                return match
            }
        }
        return nil
    }

    /// The overline above a peeked span.
    static func peekTitle(locale: Locale) -> String {
        localized("From the transcript", locale: locale)
    }

    /// The action that takes a reader from the peek to the words themselves.
    static func peekJumpTitle(locale: Locale) -> String {
        localized("Show in transcript", locale: locale)
    }

    /// What a read-only panel says when someone looks for the template menu.
    static func readOnlyHelpText(locale: Locale) -> String {
        localized(
            "An earlier version of Pindrop wrote this note. It cannot be written again.",
            locale: locale
        )
    }

    // MARK: Blocks

    /// The panel body as drawable lines, with the citation markers lifted out of
    /// the text and into chips and the searched words picked out.
    static func blocks(
        in content: String,
        targets: [String: TranscriptSegmentSnapshot],
        query: String = ""
    ) -> [EnhancedNoteBlock] {
        searched(blocks: bodyBlocks(in: content, targets: targets), query: query).blocks
    }

    /// Cuts every block into plain and matched runs and numbers the matches in
    /// document order. One pass over the blocks on screen, so the numbers and
    /// the scroll targets can never disagree.
    ///
    /// Matching is the transcript's own rule, applied to the text a block draws
    /// rather than to the markdown behind it: a reader searching one note gets
    /// one answer, and a highlight sits on the characters they can see.
    static func searched(
        blocks: [EnhancedNoteBlock],
        query: String
    ) -> (blocks: [EnhancedNoteBlock], matchBlockIDs: [String]) {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuery.isEmpty else { return (blocks, []) }

        var counter = 0
        var matchBlockIDs: [String] = []
        let searched = blocks.map { block -> EnhancedNoteBlock in
            let runs = TranscriptSegmentPresentation.runs(in: block.text, query: trimmedQuery)
            guard !runs.isEmpty else { return block }
            let numbered = runs.map { run -> TranscriptTextRun in
                guard run.isMatch else { return run }
                let index = counter
                counter += 1
                matchBlockIDs.append(block.blockID)
                return TranscriptTextRun(
                    id: run.id,
                    text: run.text,
                    isMatch: true,
                    matchIndex: index
                )
            }
            return EnhancedNoteBlock(
                id: block.id,
                kind: block.kind,
                text: block.text,
                citations: block.citations,
                runs: numbered
            )
        }
        return (searched, matchBlockIDs)
    }

    /// The panel body before any search: one block per source line.
    private static func bodyBlocks(
        in content: String,
        targets: [String: TranscriptSegmentSnapshot]
    ) -> [EnhancedNoteBlock] {
        let nsContent = content as NSString
        return MarkdownBlockGrammar.lines(in: content).enumerated().map { index, line in
            let lineText = nsContent.substring(with: line.contentRange)
            // Code is quoted verbatim: a bracketed word inside a fence is text
            // the panel is showing, not a claim about the recording.
            guard line.kind != .code else {
                return EnhancedNoteBlock(id: index, kind: line.kind, text: lineText, citations: [])
            }
            let markers = MeetingNoteDerivation.citationMarkers(in: lineText)
            guard !markers.isEmpty else {
                return EnhancedNoteBlock(id: index, kind: line.kind, text: lineText, citations: [])
            }

            var chips: [EnhancedCitationChip] = []
            for (markerIndex, marker) in markers.enumerated() {
                guard
                    let identifier = marker.identifier,
                    let segment = targets[identifier]
                else {
                    continue
                }
                chips.append(
                    EnhancedCitationChip(
                        id: "\(index)-\(markerIndex)",
                        identifier: identifier,
                        label: label(for: identifier),
                        segmentID: segment.id,
                        startOffset: segment.startOffset
                    )
                )
            }

            return EnhancedNoteBlock(
                id: index,
                kind: line.kind,
                text: strippingMarkers(markers, from: lineText),
                citations: chips
            )
        }
    }

    /// Removes every marker from a line, resolved or not: an unresolved marker
    /// is a forgery, and leaving it in the text would draw it anyway.
    private static func strippingMarkers(
        _ markers: [MeetingNoteCitationMarker],
        from text: String
    ) -> String {
        let stripped = NSMutableString(string: text)
        for marker in markers.reversed() {
            stripped.replaceCharacters(in: marker.range, with: "")
        }
        return (stripped as String)
            .replacingOccurrences(of: #" {2,}"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }

    // MARK: Citation targets

    /// The span a citation quotes, or nil when the transcript on screen has none.
    ///
    /// The evidence and the transcript are derived from the same checkpoints by
    /// the same rule, so the span a citation names is normally there to the
    /// millisecond. Overlap is the fallback for a transcript that was re-read
    /// with different span boundaries; a citation from another revision resolves
    /// to nothing at all rather than to a stranger's words.
    static func target(
        for citation: MeetingNoteCitation,
        in segments: [TranscriptSegmentSnapshot]
    ) -> TranscriptSegmentSnapshot? {
        let candidates = segments.filter { $0.revisionID == citation.transcriptRevisionID }
        guard !candidates.isEmpty else { return nil }

        if let exact = candidates.first(where: {
            abs($0.startOffset - citation.startTime) <= 0.001
        }) {
            return exact
        }

        var best: TranscriptSegmentSnapshot?
        var bestOverlap: TimeInterval = 0
        for candidate in candidates {
            let overlap = min(candidate.endOffset, citation.endTime)
                - max(candidate.startOffset, citation.startTime)
            guard overlap > bestOverlap else { continue }
            bestOverlap = overlap
            best = candidate
        }
        return best
    }

    /// "C3" reads as "3". An identifier in any other shape reads as itself.
    static func label(for identifier: String) -> String {
        guard identifier.count > 1, identifier.hasPrefix("C") else { return identifier }
        let number = identifier.dropFirst()
        guard number.allSatisfy(\.isNumber) else { return identifier }
        return String(number)
    }

    private static func speakerName(
        for segment: TranscriptSegmentSnapshot,
        locale: Locale
    ) -> String? {
        guard segment.isCurrentUser || segment.speakerNumber != nil || segment.speakerLabel != nil
        else {
            return nil
        }
        return TranscriptSegmentPresentation.speakerName(
            isCurrentUser: segment.isCurrentUser,
            speakerNumber: segment.speakerNumber,
            speakerLabel: segment.speakerLabel,
            locale: locale
        )
    }

    // MARK: Template menu

    /// Whether the meta row offers the template menu at all. A read-only panel
    /// has no menu: there is nothing it can be regenerated into.
    static func showsTemplateMenu(
        panel: CaptureEnhancedPanelSnapshot?,
        selection: CaptureNoteViewKind
    ) -> Bool {
        guard selection == .enhanced, let panel else { return false }
        return panel.isRegenerable
    }

    /// The menu items, built-ins first and custom templates after, each group in
    /// its own stored order. Same split the preset sheet shows, so a person sees
    /// their templates in one order everywhere.
    static func templateMenuItems(
        presets: [TemplateMenuPreset],
        selected: String?
    ) -> [TemplateMenuItem] {
        let ordered = presets.filter(\.isBuiltIn).sorted { $0.sortOrder < $1.sortOrder }
            + presets.filter { !$0.isBuiltIn }.sorted { $0.sortOrder < $1.sortOrder }
        return ordered.map { preset in
            TemplateMenuItem(
                id: preset.identifier,
                name: preset.name,
                isBuiltIn: preset.isBuiltIn,
                isSelected: preset.identifier == selected
            )
        }
    }

    /// The merged dropdown the Enhanced chip opens.
    ///
    /// The template rows are the menu items in the same order the flat menu used,
    /// so a template sits in one place wherever it is picked. The two rows below
    /// them both end in the preset sheet: one on the list, one on a new template.
    static func menu(
        presets: [TemplateMenuPreset],
        selected: String?,
        locale: Locale
    ) -> EnhancedMenuContent {
        let templates = templateMenuItems(presets: presets, selected: selected).map { item in
            EnhancedMenuRow(
                id: item.id,
                title: item.name,
                systemImage: templateGlyph(identifier: item.id, isBuiltIn: item.isBuiltIn),
                isSelected: item.isSelected,
                action: .selectTemplate(item.id)
            )
        }
        return EnhancedMenuContent(
            headerTitle: localized("Enhanced notes", locale: locale),
            templatesTitle: localized("Templates", locale: locale),
            emptyTemplateMessage: selected == nil
                ? localized(
                    "No template. The note is written as plain notes.",
                    locale: locale
                )
                : nil,
            templates: templates,
            actions: [
                EnhancedMenuRow(
                    id: "all-templates",
                    title: localized("All templates…", locale: locale),
                    systemImage: "square.grid.2x2",
                    isSelected: false,
                    action: .manageTemplates
                ),
                EnhancedMenuRow(
                    id: "new-template",
                    title: localized("New template", locale: locale),
                    systemImage: "plus",
                    isSelected: false,
                    action: .newTemplate
                )
            ],
            regenerateHelp: localized("Write this note again", locale: locale)
        )
    }

    /// The glyph a template wears in its 13pt slot. Built-ins get a glyph that
    /// says what they write; anything a person made is a document.
    static func templateGlyph(identifier: String, isBuiltIn: Bool) -> String {
        guard isBuiltIn else { return "doc.text" }
        switch identifier {
        case "clean": return "text.alignleft"
        case "meeting": return "person.2"
        case "email": return "envelope"
        case "social": return "bubble.left.and.bubble.right"
        case "bullets": return "list.bullet"
        case "technical": return "chevron.left.forwardslash.chevron.right"
        default: return "sparkles"
        }
    }

    /// What picking `identifier` has to do.
    ///
    /// Switching back to a template that already has a panel is a read, never a
    /// generation: the panel is on disk and the person is owed it instantly.
    static func selection(
        of identifier: String,
        panels: [CaptureEnhancedPanelSnapshot],
        showing currentTemplateIdentifier: String?
    ) -> EnhancedTemplateSelection {
        if identifier == currentTemplateIdentifier {
            return .alreadyShowing
        }
        if let existing = panels.first(where: { $0.templatePresetIdentifier == identifier }) {
            return .showExisting(panelID: existing.id, templatePresetIdentifier: identifier)
        }
        return .generate(templatePresetIdentifier: identifier)
    }

    /// What the page says while it writes a panel with a template that has none.
    static func generatingMessage(templateName: String?, locale: Locale) -> String {
        guard let templateName, !templateName.isEmpty else {
            return localized("Writing your enhanced note.", locale: locale)
        }
        return String(
            format: localized("Writing your enhanced note with %@.", locale: locale),
            templateName
        )
    }
}
