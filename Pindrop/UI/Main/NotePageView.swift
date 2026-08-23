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
    let onGenerateEnhancedPanel: NoteEnhancementHandler?

    init(
        noteID: UUID,
        onBack: @escaping () -> Void,
        noteCaptureState: NoteCaptureState? = nil,
        onStartNoteCapture: ((NoteCaptureRequest) -> Bool)? = nil,
        onFinishNoteCapture: (() -> Void)? = nil,
        onGenerateEnhancedPanel: NoteEnhancementHandler? = nil
    ) {
        self.noteID = noteID
        self.onBack = onBack
        self.noteCaptureState = noteCaptureState
        self.onStartNoteCapture = onStartNoteCapture
        self.onFinishNoteCapture = onFinishNoteCapture
        self.onGenerateEnhancedPanel = onGenerateEnhancedPanel
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
    @State private var showSavedConfirmation = false
    @State private var savedConfirmationTask: Task<Void, Never>?

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
    @State private var errorMessage: String?

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
            hasUnreadEnhanced: hasUnreadEnhanced
        )
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
        VStack(spacing: 0) {
            ScrollView(.vertical, showsIndicators: true) {
                VStack(alignment: .leading, spacing: 24) {
                    headerRail
                    titleField
                    metaChipRow
                    canvas
                }
                .frame(maxWidth: canvasMaxWidth, alignment: .leading)
                .padding(.horizontal, 40)
                .padding(.top, 40)
                .padding(.bottom, 16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            captureDock
                .frame(maxWidth: canvasMaxWidth, alignment: .leading)
                .padding(.horizontal, 40)
                .frame(maxWidth: .infinity, alignment: .leading)

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
        }
        .onChange(of: title) { _, _ in noteDidChange() }
        .onChange(of: content) { _, newValue in
            scheduleWordCountUpdate(for: newValue)
            noteDidChange()
        }
        .onChange(of: tags) { _, _ in noteDidChange() }
        .onDisappear {
            autosaveTask?.cancel()
            wordCountTask?.cancel()
            savedConfirmationTask?.cancel()
            flushOnLeaving()
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
        .background {
            Button(action: saveNow) { EmptyView() }
                .keyboardShortcut("s", modifiers: .command)
                .opacity(0)
                .frame(width: 0, height: 0)
                .allowsHitTesting(false)
        }
    }

    // MARK: - Header rail

    private var headerRail: some View {
        HStack(spacing: 10) {
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
                Image(systemName: "chevron.left")
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

            Button(localized("Copy Content", locale: locale)) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(currentViewText(), forType: .string)
            }

            Divider()

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

    private var titleField: some View {
        TextField(localized("Note Title", locale: locale), text: $title)
            .font(AppTypography.pageTitle)
            .tracking(AppTypography.pageTitleTracking)
            .foregroundStyle(AppColors.textPrimary)
            .textFieldStyle(.plain)
            .focused($titleFieldFocused)
            .padding(.leading, textColumnInset)
            .accessibilityIdentifier("note.page.title")
    }

    // MARK: - Meta chips

    private var metaChipRow: some View {
        HStack(spacing: 8) {
            if NotePagePresentation.isToggleVisible(state: pageState, locale: locale) {
                viewToggle
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

    private var viewToggle: some View {
        SegmentedViewToggle(
            segments: NotePagePresentation.segments(state: pageState, locale: locale).map { segment in
                SegmentedViewToggle<CaptureNoteViewKind>.Segment(
                    value: segment.kind,
                    title: NotePagePresentation.viewTitle(segment.kind, locale: locale),
                    isEnabled: segment.isEnabled,
                    helpText: segment.helpText,
                    indicator: segment.indicator.map { indicator in
                        switch indicator {
                        case .live: .live
                        case .ready: .ready
                        }
                    },
                    accessibilityIdentifier: NotePagePresentation.accessibilityIdentifier(segment.kind)
                )
            },
            selection: resolvedSelection,
            onSelect: select
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

    private var speakersChip: some View {
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
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .overlay(Capsule(style: .continuous).strokeBorder(AppColors.border, lineWidth: 1))
        .disabled(capturePhase.isActive)
        .help(capturePhase.isActive
              ? localized("Speakers are set when the recording starts.", locale: locale)
              : "")
        .accessibilityIdentifier("note.page.speakers")
    }

    private var speakersChipTitle: String {
        guard let expectedSpeakerCount else {
            return String(
                format: localized("Speakers: %1$@", locale: locale),
                localized("Auto", locale: locale)
            )
        }
        return String(
            format: localized("Speakers: %1$@", locale: locale),
            "\(expectedSpeakerCount)"
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

    @ViewBuilder
    private var enhancedCanvas: some View {
        if let panel = currentPanel {
            VStack(alignment: .leading, spacing: 0) {
                RenderedMarkdownText(markdown: panel.content)
            }
            .padding(.leading, textColumnInset)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityIdentifier("note.page.enhanced")
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
                        title: isGeneratingPanel
                            ? localized("Writing note", locale: locale)
                            : localized("Generate enhanced note", locale: locale),
                        systemImage: "sparkles",
                        action: { regeneratePanel(templatePresetIdentifier: nil) }
                    )
                    .disabled(isGeneratingPanel)
                    .accessibilityIdentifier("note.page.enhanced.generate")
                }
            }
            .padding(.leading, textColumnInset)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private var transcriptCanvas: some View {
        if let transcript = views?.transcript, !transcript.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(TranscriptTurn.turns(in: transcript.segments)) { turn in
                    transcriptTurnView(turn)
                }
            }
            .padding(.leading, textColumnInset)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityIdentifier("note.page.transcript")
        } else {
            Text(localized("Nothing was transcribed yet.", locale: locale))
                .font(AppTypography.body)
                .foregroundStyle(AppColors.textSecondary)
                .padding(.leading, textColumnInset)
        }
    }

    private func transcriptTurnView(_ turn: TranscriptTurn) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Circle()
                    .fill(turn.isCurrentUser
                          ? AppColors.accent
                          : LibrarySpeakerColor.color(for: turn.speakerKey))
                    .frame(width: 8, height: 8)

                Text(turn.displayName(locale: locale))
                    .font(AppTypography.labelSemibold)
                    .foregroundStyle(AppColors.textPrimary)

                Text(NoteRowPresentation.elapsedText(turn.startOffset))
                    .font(AppTypography.monoSmall)
                    .foregroundStyle(AppColors.textTertiary)
                    .monospacedDigit()
                    .environment(\.layoutDirection, .leftToRight)
            }

            Text(turn.text)
                .font(FontLoader.font(family: .newsreader, size: 15))
                .lineSpacing(7)
                .foregroundStyle(AppColors.textSecondary)
                .textSelection(.enabled)
                .frame(maxWidth: 640, alignment: .leading)
                .padding(.leading, 16)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Capture dock

    @ViewBuilder
    private var captureDock: some View {
        if NotePagePresentation.showsCaptureStrip(state: pageState) {
            // One second-by-second tick drives both the capture bar's clock and
            // the finalizing row's, so neither shows a frozen time.
            TimelineView(.periodic(from: noteCaptureState?.startedAt ?? .now, by: 1)) { context in
                captureDockContent(now: context.date)
            }
            .padding(.bottom, 12)
        }
    }

    @ViewBuilder
    private func captureDockContent(now: Date) -> some View {
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
            captureBar(elapsed: elapsed ?? "00:00")
        }
    }

    private func captureBar(elapsed: String) -> some View {
        HStack(spacing: 12) {
            Circle()
                .fill(AppColors.recording)
                .frame(width: 8, height: 8)

            Text(elapsed)
                .font(AppTypography.monoTime)
                .foregroundStyle(AppColors.textPrimary)
                .monospacedDigit()
                .environment(\.layoutDirection, .leftToRight)

            Text(liveTranscriptLine)
                .font(FontLoader.font(family: .newsreader, size: 14))
                .foregroundStyle(AppColors.textSecondary)
                .lineLimit(1)
                .truncationMode(.head)
                .frame(maxWidth: .infinity, alignment: .leading)

            PrimaryButton(
                title: localized("Finish", locale: locale),
                action: { onFinishNoteCapture?() }
            )
            .accessibilityIdentifier("note.page.capture.finish")
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 16)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(AppColors.windowBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(AppColors.border, lineWidth: 1)
        )
        .accessibilityIdentifier("note.page.capture.bar")
    }

    private var liveTranscriptLine: String {
        guard let noteCaptureState else { return "" }
        if noteCaptureState.isLiveTranscriptDegraded {
            return localized(
                "Live text stopped. The recording continues.",
                locale: locale
            )
        }
        let text = noteCaptureState.liveTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty
            ? localized("Listening…", locale: locale)
            : text
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

            if showSavedConfirmation {
                Text(localized("Saved", locale: locale))
                    .font(AppTypography.caption)
                    .foregroundStyle(AppColors.accent)
                    .transition(.opacity)
            }

            if let trailing = line.trailing {
                Text(trailing)
                    .font(AppTypography.monoSmall)
                    .foregroundStyle(AppColors.textTertiary)
                    .onTapGesture { saveNow() }
                    .help(localized("Save now (⌘S)", locale: locale))
            }
        }
        .padding(.horizontal, 40)
        .frame(height: 40)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(AppColors.border)
                .frame(height: 1)
        }
        .appAnimation(.fast, value: showSavedConfirmation)
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

        if let stored = views?.selectedView {
            selection = stored.kind
            selectedTemplateIdentifier = stored.templatePresetIdentifier
        }
        lastSeenPanelID = views?.panels.first?.id
        hasUnreadEnhanced = false
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
        } catch {
            Log.ui.error("Failed to read note views: \(error.localizedDescription)")
        }
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
        do {
            try captureSessionStore.selectView(noteID: noteID, selection: stored)
        } catch {
            Log.ui.error("Failed to remember the note view: \(error.localizedDescription)")
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

    private func regeneratePanel(templatePresetIdentifier: String?) {
        guard let onGenerateEnhancedPanel,
              let sessionID = views?.captureState?.handle.sessionID,
              !isGeneratingPanel
        else {
            return
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
        showSavedFlash()
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

    private func showSavedFlash() {
        savedConfirmationTask?.cancel()
        withAnimation(reduceMotion ? nil : AppTheme.Animation.fast) {
            showSavedConfirmation = true
        }
        savedConfirmationTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled else { return }
            withAnimation(reduceMotion ? nil : AppTheme.Animation.fast) {
                showSavedConfirmation = false
            }
        }
    }
}

// MARK: - Transcript turns

/// Consecutive spans of one speaker, read as one turn.
struct TranscriptTurn: Identifiable, Equatable {
    let id: String
    let speakerKey: String
    let speakerLabel: String?
    let speakerNumber: Int?
    let isCurrentUser: Bool
    let startOffset: TimeInterval
    let text: String

    func displayName(locale: Locale) -> String {
        if isCurrentUser {
            return localized("You", locale: locale)
        }
        if let speakerNumber {
            return String(format: localized("Speaker %d", locale: locale), speakerNumber)
        }
        if let speakerLabel, !speakerLabel.isEmpty {
            return speakerLabel
        }
        return localized("Speaker", locale: locale)
    }

    /// Groups a transcript into turns. Same speaker back to back reads as one
    /// person talking, not as several disconnected lines.
    static func turns(in segments: [TranscriptSegmentSnapshot]) -> [TranscriptTurn] {
        var turns: [TranscriptTurn] = []
        for segment in segments {
            let key = segment.speakerKey ?? "_"
            if var last = turns.last, last.speakerKey == key {
                last = TranscriptTurn(
                    id: last.id,
                    speakerKey: last.speakerKey,
                    speakerLabel: last.speakerLabel,
                    speakerNumber: last.speakerNumber,
                    isCurrentUser: last.isCurrentUser,
                    startOffset: last.startOffset,
                    text: last.text + "\n" + segment.text
                )
                turns[turns.count - 1] = last
                continue
            }
            turns.append(
                TranscriptTurn(
                    id: segment.id,
                    speakerKey: key,
                    speakerLabel: segment.speakerLabel,
                    speakerNumber: segment.speakerNumber,
                    isCurrentUser: segment.isCurrentUser,
                    startOffset: segment.startOffset,
                    text: segment.text
                )
            )
        }
        return turns
    }
}

// MARK: - Read-only markdown

/// Minimal read-only rendering of generated markdown: headings, bullets, and
/// paragraphs. WP6 replaces this with the citation-aware enhanced view.
struct RenderedMarkdownText: View {
    let markdown: String

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                block.view
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private struct Block: Identifiable {
        let id = UUID()
        let line: MarkdownLine
        let text: String

        @ViewBuilder
        var view: some View {
            switch line.kind {
            case .blank:
                Color.clear.frame(height: 10)
            case .heading:
                Text(text)
                    .font(FontLoader.font(family: .newsreader, size: 20, weight: .medium))
                    .lineSpacing(6)
                    .foregroundStyle(AppColors.textPrimary)
                    .padding(.top, 10)
                    .padding(.bottom, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
            case .bullet(let level), .task(let level, _):
                HStack(alignment: .firstTextBaseline, spacing: 0) {
                    Text(level.isMultiple(of: 2) ? "◦" : "•")
                        .font(AppTypography.body)
                        .foregroundStyle(AppColors.textTertiary)
                        .frame(width: 14, alignment: .leading)
                    Text(text)
                        .font(AppTypography.body)
                        .lineSpacing(8)
                        .foregroundStyle(AppColors.textPrimary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.leading, CGFloat(level - 1) * 20)
                .padding(.bottom, 4)
            case .ordered(let level, let marker):
                HStack(alignment: .firstTextBaseline, spacing: 0) {
                    Text(marker)
                        .font(AppTypography.body)
                        .foregroundStyle(AppColors.textTertiary)
                        .frame(width: 20, alignment: .leading)
                    Text(text)
                        .font(AppTypography.body)
                        .lineSpacing(8)
                        .foregroundStyle(AppColors.textPrimary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.leading, CGFloat(level - 1) * 20)
                .padding(.bottom, 4)
            case .quote:
                Text(text)
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
                Text(text)
                    .font(AppTypography.monoSmall)
                    .foregroundStyle(AppColors.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            case .paragraph:
                Text(text)
                    .font(AppTypography.body)
                    .lineSpacing(8)
                    .foregroundStyle(AppColors.textPrimary)
                    .textSelection(.enabled)
                    .padding(.bottom, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var blocks: [Block] {
        let nsText = markdown as NSString
        return MarkdownBlockGrammar.lines(in: markdown).map { line in
            Block(line: line, text: nsText.substring(with: line.contentRange))
        }
    }
}

// MARK: - Preview

#Preview("Note page") {
    NotePageView(noteID: UUID(), onBack: {})
        .modelContainer(PreviewContainer.withSampleNotes)
        .frame(width: 900, height: 640)
}
