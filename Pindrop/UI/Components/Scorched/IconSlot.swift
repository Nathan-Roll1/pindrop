//
//  IconSlot.swift
//  Pindrop
//
//  Created on 2026-08-22.
//

import SwiftUI

/// Icon sizing ramp. Glyph point sizes were scattered as `.system(size: 11...14)`
/// across nav and row chrome; these are the three sizes that ramp actually used.
enum AppIcon {
    /// Sidebar and nav glyphs (13 pt) inside an 18 pt slot.
    static let navSize: CGFloat = 13
    /// List-row glyphs (13 pt) inside a 16 pt slot.
    static let rowSize: CGFloat = 13
    /// Chip and inline-button glyphs (12 pt), sized by the label, no slot.
    static let chipSize: CGFloat = 12

    /// Nav slot side (spec §3): the glyph box that keeps labels on one axis.
    static let navSlot: CGFloat = 18
    /// Row slot side (spec §5).
    static let rowSlot: CGFloat = 16

    static func nav(weight: Font.Weight = .medium) -> Font {
        .system(size: navSize, weight: weight)
    }

    static func row(weight: Font.Weight = .regular) -> Font {
        .system(size: rowSize, weight: weight)
    }

    static func chip(weight: Font.Weight = .medium) -> Font {
        .system(size: chipSize, weight: weight)
    }
}

/// A glyph in a fixed square slot. The slot never shrinks, so labels in a list
/// stay on one axis even when glyph widths differ (mic vs person.2 vs waveform).
struct IconSlot: View {
    enum Slot {
        /// 18 pt sidebar / nav slot.
        case nav
        /// 16 pt list-row slot.
        case row

        var side: CGFloat {
            switch self {
            case .nav: return AppIcon.navSlot
            case .row: return AppIcon.rowSlot
            }
        }

        var font: Font {
            switch self {
            case .nav: return AppIcon.nav()
            case .row: return AppIcon.row()
            }
        }
    }

    let systemImage: String
    var slot: Slot = .nav
    /// Overrides the slot's default glyph font (weight or size).
    var font: Font? = nil
    var tint: Color = AppColors.textSecondary

    var body: some View {
        Image(systemName: systemImage)
            .font(font ?? slot.font)
            .foregroundStyle(tint)
            // Fixed frame + fixedSize: the slot holds its width in an HStack that
            // runs out of room instead of squeezing the glyph.
            .frame(width: slot.side, height: slot.side)
            .fixedSize()
    }
}

#Preview("IconSlot") {
    VStack(alignment: .leading, spacing: 12) {
        HStack(spacing: 10) {
            IconSlot(systemImage: "mic", slot: .nav, tint: AppColors.accent)
            Text("Dictate").font(AppTypography.labelStrong)
        }
        HStack(spacing: 10) {
            IconSlot(systemImage: "note.text", slot: .row, tint: AppColors.textTertiary)
            Text("Weekly planning").font(AppTypography.body)
        }
    }
    .padding(16)
    .background(AppColors.contentBackground)
    .themeRefresh()
}
