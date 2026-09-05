// Created on 2026-07-22

import Testing
import PindropAI

@Suite("PindropAI")
struct PindropAITests {
    @Test("module name is stable")
    func moduleNameIsStable() {
        #expect(PindropAIModule.name == "PindropAI")
    }
}
