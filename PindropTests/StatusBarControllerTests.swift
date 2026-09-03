//
//  StatusBarControllerTests.swift
//  PindropTests
//
//  Created on 2026-07-13.
//

import AppKit
import Testing
@testable import Pindrop
import PindropAI
import PindropCore

/// A conference monitor a test drives by hand, through the same seams the
/// monitor's own tests use. No Core Audio runs here, and no ten seconds pass.
@MainActor
private final class CallMonitorHarness {
    /// A reference box, so the monitor and the harness read one clock.
    @MainActor
    final class ClockBox {
        var current = Date(timeIntervalSinceReferenceDate: 20_000)
    }

    let monitor: ConferenceAudioMonitor

    private let probe: MockConferenceAudioProcessProbe
    private let scheduler: TestConferenceAudioScheduler
    private let box: ClockBox

    init() {
        let probe = MockConferenceAudioProcessProbe()
        let scheduler = TestConferenceAudioScheduler()
        let box = ClockBox()
        self.probe = probe
        self.scheduler = scheduler
        self.box = box
        monitor = ConferenceAudioMonitor(
            probe: probe,
            now: { box.current },
            pollScheduler: scheduler.pollScheduler,
            processListObserver: scheduler.processListObserver
        )
    }

    func reportCall() async {
        probe.setStates([conferenceProcess("us.zoom.xos", input: true, output: true)])
        await scheduler.tick()
        box.current = box.current.addingTimeInterval(
            ConferenceAudioMonitor.callConfirmationInterval
        )
        await scheduler.tick()
    }

    func endCall() async {
        probe.setStates([])
        await scheduler.tick()
    }
}

@MainActor
@Suite(.serialized)
struct StatusBarControllerTests {
    /// The status bar controller with both capture backends mocked, so
    /// `isSystemAudioCaptureAvailable` is true and the meeting rows are offered.
    private func makeStatusBarController(
        settingsStore: SettingsStore,
        conferenceAudioMonitor: ConferenceAudioMonitor? = nil
    ) throws -> StatusBarController {
        let audioRecorder = try AudioRecorder(
            permissionManager: MockPermissionProvider(),
            captureBackend: MockAudioCaptureBackend(identifier: "microphone"),
            systemAudioCaptureBackend: MockAudioCaptureBackend(identifier: "system")
        )
        return StatusBarController(
            audioRecorder: audioRecorder,
            settingsStore: settingsStore,
            conferenceAudioMonitor: conferenceAudioMonitor
        )
    }

    @Test func promptPresetMenuShowsSelectionAndRoutesChanges() throws {
        let settingsStore = SettingsStore()
        settingsStore.resetAllSettings()
        defer { settingsStore.resetAllSettings() }

        let provider = ProviderConfig(kind: .openai, displayName: "OpenAI")
        settingsStore.upsertProvider(provider)
        settingsStore.setAssignment(
            ModelAssignment(
                providerID: provider.id,
                modelID: "gpt-4o-mini",
                promptPresetID: BuiltInPresetID.cleanTranscript
            ),
            for: .transcriptionEnhancement
        )

        let audioRecorder = try AudioRecorder(
            permissionManager: MockPermissionProvider(),
            captureBackend: MockAudioCaptureBackend(identifier: "microphone"),
            systemAudioCaptureBackend: MockAudioCaptureBackend(identifier: "system")
        )
        let sut = StatusBarController(
            audioRecorder: audioRecorder,
            settingsStore: settingsStore
        )
        let clean = StatusBarController.PromptPresetOption(
            id: "clean-row-id",
            assignmentID: BuiltInPresetID.cleanTranscript,
            name: "Clean Transcript"
        )
        let meeting = StatusBarController.PromptPresetOption(
            id: "meeting-row-id",
            assignmentID: BuiltInPresets.meetingNotes.identifier,
            name: "Meeting Notes"
        )

        sut.updatePromptPresets([clean, meeting])

        var menu = try #require(sut.promptPresetMenuForTesting())
        #expect(menu.items.count == 2)
        #expect(menu.items[0].title == clean.name)
        #expect(menu.items[0].state == .on)
        #expect(menu.items[1].title == meeting.name)
        #expect(menu.items[1].state == .off)
        #expect(sut.promptPresetMenuItemForTesting()?.isEnabled == true)

        var didApplySelection = false
        sut.onSelectPromptPreset = { option in
            didApplySelection = AppCoordinator.applyPromptPresetSelection(
                option,
                to: settingsStore
            )
        }
        menu.performActionForItem(at: 1)
        #expect(didApplySelection)
        #expect(
            settingsStore.assignment(for: .transcriptionEnhancement)?.promptPresetID
                == meeting.assignmentID
        )
        #expect(settingsStore.selectedPresetId == meeting.id)

        #expect(menu.items[0].state == .off)
        #expect(menu.items[1].state == .on)

        settingsStore.selectedAppLocale = .german
        sut.reloadLocalizedStrings()
        menu = try #require(sut.promptPresetMenuForTesting())
        #expect(menu.items.count == 2)
        #expect(menu.items[0].state == .off)
        #expect(menu.items[1].state == .on)
        #expect(
            sut.promptPresetMenuItemForTesting()?.title
                == localized("Prompt Preset", locale: AppLocale.german.locale)
        )

        settingsStore.setAssignment(nil, for: .transcriptionEnhancement)
        sut.updateDynamicItems()
        #expect(sut.promptPresetMenuItemForTesting()?.isEnabled == false)
        #expect(!menu.items[0].isEnabled)
        #expect(!menu.items[1].isEnabled)

        sut.updatePromptPresets([])
        #expect(menu.items.isEmpty)
    }

    @Test func noteCaptureMenuItemsAppearOnlyOnceWiredAndCarryTheRequestedSources() throws {
        let settingsStore = SettingsStore()
        settingsStore.resetAllSettings()
        defer { settingsStore.resetAllSettings() }

        let sut = try makeStatusBarController(settingsStore: settingsStore)
        let locale = settingsStore.selectedAppLocale.locale
        let meetingNoteTitle = localized("New meeting note", locale: locale)
        let newNoteTitle = localized("New note", locale: locale)
        let systemAudioTitle = localized("New note with system audio", locale: locale)

        let menu = sut.menuForTesting()
        // Unwired: no dead rows.
        #expect(!menu.items.contains { $0.title == meetingNoteTitle })
        #expect(!menu.items.contains { $0.title == newNoteTitle })

        var requests: [NoteCaptureRequest] = []
        sut.configureNoteCapture { request in
            requests.append(request)
            return true
        }

        let startRecordingIndex = try #require(
            menu.items.firstIndex { $0.title == localized("Start Recording", locale: locale) }
        )
        let meetingNoteIndex = try #require(menu.items.firstIndex { $0.title == meetingNoteTitle })
        let newNoteIndex = try #require(menu.items.firstIndex { $0.title == newNoteTitle })
        // The note rows sit with the dictation rows, in order.
        #expect(meetingNoteIndex == startRecordingIndex + 1)
        #expect(newNoteIndex == meetingNoteIndex + 1)
        // "New meeting note" says the same thing in the words a person uses, so
        // the row it replaced is gone. The string itself stays: the notes list
        // still offers it, and LocalizationKeyResolutionTests still asserts it.
        #expect(!menu.items.contains { $0.title == systemAudioTitle })

        menu.performActionForItem(at: meetingNoteIndex)
        menu.performActionForItem(at: newNoteIndex)

        #expect(requests == [.meetingNote(recordsSystemAudio: true), .soloNote()])
        #expect(requests.map(\.requestedSourceKinds) == [
            [.microphone, .systemAudio],
            [.microphone]
        ])
    }

    @Test func recordThisCallIsAbsentWithoutACall() async throws {
        let settingsStore = SettingsStore()
        settingsStore.resetAllSettings()
        defer { settingsStore.resetAllSettings() }

        let calls = CallMonitorHarness()
        let sut = try makeStatusBarController(
            settingsStore: settingsStore,
            conferenceAudioMonitor: calls.monitor
        )
        sut.configureNoteCapture { _ in true }
        calls.monitor.start()

        let recordCallTitle = localized(
            "Record this call",
            locale: settingsStore.selectedAppLocale.locale
        )
        let menu = sut.menuForTesting()

        // No call: the row is absent, not a greyed-out row that says nothing.
        #expect(!menu.items.contains { $0.title == recordCallTitle })

        await calls.reportCall()
        let item = try #require(menu.items.first { $0.title == recordCallTitle })
        #expect(item.isEnabled)

        await calls.endCall()
        #expect(!menu.items.contains { $0.title == recordCallTitle })
    }

    @Test func recordThisCallNeverMovesTheStartRecordingItem() async throws {
        let settingsStore = SettingsStore()
        settingsStore.resetAllSettings()
        defer { settingsStore.resetAllSettings() }

        let calls = CallMonitorHarness()
        let sut = try makeStatusBarController(
            settingsStore: settingsStore,
            conferenceAudioMonitor: calls.monitor
        )
        sut.configureNoteCapture { _ in true }
        calls.monitor.start()

        let locale = settingsStore.selectedAppLocale.locale
        let startRecordingTitle = localized("Start Recording", locale: locale)
        let newNoteTitle = localized("New note", locale: locale)
        let recordCallTitle = localized("Record this call", locale: locale)
        let menu = sut.menuForTesting()

        let startRecordingIndex = try #require(
            menu.items.firstIndex { $0.title == startRecordingTitle }
        )

        await calls.reportCall()
        // The primary action stays under the same pixels while a call runs.
        #expect(menu.items.firstIndex { $0.title == startRecordingTitle } == startRecordingIndex)
        let newNoteIndex = try #require(menu.items.firstIndex { $0.title == newNoteTitle })
        let recordCallIndex = try #require(menu.items.firstIndex { $0.title == recordCallTitle })
        #expect(recordCallIndex == newNoteIndex + 1)
        #expect(recordCallIndex > startRecordingIndex)

        await calls.endCall()
        #expect(menu.items.firstIndex { $0.title == startRecordingTitle } == startRecordingIndex)
    }

    @Test func newMeetingNoteRequestsBothSourcesAndNoTemplate() async throws {
        let settingsStore = SettingsStore()
        settingsStore.resetAllSettings()
        defer { settingsStore.resetAllSettings() }

        let calls = CallMonitorHarness()
        let sut = try makeStatusBarController(
            settingsStore: settingsStore,
            conferenceAudioMonitor: calls.monitor
        )
        var requests: [NoteCaptureRequest] = []
        sut.configureNoteCapture { request in
            requests.append(request)
            return true
        }
        calls.monitor.start()
        await calls.reportCall()

        let locale = settingsStore.selectedAppLocale.locale
        let menu = sut.menuForTesting()
        let meetingNoteIndex = try #require(
            menu.items.firstIndex { $0.title == localized("New meeting note", locale: locale) }
        )
        let recordCallIndex = try #require(
            menu.items.firstIndex { $0.title == localized("Record this call", locale: locale) }
        )

        menu.performActionForItem(at: meetingNoteIndex)
        menu.performActionForItem(at: recordCallIndex)

        // Both meeting entries start the same capture.
        #expect(
            requests == [
                .meetingNote(recordsSystemAudio: true),
                .meetingNote(recordsSystemAudio: true),
            ]
        )

        let request = try #require(requests.first)
        #expect(request.requestedSourceKinds == [.microphone, .systemAudio])

        // Phase 3 changes the sources, not the shape of the enhanced note: a
        // meeting note carries no template preset, so it reads exactly like the
        // system-audio note the renamed row used to start.
        let intentRequest = request.captureIntentRequest(origin: .menuBar)
        #expect(intentRequest.requestedTemplatePresetIdentifier == nil)
        let intent = try intentRequest.intent(
            sessionID: UUID(),
            requestedSourceKinds: request.requestedSourceKinds
        )
        #expect(intent.requestedSourceKinds == [.microphone, .systemAudio])
        #expect(intent.requestedTemplatePresetIdentifier == nil)
        #expect(intent.origin == .menuBar)
    }

    @Test func meetingNoteFollowsTheRecordSystemAudioSetting() throws {
        let settingsStore = SettingsStore()
        settingsStore.resetAllSettings()
        defer { settingsStore.resetAllSettings() }

        settingsStore.recordSystemAudioInMeetingNotes = false
        let sut = try makeStatusBarController(settingsStore: settingsStore)
        var requests: [NoteCaptureRequest] = []
        sut.configureNoteCapture { request in
            requests.append(request)
            return true
        }

        let locale = settingsStore.selectedAppLocale.locale
        let menu = sut.menuForTesting()
        let meetingNoteIndex = try #require(
            menu.items.firstIndex { $0.title == localized("New meeting note", locale: locale) }
        )
        menu.performActionForItem(at: meetingNoteIndex)

        // The Meetings row is the one control over what a meeting note records,
        // so with it off the meeting row asks for the microphone alone.
        #expect(requests == [.meetingNote(recordsSystemAudio: false)])
        let request = try #require(requests.first)
        #expect(!request.includeSystemAudio)
        #expect(request.requestedSourceKinds == [.microphone])
    }

    @Test func newNoteRequestsTheMicrophoneOnly() throws {
        let settingsStore = SettingsStore()
        settingsStore.resetAllSettings()
        defer { settingsStore.resetAllSettings() }

        let sut = try makeStatusBarController(settingsStore: settingsStore)
        var requests: [NoteCaptureRequest] = []
        sut.configureNoteCapture { request in
            requests.append(request)
            return true
        }

        let menu = sut.menuForTesting()
        let newNoteIndex = try #require(
            menu.items.firstIndex {
                $0.title == localized("New note", locale: settingsStore.selectedAppLocale.locale)
            }
        )
        menu.performActionForItem(at: newNoteIndex)

        #expect(requests == [.soloNote()])
        let request = try #require(requests.first)
        #expect(!request.includeSystemAudio)
        #expect(request.requestedSourceKinds == [.microphone])
    }

    @Test func promptPresetSelectionMapsCustomIDsAndNoOpsWhenDisabled() {
        let settingsStore = SettingsStore()
        settingsStore.resetAllSettings()
        defer { settingsStore.resetAllSettings() }

        let customID = UUID().uuidString
        let custom = StatusBarController.PromptPresetOption(
            id: customID,
            assignmentID: customID,
            name: "Custom Preset"
        )

        #expect(!AppCoordinator.applyPromptPresetSelection(custom, to: settingsStore))
        #expect(settingsStore.selectedPresetId == nil)

        settingsStore.setAssignment(
            ModelAssignment(
                providerID: UUID(),
                modelID: "gpt-4o-mini",
                promptPresetID: BuiltInPresetID.cleanTranscript
            ),
            for: .transcriptionEnhancement
        )

        #expect(AppCoordinator.applyPromptPresetSelection(custom, to: settingsStore))
        #expect(
            settingsStore.assignment(for: .transcriptionEnhancement)?.promptPresetID
                == customID
        )
        #expect(settingsStore.selectedPresetId == customID)
    }
}
