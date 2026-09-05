// Created on 2026-07-22

import Testing
import PindropCore

@Suite("PindropCore")
struct PindropCoreTests {
    @Test("module name is stable")
    func moduleNameIsStable() {
        #expect(PindropCoreModule.name == "PindropCore")
    }
}
