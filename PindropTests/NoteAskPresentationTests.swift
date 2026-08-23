//
//  NoteAskPresentationTests.swift
//  PindropTests
//
//  Created on 2026-08-23.
//

import Foundation
import Testing
@testable import Pindrop

@MainActor
@Suite("Note ask presentation (Round B)")
struct NoteAskPresentationTests {

    private let locale = Locale(identifier: "en")

    // MARK: - Who owns the band

    @Test func aRunningCaptureTakesTheBand() {
        #expect(!NoteAskPresentation.isVisible(isOpen: true, isCaptureDockVisible: true))
        #expect(NoteAskPresentation.isVisible(isOpen: true, isCaptureDockVisible: false))
    }

    @Test func aClosedDockIsNeverDrawn() {
        #expect(!NoteAskPresentation.isVisible(isOpen: false, isCaptureDockVisible: false))
    }

    @Test func anEmptyNoteIsNotWorthAsking() {
        #expect(NoteAskPresentation.canAsk(hasChatService: true, hasEvidence: true))
        #expect(!NoteAskPresentation.canAsk(hasChatService: true, hasEvidence: false))
        #expect(!NoteAskPresentation.canAsk(hasChatService: false, hasEvidence: true))
    }

    // MARK: - Input row

    @Test func theFirstQuestionAndAFollowUpAskDifferently() {
        #expect(
            NoteAskPresentation.placeholder(hasThread: false, locale: locale)
                == "Ask about this note"
        )
        #expect(
            NoteAskPresentation.placeholder(hasThread: true, locale: locale)
                == "Ask a follow-up"
        )
    }

    @Test func aQuestionInFlightClosesTheInput() {
        #expect(NoteAskPresentation.isInputEnabled(phase: .idle))
        #expect(!NoteAskPresentation.isInputEnabled(phase: .thinking))
        // A failure leaves the field open: trying again is the whole point.
        let failure = NoteAskFailure(message: "Nope.", question: "Who owns this?")
        #expect(NoteAskPresentation.isInputEnabled(phase: .failed(failure)))
    }

    @Test func onlyARealQuestionCanBeSent() {
        #expect(NoteAskPresentation.canSend(question: "What was decided?", phase: .idle))
        #expect(!NoteAskPresentation.canSend(question: "   \n ", phase: .idle))
        #expect(!NoteAskPresentation.canSend(question: "", phase: .idle))
        #expect(!NoteAskPresentation.canSend(question: "What was decided?", phase: .thinking))
    }

    // MARK: - Failures

    @Test func aTypedFailureKeepsTheServiceSentenceAndTheQuestion() {
        let failure = NoteAskPresentation.failure(
            from: NoteChatService.NoteChatError.noProviderConfigured,
            question: "What did we decide?"
        )
        #expect(
            failure?.message == "Pick a model for note enhancement in Settings, then try again."
        )
        // The retry sends the same question, not whatever is in the field by then.
        #expect(failure?.question == "What did we decide?")
        if let failure {
            #expect(NoteAskPhase.failed(failure).failure == failure)
        }
    }

    @Test func aCancelledQuestionIsNotAFailure() {
        #expect(
            NoteAskPresentation.failure(from: CancellationError(), question: "Anything?") == nil
        )
        let cancelledURL = URLError(.cancelled)
        #expect(NoteAskPresentation.failure(from: cancelledURL, question: "Anything?") == nil)
    }

    @Test func anUntypedFailureStillSaysSomething() {
        struct PlainFailure: Error {}
        let failure = NoteAskPresentation.failure(from: PlainFailure(), question: "Anything?")
        #expect(failure != nil)
        #expect(!(failure?.message.isEmpty ?? true))
    }

    // MARK: - Phase

    @Test func onlyTheThinkingPhaseIsThinking() {
        #expect(NoteAskPhase.thinking.isThinking)
        #expect(!NoteAskPhase.idle.isThinking)
        #expect(NoteAskPhase.idle.failure == nil)
    }

    // MARK: - Geometry and copy

    @Test func theExchangeListOpensLikeTheTranscriptSheet() {
        let canvas: CGFloat = 800
        #expect(
            NoteAskPresentation.maxExchangeHeight(canvasHeight: canvas)
                == TranscriptSheetGeometry.height(for: .medium, canvasHeight: canvas)
        )
    }

    @Test func aSourceLinkNamesTheTranscriptAndTheTime() {
        let source = NoteChatSource(
            segmentID: "seg-1",
            revisionID: UUID(),
            startOffset: 192,
            timestampLabel: "03:12",
            speakerLabel: "You",
            text: "Let us move the launch to October."
        )
        #expect(
            NoteAskPresentation.sourceTitle(source, locale: locale)
                == "From the transcript · 03:12"
        )
    }

    @Test func theDockSaysWhereAnswersComeFrom() {
        #expect(
            NoteAskPresentation.caption(locale: locale)
                == "Answers come from this note's transcript and your AI provider. "
                + "Check anything important."
        )
        #expect(NoteAskPresentation.title(locale: locale) == "Ask this note")
        #expect(NoteAskPresentation.quickActionTitle(locale: locale) == "List action items")
        #expect(NoteAskPresentation.thinkingText(locale: locale) == "Thinking…")
    }
}
