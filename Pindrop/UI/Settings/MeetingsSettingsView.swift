//
//  MeetingsSettingsView.swift
//  Pindrop
//
//  Created on 2026-09-03.
//
//  The Meetings settings section: watching for calls, and what a meeting note
//  records.
//

import SwiftUI
import PindropCore

struct MeetingsSettingsView: View {
    @ObservedObject var settings: SettingsStore
    /// Owns the notification permission request, so the app has one place that
    /// asks and one place that records a denial. Nil in the UI-test fixture,
    /// where the row can be read but never asks the system for anything.
    let invitationController: MeetingInvitationController?

    @Environment(\.locale) private var locale

    var body: some View {
        SettingsPaneStack {
            SettingsGroupCard {
                SettingsRow(showSeparator: true) {
                    SettingsRowLabel(
                        title: localized("Watch for calls", locale: locale),
                        subtitle: localized(
                            "Show a way to record when a meeting app opens your microphone.",
                            locale: locale
                        )
                    )
                } control: {
                    SettingsToggle(
                        isOn: $settings.watchForCalls,
                        label: localized("Watch for calls", locale: locale)
                    )
                    .accessibilityIdentifier("settings.toggle.watchForCalls")
                }

                SettingsRow(showSeparator: false) {
                    SettingsRowLabel(
                        title: localized("Notify me when a call starts", locale: locale),
                        subtitle: notifyWhenCallStartsSubtitle
                    )
                } control: {
                    SettingsToggle(
                        isOn: notifyWhenCallStartsBinding,
                        label: localized("Notify me when a call starts", locale: locale)
                    )
                    .disabled(!settings.watchForCalls)
                    .opacity(settings.watchForCalls ? 1 : 0.4)
                    .accessibilityIdentifier("settings.toggle.notifyWhenCallStarts")
                }
            }

            // What a meeting note records, whichever surface started it. These
            // two apply to a meeting note started by hand, so they stay live
            // even with "Watch for calls" off.
            SettingsGroupCard {
                SettingsRow(showSeparator: true) {
                    SettingsRowLabel(
                        title: localized("Record system audio in meeting notes", locale: locale)
                    )
                } control: {
                    SettingsToggle(
                        isOn: $settings.recordSystemAudioInMeetingNotes,
                        label: localized("Record system audio in meeting notes", locale: locale)
                    )
                    .accessibilityIdentifier("settings.toggle.recordSystemAudioInMeetingNotes")
                }

                // Live labels only. The finalize diarization stage keeps its own
                // switch, so turning this off never strips the speakers out of a
                // finished note.
                SettingsRow(showSeparator: false) {
                    SettingsRowLabel(
                        title: localized("Name speakers while recording", locale: locale),
                        subtitle: localized(
                            "Show who is talking in the live transcript. Names are checked again when the recording ends.",
                            locale: locale
                        )
                    )
                } control: {
                    SettingsToggle(
                        isOn: $settings.liveSpeakerNamesEnabled,
                        label: localized("Name speakers while recording", locale: locale)
                    )
                    .accessibilityIdentifier("settings.toggle.liveSpeakerNames")
                }
            }
        }
    }

    /// Says where the switch went when the system, not Pindrop, turned it off.
    private var notifyWhenCallStartsSubtitle: String? {
        guard invitationController?.isNotificationAuthorizationDenied == true else { return nil }
        return localized(
            "Notifications are turned off for Pindrop. Turn them on in System Settings to be asked about calls.",
            locale: locale
        )
    }

    /// Routes the switch through the invitation controller, which asks for
    /// authorization and writes the answer back to the setting.
    ///
    /// The setting is never written here: an ask that is refused must leave the
    /// switch off, and only the controller knows the answer.
    private var notifyWhenCallStartsBinding: Binding<Bool> {
        Binding(
            get: { settings.notifyWhenCallStarts },
            set: { isOn in
                guard let invitationController else {
                    // No controller means no monitor, so there is nothing to be
                    // notified about.
                    settings.notifyWhenCallStarts = false
                    return
                }
                Task { await invitationController.setNotifyWhenCallStarts(isOn) }
            }
        )
    }
}
