// Created on 2026-07-22

import Testing
import PindropData

@Suite("PindropData")
struct PindropDataTests {
    @Test("module name is stable")
    func moduleNameIsStable() {
        #expect(PindropDataModule.name == "PindropData")
    }
}
