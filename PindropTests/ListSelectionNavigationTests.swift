//
//  ListSelectionNavigationTests.swift
//  PindropTests
//
//  Created on 2026-07-09.
//

import AppKit
import Testing
@testable import Pindrop

@Suite("ListSelectionNavigation")
struct ListSelectionNavigationTests {

    @Test("empty list returns nil")
    func emptyList() {
        #expect(ListSelectionNavigation.moveIndex(current: nil, count: 0, delta: 1) == nil)
        #expect(ListSelectionNavigation.moveIndex(current: 0, count: 0, delta: -1) == nil)
    }

    @Test("no selection: down selects first, up selects last")
    func noSelectionDefaults() {
        #expect(ListSelectionNavigation.moveIndex(current: nil, count: 5, delta: 1) == 0)
        #expect(ListSelectionNavigation.moveIndex(current: nil, count: 5, delta: -1) == 4)
    }

    @Test("moves within bounds and clamps at ends")
    func moveAndClamp() {
        #expect(ListSelectionNavigation.moveIndex(current: 2, count: 5, delta: 1) == 3)
        #expect(ListSelectionNavigation.moveIndex(current: 2, count: 5, delta: -1) == 1)
        #expect(ListSelectionNavigation.moveIndex(current: 0, count: 5, delta: -1) == 0)
        #expect(ListSelectionNavigation.moveIndex(current: 4, count: 5, delta: 1) == 4)
    }

    @Test("zero delta keeps current selection")
    func zeroDelta() {
        #expect(ListSelectionNavigation.moveIndex(current: 2, count: 5, delta: 0) == 2)
        #expect(ListSelectionNavigation.moveIndex(current: nil, count: 5, delta: 0) == nil)
    }

    @Test("single item list")
    func singleItem() {
        #expect(ListSelectionNavigation.moveIndex(current: nil, count: 1, delta: 1) == 0)
        #expect(ListSelectionNavigation.moveIndex(current: 0, count: 1, delta: 1) == 0)
        #expect(ListSelectionNavigation.moveIndex(current: 0, count: 1, delta: -1) == 0)
    }
}

/// The key mapping behind `listKeyboardSelection`, extracted from `NotesView`
/// so every main-window list shares one behavior.
@Suite("ListKeyboardCommand")
struct ListKeyboardCommandTests {

    @Test("arrow keys move the selection")
    func arrowKeys() {
        #expect(ListKeyboardCommand.command(forKeyCode: 126) == .moveUp)
        #expect(ListKeyboardCommand.command(forKeyCode: 125) == .moveDown)
    }

    @Test("return opens, delete and forward delete remove, escape clears")
    func actionKeys() {
        #expect(ListKeyboardCommand.command(forKeyCode: 36) == .activate)
        #expect(ListKeyboardCommand.command(forKeyCode: 51) == .delete)
        #expect(ListKeyboardCommand.command(forKeyCode: 117) == .delete)
        #expect(ListKeyboardCommand.command(forKeyCode: 53) == .clearSelection)
    }

    @Test("unmapped keys fall through to the responder chain")
    func unmappedKeys() {
        #expect(ListKeyboardCommand.command(forKeyCode: 0) == nil)
        #expect(ListKeyboardCommand.command(forKeyCode: 49) == nil)
    }

    @Test("text controls keep their own key handling")
    @MainActor
    func textInputResponders() {
        #expect(ListKeyboardSelection.isTextInputFirstResponder(nil) == false)
        #expect(ListKeyboardSelection.isTextInputFirstResponder(NSTextField()))

        let readOnly = NSTextView()
        readOnly.isEditable = false
        readOnly.isSelectable = false
        #expect(ListKeyboardSelection.isTextInputFirstResponder(readOnly) == false)

        let editable = NSTextView()
        editable.isEditable = true
        #expect(ListKeyboardSelection.isTextInputFirstResponder(editable))
    }
}
