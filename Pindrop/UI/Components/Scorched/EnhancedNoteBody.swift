//
//  EnhancedNoteBody.swift
//  Pindrop
//
//  Created on 2026-08-22.
//
//  The Enhanced view of a note, drawn (WP6).
//
//  Everything with a right answer is decided in `EnhancedViewPresentation`:
//  which blocks exist, which citations survived resolution, what the sources
//  say, and what picking a template has to do. These views draw those answers
//  and nothing else, which is why a source peek here can only ever point at a
//  span the transcript is already showing.
//

import SwiftUI
import PindropCore
import PindropData

// MARK: - Body

/// The generated note: sections, bullets, and the sources behind them.
struct EnhancedNoteBody: View {
    @Environment(\.locale) private var locale

    let presentation: EnhancedNotePresentation
    /// Follows a source to the words it quotes.
    var onFollowSource: ((EnhancedSourceRow) -> Void)?

    /// The line whose peek is open. Only one at a time: the popover owns the
    /// reader's attention while it is up.
    @State private var peekedBlockID: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(presentation.blocks) { block in
                // The scroll target of a search hit is the block it landed in,
                // so stepping through matches lands on the line, not the panel.
                blockView(block)
                    .id(block.blockID)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func blockView(_ block: EnhancedNoteBlock) -> some View {
        switch block.kind {
        case .blank:
            Color.clear.frame(height: 10)

        case .heading:
            // A heading opens a section, so it takes the extra air above it.
            Text(highlighted(block))
                .font(FontLoader.font(family: .newsreader, size: 20, weight: .medium))
                .lineSpacing(6)
                .foregroundStyle(AppColors.textPrimary)
                .textSelection(.enabled)
                .padding(.top, 10)
                .padding(.bottom, 8)
                .frame(maxWidth: .infinity, alignment: .leading)

        case .bullet(let level), .task(let level, _):
            listRow(
                marker: level.isMultiple(of: 2) ? "◦" : "•",
                markerWidth: EnhancedViewPresentation.bulletSlotWidth,
                level: level,
                block: block
            )

        case .ordered(let level, let marker):
            listRow(marker: marker, markerWidth: 20, level: level, block: block)

        case .quote:
            bodyText(block)
                .font(FontLoader.font(family: .newsreader, size: 15, italic: true))
                .lineSpacing(7)
                .foregroundStyle(AppColors.textSecondary)
                .padding(.leading, 14)
                .padding(.bottom, 8)
                .overlay(alignment: .leading) {
                    Capsule().fill(AppColors.border).frame(width: 2)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

        case .code:
            Text(highlighted(block))
                .font(AppTypography.monoSmall)
                .foregroundStyle(AppColors.textSecondary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)

        case .paragraph:
            cited(block) {
                bodyText(block)
                    .font(AppTypography.body)
                    .lineSpacing(8)
                    .foregroundStyle(AppColors.textPrimary)
            }
            .padding(.bottom, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func listRow(
        marker: String,
        markerWidth: CGFloat,
        level: Int,
        block: EnhancedNoteBlock
    ) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            Text(marker)
                .font(AppTypography.body)
                .foregroundStyle(AppColors.textTertiary)
                .frame(width: markerWidth, alignment: .leading)

            cited(block) {
                bodyText(block)
                    .font(AppTypography.body)
                    .lineSpacing(8)
                    .foregroundStyle(AppColors.textPrimary)
            }
        }
        .padding(.leading, CGFloat(level - 1) * MarkdownBlockGrammar.listIndentStep)
        .padding(.bottom, 4)
    }

    private func bodyText(_ block: EnhancedNoteBlock) -> some View {
        Text(highlighted(block))
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// One block's text, with the searched words picked out.
    ///
    /// The runs are attributes of one string rather than separate views: a line
    /// has to wrap as a line, and a row of views would break it wherever a match
    /// happened to fall. A block with nothing matched is the plain string it has
    /// always been, so a panel nobody is searching is drawn exactly as before.
    private func highlighted(_ block: EnhancedNoteBlock) -> AttributedString {
        guard block.runs.contains(where: \.isMatch) else {
            return AttributedString(block.text)
        }
        return block.runs.reduce(into: AttributedString()) { string, run in
            string.append(styled(run))
        }
    }

    /// Matched words take the accent wash; the match the reader is standing on
    /// takes a stronger one and the primary ink. Same treatment the transcript
    /// gives a match, so one search reads the same in both views.
    ///
    /// Plain runs carry no color of their own: the block already decided its
    /// ink, and a heading is not a paragraph.
    private func styled(_ run: TranscriptTextRun) -> AttributedString {
        var string = AttributedString(run.text)
        guard run.isMatch else { return string }
        let isCurrent = run.matchIndex != nil && run.matchIndex == presentation.currentMatchIndex
        string.foregroundColor = isCurrent ? AppColors.textPrimary : AppColors.accent
        string.backgroundColor = isCurrent
            ? AppColors.accent.opacity(0.28)
            : AppColors.accentBackground
        return string
    }

    /// Wraps a line that has a resolved source in its peek affordance.
    ///
    /// A line that cites nothing is drawn exactly as it was: no wash, no
    /// magnifier, nothing to click. The affordance is the promise that there is
    /// something behind the words, so it only appears where there is.
    @ViewBuilder
    private func cited(
        _ block: EnhancedNoteBlock,
        @ViewBuilder content: () -> some View
    ) -> some View {
        if let source = EnhancedViewPresentation.peekTarget(
            for: block,
            in: presentation.sources
        ) {
            EnhancedSourcePeekRow(
                source: source,
                isPeeking: Binding(
                    get: { peekedBlockID == block.id },
                    set: { isPeeking in
                        if isPeeking {
                            peekedBlockID = block.id
                        } else if peekedBlockID == block.id {
                            peekedBlockID = nil
                        }
                    }
                ),
                onFollow: { onFollowSource?(source) },
                content: content
            )
        } else {
            content()
        }
    }
}

// MARK: - Source peek

/// One line of the panel that has words behind it.
///
/// Hover washes the line and shows the magnifier; the click opens the span the
/// line was written from, with the way into the transcript beside it.
struct EnhancedSourcePeekRow<Content: View>: View {
    @Environment(\.locale) private var locale

    let source: EnhancedSourceRow
    @Binding var isPeeking: Bool
    var onFollow: () -> Void
    @ViewBuilder let content: Content

    @State private var isHovering = false

    private var isWashed: Bool { isHovering || isPeeking }

    var body: some View {
        Button {
            isPeeking = true
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                content

                Image(systemName: "magnifyingglass")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(AppColors.textSecondary)
                    .opacity(isWashed ? 1 : 0)
                    .accessibilityHidden(true)
            }
            .padding(.vertical, 4)
            .padding(.horizontal, 8)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(isWashed ? AppColors.windowBackground : Color.clear)
            )
            .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(.plain)
        .focusRing(.rounded(.sm))
        .onHover { isHovering = $0 }
        .help(localized("See where this came from", locale: locale))
        .accessibilityIdentifier("note.page.enhanced.peek")
        .accessibilityHint(localized("See where this came from", locale: locale))
        .popover(isPresented: $isPeeking, arrowEdge: .bottom) {
            EnhancedSourcePeek(
                source: source,
                onFollow: {
                    isPeeking = false
                    onFollow()
                }
            )
        }
        // The wash is a hover state, not a transition the reader has to wait on.
        .appAnimation(.fast, value: isWashed)
    }
}

/// The quoted span behind one line, and the way to it.
struct EnhancedSourcePeek: View {
    @Environment(\.locale) private var locale

    let source: EnhancedSourceRow
    var onFollow: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text(EnhancedViewPresentation.peekTitle(locale: locale))
                    .font(AppTypography.overline)
                    .foregroundStyle(AppColors.textTertiary)
                    .textCase(.uppercase)

                Spacer(minLength: 12)

                Text(source.timestampText)
                    .font(AppTypography.monoSmall)
                    .foregroundStyle(AppColors.textTertiary)
                    .monospacedDigit()
                    .environment(\.layoutDirection, .leftToRight)
            }

            Text(source.text)
                .font(FontLoader.font(family: .newsreader, size: 15))
                .lineSpacing(7)
                .foregroundStyle(AppColors.textSecondary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 8) {
                if let speakerName = source.speakerName {
                    Circle()
                        .fill(speakerColor)
                        .frame(width: 8, height: 8)
                        .accessibilityHidden(true)

                    Text(speakerName)
                        .font(AppTypography.labelSemibold)
                        .foregroundStyle(AppColors.textPrimary)
                }

                Spacer(minLength: 12)

                Button(action: onFollow) {
                    Text(EnhancedViewPresentation.peekJumpTitle(locale: locale))
                        .font(AppTypography.labelSemibold)
                        .foregroundStyle(AppColors.accent)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .focusRing(.rounded(.sm))
                .accessibilityIdentifier("note.page.enhanced.peek.jump")
            }
        }
        .padding(.vertical, 14)
        .padding(.horizontal, 16)
        .frame(width: 520, alignment: .leading)
        .background(AppColors.contentBackground)
        .accessibilityIdentifier("note.page.enhanced.peek.popover")
    }

    private var speakerColor: Color {
        source.isCurrentUser
            ? AppColors.accent
            : LibrarySpeakerColor.color(for: source.speakerKey ?? "_")
    }
}

// MARK: - Enhanced dropdown

/// The merged dropdown the Enhanced chip opens: what this view is, which
/// template wrote it, and the two ways to reach the rest of them.
struct EnhancedMenuPanel: View {
    @Environment(\.locale) private var locale

    let content: EnhancedMenuContent
    var isBusy = false
    var onSelectTemplate: (String) -> Void
    var onRegenerate: () -> Void
    var onManageTemplates: () -> Void
    var onNewTemplate: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            hairline

            Text(content.templatesTitle)
                .font(AppTypography.overline)
                .foregroundStyle(AppColors.textTertiary)
                .textCase(.uppercase)
                .padding(.top, 8)
                .padding(.horizontal, 10)
                .padding(.bottom, 4)

            // No row is checked when no template wrote the panel, so the state
            // is said in words above the list rather than left as an absence.
            if let emptyTemplateMessage = content.emptyTemplateMessage {
                Text(emptyTemplateMessage)
                    .font(AppTypography.caption)
                    .foregroundStyle(AppColors.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 10)
                    .padding(.bottom, 6)
                    .accessibilityIdentifier("note.page.enhanced.menu.noTemplate")
            }

            ForEach(content.templates) { row in
                menuRow(row)
            }

            hairline

            ForEach(content.actions) { row in
                menuRow(row)
            }
        }
        .padding(6)
        .frame(width: 236, alignment: .leading)
        .background(AppColors.contentBackground)
        .accessibilityIdentifier("note.page.enhanced.menu")
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: isBusy ? "sparkles.rectangle.stack" : "sparkles")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(AppColors.accent)

            Text(content.headerTitle)
                .font(AppTypography.labelStrongSelected)
                .foregroundStyle(AppColors.textPrimary)

            Spacer(minLength: 8)

            Button(action: onRegenerate) {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(AppColors.textSecondary)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .focusRing(.rounded(.sm))
            .disabled(isBusy)
            .help(content.regenerateHelp)
            .accessibilityLabel(content.regenerateHelp)
            .accessibilityIdentifier("note.page.enhanced.menu.regenerate")

            Image(systemName: "checkmark")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(AppColors.accent)
                .accessibilityHidden(true)
        }
        .padding(.vertical, 7)
        .padding(.horizontal, 10)
    }

    private var hairline: some View {
        Rectangle()
            .fill(AppColors.border)
            .frame(height: 1)
            .padding(.vertical, 4)
    }

    private func menuRow(_ row: EnhancedMenuRow) -> some View {
        Button {
            switch row.action {
            case .selectTemplate(let identifier): onSelectTemplate(identifier)
            case .manageTemplates: onManageTemplates()
            case .newTemplate: onNewTemplate()
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: row.systemImage)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(
                        row.isSelected ? AppColors.accent : AppColors.textTertiary
                    )
                    .frame(width: 16, alignment: .center)

                Text(row.title)
                    .font(row.isSelected
                          ? AppTypography.labelStrongSelected
                          : AppTypography.labelStrong)
                    .foregroundStyle(
                        row.isSelected ? AppColors.textPrimary : AppColors.textSecondary
                    )
                    .lineLimit(1)

                Spacer(minLength: 8)

                if row.isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(AppColors.accent)
                        .accessibilityHidden(true)
                }
            }
            .padding(.vertical, 7)
            .padding(.horizontal, 10)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(row.isSelected ? AppColors.accentBackground : Color.clear)
            )
            .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(.plain)
        .focusRing(.rounded(.sm))
        .accessibilityAddTraits(row.isSelected ? .isSelected : [])
        .accessibilityIdentifier("note.page.enhanced.menu.row")
    }
}

// MARK: - Preview

#Preview("Enhanced note") {
    let locale = Locale(identifier: "en")
    let source = EnhancedSourceRow(
        id: "C1",
        label: "1",
        timestampText: "00:12",
        speakerName: "You",
        speakerKey: "self",
        isCurrentUser: true,
        text: "\"We can stage it behind the schema version.\"",
        segmentID: "a",
        startOffset: 12
    )
    let presentation = EnhancedNotePresentation(
        blocks: EnhancedViewPresentation.blocks(
            in: """
            ## Decisions

            - Ship the migration behind the schema version. [C1]
            - Keep audio retention at seven days.

            ## Next steps

            - Andrea writes the release note.
            """,
            targets: [
                "C1": TranscriptSegmentSnapshot(
                    id: "a",
                    revisionID: UUID(),
                    speakerKey: "self",
                    speakerLabel: "You",
                    isCurrentUser: true,
                    text: "We can stage it behind the schema version.",
                    startOffset: 12,
                    duration: 4
                )
            ]
        ),
        sources: [source],
        isReadOnly: false,
        readOnlyLabel: nil
    )

    return VStack(alignment: .leading, spacing: 16) {
        EnhancedNoteBody(presentation: presentation)
        EnhancedSourcePeek(source: source, onFollow: {})
    }
    .padding(40)
    .frame(width: 760)
    .background(AppColors.contentBackground)
    .environment(\.locale, locale)
    .themeRefresh()
}

#Preview("Enhanced dropdown") {
    EnhancedMenuPanel(
        content: EnhancedViewPresentation.menu(
            presets: [
                TemplateMenuPreset(
                    identifier: "meeting", name: "Meeting Notes", isBuiltIn: true, sortOrder: 0
                ),
                TemplateMenuPreset(
                    identifier: "bullets", name: "Bullet Summary", isBuiltIn: true, sortOrder: 1
                ),
                TemplateMenuPreset(
                    identifier: "mine", name: "Client recap", isBuiltIn: false, sortOrder: 0
                )
            ],
            selected: "meeting",
            locale: Locale(identifier: "en")
        ),
        onSelectTemplate: { _ in },
        onRegenerate: {},
        onManageTemplates: {},
        onNewTemplate: {}
    )
    .padding(24)
    .background(AppColors.windowBackground)
    .environment(\.locale, Locale(identifier: "en"))
    .themeRefresh()
}
