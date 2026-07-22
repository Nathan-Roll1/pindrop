//
//  NotesGroupingTests.swift
//  PindropTests
//
//  Created on 2026-07-09.
//
//  App-retained localization presentation for NotesGrouping.SectionKey.
//  Pure grouping behavior lives in Packages/PindropShared/Tests/PindropCoreTests.
//

import Foundation
import Testing
@testable import Pindrop
import PindropCore

@Suite("NotesGrouping presentation")
struct NotesGroupingPresentationTests {
    @Test func localizationKeysForStableSections() {
        #expect(NotesGrouping.SectionKey.pinned.localizationKey == "Pinned")
        #expect(NotesGrouping.SectionKey.today.localizationKey == "Today")
        #expect(NotesGrouping.SectionKey.yesterday.localizationKey == "Yesterday")
    }
}
