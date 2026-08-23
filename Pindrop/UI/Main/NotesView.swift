//
//  NotesView.swift
//  Pindrop
//
//  Created on 2026-01-29.
//
//  The one Notes page (WP2). Replaces the Voice Note pillar, the Meeting
//  pillar, and the old workspace Notes page: humanized header, split
//  "New note" button, pinned section, date groups, capture-aware rows.
//

import SwiftUI
import SwiftData
import Foundation
import AppKit
import PindropCore
import PindropData

struct NotesView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.locale) private var locale

    /// Opens a note in the main window. `nil` in previews and fixtures.
    let onOpenNote: ((UUID) -> Void)?
    /// Starts a capture bound to a note. Returns `false` when the coordinator
    /// refused (another capture is running). `nil` in previews and fixtures.
    let onStartNoteCapture: ((NoteCaptureRequest) -> Bool)?
    /// The capture attached to a note right now, if any. See `NoteCaptureLiveRow`.
    let liveCapture: NoteCaptureLiveRow?

    init(
        onOpenNote: ((UUID) -> Void)? = nil,
        onStartNoteCapture: ((NoteCaptureRequest) -> Bool)? = nil,
        liveCapture: NoteCaptureLiveRow? = nil
    ) {
        self.onOpenNote = onOpenNote
        self.onStartNoteCapture = onStartNoteCapture
        self.liveCapture = liveCapture
    }

    @Query(sort: \NoteSchema.Note.updatedAt, order: .reverse) private var allNotes: [NoteSchema.Note]

    /// Applied search query driving the derived list snapshot.
    /// Empty clears immediately; non-empty queries debounce before applying.
    @State private var appliedSearchQuery = ""
    /// Draft empty/nonempty intent for empty-state wording only. Updates on
    /// whitespace-empty transitions so presentation is immediate while the
    /// expensive filter query remains debounced.
    @State private var hasDraftSearchIntent = false
    @State private var snapshotCache = NotesListSnapshotCache()
    /// Capture linkage per note (kind glyph, Enhanced badge, duration lane).
    /// Refreshed off the body via `task(id:)` so the list never fetches inline.
    @State private var rowFacts: [UUID: NoteRowCaptureFacts] = [:]
    /// Focus stays on the list owner so keyboard selection can exclude the field;
    /// draft text/debounce live in `NotesSearchChrome`.
    @FocusState private var isSearchFieldFocused: Bool
    @State private var selectedNoteID: PersistentIdentifier?
    @State private var pendingDeletionNote: NoteSchema.Note?
    @State private var errorMessage: String?

    private var notesStore: NotesStore {
        NotesStore(
            modelContext: modelContext,
            metadataGenerator: { _, _ in nil }
        )
    }

    /// Single derived snapshot for body + keyboard selection (one derivation per input change).
    private func listSnapshot() -> NotesListSnapshot {
        snapshotCache.snapshot(notes: allNotes, query: appliedSearchQuery)
    }

    var body: some View {
        // Exactly one snapshot/fingerprint evaluation per owner body.
        let snapshot = listSnapshot()
        VStack(spacing: 0) {
            headerSection(snapshot: snapshot)
                .padding(.horizontal, 40)
                .padding(.top, 40)
                // Paper board 50: 24 between the header and the list.
                .padding(.bottom, 24)
                .background(AppColors.contentBackground)

            contentArea(snapshot: snapshot)
                .background(AppColors.contentBackground)
        }
        .background(AppColors.contentBackground)
        .confirmationDialog(
            localized("Delete note?", locale: locale),
            isPresented: Binding(
                get: { pendingDeletionNote != nil },
                set: { isPresented in
                    if !isPresented { pendingDeletionNote = nil }
                }
            ),
            titleVisibility: .visible
        ) {
            Button(localized("Delete", locale: locale), role: .destructive) {
                if let note = pendingDeletionNote {
                    deleteNote(note)
                }
                pendingDeletionNote = nil
            }
            Button(localized("Cancel", locale: locale), role: .cancel) {
                pendingDeletionNote = nil
            }
        } message: {
            Text(localized("This will permanently remove this note.", locale: locale))
        }
        .onChange(of: NoteRowFactsKey(notes: allNotes), initial: true) { _, _ in
            rowFacts = NoteRowFactsProvider(modelContext: modelContext).facts(for: allNotes)
        }
        .listKeyboardSelection(isSearchFieldFocused: isSearchFieldFocused) { command in
            handleListCommand(command)
        }
        .background {
            // ⌘N new note (hidden button for keyboard shortcut)
            Button { startNewNote(.recordMicrophone) } label: { EmptyView() }
                .keyboardShortcut("n", modifiers: .command)
                .opacity(0)
                .frame(width: 0, height: 0)
                .allowsHitTesting(false)
        }
    }

    // MARK: - Header

    private func headerSection(snapshot: NotesListSnapshot) -> some View {
        HStack(alignment: .center, spacing: 16) {
            HStack(alignment: .lastTextBaseline, spacing: 10) {
                Text(localized("Notes", locale: locale))
                    .font(AppTypography.pageTitle)
                    .tracking(AppTypography.pageTitleTracking)
                    .foregroundStyle(AppColors.textPrimary)

                Text(NotesHeaderMeta.humanizedText(
                    noteCount: snapshot.filteredCount,
                    todayCount: snapshot.todayCount,
                    locale: locale
                ))
                .font(AppTypography.pageMeta)
                .foregroundStyle(AppColors.textTertiary)
                .accessibilityIdentifier("notes.list.meta")
            }

            Spacer(minLength: 12)

            HStack(spacing: 10) {
                NotesSearchChrome(
                    placeholder: localized("Search notes...", locale: locale),
                    isFocused: $isSearchFieldFocused,
                    onAppliedQueryChange: { query in
                        appliedSearchQuery = query
                    },
                    onDraftSearchIntentChange: { hasIntent in
                        hasDraftSearchIntent = hasIntent
                    }
                )
                .frame(width: 200)
                .accessibilityIdentifier("notes.list.search")

                NewNoteSplitButton(onSelect: startNewNote)
            }
        }
    }

    // MARK: - Content

    @ViewBuilder
    private func contentArea(snapshot: NotesListSnapshot) -> some View {
        if let errorMessage {
            errorView(errorMessage)
        } else if snapshot.filteredCount == 0 {
            emptyStateView(isSearching: hasDraftSearchIntent)
        } else {
            notesList(snapshot: snapshot)
        }
    }

    private func errorView(_ message: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(AppColors.textTertiary)

            Text(localized("Something went wrong", locale: locale))
                .font(AppTypography.labelStrong)
                .foregroundStyle(AppColors.textPrimary)

            Text(message)
                .font(AppTypography.body)
                .foregroundStyle(AppColors.textSecondary)
                .multilineTextAlignment(.center)

            SecondaryButton(title: localized("Dismiss", locale: locale)) {
                self.errorMessage = nil
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func emptyStateView(isSearching: Bool) -> some View {
        if isSearching {
            VStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 20, weight: .regular))
                    .foregroundStyle(AppColors.textTertiary)

                Text(localized("No results found", locale: locale))
                    .font(AppTypography.labelStrongSelected)
                    .foregroundStyle(AppColors.textPrimary)

                Text(localized("Try a different search term", locale: locale))
                    .font(AppTypography.body)
                    .foregroundStyle(AppColors.textSecondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            VStack(spacing: 10) {
                ZStack {
                    Circle()
                        .fill(AppColors.accentBackground)
                        .frame(width: 40, height: 40)
                    Image(systemName: "mic")
                        .font(.system(size: 16, weight: .regular))
                        .foregroundStyle(AppColors.accent)
                }
                .padding(.bottom, 2)
                .accessibilityHidden(true)

                Text(localized("No notes yet.", locale: locale))
                    .font(AppTypography.labelStrongSelected)
                    .foregroundStyle(AppColors.textPrimary)

                Text(localized(
                    "Click New note to start one. Pindrop records while you type.",
                    locale: locale
                ))
                .font(AppTypography.body)
                .foregroundStyle(AppColors.textSecondary)
                .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityIdentifier("notes.list.empty")
        }
    }

    private func notesList(snapshot: NotesListSnapshot) -> some View {
        ScrollView(.vertical, showsIndicators: true) {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(Array(snapshot.sections.enumerated()), id: \.element.key) { index, group in
                    SectionHeader(
                        title: localizedSectionTitle(group.key),
                        trailing: "\(group.notes.count)",
                        isFirst: index == 0
                    )
                    .padding(.horizontal, 20)

                    if group.key == .pinned {
                        ForEach(group.notes) { note in
                            pinnedCard(note)
                                .padding(.horizontal, 20)
                                .padding(.bottom, 8)
                        }
                    } else {
                        ForEach(group.notes) { note in
                            noteRow(note)
                        }
                    }
                }

                Color.clear.frame(height: 32)
            }
            .padding(.bottom, 24)
        }
        .accessibilityIdentifier("notes.list")
    }

    // MARK: - Pinned card (spec §10)

    private func pinnedCard(_ note: NoteSchema.Note) -> some View {
        let isSelected = selectedNoteID == note.persistentModelID
        let title = NotesListPresentation.displayTitle(
            title: note.title,
            content: note.content,
            emptyTitle: localized("Untitled Note", locale: locale)
        )
        let preview = NotesListPresentation.previewLine(content: note.content)
        let edited = NotesDateFormatting.editedLabel(
            date: note.updatedAt,
            locale: locale
        )

        return Button {
            selectedNoteID = note.persistentModelID
            openNote(note)
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 10) {
                    Text(title)
                        .font(AppTypography.pinnedCardTitle)
                        .lineSpacing(AppTypography.pinnedCardTitleLineSpacing)
                        .foregroundStyle(AppColors.textPrimary)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    Image(systemName: "pin.fill")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(AppColors.accent)

                    Text(edited)
                        .font(AppTypography.label)
                        .foregroundStyle(AppColors.textTertiary)
                        .lineLimit(1)
                }

                if !preview.isEmpty {
                    Text(preview)
                        .font(AppTypography.body)
                        .lineSpacing(4) // ~13/20
                        .foregroundStyle(AppColors.textSecondary)
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(.vertical, 16)
            .padding(.horizontal, 20)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(AppColors.windowBackground)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(
                        isSelected ? AppColors.accent.opacity(0.5) : AppColors.border,
                        lineWidth: 1
                    )
            )
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityIdentifier("notes.list.pinned")
        .accessibilityLabel(NoteRowPresentation.accessibilityLabel(
            title: title,
            facts: rowFacts[note.id] ?? .none,
            isPinned: true,
            dateText: edited,
            locale: locale
        ))
        .accessibilityAddTraits(.isButton)
        .contextMenu { noteContextMenu(note) }
    }

    // MARK: - Note row (design spec, "Notes list page")

    private func noteRow(_ note: NoteSchema.Note) -> some View {
        let isSelected = selectedNoteID == note.persistentModelID
        let live = liveCapture?.noteID == note.id ? liveCapture : nil
        let facts = rowFacts[note.id] ?? .none
        let title = NotesListPresentation.displayTitle(
            title: note.title,
            content: note.content,
            emptyTitle: localized("Untitled Note", locale: locale)
        )
        let preview = NotesListPresentation.previewLine(content: note.content)
        let dateText = NotesDateFormatting.rowDate(
            date: note.updatedAt,
            locale: locale
        )
        let duration = NoteRowPresentation.durationText(facts.duration)

        return Button {
            selectedNoteID = note.persistentModelID
            openNote(note)
        } label: {
            HStack(spacing: 10) {
                if live != nil {
                    Circle()
                        .fill(AppColors.recording)
                        .frame(width: 8, height: 8)
                        .frame(width: AppIcon.rowSlot, height: AppIcon.rowSlot)
                } else {
                    IconSlot(
                        systemImage: NoteRowPresentation.kind(facts: facts).systemImage,
                        slot: .row,
                        tint: AppColors.textTertiary
                    )
                }

                Text(title)
                    .font(AppTypography.labelStrong)
                    .foregroundStyle(AppColors.textPrimary)
                    .lineLimit(1)
                    .frame(width: 220, alignment: .leading)

                Text(preview)
                    .font(AppTypography.body)
                    .foregroundStyle(AppColors.textSecondary)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)

                if let live {
                    // The clock ticks inside the row, so a running recording
                    // never re-renders the rest of the list once a second.
                    TimelineView(.periodic(from: live.startedAt ?? .now, by: 1)) { context in
                        Text(NoteRowPresentation.liveLabel(
                            elapsed: live.elapsed(now: context.date),
                            locale: locale
                        ))
                        .font(AppTypography.monoSmall)
                        .foregroundStyle(AppColors.recording)
                        .monospacedDigit()
                        .lineLimit(1)
                        .environment(\.layoutDirection, .leftToRight)
                    }
                    .frame(width: 118, alignment: .trailing)
                } else {
                    Group {
                        if NoteRowPresentation.showsEnhancedBadge(facts: facts) {
                            enhancedBadge
                        }
                    }
                    .frame(width: 74, alignment: .trailing)

                    Text(duration)
                        .font(AppTypography.monoSmall)
                        .foregroundStyle(AppColors.textTertiary)
                        .monospacedDigit()
                        .lineLimit(1)
                        .frame(width: 44, alignment: .trailing)
                        .environment(\.layoutDirection, .leftToRight)

                    Text(dateText)
                        .font(AppTypography.label)
                        .foregroundStyle(AppColors.textTertiary)
                        .lineLimit(1)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 64, alignment: .trailing)
                }
            }
            .padding(.vertical, 13)
            // Divider inside the horizontal padding: constrained to the content
            // column; the selected wash below stays full-bleed. A live row wears
            // the recording wash instead of a hairline.
            .overlay(alignment: .bottom) {
                if live == nil {
                    Rectangle()
                        .fill(AppColors.border)
                        .frame(height: 1)
                }
            }
            .padding(.horizontal, 20)
            .background {
                if live != nil {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(AppColors.errorBackground)
                        .padding(.horizontal, 12)
                } else if isSelected {
                    AppColors.accent.opacity(0.06)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // One element, one sentence: read as lanes, the row would speak a title,
        // a preview, and then three unlabelled numbers.
        .accessibilityElement(children: .ignore)
        .accessibilityIdentifier("notes.list.row")
        .accessibilityLabel(NoteRowPresentation.accessibilityLabel(
            title: title,
            facts: facts,
            liveElapsed: live?.elapsed,
            dateText: dateText,
            locale: locale
        ))
        .accessibilityAddTraits(.isButton)
        .contextMenu { noteContextMenu(note) }
    }

    private var enhancedBadge: some View {
        Text(localized("Enhanced", locale: locale))
            .font(AppTypography.badge)
            .foregroundStyle(AppColors.accent)
            .padding(.vertical, 2)
            .padding(.horizontal, 8)
            .background(Capsule(style: .continuous).fill(AppColors.accentBackground))
    }

    @ViewBuilder
    private func noteContextMenu(_ note: NoteSchema.Note) -> some View {
        Button {
            openNote(note)
        } label: {
            Label(localized("Open Note", locale: locale), systemImage: "square.and.pencil")
        }

        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(note.content, forType: .string)
        } label: {
            Label(localized("Copy Content", locale: locale), systemImage: "doc.on.doc")
        }

        Button {
            togglePin(note)
        } label: {
            Label(
                note.isPinned ? localized("Unpin", locale: locale) : localized("Pin", locale: locale),
                systemImage: note.isPinned ? "pin.slash" : "pin"
            )
        }

        Divider()

        Button(role: .destructive) {
            pendingDeletionNote = note
        } label: {
            Label(localized("Delete Note", locale: locale), systemImage: "trash")
        }
    }

    private func localizedSectionTitle(_ key: NotesGrouping.SectionKey) -> String {
        localized(key.localizationKey, locale: locale)
    }

    // MARK: - Actions

    /// A new note is created durably first, then capture starts against that
    /// identity, then the note opens. Order matters: the note page always has an
    /// identity to bind capture and panels to.
    private func startNewNote(_ action: NewNoteAction) {
        let store = notesStore
        Task { @MainActor in
            do {
                let note = try await store.create(content: "")
                if let request = action.captureRequest(noteID: note.id) {
                    _ = onStartNoteCapture?(request)
                }
                onOpenNote?(note.id)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func openNote(_ note: NoteSchema.Note) {
        selectedNoteID = note.persistentModelID
        onOpenNote?(note.id)
    }

    private func togglePin(_ note: NoteSchema.Note) {
        do {
            try notesStore.togglePin(note)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func deleteNote(_ note: NoteSchema.Note) {
        do {
            try notesStore.delete(note)
            if selectedNoteID == note.persistentModelID {
                selectedNoteID = nil
            }
        } catch {
            errorMessage = localized("Failed to delete note: %@", locale: locale)
                .replacingOccurrences(of: "%@", with: error.localizedDescription)
        }
    }

    // MARK: - Keyboard Selection

    private func handleListCommand(_ command: ListKeyboardCommand) -> Bool {
        let selectable = listSnapshot().flatSelectableNotes
        switch command {
        case .moveUp:
            moveListSelection(delta: -1, notes: selectable)
            return true
        case .moveDown:
            moveListSelection(delta: 1, notes: selectable)
            return true
        case .delete:
            requestDeleteForSelection(notes: selectable)
            return true
        case .clearSelection:
            return clearSelection()
        case .activate:
            guard let note = selectable.first(where: { $0.persistentModelID == selectedNoteID }) else {
                return false
            }
            openNote(note)
            return true
        }
    }

    private func moveListSelection(delta: Int, notes: [NoteSchema.Note]) {
        let currentIndex = notes.firstIndex(where: { $0.persistentModelID == selectedNoteID })
        guard let nextIndex = ListSelectionNavigation.moveIndex(
            current: currentIndex,
            count: notes.count,
            delta: delta
        ) else { return }
        selectedNoteID = notes[nextIndex].persistentModelID
    }

    private func requestDeleteForSelection(notes: [NoteSchema.Note]) {
        if let note = notes.first(where: { $0.persistentModelID == selectedNoteID }) {
            pendingDeletionNote = note
        }
    }

    @discardableResult
    private func clearSelection() -> Bool {
        guard selectedNoteID != nil else { return false }
        selectedNoteID = nil
        return true
    }
}

// MARK: - Split "New note" button

/// Accent-filled split button: the primary segment starts a microphone note
/// (⌘N), the menu segment offers the system-audio and no-recording variants.
/// One face shared with the Dictate CTA via `CapturePrimaryButton`.
private struct NewNoteSplitButton: View {
    @Environment(\.locale) private var locale
    let onSelect: (NewNoteAction) -> Void

    var body: some View {
        CapturePrimaryButton(
            glyph: .plus,
            title: NewNoteAction.recordMicrophone.title(locale: locale),
            keyboardHint: "⌘N",
            accessibilityIdentifier: "notes.list.newNote",
            action: { onSelect(.recordMicrophone) },
            menuAccessibilityLabel: localized("More new note options", locale: locale),
            menuAccessibilityIdentifier: "notes.list.newNoteOptions"
        ) {
            Button(NewNoteAction.recordWithSystemAudio.title(locale: locale)) {
                onSelect(.recordWithSystemAudio)
            }
            Button(NewNoteAction.withoutRecording.title(locale: locale)) {
                onSelect(.withoutRecording)
            }
        }
    }
}

// MARK: - Row capture facts

/// Identity of the note set for the capture-linkage fetch. Content edits that do
/// not change `updatedAt` cannot change a row's lanes, so the key stays small.
private struct NoteRowFactsKey: Equatable {
    struct Entry: Equatable {
        let noteID: UUID
        let transcriptionID: UUID?
        let updatedAt: Date
    }

    let entries: [Entry]

    @MainActor
    init(notes: [NoteSchema.Note]) {
        entries = notes.map {
            Entry(noteID: $0.id, transcriptionID: $0.sourceTranscriptionID, updatedAt: $0.updatedAt)
        }
    }
}

/// Resolves the row lanes that live outside `Note`: kind glyph, Enhanced badge,
/// duration. WP6 refines `hasEnhancedArtifact` into per-template panel state;
/// this provider is the seam that keeps the list from knowing about panels.
@MainActor
struct NoteRowFactsProvider {
    let modelContext: ModelContext

    func facts(for notes: [NoteSchema.Note]) -> [UUID: NoteRowCaptureFacts] {
        guard !notes.isEmpty else { return [:] }

        let records = linkedRecords(for: notes)
        let enhancedNoteIDs = enhancedNoteIDs()
        let (linkedNoteIDs, generatedNoteIDs) = noteReferenceIDs()

        var result: [UUID: NoteRowCaptureFacts] = [:]
        result.reserveCapacity(notes.count)
        for note in notes {
            let record = note.sourceTranscriptionID.flatMap { records[$0] }
            let hasLink = record != nil || linkedNoteIDs.contains(note.id)
            result[note.id] = NoteRowCaptureFacts(
                hasCaptureLink: hasLink,
                isMeetingCapture: record?.kind == .manualCapture,
                hasEnhancedArtifact: enhancedNoteIDs.contains(note.id)
                    || generatedNoteIDs.contains(note.id),
                duration: record?.duration
            )
        }
        return result
    }

    private struct LinkedRecord {
        let duration: TimeInterval
        let kind: MediaSourceKind
    }

    private func linkedRecords(for notes: [NoteSchema.Note]) -> [UUID: LinkedRecord] {
        let ids = Array(Set(notes.compactMap(\.sourceTranscriptionID)))
        guard !ids.isEmpty else { return [:] }
        let descriptor = FetchDescriptor<TranscriptionRecord>(
            predicate: #Predicate { ids.contains($0.id) }
        )
        do {
            let records = try modelContext.fetch(descriptor)
            return Dictionary(
                uniqueKeysWithValues: records.map {
                    ($0.id, LinkedRecord(duration: $0.duration, kind: $0.resolvedSourceKind))
                }
            )
        } catch {
            Log.ui.error("Failed to resolve note capture links: \(error.localizedDescription)")
            return [:]
        }
    }

    /// Notes with a live (not superseded) enhanced panel.
    private func enhancedNoteIDs() -> Set<UUID> {
        do {
            let panels = try modelContext.fetch(FetchDescriptor<CaptureEnhancedPanelModel>())
            return Set(panels.lazy.filter { $0.supersededAt == nil }.map(\.noteID))
        } catch {
            Log.ui.error("Failed to fetch enhanced panels: \(error.localizedDescription)")
            return []
        }
    }

    /// Every note a capture references, plus the legacy generated notes that
    /// stand in for an enhanced artifact until WP6 migrates them onto panels.
    private func noteReferenceIDs() -> (linked: Set<UUID>, generated: Set<UUID>) {
        do {
            let references = try modelContext.fetch(FetchDescriptor<CaptureNoteReferenceModel>())
            var linked: Set<UUID> = []
            var generated: Set<UUID> = []
            for reference in references {
                linked.insert(reference.noteID)
                if reference.roleRawValue == CaptureNoteRole.generated.rawValue {
                    generated.insert(reference.noteID)
                }
            }
            return (linked, generated)
        } catch {
            Log.ui.error("Failed to fetch capture note references: \(error.localizedDescription)")
            return ([], [])
        }
    }
}

// MARK: - Search draft intent

/// Pure helpers for notes search draft intent (empty-state wording).
/// Filtering still uses the debounced applied query; only the empty/nonempty
/// boundary is published upward for immediate empty-state presentation.
enum NotesSearchPresentation {
    /// True when the draft has any non-whitespace content.
    static func hasDraftSearchIntent(_ draft: String) -> Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Returns the new intent only when the empty/nonempty boundary is crossed;
    /// `nil` means the owner should not be notified (no keystroke fan-out).
    static func draftSearchIntentTransition(
        previousHasIntent: Bool,
        draft: String
    ) -> Bool? {
        let next = hasDraftSearchIntent(draft)
        return next == previousHasIntent ? nil : next
    }
}

// MARK: - Search chrome (draft state isolated)

/// Owns draft search text and the 250 ms debounce so keystrokes do not
/// invalidate the list-owning `NotesView` body. Empty clears apply immediately;
/// non-empty queries settle after 250 ms. Draft empty/nonempty intent is
/// published immediately (boolean only) for empty-state presentation.
private struct NotesSearchChrome: View {
    let placeholder: String
    var isFocused: FocusState<Bool>.Binding
    let onAppliedQueryChange: (String) -> Void
    let onDraftSearchIntentChange: (Bool) -> Void

    @State private var searchText = ""
    @State private var searchDebounceTask: Task<Void, Never>?
    @State private var lastPublishedDraftIntent = false

    var body: some View {
        SearchFieldChrome(
            text: $searchText,
            placeholder: placeholder,
            showsKeyboardHint: true,
            isFocused: isFocused
        )
        .onChange(of: searchText) { _, _ in
            handleSearchTextChange()
        }
        .onDisappear {
            searchDebounceTask?.cancel()
            searchDebounceTask = nil
        }
    }

    private var trimmedSearchText: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func handleSearchTextChange() {
        let query = trimmedSearchText
        publishDraftSearchIntentIfNeeded(for: searchText)
        if query.isEmpty {
            // Empty query must clear results immediately (no debounce lag).
            applySearchQueryImmediately("")
            return
        }
        searchDebounceTask?.cancel()
        searchDebounceTask = Task { @MainActor in
            do {
                try await Task.sleep(for: .milliseconds(250))
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            // Re-read current field so a superseded keystroke is ignored.
            let latest = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
            onAppliedQueryChange(latest)
        }
    }

    private func applySearchQueryImmediately(_ query: String) {
        searchDebounceTask?.cancel()
        searchDebounceTask = nil
        onAppliedQueryChange(query)
    }

    private func publishDraftSearchIntentIfNeeded(for draft: String) {
        guard let next = NotesSearchPresentation.draftSearchIntentTransition(
            previousHasIntent: lastPublishedDraftIntent,
            draft: draft
        ) else {
            return
        }
        lastPublishedDraftIntent = next
        onDraftSearchIntentChange(next)
    }
}

// MARK: - Derived list snapshot

/// One-shot derived Notes list: filtered count, grouped sections, flat selection order.
private struct NotesListSnapshot {
    struct Section {
        let key: NotesGrouping.SectionKey
        let notes: [NoteSchema.Note]
    }

    let filteredCount: Int
    /// Notes edited today, for the humanized header meta.
    let todayCount: Int
    let sections: [Section]
    let flatSelectableNotes: [NoteSchema.Note]

    static let empty = NotesListSnapshot(
        filteredCount: 0,
        todayCount: 0,
        sections: [],
        flatSelectableNotes: []
    )
}

/// Identity fingerprint for note list inputs (avoids full-content re-derivation on unrelated body ticks).
/// Searchable text is included while a query is active: edit timestamps are not
/// unique, so two content saves can legitimately share the same `updatedAt` value.
private struct NotesListInputFingerprint: Equatable {
    struct NoteIdentity: Equatable {
        let id: UUID
        let updatedAt: Date
        let isPinned: Bool
        let searchableTitle: String?
        let searchableContent: String?
    }

    let query: String
    let notes: [NoteIdentity]
}

/// Class init stays nonisolated for `@State` default construction under Swift 5.9;
/// mutation is method-isolated (`@MainActor` accessors only).
private final class NotesListSnapshotCache {
    private var fingerprint: NotesListInputFingerprint?
    private var value: NotesListSnapshot = .empty

    @MainActor
    func snapshot(notes: [NoteSchema.Note], query: String) -> NotesListSnapshot {
        let isSearching = !query.isEmpty
        let nextFingerprint = NotesListInputFingerprint(
            query: query,
            notes: notes.map {
                NotesListInputFingerprint.NoteIdentity(
                    id: $0.id,
                    updatedAt: $0.updatedAt,
                    isPinned: $0.isPinned,
                    searchableTitle: isSearching ? $0.title : nil,
                    searchableContent: isSearching ? $0.content : nil
                )
            }
        )
        if fingerprint == nextFingerprint {
            return value
        }
        fingerprint = nextFingerprint
        value = Self.derive(notes: notes, query: query)
        return value
    }

    @MainActor
    private static func derive(notes: [NoteSchema.Note], query: String) -> NotesListSnapshot {
        let filtered: [NoteSchema.Note]
        if query.isEmpty {
            filtered = notes
        } else {
            filtered = notes.filter { note in
                note.title.localizedStandardContains(query)
                    || note.content.localizedStandardContains(query)
            }
        }

        let inputs = filtered.map {
            NotesGrouping.Input(id: $0.id, updatedAt: $0.updatedAt, isPinned: $0.isPinned)
        }
        let byID = Dictionary(uniqueKeysWithValues: filtered.map { ($0.id, $0) })
        let sections: [NotesListSnapshot.Section] = NotesGrouping.sections(notes: inputs).compactMap { section in
            let sectionNotes = section.ids.compactMap { byID[$0] }
            guard !sectionNotes.isEmpty else { return nil }
            return NotesListSnapshot.Section(key: section.key, notes: sectionNotes)
        }
        let flat = sections.flatMap(\.notes)
        let calendar = Calendar.current
        let now = Date()
        let todayCount = filtered.reduce(0) {
            $0 + (calendar.isDate($1.updatedAt, inSameDayAs: now) ? 1 : 0)
        }
        return NotesListSnapshot(
            filteredCount: filtered.count,
            todayCount: todayCount,
            sections: sections,
            flatSelectableNotes: flat
        )
    }
}

@MainActor
final class NoteEditorWindowControllerRegistry {
    static let shared = NoteEditorWindowControllerRegistry()

    private var controllers: [NoteEditorWindowController] = []

    var count: Int { controllers.count }

    func retain(_ controller: NoteEditorWindowController) {
        controllers.append(controller)
    }

    func release(_ controller: NoteEditorWindowController) {
        controllers.removeAll { $0 === controller }
    }

    /// Presents a note editor window; the registry owns the controller until it closes.
    func presentEditor(note: NoteSchema.Note?, isNewNote: Bool, modelContainer: ModelContainer) {
        let editorController = NoteEditorWindowController()
        editorController.setModelContainer(modelContainer)
        retain(editorController)
        editorController.onClose = { [weak self, weak editorController] in
            guard let editorController else { return }
            self?.release(editorController)
        }
        editorController.show(note: note, isNewNote: isNewNote)
    }
}

// MARK: - Preview

#Preview("Notes View - With Data") {
    NotesView()
        .modelContainer(PreviewContainer.withSampleNotes)
        .frame(width: 900, height: 600)
        .preferredColorScheme(.light)
}

#Preview("Notes View - Empty") {
    NotesView()
        .modelContainer(PreviewContainer.empty)
        .frame(width: 900, height: 600)
        .preferredColorScheme(.light)
}

#Preview("Notes View - Dark") {
    NotesView()
        .modelContainer(PreviewContainer.withSampleNotes)
        .frame(width: 900, height: 600)
        .preferredColorScheme(.dark)
}
