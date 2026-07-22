//
//  ProgrammaticTranscriptFormatterTests.swift
//  PindropTests
//
//  Created on 2026-07-13.
//
//  App-retained SettingsStore seam for programmatic formatting. Pure formatter
//  behavior lives in Packages/PindropShared/Tests/PindropCoreTests.
//

import Foundation
import Testing
@testable import Pindrop
import PindropCore

@Suite
struct ProgrammaticTranscriptFormatterSettingsTests {
    private let formatter = ProgrammaticTranscriptFormatter()

    @Test @MainActor func programmaticFormattingDefaultsToDisabled() {
        let store = SettingsStore()
        store.resetAllSettings()
        defer { store.resetAllSettings() }

        #expect(store.programmaticFormattingEnabled == false)
        #expect(SettingsStore.Defaults.programmaticFormattingEnabled == false)

        store.programmaticFormattingEnabled = true
        #expect(store.programmaticFormattingEnabled)

        store.resetAllSettings()
        #expect(store.programmaticFormattingEnabled == false)
    }

    @Test @MainActor func settingsGateMatchesFormatIfEnabledContract() {
        // Production call sites pass settingsStore.programmaticFormattingEnabled into
        // formatIfEnabled. Verify that gate preserves disabled identity and formats when on.
        let store = SettingsStore()
        store.resetAllSettings()
        defer { store.resetAllSettings() }

        let raw = """
        This is the first sentence of a longer dictation sample. This is the second sentence that continues the thought. This is the third sentence with more content. This is the fourth sentence wrapping things up cleanly.
        """
        .trimmingCharacters(in: .whitespacesAndNewlines)

        #expect(
            ProgrammaticTranscriptFormatter.formatIfEnabled(
                raw,
                enabled: store.programmaticFormattingEnabled
            ) == raw
        )

        store.programmaticFormattingEnabled = true
        let gated = ProgrammaticTranscriptFormatter.formatIfEnabled(
            raw,
            enabled: store.programmaticFormattingEnabled
        )
        #expect(gated == formatter.format(raw))
        #expect(gated.contains("\n\n"))
    }
}
