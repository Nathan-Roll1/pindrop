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
//  and nothing else, which is why a citation chip here can only ever point at a
//  span the transcript is already showing.
//

import SwiftUI
import PindropCore
import PindropData

// MARK: - Body

/// The generated note: sections, bullets, and the citations that survived.
struct EnhancedNoteBody: View {
    let presentation: EnhancedNotePresentation
    /// Follows a citation to the transcript.
    var onFollowCitation: ((EnhancedCitationChip) -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(presentation.blocks) { block in
                blockView(block)
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
            Text(block.text)
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
            Text(block.text)
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
        Text(block.text)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Hangs the block's citation chips off the end of its last line.
    @ViewBuilder
    private func cited(
        _ block: EnhancedNoteBlock,
        @ViewBuilder content: () -> some View
    ) -> some View {
        if block.citations.isEmpty {
            content()
        } else {
            HStack(alignment: .lastTextBaseline, spacing: 4) {
                content()

                ForEach(block.citations) { citation in
                    EnhancedCitationChipView(
                        citation: citation,
                        action: { onFollowCitation?(citation) }
                    )
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: - Citation chip

/// One inline citation: the source number, and the way back to the words.
struct EnhancedCitationChipView: View {
    @Environment(\.locale) private var locale

    let citation: EnhancedCitationChip
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(citation.label)
                .font(FontLoader.font(family: .jetbrainsMono, size: 10, weight: .semibold))
                .foregroundStyle(AppColors.accent)
                .monospacedDigit()
                .environment(\.layoutDirection, .leftToRight)
                .padding(.horizontal, 4)
                .frame(minWidth: 16, minHeight: 16)
                .background(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(AppColors.accentBackground)
                )
                .offset(y: -2)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusRing(.rounded(.sm))
        .help(localized("See this in the transcript", locale: locale))
        .accessibilityIdentifier("note.page.enhanced.citation")
        .accessibilityLabel(
            String(
                format: localized("Transcript source %@", locale: locale),
                citation.label
            )
        )
    }
}

// MARK: - Sources

/// The collapsed list of everything the note was written from.
struct EnhancedSourcesDisclosure: View {
    @Environment(\.locale) private var locale

    let title: String
    let hint: String
    let sources: [EnhancedSourceRow]
    var onFollow: ((EnhancedSourceRow) -> Void)?

    @State private var isExpanded = false
    @Environment(\.layoutDirection) private var layoutDirection

    private var disclosureRotation: Double {
        layoutDirection == .rightToLeft ? -90 : 90
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                isExpanded.toggle()
            } label: {
                HStack(spacing: 6) {
                    // `.forward` mirrors with the locale; the open rotation has
                    // to turn the other way with it so the chevron still points
                    // down at the list it opened.
                    Image(systemName: "chevron.forward")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(AppColors.textTertiary)
                        .rotationEffect(.degrees(isExpanded ? disclosureRotation : 0))

                    Text(title)
                        .font(AppTypography.label)
                        .foregroundStyle(AppColors.textSecondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .focusRing(.rounded(.sm))
            .accessibilityIdentifier("note.page.enhanced.sources")

            if isExpanded {
                Text(hint)
                    .font(AppTypography.captionLarge)
                    .foregroundStyle(AppColors.textTertiary)

                VStack(alignment: .leading, spacing: 8) {
                    ForEach(sources) { source in
                        sourceRow(source)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .appAnimation(.fast, value: isExpanded)
    }

    private func sourceRow(_ source: EnhancedSourceRow) -> some View {
        Button {
            onFollow?(source)
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(source.label)
                    .font(FontLoader.font(family: .jetbrainsMono, size: 10, weight: .semibold))
                    .foregroundStyle(AppColors.accent)
                    .monospacedDigit()
                    .environment(\.layoutDirection, .leftToRight)
                    .padding(.horizontal, 4)
                    .frame(minWidth: 16, minHeight: 16)
                    .background(
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .fill(AppColors.accentBackground)
                    )

                Text(source.timestampText)
                    .font(AppTypography.monoSmall)
                    .foregroundStyle(AppColors.textTertiary)
                    .monospacedDigit()
                    .environment(\.layoutDirection, .leftToRight)

                if let speakerName = source.speakerName {
                    Text(speakerName)
                        .font(AppTypography.labelSemibold)
                        .foregroundStyle(AppColors.textSecondary)
                }

                Text(source.text)
                    .font(AppTypography.captionLarge)
                    .foregroundStyle(AppColors.textTertiary)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusRing(.rounded(.sm))
        .help(localized("See this in the transcript", locale: locale))
        .accessibilityIdentifier("note.page.enhanced.source")
    }
}

// MARK: - Template menu

/// The template this panel was written with, and the ones it could be.
struct TemplateMenuButton: View {
    @Environment(\.locale) private var locale

    /// The frozen label of the panel on screen.
    let templateName: String
    let items: [TemplateMenuItem]
    var isBusy = false
    var onSelect: (String) -> Void
    var onManage: () -> Void

    private var builtInItems: [TemplateMenuItem] {
        items.filter(\.isBuiltIn)
    }

    private var customItems: [TemplateMenuItem] {
        items.filter { !$0.isBuiltIn }
    }

    var body: some View {
        Menu {
            if !builtInItems.isEmpty {
                Section(localized("Templates", locale: locale)) {
                    ForEach(builtInItems) { item in
                        menuItem(item)
                    }
                }
            }

            if !customItems.isEmpty {
                Section(localized("Custom templates", locale: locale)) {
                    ForEach(customItems) { item in
                        menuItem(item)
                    }
                }
            }

            Divider()

            Button(localized("Manage templates…", locale: locale), action: onManage)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: isBusy ? "sparkles.rectangle.stack" : "sparkles")
                    .font(.system(size: 12))
                    .foregroundStyle(AppColors.accent)

                Text(templateName)
                    .font(AppTypography.labelSemibold)
                    .foregroundStyle(AppColors.textPrimary)
                    .lineLimit(1)

                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(AppColors.textTertiary)
            }
            .menuButtonChrome(verticalPadding: 5, horizontalPadding: 12)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityIdentifier("note.page.enhanced.template")
        .accessibilityLabel(
            String(format: localized("Template: %@", locale: locale), templateName)
        )
    }

    @ViewBuilder
    private func menuItem(_ item: TemplateMenuItem) -> some View {
        Button {
            onSelect(item.id)
        } label: {
            if item.isSelected {
                Label(item.name, systemImage: "checkmark")
            } else {
                Text(item.name)
            }
        }
    }
}

// MARK: - Feedback

/// Was the generated note any good? One quiet question, asked once.
struct EnhancedPanelFeedbackRow: View {
    @Environment(\.locale) private var locale

    let feedback: CaptureNotePanelFeedback?
    var onRate: (CaptureNotePanelFeedback?) -> Void

    var body: some View {
        HStack(spacing: 8) {
            Text(localized("Was this note useful?", locale: locale))
                .font(AppTypography.caption)
                .foregroundStyle(AppColors.textTertiary)

            rateButton(
                .helpful,
                systemImage: "hand.thumbsup",
                label: localized("Helpful", locale: locale)
            )
            rateButton(
                .notHelpful,
                systemImage: "hand.thumbsdown",
                label: localized("Not helpful", locale: locale)
            )
        }
    }

    private func rateButton(
        _ rating: CaptureNotePanelFeedback,
        systemImage: String,
        label: String
    ) -> some View {
        let isSelected = feedback == rating
        return Button {
            // Picking the same rating twice takes it back.
            onRate(isSelected ? nil : rating)
        } label: {
            Image(systemName: isSelected ? "\(systemImage).fill" : systemImage)
                .font(.system(size: 12))
                .foregroundStyle(isSelected ? AppColors.accent : AppColors.textTertiary)
                .frame(width: 20, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusRing(.rounded(.sm))
        .help(label)
        .accessibilityLabel(label)
        .accessibilityIdentifier("note.page.enhanced.feedback.\(rating.rawValue)")
    }
}

// MARK: - Preview

#Preview("Enhanced note") {
    let locale = Locale(identifier: "en")
    let presentation = EnhancedNotePresentation(
        blocks: EnhancedViewPresentation.blocks(
            in: """
            ## Decisions

            - Ship the migration behind the schema version.
            - Keep audio retention at seven days.

            ## Next steps

            - Andrea writes the release note.
            """,
            targets: [:]
        ),
        sources: [
            EnhancedSourceRow(
                id: "C1",
                label: "1",
                timestampText: "00:12",
                speakerName: "You",
                text: "\"We can stage it behind the schema version.\"",
                segmentID: "a",
                startOffset: 12
            )
        ],
        sourcesTitle: "Sources (1)",
        sourcesHint: "Click a number to see it in the transcript.",
        isReadOnly: false,
        readOnlyLabel: nil
    )

    return VStack(alignment: .leading, spacing: 16) {
        EnhancedNoteBody(presentation: presentation)
        EnhancedSourcesDisclosure(
            title: presentation.sourcesTitle ?? "",
            hint: presentation.sourcesHint,
            sources: presentation.sources
        )
    }
    .padding(40)
    .frame(width: 760)
    .background(AppColors.contentBackground)
    .environment(\.locale, locale)
    .themeRefresh()
}
