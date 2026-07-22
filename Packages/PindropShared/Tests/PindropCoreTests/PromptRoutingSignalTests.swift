//
//  PromptRoutingSignalTests.swift
//  PindropCoreTests
//
//  Created on 2026-02-09.
//

import Foundation
import Testing
import PindropCore

@Suite
struct PromptRoutingSignalTests {
    @Test func emptySignalHasNilFieldsAndNotCodeEditor() {
        let signal = PromptRoutingSignal.empty
        #expect(signal.appBundleIdentifier == nil)
        #expect(signal.appName == nil)
        #expect(signal.windowTitle == nil)
        #expect(signal.workspacePath == nil)
        #expect(signal.browserDomain == nil)
        #expect(signal.isCodeEditorContext == false)
        #expect(signal.terminalProviderIdentifier == nil)
    }

    @Test func initializerPreservesAllFields() {
        let signal = PromptRoutingSignal(
            appBundleIdentifier: "com.todesktop.230313mzl4w4u92",
            appName: "cursor",
            windowTitle: "main.swift",
            workspacePath: "/Users/dev/MyProject",
            browserDomain: nil,
            isCodeEditorContext: true,
            terminalProviderIdentifier: "pi"
        )

        #expect(signal.appBundleIdentifier == "com.todesktop.230313mzl4w4u92")
        #expect(signal.appName == "cursor")
        #expect(signal.windowTitle == "main.swift")
        #expect(signal.workspacePath == "/Users/dev/MyProject")
        #expect(signal.browserDomain == nil)
        #expect(signal.isCodeEditorContext)
        #expect(signal.terminalProviderIdentifier == "pi")
    }

    @Test func equatableDistinguishesFieldChanges() {
        let base = PromptRoutingSignal(
            appBundleIdentifier: "com.apple.Safari",
            appName: "safari",
            windowTitle: "GitHub",
            workspacePath: nil,
            browserDomain: "github.com",
            isCodeEditorContext: false
        )
        let same = PromptRoutingSignal(
            appBundleIdentifier: "com.apple.Safari",
            appName: "safari",
            windowTitle: "GitHub",
            workspacePath: nil,
            browserDomain: "github.com",
            isCodeEditorContext: false
        )
        let different = PromptRoutingSignal(
            appBundleIdentifier: "com.apple.Safari",
            appName: "safari",
            windowTitle: "GitHub",
            workspacePath: nil,
            browserDomain: "github.com",
            isCodeEditorContext: true
        )

        #expect(base == same)
        #expect(base != different)
        #expect(base != .empty)
    }
}
