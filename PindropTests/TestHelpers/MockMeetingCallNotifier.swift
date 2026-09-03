//
//  MockMeetingCallNotifier.swift
//  PindropTests
//
//  Created on 2026-09-03.
//

import Foundation

@testable import Pindrop

/// A scripted notification centre, so the invitation rules can be tested
/// without asking the system for permission or posting anything.
@MainActor
final class MockMeetingCallNotifier: MeetingCallNotifying {
    /// The state a fresh read of the authorization would report. Set it to
    /// `.denied` to model a revoke in System Settings.
    var authorizationState: MeetingCallAuthorizationState = .granted
    /// What the next authorization request answers.
    var grantsAuthorizationRequest = true
    /// Runs inside the authorization read, so a test can land a state change in
    /// the middle of the controller's await the way the real round trip does.
    var onAuthorizationStateRead: (@MainActor () async -> Void)?

    private(set) var postedInvitations: [MeetingCallInvitation] = []
    private(set) var withdrawnIdentifiers: [String] = []
    private(set) var authorizationRequestCount = 0
    private(set) var authorizationReadCount = 0

    func requestAlertAuthorization() async -> Bool {
        authorizationRequestCount += 1
        authorizationState = grantsAuthorizationRequest ? .granted : .denied
        return grantsAuthorizationRequest
    }

    func alertAuthorizationState() async -> MeetingCallAuthorizationState {
        authorizationReadCount += 1
        if let onAuthorizationStateRead {
            // One shot: the interleaving being modelled happens once.
            self.onAuthorizationStateRead = nil
            await onAuthorizationStateRead()
        }
        return authorizationState
    }

    func post(_ invitation: MeetingCallInvitation) async {
        postedInvitations.append(invitation)
    }

    func withdraw(invitationIdentifier: String) {
        withdrawnIdentifiers.append(invitationIdentifier)
    }
}

/// Counts the one-time ask and answers it with a scripted button.
@MainActor
final class MockMeetingCallAskPresenter: MeetingCallAskPresenting {
    /// True is "Notify me", false is "No thanks".
    var answer = true
    private(set) var presentationCount = 0

    func presentCallNotificationAsk() -> Bool {
        presentationCount += 1
        return answer
    }
}
