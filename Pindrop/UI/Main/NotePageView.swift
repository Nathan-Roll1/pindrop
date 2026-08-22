//
//  NotePageView.swift
//  Pindrop
//
//  Created on 2026-08-22.
//
//  Note page destination inside the main window (WP1 stub). WP3 replaces the
//  body with the real note surface: title, editor, capture dock, view toggle.
//  This version only proves the route: it resolves the note and shows its title.
//

import SwiftUI
import SwiftData
import PindropData

struct NotePageView: View {
    @Environment(\.locale) private var locale
    @Query private var notes: [NoteSchema.Note]

    let noteID: UUID
    let onBack: () -> Void

    init(noteID: UUID, onBack: @escaping () -> Void) {
        self.noteID = noteID
        self.onBack = onBack
        _notes = Query(
            filter: #Predicate<NoteSchema.Note> { $0.id == noteID },
            sort: \NoteSchema.Note.updatedAt
        )
    }

    private var note: NoteSchema.Note? { notes.first }

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            backChip

            Text(note?.title ?? localized("Note", locale: locale))
                .font(AppTypography.pageTitle)
                .foregroundStyle(AppColors.textPrimary)
                .accessibilityIdentifier("note.page.title")

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 40)
        .padding(.top, 40)
        .padding(.bottom, 32)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(AppColors.contentBackground)
        .accessibilityIdentifier("note.page")
    }

    private var backChip: some View {
        Button(action: onBack) {
            HStack(spacing: 4) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 11, weight: .medium))
                Text(localized("Notes", locale: locale))
                    .font(AppTypography.labelStrong)
            }
            .foregroundStyle(AppColors.textSecondary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("note.page.back")
        .accessibilityLabel(localized("Back to notes", locale: locale))
    }
}
