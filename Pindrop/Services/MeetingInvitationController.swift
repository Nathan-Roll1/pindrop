//
//  MeetingInvitationController.swift
//  Pindrop
//
//  Created on 2026-09-03.
//
//  Offers to record a call the ConferenceAudioMonitor detected.
//

import Foundation
import PindropCore

// MARK: - Values

/// One "A call started" alert, ready to post.
struct MeetingCallInvitation: Equatable, Sendable {
    /// The category every call alert carries. The app-level notification
    /// delegate dispatches on it, which is how the Sparkle update notification
    /// keeps its own handler.
    static let categoryIdentifier = "PindropCallInvitation"

    /// One per call app, so a later alert replaces the earlier one in Notification
    /// Centre instead of stacking under it.
    let identifier: String
    let bundleIdentifier: String
    let title: String
    let body: String
    let recordActionTitle: String
    let notNowActionTitle: String

    static func identifier(for bundleIdentifier: String) -> String {
        "\(categoryIdentifier).\(bundleIdentifier)"
    }
}

/// Which button on the call alert the person pressed.
enum MeetingCallNotificationAction: String, Sendable {
    case record = "PindropCallInvitationRecord"
    case notNow = "PindropCallInvitationNotNow"
}

/// What the system says about Pindrop's permission to post an alert.
///
/// Three states, not a Bool: "never asked" and "asked and refused" read the
/// same to a Bool, and only the second one earns the "turn them on in System
/// Settings" line under the Settings row.
enum MeetingCallAuthorizationState: Sendable {
    case notDetermined
    case granted
    case denied
}

// MARK: - Seams

/// The notification surface the invitation controller posts through.
///
/// A protocol because `UNUserNotificationCenter` asks the system for permission
/// and puts real alerts on a real screen, neither of which belongs in a test.
@MainActor
protocol MeetingCallNotifying: AnyObject {
    /// Asks for alert-only authorization. No sound: a chime during a call is the
    /// interruption this whole feature exists to avoid.
    func requestAlertAuthorization() async -> Bool
    /// Reads the authorization state fresh, so a revoke in System Settings is seen.
    func alertAuthorizationState() async -> MeetingCallAuthorizationState
    func post(_ invitation: MeetingCallInvitation) async
    /// Takes a delivered alert back when its call ends.
    func withdraw(invitationIdentifier: String)
}

/// Shows the one-time in-app ask and returns the answer.
///
/// `true` is "Notify me", `false` is "No thanks". Either answer is final, so
/// there is no third result to report.
@MainActor
protocol MeetingCallAskPresenting: AnyObject {
    func presentCallNotificationAsk() -> Bool
}

// MARK: - Controller

/// Turns a detected call into an offer to record it.
///
/// Two surfaces live here. The notification (surface B) is opt-in and rate
/// limited. The one-time ask (surface C) is what makes the notification
/// findable at all: without it, detection runs all day behind a Settings row
/// nobody has a reason to open. The menu item (surface A) needs no permission
/// and is built on the monitor directly.
@MainActor
@Observable
final class MeetingInvitationController {
    /// At most one alert per call app in this window.
    static let invitationInterval: TimeInterval = 30 * 60

    /// True when notifications are turned off for Pindrop at the system level.
    ///
    /// The Settings row reads this for its "turn them on in System Settings"
    /// line. It is derived from the last authorization answer, not persisted:
    /// the system is the authority, and it is read at `start()` and again on
    /// every post.
    private(set) var isNotificationAuthorizationDenied = false

    /// Starts a note that records both channels, with origin `.automation`.
    var onRecordCall: (() -> Void)?

    private let monitor: ConferenceAudioMonitor
    private let settingsStore: SettingsStore
    private let notifier: any MeetingCallNotifying
    private let askPresenter: any MeetingCallAskPresenting
    private let isCaptureRunning: () -> Bool
    private let isMainWindowVisible: () -> Bool
    private let now: () -> Date

    /// The call the monitor last reported, so a "Not now" knows which app it
    /// answered and the end of a call knows which alert to take back.
    private var reportedCall: DetectedConferenceCall?
    private var lastInvitationByBundle: [String: Date] = [:]
    /// Apps dismissed with "Not now". Cleared when that app's call ends.
    private var declinedBundleIdentifiers: Set<String> = []
    private var isAskArmed = false
    private var isPresentingAsk = false
    private var isStarted = false

    init(
        monitor: ConferenceAudioMonitor,
        settingsStore: SettingsStore,
        notifier: any MeetingCallNotifying,
        askPresenter: any MeetingCallAskPresenting,
        isCaptureRunning: @escaping () -> Bool,
        isMainWindowVisible: @escaping () -> Bool,
        now: @escaping () -> Date = Date.init
    ) {
        self.monitor = monitor
        self.settingsStore = settingsStore
        self.notifier = notifier
        self.askPresenter = askPresenter
        self.isCaptureRunning = isCaptureRunning
        self.isMainWindowVisible = isMainWindowVisible
        self.now = now
    }

    // MARK: Control

    /// Subscribes to the monitor.
    ///
    /// The monitor's observers are additive, so the menu bar rows keep their own
    /// subscription. A second call would add a second observer, and a second
    /// observer would post the same alert twice, so this runs once.
    func start() {
        guard !isStarted else { return }
        isStarted = true
        monitor.addDetectedCallObserver { [weak self] call in
            Task { @MainActor [weak self] in
                await self?.handleDetectedCall(call)
            }
        }
        // The denied state is not persisted, so without this read the Settings
        // row would come back after a relaunch with no subtitle and a switch
        // that refuses to move. The system is asked once instead.
        Task { @MainActor [weak self] in
            await self?.refreshAuthorizationState()
        }
    }

    /// Reads the system's answer once, so the Meetings row can explain a dead
    /// switch before it is pressed rather than after.
    func refreshAuthorizationState() async {
        await syncAuthorizationState()
    }

    // MARK: Detection

    /// Applies one report from the monitor.
    ///
    /// `async` because the authorization state is read from the system on every
    /// post: a permission revoked in System Settings has no other way in.
    func handleDetectedCall(_ call: DetectedConferenceCall?) async {
        let previous = reportedCall
        reportedCall = call

        guard let call else {
            guard let previous else { return }
            // A "Not now" answered one call, not the app.
            declinedBundleIdentifiers.remove(previous.bundleIdentifier)
            notifier.withdraw(
                invitationIdentifier: MeetingCallInvitation.identifier(
                    for: previous.bundleIdentifier
                )
            )
            return
        }

        await postInvitationIfAllowed(for: call)
        armAsk()
        await presentPendingAskIfNeeded()
    }

    /// Routes a press on the call alert. The app-level notification delegate is
    /// the only caller.
    func handleNotificationAction(_ action: MeetingCallNotificationAction) {
        switch action {
        case .record:
            Log.app.info("Recording a detected call from its notification")
            onRecordCall?()
        case .notNow:
            guard let bundleIdentifier = reportedCall?.bundleIdentifier else { return }
            declinedBundleIdentifiers.insert(bundleIdentifier)
            Log.app.info("Call notifications paused for \(bundleIdentifier) until this call ends")
        }
    }

    // MARK: Surface B, the notification

    /// Turns the notification on or off, asking for permission when it goes on.
    ///
    /// The Settings row and the one-time ask both come through here, so there is
    /// one authorization request in the app and one place that records a denial.
    @discardableResult
    func setNotifyWhenCallStarts(_ isOn: Bool) async -> Bool {
        guard isOn else {
            settingsStore.notifyWhenCallStarts = false
            return false
        }
        let isGranted = await notifier.requestAlertAuthorization()
        settingsStore.notifyWhenCallStarts = isGranted
        isNotificationAuthorizationDenied = !isGranted
        if isGranted {
            // Turning the row on is an answer to the one-time ask. Asking
            // someone whether they want the thing they just turned on is the
            // one case surface C exists to skip.
            settingsStore.callNotificationAskAnswered = true
        } else {
            Log.app.info("Call notifications stayed off: authorization was not granted")
        }
        return isGranted
    }

    private func postInvitationIfAllowed(for call: DetectedConferenceCall) async {
        guard settingsStore.notifyWhenCallStarts else { return }
        // A live recording is the one moment an offer to record is only noise.
        guard !isCaptureRunning() else { return }
        guard !declinedBundleIdentifiers.contains(call.bundleIdentifier) else { return }

        let timestamp = now()
        if let last = lastInvitationByBundle[call.bundleIdentifier],
           timestamp.timeIntervalSince(last) < Self.invitationInterval {
            return
        }
        guard await confirmAuthorization() else { return }
        // The authorization read is a round trip to the system, and both of the
        // rules above can change across it: a hotkey can start a recording, and
        // the call itself can end. Re-check rather than post into either.
        guard !isCaptureRunning(),
              reportedCall?.bundleIdentifier == call.bundleIdentifier else { return }

        lastInvitationByBundle[call.bundleIdentifier] = timestamp
        await notifier.post(makeInvitation(for: call))
        Log.app.info("Offered to record a call in \(call.bundleIdentifier)")
    }

    private func confirmAuthorization() async -> Bool {
        await syncAuthorizationState() == .granted
    }

    /// Reads the live authorization state and turns the setting off when it is
    /// gone, which is the only signal a revoke in System Settings ever sends.
    @discardableResult
    private func syncAuthorizationState() async -> MeetingCallAuthorizationState {
        let state = await notifier.alertAuthorizationState()
        isNotificationAuthorizationDenied = state == .denied
        if state != .granted, settingsStore.notifyWhenCallStarts {
            settingsStore.notifyWhenCallStarts = false
            Log.app.info("Call notifications turned off: authorization is no longer granted")
        }
        return state
    }

    private func makeInvitation(for call: DetectedConferenceCall) -> MeetingCallInvitation {
        let locale = settingsStore.selectedAppLocale.locale
        return MeetingCallInvitation(
            identifier: MeetingCallInvitation.identifier(for: call.bundleIdentifier),
            bundleIdentifier: call.bundleIdentifier,
            title: localized("A call started", locale: locale),
            body: localized("Record it as a note?", locale: locale),
            recordActionTitle: localized("Record", locale: locale),
            notNowActionTitle: localized("Not now", locale: locale)
        )
    }

    // MARK: Surface C, the one-time ask

    private func armAsk() {
        // Someone who already turned the row on has answered this question, and
        // the ask has nothing left to offer them.
        guard !settingsStore.callNotificationAskAnswered,
              !settingsStore.notifyWhenCallStarts,
              !isAskArmed else { return }
        isAskArmed = true
        Log.app.info("Armed the one-time call notification ask")
    }

    /// Shows the armed ask, if this is a moment to show it.
    ///
    /// Called on detection and again whenever the main window appears, because
    /// the first detected call almost always happens with the call app in front.
    func presentPendingAskIfNeeded() async {
        guard isAskArmed,
              !settingsStore.callNotificationAskAnswered,
              !settingsStore.notifyWhenCallStarts,
              !isPresentingAsk else { return }
        // Never over the call, and never over a live recording.
        guard isMainWindowVisible(), !isCaptureRunning() else { return }

        isPresentingAsk = true
        let wantsNotifications = askPresenter.presentCallNotificationAsk()
        isPresentingAsk = false
        isAskArmed = false
        // Either answer is final.
        settingsStore.callNotificationAskAnswered = true
        Log.app.info("One-time call notification ask answered accepted=\(wantsNotifications)")

        guard wantsNotifications else { return }
        await setNotifyWhenCallStarts(true)
    }
}
