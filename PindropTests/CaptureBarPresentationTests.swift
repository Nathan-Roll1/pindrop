//
//  CaptureBarPresentationTests.swift
//  PindropTests
//
//  Created on 2026-08-22.
//

import Foundation
import Testing
@testable import Pindrop

@Suite("Capture bar presentation (WP4)")
struct CaptureBarPresentationTests {

    private let locale = Locale(identifier: "en")

    private func page(_ state: CaptureBarState) -> CaptureBarPresentation {
        CaptureBarPresentation.make(state: state, density: .page, locale: locale)
    }

    private func global(_ state: CaptureBarState) -> CaptureBarPresentation {
        CaptureBarPresentation.make(state: state, density: .global, locale: locale)
    }

    // MARK: - Clock

    @Test func theClockIsZeroPaddedMinutesAndSeconds() {
        #expect(page(CaptureBarState(elapsed: 0)).elapsedText == "00:00")
        #expect(page(CaptureBarState(elapsed: 243)).elapsedText == "04:03")
        #expect(global(CaptureBarState(elapsed: 3723)).elapsedText == "1:02:03")
    }

    // MARK: - Title and detail

    @Test func onlyTheGlobalBarNamesTheNote() {
        let state = CaptureBarState(noteTitle: "Weekly sync")
        #expect(page(state).title == nil)
        #expect(page(state).detail == nil)
        #expect(global(state).title == "Weekly sync")
        #expect(global(state).detail == "Recording continues while you work")
    }

    @Test func anUntitledNoteStillHasSomethingToShowFor() {
        #expect(global(CaptureBarState(noteTitle: "   ")).title == "Untitled Note")
        #expect(global(CaptureBarState(noteTitle: "")).title == "Untitled Note")
    }

    // MARK: - Source chips

    @Test func thePageBarShowsBothSourcesAndTheGlobalBarShowsNone() {
        let state = CaptureBarState(includesSystemAudio: true)
        #expect(page(state).chips.map(\.source) == [.microphone, .systemAudio])
        #expect(global(state).chips.isEmpty)
    }

    @Test func systemAudioReadsOnOnlyWhenItIsBeingRecorded() {
        let withSystem = page(CaptureBarState(includesSystemAudio: true))
        #expect(withSystem.chips.first { $0.source == .systemAudio }?.isOn == true)

        let withoutSystem = page(CaptureBarState(includesSystemAudio: false))
        #expect(withoutSystem.chips.first { $0.source == .systemAudio }?.isOn == false)
        // The microphone is always on: there is no capture without it.
        #expect(withoutSystem.chips.first { $0.source == .microphone }?.isOn == true)
    }

    @Test func chipsAreLockedOnceTheCaptureOwnsItsSourcesAndSayWhy() {
        for phase in [CaptureBarPhase.starting, .recording] {
            let chips = page(CaptureBarState(phase: phase)).chips
            let allLocked = chips.allSatisfy { !$0.isEnabled }
            let allExplained = chips.allSatisfy {
                $0.helpText == "Sources are fixed when the recording starts."
            }
            #expect(allLocked)
            #expect(allExplained)
        }
    }

    @Test func chipsCanStillBeChangedBeforeTheCaptureStarts() {
        let chips = page(CaptureBarState(phase: .idle)).chips
        let allEnabled = chips.allSatisfy(\.isEnabled)
        let noneExplained = chips.allSatisfy { $0.helpText == nil }
        #expect(allEnabled)
        #expect(noneExplained)
    }

    // MARK: - Actions

    @Test func thePageBarOffersOnlyFinish() {
        let actions = page(CaptureBarState(phase: .recording)).actions
        #expect(actions.map(\.kind) == [.finish])
        #expect(actions.first?.title == "Finish")
        #expect(actions.first?.isPrimary == true)
    }

    @Test func theGlobalBarOffersTheWayBackBeforeTheWayOut() {
        let actions = global(CaptureBarState(phase: .recording)).actions
        #expect(actions.map(\.kind) == [.openNote, .finish])
        #expect(actions.first?.title == "Open note")
        #expect(actions.first?.isPrimary == false)
    }

    @Test func finishWaitsUntilThereIsSomethingToFinish() {
        // Nothing has been recorded while the capture is still starting up.
        #expect(page(CaptureBarState(phase: .starting)).action(.finish)?.isEnabled == false)
        #expect(global(CaptureBarState(phase: .starting)).action(.finish)?.isEnabled == false)
        #expect(page(CaptureBarState(phase: .recording)).action(.finish)?.isEnabled == true)
        // Open note is always available: the note exists before audio does.
        #expect(global(CaptureBarState(phase: .starting)).action(.openNote)?.isEnabled == true)
    }

    // MARK: - Level bars

    @Test func onlyThePageBarMetersALiveRecording() {
        #expect(page(CaptureBarState(phase: .recording)).showsLevelBars)
        #expect(!page(CaptureBarState(phase: .starting)).showsLevelBars)
        #expect(!global(CaptureBarState(phase: .recording)).showsLevelBars)
    }

    // MARK: - Accessibility identifiers

    @Test func actionsAndChipsCarryStableIdentifiers() {
        let bar = global(CaptureBarState(phase: .recording))
        #expect(bar.action(.openNote)?.accessibilityIdentifier == "capture.bar.openNote")
        #expect(bar.action(.finish)?.accessibilityIdentifier == "capture.bar.finish")

        let chips = page(CaptureBarState()).chips
        #expect(chips.first?.accessibilityIdentifier == "capture.bar.source.microphone")
        #expect(chips.last?.accessibilityIdentifier == "capture.bar.source.systemAudio")
    }
}

@Suite("Global capture bar visibility (WP4)")
struct GlobalCaptureBarVisibilityTests {

    private let capturingNote = UUID()

    @Test func theStripShowsOnEveryDestinationThatIsNotTheCapturingNote() {
        #expect(GlobalCaptureBarVisibility.isVisible(
            isRecording: true,
            capturingNoteID: capturingNote,
            openNoteID: nil
        ))
        #expect(GlobalCaptureBarVisibility.isVisible(
            isRecording: true,
            capturingNoteID: capturingNote,
            openNoteID: UUID()
        ))
    }

    @Test func theCapturingNotePageDrawsItsOwnDockInstead() {
        #expect(!GlobalCaptureBarVisibility.isVisible(
            isRecording: true,
            capturingNoteID: capturingNote,
            openNoteID: capturingNote
        ))
    }

    @Test func nothingRecordingMeansNoStrip() {
        #expect(!GlobalCaptureBarVisibility.isVisible(
            isRecording: false,
            capturingNoteID: capturingNote,
            openNoteID: nil
        ))
        #expect(!GlobalCaptureBarVisibility.isVisible(
            isRecording: true,
            capturingNoteID: nil,
            openNoteID: nil
        ))
    }
}

@Suite("Capture level meter geometry (WP4)")
struct CaptureLevelGeometryTests {

    @Test func silenceStillDrawsARestingLine() {
        let bars = CaptureLevelGeometry.bars(level: 0, bands: .zero)
        let allResting = bars.allSatisfy { $0 == CaptureLevelGeometry.restingFraction }
        #expect(bars.count == CaptureLevelGeometry.barCount)
        #expect(allResting)
    }

    @Test func aLoudFullSpectrumSignalFillsTheMeter() {
        let bars = CaptureLevelGeometry.bars(
            level: 1,
            bands: AudioBandLevels(low: 1, mid: 1, high: 1)
        )
        let allFull = bars.allSatisfy { $0 == 1 }
        #expect(allFull)
    }

    @Test func theBandsGiveTheMeterItsShape() {
        let bars = CaptureLevelGeometry.bars(
            level: 1,
            bands: AudioBandLevels(low: 0.9, mid: 0.5, high: 0.2)
        )
        // Low outside, high in the middle, symmetric.
        #expect(bars[0] == bars[4])
        #expect(bars[1] == bars[3])
        #expect(bars[0] > bars[1])
        #expect(bars[1] > bars[2])
    }

    @Test func aQuietSignalNeverExceedsALoudOne() {
        let bands = AudioBandLevels(low: 1, mid: 1, high: 1)
        let quiet = CaptureLevelGeometry.bars(level: 0.1, bands: bands)
        let loud = CaptureLevelGeometry.bars(level: 0.9, bands: bands)
        let everyBarGrew = zip(quiet, loud).allSatisfy { $0 < $1 }
        #expect(everyBarGrew)
    }

    @Test func outOfRangeMetersAreClamped() {
        let bars = CaptureLevelGeometry.bars(
            level: 4,
            bands: AudioBandLevels(low: -1, mid: 9, high: 0.5)
        )
        let allInRange = bars.allSatisfy {
            $0 >= CaptureLevelGeometry.restingFraction && $0 <= 1
        }
        #expect(allInRange)
    }

    @Test func theMeterMatchesTheDesignWidth() {
        #expect(CaptureLevelGeometry.width == 46)
        #expect(CaptureLevelGeometry.height == 16)
    }
}
