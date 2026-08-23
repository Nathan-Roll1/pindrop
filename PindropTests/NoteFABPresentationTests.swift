//
//  NoteFABPresentationTests.swift
//  PindropTests
//
//  Created on 2026-08-23.
//

import Foundation
import Testing
@testable import Pindrop

@Suite("Note FAB presentation (Round B)")
struct NoteFABPresentationTests {

    private let locale = Locale(identifier: "en")

    // MARK: - Who owns the corner

    @Test func theAskSurfaceTakesTheCorner() {
        let context = NoteFABContext(hasAudio: true, canAsk: true, isAskSurfaceOpen: true)
        #expect(!NoteFABPresentation.isVisible(context: context))
        // Whatever shape it was in, it is not drawn.
        #expect(NoteFABPresentation.resolvedState(.search, context: context) == .resting)
    }

    @Test func aRunningCaptureTakesTheCorner() {
        let context = NoteFABContext(hasAudio: true, isCaptureDockVisible: true)
        #expect(!NoteFABPresentation.isVisible(context: context))
    }

    @Test func aQuietNoteKeepsTheCorner() {
        #expect(NoteFABPresentation.isVisible(context: NoteFABContext()))
    }

    // MARK: - Satellites

    @Test func copyIsAlwaysOffered() {
        let satellites = NoteFABPresentation.satellites(context: NoteFABContext(), locale: locale)
        #expect(satellites.map(\.action) == [.copy])
    }

    @Test func playingIsOfferedOnlyWithAudio() {
        let withAudio = NoteFABPresentation.satellites(
            context: NoteFABContext(hasAudio: true),
            locale: locale
        )
        #expect(withAudio.map(\.action) == [.copy, .play])
    }

    @Test func askIsOfferedOnlyWhenTheShellCanAnswerIt() {
        let full = NoteFABPresentation.satellites(
            context: NoteFABContext(hasAudio: true, canAsk: true),
            locale: locale
        )
        // Fixed order, so the same action is always in the same place.
        #expect(full.map(\.action) == [.ask, .copy, .play])
        #expect(full.map(\.accessibilityIdentifier) == [
            "note.fab.ask", "note.fab.copy", "note.fab.play"
        ])
    }

    // MARK: - Shapes

    @Test func aSearchPillNeedsAViewThatCanBeSearched() {
        let searchable = NoteFABContext(canSearch: true)
        #expect(NoteFABPresentation.resolvedState(.search, context: searchable) == .search)
        #expect(NoteFABPresentation.resolvedState(.search, context: NoteFABContext()) == .resting)
    }

    @Test func aPlaybackPillNeedsAFile() {
        let playable = NoteFABContext(hasAudio: true)
        #expect(NoteFABPresentation.resolvedState(.playing, context: playable) == .playing)
        #expect(NoteFABPresentation.resolvedState(.playing, context: NoteFABContext()) == .resting)
    }

    @Test func theRestingCircleOpensWhateverItCanOffer() {
        #expect(
            NoteFABPresentation.restingActivation(context: NoteFABContext(canSearch: true))
                == .search
        )
        // A magnifier over a view that cannot be searched opens the fan rather
        // than doing nothing.
        #expect(NoteFABPresentation.restingActivation(context: NoteFABContext()) == .fan)
    }

    @Test func escapeAlwaysLandsOnTheRestingCircle() {
        for state: NoteFABState in [.fan, .search, .playing, .resting] {
            #expect(NoteFABPresentation.collapsed(from: state) == .resting)
        }
    }

    @Test func onlyTheHoverFanClosesItself() {
        #expect(NoteFABPresentation.collapsesOnExit(.fan))
        #expect(!NoteFABPresentation.collapsesOnExit(.search))
        #expect(!NoteFABPresentation.collapsesOnExit(.playing))
        #expect(!NoteFABPresentation.collapsesOnExit(.resting))
    }

    // MARK: - Matches

    @Test func theCountReadsAsAPosition() {
        #expect(
            NoteFABPresentation.matchCountText(current: 0, total: 3, locale: locale) == "1 of 3"
        )
        #expect(
            NoteFABPresentation.matchCountText(current: 2, total: 3, locale: locale) == "3 of 3"
        )
        // Nothing matched: the field says so rather than claiming a position.
        #expect(
            NoteFABPresentation.matchCountText(current: nil, total: 0, locale: locale) == "0 of 0"
        )
        #expect(
            NoteFABPresentation.matchCountText(current: nil, total: 4, locale: locale) == "0 of 4"
        )
    }

    @Test func steppingWrapsAtBothEnds() {
        #expect(NoteFABPresentation.steppedMatch(from: 0, total: 3, step: .next) == 1)
        #expect(NoteFABPresentation.steppedMatch(from: 2, total: 3, step: .next) == 0)
        #expect(NoteFABPresentation.steppedMatch(from: 0, total: 3, step: .previous) == 2)
        #expect(NoteFABPresentation.steppedMatch(from: 2, total: 3, step: .previous) == 1)
    }

    @Test func steppingWithNothingSelectedStartsAtTheNearestEnd() {
        #expect(NoteFABPresentation.steppedMatch(from: nil, total: 3, step: .next) == 0)
        #expect(NoteFABPresentation.steppedMatch(from: nil, total: 3, step: .previous) == 2)
        // A number left over from a longer list is not a match any more.
        #expect(NoteFABPresentation.steppedMatch(from: 9, total: 3, step: .next) == 0)
    }

    @Test func steppingThroughNothingStaysNowhere() {
        #expect(NoteFABPresentation.steppedMatch(from: nil, total: 0, step: .next) == nil)
        #expect(NoteFABPresentation.steppedMatch(from: 1, total: 0, step: .previous) == nil)
        #expect(!NoteFABPresentation.canStepMatches(total: 0))
        #expect(!NoteFABPresentation.canStepMatches(total: 1))
        #expect(NoteFABPresentation.canStepMatches(total: 2))
    }

    @Test func anotherLetterPutsTheReaderBackOnTheFirstMatch() {
        #expect(NoteFABPresentation.resetMatch(total: 5) == 0)
        #expect(NoteFABPresentation.resetMatch(total: 0) == nil)
    }

    // MARK: - Playback

    @Test func progressIsClampedToTheRecording() {
        #expect(NoteFABPresentation.progressFraction(currentTime: 30, duration: 120) == 0.25)
        #expect(NoteFABPresentation.progressFraction(currentTime: 200, duration: 120) == 1)
        #expect(NoteFABPresentation.progressFraction(currentTime: -5, duration: 120) == 0)
        // Nothing loaded yet: no progress rather than a divide by zero.
        #expect(NoteFABPresentation.progressFraction(currentTime: 10, duration: 0) == 0)
    }

    @Test func seekingReadsTheTrackAsAFractionOfTheRecording() {
        #expect(NoteFABPresentation.seekTime(fraction: 0.5, duration: 120) == 60)
        #expect(NoteFABPresentation.seekTime(fraction: 1.4, duration: 120) == 120)
        #expect(NoteFABPresentation.seekTime(fraction: -0.2, duration: 120) == 0)
        #expect(NoteFABPresentation.seekTime(fraction: 0.5, duration: 0) == 0)
    }

    @Test func theClockReadsAsElapsedOverTotal() {
        #expect(NoteFABPresentation.clockText(currentTime: 65, duration: 130) == "01:05 / 02:10")
    }

    // MARK: - Anchor

    @Test func theAnchorSitsOpticallyOnTheContentEdge() {
        // The content column keeps a 40 gutter; a circle set flush with it reads
        // as inset, so the anchor is pushed out by a hair.
        #expect(NoteFABPresentation.trailingInset == 38)
        #expect(NoteFABPresentation.bottomInset == 20)
        #expect(NoteFABPresentation.restingDiameter == 36)
        #expect(NoteFABPresentation.satelliteDiameter == 32)
        #expect(NoteFABPresentation.satelliteGap == 8)
    }
}
