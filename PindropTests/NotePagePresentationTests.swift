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

    // MARK: - Footer

    @Test func theTypedNotesFooterCountsWordsAndOffersTheSaveHint() {
        let now = Date()
        let footer = NotePagePresentation.footer(
            kind: .humanNotes,
            state: .plainNote,
            facts: NotePageFooterFacts(wordCount: 128, editedAt: now),
            now: now,
            locale: locale
        )
        #expect(footer.leading == "128 words · edited just now")
        #expect(footer.trailing == "⌘S to save")
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
