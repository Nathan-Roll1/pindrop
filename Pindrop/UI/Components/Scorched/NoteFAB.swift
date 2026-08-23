//
//  NoteFAB.swift
//  Pindrop
//
//  Created on 2026-08-22.
//
//  The note page's floating control (Round B).
//
//  One button in the bottom-right corner, which grows into whatever the reader
//  asked of it: a fan of satellites on hover, a search pill, a playback pill.
//  There is only ever one of them on screen, and they all grow leftward from the
//  same anchor, so the control reads as changing shape rather than as several
//  controls taking turns in one corner.
//
//  Every decision with a right answer is in `NoteFABPresentation`: which
//  satellites this note has, which shape a state resolves to, how the matches
//  are counted and stepped, and the geometry the shapes share. This file draws
//  those answers.
//
//  The playback clock ticks four times a second and the note page around this
//  control holds a text editor, so the clock is read inside the pill and nowhere
//  above it.
//

import SwiftUI
import Foundation

struct NoteFAB: View {
    @Environment(\.locale) private var locale

    // MARK: Inputs

    let context: NoteFABContext
    @Binding var state: NoteFABState
    /// What is being searched for. The page owns it: the same text narrows the
    /// canvas behind this control.
    @Binding var query: String
    /// How many times the query appears in the view on screen.
    var matchTotal: Int = 0
    /// Which of those matches is the current one.
    @Binding var currentMatch: Int?
    /// The playback clock, read only inside the pill.
    let controller: MediaPlaybackController
    /// The recorded length, used until the asset reports its own.
    var fallbackDuration: TimeInterval = 0
    var onAsk: (() -> Void)?
    var onCopy: (() -> Void)?
    var onPlay: (() -> Void)?
    var onStepMatch: ((NoteFABMatchStep) -> Void)?

    @FocusState private var isFieldFocused: Bool

    private var resolvedState: NoteFABState {
        NoteFABPresentation.resolvedState(state, context: context)
    }

    private var satellites: [NoteFABSatellite] {
        NoteFABPresentation.satellites(context: context, locale: locale)
    }

    private var duration: TimeInterval {
        max(controller.duration, fallbackDuration)
    }

    // MARK: Body

    var body: some View {
        Group {
            if NoteFABPresentation.isVisible(context: context) {
                control
            }
        }
        .accessibilityIdentifier("note.fab")
    }

    private var control: some View {
        VStack(alignment: .trailing, spacing: NoteFABPresentation.satelliteGap) {
            if resolvedState == .fan {
                ForEach(satellites) { satellite in
                    satelliteRow(satellite)
                }
            }

            anchoredControl
        }
        .onHover { isHovering in
            if isHovering {
                if resolvedState == .resting { state = .fan }
            } else if NoteFABPresentation.collapsesOnExit(resolvedState) {
                state = .resting
            }
        }
        .appAnimation(.fast, value: resolvedState)
        // Escape gets out of any expanded shape. It is only installed while
        // there is something to get out of, so a resting corner leaves the key
        // to whatever else wants it.
        .background {
            if resolvedState != .resting {
                Button(action: collapse) { EmptyView() }
                    .keyboardShortcut(.cancelAction)
                    .opacity(0)
                    .frame(width: 0, height: 0)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
        .onChange(of: resolvedState) { _, newValue in
            isFieldFocused = newValue == .search
        }
    }

    @ViewBuilder
    private var anchoredControl: some View {
        switch resolvedState {
        case .resting, .fan:
            restingCircle
        case .search:
            searchPill
        case .playing:
            playingPill
        }
    }

    // MARK: Resting

    private var restingCircle: some View {
        Button {
            state = NoteFABPresentation.restingActivation(context: context)
        } label: {
            Circle()
                .fill(
                    resolvedState == .fan
                        ? AppColors.windowBackground
                        : AppColors.contentBackground
                )
                .frame(
                    width: NoteFABPresentation.restingDiameter,
                    height: NoteFABPresentation.restingDiameter
                )
                .overlay(Circle().strokeBorder(AppColors.border, lineWidth: 1))
                .overlay {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(AppColors.textSecondary)
                }
                .shadow(color: AppColors.shadowColor.opacity(0.10), radius: 14, x: 0, y: 4)
        }
        .buttonStyle(.plain)
        .focusRing(.circle)
        .accessibilityIdentifier("note.fab.resting")
        .accessibilityLabel(NoteFABPresentation.restingLabel(context: context, locale: locale))
    }

    // MARK: Fan

    private func satelliteRow(_ satellite: NoteFABSatellite) -> some View {
        Button {
            perform(satellite.action)
        } label: {
            HStack(spacing: NoteFABPresentation.satelliteGap) {
                Text(satellite.title)
                    .font(AppTypography.captionMedium)
                    .foregroundStyle(AppColors.textSecondary)
                    .fixedSize()
                    .padding(.vertical, 4)
                    .padding(.horizontal, 8)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(AppColors.contentBackground)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .strokeBorder(AppColors.border, lineWidth: 1)
                    )

                Circle()
                    .fill(AppColors.contentBackground)
                    .frame(
                        width: NoteFABPresentation.satelliteDiameter,
                        height: NoteFABPresentation.satelliteDiameter
                    )
                    .overlay(Circle().strokeBorder(AppColors.border, lineWidth: 1))
                    .overlay {
                        Image(systemName: satellite.systemImage)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(
                                satellite.action == .ask
                                    ? AppColors.accent
                                    : AppColors.textSecondary
                            )
                    }
                    .shadow(color: AppColors.shadowColor.opacity(0.10), radius: 14, x: 0, y: 4)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusRing(.rounded(.sm))
        // A satellite is smaller than the circle it fans out of, so it is nudged
        // in by half the difference to stand on the same vertical line.
        .padding(
            .trailing,
            (NoteFABPresentation.restingDiameter - NoteFABPresentation.satelliteDiameter) / 2
        )
        .accessibilityIdentifier(satellite.accessibilityIdentifier)
        .accessibilityLabel(satellite.title)
    }

    // MARK: Search

    private var searchPill: some View {
        HStack(spacing: 8) {
            glyphCircle(systemImage: "magnifyingglass")

            ZStack(alignment: .leading) {
                if query.isEmpty {
                    Text(NoteFABPresentation.searchPlaceholder(locale: locale))
                        .font(AppTypography.body)
                        .foregroundStyle(AppColors.textTertiary)
                        .allowsHitTesting(false)
                }

                TextField("", text: $query)
                    .font(AppTypography.body)
                    .foregroundStyle(AppColors.textPrimary)
                    .textFieldStyle(.plain)
                    .focused($isFieldFocused)
                    // Claim focus when the field enters the tree, not only on
                    // the state change: the change can land before the field
                    // exists, and then the keystrokes go to the title. The tick
                    // of delay is what lets it win: an assignment made while
                    // the field is still being inserted loses to the window's
                    // current first responder.
                    .onAppear {
                        Task { @MainActor in
                            try? await Task.sleep(for: .milliseconds(50))
                            isFieldFocused = true
                        }
                    }
                    .accessibilityIdentifier("note.fab.search.field")
                    .accessibilityLabel(NoteFABPresentation.searchPlaceholder(locale: locale))
            }
            .frame(width: NoteFABPresentation.searchFieldWidth)

            Text(
                NoteFABPresentation.matchCountText(
                    current: currentMatch,
                    total: matchTotal,
                    locale: locale
                )
            )
            .font(AppTypography.monoSmall)
            .foregroundStyle(AppColors.textTertiary)
            .monospacedDigit()
            .environment(\.layoutDirection, .leftToRight)
            .fixedSize()
            .accessibilityIdentifier("note.fab.search.count")
            .accessibilityLabel(
                NoteFABPresentation.matchCountLabel(
                    current: currentMatch,
                    total: matchTotal,
                    locale: locale
                )
            )

            stepButton(
                .previous,
                systemImage: "chevron.up",
                label: NoteFABPresentation.previousMatchLabel(locale: locale)
            )
            stepButton(
                .next,
                systemImage: "chevron.down",
                label: NoteFABPresentation.nextMatchLabel(locale: locale)
            )
        }
        .padding(.vertical, 5)
        .padding(.horizontal, 6)
        .background(pillBackground)
        .accessibilityIdentifier("note.fab.search")
    }

    private func stepButton(
        _ step: NoteFABMatchStep,
        systemImage: String,
        label: String
    ) -> some View {
        Button { onStepMatch?(step) } label: {
            Circle()
                .fill(AppColors.windowBackground)
                .frame(
                    width: NoteFABPresentation.stepButtonDiameter,
                    height: NoteFABPresentation.stepButtonDiameter
                )
                .overlay {
                    Image(systemName: systemImage)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(AppColors.textSecondary)
                }
        }
        .buttonStyle(.plain)
        .focusRing(.circle)
        .disabled(!NoteFABPresentation.canStepMatches(total: matchTotal))
        .opacity(NoteFABPresentation.canStepMatches(total: matchTotal) ? 1 : 0.4)
        .accessibilityIdentifier(
            step == .next ? "note.fab.search.next" : "note.fab.search.previous"
        )
        .accessibilityLabel(label)
    }

    // MARK: Playing

    private var playingPill: some View {
        HStack(spacing: 10) {
            Button(action: controller.togglePlayback) {
                glyphCircle(
                    systemImage: controller.isPlaying ? "pause.fill" : "play.fill",
                    fill: AppColors.windowBackground
                )
            }
            .buttonStyle(.plain)
            .focusRing(.circle)
            .accessibilityIdentifier("note.fab.player.toggle")
            .accessibilityLabel(
                localized(controller.isPlaying ? "Pause" : "Play", locale: locale)
            )

            progressTrack

            Text(
                NoteFABPresentation.clockText(
                    currentTime: controller.currentTime,
                    duration: duration
                )
            )
            .font(AppTypography.monoSmall)
            .foregroundStyle(AppColors.textTertiary)
            .monospacedDigit()
            .environment(\.layoutDirection, .leftToRight)
            .fixedSize()
        }
        .padding(.vertical, 5)
        .padding(.horizontal, 6)
        .background(pillBackground)
        .accessibilityIdentifier("note.fab.player")
    }

    private var progressTrack: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule(style: .continuous)
                    .fill(AppColors.border)
                    .frame(height: NoteFABPresentation.progressHeight)

                Capsule(style: .continuous)
                    .fill(AppColors.accent)
                    .frame(
                        width: geometry.size.width * NoteFABPresentation.progressFraction(
                            currentTime: controller.currentTime,
                            duration: duration
                        ),
                        height: NoteFABPresentation.progressHeight
                    )
            }
            .frame(height: geometry.size.height, alignment: .center)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        controller.seek(
                            to: NoteFABPresentation.seekTime(
                                fraction: value.location.x / max(1, geometry.size.width),
                                duration: duration
                            )
                        )
                    }
            )
        }
        .frame(width: NoteFABPresentation.progressWidth, height: 16)
        .accessibilityIdentifier("note.fab.player.progress")
        .accessibilityLabel(localized("Playback position", locale: locale))
        .accessibilityValue(
            NoteFABPresentation.clockText(
                currentTime: controller.currentTime,
                duration: duration
            )
        )
    }

    // MARK: Shared chrome

    private func glyphCircle(
        systemImage: String,
        fill: Color = AppColors.windowBackground
    ) -> some View {
        Circle()
            .fill(fill)
            .frame(
                width: NoteFABPresentation.pillGlyphDiameter,
                height: NoteFABPresentation.pillGlyphDiameter
            )
            .overlay {
                Image(systemName: systemImage)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(AppColors.textSecondary)
            }
    }

    private var pillBackground: some View {
        Capsule(style: .continuous)
            .fill(AppColors.contentBackground)
            .overlay(Capsule(style: .continuous).strokeBorder(AppColors.border, lineWidth: 1))
            .shadow(color: AppColors.shadowColor.opacity(0.10), radius: 14, x: 0, y: 4)
    }

    // MARK: Actions

    private func perform(_ action: NoteFABAction) {
        switch action {
        case .ask:
            state = .resting
            onAsk?()
        case .copy:
            state = .resting
            onCopy?()
        case .play:
            state = .playing
            onPlay?()
        }
    }

    /// Escape. Closing the search takes the query with it: a narrowed canvas
    /// behind a control that is no longer on screen would have no way back.
    private func collapse() {
        if resolvedState == .search {
            query = ""
            currentMatch = nil
        }
        state = NoteFABPresentation.collapsed(from: resolvedState)
    }
}

// MARK: - Preview

#Preview("Note FAB") {
    NoteFAB(
        context: NoteFABContext(hasAudio: true, canAsk: true, canSearch: true),
        state: .constant(.fan),
        query: .constant(""),
        matchTotal: 3,
        currentMatch: .constant(0),
        controller: MediaPlaybackController()
    )
    .padding(40)
    .frame(width: 520, height: 320, alignment: .bottomTrailing)
    .background(AppColors.contentBackground)
    .environment(\.locale, Locale(identifier: "en"))
    .themeRefresh()
}
