//
//  DictationAudioRetentionSettingsTests.swift
//  PindropTests
//
//  SettingsStore retention defaults remain app-owned.
//

import Foundation
import PindropCore
import Testing
@testable import Pindrop

@MainActor
@Suite
struct DictationAudioRetentionSettingsTests {
    @Test func testDefaultRetentionIsDays7() {
        let settings = SettingsStore()
        settings.resetAllSettings()
        defer { settings.resetAllSettings() }

        #expect(settings.dictationAudioRetention == .days7)

        settings.dictationAudioRetention = .off
        #expect(settings.dictationAudioRetention == .off)
        #expect(settings.dictationAudioRetentionRawValue == DictationAudioRetention.off.rawValue)

        settings.dictationAudioRetention = .days30
        #expect(settings.dictationAudioRetention == .days30)

        settings.resetAllSettings()
        #expect(settings.dictationAudioRetention == .days7)
    }
}
