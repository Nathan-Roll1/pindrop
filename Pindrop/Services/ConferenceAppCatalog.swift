//
//  ConferenceAppCatalog.swift
//  Pindrop
//
//  Created on 2026-09-03.
//
//  The bundle identifiers that can be hosting a conference call.
//

import Foundation

/// Apps that can host a conference call, by bundle identifier.
///
/// A plain constant, not a heuristic, so adding an app is a one-line change.
///
/// Browsers are on the list only because the detection rule requires
/// `isRunningInput` as well as `isRunningOutput`. A browser playing a video has
/// output alone and never reads as a call; a browser in a Meet call has the
/// microphone open. That one requirement removes almost every false positive
/// with no per-app special casing, which is what makes browsers safe here.
enum ConferenceAppCatalog {
    static let bundleIdentifiers: Set<String> = [
        "us.zoom.xos",
        "com.microsoft.teams",
        "com.microsoft.teams2",
        "com.cisco.webexmeetingsapp",
        "com.webex.meetingmanager",
        "com.tinyspeck.slackmacgap",
        "com.hnc.Discord",
        "com.apple.FaceTime",
        "com.google.Chrome",
        "com.apple.Safari",
        "org.mozilla.firefox",
        "com.microsoft.edgemac",
        "com.brave.Browser",
        "company.thebrowser.Browser"
    ]

    static func contains(_ bundleIdentifier: String) -> Bool {
        bundleIdentifiers.contains(bundleIdentifier)
    }
}
