//
//  MeetingInvitationControllerTests.swift
//  PindropTests
//
//  Created on 2026-09-03.
//
//  The offer to record a detected call: the opt-in notification with its rate
//  limits, and the one-time in-app ask that makes the notification findable.
//

import Foundation
import PindropCore
import Testing

@testable import Pindrop

/// The clock, the capture, and the main window, all stepped by hand.
@MainActor
private final class MeetingInvitationTestState {
    var now = Date(timeIntervalSinceReferenceDate: 20_000)
    var isCapturing = false
    var isMainWindowVisible = false
    /// How many times the controller asked for a note that records the call.
    var recordedCallCount = 0

    func advance(by interval: TimeInterval) {
        now = now.addingTimeInterval(interval)
    }
}

@MainActor
@Suite(.serialized)
struct MeetingInvitationControllerTests {

    private struct Harness {
        let sut: MeetingInvitationController
        let settings: SettingsStore
        let notifier: MockMeetingCallNotifier
        let ask: MockMeetingCallAskPresenter
        let state: MeetingInvitationTestState
    }

    private let zoom = DetectedConferenceCall(
        bundleIdentifier: "us.zoom.xos",
        startedAt: Date(timeIntervalSinceReferenceDate: 20_000)
    )

    // MARK: - Surface B: the opt-in notification

    @Test
    func oneCallProducesAtMostOneNotification() async {
        let harness = makeHarness()
        defer { cleanup(harness) }
        harness.settings.notifyWhenCallStarts = true
        // The ask has its own tests below; keep it out of this one.
        harness.settings.callNotificationAskAnswered = true

        await harness.sut.handleDetectedCall(zoom)
        // The monitor republishes the same call on every poll.
        await harness.sut.handleDetectedCall(zoom)
        // The call drops and comes straight back, still inside the rate limit.
        harness.state.advance(by: 29 * 60)
        await harness.sut.handleDetectedCall(nil)
        await harness.sut.handleDetectedCall(zoom)

        #expect(harness.notifier.postedInvitations.count == 1)
        #expect(harness.notifier.postedInvitations.first?.title == "A call started")
        #expect(harness.notifier.postedInvitations.first?.body == "Record it as a note?")
        #expect(harness.notifier.postedInvitations.first?.recordActionTitle == "Record")
        #expect(harness.notifier.postedInvitations.first?.notNowActionTitle == "Not now")
    }

    @Test
    func noNotificationWhileACaptureIsRunning() async {
        let harness = makeHarness()
        defer { cleanup(harness) }
        harness.settings.notifyWhenCallStarts = true
        harness.settings.callNotificationAskAnswered = true
        harness.state.isCapturing = true

        await harness.sut.handleDetectedCall(zoom)

        #expect(harness.notifier.postedInvitations.isEmpty)
    }

    @Test
    func notNowSuppressesThatAppUntilTheCallEnds() async {
        let harness = makeHarness()
        defer { cleanup(harness) }
        harness.settings.notifyWhenCallStarts = true
        harness.settings.callNotificationAskAnswered = true

        await harness.sut.handleDetectedCall(zoom)
        #expect(harness.notifier.postedInvitations.count == 1)

        harness.sut.handleNotificationAction(.notNow)
        // Dismissing an offer never starts anything.
        #expect(harness.state.recordedCallCount == 0)

        // Past the rate limit, so only the dismissal can hold the second offer
        // back. The same call is still running.
        harness.state.advance(by: 31 * 60)
        await harness.sut.handleDetectedCall(zoom)
        #expect(harness.notifier.postedInvitations.count == 1)

        // The call ends, and the next one is offered again: the dismissal
        // answered one call, not the app.
        await harness.sut.handleDetectedCall(nil)
        harness.state.advance(by: 31 * 60)
        await harness.sut.handleDetectedCall(zoom)
        #expect(harness.notifier.postedInvitations.count == 2)

        // The other action is the whole point of the notification.
        harness.sut.handleNotificationAction(.record)
        #expect(harness.state.recordedCallCount == 1)
    }

    @Test
    func deniedAuthorizationTurnsTheSettingOff() async {
        let harness = makeHarness()
        defer { cleanup(harness) }
        harness.settings.callNotificationAskAnswered = true
        // The row was on, and permission was revoked in System Settings since.
        harness.settings.notifyWhenCallStarts = true
        harness.notifier.authorizationState = .denied

        await harness.sut.handleDetectedCall(zoom)

        #expect(harness.notifier.postedInvitations.isEmpty)
        #expect(!harness.settings.notifyWhenCallStarts)
        #expect(harness.sut.isNotificationAuthorizationDenied)
    }

    @Test
    func aCaptureStartedWhileAskingForPermissionCancelsTheOffer() async {
        let harness = makeHarness()
        defer { cleanup(harness) }
        harness.settings.notifyWhenCallStarts = true
        harness.settings.callNotificationAskAnswered = true
        // The authorization read is a round trip to the system. A hotkey start
        // lands inside it, which the "never while a capture is running" rule has
        // to survive as well as it survives a start before it.
        harness.notifier.onAuthorizationStateRead = { harness.state.isCapturing = true }

        await harness.sut.handleDetectedCall(zoom)

        #expect(harness.notifier.postedInvitations.isEmpty)
    }

    @Test
    func aCallThatEndsWhileAskingForPermissionIsNotOffered() async {
        let harness = makeHarness()
        defer { cleanup(harness) }
        harness.settings.notifyWhenCallStarts = true
        harness.settings.callNotificationAskAnswered = true
        // The call ends inside the authorization read. An alert posted after
        // that would outlive the call, and its "Not now" would answer nothing.
        harness.notifier.onAuthorizationStateRead = {
            await harness.sut.handleDetectedCall(nil)
        }

        await harness.sut.handleDetectedCall(zoom)

        #expect(harness.notifier.postedInvitations.isEmpty)

        // The rate limit did not record an offer that never went out, so the
        // next call is still offered.
        await harness.sut.handleDetectedCall(zoom)
        #expect(harness.notifier.postedInvitations.count == 1)
    }

    @Test
    func aRefusedPermissionExplainsTheDeadSwitchOnTheNextLaunch() async {
        let harness = makeHarness()
        defer { cleanup(harness) }
        // Nobody has been asked yet: an untouched install must not claim that
        // notifications were turned off.
        harness.notifier.authorizationState = .notDetermined
        await harness.sut.refreshAuthorizationState()
        #expect(!harness.sut.isNotificationAuthorizationDenied)

        // Turned on in an earlier run, refused since. The denial is not
        // persisted, so the row learns it from the system before it is pressed.
        harness.settings.notifyWhenCallStarts = true
        harness.notifier.authorizationState = .denied
        await harness.sut.refreshAuthorizationState()

        #expect(harness.sut.isNotificationAuthorizationDenied)
        #expect(!harness.settings.notifyWhenCallStarts)
    }

    // MARK: - Surface C: the one-time ask

    @Test
    func theFirstDetectedCallArmsTheOneTimeAsk() async {
        let harness = makeHarness()
        defer { cleanup(harness) }
        harness.ask.answer = true

        // The person is in the call window, so the ask waits.
        await harness.sut.handleDetectedCall(zoom)
        #expect(harness.ask.presentationCount == 0)

        // The next time the main window is up, it is asked.
        harness.state.isMainWindowVisible = true
        await harness.sut.presentPendingAskIfNeeded()

        #expect(harness.ask.presentationCount == 1)
        #expect(harness.settings.callNotificationAskAnswered)
        // "Notify me" runs the same authorization request the Settings row runs.
        #expect(harness.notifier.authorizationRequestCount == 1)
        #expect(harness.settings.notifyWhenCallStarts)
    }

    @Test
    func theAskIsNeverShownTwice() async {
        let harness = makeHarness()
        defer { cleanup(harness) }
        harness.ask.answer = false

        harness.state.isMainWindowVisible = true
        await harness.sut.handleDetectedCall(zoom)
        #expect(harness.ask.presentationCount == 1)
        #expect(harness.settings.callNotificationAskAnswered)
        // "No thanks" is an answer, so nothing is turned on and nothing is asked.
        #expect(!harness.settings.notifyWhenCallStarts)
        #expect(harness.notifier.authorizationRequestCount == 0)

        await harness.sut.handleDetectedCall(nil)
        await harness.sut.handleDetectedCall(zoom)
        await harness.sut.presentPendingAskIfNeeded()

        #expect(harness.ask.presentationCount == 1)
    }

    @Test
    func theAskIsSkippedWhenTheNotificationIsAlreadyOn() async {
        let harness = makeHarness()
        defer { cleanup(harness) }
        // This person found the Meetings row on their own and turned it on.
        let isGranted = await harness.sut.setNotifyWhenCallStarts(true)
        #expect(isGranted)
        #expect(harness.settings.notifyWhenCallStarts)
        // Turning the row on is the answer, so nothing is left to ask.
        #expect(harness.settings.callNotificationAskAnswered)

        harness.state.isMainWindowVisible = true
        await harness.sut.handleDetectedCall(zoom)
        await harness.sut.presentPendingAskIfNeeded()

        // The banner is the offer. A modal asking whether they want the banner
        // they are looking at is the one case this ask exists to skip.
        #expect(harness.ask.presentationCount == 0)
        #expect(harness.notifier.postedInvitations.count == 1)
    }

    @Test
    func theAskIsNotShownDuringACapture() async {
        let harness = makeHarness()
        defer { cleanup(harness) }
        harness.state.isMainWindowVisible = true
        harness.state.isCapturing = true

        await harness.sut.handleDetectedCall(zoom)
        await harness.sut.presentPendingAskIfNeeded()

        #expect(harness.ask.presentationCount == 0)
        #expect(!harness.settings.callNotificationAskAnswered)

        // Still armed: the recording ended, and the question is still worth asking.
        harness.state.isCapturing = false
        await harness.sut.presentPendingAskIfNeeded()

        #expect(harness.ask.presentationCount == 1)
    }

    // MARK: - Helpers

    private func makeHarness() -> Harness {
        let settings = SettingsStore()
        settings.resetAllSettings()
        // The notification copy is asserted in English, so pin the interface locale.
        settings.selectedAppLocaleRawValue = AppLocale.english.rawValue

        let state = MeetingInvitationTestState()
        let notifier = MockMeetingCallNotifier()
        let ask = MockMeetingCallAskPresenter()
        let scheduler = TestConferenceAudioScheduler()
        // The monitor is never started here: every test drives the controller
        // with the reports the monitor would have made.
        let monitor = ConferenceAudioMonitor(
            probe: MockConferenceAudioProcessProbe(),
            now: { state.now },
            pollScheduler: scheduler.pollScheduler,
            processListObserver: scheduler.processListObserver
        )
        let sut = MeetingInvitationController(
            monitor: monitor,
            settingsStore: settings,
            notifier: notifier,
            askPresenter: ask,
            isCaptureRunning: { state.isCapturing },
            isMainWindowVisible: { state.isMainWindowVisible },
            now: { state.now }
        )
        sut.onRecordCall = { state.recordedCallCount += 1 }

        return Harness(sut: sut, settings: settings, notifier: notifier, ask: ask, state: state)
    }

    private func cleanup(_ harness: Harness) {
        harness.settings.resetAllSettings()
    }
}
