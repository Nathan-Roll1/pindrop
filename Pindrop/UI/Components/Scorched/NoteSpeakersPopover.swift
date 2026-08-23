//
//  NoteSpeakersPopover.swift
//  Pindrop
//
//  Created on 2026-08-22.
//
//  Who the recording heard (design spec, Round B "Speakers popover").
//
//  The chip used to be a menu that only set the expected speaker count. Round B
//  turns it into the list of people the transcript actually names, because that
//  is what a reader wants from it: which name belongs to which voice, and how to
//  change one that is wrong.
//
//  A name can only be changed where something owns it. Pindrop names a speaker
//  from a participant profile when diarization matched one; everything else is a
//  generic number that no rename could outlive. So the Rename action appears on
//  the rows a profile named, and says why it is missing on the rest.
//

import SwiftUI
import Foundation
import PindropCore

struct NoteSpeakersPopover: View {
    @Environment(\.locale) private var locale

    let content: NoteSpeakersPopoverContent
    /// The count the next capture is told to expect. Nil is "let Pindrop decide".
    @Binding var expectedSpeakerCount: Int?
    /// True while a capture owns the note: the expected count is fixed at start.
    var isExpectedCountLocked = false
    /// Renames the participant profile behind a row.
    var onRename: (UUID, String) -> Void

    /// The row being renamed, and the name being typed into it.
    @State private var renamingRowID: String?
    @State private var draftName = ""
    @State private var hoveredRowID: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            headerRow

            ForEach(content.rows) { row in
                speakerRow(row)
            }

            hairline

            Text(content.caption)
                .font(AppTypography.caption)
                .foregroundStyle(AppColors.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 10)
                .padding(.bottom, 6)

            expectedCountMenu
        }
        .padding(6)
        .frame(width: 280, alignment: .leading)
        .background(AppColors.contentBackground)
        .accessibilityIdentifier("note.page.speakers.popover")
    }

    private var headerRow: some View {
        HStack(spacing: 8) {
            Text(content.title)
                .font(AppTypography.overline)
                .foregroundStyle(AppColors.textTertiary)
                .textCase(.uppercase)

            Spacer(minLength: 12)

            Text(content.durationText)
                .font(AppTypography.monoSmall)
                .foregroundStyle(AppColors.textTertiary)
                .monospacedDigit()
                .environment(\.layoutDirection, .leftToRight)
        }
        .padding(.horizontal, 10)
        .padding(.top, 4)
        .padding(.bottom, 6)
    }

    @ViewBuilder
    private func speakerRow(_ row: NoteSpeakerRow) -> some View {
        HStack(spacing: 8) {
            Circle()
                .fill(dotColor(row))
                .frame(width: 8, height: 8)
                .accessibilityHidden(true)

            if renamingRowID == row.id {
                TextField(row.name, text: $draftName)
                    .font(AppTypography.labelStrong)
                    .textFieldStyle(.plain)
                    .foregroundStyle(AppColors.textPrimary)
                    .onSubmit { commitRename(row) }
                    .accessibilityIdentifier("note.page.speakers.renameField")

                Button(localized("Save", locale: locale)) { commitRename(row) }
                    .buttonStyle(.plain)
                    .font(AppTypography.labelSemibold)
                    .foregroundStyle(AppColors.accent)
                    .focusRing(.rounded(.sm))
            } else {
                Text(row.name)
                    .font(AppTypography.labelStrong)
                    .foregroundStyle(AppColors.textPrimary)
                    .lineLimit(1)

                Spacer(minLength: 8)

                renameAction(row)
            }
        }
        .padding(.vertical, 7)
        .padding(.horizontal, 10)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(hoveredRowID == row.id ? AppColors.windowBackground : Color.clear)
        )
        .contentShape(Rectangle())
        .onHover { isHovering in
            hoveredRowID = isHovering ? row.id : (hoveredRowID == row.id ? nil : hoveredRowID)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("note.page.speakers.row")
    }

    @ViewBuilder
    private func renameAction(_ row: NoteSpeakerRow) -> some View {
        if row.canRename {
            Button {
                draftName = row.name
                renamingRowID = row.id
            } label: {
                Text(localized("Rename", locale: locale))
                    .font(AppTypography.labelSemibold)
                    .foregroundStyle(AppColors.accent)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .focusRing(.rounded(.sm))
            .opacity(hoveredRowID == row.id ? 1 : 0)
            .accessibilityIdentifier("note.page.speakers.rename")
        } else if hoveredRowID == row.id {
            Image(systemName: "info.circle")
                .font(.system(size: 11))
                .foregroundStyle(AppColors.textTertiary)
                .help(NotePagePresentation.renameUnavailableHelpText(locale: locale))
        }
    }

    private var expectedCountMenu: some View {
        Menu {
            Button(localized("Auto", locale: locale)) { expectedSpeakerCount = nil }
            ForEach(2...8, id: \.self) { count in
                Button(NotePagePresentation.speakerCountLabel(count, locale: locale)) {
                    expectedSpeakerCount = count
                }
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "person.2")
                    .font(.system(size: 11))
                    .foregroundStyle(AppColors.textTertiary)
                Text(expectedCountTitle)
                    .font(AppTypography.label)
                    .foregroundStyle(AppColors.textSecondary)
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 10)
            .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .disabled(isExpectedCountLocked)
        .help(isExpectedCountLocked
              ? localized("Speakers are set when the recording starts.", locale: locale)
              : "")
        .accessibilityIdentifier("note.page.speakers.expectedCount")
    }

    private var expectedCountTitle: String {
        String(
            format: localized("Expect: %1$@", locale: locale),
            expectedSpeakerCount.map(String.init) ?? localized("Auto", locale: locale)
        )
    }

    private var hairline: some View {
        Rectangle()
            .fill(AppColors.border)
            .frame(height: 1)
            .padding(.vertical, 6)
    }

    private func dotColor(_ row: NoteSpeakerRow) -> Color {
        row.isCurrentUser ? AppColors.accent : LibrarySpeakerColor.color(for: row.id)
    }

    /// An empty or unchanged name is not a rename: the row keeps the name it had.
    private func commitRename(_ row: NoteSpeakerRow) {
        defer {
            renamingRowID = nil
            draftName = ""
        }
        guard let profileID = row.profileID else { return }
        let trimmed = draftName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != row.name else { return }
        onRename(profileID, trimmed)
    }
}

#Preview("Speakers popover") {
    NoteSpeakersPopover(
        content: NoteSpeakersPopoverContent(
            title: "Speakers",
            durationText: "42:18",
            rows: [
                NoteSpeakerRow(
                    id: "self",
                    name: "You",
                    isCurrentUser: true,
                    profileID: UUID()
                ),
                NoteSpeakerRow(
                    id: "s2",
                    name: "Speaker 2",
                    isCurrentUser: false,
                    profileID: nil
                )
            ],
            caption: "Detected from the recording. Renames apply to the transcript and future notes."
        ),
        expectedSpeakerCount: .constant(nil),
        onRename: { _, _ in }
    )
    .padding(24)
    .background(AppColors.windowBackground)
    .environment(\.locale, Locale(identifier: "en"))
    .themeRefresh()
}
