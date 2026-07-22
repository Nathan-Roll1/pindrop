//
//  WordCountHelperTests.swift
//  PindropTests
//
//  Created on 2026-07-09.
//
//  App/data-retained effectiveWordCount caching. Pure String.wordCount lives in
//  Packages/PindropShared/Tests/PindropCoreTests.
//

import Foundation
import Testing
@testable import Pindrop
import PindropData

@Suite
struct WordCountHelperTests {
    @Test func effectiveWordCountUsesCacheWhenPresent() {
        let cached = TranscriptionRecord(
            text: "one two three four",
            duration: 1.0,
            modelUsed: "tiny",
            wordCount: 99
        )
        #expect(cached.effectiveWordCount == 99)

        let uncached = TranscriptionRecord(
            text: "one two three four",
            duration: 1.0,
            modelUsed: "tiny"
        )
        #expect(uncached.wordCount == nil)
        #expect(uncached.effectiveWordCount == 4)
    }
}
