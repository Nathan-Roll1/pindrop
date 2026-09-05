//
//  ListSelectionNavigation.swift
//  Pindrop
//
//  Created on 2026-07-09.
//

import Foundation
import SwiftUI
import AppKit

/// Pure helpers for keyboard-driven list selection (↑/↓).
enum ListSelectionNavigation {
    /// Moves a selection index within `0..<count`.
    /// - If nothing is selected, a positive delta selects the first item and a
    ///   negative delta selects the last item.
    /// - Movement clamps at the ends (no wrap).
    /// - Returns `nil` when the list is empty.
    static func moveIndex(current: Int?, count: Int, delta: Int) -> Int? {
        guard count > 0 else { return nil }
        guard delta != 0 else { return current }

        guard let current else {
            return delta > 0 ? 0 : count - 1
        }

        let next = current + delta
        if next < 0 { return 0 }
        if next >= count { return count - 1 }
        return next
    }
}

// MARK: - Key mapping

/// What a key press means to a selectable list. Pure so the mapping is testable
/// without an `NSEvent`.
enum ListKeyboardCommand: Equatable, Sendable {
    case moveUp
    case moveDown
    case activate
    case delete
    case clearSelection

    /// macOS virtual key codes used by every list in the main window.
    static func command(forKeyCode keyCode: UInt16) -> ListKeyboardCommand? {
        switch keyCode {
        case 126: .moveUp
        case 125: .moveDown
        case 36: .activate
        case 51, 117: .delete
        case 53: .clearSelection
        default: nil
        }
    }
}

// MARK: - View modifier

/// Installs a local key monitor that drives list selection while the main window
/// is key and no text control has focus. Extracted from `NotesView` so every
/// selectable list in the main window shares one behavior.
///
/// Handlers return `true` when they consumed the key; anything else falls
/// through to the responder chain.
struct ListKeyboardSelection: ViewModifier {
    /// Set while the page's own search field is focused, so typing there never
    /// moves the selection.
    var isSearchFieldFocused: Bool
    var onCommand: (ListKeyboardCommand) -> Bool

    @State private var monitor: Any?

    func body(content: Content) -> some View {
        content
            .onAppear { install() }
            .onDisappear { remove() }
    }

    private func install() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard shouldHandle(event) else { return event }
            guard let command = ListKeyboardCommand.command(forKeyCode: event.keyCode) else {
                return event
            }
            return onCommand(command) ? nil : event
        }
    }

    private func remove() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
    }

    private func shouldHandle(_ event: NSEvent) -> Bool {
        guard MainWindowController.isMainWindowKey(event.window) else { return false }
        if isSearchFieldFocused { return false }
        return !Self.isTextInputFirstResponder(event.window?.firstResponder)
    }

    /// Text fields and editable/selectable text views own their own key handling.
    static func isTextInputFirstResponder(_ responder: NSResponder?) -> Bool {
        guard let responder else { return false }
        if responder is NSTextField { return true }
        if let textView = responder as? NSTextView {
            return textView.isEditable || textView.isSelectable
        }
        if responder is NSText { return true }
        return false
    }
}

extension View {
    /// Keyboard selection for a main-window list: ↑/↓ move, Return opens,
    /// Delete requests deletion, Esc clears.
    func listKeyboardSelection(
        isSearchFieldFocused: Bool,
        onCommand: @escaping (ListKeyboardCommand) -> Bool
    ) -> some View {
        modifier(
            ListKeyboardSelection(
                isSearchFieldFocused: isSearchFieldFocused,
                onCommand: onCommand
            )
        )
    }
}
