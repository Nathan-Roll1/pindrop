//
//  MeetingCallNotifications.swift
//  Pindrop
//
//  Created on 2026-09-03.
//
//  Posts the call alert, and owns the app's single notification-centre delegate.
//

import Foundation
import PindropCore
import UserNotifications

// MARK: - Posting

/// Posts the call alert through `UNUserNotificationCenter`.
///
/// Built only on a machine that can record a call, because
/// `UNUserNotificationCenter.current()` needs a real app bundle.
@MainActor
final class MeetingCallNotificationCenter: MeetingCallNotifying {
    private let center: UNUserNotificationCenter

    init(center: UNUserNotificationCenter = .current()) {
        self.center = center
    }

    func requestAlertAuthorization() async -> Bool {
        do {
            // Alert only. Sparkle asks for badge and sound for its own reminder;
            // this request adds nothing to that set.
            return try await center.requestAuthorization(options: [.alert])
        } catch {
            Log.app.warning(
                "Failed to request call notification authorization: \(error.localizedDescription)"
            )
            return false
        }
    }

    func isAlertAuthorizationGranted() async -> Bool {
        switch await center.notificationSettings().authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            return true
        default:
            return false
        }
    }

    func post(_ invitation: MeetingCallInvitation) async {
        registerCategory(for: invitation)

        let content = UNMutableNotificationContent()
        content.title = invitation.title
        content.body = invitation.body
        content.categoryIdentifier = MeetingCallInvitation.categoryIdentifier
        // No sound, deliberately: the person is on a call.
        content.sound = nil

        let request = UNNotificationRequest(
            identifier: invitation.identifier,
            content: content,
            trigger: nil
        )
        do {
            try await center.add(request)
        } catch {
            Log.app.warning("Failed to post the call notification: \(error.localizedDescription)")
        }
    }

    func withdraw(invitationIdentifier: String) {
        center.removeDeliveredNotifications(withIdentifiers: [invitationIdentifier])
    }

    /// Registers the category on every post, because the action titles are
    /// localized and the interface language can change between calls.
    private func registerCategory(for invitation: MeetingCallInvitation) {
        let record = UNNotificationAction(
            identifier: MeetingCallNotificationAction.record.rawValue,
            title: invitation.recordActionTitle,
            options: [.foreground]
        )
        let notNow = UNNotificationAction(
            identifier: MeetingCallNotificationAction.notNow.rawValue,
            title: invitation.notNowActionTitle,
            options: []
        )
        let category = UNNotificationCategory(
            identifier: MeetingCallInvitation.categoryIdentifier,
            actions: [record, notNow],
            intentIdentifiers: [],
            options: []
        )
        center.setNotificationCategories([category])
    }
}

// MARK: - Delivery

/// The app's one `UNUserNotificationCenter` delegate.
///
/// The centre has a single delegate slot and Sparkle's gentle-reminder driver
/// already implements the response callback for its update notification. Every
/// notification therefore lands here and is dispatched on its category
/// identifier: the call invitation is handled in the app, and everything else is
/// forwarded to the delegate Sparkle supplied, unchanged.
///
/// Not main-actor isolated: the centre calls these methods from its own queue,
/// and both stored values are set once at construction.
final class AppUserNotificationDelegate: NSObject, UNUserNotificationCenterDelegate,
    @unchecked Sendable {
    private let onCallAction: @Sendable (MeetingCallNotificationAction) -> Void
    private let forwardedDelegate: (any UNUserNotificationCenterDelegate)?

    init(
        onCallAction: @escaping @Sendable (MeetingCallNotificationAction) -> Void,
        forwardedDelegate: (any UNUserNotificationCenterDelegate)?
    ) {
        self.onCallAction = onCallAction
        self.forwardedDelegate = forwardedDelegate
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        guard isCallInvitation(response.notification) else {
            let selector = #selector(
                UNUserNotificationCenterDelegate.userNotificationCenter(
                    _:didReceive:withCompletionHandler:
                )
            )
            guard let forwardedDelegate, forwardedDelegate.responds(to: selector) else {
                completionHandler()
                return
            }
            forwardedDelegate.userNotificationCenter?(
                center,
                didReceive: response,
                withCompletionHandler: completionHandler
            )
            return
        }

        // Clicking the alert body is the offer accepted: the notification asks
        // one question and Record is its answer.
        let action: MeetingCallNotificationAction?
        switch response.actionIdentifier {
        case UNNotificationDefaultActionIdentifier:
            action = .record
        case UNNotificationDismissActionIdentifier:
            action = nil
        default:
            action = MeetingCallNotificationAction(rawValue: response.actionIdentifier)
        }
        if let action {
            onCallAction(action)
        }
        completionHandler()
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        guard isCallInvitation(notification) else {
            let selector = #selector(
                UNUserNotificationCenterDelegate.userNotificationCenter(
                    _:willPresent:withCompletionHandler:
                )
            )
            guard let forwardedDelegate, forwardedDelegate.responds(to: selector) else {
                // The same silence the app had before this delegate existed.
                completionHandler([])
                return
            }
            forwardedDelegate.userNotificationCenter?(
                center,
                willPresent: notification,
                withCompletionHandler: completionHandler
            )
            return
        }
        // A banner even when Pindrop is in front, and still no sound.
        completionHandler([.banner])
    }

    private func isCallInvitation(_ notification: UNNotification) -> Bool {
        notification.request.content.categoryIdentifier == MeetingCallInvitation.categoryIdentifier
    }
}
