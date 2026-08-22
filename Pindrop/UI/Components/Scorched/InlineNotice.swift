//
//  InlineNotice.swift
//  Pindrop
//
//  Created on 2026-08-22.
//

import SwiftUI

/// One-line (or wrapping) notice band: glyph, message, optional progress, optional
/// action. Replaces the per-page setup-issue banners that Dictate, Meeting, and
/// Library each carried their own copy of.
struct InlineNotice: View {
    enum Kind {
        case info
        case warning
        case error

        var glyph: String {
            switch self {
            case .info: return "info.circle"
            case .warning: return "exclamationmark.triangle"
            case .error: return "exclamationmark.octagon"
            }
        }

        var tint: Color {
            switch self {
            case .info: return AppColors.accent
            case .warning: return AppColors.warning
            case .error: return AppColors.error
            }
        }

        var background: Color {
            switch self {
            case .info: return AppColors.accentBackground
            case .warning: return AppColors.warningBackground
            case .error: return AppColors.errorBackground
            }
        }
    }

    let kind: Kind
    let message: String
    /// Overrides the kind glyph (for example a download arrow on an info notice).
    var systemImage: String? = nil
    /// Determinate progress under the message. `nil` hides the bar.
    var progress: Double? = nil
    var actionTitle: String? = nil
    var actionIdentifier: String? = nil
    var action: (() -> Void)? = nil

    private var clampedProgress: Double? {
        progress.map { min(max($0, 0), 1) }
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: systemImage ?? kind.glyph)
                .font(.system(size: 14))
                .foregroundStyle(kind.tint)

            if let clampedProgress {
                VStack(alignment: .leading, spacing: 4) {
                    messageText

                    ProgressView(value: clampedProgress)
                        .progressViewStyle(.linear)
                        .tint(kind.tint)
                        .frame(maxWidth: 180)
                        .accessibilityValue("\(Int(clampedProgress * 100))%")
                }
            } else {
                messageText
            }

            Spacer(minLength: 8)

            if let actionTitle, !actionTitle.isEmpty, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(.plain)
                    .font(AppTypography.caption.weight(.semibold))
                    .foregroundStyle(AppColors.accent)
                    .focusRing(.rounded(.sm))
                    .accessibilityIdentifier(actionIdentifier ?? "")
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: AppTheme.Radius.sm, style: .continuous)
                .fill(kind.background)
        )
    }

    private var messageText: some View {
        Text(message)
            .font(AppTypography.caption)
            .foregroundStyle(AppColors.textPrimary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

#Preview("InlineNotice") {
    VStack(alignment: .leading, spacing: 10) {
        InlineNotice(
            kind: .warning,
            message: "Speaker labels need the diarization model.",
            actionTitle: "Download model",
            action: {}
        )
        InlineNotice(
            kind: .info,
            message: "Downloading the diarization model.",
            systemImage: "arrow.down.circle",
            progress: 0.42
        )
        InlineNotice(
            kind: .error,
            message: "Enhanced note failed. The AI provider did not respond. Your notes and the transcript are safe.",
            actionTitle: "Try again",
            action: {}
        )
    }
    .padding(16)
    .frame(width: 560)
    .background(AppColors.contentBackground)
    .themeRefresh()
}
