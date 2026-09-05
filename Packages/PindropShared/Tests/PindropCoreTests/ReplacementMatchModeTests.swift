//
//  ReplacementMatchModeTests.swift
//  PindropCoreTests
//
//  Created on 2026-07-09.
//

import Foundation
import Testing
import PindropCore

@Suite
struct ReplacementMatchModeTests {
    @Test func rawValuesAreStable() {
        #expect(ReplacementMatchMode.caseInsensitive.rawValue == "caseInsensitive")
        #expect(ReplacementMatchMode.exact.rawValue == "exact")
        #expect(ReplacementMatchMode.command.rawValue == "command")
    }

    @Test func unknownRawValueFailsToInitialize() {
        #expect(ReplacementMatchMode(rawValue: "not-a-real-mode") == nil)
        #expect(ReplacementMatchMode(rawValue: ReplacementMatchMode.exact.rawValue) == .exact)
        #expect(ReplacementMatchMode(rawValue: ReplacementMatchMode.command.rawValue) == .command)
        #expect(ReplacementMatchMode(rawValue: ReplacementMatchMode.caseInsensitive.rawValue) == .caseInsensitive)
    }

    @Test func roundTripsThroughCodable() throws {
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        for mode in [ReplacementMatchMode.caseInsensitive, .exact, .command] {
            let data = try encoder.encode(mode)
            let decoded = try decoder.decode(ReplacementMatchMode.self, from: data)
            #expect(decoded == mode)
        }
    }
}
