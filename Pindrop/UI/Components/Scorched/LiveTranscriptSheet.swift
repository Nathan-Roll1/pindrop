//
//  LiveTranscriptSheet.swift
//  Pindrop
//
//  Created on 2026-08-22.
//
//  The live half of the capture dock (WP5).
//
//  While a note is recording, the dock's top half is a sheet the person can pull
//  open: collapsed it is one line, the last thing Pindrop heard; opened it is the
//  running transcript, settled words in the reading ink and the tentative tail in
//  the quiet one.
//
//  The sheet reads `NoteCaptureState` inside its own body on purpose. Live text
//  changes several times a second and the note page around it holds a text
//  editor, so the observation has to stop here.
//

import SwiftUI
import Foundation

// MARK: - Snap points

/// How far the live sheet is open.
enum TranscriptSheetDetent: String, CaseIterable, Equatable, Sendable {
    /// One line and a handle.
    case collapsed
    /// About 40% of the canvas.
    case medium
    /// About 70% of the canvas.
    case expanded

    var isOpen: Bool { self != .collapsed }
}

/// Where the sheet snaps, as plain arithmetic.
enum TranscriptSheetGeometry {
    /// The collapsed row: handle, one line, chevron.
    static let collapsedHeight: CGFloat = 36
    /// Below this an opened sheet shows too little to be worth opening, so a
    /// short window gets the floor rather than a proportional sliver.
    static let minimumExpandedHeight: CGFloat = 260
    static let mediumFraction: CGFloat = 0.40
    static let expandedFraction: CGFloat = 0.70

    static func height(for detent: TranscriptSheetDetent, canvasHeight: CGFloat) -> CGFloat {
        switch detent {
        case .collapsed:
            return collapsedHeight
        case .medium:
            return min(
                expandedHeight(canvasHeight: canvasHeight),
                fitted(canvasHeight * mediumFraction, canvasHeight: canvasHeight)
            )
        case .expanded:
            return expandedHeight(canvasHeight: canvasHeight)
        }
    }

    /// The snap point a dragged height lands on. Ties settle on the smaller one:
    /// a sheet that covers the note is the more surprising outcome.
    static func nearestDetent(
        toHeight height: CGFloat,
        canvasHeight: CGFloat
    ) -> TranscriptSheetDetent {
        var best = TranscriptSheetDetent.collapsed
        var bestDistance = CGFloat.greatestFiniteMagnitude
        for detent in TranscriptSheetDetent.allCases {
            let distance = abs(self.height(for: detent, canvasHeight: canvasHeight) - height)
            if distance < bestDistance {
                bestDistance = distance
                best = detent
            }
        }
        return best
    }

    private static func expandedHeight(canvasHeight: CGFloat) -> CGFloat {
        fitted(canvasHeight * expandedFraction, canvasHeight: canvasHeight)
    }

    private static func fitted(_ proposed: CGFloat, canvasHeight: CGFloat) -> CGFloat {
        let floored = max(proposed, minimumExpandedHeight)
        let ceiling = max(collapsedHeight, canvasHeight)
        return max(collapsedHeight, min(floored, ceiling))
    }
}

// MARK: - Sheet

/// The live transcript sheet at the top of the capture dock.
struct LiveTranscriptSheet: View {
    @Environment(\.locale) private var locale
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// The capture being recorded. Nil draws the resting line.
    let state: NoteCaptureState?
    @Binding var detent: TranscriptSheetDetent
    /// The room the note page has. The open snap points are fractions of it.
    let canvasHeight: CGFloat

    /// Live drag offset, in points, while the handle is held.
    @State private var dragHeight: CGFloat?
    /// True while the newest line should stay pinned to the bottom.
    @State private var isFollowingLive = true

    private static let lineMetrics = TypographyRoleMetrics(
        family: .newsreader, size: 15, weight: .regular, lineHeight: 22
    )
    private static let collapsedLineMetrics = TypographyRoleMetrics(
        family: .newsreader, size: 14, weight: .regular, lineHeight: 20
    )
    private static let scrollSpace = "note.page.capture.live.scroll"

    private var lines: [TranscriptLiveLine] {
        TranscriptSegmentPresentation.liveLines(
            // P1.5 replaces this joined-text adapter with the real turn stack.
            // Until then both live surfaces keep rendering exactly what they
            // rendered before, read out of the spans.
            committed: state?.liveTranscriptText ?? "",
            tentative: state?.liveTentative?.text ?? ""
        )
    }

    private var openHeight: CGFloat {
        dragHeight ?? TranscriptSheetGeometry.height(for: detent, canvasHeight: canvasHeight)
    }

    var body: some View {
        VStack(spacing: 0) {
            handle

            if detent.isOpen || dragHeight != nil {
                expandedContent
            } else {
                collapsedRow
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: detent.isOpen || dragHeight != nil ? openHeight : nil)
        .onExitCommand { collapse() }
        .accessibilityIdentifier("note.page.capture.live")
    }

    // MARK: Handle

    private var handle: some View {
        Capsule(style: .continuous)
            .fill(AppColors.border)
            .frame(width: 36, height: 4)
            .padding(.top, 6)
            .padding(.bottom, 2)
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
            .gesture(dragGesture)
            .onTapGesture { toggle() }
            .accessibilityIdentifier("note.page.capture.live.handle")
            .accessibilityLabel(localized("Live transcript", locale: locale))
            .accessibilityAddTraits(.isButton)
    }

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { value in
                let base = TranscriptSheetGeometry.height(
                    for: detent,
                    canvasHeight: canvasHeight
                )
                dragHeight = max(
                    TranscriptSheetGeometry.collapsedHeight,
                    min(base - value.translation.height, max(canvasHeight, 0))
                )
            }
            .onEnded { _ in
                guard let dragHeight else { return }
                let snapped = TranscriptSheetGeometry.nearestDetent(
                    toHeight: dragHeight,
                    canvasHeight: canvasHeight
                )
                self.dragHeight = nil
                setDetent(snapped)
            }
    }

    // MARK: Collapsed

    private var collapsedRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
                Image(systemName: "mic")
                    .font(.system(size: 13))
                    .foregroundStyle(AppColors.textTertiary)
                    .accessibilityHidden(true)

                Text(TranscriptSegmentPresentation.collapsedLine(
                    committed: state?.liveTranscriptText ?? "",
                    tentative: state?.liveTentative?.text ?? "",
                    locale: locale
                ))
                .font(Self.collapsedLineMetrics.font)
                .foregroundStyle(AppColors.textSecondary)
                .lineLimit(1)
                .truncationMode(.head)
                .frame(maxWidth: .infinity, alignment: .leading)

                chevron(systemImage: "chevron.up", label: localized("Show live transcript", locale: locale))
            }

            degradedNotice
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .onTapGesture { setDetent(.medium) }
        .accessibilityIdentifier("note.page.capture.live.collapsed")
    }

    // MARK: Expanded

    private var expandedContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Text(localized("Live transcript", locale: locale))
                    .font(AppTypography.overline)
                    .tracking(AppTypography.overlineMetrics.tracking)
                    .textCase(.uppercase)
                    .foregroundStyle(AppColors.textTertiary)

                Spacer(minLength: 8)

                chevron(
                    systemImage: "chevron.down",
                    label: localized("Hide live transcript", locale: locale)
                )
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 6)

            linesColumn

            degradedNotice
                .padding(.horizontal, 16)
                .padding(.bottom, 8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityIdentifier("note.page.capture.live.expanded")
    }

    private var linesColumn: some View {
        GeometryReader { viewport in
            ScrollViewReader { proxy in
                ScrollView(.vertical) {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(lines) { line in
                            TranscriptLiveLineText(line: line).id(line.id)
                        }

                        if lines.isEmpty {
                            Text(localized("Listening…", locale: locale))
                                .font(Self.lineMetrics.font)
                                .foregroundStyle(AppColors.textTertiary)
                        }
                    }
                    .frame(maxWidth: 640, alignment: .leading)
                    .padding(.horizontal, 40)
                    .padding(.top, 6)
                    .padding(.bottom, 16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        GeometryReader { content in
                            Color.clear.preference(
                                key: LiveTranscriptBottomKey.self,
                                value: content.frame(in: .named(Self.scrollSpace)).maxY
                            )
                        }
                    )
                }
                .coordinateSpace(name: Self.scrollSpace)
                .onPreferenceChange(LiveTranscriptBottomKey.self) { bottom in
                    let distance = max(0, bottom - viewport.size.height)
                    isFollowingLive = TranscriptSegmentPresentation
                        .followsLive(distanceFromBottom: distance)
                }
                .onChange(of: lines.last?.id) { _, _ in scrollToLive(proxy) }
                .onChange(of: lines.last?.text) { _, _ in scrollToLive(proxy) }
                .onAppear { scrollToLive(proxy, animated: false) }
                .overlay(alignment: .bottomTrailing) {
                    if !isFollowingLive, !lines.isEmpty {
                        jumpToLivePill(proxy)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func jumpToLivePill(_ proxy: ScrollViewProxy) -> some View {
        Button {
            isFollowingLive = true
            scrollToLive(proxy)
        } label: {
            Text(localized("Jump to live", locale: locale))
                .font(AppTypography.badge)
                .foregroundStyle(AppColors.accent)
                .padding(.vertical, 5)
                .padding(.horizontal, 12)
                .background(Capsule(style: .continuous).fill(AppColors.contentBackground))
                .overlay(Capsule(style: .continuous).strokeBorder(AppColors.border, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .focusRing(.capsule)
        .padding(.trailing, 16)
        .padding(.bottom, 12)
        .accessibilityIdentifier("note.page.capture.live.jump")
    }

    // MARK: Parts

    @ViewBuilder
    private var degradedNotice: some View {
        // The recording is unaffected when live text stops, so say both things
        // rather than letting a frozen line imply a dead recorder.
        if state?.isLiveTranscriptDegraded == true {
            Text(localized("Live text stopped. The recording continues.", locale: locale))
                .font(AppTypography.caption)
                .foregroundStyle(AppColors.textTertiary)
                .lineLimit(1)
                .accessibilityIdentifier("note.page.capture.degraded")
        }
    }

    private func chevron(systemImage: String, label: String) -> some View {
        Button(action: toggle) {
            Image(systemName: systemImage)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(AppColors.textTertiary)
                .frame(width: 20, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusRing(.rounded(.sm))
        .accessibilityLabel(label)
        .accessibilityIdentifier("note.page.capture.live.toggle")
    }

    // MARK: Actions

    private func toggle() {
        setDetent(detent.isOpen ? .collapsed : .medium)
    }

    private func collapse() {
        guard detent.isOpen else { return }
        setDetent(.collapsed)
    }

    private func setDetent(_ next: TranscriptSheetDetent) {
        withAnimation(reduceMotion ? nil : AppTheme.Animation.fast) {
            detent = next
        }
    }

    private func scrollToLive(_ proxy: ScrollViewProxy, animated: Bool = true) {
        guard isFollowingLive, let last = lines.last?.id else { return }
        withAnimation(animated && !reduceMotion ? AppTheme.Animation.fast : nil) {
            proxy.scrollTo(last, anchor: .bottom)
        }
    }
}

// MARK: - Line

/// One live line: the settled words in the reading ink, the tail the engine may
/// still rewrite in the quiet one.
struct TranscriptLiveLineText: View {
    static let metrics = TypographyRoleMetrics(
        family: .newsreader, size: 15, weight: .regular, lineHeight: 22
    )

    let line: TranscriptLiveLine

    var body: some View {
        composed
            .font(Self.metrics.font)
            .lineSpacing(Self.metrics.lineSpacing)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityIdentifier("note.page.capture.live.line")
    }

    private var composed: Text {
        let settled = Text(line.text)
            .foregroundStyle(line.isCurrent ? AppColors.textPrimary : AppColors.textSecondary)
        guard let tail = line.tentativeTail else { return settled }
        let spacer = line.text.isEmpty ? "" : " "
        return settled + Text(spacer + tail).foregroundStyle(AppColors.textTertiary)
    }
}

/// The bottom edge of the live lines, in the scroll viewport's own space.
private struct LiveTranscriptBottomKey: PreferenceKey {
    static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}
