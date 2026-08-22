//
//  MainShellNavigationTests.swift
//  PindropTests
//
//  Created on 2026-07-09.
//

import Foundation
import Testing
@testable import Pindrop

@Suite("Main shell navigation")
struct MainShellNavigationTests {

    @Test func sidebarGroupsFlattenIntoCanonicalViewMenuOrder() {
        #expect(MainNavItem.sidebarGroups.map { $0.0 } == [.capture, .workspace, .tools])
        #expect(MainNavItem.sidebarGroups.map { $0.1 } == [
            [.dictate, .notes],
            [.library, .stats],
            [.dictionary, .models]
        ])

        let expected: [MainNavItem] = [
            .dictate,
            .notes,
            .library,
            .stats,
            .dictionary,
            .models
        ]
        #expect(MainNavItem.allSidebarItems == expected)
        #expect(Set(MainNavItem.allSidebarItems) == Set(MainNavItem.allCases))
        #expect(Set(MainNavItem.allSidebarItems).count == MainNavItem.allSidebarItems.count)
        #expect(expected.map(\.rawValue) == [
            "dictate",
            "notes",
            "library",
            "stats",
            "dictionary",
            "models"
        ])
        #expect(expected.enumerated().allSatisfy {
            MainNavItem.viewMenuShortcut(for: $0.element) == String($0.offset + 1)
        })
    }

    @Test func legacyRawValuesResolveToNotes() {
        #expect(MainNavItem.resolve(rawValue: "voice-note") == .notes)
        #expect(MainNavItem.resolve(rawValue: "meeting") == .notes)
        // Survivors keep their raw values, so they resolve to themselves.
        for item in MainNavItem.allCases {
            #expect(MainNavItem.resolve(rawValue: item.rawValue) == item)
        }
        #expect(MainNavItem.resolve(rawValue: "not-a-destination") == nil)
        #expect(MainNavItem(rawValue: "voice-note") == nil)
        #expect(MainNavItem(rawValue: "meeting") == nil)
    }

    @Test func sidebarMetadataUsesCanonicalTitlesAndIcons() {
        let locale = Locale(identifier: "en")

        #expect(MainNavItem.dictate.title(locale: locale) == "Dictate")
        #expect(MainNavItem.dictate.icon == "waveform")
        #expect(MainNavItem.notes.title(locale: locale) == "Notes")
        #expect(MainNavItem.notes.icon == "note.text")
        #expect(MainNavItem.library.title(locale: locale) == "Library")
        #expect(MainNavItem.library.icon == "books.vertical")
        #expect(MainNavItem.stats.title(locale: locale) == "Stats")
        #expect(MainNavItem.stats.icon == "chart.xyaxis.line")
        #expect(MainNavItem.dictionary.title(locale: locale) == "Dictionary")
        #expect(MainNavItem.dictionary.icon == "text.book.closed")
        #expect(MainNavItem.models.title(locale: locale) == "Models")
        #expect(MainNavItem.models.icon == "cpu")
    }

    @Test func accessibilityIdentifierComponentsMatchRawValues() {
        for item in MainNavItem.allCases {
            #expect(item.accessibilityIdentifierComponent == item.rawValue)
        }
    }

    @Test @MainActor func openNoteKeepsTheSidebarOnNotes() {
        let state = MainWindowRouteState()
        #expect(state.notesRoute == .list)

        let noteID = UUID()
        state.navigate(to: .library)
        state.openNote(id: noteID)
        #expect(state.selectedItem == .notes)
        #expect(state.notesRoute == .note(noteID))
        #expect(state.notesRoute.openNoteID == noteID)

        // Leaving Notes for another destination keeps the open note.
        state.navigate(to: .stats)
        #expect(state.selectedItem == .stats)
        #expect(state.notesRoute == .note(noteID))

        // Picking Notes in the sidebar returns to the list.
        state.navigate(to: .notes)
        #expect(state.selectedItem == .notes)
        #expect(state.notesRoute == .list)

        state.openNote(id: noteID)
        state.closeNote()
        #expect(state.notesRoute == .list)
        #expect(state.selectedItem == .notes)
    }

    @Test @MainActor func legacyRawValueNavigationLandsOnNotes() {
        let state = MainWindowRouteState()

        state.navigate(toRawValue: "voice-note")
        #expect(state.selectedItem == .notes)

        state.navigate(to: .library)
        state.navigate(toRawValue: "meeting")
        #expect(state.selectedItem == .notes)

        state.navigate(to: .library)
        state.navigate(toRawValue: "not-a-destination")
        #expect(state.selectedItem == .library)
    }

    @Test @MainActor func routeStateSelectsAndGeneratesLibraryRequests() throws {
        let state = MainWindowRouteState()
        #expect(state.selectedItem == .dictate)
        #expect(state.libraryOpenRequest == nil)
        #expect(state.librarySearchRequest == nil)

        state.navigate(to: .stats)
        #expect(state.selectedItem == .stats)

        let firstRecordID = UUID()
        state.openLibrary(recordID: firstRecordID)
        let firstOpenRequest = try #require(state.libraryOpenRequest)
        #expect(state.selectedItem == .library)
        #expect(firstOpenRequest.recordID == firstRecordID)
        #expect(firstOpenRequest.generation == 1)

        let secondRecordID = UUID()
        state.openLibrary(recordID: secondRecordID)
        let secondOpenRequest = try #require(state.libraryOpenRequest)
        #expect(secondOpenRequest.recordID == secondRecordID)
        #expect(secondOpenRequest.generation == 2)

        state.consumeLibraryOpenRequest(generation: firstOpenRequest.generation)
        #expect(state.libraryOpenRequest == secondOpenRequest)
        state.consumeLibraryOpenRequest(generation: secondOpenRequest.generation)
        #expect(state.libraryOpenRequest == nil)

        state.navigate(to: .notes)
        state.focusLibrarySearch()
        #expect(state.selectedItem == .library)
        #expect(state.librarySearchRequest == 1)
        state.focusLibrarySearch()
        #expect(state.librarySearchRequest == 2)
        state.consumeLibrarySearchRequest(generation: 1)
        #expect(state.librarySearchRequest == 2)
        state.consumeLibrarySearchRequest(generation: 2)
        #expect(state.librarySearchRequest == nil)
    }

    @Test @MainActor func captureStartClaimsAreExclusiveAndGenerationSafe() throws {
        let state = RecordingFeatureState()

        let firstClaim = try #require(state.claimCaptureStart())
        #expect(state.isCaptureStartPending)
        #expect(state.isCaptureBusy)
        #expect(state.claimCaptureStart() == nil)

        state.releaseCaptureStart(firstClaim)
        #expect(!state.isCaptureStartPending)
        #expect(!state.isCaptureBusy)

        let secondClaim = try #require(state.claimCaptureStart())
        state.releaseCaptureStart(firstClaim)
        #expect(state.isCaptureStartClaimCurrent(secondClaim))
        #expect(state.isCaptureStartPending)
        #expect(state.isCaptureBusy)

        state.releaseCaptureStart(secondClaim)
        #expect(!state.isCaptureStartPending)
        #expect(!state.isCaptureBusy)

        let invalidatedClaim = try #require(state.claimCaptureStart())
        state.invalidateCaptureStart()
        #expect(!state.isCaptureStartClaimCurrent(invalidatedClaim))
        #expect(!state.isCaptureBusy)

        state.setCaptureActivity(isRecording: true, isProcessing: false)
        #expect(state.isCaptureBusy)
        state.setCaptureActivity(isRecording: false, isProcessing: true)
        #expect(state.isCaptureBusy)
        state.setCaptureActivity(isRecording: false, isProcessing: false)
        #expect(!state.isCaptureBusy)
    }

    @Test func windowTokensMatchScorchedSpec() {
        #expect(AppTheme.Window.mainMinWidth == 980)
        #expect(AppTheme.Window.mainMinHeight == 640)
        #expect(AppTheme.Window.mainDefaultWidth == 1160)
        #expect(AppTheme.Window.mainDefaultHeight == 760)
        #expect(AppTheme.Window.sidebarWidth == 236)
        #expect(AppTheme.Window.sidebarCollapsedWidth == 64)
    }
}

@Suite("Status card phase mapping (U2)")
struct StatusCardPhaseTests {

    @Test func readyWhenIdle() {
        let phase = StatusCardPhase(isRecording: false, isProcessing: false)
        #expect(phase == .ready)
        #expect(phase.isActive == false)
    }

    @Test func recordingTakesPrecedenceOverProcessing() {
        let phase = StatusCardPhase(isRecording: true, isProcessing: true, duration: 12.4)
        #expect(phase == .recording(duration: 12.4))
        #expect(phase.isActive)
    }

    @Test func processingWhenNotRecording() {
        let phase = StatusCardPhase(isRecording: false, isProcessing: true)
        #expect(phase == .processing)
        #expect(phase.isActive)
    }

    @Test func formatDurationRoundsAndPads() {
        #expect(StatusCard.formatDuration(0) == "0:00")
        #expect(StatusCard.formatDuration(5) == "0:05")
        #expect(StatusCard.formatDuration(65.4) == "1:05")
        #expect(StatusCard.formatDuration(65.6) == "1:06")
        #expect(StatusCard.formatDuration(-3) == "0:00")
    }
}
