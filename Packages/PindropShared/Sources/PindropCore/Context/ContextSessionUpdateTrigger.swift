//
//  ContextSessionUpdateTrigger.swift
//  PindropCore
//
//  Created on 2026-07-22.
//

import Foundation

public enum ContextSessionUpdateTrigger: String, Sendable {
    case recordingStart = "recording_start"
    case poll = "poll"
    case frontmostAppChange = "frontmost_app_change"
    case focusOrWindowChange = "focus_or_window_change"
}
