//
//  NotePagePresentationTests.swift
//  PindropTests
//
//  Created on 2026-08-22.
//

import Foundation
import Testing
import PindropCore
@testable import Pindrop

@Suite("Note page presentation (WP3)")
struct NotePagePresentationTests {

    private let locale = Locale(identifier: "en")

    private func kinds(_ state: NotePageState) -> [CaptureNoteViewKind] {
        NotePagePresentation.segments(state: state, locale: locale).map(\.kind)
    }

    private func segment(
        _ kind: CaptureNoteViewKind,
        in state: NotePageState
    ) -> NotePageSegment? {
        NotePagePresentation.segments(state: state, locale: locale)
            .first { $0.kind == kind }
    }

    // MARK: - Which segments exist

    @Test func plainTypedNoteShowsNoToggle() {
        let state = NotePageState.plainNote
        #expect(kinds(state) == [.humanNotes])
        #expect(!NotePagePresentation.isToggleVisible(state: state, locale: locale))
    }

    @Test func aRecordedNoteOffersEnhancedAndTranscript() {
        let state = NotePageState(
            hasPanels: true,
            hasTranscript: true,
            isRecorded: true
        )
        #expect(kinds(state) == [.humanNotes, .enhanced, .transcript])
        #expect(NotePagePresentation.isToggleVisible(state: state, locale: locale))
    }

    @Test func aRecordedNoteWithNoPanelStillOffersTheEnhancedSegment() {
        // The segment has to exist for the person to learn one is coming.
        let state = NotePageState(hasTranscript: true, isRecorded: true)
        #expect(kinds(state) == [.humanNotes, .enhanced, .transcript])
        #expect(segment(.enhanced, in: state)?.isEnabled == false)
        #expect(segment(.enhanced, in: state)?.helpText == "No enhanced note yet.")
    }

    @Test func aDeletedTranscriptRemovesTheSegmentEntirely() {
        let state = NotePageState(
            hasPanels: true,
            hasTranscript: false,
            isTranscriptDeleted: true,
            isRecorded: true
        )
        #expect(kinds(state) == [.humanNotes, .enhanced])
    }

    @Test func aDeletedTranscriptStaysHiddenEvenWhileCapturing() {
        let state = NotePageState(
            isTranscriptDeleted: true,
            isRecorded: true,
            capture: .capturing
        )
        #expect(!kinds(state).contains(.transcript))
    }

    // MARK: - While a capture runs

    @Test func enhancedIsDisabledWhileRecordingAndSaysWhy() throws {
        let state = NotePageState(isRecorded: true, capture: .capturing)
        let enhanced = try #require(segment(.enhanced, in: state))
        #expect(!enhanced.isEnabled)
        #expect(enhanced.helpText == "Available when the recording is finished")
        #expect(enhanced.indicator == nil)
    }

    @Test func enhancedStaysDisabledWhileTheEnhancedNoteIsBeingWritten() throws {
        let state = NotePageState(hasPanels: true, isRecorded: true, capture: .enhancing)
        let enhanced = try #require(segment(.enhanced, in: state))
        #expect(!enhanced.isEnabled)
        #expect(enhanced.helpText == "Writing your enhanced note.")
    }

    @Test func transcriptCarriesTheLiveDotWhileRecording() throws {
        let state = NotePageState(
            hasTranscript: true,
            isRecorded: true,
            capture: .capturing
        )
        let transcript = try #require(segment(.transcript, in: state))
        #expect(transcript.indicator == .live)
        #expect(transcript.isEnabled)
    }

    @Test func aRecordingWithNothingSaidYetOffersTheTranscriptSegmentDisabled() throws {
        let state = NotePageState(capture: .capturing)
        let transcript = try #require(segment(.transcript, in: state))
        #expect(!transcript.isEnabled)
        #expect(transcript.indicator == .live)
        #expect(transcript.helpText == "The transcript starts once you speak.")
    }

    @Test func aRecordingThatHasBeenHeardCanBeReadBeforeAnythingIsDurable() throws {
        // WP5: the live text is enough to open the Transcript view on, so a
        // person can follow along while the recording is still running.
        let state = NotePageState(capture: .capturing, hasLiveText: true)
        let transcript = try #require(segment(.transcript, in: state))
        #expect(transcript.isEnabled)
        #expect(transcript.indicator == .live)
        #expect(transcript.helpText == nil)
    }

    @Test func liveTextDoesNotResurrectADeletedTranscript() {
        let state = NotePageState(
            isTranscriptDeleted: true,
            capture: .capturing,
            hasLiveText: true
        )
        #expect(segment(.transcript, in: state) == nil)
    }

    // MARK: - Reading the transcript

    @Test func theTranscriptViewIsLiveOnlyWhileAudioIsBeingRecorded() {
        #expect(NotePagePresentation.isTranscriptLive(
            state: NotePageState(capture: .capturing, hasLiveText: true)
        ))
        #expect(!NotePagePresentation.isTranscriptLive(
            state: NotePageState(hasTranscript: true, capture: .finalizing(.transcribing, progress: nil))
        ))
        #expect(!NotePagePresentation.isTranscriptLive(
            state: NotePageState(hasTranscript: true, isRecorded: true)
        ))
    }

    @Test func everyReadableViewCanBeSearched() {
        // Live text has no durable spans yet, so the transcript view waits.
        let recording = NotePageState(capture: .capturing, hasLiveText: true)
        #expect(!NotePagePresentation.showsSearch(state: recording, selection: .transcript))
        // The typed notes can always be searched, even mid-capture.
        #expect(NotePagePresentation.showsSearch(state: recording, selection: .humanNotes))

        let finished = NotePageState(hasPanels: true, hasTranscript: true, isRecorded: true)
        #expect(NotePagePresentation.showsSearch(state: finished, selection: .transcript))
        #expect(NotePagePresentation.showsSearch(state: finished, selection: .humanNotes))
        #expect(NotePagePresentation.showsSearch(state: finished, selection: .enhanced))

        // An enhanced view with no panel behind it has nothing to search.
        let noPanels = NotePageState(hasTranscript: true, isRecorded: true)
        #expect(!NotePagePresentation.showsSearch(state: noPanels, selection: .enhanced))
    }

    /// Round B moved playback out of the docked bar and into the floating
    /// control, so playing is no longer tied to the transcript view: the
    /// recording can be played from wherever the note is being read.
    @Test func playingNeedsAFileAndNoRunningCapture() {
        let finished = NotePageState(hasTranscript: true, isRecorded: true)
        #expect(NotePagePresentation.showsPlayAction(state: finished, hasPlayableAudio: true))
        // Nothing to play, nothing to offer.
        #expect(!NotePagePresentation.showsPlayAction(state: finished, hasPlayableAudio: false))

        // A recording being made is not a recording to replay yet.
        let recording = NotePageState(capture: .capturing, hasLiveText: true)
        #expect(!NotePagePresentation.showsPlayAction(state: recording, hasPlayableAudio: true))
        let finalizing = NotePageState(
            isRecorded: true,
            capture: .finalizing(.transcribing, progress: nil)
        )
        #expect(!NotePagePresentation.showsPlayAction(state: finalizing, hasPlayableAudio: true))
    }

    @Test func finalizingIsStillAnActiveCapture() {
        let phase = NotePageCapturePhase.finalizing(.transcribing, progress: 0.4)
        #expect(phase.isActive)
        #expect(!phase.isRecording)
        #expect(phase.finalizationStage == .transcribing)
        #expect(phase.finalizationProgress == 0.4)
        #expect(NotePagePresentation.showsCaptureStrip(state: NotePageState(capture: phase)))
    }

    @Test func aFailedCaptureIsNotActiveAndDrawsNoStrip() {
        let state = NotePageState(isRecorded: true, capture: .failed)
        #expect(!state.capture.isActive)
        #expect(!NotePagePresentation.showsCaptureStrip(state: state))
    }

    // MARK: - The ready dot

    @Test func theReadyDotAppearsOnlyWhenThereIsAPanelToRead() throws {
        let unread = NotePageState(hasPanels: true, isRecorded: true, hasUnreadEnhanced: true)
        #expect(try #require(segment(.enhanced, in: unread)).indicator == .ready)

        let noPanelYet = NotePageState(isRecorded: true, hasUnreadEnhanced: true)
        #expect(try #require(segment(.enhanced, in: noPanelYet)).indicator == nil)

        let seen = NotePageState(hasPanels: true, isRecorded: true)
        #expect(try #require(segment(.enhanced, in: seen)).indicator == nil)
    }

    // MARK: - Resolving a selection

    @Test func aSelectionThatCannotBeShownFallsBackToTheTypedNotes() {
        let state = NotePageState(hasTranscript: true, isRecorded: true)
        // No panel was ever generated.
        #expect(
            NotePagePresentation.resolvedKind(
                requested: .enhanced,
                state: state,
                locale: locale
            ) == .humanNotes
        )
        #expect(
            NotePagePresentation.resolvedKind(
                requested: .transcript,
                state: state,
                locale: locale
            ) == .transcript
        )
    }

    @Test func aDeletedTranscriptSelectionFallsBack() {
        let state = NotePageState(isTranscriptDeleted: true, isRecorded: true)
        #expect(
            NotePagePresentation.resolvedKind(
                requested: .transcript,
                state: state,
                locale: locale
            ) == .humanNotes
        )
    }

    @Test func availabilityNeverChangesTheSelection() {
        // The only thing that resolves a selection is whether it can be drawn.
        // A newly ready panel leaves a person on the view they picked.
        let before = NotePageState(hasTranscript: true, isRecorded: true)
        let after = NotePageState(
            hasPanels: true,
            hasTranscript: true,
            isRecorded: true,
            hasUnreadEnhanced: true
        )
        for requested in CaptureNoteViewKind.allCases {
            let resolvedBefore = NotePagePresentation.resolvedKind(
                requested: requested,
                state: before,
                locale: locale
            )
            let resolvedAfter = NotePagePresentation.resolvedKind(
                requested: requested,
                state: after,
                locale: locale
            )
            if requested == .enhanced {
                // The only difference: enhanced became showable.
                #expect(resolvedBefore == .humanNotes)
                #expect(resolvedAfter == .enhanced)
            } else {
                #expect(resolvedBefore == resolvedAfter)
            }
        }
    }

    // MARK: - Header actions

    @Test func theRecordButtonIsHiddenWhileACaptureIsAttached() {
        let idle = NotePagePresentation.headerActions(
            state: .plainNote,
            selection: .humanNotes
        )
        #expect(idle.showsRecordButton)

        for phase in [
            NotePageCapturePhase.starting,
            .capturing,
            .finalizing(.sealingAudio, progress: nil),
            .enhancing
        ] {
            let actions = NotePagePresentation.headerActions(
                state: NotePageState(capture: phase),
                selection: .humanNotes
            )
            #expect(!actions.showsRecordButton)
        }
    }

    @Test func aFailedCaptureLetsThePersonRecordAgain() {
        let actions = NotePagePresentation.headerActions(
            state: NotePageState(isRecorded: true, capture: .failed),
            selection: .humanNotes
        )
        #expect(actions.showsRecordButton)
    }

    @Test func saveAsNoteNeedsAPanelOnScreen() {
        let onEnhanced = NotePagePresentation.headerActions(
            state: NotePageState(hasPanels: true, isRecorded: true),
            selection: .enhanced
        )
        #expect(onEnhanced.canSaveAsNote)

        let onNotes = NotePagePresentation.headerActions(
            state: NotePageState(hasPanels: true, isRecorded: true),
            selection: .humanNotes
        )
        #expect(!onNotes.canSaveAsNote)
    }

    @Test func deleteTranscriptNeedsATranscriptThatIsStillThere() {
        let withTranscript = NotePagePresentation.headerActions(
            state: NotePageState(hasTranscript: true, isRecorded: true),
            selection: .humanNotes
        )
        #expect(withTranscript.canDeleteTranscript)

        let alreadyDeleted = NotePagePresentation.headerActions(
            state: NotePageState(isTranscriptDeleted: true, isRecorded: true),
            selection: .humanNotes
        )
        #expect(!alreadyDeleted.canDeleteTranscript)

        let plain = NotePagePresentation.headerActions(state: .plainNote, selection: .humanNotes)
        #expect(!plain.canDeleteTranscript)
        #expect(plain.canDeleteNote)
        // The pop-out lands in WP8; the item is present and inert until then.
        #expect(!plain.canOpenInNewWindow)
    }

    @Test func cancelIsOfferedOnlyWhileAudioIsStillBeingRecorded() {
        for phase in [NotePageCapturePhase.starting, .capturing] {
            let actions = NotePagePresentation.headerActions(
                state: NotePageState(capture: phase),
                selection: .humanNotes
            )
            #expect(actions.canCancelCapture)
        }

        // Past the recording there is nothing left to cancel: Finish already
        // happened and the audio is durable.
        for phase in [
            NotePageCapturePhase.none,
            .finalizing(.transcribing, progress: 0.5),
            .enhancing,
            .failed
        ] {
            let actions = NotePagePresentation.headerActions(
                state: NotePageState(capture: phase),
                selection: .humanNotes
            )
            #expect(!actions.canCancelCapture)
        }
    }

    @Test func deleteNoteIsOfferedOnlyWhenCaptureWorkIsFinished() {
        for phase in [
            NotePageCapturePhase.starting,
            .capturing,
            .finalizing(.transcribing, progress: 0.5),
            .enhancing
        ] {
            let actions = NotePagePresentation.headerActions(
                state: NotePageState(capture: phase),
                selection: .humanNotes
            )
            #expect(!actions.canDeleteNote)
        }

        let idleActions = NotePagePresentation.headerActions(
            state: NotePageState(capture: .none),
            selection: .humanNotes
        )
        #expect(idleActions.canDeleteNote)

        let failedActions = NotePagePresentation.headerActions(
            state: NotePageState(capture: .failed),
            selection: .humanNotes
        )
        #expect(!failedActions.canDeleteNote)
    }

    @Test func cancelSaysWhatItThrowsAwayAndWhatItKeeps() {
        #expect(NotePagePresentation.cancelCaptureMessage(locale: locale)
            == "The audio and the live transcript are deleted. Your typed notes stay.")
    }

    // MARK: - Footer

    @Test func theTypedNotesFooterCountsWordsAndAutosavesQuietly() {
        let now = Date()
        let footer = NotePagePresentation.footer(
            kind: .humanNotes,
            state: .plainNote,
            facts: NotePageFooterFacts(wordCount: 128, editedAt: now),
            now: now,
            locale: locale
        )
        #expect(footer.leading == "128 words · edited just now")
        // Autosave owns the write path, so there is no save hint.
        #expect(footer.trailing == nil)
    }

    @Test func oneWordReadsAsOneWord() {
        let now = Date()
        let footer = NotePagePresentation.footer(
            kind: .humanNotes,
            state: .plainNote,
            facts: NotePageFooterFacts(wordCount: 1, editedAt: now),
            now: now,
            locale: locale
        )
        #expect(footer.leading.hasPrefix("1 word ·"))
    }

    @Test func theEnhancedFooterNamesTheTemplate() {
        let now = Date()
        let footer = NotePagePresentation.footer(
            kind: .enhanced,
            state: NotePageState(hasPanels: true, isRecorded: true),
            facts: NotePageFooterFacts(
                panelGeneratedAt: now,
                panelTemplateName: "Standup"
            ),
            now: now,
            locale: locale
        )
        #expect(footer.leading == "Generated just now · Standup template")
        #expect(footer.trailing == nil)
    }

    @Test func theEnhancedFooterSaysSoWhenNothingWasGenerated() {
        let footer = NotePagePresentation.footer(
            kind: .enhanced,
            state: NotePageState(isRecorded: true),
            facts: NotePageFooterFacts(),
            locale: locale
        )
        #expect(footer.leading == "No enhanced note yet.")
    }

    @Test func theTranscriptFooterReportsLengthAndSpeakers() {
        let footer = NotePagePresentation.footer(
            kind: .transcript,
            state: NotePageState(hasTranscript: true, isRecorded: true),
            facts: NotePageFooterFacts(
                transcriptDuration: 2538,
                transcriptSpeakerCount: 2
            ),
            locale: locale
        )
        #expect(footer.leading == "42:18 recording · 2 speakers")
    }

    @Test func theTranscriptFooterDropsSpeakersWhenNobodyWasAttributed() {
        let footer = NotePagePresentation.footer(
            kind: .transcript,
            state: NotePageState(hasTranscript: true, isRecorded: true),
            facts: NotePageFooterFacts(transcriptDuration: 65),
            locale: locale
        )
        #expect(footer.leading == "01:05 recording")
    }

    @Test func aLiveTranscriptFooterDoesNotClaimALength() {
        let footer = NotePagePresentation.footer(
            kind: .transcript,
            state: NotePageState(hasTranscript: true, isRecorded: true, capture: .capturing),
            facts: NotePageFooterFacts(isTranscriptLive: true),
            locale: locale
        )
        #expect(footer.leading == "The transcript fills in as you speak.")
    }

    @Test func aRunningRecordingIsLiveEvenBeforeTheStoreCatchesUp() {
        // WP5: the live view draws from the capture, so the footer must not
        // report a finished length for a transcript that is still growing.
        let footer = NotePagePresentation.footer(
            kind: .transcript,
            state: NotePageState(capture: .capturing, hasLiveText: true),
            facts: NotePageFooterFacts(isTranscriptLive: false),
            locale: locale
        )
        #expect(footer.leading == "The transcript fills in as you speak.")
    }

    // MARK: - Finalizing copy

    @Test func everyStageHasAnHonestNameAndAPredecessor() {
        #expect(NotePagePresentation.stageTitle(.sealingAudio, locale: locale) == "Sealing audio")
        #expect(NotePagePresentation.stageTitle(.transcribing, locale: locale) == "Transcribing")
        #expect(NotePagePresentation.stageTitle(.diarizing, locale: locale) == "Identifying speakers")
        #expect(NotePagePresentation.stageTitle(.assembling, locale: locale) == "Writing note")

        #expect(NotePagePresentation.completedStages(before: .sealingAudio, locale: locale) == nil)
        #expect(NotePagePresentation.completedStages(before: .transcribing, locale: locale) == "Audio sealed")
        #expect(NotePagePresentation.completedStages(before: .diarizing, locale: locale) == "Transcription done")
        #expect(NotePagePresentation.completedStages(before: .assembling, locale: locale) == "Speakers identified")

        for stage in NotePageFinalizationStage.allCases {
            #expect(!NotePagePresentation.stageTitle(stage, locale: locale).isEmpty)
        }
    }

    @Test func theFinalizingCaptionPromisesNothingItCannotKeep() {
        let caption = NotePagePresentation.finalizingCaption(locale: locale)
        #expect(caption.contains("Long recordings can take a few minutes."))
        #expect(caption.contains("You can keep typing."))
        // Copy rule: no em or en dashes as sentence dashes.
        #expect(!caption.contains("—"))
        #expect(!caption.contains("–"))
    }

    // MARK: - View chips (Round B)

    private func chip(
        _ kind: CaptureNoteViewKind,
        in state: NotePageState,
        selection: CaptureNoteViewKind,
        canOpenEnhancedMenu: Bool = false
    ) -> NoteViewChipState? {
        NotePagePresentation.chips(
            state: state,
            selection: selection,
            canOpenEnhancedMenu: canOpenEnhancedMenu,
            locale: locale
        )
        .first { $0.kind == kind }
    }

    @Test func everyChipCarriesItsOwnGlyph() {
        #expect(NotePagePresentation.chipIcon(.humanNotes) == "text.alignleft")
        #expect(NotePagePresentation.chipIcon(.enhanced) == "sparkles")
        #expect(NotePagePresentation.chipIcon(.transcript) == "mic")
    }

    @Test func theChipsMirrorTheSegmentsTheyReplaced() {
        let state = NotePageState(hasPanels: true, hasTranscript: true, isRecorded: true)
        let chips = NotePagePresentation.chips(
            state: state,
            selection: .transcript,
            locale: locale
        )
        let segments = NotePagePresentation.segments(state: state, locale: locale)

        #expect(chips.map(\.kind) == segments.map(\.kind))
        #expect(chips.map(\.isEnabled) == segments.map(\.isEnabled))
        #expect(chips.map(\.indicator) == segments.map(\.indicator))
        #expect(chips.map(\.helpText) == segments.map(\.helpText))
        #expect(chips.filter(\.isSelected).map(\.kind) == [.transcript])
    }

    @Test func everyEnabledEnhancedChipWearsTheMenuChevron() throws {
        let state = NotePageState(hasPanels: true, hasTranscript: true, isRecorded: true)

        let selected = try #require(
            chip(.enhanced, in: state, selection: .enhanced, canOpenEnhancedMenu: true)
        )
        #expect(selected.isSelected)
        #expect(selected.opensMenu)

        // Unselected but enabled: the chevron stays visible (boards 56/70);
        // clicking still switches views, and the menu opens once selected.
        let unselected = try #require(
            chip(.enhanced, in: state, selection: .transcript, canOpenEnhancedMenu: true)
        )
        #expect(!unselected.isSelected)
        #expect(unselected.opensMenu)

        // Nothing else ever opens a dropdown.
        let transcript = try #require(
            chip(.transcript, in: state, selection: .transcript, canOpenEnhancedMenu: true)
        )
        #expect(!transcript.opensMenu)
    }

    @Test func aPanelWithNoTemplatesToOfferKeepsItsChipAPlainSwitch() throws {
        // A legacy panel cannot be regenerated, so the chip must not promise a
        // dropdown that has nothing to do.
        let state = NotePageState(hasPanels: true, hasTranscript: true, isRecorded: true)
        let enhanced = try #require(
            chip(.enhanced, in: state, selection: .enhanced, canOpenEnhancedMenu: false)
        )
        #expect(enhanced.isSelected)
        #expect(!enhanced.opensMenu)
    }

    @Test func aDisabledChipIsNeverSelectedAndNeverOpensAnything() throws {
        // Enhanced during a recording: the person's stored selection may still
        // name it, but the page is drawing My notes.
        let state = NotePageState(isRecorded: true, capture: .capturing)
        let enhanced = try #require(
            chip(.enhanced, in: state, selection: .enhanced, canOpenEnhancedMenu: true)
        )
        #expect(!enhanced.isEnabled)
        #expect(!enhanced.isSelected)
        #expect(!enhanced.opensMenu)
        #expect(enhanced.helpText == "Available when the recording is finished")
    }

    @Test func theLiveAndReadyDotsCarryOverOntoTheChips() throws {
        let recording = NotePageState(hasTranscript: true, isRecorded: true, capture: .capturing)
        #expect(
            try #require(chip(.transcript, in: recording, selection: .humanNotes)).indicator
                == .live
        )

        let unread = NotePageState(hasPanels: true, isRecorded: true, hasUnreadEnhanced: true)
        #expect(
            try #require(chip(.enhanced, in: unread, selection: .humanNotes)).indicator == .ready
        )
    }

    // MARK: - Speakers popover (Round B)

    private func speakerSegment(
        id: String,
        key: String?,
        label: String?,
        number: Int? = nil,
        profileID: UUID? = nil,
        isCurrentUser: Bool = false,
        start: TimeInterval
    ) -> TranscriptSegmentSnapshot {
        TranscriptSegmentSnapshot(
            id: id,
            revisionID: UUID(),
            speakerKey: key,
            speakerLabel: label,
            speakerNumber: number,
            speakerProfileID: profileID,
            isCurrentUser: isCurrentUser,
            text: "Words.",
            startOffset: start,
            duration: 2
        )
    }

    @Test func theSpeakersChipCountsWhoTheRecordingHeard() {
        #expect(
            NotePagePresentation.speakersChipTitle(
                speakerCount: 3,
                expectedSpeakerCount: nil,
                locale: locale
            ) == "3 speakers"
        )
        // Before a transcript exists there is only the count that was asked for.
        #expect(
            NotePagePresentation.speakersChipTitle(
                speakerCount: 0,
                expectedSpeakerCount: nil,
                locale: locale
            ) == "Speakers: Auto"
        )
        #expect(
            NotePagePresentation.speakersChipTitle(
                speakerCount: 0,
                expectedSpeakerCount: 4,
                locale: locale
            ) == "Speakers: 4"
        )
    }

    @Test func thePopoverListsEachSpeakerOnceInTheOrderTheyWereHeard() throws {
        let profileID = UUID()
        let popover = NotePagePresentation.speakersPopover(
            segments: [
                speakerSegment(id: "a", key: "self", label: "You", isCurrentUser: true, start: 0),
                speakerSegment(id: "b", key: "s2", label: "Andrea", profileID: profileID, start: 4),
                speakerSegment(id: "c", key: "self", label: "You", isCurrentUser: true, start: 8),
                speakerSegment(id: "d", key: "s3", label: "Speaker 3", number: 3, start: 12)
            ],
            duration: 2538,
            locale: locale
        )

        #expect(popover.title == "Speakers")
        #expect(popover.durationText == "42:18")
        #expect(popover.rows.map(\.id) == ["self", "s2", "s3"])
        #expect(popover.rows.map(\.name) == ["You", "Andrea", "Speaker 3"])
        #expect(popover.rows.map(\.isCurrentUser) == [true, false, false])
        #expect(popover.caption.contains("Renames apply to the transcript and future notes."))
        // Copy rule: no em or en dashes as sentence dashes.
        #expect(!popover.caption.contains("—"))
    }

    @Test func onlyASpeakerAProfileNamedCanBeRenamed() throws {
        let profileID = UUID()
        let popover = NotePagePresentation.speakersPopover(
            segments: [
                speakerSegment(id: "a", key: "s2", label: "Andrea", profileID: profileID, start: 0),
                speakerSegment(id: "b", key: "s3", label: "Speaker 3", number: 3, start: 4)
            ],
            duration: 60,
            locale: locale
        )

        #expect(try #require(popover.rows.first).canRename)
        #expect(try #require(popover.rows.first).profileID == profileID)
        // A generic number has no owner, so nothing here could keep a new name.
        #expect(!(try #require(popover.rows.last).canRename))
        #expect(!NotePagePresentation.renameUnavailableHelpText(locale: locale).isEmpty)
    }

    @Test func theRecorderReadsAsYouWhateverTheirProfileIsCalled() throws {
        // The transcript names the person recording "You" everywhere, so the
        // popover has to agree with the turns above it.
        let popover = NotePagePresentation.speakersPopover(
            segments: [
                speakerSegment(
                    id: "a",
                    key: "self",
                    label: "Chris",
                    profileID: UUID(),
                    isCurrentUser: true,
                    start: 0
                )
            ],
            duration: 60,
            locale: locale
        )

        let row = try #require(popover.rows.first)
        #expect(row.name == "You")
        #expect(row.isCurrentUser)
        #expect(row.canRename)
    }

    @Test func anUnattributedTranscriptStillListsOneSpeaker() throws {
        let popover = NotePagePresentation.speakersPopover(
            segments: [speakerSegment(id: "a", key: nil, label: nil, start: 0)],
            duration: 30,
            locale: locale
        )

        #expect(popover.rows.map(\.id) == ["_"])
        #expect(try #require(popover.rows.first).name == "Speaker")
    }

    @Test func aNoteWithNoTranscriptHasNoSpeakerRows() {
        let popover = NotePagePresentation.speakersPopover(
            segments: [],
            duration: 0,
            locale: locale
        )
        #expect(popover.rows.isEmpty)
        #expect(popover.durationText == "00:00")
    }

    @Test func segmentIdentifiersAreStable() {
        #expect(NotePagePresentation.accessibilityIdentifier(.humanNotes) == "note.page.view.humanNotes")
        #expect(NotePagePresentation.accessibilityIdentifier(.enhanced) == "note.page.view.enhanced")
        #expect(NotePagePresentation.accessibilityIdentifier(.transcript) == "note.page.view.transcript")
    }

    @Test func viewTitlesUseTheWordsTheSpecUses() {
        #expect(NotePagePresentation.viewTitle(.humanNotes, locale: locale) == "My notes")
        #expect(NotePagePresentation.viewTitle(.enhanced, locale: locale) == "Enhanced")
        #expect(NotePagePresentation.viewTitle(.transcript, locale: locale) == "Transcript")
    }

    // MARK: - Live speaker labels

    @Test func aMissingLiveSpeakerModelOffersTheDownload() {
        #expect(
            NotePagePresentation.liveSpeakerSetupMessage(status: .modelMissing, locale: locale)
                == "Live speaker names need the speaker model. Download it to name people while you record."
        )
    }

    @Test func aFailedLoadSaysTheRecordingContinues() {
        #expect(
            NotePagePresentation.liveSpeakerSetupMessage(status: .loadFailed, locale: locale)
                == "The live speaker model could not be loaded. Recording continues, and the finished note still names everyone."
        )
    }

    /// Only the two conditions a download can fix get a banner. Paused labels are
    /// a chip on the live sheet, and labels that are simply off are not a fault.
    @Test(arguments: [
        LiveSpeakerLabelStatus.off,
        .running,
        .paused
    ])
    func statesADownloadCannotFixShowNoBanner(_ status: LiveSpeakerLabelStatus) {
        #expect(NotePagePresentation.liveSpeakerSetupMessage(status: status, locale: locale) == nil)
    }

    @Test func theFourVoiceChipStatesTheCapabilityAndNotAHeadcount() throws {
        let chip = try #require(
            NotePagePresentation.liveSpeakerChip(
                status: .running,
                isAtSlotCapacity: true,
                isOfflinePassScheduled: true,
                locale: locale
            )
        )
        #expect(
            chip == "Live names cover up to four voices. Pindrop checks every speaker again when the recording ends."
        )
    }

    @Test func runningLabelsBelowCapacitySayNothing() {
        #expect(
            NotePagePresentation.liveSpeakerChip(
                status: .running,
                isAtSlotCapacity: false,
                isOfflinePassScheduled: true,
                locale: locale
            ) == nil
        )
    }

    /// The promise of a second pass is only made when there is going to be one.
    @Test func aPausedChipOnlyPromisesARecheckWhenTheOfflinePassIsScheduled() {
        #expect(
            NotePagePresentation.liveSpeakerChip(
                status: .paused,
                isAtSlotCapacity: false,
                isOfflinePassScheduled: true,
                locale: locale
            ) == "Live speaker names paused. Pindrop checks the speakers again when the recording ends."
        )
        #expect(
            NotePagePresentation.liveSpeakerChip(
                status: .paused,
                isAtSlotCapacity: false,
                isOfflinePassScheduled: false,
                locale: locale
            ) == "Live speaker names paused."
        )
    }

    /// Paused outranks capacity: a frozen label list is the more useful fact.
    @Test func aPausedChipWinsOverTheCapacityChip() {
        #expect(
            NotePagePresentation.liveSpeakerChip(
                status: .paused,
                isAtSlotCapacity: true,
                isOfflinePassScheduled: false,
                locale: locale
            ) == "Live speaker names paused."
        )
    }

    // MARK: - The reconciliation line

    @Test func theReconciliationLineShowsUntilTheStoredFlagIsCleared() {
        var state = NotePageState(hasTranscript: true, isRecorded: true, liveLabelsDiffered: true)
        #expect(NotePagePresentation.showsSpeakerReconciliation(state: state))

        // Dismissal clears the stored flag, which is the whole of the state: a
        // relaunch reads the same flag and draws the same answer.
        state.liveLabelsDiffered = false
        #expect(!NotePagePresentation.showsSpeakerReconciliation(state: state))
    }

    @Test func theReconciliationLineWaitsForTheCaptureToEnd() {
        let state = NotePageState(
            hasTranscript: true,
            isRecorded: true,
            capture: .capturing,
            liveLabelsDiffered: true
        )
        #expect(!NotePagePresentation.showsSpeakerReconciliation(state: state))
    }

    @Test func aNoteWhoseNamesDidNotChangeSaysNothing() {
        let state = NotePageState(hasTranscript: true, isRecorded: true)
        #expect(!NotePagePresentation.showsSpeakerReconciliation(state: state))
    }
}

@Suite("Note page capture phase binding (WP3)")
@MainActor
struct NotePageCapturePhaseTests {

    @Test func aCaptureOnAnotherNoteLeavesThisPageAlone() {
        let state = NoteCaptureState()
        state.beginStarting(includesSystemAudio: false, origin: .mainWindow)
        state.bindNote(id: UUID())
        state.beginCapturing(startedAt: Date())

        #expect(NotePageCapturePhase(state: state, noteID: UUID()) == .none)
    }

    @Test func everyPhaseMapsToWhatThePageDraws() {
        let noteID = UUID()
        let state = NoteCaptureState()
        #expect(NotePageCapturePhase(state: state, noteID: noteID) == .none)

        state.beginStarting(includesSystemAudio: true, origin: .mainWindow)
        state.bindNote(id: noteID)
        #expect(NotePageCapturePhase(state: state, noteID: noteID) == .starting)

        state.beginCapturing(startedAt: Date())
        #expect(NotePageCapturePhase(state: state, noteID: noteID) == .capturing)

        state.beginFinalizing(.sealingAudio)
        #expect(
            NotePageCapturePhase(state: state, noteID: noteID)
                == .finalizing(.sealingAudio, progress: nil)
        )

        state.beginFinalizing(.transcribing(0.25))
        #expect(
            NotePageCapturePhase(state: state, noteID: noteID)
                == .finalizing(.transcribing, progress: 0.25)
        )

        state.beginFinalizing(.diarizing(nil))
        #expect(
            NotePageCapturePhase(state: state, noteID: noteID)
                == .finalizing(.diarizing, progress: nil)
        )

        state.beginFinalizing(.assembling)
        #expect(
            NotePageCapturePhase(state: state, noteID: noteID)
                == .finalizing(.assembling, progress: nil)
        )

        state.beginEnhancing()
        #expect(NotePageCapturePhase(state: state, noteID: noteID) == .enhancing)

        state.fail("Recording stopped.")
        #expect(NotePageCapturePhase(state: state, noteID: noteID) == .failed)

        state.complete()
        // A finished capture no longer owns the page.
        #expect(NotePageCapturePhase(state: state, noteID: noteID) == .none)
    }

    @Test func aCompletedCaptureShowsTheRecordButtonAgain() {
        let noteID = UUID()
        let state = NoteCaptureState()
        state.beginStarting(includesSystemAudio: false, origin: .mainWindow)
        state.bindNote(id: noteID)
        state.beginCapturing(startedAt: Date())
        state.complete()

        let phase = NotePageCapturePhase(state: state, noteID: noteID)
        let actions = NotePagePresentation.headerActions(
            state: NotePageState(hasPanels: true, hasTranscript: true, isRecorded: true, capture: phase),
            selection: .humanNotes
        )
        #expect(actions.showsRecordButton)
    }
}

@Suite("Transcript turns (WP3)")
struct TranscriptTurnTests {

    private func segment(
        id: String,
        speakerKey: String?,
        label: String?,
        number: Int? = nil,
        isCurrentUser: Bool = false,
        text: String,
        start: TimeInterval
    ) -> TranscriptSegmentSnapshot {
        TranscriptSegmentSnapshot(
            id: id,
            revisionID: UUID(),
            speakerKey: speakerKey,
            speakerLabel: label,
            speakerNumber: number,
            isCurrentUser: isCurrentUser,
            text: text,
            startOffset: start,
            duration: 2
        )
    }

    @Test func consecutiveSpansOfOneSpeakerReadAsOneTurn() throws {
        let turns = TranscriptTurn.turns(in: [
            segment(id: "a", speakerKey: "s1", label: "You", isCurrentUser: true, text: "First.", start: 0),
            segment(id: "b", speakerKey: "s1", label: "You", isCurrentUser: true, text: "Second.", start: 3),
            segment(id: "c", speakerKey: "s2", label: "Speaker 2", number: 2, text: "Third.", start: 6)
        ])

        #expect(turns.count == 2)
        let first = try #require(turns.first)
        #expect(first.text == "First.\nSecond.")
        #expect(first.startOffset == 0)
        #expect(first.isCurrentUser)
        #expect(first.displayName(locale: Locale(identifier: "en")) == "You")

        let second = try #require(turns.last)
        #expect(second.text == "Third.")
        #expect(second.displayName(locale: Locale(identifier: "en")) == "Speaker 2")
    }

    @Test func unattributedSpansGroupTogetherAndKeepAName() throws {
        let turns = TranscriptTurn.turns(in: [
            segment(id: "a", speakerKey: nil, label: nil, text: "One.", start: 0),
            segment(id: "b", speakerKey: nil, label: nil, text: "Two.", start: 2)
        ])
        #expect(turns.count == 1)
        let turn = try #require(turns.first)
        #expect(turn.speakerKey == "_")
        #expect(turn.displayName(locale: Locale(identifier: "en")) == "Speaker")
    }

    @Test func anEmptyTranscriptHasNoTurns() {
        #expect(TranscriptTurn.turns(in: []).isEmpty)
    }
}
