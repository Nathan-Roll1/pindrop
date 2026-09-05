//
//  StageProgressRow.swift
//  Pindrop
//
//  Created on 2026-08-22.
//

import SwiftUI

/// One line of a `StageProgressRow` checklist: a named step and what it is
/// doing. Every string is localized by the caller, because this component knows
/// nothing about the pipeline it draws.
struct StageProgressStep: Identifiable {

    enum Status: Equatable {
        case pending
        case running(Double?)
        /// The step does not apply to this piece of work. Drawn quietly, never
        /// as a failure.
        case skipped
        case done
        case failed
    }

    /// Something a reader can do about one step, drawn under it.
    struct Action {
        let title: String
        let perform: () -> Void

        init(title: String, perform: @escaping () -> Void) {
            self.title = title
            self.perform = perform
        }
    }

    let id: String
    let title: String
    let status: Status
    /// The line under the step: the word a skipped step carries, the stall line,
    /// or what a failed step says.
    var detail: String?
    /// What VoiceOver says the step is doing. The marker glyph carries the
    /// status on screen and a glyph reads as nothing, so the caller supplies the
    /// word. Nil where the detail line already says it.
    var accessibilityStatus: String?
    /// Carries a closure, which is why this type is not `Equatable`. `ForEach`
    /// needs only `Identifiable`.
    var action: Action?

    init(
        id: String,
        title: String,
        status: Status,
        detail: String? = nil,
        accessibilityStatus: String? = nil,
        action: Action? = nil
    ) {
        self.id = id
        self.title = title
        self.status = status
        self.detail = detail
        self.accessibilityStatus = accessibilityStatus
        self.action = action
    }
}

/// Named-stage progress block (design spec "Finalizing bar"): current stage,
/// what already finished, elapsed time, a 3 pt bar, and a caption that says what
/// happens next. Determinate when `progress` is set, indeterminate otherwise.
///
/// Given `steps`, it draws the whole pipeline as a checklist instead of one
/// stage: a reader who stopped a 50-minute meeting can see what is finished,
/// what is running, and what does not apply to their recording.
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
    /// Every step of the work, in order. Empty keeps the single-stage layout.
    var steps: [StageProgressStep] = []

    private var clampedProgress: Double? {
        progress.map { min(max($0, 0), 1) }
    }

    var body: some View {
        Group {
            if steps.isEmpty {
                singleStageBody
            } else {
                checklistBody
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
    }

    private var singleStageBody: some View {
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

            captionText
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
    }

    private var checklistBody: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let elapsedText, !elapsedText.isEmpty {
                HStack(spacing: 8) {
                    Spacer(minLength: 8)
                    Text(elapsedText)
                        .font(AppTypography.monoSmall)
                        .foregroundStyle(AppColors.textTertiary)
                        .monospacedDigit()
                        .environment(\.layoutDirection, .leftToRight)
                }
            }

            ForEach(steps) { step in
                stepRow(step)
            }

            captionText
        }
    }

    @ViewBuilder
    private func stepRow(_ step: StageProgressStep) -> some View {
        HStack(alignment: .top, spacing: 8) {
            // Fixed slot so every step name starts on the same axis, whatever
            // its marker is.
            stepMarker(step.status)
                .frame(width: 16, height: 16)

            VStack(alignment: .leading, spacing: 6) {
                Text(step.title)
                    .font(stepFont(step.status))
                    .foregroundStyle(stepColor(step.status))
                    .fixedSize(horizontal: false, vertical: true)

                if case .running(let value) = step.status {
                    StageProgressBar(
                        progress: value.map { min(max($0, 0), 1) },
                        height: Self.barHeight
                    )
                }

                if let detail = step.detail, !detail.isEmpty {
                    Text(detail)
                        .font(AppTypography.caption)
                        .foregroundStyle(AppColors.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if let action = step.action {
                    Button(action.title, action: action.perform)
                        .buttonStyle(.link)
                        .font(AppTypography.caption)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            [step.title, step.accessibilityStatus, step.detail, step.action?.title]
                .compactMap { $0 }
                .filter { !$0.isEmpty }
                .joined(separator: ", ")
        )
    }

    @ViewBuilder
    private func stepMarker(_ status: StageProgressStep.Status) -> some View {
        switch status {
        case .done:
            Image(systemName: "checkmark")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(AppColors.textSecondary)
        case .running:
            ProgressView()
                .progressViewStyle(.circular)
                .controlSize(.small)
                .tint(AppColors.accent)
                .scaleEffect(0.7)
        case .skipped:
            Image(systemName: "minus")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(AppColors.textTertiary)
        case .failed:
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(AppColors.error)
        case .pending:
            Image(systemName: "circle")
                .font(.system(size: 8, weight: .regular))
                .foregroundStyle(AppColors.textTertiary)
        }
    }

    private func stepFont(_ status: StageProgressStep.Status) -> Font {
        switch status {
        case .running, .failed: AppTypography.labelSemibold
        case .pending, .skipped, .done: AppTypography.label
        }
    }

    private func stepColor(_ status: StageProgressStep.Status) -> Color {
        switch status {
        case .running: AppColors.textPrimary
        case .done: AppColors.textSecondary
        case .failed: AppColors.error
        case .pending, .skipped: AppColors.textTertiary
        }
    }

    @ViewBuilder
    private var captionText: some View {
        if let caption, !caption.isEmpty {
            Text(caption)
                .font(AppTypography.caption)
                .foregroundStyle(AppColors.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
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
        StageProgressRow(
            stage: "Transcribing",
            elapsedText: "3:05",
            caption: "Writing your enhanced note comes next. Long recordings can take a few minutes. You can keep typing.",
            steps: [
                StageProgressStep(id: "sealingAudio", title: "Sealing audio", status: .done),
                StageProgressStep(
                    id: "transcribing",
                    title: "Transcribing",
                    status: .running(0.45),
                    detail: "Still working. Long recordings take a while.",
                    action: StageProgressStep.Action(title: "Show the transcript so far") {}
                ),
                StageProgressStep(
                    id: "diarizing",
                    title: "Identifying speakers",
                    status: .skipped,
                    detail: "Skipped"
                ),
                StageProgressStep(id: "matchingSpeakers", title: "Matching names", status: .pending),
                StageProgressStep(id: "assembling", title: "Writing note", status: .pending),
                StageProgressStep(id: "enhancing", title: "Enhancing…", status: .pending),
            ]
        )
    }
    .padding(16)
    .frame(width: 620)
    .background(AppColors.contentBackground)
    .themeRefresh()
}
