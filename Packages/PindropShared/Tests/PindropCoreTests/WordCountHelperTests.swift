//
//  WordCountHelperTests.swift
//  PindropCoreTests
//
//  Created on 2026-07-09.
//

import Foundation
import Testing
import PindropCore

@Suite
struct WordCountHelperTests {
    @Test func emptyStringHasZeroWords() {
        #expect("".wordCount == 0)
        #expect("   ".wordCount == 0)
        #expect("\n\t  \n".wordCount == 0)
    }

    @Test func simpleWords() {
        #expect("hello".wordCount == 1)
        #expect("hello world".wordCount == 2)
        #expect("one two three".wordCount == 3)
    }

    @Test func multipleSpacesAreCollapsed() {
        #expect("hello    world".wordCount == 2)
        #expect("  padded  words  ".wordCount == 2)
    }

    @Test func newlinesSplitWords() {
        #expect("hello\nworld".wordCount == 2)
        #expect("one\ntwo\nthree".wordCount == 3)
        #expect("line one\n\nline two".wordCount == 4)
    }

    @Test func punctuationStaysAttachedToWords() {
        #expect("hello, world!".wordCount == 2)
        #expect("it's fine.".wordCount == 2)
        #expect("one—two".wordCount == 1)
    }
}
