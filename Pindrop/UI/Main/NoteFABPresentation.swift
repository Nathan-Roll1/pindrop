//
//  NoteFABPresentation.swift
//  Pindrop
//
//  Created on 2026-08-22.
//
//  What the note page's floating control offers, decided once (Round B).
//
//  One button in the bottom-right corner carries every action a note has once it
//  is written: ask it a question, copy it, play what was recorded, and find a
//  word in it. Which of those exist depends on the note, and which shape the
//  button takes depends on what the reader last asked for, so both questions are
//  answered here as pure functions of plain values.
//
//  The geometry lives here too. The anchor is shared by four different shapes,
//  and a pill that grows leftward from a different point than the circle it
//  replaced would read as the control jumping.
//

import Foundation
import CoreGraphics

// MARK: - State

/// What the floating control is showing.
enum NoteFABState: Equatable, Sendable {
    /// One circle with a magnifier in it.
    case resting
    /// The satellites are fanned out above the circle.
    case fan
    /// The search pill: field, count, and the two steppers.
    case search
    /// The playback pill: pause, progress, and the clock.
    case playing
}

/// One action the fan offers.
enum NoteFABAction: String, Equatable, Sendable, CaseIterable {
    case ask
    case copy
    case play
}

/// One satellite, as the fan draws it.
struct NoteFABSatellite: Identifiable, Equatable, Sendable {
    let action: NoteFABAction
    let title: String
    let systemImage: String

    var id: NoteFABAction { action }

    /// Stable identifiers so the corner can be driven without a window.
    var accessibilityIdentifier: String { "note.fab.\(action.rawValue)" }
}

/// Which way a step through the matches goes.
enum NoteFABMatchStep: Equatable, Sendable {
    case next
    case previous
}

/// Everything the floating control depends on, as plain values.
struct NoteFABContext: Equatable, Sendable {
    /// The note kept its recording and the file is still on disk.
    var hasAudio: Bool
    /// The shell handed this page a way into the Ask surface.
    var canAsk: Bool
    /// The view on screen can answer a search.
    var canSearch: Bool
    /// The Ask surface is open. It owns the corner while it is.
    var isAskSurfaceOpen: Bool
    /// A capture is running. Its dock fills the band the pills grow into.
    var isCaptureDockVisible: Bool

    init(
        hasAudio: Bool = false,
        canAsk: Bool = false,
        canSearch: Bool = false,
        isAskSurfaceOpen: Bool = false,
        isCaptureDockVisible: Bool = false
    ) {
        self.hasAudio = hasAudio
        self.canAsk = canAsk
        self.canSearch = canSearch
        self.isAskSurfaceOpen = isAskSurfaceOpen
        self.isCaptureDockVisible = isCaptureDockVisible
    }
}

// MARK: - Presentation

enum NoteFABPresentation {

    // MARK: Geometry

    /// The resting circle.
    static let restingDiameter: CGFloat = 36
    /// One satellite circle.
    static let satelliteDiameter: CGFloat = 32
    /// Between the satellites, and between a satellite and its label chip.
    static let satelliteGap: CGFloat = 8
    /// The glyph circle inside a pill.
    static let pillGlyphDiameter: CGFloat = 26
    /// The search field between the glyph and the count.
    static let searchFieldWidth: CGFloat = 150
    /// One prev/next button.
    static let stepButtonDiameter: CGFloat = 22
    /// The playback progress track.
    static let progressWidth: CGFloat = 130
    static let progressHeight: CGFloat = 3
    /// The gutter the page's content column keeps on both sides.
    static let contentInset: CGFloat = 40
    /// A circle set flush with a straight edge reads as inset, so it is pushed
    /// out by a hair to sit optically on the content edge.
    static let opticalOvershoot: CGFloat = 2
    /// The gap between the control and the footer hairline.
    static let bottomInset: CGFloat = 20

    /// How far the anchor sits from the trailing edge of the pane.
    static var trailingInset: CGFloat { contentInset - opticalOvershoot }

    // MARK: Availability

    /// True when the corner belongs to the floating control.
    ///
    /// Two things take it away: the Ask surface, which owns the corner while it
    /// is open, and a running capture, whose dock fills the same band the pills
    /// grow into. Both are geometry, not preference: two controls in one corner
    /// would overlap.
    static func isVisible(context: NoteFABContext) -> Bool {
        !context.isAskSurfaceOpen && !context.isCaptureDockVisible
    }

    /// The satellites, top to bottom. Order is fixed so the same action is always
    /// in the same place, whatever else this note has.
    static func satellites(context: NoteFABContext, locale: Locale) -> [NoteFABSatellite] {
        var satellites: [NoteFABSatellite] = []
        if context.canAsk {
            satellites.append(
                NoteFABSatellite(
                    action: .ask,
                    title: localized("Ask this note", locale: locale),
                    systemImage: "sparkles"
                )
            )
        }
        satellites.append(
            NoteFABSatellite(
                action: .copy,
                title: localized("Copy note", locale: locale),
                systemImage: "doc.on.doc"
            )
        )
        if context.hasAudio {
            satellites.append(
                NoteFABSatellite(
                    action: .play,
                    title: localized("Play recording", locale: locale),
                    systemImage: "play.fill"
                )
            )
        }
        return satellites
    }

    /// The state to draw, given the one that was asked for.
    ///
    /// A state the note can no longer honor falls back to the resting circle: a
    /// search pill over a view that cannot be searched, or a playback pill for a
    /// recording that was swept, would both be controls that do nothing.
    static func resolvedState(_ state: NoteFABState, context: NoteFABContext) -> NoteFABState {
        guard isVisible(context: context) else { return .resting }
        switch state {
        case .search:
            return context.canSearch ? .search : .resting
        case .playing:
            return context.hasAudio ? .playing : .resting
        case .resting, .fan:
            return state
        }
    }

    /// What clicking the resting circle does.
    ///
    /// Its glyph is a magnifier, so it opens the search wherever a search can be
    /// answered. Where one cannot, it opens the fan rather than doing nothing.
    static func restingActivation(context: NoteFABContext) -> NoteFABState {
        context.canSearch ? .search : .fan
    }

    /// Escape always lands on the resting circle, from any expanded shape.
    static func collapsed(from state: NoteFABState) -> NoteFABState { .resting }

    /// True when leaving the control should put it back to resting. Only the
    /// hover fan closes itself: a search and a playback the reader opened stay
    /// open until they are dismissed.
    static func collapsesOnExit(_ state: NoteFABState) -> Bool { state == .fan }

    // MARK: Search

    /// The mono count between the field and the steppers.
    static func matchCountText(current: Int?, total: Int, locale: Locale) -> String {
        let position = total > 0 ? (current.map { $0 + 1 } ?? 0) : 0
        return String(
            format: localized("%1$d of %2$d", locale: locale),
            locale: locale,
            position,
            total
        )
    }

    /// What a screen reader hears instead of the mono count.
    static func matchCountLabel(current: Int?, total: Int, locale: Locale) -> String {
        guard total > 0 else { return localized("No matches", locale: locale) }
        return String(
            format: localized("Match %1$d of %2$d", locale: locale),
            locale: locale,
            (current ?? 0) + 1,
            total
        )
    }

    /// The match one step away, wrapping at both ends.
    ///
    /// Wrapping is what makes the two buttons enough to reach every match: a
    /// reader who steps past the last one is looking for the first one again.
    static func steppedMatch(from current: Int?, total: Int, step: NoteFABMatchStep) -> Int? {
        guard total > 0 else { return nil }
        guard let current, current >= 0, current < total else {
            return step == .next ? 0 : total - 1
        }
        switch step {
        case .next:
            return (current + 1) % total
        case .previous:
            return (current - 1 + total) % total
        }
    }

    /// Where the current match lands after the matches themselves changed.
    ///
    /// Typing another letter renumbers everything, so the reader is put back at
    /// the first match rather than at a number that now means another word.
    static func resetMatch(total: Int) -> Int? {
        total > 0 ? 0 : nil
    }

    /// True when the steppers can be pressed.
    static func canStepMatches(total: Int) -> Bool { total > 1 }

    // MARK: Playback

    static func progressFraction(currentTime: TimeInterval, duration: TimeInterval) -> Double {
        guard duration > 0 else { return 0 }
        return min(1, max(0, currentTime / duration))
    }

    /// The time a click at this fraction of the track seeks to.
    static func seekTime(fraction: Double, duration: TimeInterval) -> TimeInterval {
        guard duration > 0 else { return 0 }
        return min(1, max(0, fraction)) * duration
    }

    /// "cur / total", in the mono slot at the end of the playback pill.
    static func clockText(currentTime: TimeInterval, duration: TimeInterval) -> String {
        let elapsed = NoteRowPresentation.elapsedText(max(0, currentTime))
        let total = NoteRowPresentation.elapsedText(max(0, duration))
        return "\(elapsed) / \(total)"
    }

    // MARK: Copy

    /// Titles

    static func restingLabel(context: NoteFABContext, locale: Locale) -> String {
        context.canSearch
            ? localized("Find in this note", locale: locale)
            : localized("Note actions", locale: locale)
    }

    static func searchPlaceholder(locale: Locale) -> String {
        localized("Find in this note", locale: locale)
    }

    static func nextMatchLabel(locale: Locale) -> String {
        localized("Next match", locale: locale)
    }

    static func previousMatchLabel(locale: Locale) -> String {
        localized("Previous match", locale: locale)
    }

    static func closeLabel(locale: Locale) -> String {
        localized("Close", locale: locale)
    }

    /// What the footer flashes after a copy. The app already has this word, so a
    /// copy confirms itself the same way everywhere.
    static func copyConfirmation(locale: Locale) -> String {
        localized("Copied!", locale: locale)
    }
}
