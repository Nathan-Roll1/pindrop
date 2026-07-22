//
//  BuiltInPresetID.swift
//  PindropCore
//
//  Created on 2026-07-22.
//

import Foundation

/// Stable IDs for built-in prompt presets. Used by ModelAssignment.promptPresetID so presets
/// can be renamed without breaking assignments. These must match the `identifier` field on
/// `BuiltInPresets.PresetDefinition` entries so `PromptPresetStore.fetchBuiltIn()` lookups
/// line up with assignments.
public enum BuiltInPresetID: Sendable {
    /// BuiltInPresets.cleanTranscript
    public static let cleanTranscript = "clean"
    /// Reserved for a future note-formatting built-in. Not seeded today; callers that
    /// reference this ID fall back to ModelAssignment.promptOverride (or the purpose's
    /// caller-supplied default).
    public static let noteFormatting = "note"
    /// BuiltInPresets.liveStreamingRefinement (added in v2 - see PromptPresetStore seeding).
    public static let liveStreamingRefinement = "live-stream-refine"
}
