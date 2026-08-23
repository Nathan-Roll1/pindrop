//
//  CaptureBar.swift
//  Pindrop
//
//  Created on 2026-08-22.
//
//  The bar that says "this is recording right now" (WP4).
//
//  Two densities, one component. The page density sits at the bottom of the note
//  that is recording: clock, live level, the sources it is listening to, Finish.
//  The global density is the 44 pt strip pinned to the bottom of every other
//  destination while that capture runs somewhere else: clock, which note, and the
//  two ways out of it.
//
//  Everything with a right answer lives in `CaptureBarPresentation`, a pure value
//  type: which chips exist, whether they can be touched, which actions the bar
//  offers, and what each one is called. The view draws the answer and nothing
//  else, so the rules can be tested without a window.
//
//  The live meters are deliberately NOT part of the presentation. They change per
//  audio buffer; if the bar's own body read them, every buffer would invalidate
//  the note page around it. `CaptureLevelBars` samples them inside its own leaf
//  body instead, so only five rectangles redraw.
//

import SwiftUI
import Foundation

// MARK: - Inputs

/// How much room the bar has, and therefore what it says.
enum CaptureBarDensity: Equatable, Sendable {
    /// Bottom of the note page: level meter and source chips fit.
    case page
    /// 44 pt strip on every other destination: which note, and the way back to it.
    case global
}

/// Where the capture is in its life, as far as the bar is concerned.
enum CaptureBarPhase: Equatable, Sendable {
    /// Nothing has started. The sources can still be changed.
    case idle
    /// Starting up: the sources are fixed, the clock has not begun.
    case starting
    /// Audio is being recorded.
    case recording
}

/// What the bar is drawn from.
struct CaptureBarState: Equatable, Sendable {
    var phase: CaptureBarPhase
    var elapsed: TimeInterval
    /// The note the capture writes to. Empty falls back to the untitled label.
    var noteTitle: String
    var includesSystemAudio: Bool

    init(
        phase: CaptureBarPhase = .recording,
        elapsed: TimeInterval = 0,
        noteTitle: String = "",
        includesSystemAudio: Bool = false
    ) {
        self.phase = phase
        self.elapsed = elapsed
        self.noteTitle = noteTitle
        self.includesSystemAudio = includesSystemAudio
    }

    /// True once the capture owns its sources: they were chosen at start and
    /// cannot be changed without restarting the recording.
    var areSourcesFixed: Bool {
        switch phase {
        case .idle: false
        case .starting, .recording: true
        }
    }
}

// MARK: - Presentation

/// One audio source, as a chip.
struct CaptureBarSourceChip: Equatable, Sendable, Identifiable {
    enum Source: Equatable, Sendable {
        case microphone
        case systemAudio
    }

    let source: Source
    let title: String
    /// Filled treatment: this source is being recorded.
    let isOn: Bool
    let isEnabled: Bool
    /// Why the chip cannot be touched.
    let helpText: String?

    var id: Source { source }

    var accessibilityIdentifier: String {
        switch source {
        case .microphone: "capture.bar.source.microphone"
        case .systemAudio: "capture.bar.source.systemAudio"
        }
    }
}

/// One button on the bar.
struct CaptureBarAction: Equatable, Sendable, Identifiable {
    enum Kind: Equatable, Sendable {
        /// Goes to the note the capture is writing to.
        case openNote
        /// Stops the recording and starts finalization.
        case finish
    }

    let kind: Kind
    let title: String
    let isEnabled: Bool

    var id: Kind { kind }

    /// The accent-filled one. Only Finish is.
    var isPrimary: Bool { kind == .finish }

    var accessibilityIdentifier: String {
        switch kind {
        case .openNote: "capture.bar.openNote"
        case .finish: "capture.bar.finish"
        }
    }
}

/// Everything the bar draws, decided once and tested without a window.
struct CaptureBarPresentation: Equatable, Sendable {
    let density: CaptureBarDensity
    /// Zero-padded mm:ss (h:mm:ss past an hour).
    let elapsedText: String
    /// The note being recorded. Only the global density names it: on the note
    /// page the title is already at the top of the page.
    let title: String?
    /// The reassurance line beside the title.
    let detail: String?
    let chips: [CaptureBarSourceChip]
    /// In drawing order, leading to trailing.
    let actions: [CaptureBarAction]
    let showsLevelBars: Bool

    /// The one place the bar's rules live.
    static func make(
        state: CaptureBarState,
        density: CaptureBarDensity,
        locale: Locale
    ) -> CaptureBarPresentation {
        CaptureBarPresentation(
            density: density,
            elapsedText: NoteRowPresentation.elapsedText(state.elapsed),
            title: density == .global ? noteTitle(state: state, locale: locale) : nil,
            detail: density == .global
                ? localized("Recording continues while you work", locale: locale)
                : nil,
            chips: density == .page ? chips(state: state, locale: locale) : [],
            actions: actions(state: state, density: density, locale: locale),
            showsLevelBars: density == .page && state.phase == .recording
        )
    }

    /// The action of a kind, or nil when this density does not offer it.
    func action(_ kind: CaptureBarAction.Kind) -> CaptureBarAction? {
        actions.first { $0.kind == kind }
    }

    private static func noteTitle(state: CaptureBarState, locale: Locale) -> String {
        let trimmed = state.noteTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? localized("Untitled Note", locale: locale) : trimmed
    }

    private static func chips(state: CaptureBarState, locale: Locale) -> [CaptureBarSourceChip] {
        // The sources were chosen when the recording started. Saying so is the
        // whole point of leaving the chips on screen but untouchable.
        let helpText = state.areSourcesFixed
            ? localized("Sources are fixed when the recording starts.", locale: locale)
            : nil
        return [
            CaptureBarSourceChip(
                source: .microphone,
                title: localized("Mic", locale: locale),
                isOn: true,
                isEnabled: !state.areSourcesFixed,
                helpText: helpText
            ),
            CaptureBarSourceChip(
                source: .systemAudio,
                title: localized("System audio", locale: locale),
                isOn: state.includesSystemAudio,
                isEnabled: !state.areSourcesFixed,
                helpText: helpText
            )
        ]
    }

    private static func actions(
        state: CaptureBarState,
        density: CaptureBarDensity,
        locale: Locale
    ) -> [CaptureBarAction] {
        var actions: [CaptureBarAction] = []
        if density == .global {
            actions.append(
                CaptureBarAction(
                    kind: .openNote,
                    title: localized("Open note", locale: locale),
                    isEnabled: true
                )
            )
        }
        actions.append(
            CaptureBarAction(
                kind: .finish,
                title: localized("Finish", locale: locale),
                // Nothing to finish until the recorder is actually running.
                isEnabled: state.phase == .recording
            )
        )
        return actions
    }
}

// MARK: - Global bar visibility

/// When the global strip is on screen.
///
/// The rule reads as one sentence: a note is recording, and the person is looking
/// at something else. On the capturing note the in-page capture dock says the same
/// thing better, so the strip stays away.
enum GlobalCaptureBarVisibility {
    static func isVisible(
        isRecording: Bool,
        capturingNoteID: UUID?,
        openNoteID: UUID?
    ) -> Bool {
        guard isRecording, let capturingNoteID else { return false }
        return openNoteID != capturingNoteID
    }
}

// MARK: - View

/// The capture bar. See `CaptureBarPresentation` for what it decides to show.
struct CaptureBar: View {
    @Environment(\.locale) private var locale

    let presentation: CaptureBarPresentation
    /// Samples the live meters. Called only inside `CaptureLevelBars`, never in
    /// this body, so per-buffer audio cannot invalidate the page around the bar.
    var levels: (@MainActor () -> CaptureLevelSample)?
    let onAction: (CaptureBarAction.Kind) -> Void

    var body: some View {
        switch presentation.density {
        case .page:
            pageBar
        case .global:
            globalBar
        }
    }

    // MARK: Page density

    private var pageBar: some View {
        HStack(spacing: 12) {
            recordingDot

            // Spec: mono 13/500 on the page density, 12 on the global strip.
            elapsedLabel(font: AppTypography.monoTimeLarge)

            if presentation.showsLevelBars, let levels {
                CaptureLevelBars(sample: levels)
            }

            Spacer(minLength: 8)

            ForEach(presentation.chips) { chip in
                CaptureSourceChip(chip: chip)
            }

            actionButtons
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityIdentifier("capture.bar.page")
    }

    // MARK: Global density

    private var globalBar: some View {
        HStack(spacing: 12) {
            recordingDot

            elapsedLabel(font: AppTypography.monoTime)

            if let title = presentation.title {
                Text(title)
                    .font(AppTypography.labelStrong)
                    .foregroundStyle(AppColors.textPrimary)
                    .lineLimit(1)
            }

            if let detail = presentation.detail {
                Text(detail)
                    .font(AppTypography.label)
                    .foregroundStyle(AppColors.textTertiary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            actionButtons
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 20)
        // At least the design's 44 pt, and taller if a button needs it: the strip
        // reserves layout height, so clipping here would hide its own controls.
        .frame(minHeight: 44)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppColors.contentBackground)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(AppColors.border)
                .frame(height: 1)
        }
        .accessibilityIdentifier("capture.bar.global")
    }

    // MARK: Parts

    private var recordingDot: some View {
        Circle()
            .fill(AppColors.recording)
            .frame(width: 8, height: 8)
            .accessibilityHidden(true)
    }

    private func elapsedLabel(font: Font) -> some View {
        Text(presentation.elapsedText)
            .font(font)
            .foregroundStyle(AppColors.textPrimary)
            .monospacedDigit()
            .environment(\.layoutDirection, .leftToRight)
            .accessibilityLabel(localized("Recording", locale: locale))
            .accessibilityValue(presentation.elapsedText)
    }

    private var actionButtons: some View {
        ForEach(presentation.actions) { action in
            if action.isPrimary {
                PrimaryButton(
                    title: action.title,
                    isEnabled: action.isEnabled,
                    action: { onAction(action.kind) }
                )
                .accessibilityIdentifier(action.accessibilityIdentifier)
            } else {
                SecondaryButton(
                    title: action.title,
                    action: { onAction(action.kind) }
                )
                .disabled(!action.isEnabled)
                .accessibilityIdentifier(action.accessibilityIdentifier)
            }
        }
    }
}

/// One source chip: on is filled accent, off is an outlined ring.
private struct CaptureSourceChip: View {
    let chip: CaptureBarSourceChip

    @Environment(\.locale) private var locale

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .strokeBorder(
                    chip.isOn ? Color.clear : AppColors.textTertiary,
                    lineWidth: 1.2
                )
                .background(Circle().fill(chip.isOn ? AppColors.accent : Color.clear))
                .frame(width: 6, height: 6)

            Text(chip.title)
                .font(chip.isOn ? AppTypography.badge : AppTypography.captionMedium)
                .foregroundStyle(chip.isOn ? AppColors.accent : AppColors.textTertiary)
                .lineLimit(1)
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 10)
        .background {
            if chip.isOn {
                Capsule(style: .continuous).fill(AppColors.accentBackground)
            }
        }
        .overlay {
            if !chip.isOn {
                Capsule(style: .continuous).strokeBorder(AppColors.border, lineWidth: 1)
            }
        }
        .opacity(chip.isEnabled ? 1 : 0.75)
        .help(chip.helpText ?? "")
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(chip.accessibilityIdentifier)
        .accessibilityLabel(chip.title)
        // On and off differ only by fill and dot, so the state has to be spoken.
        .accessibilityValue(localized(chip.isOn ? "On" : "Off", locale: locale))
        .accessibilityHint(chip.helpText ?? "")
    }
}

// MARK: - Preview

#Preview("CaptureBar") {
    VStack(spacing: 16) {
        CaptureBar(
            presentation: CaptureBarPresentation.make(
                state: CaptureBarState(
                    phase: .recording,
                    elapsed: 243,
                    noteTitle: "Weekly sync",
                    includesSystemAudio: true
                ),
                density: .page,
                locale: Locale(identifier: "en")
            ),
            levels: { CaptureLevelSample(level: 0.6, bands: AudioBandLevels(low: 0.7, mid: 0.5, high: 0.3)) },
            onAction: { _ in }
        )
        .background(AppColors.windowBackground)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(AppColors.border, lineWidth: 1)
        )
        .padding(.horizontal, 40)

        CaptureBar(
            presentation: CaptureBarPresentation.make(
                state: CaptureBarState(phase: .recording, elapsed: 243, noteTitle: "Weekly sync"),
                density: .global,
                locale: Locale(identifier: "en")
            ),
            onAction: { _ in }
        )
    }
    .padding(.vertical, 24)
    .frame(width: 820)
    .background(AppColors.contentBackground)
    .themeRefresh()
}
