//
//  SidebarItem.swift
//  Pindrop
//
//  Created on 2026-07-09.
//

import SwiftUI

/// Scorched Earth sidebar nav item (spec §3).
/// Selected: page bg + 1 pt line border, ink label 600, accent icon.
/// Unselected: transparent, ink-2 label 500, ink-2 icon.
/// Collapsed (derived 64 pt rail): icon-only, centered 18 pt slot, counts hidden.
struct SidebarItem: View {
    let title: String
    let systemImage: String
    var count: Int? = nil
    var isCollapsed: Bool = false
    var accessibilityIdentifier = ""
    let isSelected: Bool
    let action: () -> Void

    private var iconTint: Color {
        isSelected ? AppColors.accent : AppColors.textSecondary
    }

    var body: some View {
        Button(action: action) {
            Group {
                if isCollapsed {
                    IconSlot(systemImage: systemImage, slot: .nav, tint: iconTint)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 7)
                        .padding(.horizontal, 10)
                } else {
                    HStack(spacing: 10) {
                        IconSlot(systemImage: systemImage, slot: .nav, tint: iconTint)

                        Text(title)
                            .font(isSelected ? AppTypography.labelStrongSelected : AppTypography.labelStrong)
                            .foregroundStyle(isSelected ? AppColors.textPrimary : AppColors.textSecondary)
                            .lineLimit(1)

                        Spacer(minLength: 0)

                        if let count {
                            Text("\(count)")
                                .font(AppTypography.monoSmall)
                                .foregroundStyle(AppColors.textTertiary)
                        }
                    }
                    .padding(.vertical, 7)
                    .padding(.horizontal, 10)
                }
            }
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isSelected ? AppColors.contentBackground : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(isSelected ? AppColors.border : Color.clear, lineWidth: 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .focusRing(.rounded(.sm))
        .help(isCollapsed ? title : "")
        .accessibilityLabel(count.map { "\(title), \($0)" } ?? title)
        .accessibilityIdentifier(accessibilityIdentifier)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }
}

#Preview("SidebarItem") {
    VStack(alignment: .leading, spacing: 2) {
        SidebarItem(title: "Home", systemImage: "house", isSelected: false, action: {})
        SidebarItem(title: "Library", systemImage: "books.vertical", count: 128, isSelected: true, action: {})
        SidebarItem(title: "Notes", systemImage: "note.text", count: 12, isSelected: false, action: {})
    }
    .padding(16)
    .frame(width: 236)
    .background(AppColors.windowBackground)
    .themeRefresh()
}
