//
//  NoteAskPresentation.swift
//  Pindrop
//
//  Created on 2026-08-23.
//
//  What the "Ask this note" dock shows, decided once (Round B).
//
//  The dock itself is chrome around three questions: is it on screen at all,
//  what does the input row say, and what happened to the last question. All
//  three have one right answer for a given set of plain values, so they are
//  answered here and drawn in `NoteAskDock`.
//
//  The conversation is not one of those values. It lives in `NoteChatService`
//  for the life of the app run, which is what lets the dock close and reopen
//  with the thread still in it.
//

import Foundation
import CoreGraphics

// MARK: - Values

/// The question that could not be answered, and the sentence to say about it.
struct NoteAskFailure: Equatable, Sendable {
    /// The service's own copy: what went wrong and what to do next.
    let message: String
    /// The question "Try again" sends again. Kept whole, so a retry asks the
    /// same thing and not whatever is in the field by then.
    let question: String
}

/// What the dock is doing.
enum NoteAskPhase: Equatable, Sendable {
    /// Waiting for a question.
    case idle
    /// One question is with the provider.
    case thinking
    /// The last question came back as an error.
    case failed(NoteAskFailure)

    var isThinking: Bool { self == .thinking }

    var failure: NoteAskFailure? {
        guard case .failed(let failure) = self else { return nil }
        return failure
    }
}

// MARK: - Presentation

enum NoteAskPresentation {

    // MARK: Geometry

    static let cornerRadius: CGFloat = 10
    /// The reading measure of one answer.
    static let answerMaxWidth: CGFloat = 560
    /// Between one exchange and the next.
    static let exchangeSpacing: CGFloat = 14
    /// A question chip and the answer under it.
    static let bubbleRadius: CGFloat = 10

    /// How tall the exchange list may grow.
    ///
    /// The same fraction of the page the live transcript sheet opens to, and by
    /// the same arithmetic: two surfaces in the same band that measured the page
    /// differently would read as two different docks.
    static func maxExchangeHeight(canvasHeight: CGFloat) -> CGFloat {
        TranscriptSheetGeometry.height(for: .medium, canvasHeight: canvasHeight)
    }

    // MARK: Availability

    /// True when the dock belongs in the band above the footer.
    ///
    /// A running capture owns that band. It is geometry, not preference: the
    /// capture dock fills the same space, so the ask stands down and comes back
    /// with its thread when the recording is over.
    static func isVisible(isOpen: Bool, isCaptureDockVisible: Bool) -> Bool {
        isOpen && !isCaptureDockVisible
    }

    /// True when this note can be asked about at all.
    ///
    /// Two things have to hold: the shell can answer a question, and the note
    /// has something to answer from. An Ask satellite on an empty note would
    /// only ever produce "there is nothing to ask about yet".
    static func canAsk(hasChatService: Bool, hasEvidence: Bool) -> Bool {
        hasChatService && hasEvidence
    }

    /// True while the field takes typing. A question already with the provider
    /// disables it: a second question would race the first one's answer.
    static func isInputEnabled(phase: NoteAskPhase) -> Bool {
        !phase.isThinking
    }

    /// True when this question can be sent.
    static func canSend(question: String, phase: NoteAskPhase) -> Bool {
        guard isInputEnabled(phase: phase) else { return false }
        return !question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // MARK: Failures

    /// The notice one failed question turns into, or nil when there is nothing
    /// to say.
    ///
    /// A cancelled question is not a failure: the person navigated away, and a
    /// notice about it would be an error nobody made.
    @MainActor
    static func failure(from error: Error, question: String) -> NoteAskFailure? {
        guard !NoteChatService.isCancellation(error) else { return nil }
        let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        return NoteAskFailure(message: message, question: question)
    }

    // MARK: Copy

    static func title(locale: Locale) -> String {
        localized("Ask this note", locale: locale)
    }

    /// The field's prompt. A thread that already exists asks for the next turn,
    /// not for the first one.
    static func placeholder(hasThread: Bool, locale: Locale) -> String {
        hasThread
            ? localized("Ask a follow-up", locale: locale)
            : localized("Ask about this note", locale: locale)
    }

    static func quickActionTitle(locale: Locale) -> String {
        localized("List action items", locale: locale)
    }

    static func clearTitle(locale: Locale) -> String {
        localized("Clear", locale: locale)
    }

    static func closeLabel(locale: Locale) -> String {
        localized("Close", locale: locale)
    }

    static func thinkingText(locale: Locale) -> String {
        localized("Thinking…", locale: locale)
    }

    static func retryTitle(locale: Locale) -> String {
        localized("Try again", locale: locale)
    }

    /// The line under the dock: where answers come from, and what to do about
    /// that.
    static func caption(locale: Locale) -> String {
        localized(
            "Answers come from this note's transcript and your AI provider. Check anything important.",
            locale: locale
        )
    }

    /// One source link: the same words the source peek uses, then the time the
    /// line was said.
    static func sourceTitle(_ source: NoteChatSource, locale: Locale) -> String {
        "\(localized("From the transcript", locale: locale)) · \(source.timestampLabel)"
    }
}
