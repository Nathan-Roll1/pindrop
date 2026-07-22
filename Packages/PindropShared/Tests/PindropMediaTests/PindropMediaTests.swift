// Created on 2026-07-22

import Testing
@testable import PindropMedia

@Suite("PindropMedia")
struct PindropMediaTests {
    @Test("module name is stable")
    func moduleNameIsStable() {
        #expect(PindropMediaModule.name == "PindropMedia")
    }
}
