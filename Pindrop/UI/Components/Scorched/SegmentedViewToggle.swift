//
//  SegmentedViewToggle.swift
//  Pindrop
//
//  Created on 2026-08-22.
//

import SwiftUI

/// The note page's My notes / Enhanced / Transcript switch (design spec, "Note
/// page").
///
/// The control never changes the selection by itself. A segment that cannot be
/// shown yet is drawn disabled with a help string that says when it can, and a
/// segment carrying news wears a dot: nothing here moves a reader off the view
/// they chose.
struct SegmentedViewToggle<Value: Hashable>: View {

    /// The dot a segment can carry.
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

    struct Segment: Identifiable {
        let value: Value
        let title: String
        var isEnabled: Bool = true
        /// Why the segment is disabled, shown on hover.
        var helpText: String? = nil
        var indicator: Indicator? = nil
        var accessibilityIdentifier: String? = nil

        var id: Value { value }
    }

    let segments: [Segment]
    let selection: Value
    let onSelect: (Value) -> Void

    private static var containerRadius: CGFloat { 8 }
    private static var segmentRadius: CGFloat { 6 }
    private static var dotSize: CGFloat { 6 }

    var body: some View {
        HStack(spacing: 0) {
            ForEach(segments) { segment in
                segmentButton(segment)
            }
        }
        .padding(2)
        .background(
            RoundedRectangle(cornerRadius: Self.containerRadius, style: .continuous)
                .fill(AppColors.windowBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Self.containerRadius, style: .continuous)
                .strokeBorder(AppColors.border, lineWidth: 1)
        )
        .fixedSize()
    }

    @ViewBuilder
    private func segmentButton(_ segment: Segment) -> some View {
        let isSelected = segment.value == selection

        Button {
            guard segment.isEnabled, !isSelected else { return }
            onSelect(segment.value)
        } label: {
            HStack(spacing: 5) {
                Text(segment.title)
                    .font(isSelected ? AppTypography.labelSemibold : AppTypography.label)
                    .foregroundStyle(labelColor(segment: segment, isSelected: isSelected))

                if let indicator = segment.indicator {
                    Circle()
                        .fill(indicator.color)
                        .frame(width: Self.dotSize, height: Self.dotSize)
                }
            }
            .padding(.vertical, 4)
            .padding(.horizontal, 12)
            .background(
                RoundedRectangle(cornerRadius: Self.segmentRadius, style: .continuous)
                    .fill(isSelected ? AppColors.contentBackground : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Self.segmentRadius, style: .continuous)
                    .strokeBorder(isSelected ? AppColors.border : Color.clear, lineWidth: 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: Self.segmentRadius, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(!segment.isEnabled)
        .focusRing(.rounded(.sm))
        .help(segment.helpText ?? "")
        .accessibilityIdentifier(segment.accessibilityIdentifier ?? "")
        .accessibilityLabel(segment.title)
        .accessibilityHint(segment.helpText ?? "")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func labelColor(segment: Segment, isSelected: Bool) -> Color {
        guard segment.isEnabled else { return AppColors.textTertiary }
        return isSelected ? AppColors.textPrimary : AppColors.textSecondary
    }
}

#Preview("SegmentedViewToggle") {
    VStack(alignment: .leading, spacing: 12) {
        SegmentedViewToggle(
            segments: [
                .init(value: "notes", title: "My notes"),
                .init(value: "enhanced", title: "Enhanced"),
                .init(value: "transcript", title: "Transcript")
            ],
            selection: "notes",
            onSelect: { _ in }
        )

        SegmentedViewToggle(
            segments: [
                .init(value: "notes", title: "My notes"),
                .init(
                    value: "enhanced",
                    title: "Enhanced",
                    isEnabled: false,
                    helpText: "Available when the recording is finished"
                ),
                .init(value: "transcript", title: "Transcript", indicator: .live)
            ],
            selection: "notes",
            onSelect: { _ in }
        )

        SegmentedViewToggle(
            segments: [
                .init(value: "notes", title: "My notes"),
                .init(value: "enhanced", title: "Enhanced", indicator: .ready),
                .init(value: "transcript", title: "Transcript")
            ],
            selection: "transcript",
            onSelect: { _ in }
        )
    }
    .padding(16)
    .background(AppColors.contentBackground)
    .themeRefresh()
}
