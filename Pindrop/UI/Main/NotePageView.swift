//
//  NotePageView.swift
//  Pindrop
//
//  Created on 2026-08-22.
//
//  The note, in the main window (WP3).
//
//  One page draws every shape a note can have: a plain typed note, a note that
//  is recording right now, and a note whose recording produced a transcript and
//  an enhanced panel. The three views are switched by hand and never by the app.
//
//  The editor is the one from the pop-out window, persistence stack included.
//  Note autosave arbitration is subtle enough that a second implementation would
//  be a second set of bugs, so `NoteEditorPersistenceController` stays the single
//  owner: this page tracks drafts, debounces, and flushes exactly the way the
//  window did, and the window's own termination sweep therefore still covers it.
//

import SwiftUI
import SwiftData
import AppKit
import Foundation
import PindropCore
import PindropData

/// One request for a generated panel. Returns nil on success, or the message to
/// show the person when it could not be produced.
typealias NoteEnhancementHandler = @MainActor (NoteEnhancementRequest) async -> String?

struct NoteEnhancementRequest: Equatable, Sendable {
    let sessionID: UUID
    let noteID: UUID
    let templatePresetIdentifier: String?
}

/// One trip from a citation to the span it quotes.
///
/// The sequence number is what makes following the same citation twice a new
/// trip: the page scrolls and flashes on a change, and two identical spans
/// would otherwise be no change at all.
struct NoteCitationJump: Equatable, Sendable {
    let sequence: Int
    let segmentID: String
}

struct NotePageView: View {

    // MARK: Inputs

    let noteID: UUID
    let onBack: () -> Void
    /// The one live capture in the app, if the shell has one. The page only acts
    /// on it while it is attached to this note.
    let noteCaptureState: NoteCaptureState?
    /// Starts a capture bound to this note. `false` means the shell refused.
    let onStartNoteCapture: ((NoteCaptureRequest) -> Bool)?
    /// Finishes the capture attached to this note.
    let onFinishNoteCapture: (() -> Void)?
    /// Throws the capture away: the audio and the live transcript go, the typed
    /// notes stay.
    let onCancelNoteCapture: (() -> Void)?
    let onGenerateEnhancedPanel: NoteEnhancementHandler?
    /// Opens the Ask surface. Nil while the shell has none, which is what keeps
    /// the Ask satellite off a build that cannot answer it.
    let onOpenAsk: (() -> Void)?
    /// True while the Ask surface is up. It owns the bottom-right corner, so the
    /// floating control stands down.
    let isAskSurfaceOpen: Bool

    init(
        noteID: UUID,
        onBack: @escaping () -> Void,
        noteCaptureState: NoteCaptureState? = nil,
        onStartNoteCapture: ((NoteCaptureRequest) -> Bool)? = nil,
        onFinishNoteCapture: (() -> Void)? = nil,
        onCancelNoteCapture: (() -> Void)? = nil,
        onGenerateEnhancedPanel: NoteEnhancementHandler? = nil,
        onOpenAsk: (() -> Void)? = nil,
        isAskSurfaceOpen: Bool = false
    ) {
        self.noteID = noteID
        self.onBack = onBack
        self.noteCaptureState = noteCaptureState
        self.onStartNoteCapture = onStartNoteCapture
        self.onFinishNoteCapture = onFinishNoteCapture
        self.onCancelNoteCapture = onCancelNoteCapture
        self.onGenerateEnhancedPanel = onGenerateEnhancedPanel
        self.onOpenAsk = onOpenAsk
        self.isAskSurfaceOpen = isAskSurfaceOpen
        _notes = Query(
            filter: #Predicate<NoteSchema.Note> { $0.id == noteID },
            sort: \NoteSchema.Note.updatedAt
        )
    }

    // MARK: Environment and store

    @Environment(\.modelContext) private var modelContext
    @Environment(\.locale) private var locale
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Query private var notes: [NoteSchema.Note]

    // MARK: Editor draft state (mirrors the pop-out editor)

    @State private var title = ""
    @State private var content = ""
    @State private var tags: [String] = []
    @State private var newTag = ""
    @State private var currentNote: NoteSchema.Note?
    @State private var lastSavedSnapshot: NoteSnapshot?
    @State private var lastEditedAt = Date()
    @State private var autosaveTask: Task<Void, Never>?
    @State private var displayedWordCount = 0
    @State private var wordCountTask: Task<Void, Never>?
    /// The word the footer flashes after a save or a copy. One slot: two
    /// confirmations in one corner would only compete.
    @State private var confirmationMessage: String?
    @State private var confirmationTask: Task<Void, Never>?

    // MARK: Page state

    @State private var views: NoteCaptureViews?
    @State private var selection: CaptureNoteViewKind = .humanNotes
    @State private var selectedTemplateIdentifier: String?
    /// The newest panel the person has actually opened. Anything newer wears the
    /// ready dot until they look at it.
    @State private var lastSeenPanelID: UUID?
    @State private var hasUnreadEnhanced = false
    @State private var isEnhancedNoticeDismissed = false
    @State private var isGeneratingPanel = false
    @State private var enhancementFailureMessage: String?
    @State private var recordIncludesSystemAudio = false
    @State private var expectedSpeakerCount: Int?
    @State private var pendingTranscriptDeletion = false
    @State private var pendingNoteDeletion = false
    @State private var pendingCaptureCancellation = false
    @State private var errorMessage: String?

    // MARK: Enhanced view state

    /// The sources behind each panel, read once per store refresh. A panel with
    /// no readable provenance keeps an empty list rather than disappearing.
    @State private var panelCitations: [UUID: [MeetingNoteCitation]] = [:]
    /// The templates the menu offers, in their stored order.
    @State private var templatePresets: [TemplateMenuPreset] = []
    @State private var isPresetSheetPresented = false
    /// True when the preset sheet was opened to make a template, not to read the
    /// list of them.
    @State private var presetSheetStartsCreating = false
    /// The chip whose dropdown is open. Only the Enhanced chip has one.
    @State private var openChipMenu: CaptureNoteViewKind?
    @State private var isSpeakersPopoverPresented = false
    @State private var isTitleHovering = false

    // MARK: Transcript view state

    @State private var transcriptQuery = ""
    /// Which shape the floating control is in.
    @State private var fabState: NoteFABState = .resting
    /// The match the reader is standing on, counted from zero across the view.
    @State private var currentMatchIndex: Int?
    /// How far the live transcript sheet is pulled open.
    @State private var liveSheetDetent: TranscriptSheetDetent = .collapsed
    @State private var playbackController = MediaPlaybackController()
    /// The recorded audio of this note, when the capture kept one.
    @State private var mediaURL: URL?
    @State private var mediaDuration: TimeInterval = 0
    /// The span a citation was followed to. It is carried with a sequence
    /// number so following the same citation twice still scrolls and flashes.
    @State private var citationJump: NoteCitationJump?
    @State private var citationJumpCount = 0
    @State private var citationFlashTask: Task<Void, Never>?

    @FocusState private var titleFieldFocused: Bool

    /// The editor's text column starts after the marker gutter so the title, the
    /// chips, and the body share one left edge.
    private let textColumnInset: CGFloat = MarkdownTextView.headingMarginWidth
    private let canvasMaxWidth: CGFloat = 720

    private var note: NoteSchema.Note? { notes.first }

    private var captureSessionStore: CaptureSessionStore {
        CaptureSessionStore(modelContext: modelContext)
    }

    private var notesStore: NotesStore {
        NotesStore(modelContext: modelContext, metadataGenerator: { _, _ in nil })
    }

    // MARK: Derived

    private var capturePhase: NotePageCapturePhase {
        guard let noteCaptureState else { return .none }
        return NotePageCapturePhase(state: noteCaptureState, noteID: noteID)
    }

    private var pageState: NotePageState {
        NotePageState(
            hasPanels: !(views?.panels.isEmpty ?? true),
            hasTranscript: views?.transcript != nil,
            isTranscriptDeleted: views?.isTranscriptDeleted ?? false,
            isRecorded: views?.isRecorded ?? false,
            capture: capturePhase,
            hasUnreadEnhanced: hasUnreadEnhanced,
            hasLiveText: hasLiveText
        )
    }

    /// True once the running capture has heard something. Reading the live text
    /// here costs this page one invalidation per committed sentence, which is
    /// what it takes to offer the Transcript view during the recording.
    private var hasLiveText: Bool {
        guard capturePhase.isRecording, let noteCaptureState else { return false }
        return !noteCaptureState.liveTranscript.isEmpty
    }

    private var resolvedSelection: CaptureNoteViewKind {
        NotePagePresentation.resolvedKind(requested: selection, state: pageState, locale: locale)
    }

    private var headerActions: NotePageHeaderActions {
        NotePagePresentation.headerActions(state: pageState, selection: resolvedSelection)
    }

    private var currentPanel: CaptureEnhancedPanelSnapshot? {
        guard let views else { return nil }
        if let selectedTemplateIdentifier {
            return views.panels.first { $0.templatePresetIdentifier == selectedTemplateIdentifier }
                ?? views.panels.first
        }
        return views.panels.first
    }

    private var showsSpeakersChip: Bool {
        if views?.captureState?.capturesSystemAudio == true { return true }
        if capturePhase.isActive, noteCaptureState?.includesSystemAudio == true { return true }
        return capturePhase == .none && recordIncludesSystemAudio
    }

    // MARK: Body

    var body: some View {
        // The live sheet snaps to fractions of the page, so the page has to know
        // how tall it is.
        GeometryReader { proxy in
            pageBody(canvasHeight: proxy.size.height)
        }
    }

    private func pageBody(canvasHeight: CGFloat) -> some View {
        VStack(spacing: 0) {
            // The floating control sits over the reading area and nowhere else:
            // it is 20 above the footer hairline, and the capture dock, when it
            // is up, fills the same band (which is why the two never share it).
            ZStack(alignment: .bottomTrailing) {
                pageContent(canvasHeight: canvasHeight)

                noteFAB
                    .padding(.trailing, NoteFABPresentation.trailingInset)
                    .padding(.bottom, NoteFABPresentation.bottomInset)
            }

            footer
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(AppColors.contentBackground)
        .themeRefresh()
        .accessibilityIdentifier("note.page")
        .task(id: noteID) { await load() }
        .onChange(of: capturePhase) { _, newValue in
            Task { await refreshViews() }
            if newValue == .none {
                isEnhancedNoticeDismissed = false
            }
            // A sheet of live text has nothing left to show once the microphone
            // closes, and it must not keep the finalizing bar off screen.
            if !newValue.isRecording {
                liveSheetDetent = .collapsed
            }
        }
        .onChange(of: title) { _, _ in noteDidChange() }
        .onChange(of: content) { _, newValue in
            scheduleWordCountUpdate(for: newValue)
            noteDidChange()
        }
        .onChange(of: tags) { _, _ in noteDidChange() }
        .onChange(of: mediaURL) { _, url in loadPlayableAudio(url) }
        // Another letter renumbers the matches, so the reader is put back on the
        // first one rather than on a number that now means another word.
        .onChange(of: transcriptQuery) { _, _ in
            currentMatchIndex = NoteFABPresentation.resetMatch(total: transcriptMatchTotal)
        }
        .onChange(of: resolvedSelection) { _, _ in
            currentMatchIndex = NoteFABPresentation.resetMatch(total: transcriptMatchTotal)
        }
        .onDisappear {
            playbackController.teardownPlayback()
            autosaveTask?.cancel()
            wordCountTask?.cancel()
            confirmationTask?.cancel()
            citationFlashTask?.cancel()
            flushOnLeaving()
        }
        .sheet(isPresented: $isPresetSheetPresented, onDismiss: refreshTemplatePresets) {
            PresetManagementSheet(startsCreating: presetSheetStartsCreating)
        }
        .confirmationDialog(
            localized("Delete this transcript?", locale: locale),
            isPresented: $pendingTranscriptDeletion,
            titleVisibility: .visible
        ) {
            Button(localized("Delete transcript", locale: locale), role: .destructive) {
                deleteTranscript()
            }
            Button(localized("Cancel", locale: locale), role: .cancel) {}
        } message: {
            Text(localized(
                "Your notes and the enhanced note stay. The transcript is hidden from this note.",
                locale: locale
            ))
        }
        .confirmationDialog(
            localized("Delete note?", locale: locale),
            isPresented: $pendingNoteDeletion,
            titleVisibility: .visible
        ) {
            Button(localized("Delete", locale: locale), role: .destructive) {
                deleteNote()
            }
            Button(localized("Cancel", locale: locale), role: .cancel) {}
        } message: {
            Text(localized("This will permanently remove this note.", locale: locale))
        }
        .confirmationDialog(
            localized("Discard this recording?", locale: locale),
            isPresented: $pendingCaptureCancellation,
            titleVisibility: .visible
        ) {
            Button(localized("Discard recording", locale: locale), role: .destructive) {
                onCancelNoteCapture?()
            }
            Button(localized("Cancel", locale: locale), role: .cancel) {}
        } message: {
            Text(NotePagePresentation.cancelCaptureMessage(locale: locale))
        }
        .background {
            Button(action: saveNow) { EmptyView() }
                .keyboardShortcut("s", modifiers: .command)
                .opacity(0)
                .frame(width: 0, height: 0)
                .allowsHitTesting(false)

            Button(action: openSearch) { EmptyView() }
                .keyboardShortcut("f", modifiers: .command)
                .opacity(0)
                .frame(width: 0, height: 0)
                .allowsHitTesting(false)
        }
    }

    private func pageContent(canvasHeight: CGFloat) -> some View {
        VStack(spacing: 0) {
            ScrollView(.vertical, showsIndicators: true) {
                ScrollViewReader { scrollProxy in
                    // The header rail spans the pane like the mock; only the
                    // text surfaces cap at the 720pt reading measure.
                    VStack(alignment: .leading, spacing: 24) {
                        headerRail
                        // Paper board 52: title and meta form one block with a
                        // 14 gap; 24 separates the blocks around it.
                        VStack(alignment: .leading, spacing: 14) {
                            titleField
                            metaChipRow
                        }
                        .frame(maxWidth: canvasMaxWidth, alignment: .leading)
                        canvas
                            .frame(maxWidth: canvasMaxWidth, alignment: .leading)
                    }
                    .padding(.horizontal, 40)
                    .padding(.top, 40)
                    .padding(.bottom, 16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    // A citation was followed: put its line on screen. Every
                    // span carries its own identifier, so this lands on the
                    // words that were quoted and not on the turn around them.
                    .onChange(of: citationJump) { _, jump in
                        guard let jump else { return }
                        withAnimation(reduceMotion ? nil : AppTheme.Animation.normal) {
                            scrollProxy.scrollTo(jump.segmentID, anchor: .center)
                        }
                    }
                    // Stepping through the matches walks the page: the same
                    // scroll a citation uses, pointed at the span the current
                    // match is in.
                    .onChange(of: transcriptPresentation.currentMatchSegmentID) { _, segmentID in
                        guard let segmentID else { return }
                        withAnimation(reduceMotion ? nil : AppTheme.Animation.normal) {
                            scrollProxy.scrollTo(segmentID, anchor: .center)
                        }
                    }
                }
            }

            bottomDock(canvasHeight: canvasHeight)
                .padding(.horizontal, 40)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Floating control

    private var fabContext: NoteFABContext {
        NoteFABContext(
            hasAudio: NotePagePresentation.showsPlayAction(
                state: pageState,
                hasPlayableAudio: mediaURL != nil
            ),
            canAsk: onOpenAsk != nil,
            canSearch: NotePagePresentation.showsTranscriptSearch(
                state: pageState,
                selection: resolvedSelection
            ),
            isAskSurfaceOpen: isAskSurfaceOpen,
            isCaptureDockVisible: NotePagePresentation.showsCaptureStrip(state: pageState)
        )
    }

    private var transcriptMatchTotal: Int {
        transcriptPresentation.matchCount
    }

    private var noteFAB: some View {
        NoteFAB(
            context: fabContext,
            state: $fabState,
            query: $transcriptQuery,
            matchTotal: transcriptMatchTotal,
            currentMatch: $currentMatchIndex,
            controller: playbackController,
            fallbackDuration: mediaDuration,
            onAsk: { onOpenAsk?() },
            onCopy: copyCurrentView,
            onPlay: startPlayback,
            onStepMatch: stepMatch
        )
    }

    // MARK: - Header rail

    private var headerRail: some View {
        // Paper board 52: 8 between the rail's controls.
        HStack(spacing: 8) {
            backChip

            Spacer(minLength: 12)

            if headerActions.showsRecordButton {
                recordButton
            }

            exportMenu

            overflowMenu
        }
    }

    private var backChip: some View {
        Button(action: onBack) {
            HStack(spacing: 4) {
                // `.backward`, not `.left`: the back chip has to point at the
                // list, and the list is on the right in a right-to-left locale.
                Image(systemName: "chevron.backward")
                    .font(.system(size: 11, weight: .medium))
                Text(localized("Notes", locale: locale))
                    .font(AppTypography.labelStrong)
            }
            .foregroundStyle(AppColors.textSecondary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusRing(.rounded(.sm))
        .accessibilityIdentifier("note.page.back")
        .accessibilityLabel(localized("Back to notes", locale: locale))
    }

    private var recordButton: some View {
        HStack(spacing: 0) {
            Button(action: { startCapture(includeSystemAudio: recordIncludesSystemAudio) }) {
                HStack(spacing: 7) {
                    Circle()
                        .fill(AppColors.recording)
                        .frame(width: 8, height: 8)
                        .accessibilityHidden(true)
                    Text(localized("Record", locale: locale))
                        .font(AppTypography.labelSemibold)
                        .foregroundStyle(AppColors.textPrimary)
                }
                .padding(.vertical, 7)
                .padding(.leading, 13)
                .padding(.trailing, 9)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .focusRing(.rounded(.sm))
            .accessibilityIdentifier("note.page.record")

            Menu {
                Button(localized("Record", locale: locale)) {
                    recordIncludesSystemAudio = false
                    startCapture(includeSystemAudio: false)
                }
                Button(localized("Record with system audio", locale: locale)) {
                    recordIncludesSystemAudio = true
                    startCapture(includeSystemAudio: true)
                }
            } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(AppColors.textSecondary)
                    .padding(.vertical, 7)
                    .padding(.trailing, 10)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityIdentifier("note.page.recordOptions")
            .accessibilityLabel(localized("More recording options", locale: locale))
        }
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(AppColors.contentBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(AppColors.border, lineWidth: 1)
        )
    }

    private var exportMenu: some View {
        ExportMenuButton(
            title: localized("Export", locale: locale),
            formats: TranscriptExportService.availableFormats(for: exportSource()),
            formatTitle: { $0.displayName(locale: locale) },
            onSelect: exportCurrentView
        )
        .accessibilityIdentifier("note.page.export")
    }

    private var overflowMenu: some View {
        Menu {
            Button(localized("Open in new window", locale: locale)) {}
                .disabled(!headerActions.canOpenInNewWindow)

            if headerActions.canSaveAsNote {
                Button(localized("Save as Note", locale: locale), action: saveEnhancedPanelAsNote)
            }

            Button(localized("Copy Content", locale: locale), action: copyCurrentView)

            Divider()

            if headerActions.canCancelCapture, onCancelNoteCapture != nil {
                Button(localized("Cancel recording", locale: locale), role: .destructive) {
                    pendingCaptureCancellation = true
                }
                .accessibilityIdentifier("note.page.capture.cancel")
            }

            if headerActions.canDeleteTranscript {
                Button(localized("Delete transcript", locale: locale), role: .destructive) {
                    pendingTranscriptDeletion = true
                }
            }

            Button(localized("Delete this note", locale: locale), role: .destructive) {
                pendingNoteDeletion = true
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(AppColors.textSecondary)
                .frame(width: 30, height: 30)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(AppColors.border, lineWidth: 1)
        )
        .accessibilityIdentifier("note.page.overflow")
        .accessibilityLabel(localized("More note actions", locale: locale))
    }

    // MARK: - Title

    /// The title, with the quiet pencil that says it can be typed into.
    ///
    /// The glyph is a hint, not a control: it goes as soon as the field has
    /// focus, because by then the caret is saying the same thing.
    private var titleField: some View {
        HStack(spacing: 10) {
            TextField(localized("Note Title", locale: locale), text: $title)
                .font(AppTypography.pageTitle)
                .tracking(AppTypography.pageTitleTracking)
                .foregroundStyle(AppColors.textPrimary)
                .textFieldStyle(.plain)
                .focused($titleFieldFocused)
                // Only the resting title hugs its text, so the pencil can sit
                // right after the words. A focused field takes the row back and
                // keeps scrolling while a long title is typed. The text is
                // leading-aligned either way, so nothing moves on screen.
                .fixedSize(horizontal: !titleFieldFocused, vertical: false)
                .accessibilityIdentifier("note.page.title")

            if !titleFieldFocused {
                Image(systemName: "pencil")
                    .font(.system(size: 15))
                    .foregroundStyle(AppColors.textSecondary)
                    .opacity(isTitleHovering ? 0.45 : 0)
                    .accessibilityHidden(true)

                Spacer(minLength: 0)
            }
        }
        .padding(.leading, textColumnInset)
        .onHover { isTitleHovering = $0 }
        .appAnimation(.fast, value: isTitleHovering)
    }

    // MARK: - Meta chips

    private var metaChipRow: some View {
        HStack(spacing: 8) {
            if NotePagePresentation.isToggleVisible(state: pageState, locale: locale) {
                viewChips
            }

            if !canOpenEnhancedMenu,
               resolvedSelection == .enhanced,
               let label = enhancedPresentation.readOnlyLabel {
                readOnlyTemplateChip(label)
            }

            dateChip

            if showsSpeakersChip {
                speakersChip
            }

            tagChips

            Spacer(minLength: 0)
        }
        .padding(.leading, textColumnInset)
    }

    /// The Enhanced chip's dropdown is only offered where it can be honored: a
    /// panel this build wrote, which can be regenerated into another template.
    private var canOpenEnhancedMenu: Bool {
        EnhancedViewPresentation.showsTemplateMenu(
            panel: currentPanel,
            selection: resolvedSelection
        )
    }

    private var enhancedMenu: some View {
        EnhancedMenuPanel(
            content: EnhancedViewPresentation.menu(
                presets: templatePresets,
                selected: currentPanel?.templatePresetIdentifier,
                locale: locale
            ),
            isBusy: isGeneratingPanel,
            onSelectTemplate: { identifier in
                openChipMenu = nil
                selectTemplate(identifier)
            },
            onRegenerate: {
                openChipMenu = nil
                regeneratePanel(
                    templatePresetIdentifier: currentPanel?.templatePresetIdentifier
                        ?? selectedTemplateIdentifier
                )
            },
            onManageTemplates: {
                openChipMenu = nil
                presetSheetStartsCreating = false
                isPresetSheetPresented = true
            },
            onNewTemplate: {
                openChipMenu = nil
                presetSheetStartsCreating = true
                isPresetSheetPresented = true
            }
        )
    }

    /// A panel an older build wrote says so instead of offering a menu it
    /// cannot honor.
    private func readOnlyTemplateChip(_ label: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "sparkles")
                .font(.system(size: 11))
                .foregroundStyle(AppColors.textTertiary)
            Text(label)
                .font(AppTypography.badge)
                .foregroundStyle(AppColors.textTertiary)
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 10)
        .overlay(Capsule(style: .continuous).strokeBorder(AppColors.border, lineWidth: 1))
        .help(EnhancedViewPresentation.readOnlyHelpText(locale: locale))
        .accessibilityIdentifier("note.page.enhanced.readOnly")
    }

    private var viewChips: some View {
        NoteViewChips(
            chips: NotePagePresentation.chips(
                state: pageState,
                selection: resolvedSelection,
                canOpenEnhancedMenu: canOpenEnhancedMenu,
                locale: locale
            ).map { chip in
                NoteViewChips<CaptureNoteViewKind, AnyView>.Chip(
                    value: chip.kind,
                    title: NotePagePresentation.viewTitle(chip.kind, locale: locale),
                    systemImage: chip.systemImage,
                    isEnabled: chip.isEnabled,
                    helpText: chip.helpText,
                    indicator: chip.indicator.map { indicator in
                        switch indicator {
                        case .live: .live
                        case .ready: .ready
                        }
                    },
                    opensMenu: chip.opensMenu,
                    accentsIconWhenSelected: chip.kind == .enhanced,
                    accessibilityIdentifier: NotePagePresentation.accessibilityIdentifier(chip.kind)
                )
            },
            selection: resolvedSelection,
            onSelect: select,
            openMenuValue: $openChipMenu,
            menuContent: { _ in AnyView(enhancedMenu) }
        )
        .accessibilityIdentifier("note.page.viewToggle")
    }

    private var dateChip: some View {
        metaChip(
            systemImage: "calendar",
            title: NotesDateFormatting.rowDate(
                date: note?.createdAt ?? Date(),
                locale: locale
            )
        )
    }

    /// The speakers chip: who the recording heard, and the way to correct a name.
    private var speakersChip: some View {
        Button {
            isSpeakersPopoverPresented = true
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "person.2")
                    .font(.system(size: 11))
                    .foregroundStyle(AppColors.textTertiary)
                Text(speakersChipTitle)
                    .font(AppTypography.badge)
                    .foregroundStyle(AppColors.textSecondary)
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(AppColors.textTertiary)
            }
            .padding(.vertical, 4)
            .padding(.horizontal, 10)
            .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
        .focusRing(.capsule)
        .overlay(Capsule(style: .continuous).strokeBorder(AppColors.border, lineWidth: 1))
        .popover(isPresented: $isSpeakersPopoverPresented, arrowEdge: .bottom) {
            NoteSpeakersPopover(
                content: NotePagePresentation.speakersPopover(
                    segments: views?.transcript?.segments ?? [],
                    duration: views?.transcript?.duration ?? 0,
                    locale: locale
                ),
                expectedSpeakerCount: $expectedSpeakerCount,
                isExpectedCountLocked: capturePhase.isActive,
                onRename: renameSpeakerProfile
            )
        }
        .accessibilityIdentifier("note.page.speakers")
        .accessibilityLabel(speakersChipTitle)
    }

    private var speakersChipTitle: String {
        NotePagePresentation.speakersChipTitle(
            speakerCount: views?.transcript?.speakerCount ?? 0,
            expectedSpeakerCount: expectedSpeakerCount,
            locale: locale
        )
    }

    private var tagChips: some View {
        HStack(spacing: 6) {
            ForEach(tags, id: \.self) { tag in
                TagChip(tag: tag, onRemove: { removeTag(tag) })
            }

            TextField(localized("Add tag...", locale: locale), text: $newTag)
                .font(AppTypography.badge)
                .foregroundStyle(AppColors.textTertiary)
                .textFieldStyle(.plain)
                .frame(width: 68)
                .onSubmit(addTag)
                .accessibilityIdentifier("note.page.addTag")
        }
    }

    private func metaChip(systemImage: String, title: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: systemImage)
                .font(.system(size: 11))
                .foregroundStyle(AppColors.textTertiary)
            Text(title)
                .font(AppTypography.badge)
                .foregroundStyle(AppColors.textSecondary)
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 10)
        .overlay(Capsule(style: .continuous).strokeBorder(AppColors.border, lineWidth: 1))
    }

    // MARK: - Canvas

    @ViewBuilder
    private var canvas: some View {
        VStack(alignment: .leading, spacing: 12) {
            notices

            switch resolvedSelection {
            case .humanNotes:
                MarkdownEditor(text: $content)
                    .frame(minHeight: 320)
                    .accessibilityIdentifier("note.page.editor")
            case .enhanced:
                enhancedCanvas
            case .transcript:
                transcriptCanvas
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var notices: some View {
        if let errorMessage {
            InlineNotice(
                kind: .error,
                message: errorMessage,
                actionTitle: localized("Dismiss", locale: locale),
                actionIdentifier: "note.page.error.dismiss",
                action: { self.errorMessage = nil }
            )
            .padding(.leading, textColumnInset)
        }

        if let message = enhancementFailureMessage ?? noteCaptureState?.enhancementFailureMessage,
           capturePhase != .enhancing {
            InlineNotice(
                kind: .error,
                message: message,
                actionTitle: localized("Try again", locale: locale),
                actionIdentifier: "note.page.enhancement.retry",
                action: { regeneratePanel(templatePresetIdentifier: selectedTemplateIdentifier) }
            )
            .padding(.leading, textColumnInset)
        }

        if case .failed = capturePhase, let message = noteCaptureState?.failureMessage {
            InlineNotice(kind: .error, message: message)
                .padding(.leading, textColumnInset)
                .accessibilityIdentifier("note.page.capture.failure")
        }

        if hasUnreadEnhanced, !isEnhancedNoticeDismissed, resolvedSelection != .enhanced {
            InlineNotice(
                kind: .info,
                message: NotePagePresentation.enhancedReadyMessage(locale: locale),
                actionTitle: localized("View", locale: locale),
                actionIdentifier: "note.page.enhanced.view",
                action: { select(.enhanced) }
            )
            .padding(.leading, textColumnInset)
            .accessibilityIdentifier("note.page.enhanced.notice")
        }

        if views?.isTranscriptDeleted == true {
            InlineNotice(
                kind: .info,
                message: localized("You deleted this transcript.", locale: locale)
            )
            .padding(.leading, textColumnInset)
        }
    }

    /// The generated note: its sections, its citations, and where they came from.
    ///
    /// A regeneration is drawn above the panel it is replacing rather than in
    /// place of it: the note that already exists stays readable until the new
    /// one lands.
    @ViewBuilder
    private var enhancedCanvas: some View {
        if let panel = currentPanel {
            VStack(alignment: .leading, spacing: 16) {
                if isGeneratingPanel {
                    generatingRow
                }

                EnhancedNoteBody(
                    presentation: enhancedPresentation,
                    onFollowSource: { followCitation(segmentID: $0.segmentID) }
                )

                if !enhancedPresentation.isReadOnly {
                    EnhancedPanelFeedbackRow(feedback: panel.feedback, onRate: ratePanel)
                }
            }
            .padding(.leading, textColumnInset)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityIdentifier("note.page.enhanced")
        } else if isGeneratingPanel {
            generatingRow
                .padding(.leading, textColumnInset)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            VStack(alignment: .leading, spacing: 10) {
                Text(localized("No enhanced note yet.", locale: locale))
                    .font(AppTypography.labelStrongSelected)
                    .foregroundStyle(AppColors.textPrimary)

                Text(localized(
                    "Pindrop writes one from your notes and the transcript.",
                    locale: locale
                ))
                .font(AppTypography.body)
                .foregroundStyle(AppColors.textSecondary)

                if views?.captureState != nil {
                    SecondaryButton(
                        title: localized("Generate enhanced note", locale: locale),
                        systemImage: "sparkles",
                        action: { regeneratePanel(templatePresetIdentifier: nil) }
                    )
                    .accessibilityIdentifier("note.page.enhanced.generate")
                }
            }
            .padding(.leading, textColumnInset)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// The enhanced view, resolved against the transcript that is on screen.
    private var enhancedPresentation: EnhancedNotePresentation {
        EnhancedViewPresentation.make(
            panel: currentPanel,
            citations: currentPanel.flatMap { panelCitations[$0.id] } ?? [],
            segments: views?.transcript?.segments ?? [],
            locale: locale
        )
    }

    /// What the page shows while it writes a panel.
    private var generatingRow: some View {
        StageProgressRow(
            stage: NotePagePresentation.stageTitle(.assembling, locale: locale),
            caption: EnhancedViewPresentation.generatingMessage(
                templateName: generatingTemplateName,
                locale: locale
            )
        )
        .accessibilityIdentifier("note.page.enhanced.writing")
    }

    /// The template the running generation was asked for, when it has a name.
    private var generatingTemplateName: String? {
        guard let selectedTemplateIdentifier else { return nil }
        return templatePresets.first { $0.identifier == selectedTemplateIdentifier }?.name
    }

    /// The transcript, live or finished.
    ///
    /// While the recording runs there are no durable spans to draw, so the view
    /// shows the same live lines the capture sheet does, updated as they arrive
    /// rather than at the next phase change.
    @ViewBuilder
    private var transcriptCanvas: some View {
        if NotePagePresentation.isTranscriptLive(state: pageState) {
            LiveTranscriptLines(state: noteCaptureState)
                .padding(.leading, textColumnInset)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityIdentifier("note.page.transcript.live")
        } else {
            NoteTranscriptTurns(
                presentation: transcriptPresentation,
                controller: playbackController,
                canSeek: mediaURL != nil,
                flashingSegmentID: citationJump?.segmentID,
                onSeek: seekPlayback
            )
            .padding(.leading, textColumnInset)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityIdentifier("note.page.transcript")
        }
    }

    private var transcriptPresentation: TranscriptListPresentation {
        TranscriptSegmentPresentation.make(
            segments: views?.transcript?.segments ?? [],
            query: transcriptQuery,
            currentMatchIndex: currentMatchIndex,
            locale: locale
        )
    }

    // MARK: - Bottom dock

    /// The band between the page and the footer: the capture dock while a
    /// capture runs, and nothing otherwise. Playback moved into the floating
    /// control, which is why nothing else claims this band any more.
    @ViewBuilder
    private func bottomDock(canvasHeight: CGFloat) -> some View {
        if NotePagePresentation.showsCaptureStrip(state: pageState) {
            captureDock(canvasHeight: canvasHeight)
        }
    }

    @ViewBuilder
    private func captureDock(canvasHeight: CGFloat) -> some View {
        // One second-by-second tick drives both the capture bar's clock and
        // the finalizing row's, so neither shows a frozen time.
        TimelineView(.periodic(from: noteCaptureState?.startedAt ?? .now, by: 1)) { context in
            captureDockContent(now: context.date, canvasHeight: canvasHeight)
        }
        .padding(.bottom, 12)
    }

    @ViewBuilder
    private func captureDockContent(now: Date, canvasHeight: CGFloat) -> some View {
        let elapsed = elapsedText(now: now)
        if let stage = capturePhase.finalizationStage {
            StageProgressRow(
                stage: NotePagePresentation.stageTitle(stage, locale: locale),
                completedStages: NotePagePresentation.completedStages(
                    before: stage,
                    locale: locale
                ),
                elapsedText: elapsed,
                progress: capturePhase.finalizationProgress,
                caption: NotePagePresentation.finalizingCaption(locale: locale)
            )
            .accessibilityIdentifier("note.page.capture.finalizing")
        } else if capturePhase == .enhancing {
            StageProgressRow(
                stage: NotePagePresentation.stageTitle(.assembling, locale: locale),
                completedStages: NotePagePresentation.completedStages(
                    before: .assembling,
                    locale: locale
                ),
                elapsedText: elapsed,
                caption: NotePagePresentation.finalizingCaption(locale: locale)
            )
            .accessibilityIdentifier("note.page.capture.enhancing")
        } else {
            captureDockBlock(now: now, canvasHeight: canvasHeight)
        }
    }

    /// The dock is one connected block: the live transcript sheet on top, the
    /// capture bar below it, a shared hairline between. The sheet is collapsed to
    /// one line until the person pulls it open.
    private func captureDockBlock(now: Date, canvasHeight: CGFloat) -> some View {
        VStack(spacing: 0) {
            LiveTranscriptSheet(
                state: noteCaptureState,
                detent: $liveSheetDetent,
                canvasHeight: canvasHeight
            )

            Rectangle()
                .fill(AppColors.border)
                .frame(height: 1)

            CaptureBar(
                presentation: CaptureBarPresentation.make(
                    state: captureBarState(now: now),
                    density: .page,
                    locale: locale
                ),
                // Closure, not values: the meters change per audio buffer and must
                // not invalidate this page (the editor lives in it).
                levels: { [weak noteCaptureState] in
                    guard let noteCaptureState else { return .silent }
                    return CaptureLevelSample(
                        level: noteCaptureState.audioLevel,
                        bands: noteCaptureState.bandLevels
                    )
                },
                onAction: { kind in
                    if kind == .finish { onFinishNoteCapture?() }
                }
            )
        }
        .background(AppColors.windowBackground)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(AppColors.border, lineWidth: 1)
        )
        .accessibilityIdentifier("note.page.capture.dock")
    }

    private func captureBarState(now: Date) -> CaptureBarState {
        CaptureBarState(
            phase: capturePhase == .starting ? .starting : .recording,
            elapsed: noteCaptureState?.startedAt.map { max(0, now.timeIntervalSince($0)) } ?? 0,
            noteTitle: title,
            includesSystemAudio: noteCaptureState?.includesSystemAudio ?? false
        )
    }

    private func elapsedText(now: Date) -> String? {
        guard let startedAt = noteCaptureState?.startedAt else { return nil }
        return NoteRowPresentation.elapsedText(max(0, now.timeIntervalSince(startedAt)))
    }

    // MARK: - Footer

    private var footer: some View {
        let line = NotePagePresentation.footer(
            kind: resolvedSelection,
            state: pageState,
            facts: footerFacts,
            locale: locale
        )
        return HStack(spacing: 12) {
            Text(line.leading)
                .font(AppTypography.caption)
                .foregroundStyle(AppColors.textTertiary)
                .lineLimit(1)
                .accessibilityIdentifier("note.page.footer")

            Spacer(minLength: 0)

            if let confirmationMessage {
                Text(confirmationMessage)
                    .font(AppTypography.caption)
                    .foregroundStyle(AppColors.accent)
                    .transition(.opacity)
                    .accessibilityIdentifier("note.page.footer.confirmation")
            }

            if let trailing = line.trailing {
                Button(action: saveNow) {
                    Text(trailing)
                        .font(AppTypography.monoSmall)
                        .foregroundStyle(AppColors.textTertiary)
                        // A shortcut is read key by key, so it keeps its
                        // left-to-right order in a right-to-left locale.
                        .environment(\.layoutDirection, .leftToRight)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .focusRing(.rounded(.sm))
                .help(localized("Save now (⌘S)", locale: locale))
                .accessibilityIdentifier("note.page.footer.save")
                .accessibilityLabel(localized("Save now (⌘S)", locale: locale))
            }
        }
        .padding(.horizontal, 40)
        .frame(height: 40)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(AppColors.border)
                .frame(height: 1)
        }
        .appAnimation(.fast, value: confirmationMessage)
    }

    private var footerFacts: NotePageFooterFacts {
        NotePageFooterFacts(
            wordCount: displayedWordCount,
            editedAt: lastEditedAt,
            panelGeneratedAt: currentPanel?.createdAt,
            panelTemplateName: currentPanel?.templateDisplayName,
            transcriptDuration: views?.transcript?.duration ?? 0,
            transcriptSpeakerCount: views?.transcript?.speakerCount ?? 0,
            isTranscriptLive: views?.transcript?.isLive ?? false
        )
    }

    // MARK: - Loading

    private func load() async {
        guard let existing = note else { return }
        // Await any in-flight close write so a reopened page never starts from a
        // pre-close snapshot.
        let modelID = existing.persistentModelID
        await NoteEditorPersistenceController.shared.flush(modelID: modelID)

        let refreshed = modelContext.model(for: modelID) as? NoteSchema.Note ?? existing
        title = refreshed.title
        content = refreshed.content
        tags = refreshed.tags
        lastEditedAt = refreshed.updatedAt
        currentNote = refreshed
        lastSavedSnapshot = NoteSnapshot(note: refreshed)
        displayedWordCount = refreshed.content.wordCount

        await refreshViews()
        refreshTemplatePresets()

        if let stored = views?.selectedView {
            selection = stored.kind
            selectedTemplateIdentifier = stored.templatePresetIdentifier
        }
        lastSeenPanelID = views?.panels.first?.id
        hasUnreadEnhanced = false

        // Focus order on this page is title, then the view toggle, then the
        // canvas: the order the controls are declared in. A page opened on an
        // untitled note starts at the top of that order instead of nowhere, so
        // the first Tab lands on the toggle and the second on the editor.
        if title.isEmpty, content.isEmpty {
            titleFieldFocused = true
        }
    }

    private func refreshViews() async {
        do {
            let resolved = try captureSessionStore.noteCaptureViews(noteID: noteID)
            let newestPanelID = resolved.panels.first?.id
            views = resolved
            if let newestPanelID, newestPanelID != lastSeenPanelID {
                if selection == .enhanced {
                    lastSeenPanelID = newestPanelID
                } else {
                    hasUnreadEnhanced = true
                }
            }
            if newestPanelID == nil {
                hasUnreadEnhanced = false
            }
            refreshPlayableAudio()
            refreshPanelCitations(resolved.panels)
        } catch {
            Log.ui.error("Failed to read note views: \(error.localizedDescription)")
        }
    }

    /// Reads the sources behind every panel of this note.
    ///
    /// A panel whose provenance cannot be read keeps an empty list: the note it
    /// generated is still worth reading, it simply cites nothing.
    private func refreshPanelCitations(_ panels: [CaptureEnhancedPanelSnapshot]) {
        let store = captureSessionStore
        var loaded: [UUID: [MeetingNoteCitation]] = [:]
        for panel in panels {
            do {
                if panel.isLegacy {
                    loaded[panel.id] = try store.generatedMeetingNote(noteID: panel.id)?.citations
                        ?? []
                } else {
                    loaded[panel.id] = try store.enhancedPanelCitations(panelID: panel.id)
                }
            } catch {
                Log.ui.warning(
                    "Panel sources could not be read: \(error.localizedDescription)"
                )
                loaded[panel.id] = []
            }
        }
        panelCitations = loaded
    }

    /// Reads the templates the menu offers.
    private func refreshTemplatePresets() {
        do {
            templatePresets = try PromptPresetStore(modelContext: modelContext)
                .fetchAll()
                .map { preset in
                    TemplateMenuPreset(
                        // The same identity the settings picker writes, so a
                        // template picked here and one picked there agree.
                        identifier: preset.builtInIdentifier ?? preset.id.uuidString,
                        name: preset.name,
                        isBuiltIn: preset.isBuiltIn,
                        sortOrder: preset.sortOrder
                    )
                }
        } catch {
            Log.ui.error("Failed to read templates: \(error.localizedDescription)")
            templatePresets = []
        }
    }

    /// Finds the recording behind this note, if the capture kept one.
    ///
    /// The audio belongs to the history record the capture produced, so the
    /// transcript can only be played once that record exists. A note whose audio
    /// was never kept, or has since been swept, simply has no playback bar.
    private func refreshPlayableAudio() {
        guard let recordID = views?.captureState?.transcriptionRecordID else {
            mediaURL = nil
            mediaDuration = 0
            return
        }
        var descriptor = FetchDescriptor<TranscriptionRecord>(
            predicate: #Predicate<TranscriptionRecord> { $0.id == recordID }
        )
        descriptor.fetchLimit = 1
        let record = try? modelContext.fetch(descriptor).first
        let url = record?.managedMediaURL
        mediaDuration = record?.duration ?? 0
        mediaURL = url.flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil }
    }

    private func loadPlayableAudio(_ url: URL?) {
        playbackController.teardownPlayback()
        guard let url else { return }
        playbackController.load(url: url)
    }

    // MARK: - Actions

    private func select(_ kind: CaptureNoteViewKind) {
        selection = kind
        // Picking any view answers the "your enhanced note is ready" notice.
        isEnhancedNoticeDismissed = true
        if kind == .enhanced {
            lastSeenPanelID = views?.panels.first?.id
            hasUnreadEnhanced = false
            selectedTemplateIdentifier = currentPanel?.templatePresetIdentifier
        }
        let stored = kind == .enhanced
            ? CaptureNoteViewSelection.enhanced(
                templatePresetIdentifier: selectedTemplateIdentifier
            )
            : CaptureNoteViewSelection(kind: kind)
        rememberSelection(stored)
    }

    private func rememberSelection(_ selection: CaptureNoteViewSelection) {
        do {
            try captureSessionStore.selectView(noteID: noteID, selection: selection)
        } catch {
            Log.ui.error("Failed to remember the note view: \(error.localizedDescription)")
        }
    }

    /// Picks a template from the menu.
    ///
    /// A template that already has a panel is a read: the panel is on disk and
    /// switching back to it must never spend a generation.
    private func selectTemplate(_ identifier: String) {
        switch EnhancedViewPresentation.selection(
            of: identifier,
            panels: views?.panels ?? [],
            showing: currentPanel?.templatePresetIdentifier
        ) {
        case .alreadyShowing:
            return

        case .showExisting(_, let templatePresetIdentifier):
            selectedTemplateIdentifier = templatePresetIdentifier
            rememberSelection(
                .enhanced(templatePresetIdentifier: templatePresetIdentifier)
            )

        case .generate(let templatePresetIdentifier):
            // The picked template only becomes the selected one if a generation
            // actually starts. Otherwise the menu would check a template that
            // has no panel and never will.
            let previous = selectedTemplateIdentifier
            selectedTemplateIdentifier = templatePresetIdentifier
            if !regeneratePanel(templatePresetIdentifier: templatePresetIdentifier) {
                selectedTemplateIdentifier = previous
            }
        }
    }

    // MARK: Floating control actions

    /// ⌘F. It opens the search wherever a search can be answered, and leaves the
    /// control alone where one cannot.
    private func openSearch() {
        guard fabContext.canSearch else { return }
        fabState = .search
    }

    /// Steps to the next or previous match and lets the canvas follow.
    private func stepMatch(_ step: NoteFABMatchStep) {
        currentMatchIndex = NoteFABPresentation.steppedMatch(
            from: currentMatchIndex,
            total: transcriptMatchTotal,
            step: step
        )
    }

    /// Copies what is on screen, in the shape it is read in.
    private func copyCurrentView() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(currentViewText(), forType: .string)
        flashConfirmation(NoteFABPresentation.copyConfirmation(locale: locale))
    }

    /// Plays the recording from wherever it stands.
    private func startPlayback() {
        guard mediaURL != nil else { return }
        if !playbackController.isPlaying {
            playbackController.togglePlayback()
        }
    }

    /// A click on a transcript line: seek there, start playing, and put the
    /// control in the shape that says so.
    private func seekPlayback(to time: TimeInterval) {
        playbackController.seek(to: time)
        if !playbackController.isPlaying {
            playbackController.togglePlayback()
        }
        fabState = .playing
    }

    /// Follows a citation to the words behind it.
    ///
    /// A search narrows the transcript to what it matched, so it is cleared
    /// first: a citation must land on its own line and not on an empty list.
    private func followCitation(segmentID: String) {
        transcriptQuery = ""
        select(.transcript)
        citationJumpCount += 1
        let jump = NoteCitationJump(sequence: citationJumpCount, segmentID: segmentID)

        citationFlashTask?.cancel()
        citationFlashTask = Task { @MainActor in
            // The transcript has to be on screen before a line inside it can be
            // scrolled to, and switching to it is what this call just asked for.
            try? await Task.sleep(for: .milliseconds(60))
            guard !Task.isCancelled else { return }
            citationJump = jump

            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            withAnimation(reduceMotion ? nil : AppTheme.Animation.normal) {
                citationJump = nil
            }
        }
    }

    /// Changes the name behind one speaker.
    ///
    /// The name a note shows for a speaker comes from the participant profile
    /// diarization matched, the same profile the Library detail page assigns. So
    /// a rename here is a rename of that profile: this transcript and every
    /// future note that matches the same voice read the new name.
    private func renameSpeakerProfile(profileID: UUID, name: String) {
        let service = SpeakerIdentityService(modelContext: modelContext)
        do {
            guard let profile = try service.fetchAllProfiles().first(where: { $0.id == profileID })
            else {
                errorMessage = localized(
                    "That speaker profile no longer exists. Try reopening this note.",
                    locale: locale
                )
                return
            }
            try service.renameProfile(profile, to: name)
            Task { await refreshViews() }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func ratePanel(_ feedback: CaptureNotePanelFeedback?) {
        guard let panel = currentPanel, panel.isRegenerable else { return }
        do {
            try captureSessionStore.setEnhancedPanelFeedback(
                panelID: panel.id,
                feedback: feedback
            )
            Task { await refreshViews() }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func startCapture(includeSystemAudio: Bool) {
        guard let onStartNoteCapture else { return }
        let accepted = onStartNoteCapture(
            NoteCaptureRequest(
                noteID: noteID,
                includeSystemAudio: includeSystemAudio,
                expectedSpeakerCount: expectedSpeakerCount
            )
        )
        if !accepted {
            errorMessage = localized(
                "Finish the active transcription before starting another one.",
                locale: locale
            )
        }
    }

    /// Starts one generation. `false` means nothing was started: there is no
    /// capture behind this note, or one generation is already running.
    @discardableResult
    private func regeneratePanel(templatePresetIdentifier: String?) -> Bool {
        guard let onGenerateEnhancedPanel,
              let sessionID = views?.captureState?.handle.sessionID,
              !isGeneratingPanel
        else {
            return false
        }
        isGeneratingPanel = true
        enhancementFailureMessage = nil
        Task { @MainActor in
            defer { isGeneratingPanel = false }
            let failure = await onGenerateEnhancedPanel(
                NoteEnhancementRequest(
                    sessionID: sessionID,
                    noteID: noteID,
                    templatePresetIdentifier: templatePresetIdentifier
                )
            )
            enhancementFailureMessage = failure
            await refreshViews()
        }
        return true
    }

    private func saveEnhancedPanelAsNote() {
        guard let panel = currentPanel else { return }
        let store = notesStore
        Task { @MainActor in
            do {
                _ = try await store.create(content: panel.content)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func deleteTranscript() {
        do {
            try captureSessionStore.deleteTranscript(noteID: noteID)
            if selection == .transcript {
                selection = .humanNotes
            }
            Task { await refreshViews() }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func deleteNote() {
        guard let currentNote else { return }
        do {
            try notesStore.delete(currentNote)
            onBack()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func addTag() {
        let trimmed = newTag.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty, !tags.contains(trimmed) {
            tags.append(trimmed)
        }
        newTag = ""
    }

    private func removeTag(_ tag: String) {
        tags.removeAll { $0 == tag }
    }

    // MARK: - Export

    private func currentViewText() -> String {
        switch resolvedSelection {
        case .humanNotes:
            content
        case .enhanced:
            currentPanel?.content ?? content
        case .transcript:
            views?.transcript?.plainText ?? ""
        }
    }

    private func exportSource() -> TranscriptExportService.ExportSource {
        let segments: [DiarizedTranscriptSegment]
        if resolvedSelection == .transcript, let transcript = views?.transcript {
            segments = transcript.segments.map { segment in
                DiarizedTranscriptSegment(
                    speakerId: segment.speakerKey ?? "",
                    speakerLabel: segment.speakerLabel ?? "",
                    speakerProfileID: segment.speakerProfileID,
                    startTime: segment.startOffset,
                    endTime: segment.endOffset,
                    confidence: 1,
                    text: segment.text
                )
            }
        } else {
            segments = []
        }
        return TranscriptExportService.ExportSource(
            text: currentViewText(),
            title: title.isEmpty ? nil : title,
            timestamp: note?.createdAt ?? Date(),
            segments: segments
        )
    }

    private func exportCurrentView(_ format: TranscriptExportFormat) {
        do {
            try TranscriptExportService.presentSavePanel(source: exportSource(), format: format)
        } catch TranscriptExportService.ExportError.cancelled {
            return
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Persistence (same arbitration as the pop-out editor)

    private func currentSnapshot() -> NoteSnapshot {
        NoteSnapshot(
            title: title.isEmpty ? "Untitled Note" : title,
            content: content,
            isPinned: currentNote?.isPinned ?? false,
            tags: tags
        )
    }

    private func noteDidChange() {
        let snapshot = currentSnapshot()
        guard snapshot != lastSavedSnapshot else { return }

        lastEditedAt = Date()
        // Capture the latest draft synchronously before the debounce so quit can
        // persist mid-debounce edits without relying on view lifecycle timing.
        if let noteToSave = currentNote {
            NoteEditorPersistenceController.shared.trackDraft(
                container: modelContext.container,
                modelID: noteToSave.persistentModelID,
                snapshot: snapshot,
                editedAt: lastEditedAt
            )
        }
        autosaveTask?.cancel()
        autosaveTask = Task { @MainActor in
            do {
                try await Task.sleep(for: .milliseconds(500))
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            saveNote(immediate: false)
        }
    }

    private func saveNote(immediate: Bool) {
        guard let noteToSave = currentNote else { return }
        let snapshot = currentSnapshot()
        guard snapshot != lastSavedSnapshot else {
            if immediate {
                let modelID = noteToSave.persistentModelID
                Task { @MainActor in
                    await NoteEditorPersistenceController.shared.flush(modelID: modelID)
                }
            }
            return
        }

        let modelID = noteToSave.persistentModelID
        let editedAt = lastEditedAt
        let container = modelContext.container
        lastSavedSnapshot = snapshot

        if immediate {
            Task { @MainActor in
                let result = await NoteEditorPersistenceController.shared.saveAndWait(
                    container: container,
                    modelID: modelID,
                    snapshot: snapshot,
                    editedAt: editedAt
                )
                handlePersistenceResult(result, snapshot: snapshot)
            }
        } else {
            let task = NoteEditorPersistenceController.shared.scheduleSave(
                container: container,
                modelID: modelID,
                snapshot: snapshot,
                editedAt: editedAt
            )
            Task { @MainActor in
                let result = await task.value
                handlePersistenceResult(result, snapshot: snapshot)
            }
        }
    }

    /// A save that never landed rolls back the optimistic snapshot, so the next
    /// keystroke schedules the write again instead of assuming it is durable.
    private func handlePersistenceResult(
        _ result: NotePersistenceResult?,
        snapshot: NoteSnapshot
    ) {
        guard result == nil else { return }
        if lastSavedSnapshot == snapshot {
            lastSavedSnapshot = nil
        }
    }

    private func saveNow() {
        autosaveTask?.cancel()
        saveNote(immediate: true)
        flashConfirmation(localized("Saved", locale: locale))
    }

    /// Navigating away is a close: enqueue the newest draft, then await it.
    private func flushOnLeaving() {
        guard let noteToSave = currentNote else { return }
        let modelID = noteToSave.persistentModelID
        let snapshot = currentSnapshot()
        if snapshot != lastSavedSnapshot {
            lastSavedSnapshot = snapshot
            _ = NoteEditorPersistenceController.shared.scheduleSave(
                container: modelContext.container,
                modelID: modelID,
                snapshot: snapshot,
                editedAt: lastEditedAt
            )
        }
        Task { @MainActor in
            await NoteEditorPersistenceController.shared.flush(modelID: modelID)
        }
    }

    private func scheduleWordCountUpdate(for text: String) {
        wordCountTask?.cancel()
        wordCountTask = Task { @MainActor in
            do {
                try await Task.sleep(for: .milliseconds(120))
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            let count = text.wordCount
            if displayedWordCount != count {
                displayedWordCount = count
            }
        }
    }

    /// One word in the footer, for a second and a half. Saving and copying both
    /// use it, so a confirmation always lands in the same place.
    private func flashConfirmation(_ message: String) {
        confirmationTask?.cancel()
        withAnimation(reduceMotion ? nil : AppTheme.Animation.fast) {
            confirmationMessage = message
        }
        confirmationTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled else { return }
            withAnimation(reduceMotion ? nil : AppTheme.Animation.fast) {
                confirmationMessage = nil
            }
        }
    }
}

// MARK: - Transcript views

/// The finished transcript, with the turn playback is inside marked.
///
/// The active turn is derived here and not on the page: the playback clock ticks
/// four times a second, and the page around this view holds a text editor.
private struct NoteTranscriptTurns: View {
    let presentation: TranscriptListPresentation
    let controller: MediaPlaybackController
    let canSeek: Bool
    /// The span a citation was followed to, if one was.
    var flashingSegmentID: String?
    /// Seeking is the page's job: a click has to start playback and change the
    /// shape of the floating control, not only move the clock.
    var onSeek: ((TimeInterval) -> Void)?

    /// One linear scan per playback tick. Spans can overlap when people talk
    /// over each other, so "the first turn containing t" is the right pick.
    private var activeTurnID: String? {
        let time = controller.currentTime
        // Nothing is "playing now" at a standstill at zero, so nothing is marked.
        guard canSeek, time > 0 else { return nil }
        return presentation.turns.last { $0.startOffset <= time }?.id
    }

    var body: some View {
        TranscriptSegmentList(
            presentation: presentation,
            activeTurnID: activeTurnID,
            canSeek: canSeek,
            onSeek: onSeek,
            flashingSegmentID: flashingSegmentID
        )
    }
}

/// The live transcript, in the page's own column.
///
/// Its own view so the live text, which changes several times a second,
/// invalidates these lines instead of the whole page.
private struct LiveTranscriptLines: View {
    @Environment(\.locale) private var locale

    let state: NoteCaptureState?

    private var lines: [TranscriptLiveLine] {
        TranscriptSegmentPresentation.liveLines(
            committed: state?.liveTranscript ?? "",
            tentative: state?.liveTentativeTranscript ?? ""
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if lines.isEmpty {
                Text(localized("The transcript starts once you speak.", locale: locale))
                    .font(AppTypography.body)
                    .foregroundStyle(AppColors.textSecondary)
            } else {
                ForEach(lines) { line in
                    TranscriptLiveLineText(line: line)
                }
            }
        }
        .frame(maxWidth: 640, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Preview

#Preview("Note page") {
    NotePageView(noteID: UUID(), onBack: {})
        .modelContainer(PreviewContainer.withSampleNotes)
        .frame(width: 900, height: 640)
}
