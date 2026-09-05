//
//  ContextSessionTransitionTests.swift
//  PindropCoreTests
//
//  Created on 2026-07-22.
//

import Testing
@testable import PindropCore

@Suite
struct ContextSessionTransitionTests {
    @Test func confidenceValuesAreFiniteAndBounded() {
        let bounded = ContextSessionTransition(
            trigger: .poll,
            activeFileConfidence: -0.5,
            workspaceConfidence: 1.5
        )
        #expect(bounded.activeFileConfidence == 0)
        #expect(bounded.workspaceConfidence == 1)

        let nonfinite = ContextSessionTransition(
            trigger: .poll,
            activeFileConfidence: .nan,
            workspaceConfidence: .infinity
        )
        #expect(nonfinite.activeFileConfidence == nil)
        #expect(nonfinite.workspaceConfidence == nil)
    }
}
