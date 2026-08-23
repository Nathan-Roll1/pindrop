//
//  CapturePrimaryButton.swift
//  Pindrop
//
//  Created on 2026-08-22.
//
//  The one standard accent CTA for starting a capture, shared by the Dictate
//  and Notes pages: fixed 36pt face, accent fill, an optional keyboard hint
//  inside the face, and an optional split menu segment on the trailing edge.
//

import SwiftUI

enum CapturePrimaryGlyph {
    /// The 8pt ready dot the Dictate CTA leads with.
    case dot
    /// The plus glyph the New note CTA leads with.
    case plus
}

enum CapturePrimaryButtonMetrics {
    static let height: CGFloat = 36
    static let cornerRadius: CGFloat = 8
    static let contentGap: CGFloat = 8
    static let dotSize: CGFloat = 8
    static let horizontalPadding: CGFloat = 16
    static let splitTrailingPadding: CGFloat = 12
    static let menuSegmentPadding: CGFloat = 10
}

struct CapturePrimaryButton<MenuContent: View>: View {
    let glyph: CapturePrimaryGlyph
    let title: String
    var keyboardHint: String?
    var isEnabled: Bool = true
    var disabledReason: String?
    var accessibilityIdentifier: String?
    let action: () -> Void
    var menuAccessibilityLabel: String?
    var menuAccessibilityIdentifier: String?
    @ViewBuilder var menuContent: () -> MenuContent

    private var hasMenu: Bool { MenuContent.self != EmptyView.self }

    var body: some View {
        HStack(spacing: 0) {
            primarySegment

            if hasMenu {
                Rectangle()
                    .fill(AppColors.contentBackground.opacity(0.28))
                    .frame(width: 1, height: CapturePrimaryButtonMetrics.height)

                menuSegment
            }
        }
        .frame(height: CapturePrimaryButtonMetrics.height)
        .fixedSize()
        .background(
            RoundedRectangle(
                cornerRadius: CapturePrimaryButtonMetrics.cornerRadius,
                style: .continuous
            )
            .fill(isEnabled ? AppColors.accent : AppColors.accent.opacity(0.4))
        )
    }

    private var primarySegment: some View {
        Button(action: action) {
            HStack(spacing: CapturePrimaryButtonMetrics.contentGap) {
                glyphView

                Text(title)
                    .font(AppTypography.labelStrongSelected)
                    .foregroundStyle(AppColors.contentBackground)

                if let keyboardHint, !keyboardHint.isEmpty {
                    Text(keyboardHint)
                        .font(AppTypography.monoSmall)
                        .foregroundStyle(AppColors.contentBackground.opacity(0.72))
                        .environment(\.layoutDirection, .leftToRight)
                }
            }
            .padding(.leading, CapturePrimaryButtonMetrics.horizontalPadding)
            .padding(
                .trailing,
                hasMenu
                    ? CapturePrimaryButtonMetrics.splitTrailingPadding
                    : CapturePrimaryButtonMetrics.horizontalPadding
            )
            .frame(height: CapturePrimaryButtonMetrics.height)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusRing(.rounded(.sm))
        .disabled(!isEnabled)
        .help(disabledReason ?? "")
        .accessibilityIdentifier(accessibilityIdentifier ?? "")
        .accessibilityLabel(title)
        .accessibilityHint(disabledReason ?? "")
    }

    private var menuSegment: some View {
        Menu(content: menuContent) {
            Image(systemName: "chevron.down")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(AppColors.contentBackground)
                .padding(.horizontal, CapturePrimaryButtonMetrics.menuSegmentPadding)
                .frame(height: CapturePrimaryButtonMetrics.height)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityIdentifier(menuAccessibilityIdentifier ?? "")
        .accessibilityLabel(menuAccessibilityLabel ?? "")
    }
}

extension CapturePrimaryButton where MenuContent == EmptyView {
    init(
        glyph: CapturePrimaryGlyph,
        title: String,
        keyboardHint: String? = nil,
        isEnabled: Bool = true,
        disabledReason: String? = nil,
        accessibilityIdentifier: String? = nil,
        action: @escaping () -> Void
    ) {
        self.init(
            glyph: glyph,
            title: title,
            keyboardHint: keyboardHint,
            isEnabled: isEnabled,
            disabledReason: disabledReason,
            accessibilityIdentifier: accessibilityIdentifier,
            action: action,
            menuAccessibilityLabel: nil,
            menuAccessibilityIdentifier: nil,
            menuContent: { EmptyView() }
        )
    }
}

private extension CapturePrimaryButton {
    @ViewBuilder
    var glyphView: some View {
        switch glyph {
        case .dot:
            Circle()
                .fill(AppColors.contentBackground)
                .frame(
                    width: CapturePrimaryButtonMetrics.dotSize,
                    height: CapturePrimaryButtonMetrics.dotSize
                )
        case .plus:
            Image(systemName: "plus")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(AppColors.contentBackground)
        }
    }
}
