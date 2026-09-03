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
    /// The state a fresh read of the authorization would report. Set it to false
    /// to model a revoke in System Settings.
    var isAuthorized = true
    /// What the next authorization request answers.
    var grantsAuthorizationRequest = true

    private(set) var postedInvitations: [MeetingCallInvitation] = []
    private(set) var withdrawnIdentifiers: [String] = []
    private(set) var authorizationRequestCount = 0

    func requestAlertAuthorization() async -> Bool {
        authorizationRequestCount += 1
        isAuthorized = grantsAuthorizationRequest
        return grantsAuthorizationRequest
    }

    func isAlertAuthorizationGranted() async -> Bool {
        isAuthorized
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
