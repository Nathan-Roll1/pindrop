//
//  TranscriptionOptionsTests.swift
//  PindropCoreTests
//
//  Created on 2026-07-22.
//

import PindropCore
import Testing

@Suite
struct TranscriptionOptionsTests {
    @Test func audioPreprocessingDefaultsToNone() {
        #expect(TranscriptionOptions().audioPreprocessingMode == .none)
    }

    @Test func voiceIsolationParticipatesInEquality() {
        let voiceIsolation = TranscriptionOptions(audioPreprocessingMode: .voiceIsolation)

        #expect(voiceIsolation.audioPreprocessingMode == .voiceIsolation)
        #expect(voiceIsolation == TranscriptionOptions(audioPreprocessingMode: .voiceIsolation))
        #expect(voiceIsolation != TranscriptionOptions())
    }
}
