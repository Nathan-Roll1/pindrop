//
//  PindropUITests.swift
//  PindropUITests
//
//  Created on 2026-03-21.
//

import AppKit
import XCTest

final class PindropUITests: XCTestCase {
    private let targetBundleIdentifier = "tech.watzon.pindrop"
    private let testModeKey = "PINDROP_TEST_MODE"
    private let uiTestModeKey = "PINDROP_UI_TEST_MODE"
    private let uiTestSurfaceKey = "PINDROP_UI_TEST_SURFACE"
    private let settingsTabKey = "PINDROP_UI_TEST_SETTINGS_TAB"
    private let defaultsSuiteKey = "PINDROP_TEST_USER_DEFAULTS_SUITE"
    private let captureStartPendingKey = "PINDROP_UI_TEST_CAPTURE_START_PENDING"
    private var launchedApplication: XCUIApplication?
    private var launchedDefaultsSuite: String?

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    override func tearDownWithError() throws {
        if let launchedApplication, launchedApplication.state != .notRunning {
            launchedApplication.terminate()
        }
        launchedApplication = nil

        if let launchedDefaultsSuite {
            UserDefaults(suiteName: launchedDefaultsSuite)?
                .removePersistentDomain(forName: launchedDefaultsSuite)
        }
        launchedDefaultsSuite = nil
    }

    @MainActor
    func testSettingsFixtureLaunches() throws {
        try skipIfTargetAppIsAlreadyRunning()

        let app = configuredApplication(settingsTab: "general")
        launchedApplication = app
        app.launch()

        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 5))
        XCTAssertTrue(
            app.descendants(matching: .any)["settings.toggle.launchAtLogin"]
                .waitForExistence(timeout: 5)
        )
        XCTAssertTrue(app.staticTexts["Interface Language"].exists)
    }

    @MainActor
    func testDictationTabFixtureLaunches() throws {
        try skipIfTargetAppIsAlreadyRunning()

        let app = configuredApplication(settingsTab: "dictation")
        launchedApplication = app
        app.launch()

        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 5))
        XCTAssertTrue(
            app.descendants(matching: .any)["settings.picker.dictationLanguage"]
                .waitForExistence(timeout: 5)
        )
        XCTAssertTrue(app.staticTexts["Microphone"].exists)
    }

    @MainActor
    func testAppearanceTabFixtureLaunches() throws {
        try skipIfTargetAppIsAlreadyRunning()

        let app = configuredApplication(settingsTab: "appearance")
        launchedApplication = app
        app.launch()

        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 5))
        XCTAssertTrue(
            app.descendants(matching: .any)["settings.theme.mode"]
                .waitForExistence(timeout: 5)
        )
        XCTAssertTrue(app.staticTexts["Theme Mode"].exists)
        XCTAssertTrue(app.staticTexts["Recording indicator"].exists)
    }

    @MainActor
    func testNoteEditorCitationsFixtureLaunches() throws {
        try skipIfTargetAppIsAlreadyRunning()

        let app = configuredApplication(surface: "noteEditorCitations")
        launchedApplication = app
        app.launch()

        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 5))
        let citationPanel = app.descendants(matching: .any)["note-editor-citation-panel"]
        XCTAssertTrue(citationPanel.waitForExistence(timeout: 5))
        XCTAssertTrue(citationPanel.label.contains("Confirm the release timeline before publishing."))
        XCTAssertTrue(citationPanel.label.contains("C1"))
        XCTAssertTrue(citationPanel.label.contains("C2"))

        let editorBody = app.descendants(matching: .any)["note-editor-body"]
        XCTAssertTrue(editorBody.waitForExistence(timeout: 5))
    }

    @MainActor
    func testMainShellFixtureRoutesAndStartsCapturePillars() throws {
        try skipIfTargetAppIsAlreadyRunning()

        let defaultsSuite = "tech.watzon.pindrop.ui-tests.main-shell.\(UUID().uuidString)"
        launchedDefaultsSuite = defaultsSuite

        let app = configuredApplication(surface: "mainShell", defaultsSuite: defaultsSuite)
        launchedApplication = app
        app.launch()

        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 5))

        let sidebarIdentifiers = [
            "sidebar.nav.dictate",
            "sidebar.nav.voiceNote",
            "sidebar.nav.meeting",
            "sidebar.nav.library",
            "sidebar.nav.notes",
            "sidebar.nav.stats",
            "sidebar.nav.dictionary",
            "sidebar.nav.models"
        ]
        for identifier in sidebarIdentifiers {
            XCTAssertTrue(
                app.descendants(matching: .any)[identifier].waitForExistence(timeout: 5),
                "Expected sidebar item \(identifier)"
            )
        }

        let callbackReady = app.descendants(matching: .any)["mainShell.callback.ready"]
        XCTAssertTrue(callbackReady.waitForExistence(timeout: 5))

        XCTAssertTrue(
            app.descendants(matching: .any)["main.destination.dictate"].waitForExistence(timeout: 5)
        )
        let dictateStart = app.descendants(matching: .any)["main.capture.dictate.start"]
        XCTAssertTrue(dictateStart.waitForExistence(timeout: 5))
        dictateStart.click()
        XCTAssertTrue(app.descendants(matching: .any)["mainShell.callback.dictate"].waitForExistence(timeout: 2))
        let dictateOpenLibrary = app.descendants(matching: .any)["capture.dictate.openLibrary"]
        XCTAssertTrue(dictateOpenLibrary.waitForExistence(timeout: 2))
        dictateOpenLibrary.click()
        XCTAssertTrue(
            app.descendants(matching: .any)["main.destination.library"].waitForExistence(timeout: 2)
        )

        selectSidebarItem("sidebar.nav.dictate", in: app)
        let dictateOpenShortcuts = app.descendants(matching: .any)["capture.dictate.openShortcuts"]
        XCTAssertTrue(dictateOpenShortcuts.waitForExistence(timeout: 2))
        dictateOpenShortcuts.click()
        XCTAssertTrue(app.descendants(matching: .any)["mainShell.callback.settings:shortcuts"].waitForExistence(timeout: 2))

        selectSidebarItem("sidebar.nav.voiceNote", in: app)
        XCTAssertTrue(
            app.descendants(matching: .any)["main.destination.voiceNote"].waitForExistence(timeout: 2)
        )
        let voiceNoteStart = app.descendants(matching: .any)["main.capture.voiceNote.start"]
        XCTAssertTrue(voiceNoteStart.waitForExistence(timeout: 2))
        voiceNoteStart.click()
        XCTAssertTrue(app.descendants(matching: .any)["mainShell.callback.voice-note"].waitForExistence(timeout: 2))
        let voiceNoteOpenNotes = app.descendants(matching: .any)["capture.voiceNote.openNotes"]
        XCTAssertTrue(voiceNoteOpenNotes.waitForExistence(timeout: 2))
        voiceNoteOpenNotes.click()
        XCTAssertTrue(
            app.descendants(matching: .any)["main.destination.notes"].waitForExistence(timeout: 2)
        )

        selectSidebarItem("sidebar.nav.meeting", in: app)
        XCTAssertTrue(
            app.descendants(matching: .any)["main.destination.meeting"].waitForExistence(timeout: 2)
        )
        let meetingStart = app.descendants(matching: .any)["main.capture.meeting.start"]
        XCTAssertTrue(meetingStart.waitForExistence(timeout: 2))
        meetingStart.click()

        let meetingSheet = app.descendants(matching: .any)["meetingCaptureOptionsSheet"]
        XCTAssertTrue(meetingSheet.waitForExistence(timeout: 2))
        XCTAssertTrue(app.staticTexts["Expected speakers"].waitForExistence(timeout: 2))
        let meetingSheetStart = app.buttons["Start Recording"].firstMatch
        XCTAssertTrue(meetingSheetStart.waitForExistence(timeout: 2))
        meetingSheetStart.click()
        XCTAssertTrue(app.descendants(matching: .any)["mainShell.callback.meeting:nil"].waitForExistence(timeout: 2))
        let meetingOpenLibrary = app.descendants(matching: .any)["capture.meeting.openLibrary"]
        XCTAssertTrue(meetingOpenLibrary.waitForExistence(timeout: 2))
        meetingOpenLibrary.click()
        XCTAssertTrue(
            app.descendants(matching: .any)["main.destination.library"].waitForExistence(timeout: 2)
        )

        assertDestination("library", afterSelecting: "sidebar.nav.library", in: app)
        assertDestination("notes", afterSelecting: "sidebar.nav.notes", in: app)
        assertDestination("stats", afterSelecting: "sidebar.nav.stats", in: app)
        assertDestination("dictionary", afterSelecting: "sidebar.nav.dictionary", in: app)
        assertDestination("models", afterSelecting: "sidebar.nav.models", in: app)
    }

    @MainActor
    func testMainShellDisablesCaptureStartsWhileAdmissionIsPending() throws {
        try skipIfTargetAppIsAlreadyRunning()

        let defaultsSuite = "tech.watzon.pindrop.ui-tests.main-shell-busy.\(UUID().uuidString)"
        launchedDefaultsSuite = defaultsSuite

        let app = configuredApplication(surface: "mainShell", defaultsSuite: defaultsSuite)
        app.launchEnvironment[captureStartPendingKey] = "1"
        launchedApplication = app
        app.launch()

        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 5))

        let captureDestinations = [
            (
                sidebar: "sidebar.nav.dictate",
                destination: "main.destination.dictate",
                start: "main.capture.dictate.start"
            ),
            (
                sidebar: "sidebar.nav.voiceNote",
                destination: "main.destination.voiceNote",
                start: "main.capture.voiceNote.start"
            ),
            (
                sidebar: "sidebar.nav.meeting",
                destination: "main.destination.meeting",
                start: "main.capture.meeting.start"
            )
        ]

        for capture in captureDestinations {
            selectSidebarItem(capture.sidebar, in: app)
            XCTAssertTrue(
                app.descendants(matching: .any)[capture.destination]
                    .waitForExistence(timeout: 2)
            )
            let start = app.descendants(matching: .any)[capture.start]
            XCTAssertTrue(start.waitForExistence(timeout: 2))
            XCTAssertFalse(start.isEnabled, "Expected \(capture.start) to be disabled")
        }

        XCTAssertFalse(
            app.descendants(matching: .any)["meetingCaptureOptionsSheet"].exists
        )
    }

    @MainActor
    private func selectSidebarItem(_ identifier: String, in app: XCUIApplication) {
        let item = app.descendants(matching: .any)[identifier]
        XCTAssertTrue(item.waitForExistence(timeout: 2), "Expected sidebar item \(identifier)")
        item.click()
    }

    @MainActor
    private func assertDestination(
        _ destination: String,
        afterSelecting sidebarIdentifier: String,
        in app: XCUIApplication
    ) {
        selectSidebarItem(sidebarIdentifier, in: app)
        XCTAssertTrue(
            app.descendants(matching: .any)["main.destination.\(destination)"]
                .waitForExistence(timeout: 2),
            "Expected \(destination) destination"
        )
    }

    private func configuredApplication(
        surface: String = "settings",
        settingsTab: String = "general",
        defaultsSuite: String? = nil
    ) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment[testModeKey] = "1"
        app.launchEnvironment[uiTestModeKey] = "1"
        app.launchEnvironment[uiTestSurfaceKey] = surface
        app.launchEnvironment[settingsTabKey] = settingsTab
        if let defaultsSuite {
            app.launchEnvironment[defaultsSuiteKey] = defaultsSuite
        }
        return app
    }

    private func skipIfTargetAppIsAlreadyRunning() throws {
        let runningApplications = NSRunningApplication.runningApplications(withBundleIdentifier: targetBundleIdentifier)
        if !runningApplications.isEmpty {
            throw XCTSkip("Quit Pindrop before running UI tests so XCTest does not force-terminate your active app session.")
        }
    }

}
