//
//  NotePagePresentation.swift
//  Pindrop
//
//  Created on 2026-08-22.
//
//  What the note page shows, decided once and tested without a window.
//
//  The page has three views and one capture that can be in any of six phases,
//  which is more combinations than a `body` should be trusted to get right. Every
//  question with a right answer lives here as a pure function of what exists:
//  which segments are offered, which are ready, which actions the header can run,
//  and what the footer says. The view reads the answers and draws them.
//
//  One rule outranks the rest: nothing here ever changes the selected view. A
//  finished enhancement wears a dot and waits.
//

import Foundation
import PindropCore

// MARK: - Capture phase

/// The named work a finalizing capture is doing, as the page draws it.
enum NotePageFinalizationStage: String, Equatable, Sendable, CaseIterable {
    case sealingAudio
    case transcribing
    case diarizing
    case assembling
}

/// The capture attached to the note being shown, reduced to what the page draws.
enum NotePageCapturePhase: Equatable, Sendable {
    /// No capture is attached to this note right now.
    case none
    case starting
    case capturing
    case finalizing(NotePageFinalizationStage, progress: Double?)
    case enhancing
    /// The capture itself failed. The typed notes are still on screen.
    case failed

    /// True while the capture still owns the note's recording lifecycle.
    var isActive: Bool {
        switch self {
        case .starting, .capturing, .finalizing, .enhancing:
            true
        case .none, .failed:
            false
        }
    }

    /// True while audio is being recorded.
    var isRecording: Bool {
        switch self {
        case .starting, .capturing:
            true
        case .none, .finalizing, .enhancing, .failed:
            false
        }
    }

    var finalizationStage: NotePageFinalizationStage? {
        guard case .finalizing(let stage, _) = self else { return nil }
        return stage
    }

    var finalizationProgress: Double? {
        guard case .finalizing(_, let progress) = self else { return nil }
        return progress
    }
}

// MARK: - Page state

/// Everything the page's chrome depends on, as plain values.
struct NotePageState: Equatable, Sendable {
    /// At least one enhanced panel exists and can be read.
    var hasPanels: Bool
    /// A transcript exists and has not been deleted.
    var hasTranscript: Bool
    /// The person deleted the transcript. The view is hidden entirely.
    var isTranscriptDeleted: Bool
    /// A capture ever ran for this note, finished or not.
    var isRecorded: Bool
    var capture: NotePageCapturePhase
    /// An enhanced panel finished and has not been opened yet.
    var hasUnreadEnhanced: Bool
    /// The running capture has heard words. The transcript view can be opened on
    /// them before any of it is durable.
    var hasLiveText: Bool

    init(
        hasPanels: Bool = false,
        hasTranscript: Bool = false,
        isTranscriptDeleted: Bool = false,
        isRecorded: Bool = false,
        capture: NotePageCapturePhase = .none,
        hasUnreadEnhanced: Bool = false,
        hasLiveText: Bool = false
    ) {
        self.hasPanels = hasPanels
        self.hasTranscript = hasTranscript
        self.isTranscriptDeleted = isTranscriptDeleted
        self.isRecorded = isRecorded
        self.capture = capture
        self.hasUnreadEnhanced = hasUnreadEnhanced
        self.hasLiveText = hasLiveText
    }

    /// A plain typed note: nothing was ever recorded into it.
    static let plainNote = NotePageState()
}

/// The dot a segment carries.
enum NotePageSegmentIndicator: Equatable, Sendable {
    case live
    case ready
}

/// One segment of the view toggle.
struct NotePageSegment: Equatable, Sendable, Identifiable {
    let kind: CaptureNoteViewKind
    let isEnabled: Bool
    let indicator: NotePageSegmentIndicator?
    /// Why the segment cannot be picked yet.
    let helpText: String?

    var id: CaptureNoteViewKind { kind }
}

/// One chip of the Round B view switcher: a segment, plus what the chip draws.
struct NoteViewChipState: Equatable, Sendable, Identifiable {
    let kind: CaptureNoteViewKind
    let isEnabled: Bool
    let indicator: NotePageSegmentIndicator?
    /// Why the chip cannot be picked yet.
    let helpText: String?
    /// This chip is the view on screen.
    let isSelected: Bool
    /// Clicking the chip opens the Enhanced dropdown instead of switching view.
    /// Only ever true for the selected Enhanced chip.
    let opensMenu: Bool
    let systemImage: String

    var id: CaptureNoteViewKind { kind }
}

// MARK: - Speakers popover

/// One speaker of a finished transcript, as the popover lists them.
///
/// There is no separate "you" caption: the transcript already names the person
/// recording "You", so a caption saying the same word beside it would only be
/// noise. The accent dot marks the row for readers who skim the colors.
struct NoteSpeakerRow: Equatable, Sendable, Identifiable {
    /// The speaker key the transcript groups turns by.
    let id: String
    let name: String
    let isCurrentUser: Bool
    /// The participant profile that named this speaker, when one did. A speaker
    /// with no profile carries a generic number that nothing durable can rename.
    let profileID: UUID?

    /// A name can only be changed where a profile owns it.
    var canRename: Bool { profileID != nil }
}

/// The "n speakers" popover, decided once.
struct NoteSpeakersPopoverContent: Equatable, Sendable {
    let title: String
    /// Total recording length, in the mono slot beside the overline.
    let durationText: String
    let rows: [NoteSpeakerRow]
    let caption: String
}

/// What the header rail can offer.
struct NotePageHeaderActions: Equatable, Sendable {
    /// Shown only when no capture is attached to this note.
    var showsRecordButton: Bool
    /// Reserved for WP8. Always present in the menu, always disabled here, so
    /// the menu does not change shape when the pop-out lands.
    var canOpenInNewWindow: Bool
    /// A generated panel is on screen and can be copied into a note of its own.
    var canSaveAsNote: Bool
    var canDeleteTranscript: Bool
    var canDeleteNote: Bool
    /// The recording can still be thrown away. There is no pause in v1, so Cancel
    /// is the only other way out of a capture besides Finish, and it lives in the
    /// overflow menu where it cannot be hit by accident.
    var canCancelCapture: Bool
}

/// The footer line under the canvas.
struct NotePageFooter: Equatable, Sendable {
    let leading: String
    /// The right-hand hint. Only the editable view has one.
    let trailing: String?
}

/// Numbers the footer needs that only the live note knows.
struct NotePageFooterFacts: Equatable, Sendable {
    var wordCount: Int
    var editedAt: Date
    var panelGeneratedAt: Date?
    var panelTemplateName: String?
    var transcriptDuration: TimeInterval
    var transcriptSpeakerCount: Int
    var isTranscriptLive: Bool

    init(
        wordCount: Int = 0,
        editedAt: Date = Date(),
        panelGeneratedAt: Date? = nil,
        panelTemplateName: String? = nil,
        transcriptDuration: TimeInterval = 0,
        transcriptSpeakerCount: Int = 0,
        isTranscriptLive: Bool = false
    ) {
        self.wordCount = wordCount
        self.editedAt = editedAt
        self.panelGeneratedAt = panelGeneratedAt
        self.panelTemplateName = panelTemplateName
        self.transcriptDuration = transcriptDuration
        self.transcriptSpeakerCount = transcriptSpeakerCount
        self.isTranscriptLive = isTranscriptLive
    }
}

// MARK: - Presentation

enum NotePagePresentation {

    // MARK: Segments

    /// The toggle segments, in order. My notes is always one of them: it exists
    /// before a capture produces anything.
    static func segments(state: NotePageState, locale: Locale) -> [NotePageSegment] {
        var segments: [NotePageSegment] = [
            NotePageSegment(kind: .humanNotes, isEnabled: true, indicator: nil, helpText: nil)
        ]

        if state.hasPanels || state.isRecorded || state.capture.isActive {
            let isEnabled = state.hasPanels && !state.capture.isActive
            segments.append(
                NotePageSegment(
                    kind: .enhanced,
                    isEnabled: isEnabled,
                    indicator: state.hasPanels && state.hasUnreadEnhanced ? .ready : nil,
                    helpText: isEnabled ? nil : enhancedHelpText(state: state, locale: locale)
                )
            )
        }

        if !state.isTranscriptDeleted, state.hasTranscript || state.capture.isRecording {
            // A recording that has already been heard can be read live, before
            // any of it is durable. Nothing said yet means nothing to open.
            let isReadable = state.hasTranscript
                || (state.capture.isRecording && state.hasLiveText)
            segments.append(
                NotePageSegment(
                    kind: .transcript,
                    isEnabled: isReadable,
                    indicator: state.capture.isRecording ? .live : nil,
                    helpText: isReadable
                        ? nil
                        : localized("The transcript starts once you speak.", locale: locale)
                )
            )
        }

        return segments
    }

    /// A note with nothing but typed text shows no toggle at all.
    static func isToggleVisible(state: NotePageState, locale: Locale) -> Bool {
        segments(state: state, locale: locale).count > 1
    }

    // MARK: Chips

    /// The chips, in segment order.
    ///
    /// `canOpenEnhancedMenu` is the one thing the chips cannot work out for
    /// themselves: a legacy panel has no templates to offer, so its chip stays a
    /// plain switch with no chevron and no dropdown.
    static func chips(
        state: NotePageState,
        selection: CaptureNoteViewKind,
        canOpenEnhancedMenu: Bool = false,
        locale: Locale
    ) -> [NoteViewChipState] {
        segments(state: state, locale: locale).map { segment in
            let isSelected = segment.kind == selection && segment.isEnabled
            return NoteViewChipState(
                kind: segment.kind,
                isEnabled: segment.isEnabled,
                indicator: segment.indicator,
                helpText: segment.helpText,
                isSelected: isSelected,
                opensMenu: segment.kind == .enhanced && isSelected && canOpenEnhancedMenu,
                systemImage: chipIcon(segment.kind)
            )
        }
    }

    /// Round B glyphs: text lines, sparkle, microphone.
    static func chipIcon(_ kind: CaptureNoteViewKind) -> String {
        switch kind {
        case .humanNotes: "text.alignleft"
        case .enhanced: "sparkles"
        case .transcript: "mic"
        }
    }

    // MARK: Speakers

    /// What the speakers chip reads.
    ///
    /// A finished transcript knows how many people it heard, so it says so.
    /// Before that there is only the count the person asked for, or none.
    static func speakersChipTitle(
        speakerCount: Int,
        expectedSpeakerCount: Int?,
        locale: Locale
    ) -> String {
        if speakerCount > 0 {
            return speakerCountLabel(speakerCount, locale: locale)
        }
        let value = expectedSpeakerCount.map(String.init)
            ?? localized("Auto", locale: locale)
        return String(format: localized("Speakers: %1$@", locale: locale), value)
    }

    /// The speakers behind a transcript, in the order they were first heard.
    static func speakersPopover(
        segments: [TranscriptSegmentSnapshot],
        duration: TimeInterval,
        locale: Locale
    ) -> NoteSpeakersPopoverContent {
        var rows: [NoteSpeakerRow] = []
        var seen: Set<String> = []
        for segment in segments {
            let key = segment.speakerKey ?? "_"
            guard !seen.contains(key) else { continue }
            seen.insert(key)
            rows.append(
                NoteSpeakerRow(
                    id: key,
                    name: TranscriptSegmentPresentation.speakerName(
                        isCurrentUser: segment.isCurrentUser,
                        speakerNumber: segment.speakerNumber,
                        speakerLabel: segment.speakerLabel,
                        locale: locale
                    ),
                    isCurrentUser: segment.isCurrentUser,
                    profileID: segment.speakerProfileID
                )
            )
        }
        return NoteSpeakersPopoverContent(
            title: localized("Speakers", locale: locale),
            durationText: NoteRowPresentation.elapsedText(duration),
            rows: rows,
            caption: localized(
                "Detected from the recording. Renames apply to the transcript and future notes.",
                locale: locale
            )
        )
    }

    /// Why a generic speaker cannot be renamed here.
    static func renameUnavailableHelpText(locale: Locale) -> String {
        localized(
            "Pindrop did not match this voice to a saved speaker, so there is no name to change yet.",
            locale: locale
        )
    }

    /// The view to draw, given the one the person picked.
    ///
    /// A picked view that no longer exists (its panel was never generated, its
    /// transcript was deleted) falls back to the typed notes rather than drawing
    /// nothing. Falling back is not switching: nothing here reacts to a view
    /// becoming *available*.
    static func resolvedKind(
        requested: CaptureNoteViewKind,
        state: NotePageState,
        locale: Locale
    ) -> CaptureNoteViewKind {
        let available = segments(state: state, locale: locale)
        guard let match = available.first(where: { $0.kind == requested }), match.isEnabled else {
            return .humanNotes
        }
        return match.kind
    }

    private static func enhancedHelpText(state: NotePageState, locale: Locale) -> String {
        if state.capture.isRecording {
            return localized("Available when the recording is finished", locale: locale)
        }
        if state.capture.isActive {
            return localized("Writing your enhanced note.", locale: locale)
        }
        return localized("No enhanced note yet.", locale: locale)
    }

    // MARK: Header

    static func headerActions(state: NotePageState, selection: CaptureNoteViewKind) -> NotePageHeaderActions {
        NotePageHeaderActions(
            // A failed capture is over: the person can start another one.
            showsRecordButton: !state.capture.isActive,
            canOpenInNewWindow: false,
            canSaveAsNote: state.hasPanels && selection == .enhanced,
            canDeleteTranscript: state.hasTranscript && !state.isTranscriptDeleted,
            canDeleteNote: true,
            // Only while audio is still being recorded: once finalization owns
            // the capture, the recording exists and Finish already happened.
            canCancelCapture: state.capture.isRecording
        )
    }

    /// What Cancel throws away, said plainly enough to decide by.
    static func cancelCaptureMessage(locale: Locale) -> String {
        localized(
            "The audio and the live transcript are deleted. Your typed notes stay.",
            locale: locale
        )
    }

    /// The capture strip is drawn only while a capture is running for this note.
    static func showsCaptureStrip(state: NotePageState) -> Bool {
        state.capture.isActive
    }

    // MARK: Transcript view

    /// While the recording runs, the transcript view draws the live text. The
    /// durable spans, with their timings and speakers, only exist afterwards.
    static func isTranscriptLive(state: NotePageState) -> Bool {
        state.capture.isRecording
    }

    /// Searching needs a finished transcript: live text has no spans to filter
    /// and grows under the reader's hands.
    static func showsTranscriptSearch(
        state: NotePageState,
        selection: CaptureNoteViewKind
    ) -> Bool {
        selection == .transcript && state.hasTranscript && !isTranscriptLive(state: state)
    }

    /// The playback bar needs a finished transcript and a file to play.
    static func showsPlaybackBar(
        state: NotePageState,
        selection: CaptureNoteViewKind,
        hasPlayableAudio: Bool
    ) -> Bool {
        hasPlayableAudio && showsTranscriptSearch(state: state, selection: selection)
    }

    // MARK: Footer

    static func footer(
        kind: CaptureNoteViewKind,
        state: NotePageState,
        facts: NotePageFooterFacts,
        now: Date = Date(),
        locale: Locale
    ) -> NotePageFooter {
        switch kind {
        case .humanNotes:
            let words = wordCountLabel(facts.wordCount, locale: locale)
            let edited = NotesDateFormatting.compactRelative(
                from: facts.editedAt,
                now: now,
                locale: locale
            )
            return NotePageFooter(
                leading: String(
                    format: localized("%1$@ · edited %2$@", locale: locale),
                    words,
                    edited
                ),
                trailing: localized("⌘S to save", locale: locale)
            )

        case .enhanced:
            guard let generatedAt = facts.panelGeneratedAt else {
                return NotePageFooter(
                    leading: localized("No enhanced note yet.", locale: locale),
                    trailing: nil
                )
            }
            let generated = NotesDateFormatting.compactRelative(
                from: generatedAt,
                now: now,
                locale: locale
            )
            guard let template = facts.panelTemplateName, !template.isEmpty else {
                return NotePageFooter(
                    leading: String(
                        format: localized("Generated %@", locale: locale),
                        generated
                    ),
                    trailing: nil
                )
            }
            return NotePageFooter(
                leading: String(
                    format: localized("Generated %1$@ · %2$@ template", locale: locale),
                    generated,
                    template
                ),
                trailing: nil
            )

        case .transcript:
            // A running recording is live whether or not the store has caught up
            // with it, so the footer never claims a length for a transcript that
            // is still growing.
            if facts.isTranscriptLive || isTranscriptLive(state: state) {
                return NotePageFooter(
                    leading: localized("The transcript fills in as you speak.", locale: locale),
                    trailing: nil
                )
            }
            let length = NoteRowPresentation.elapsedText(facts.transcriptDuration)
            guard facts.transcriptSpeakerCount > 0 else {
                return NotePageFooter(
                    leading: String(
                        format: localized("%1$@ recording", locale: locale),
                        length
                    ),
                    trailing: nil
                )
            }
            return NotePageFooter(
                leading: String(
                    format: localized("%1$@ recording · %2$@", locale: locale),
                    length,
                    speakerCountLabel(facts.transcriptSpeakerCount, locale: locale)
                ),
                trailing: nil
            )
        }
    }

    static func wordCountLabel(_ count: Int, locale: Locale) -> String {
        if count == 1 {
            return localized("1 word", locale: locale)
        }
        return String(format: localized("%d words", locale: locale), locale: locale, count)
    }

    static func speakerCountLabel(_ count: Int, locale: Locale) -> String {
        if count == 1 {
            return localized("1 speaker", locale: locale)
        }
        return String(format: localized("%d speakers", locale: locale), locale: locale, count)
    }

    // MARK: Finalizing copy

    /// Stage vocabulary mirrors `MediaTranscriptionStage`, so the same work is
    /// named the same way wherever it is shown.
    static func stageTitle(_ stage: NotePageFinalizationStage, locale: Locale) -> String {
        switch stage {
        case .sealingAudio:
            localized("Sealing audio", locale: locale)
        case .transcribing:
            localized("Transcribing", locale: locale)
        case .diarizing:
            localized("Identifying speakers", locale: locale)
        case .assembling:
            localized("Writing note", locale: locale)
        }
    }

    /// What already finished, so a long finalization shows progress rather than
    /// one unchanging word.
    static func completedStages(before stage: NotePageFinalizationStage, locale: Locale) -> String? {
        switch stage {
        case .sealingAudio:
            nil
        case .transcribing:
            localized("Audio sealed", locale: locale)
        case .diarizing:
            localized("Transcription done", locale: locale)
        case .assembling:
            localized("Speakers identified", locale: locale)
        }
    }

    static func finalizingCaption(locale: Locale) -> String {
        localized(
            "Writing your enhanced note comes next. Long recordings can take a few minutes. You can keep typing.",
            locale: locale
        )
    }

    static func enhancedReadyMessage(locale: Locale) -> String {
        localized("Your enhanced note is ready.", locale: locale)
    }

    // MARK: Titles

    static func viewTitle(_ kind: CaptureNoteViewKind, locale: Locale) -> String {
        switch kind {
        case .humanNotes:
            localized("My notes", locale: locale)
        case .enhanced:
            localized("Enhanced", locale: locale)
        case .transcript:
            localized("Transcript", locale: locale)
        }
    }

    /// Stable identifiers so CI UI tests can find the toggle segments.
    static func accessibilityIdentifier(_ kind: CaptureNoteViewKind) -> String {
        switch kind {
        case .humanNotes: "note.page.view.humanNotes"
        case .enhanced: "note.page.view.enhanced"
        case .transcript: "note.page.view.transcript"
        }
    }
}

// MARK: - Bridging the live capture state

@MainActor
extension NotePageCapturePhase {

    /// Reads the phase of a capture, but only when it is the capture attached to
    /// `noteID`. A capture running for another note leaves this page alone.
    init(state: NoteCaptureState, noteID: UUID) {
        guard state.noteID == noteID else {
            self = .none
            return
        }
        switch state.phase {
        case .idle, .completed:
            self = .none
        case .starting:
            self = .starting
        case .capturing:
            self = .capturing
        case .finalizing(let stage):
            switch stage {
            case .sealingAudio:
                self = .finalizing(.sealingAudio, progress: nil)
            case .transcribing(let progress):
                self = .finalizing(.transcribing, progress: progress)
            case .diarizing(let progress):
                self = .finalizing(.diarizing, progress: progress)
            case .assembling:
                self = .finalizing(.assembling, progress: nil)
            }
        case .enhancing:
            self = .enhancing
        case .failed:
            self = .failed
        }
    }
}
