//
//  StageProgressRow.swift
//  Pindrop
//
//  Created on 2026-08-22.
//

import SwiftUI

/// Named-stage progress block (design spec "Finalizing bar"): current stage,
/// what already finished, elapsed time, a 3 pt bar, and a caption that says what
/// happens next. Determinate when `progress` is set, indeterminate otherwise.
struct StageProgressRow: View {
    /// Spec radius for the finalizing block (10 pt sits between Radius.sm and .md).
    private static let containerRadius: CGFloat = 10
    private static let barHeight: CGFloat = 3

    /// Current stage, for example "Transcribing".
    let stage: String
    /// Stages already done, for example "Transcription done". Optional.
    var completedStages: String? = nil
    /// Elapsed time, right aligned in mono. Optional.
    var elapsedText: String? = nil
    /// 0...1 for a determinate bar; `nil` runs the indeterminate sweep.
    var progress: Double? = nil
    /// Supporting line under the bar.
    var caption: String? = nil

    private var clampedProgress: Double? {
        progress.map { min(max($0, 0), 1) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                ProgressView()
                    .progressViewStyle(.circular)
                    .controlSize(.small)
                    .tint(AppColors.accent)

                Text(stage)
                    .font(AppTypography.labelSemibold)
                    .foregroundStyle(AppColors.textPrimary)

                if let completedStages, !completedStages.isEmpty {
                    Text(completedStages)
                        .font(AppTypography.label)
                        .foregroundStyle(AppColors.textTertiary)
                        .lineLimit(1)
                }

                Spacer(minLength: 8)

                if let elapsedText, !elapsedText.isEmpty {
                    Text(elapsedText)
                        .font(AppTypography.monoSmall)
                        .foregroundStyle(AppColors.textTertiary)
                        .monospacedDigit()
                        .environment(\.layoutDirection, .leftToRight)
                }
            }

            StageProgressBar(progress: clampedProgress, height: Self.barHeight)

            if let caption, !caption.isEmpty {
                Text(caption)
                    .font(AppTypography.caption)
                    .foregroundStyle(AppColors.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 14)
        .padding(.horizontal, 16)
        .background(
            RoundedRectangle(cornerRadius: Self.containerRadius, style: .continuous)
                .fill(AppColors.windowBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Self.containerRadius, style: .continuous)
                .strokeBorder(AppColors.border, lineWidth: 1)
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
    }

    private var accessibilityLabel: String {
        [stage, completedStages, caption]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
            .joined(separator: ", ")
    }
}

/// 3 pt track with an accent fill. Determinate fills left to right; indeterminate
/// sweeps a short segment, and holds a dimmed full bar under Reduce Motion.
private struct StageProgressBar: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let progress: Double?
    let height: CGFloat

    @State private var sweep = false

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            ZStack(alignment: .leading) {
                Capsule(style: .continuous)
                    .fill(AppColors.border)

                if let progress {
                    Capsule(style: .continuous)
                        .fill(AppColors.accent)
                        .frame(width: width * progress)
                } else if reduceMotion {
                    Capsule(style: .continuous)
                        .fill(AppColors.accent.opacity(0.4))
                } else {
                    let segment = max(24, width * 0.3)
                    Capsule(style: .continuous)
                        .fill(AppColors.accent)
                        .frame(width: segment)
                        .offset(x: sweep ? width : -segment)
                        .animation(
                            .linear(duration: 1.2).repeatForever(autoreverses: false),
                            value: sweep
                        )
                        .onAppear { sweep = true }
                        .onDisappear { sweep = false }
                }
            }
            .clipShape(Capsule(style: .continuous))
        }
        .frame(height: height)
    }
}

#Preview("StageProgressRow") {
    VStack(spacing: 12) {
        StageProgressRow(
            stage: "Transcribing",
            completedStages: "Audio sealed",
            elapsedText: "1:42",
            progress: 0.45,
            caption: "Writing your enhanced note comes next. Long recordings can take a few minutes. You can keep typing."
        )
        StageProgressRow(
            stage: "Identifying speakers",
            completedStages: "Transcription done",
            elapsedText: "3:05"
        )
    }
    .padding(16)
    .frame(width: 620)
    .background(AppColors.contentBackground)
    .themeRefresh()
}
