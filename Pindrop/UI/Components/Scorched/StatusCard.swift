//
//  StatusCard.swift
//  Pindrop
//
//  Created on 2026-07-09.
//

import SwiftUI

/// What the sidebar knows about the one live note capture.
///
/// The sidebar cannot reach the capture controller, and the note title lives in
/// the store, so the shell hands the card this much and nothing more.
struct SidebarCaptureStatus: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        /// Audio is being recorded into the note.
        case recording
        /// The recording stopped and the transcript and note are being produced.
        case finalizing
    }

    var kind: Kind
    /// When the recording began. `nil` while the capture is still starting.
    var startedAt: Date?
    /// The note the capture writes to, so the card can navigate to it.
    var noteID: UUID?

    init(kind: Kind, startedAt: Date? = nil, noteID: UUID? = nil) {
        self.kind = kind
        self.startedAt = startedAt
        self.noteID = noteID
    }

    func elapsed(now: Date) -> TimeInterval {
        guard let startedAt else { return 0 }
        return max(0, now.timeIntervalSince(startedAt))
    }
}

/// Where clicking the status card goes.
enum StatusCardDestination: Equatable, Sendable {
    /// The note that is recording right now.
    case capturingNote(UUID)
    /// Dictation has no page of its own beyond Dictate.
    case dictate

    /// A note capture owns the card whenever it is running; otherwise the card
    /// belongs to dictation.
    static func resolve(noteCapture: SidebarCaptureStatus?) -> StatusCardDestination {
        guard let noteID = noteCapture?.noteID else { return .dictate }
        return .capturingNote(noteID)
    }
}

/// Sidebar status card phase driven by floating-indicator recording state.
enum StatusCardPhase: Equatable {
    case ready
    case recording(duration: TimeInterval)
    /// A note capture stopped recording and is being turned into a note.
    case finalizing(duration: TimeInterval)
    case processing

    @MainActor
    init(state: FloatingIndicatorState) {
        self.init(isRecording: state.isRecording, isProcessing: state.isProcessing, duration: state.recordingDuration)
    }

    /// Pure mapping for tests and callers without a live indicator state.
    init(isRecording: Bool, isProcessing: Bool, duration: TimeInterval = 0) {
        if isRecording {
            self = .recording(duration: duration)
        } else if isProcessing {
            self = .processing
        } else {
            self = .ready
        }
    }

    /// A note capture outranks dictation: it is the long-running one, and it is
    /// the one the card navigates to.
    init(
        noteCapture: SidebarCaptureStatus?,
        now: Date = Date(),
        isRecording: Bool,
        isProcessing: Bool,
        duration: TimeInterval = 0
    ) {
        if let noteCapture {
            switch noteCapture.kind {
            case .recording:
                self = .recording(duration: noteCapture.elapsed(now: now))
            case .finalizing:
                self = .finalizing(duration: noteCapture.elapsed(now: now))
            }
            return
        }
        self.init(isRecording: isRecording, isProcessing: isProcessing, duration: duration)
    }

    var isActive: Bool {
        switch self {
        case .ready: return false
        case .recording, .finalizing, .processing: return true
        }
    }

    /// The clock the title carries, when the phase has one.
    var duration: TimeInterval? {
        switch self {
        case .recording(let duration), .finalizing(let duration): return duration
        case .ready, .processing: return nil
        }
    }
}

/// The words on the status card, decided once.
enum StatusCardPresentation {
    /// Active phases carry their clock in the title ("Recording · 4:03"), so the
    /// card can spend its second line on what is being recorded.
    static func title(phase: StatusCardPhase, readyTitle: String? = nil, locale: Locale) -> String {
        switch phase {
        case .ready:
            return readyTitle ?? localized("Ready to dictate", locale: locale)
        case .recording(let duration):
            return clocked(localized("Recording", locale: locale), duration: duration)
        case .finalizing(let duration):
            return clocked(localized("Finalizing", locale: locale), duration: duration)
        case .processing:
            return localized("Processing", locale: locale)
        }
    }

    private static func clocked(_ title: String, duration: TimeInterval) -> String {
        "\(title) · \(StatusCard.formatDuration(duration))"
    }
}

/// "Ready to dictate" / recording / finalizing / processing footer card (spec §3).
///
/// With an `action` the whole card is a button that goes to whatever is running:
/// the note being recorded, or Dictate.
struct StatusCard: View {
    @Environment(\.locale) private var locale

    let phase: StatusCardPhase
    var hotkeyHint: String = ""
    var readyTitle: String?
    /// Second line: the note being recorded, while a note capture runs.
    var subtitle: String?
    var accessibilityIdentifier: String = ""
    var action: (() -> Void)?

    init(
        phase: StatusCardPhase,
        hotkeyHint: String = "",
        readyTitle: String? = nil,
        subtitle: String? = nil,
        accessibilityIdentifier: String = "",
        action: (() -> Void)? = nil
    ) {
        self.phase = phase
        self.hotkeyHint = hotkeyHint
        self.readyTitle = readyTitle
        self.subtitle = subtitle
        self.accessibilityIdentifier = accessibilityIdentifier
        self.action = action
    }

    @MainActor
    init(state: FloatingIndicatorState, hotkeyHint: String = "", readyTitle: String? = nil) {
        self.phase = StatusCardPhase(state: state)
        self.hotkeyHint = hotkeyHint.isEmpty ? state.toggleRecordingHotkey : hotkeyHint
        self.readyTitle = readyTitle
    }

    var body: some View {
        Group {
            if let action {
                Button(action: action) {
                    card.contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                .buttonStyle(.plain)
                .focusRing(.rounded(.md))
            } else {
                card
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(title)
        .accessibilityValue(subtitle ?? "")
        .accessibilityIdentifier(accessibilityIdentifier)
        .accessibilityAddTraits(action == nil ? [] : .isButton)
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: iconName)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(statusColor)
                Text(title)
                    .font(AppTypography.labelSemibold)
                    .foregroundStyle(statusColor)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }

            if let subtitle, !subtitle.isEmpty {
                Text(subtitle)
                    .font(AppTypography.monoSmall)
                    .foregroundStyle(AppColors.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }

            if !hotkeyHint.isEmpty, case .ready = phase {
                Text(hotkeyHint)
                    .font(AppTypography.monoSmall)
                    .foregroundStyle(AppColors.textSecondary)
                    // Key order is the shortcut; it does not mirror with the UI.
                    .environment(\.layoutDirection, .leftToRight)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(backgroundColor)
        )
    }

    private var title: String {
        StatusCardPresentation.title(phase: phase, readyTitle: readyTitle, locale: locale)
    }

    private var iconName: String {
        switch phase {
        case .ready: return "mic.fill"
        case .recording: return "record.circle"
        case .finalizing, .processing: return "ellipsis.circle"
        }
    }

    private var statusColor: Color {
        switch phase {
        case .ready, .finalizing, .processing: return AppColors.accent
        case .recording: return AppColors.recording
        }
    }

    private var backgroundColor: Color {
        switch phase {
        case .ready, .finalizing, .processing: return AppColors.accentBackground
        case .recording: return AppColors.errorBackground
        }
    }

    static func formatDuration(_ duration: TimeInterval) -> String {
        let total = max(0, Int(duration.rounded()))
        let minutes = total / 60
        let seconds = total % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
}

/// Collapsed sidebar status indicator (derived 64 pt rail — not in Paper file).
struct StatusCardDot: View {
    let phase: StatusCardPhase

    @State private var pulse = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.locale) private var locale

    var body: some View {
        Circle()
            .fill(dotColor)
            .frame(width: 8, height: 8)
            .opacity(phase.isActive ? (pulse ? 0.45 : 1.0) : 1.0)
            .animation(
                phase.isActive && !reduceMotion
                    ? .easeInOut(duration: 0.9).repeatForever(autoreverses: true)
                    : nil,
                value: pulse
            )
            .onAppear { pulse = phase.isActive }
            .onChange(of: phase.isActive) { _, active in pulse = active }
            .accessibilityLabel(accessibilityTitle)
    }

    private var dotColor: Color {
        switch phase {
        case .ready, .finalizing, .processing: return AppColors.accent
        case .recording: return AppColors.recording
        }
    }

    private var accessibilityTitle: String {
        switch phase {
        case .ready: return localized("Ready", locale: locale)
        case .recording: return localized("Recording", locale: locale)
        case .finalizing: return localized("Finalizing", locale: locale)
        case .processing: return localized("Processing", locale: locale)
        }
    }
}

#Preview("StatusCard") {
    VStack(spacing: 12) {
        StatusCard(phase: .ready, hotkeyHint: "⌥ Space anywhere")
        StatusCard(phase: .recording(duration: 42), subtitle: "Weekly sync", action: {})
        StatusCard(phase: .finalizing(duration: 243), subtitle: "Weekly sync", action: {})
        StatusCard(phase: .processing, hotkeyHint: "")
    }
    .padding()
    .frame(width: 220)
    .background(AppColors.windowBackground)
    .themeRefresh()
}
