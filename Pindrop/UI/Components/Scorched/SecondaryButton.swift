//
//  SecondaryButton.swift
//  Pindrop
//
//  Created on 2026-07-09.
//

import SwiftUI

/// The secondary control surface: content background, 1px line border, radius 8
/// (spec §6). Every quiet button and menu in the page chrome wears it, so they
/// keep the same shape when one of them changes.
struct MenuButtonChrome: ViewModifier {
    var verticalPadding: CGFloat = 6
    var horizontalPadding: CGFloat = 12

    func body(content: Content) -> some View {
        content
            .padding(.vertical, verticalPadding)
            .padding(.horizontal, horizontalPadding)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(AppColors.contentBackground)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(AppColors.border, lineWidth: 1)
            )
    }
}

extension View {
    /// Wraps a label in the secondary chrome.
    func menuButtonChrome(
        verticalPadding: CGFloat = 6,
        horizontalPadding: CGFloat = 12
    ) -> some View {
        modifier(
            MenuButtonChrome(
                verticalPadding: verticalPadding,
                horizontalPadding: horizontalPadding
            )
        )
    }
}

/// Secondary action button: page bg, line border, radius 8 (spec §6).
struct SecondaryButton: View {
    let title: String
    var systemImage: String? = nil
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            SecondaryButtonLabel(title: title, systemImage: systemImage)
                .menuButtonChrome()
        }
        .buttonStyle(.plain)
        .focusRing(.rounded(.sm))
        .accessibilityLabel(title)
    }
}

/// Export menu chrome matching `SecondaryButton` metrics (spec §6).
struct ExportMenuButton: View {
    let title: String
    var systemImage: String? = "square.and.arrow.up"
    let formats: [TranscriptExportFormat]
    var formatTitle: (TranscriptExportFormat) -> String
    var onSelect: (TranscriptExportFormat) -> Void

    var body: some View {
        Menu {
            ForEach(formats, id: \.rawValue) { format in
                Button(formatTitle(format)) {
                    onSelect(format)
                }
            }
        } label: {
            SecondaryButtonLabel(title: title, systemImage: systemImage)
                .menuButtonChrome()
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }
}

/// The label both wear: optional glyph, then the title.
private struct SecondaryButtonLabel: View {
    let title: String
    var systemImage: String?

    var body: some View {
        // Icon inside Text so the SF Symbol aligns on its baked-in baseline —
        // box-centering glyphs with ascenders (square.and.arrow.up) reads "high".
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            if let systemImage {
                Text(Image(systemName: systemImage))
                    .font(AppIcon.chip())
            }
            Text(title)
                .font(AppTypography.label)
        }
        .foregroundStyle(AppColors.textPrimary)
    }
}

#Preview("SecondaryButton") {
    HStack(spacing: 8) {
        SecondaryButton(title: "Copy", systemImage: "doc.on.doc", action: {})
        SecondaryButton(title: "Export", systemImage: "square.and.arrow.up", action: {})
    }
    .padding()
    .background(AppColors.windowBackground)
    .themeRefresh()
}
