// Created on 2026-07-22

import Testing
@testable import PindropSpeech

@Suite("PindropSpeech")
struct PindropSpeechTests {
    @Test("module name is stable")
    func moduleNameIsStable() {
        #expect(PindropSpeechModule.name == "PindropSpeech")
    }
}
