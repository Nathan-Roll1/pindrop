//
//  NoteViewChips.swift
//  Pindrop
//
//  Created on 2026-08-22.
//
//  The note page's My notes / Enhanced / Transcript switch (design spec, Round B).
//
//  Round B drops the shared container: the three views are individual chips, so
//  the selected one reads as a surface and the others as plain labels. The
//  control never changes the selection by itself. A chip that cannot be shown
//  yet is drawn disabled with a help string that says when it can, and a chip
//  carrying news wears a dot: nothing here moves a reader off the view they
//  chose.
//
//  One chip can own a dropdown (the Enhanced chip). Clicking it while it is
//  already selected opens that dropdown instead of re-selecting the view, which
//  is the only way a click here does anything other than switch views.
//

import SwiftUI

struct NoteViewChips<Value: Hashable, MenuContent: View>: View {

    /// The dot a chip can carry.
    enum Indicator: Equatable {
        /// A capture is running: the transcript is filling in right now.
        case live
        /// Something new is ready to read and has not been opened yet.
        case ready

        var color: Color {
            switch self {
            case .live: AppColors.recording
            case .ready: AppColors.accent
            }
        }
    }

    struct Chip: Identifiable {
        let value: Value
        let title: String
        let systemImage: String
        var isEnabled: Bool = true
        /// Why the chip is disabled, shown on hover.
        var helpText: String? = nil
        var indicator: Indicator? = nil
        /// Clicking this chip while it is selected opens its dropdown.
        var opensMenu: Bool = false
        /// The glyph turns accent while the chip is selected (the sparkle).
        var accentsIconWhenSelected: Bool = false
        var accessibilityIdentifier: String? = nil

        var id: Value { value }
    }

    let chips: [Chip]
    let selection: Value
    let onSelect: (Value) -> Void
    /// The chip whose dropdown is open, if any.
    @Binding var openMenuValue: Value?
    @ViewBuilder var menuContent: (Value) -> MenuContent

    private static var chipRadius: CGFloat { 8 }
    private static var dotSize: CGFloat { 6 }

    var body: some View {
        HStack(spacing: 6) {
            ForEach(chips) { chip in
                chipButton(chip)
            }
        }
        .fixedSize()
    }

    @ViewBuilder
    private func chipButton(_ chip: Chip) -> some View {
        let isSelected = chip.value == selection

        Button {
            guard chip.isEnabled else { return }
            if isSelected {
                guard chip.opensMenu else { return }
                openMenuValue = chip.value
                return
            }
            onSelect(chip.value)
        } label: {
            HStack(spacing: 7) {
                Image(systemName: chip.systemImage)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(iconColor(chip: chip, isSelected: isSelected))

                Text(chip.title)
                    .font(isSelected ? AppTypography.labelSemibold : AppTypography.label)
                    .foregroundStyle(labelColor(chip: chip, isSelected: isSelected))

                if let indicator = chip.indicator {
                    Circle()
                        .fill(indicator.color)
                        .frame(width: Self.dotSize, height: Self.dotSize)
                        .accessibilityHidden(true)
                }

                if isSelected, chip.opensMenu {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(AppColors.textTertiary)
                        .accessibilityHidden(true)
                }
            }
            .padding(.vertical, 5)
            .padding(.horizontal, 12)
            .background(
                RoundedRectangle(cornerRadius: Self.chipRadius, style: .continuous)
                    .fill(isSelected ? AppColors.contentBackground : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Self.chipRadius, style: .continuous)
                    .strokeBorder(isSelected ? AppColors.border : Color.clear, lineWidth: 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: Self.chipRadius, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(!chip.isEnabled)
        .focusRing(.rounded(.sm))
        .help(chip.helpText ?? "")
        .accessibilityIdentifier(chip.accessibilityIdentifier ?? "")
        .accessibilityLabel(chip.title)
        .accessibilityHint(chip.helpText ?? "")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .popover(
            isPresented: menuBinding(for: chip),
            attachmentAnchor: .rect(.bounds),
            arrowEdge: .bottom
        ) {
            menuContent(chip.value)
        }
    }

    private func menuBinding(for chip: Chip) -> Binding<Bool> {
        Binding(
            get: { chip.opensMenu && openMenuValue == chip.value },
            set: { isPresented in
                if !isPresented, openMenuValue == chip.value {
                    openMenuValue = nil
                }
            }
        )
    }

    private func labelColor(chip: Chip, isSelected: Bool) -> Color {
        guard chip.isEnabled else { return AppColors.textTertiary }
        return isSelected ? AppColors.textPrimary : AppColors.textSecondary
    }

    private func iconColor(chip: Chip, isSelected: Bool) -> Color {
        guard chip.isEnabled else { return AppColors.textTertiary }
        if isSelected, chip.accentsIconWhenSelected { return AppColors.accent }
        return isSelected ? AppColors.textPrimary : AppColors.textSecondary
    }
}

#Preview("NoteViewChips") {
    VStack(alignment: .leading, spacing: 12) {
        NoteViewChips(
            chips: [
                .init(value: "notes", title: "My notes", systemImage: "text.alignleft"),
                .init(value: "enhanced", title: "Enhanced", systemImage: "sparkles"),
                .init(value: "transcript", title: "Transcript", systemImage: "mic")
            ],
            selection: "notes",
            onSelect: { _ in },
            openMenuValue: .constant(nil),
            menuContent: { _ in EmptyView() }
        )

        NoteViewChips(
            chips: [
                .init(value: "notes", title: "My notes", systemImage: "text.alignleft"),
                .init(
                    value: "enhanced",
                    title: "Enhanced",
                    systemImage: "sparkles",
                    isEnabled: false,
                    helpText: "Available when the recording is finished"
                ),
                .init(
                    value: "transcript",
                    title: "Transcript",
                    systemImage: "mic",
                    indicator: .live
                )
            ],
            selection: "notes",
            onSelect: { _ in },
            openMenuValue: .constant(nil),
            menuContent: { _ in EmptyView() }
        )

        NoteViewChips(
            chips: [
                .init(value: "notes", title: "My notes", systemImage: "text.alignleft"),
                .init(
                    value: "enhanced",
                    title: "Enhanced",
                    systemImage: "sparkles",
                    opensMenu: true,
                    accentsIconWhenSelected: true
                ),
                .init(value: "transcript", title: "Transcript", systemImage: "mic")
            ],
            selection: "enhanced",
            onSelect: { _ in },
            openMenuValue: .constant(nil),
            menuContent: { _ in EmptyView() }
        )
    }
    .padding(16)
    .background(AppColors.contentBackground)
    .themeRefresh()
}
