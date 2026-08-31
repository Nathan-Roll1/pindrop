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
//  running transcript, read as speaker turns, settled words in the reading ink
//  and the tentative tail in the quiet one.
//
//  The sheet reads `NoteCaptureState` inside its own body on purpose. Live text
//  changes several times a second and the note page around it holds a text
//  editor, so the observation has to stop here.
//

import AppKit
import SwiftUI
import Foundation
import PindropCore

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
    /// Speaker keys already announced. A promotion is announced once for the
    /// life of the sheet, however many turns that speaker holds.
    @State private var announcedPromotions: Set<String> = []

    private static let lineMetrics = TypographyRoleMetrics(
        family: .newsreader, size: 15, weight: .regular, lineHeight: 22
    )
    private static let collapsedLineMetrics = TypographyRoleMetrics(
        family: .newsreader, size: 14, weight: .regular, lineHeight: 20
    )
    private static let scrollSpace = "note.page.capture.live.scroll"

    private var entries: [TranscriptLiveEntry] {
        TranscriptSegmentPresentation.liveEntries(
            spans: state?.liveSpans ?? [],
            tentative: state?.liveTentative,
            // Read per render on purpose: the emphasis window is derived from
            // `promotedAt`, because SwiftUI cannot deliver "true for exactly
            // one render pass".
            now: Date()
        )
    }

    /// The turn the sheet is currently pinned to, if anything has been heard.
    private var newestTurn: TranscriptLiveTurn? {
        entries.compactMap(\.turn).last
    }

    /// Everything the newest turn holds, as one string. The scroll follows this
    /// rather than the entry list, which does not change while a turn grows.
    private var newestTurnText: String {
        guard let newestTurn else { return "" }
        return newestTurn.lines.map { $0.text + ($0.tentativeTail ?? "") }.joined()
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
        // On the root, not on the turn stack: the sheet is collapsed by
        // default, and a promotion has to be announced either way.
        .onChange(of: promotedSpeakers) { _, speakers in announce(speakers) }
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
            // The reader's view, with names and gap markers. The checkpoint
            // string carries neither, so it is deliberately not used here.
            .accessibilityValue(state?.liveTranscriptForCopy(locale: locale) ?? "")
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

                HStack(spacing: 4) {
                    if let collapsedName {
                        // The name keeps the row: the words truncate from the
                        // head, so without a separate view the name would be
                        // the first thing cut.
                        Text("\(collapsedName) ·")
                            .lineLimit(1)
                            .layoutPriority(1)
                    }

                    Text(collapsedLine)
                        .lineLimit(1)
                        .truncationMode(.head)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .font(Self.collapsedLineMetrics.font)
                .foregroundStyle(AppColors.textSecondary)

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

    /// Who spoke last, or nil before anything has been heard.
    private var collapsedName: String? {
        guard let newestTurn else { return nil }
        return NoteCaptureState.speakerName(for: newestTurn.speaker, locale: locale)
    }

    /// The newest thing Pindrop heard, which is the newest turn's newest line.
    private var collapsedLine: String {
        TranscriptSegmentPresentation.collapsedLine(
            committed: state?.liveTranscriptText ?? "",
            tentative: state?.liveTentative?.text ?? "",
            locale: locale
        )
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

            turnsColumn

            degradedNotice
                .padding(.horizontal, 16)
                .padding(.bottom, 8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityIdentifier("note.page.capture.live.expanded")
    }

    private var turnsColumn: some View {
        // Read once per render: every use below is the same list, and building
        // it walks every span of the capture.
        let entries = self.entries
        return GeometryReader { viewport in
            ScrollViewReader { proxy in
                ScrollView(.vertical) {
                    // 12 pt between turns, matching the finished transcript. It
                    // is also the space a gap marker needs above and below it.
                    VStack(alignment: .leading, spacing: TranscriptLiveTurnView.turnSpacing) {
                        ForEach(entries) { entry in
                            TranscriptLiveEntryView(entry: entry).id(entry.id)
                        }

                        if entries.isEmpty {
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
                .onChange(of: entries.last?.id) { _, _ in scrollToLive(proxy) }
                .onChange(of: newestTurnText) { _, _ in scrollToLive(proxy) }
                .onAppear { scrollToLive(proxy, animated: false) }
                .overlay(alignment: .bottomTrailing) {
                    if !isFollowingLive, !entries.isEmpty {
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
                // Two caption lines, and the row grows to hold them. A notice
                // naming a capture channel does not fit on one.
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
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
        guard isFollowingLive, let last = entries.last?.id else { return }
        withAnimation(animated && !reduceMotion ? AppTheme.Animation.fast : nil) {
            proxy.scrollTo(last, anchor: .bottom)
        }
    }

    // MARK: Announcements

    /// Every speaker on screen whose label has been promoted, one entry per
    /// speaker however many turns they hold.
    private var promotedSpeakers: [LiveSpeakerRef] {
        var seen: Set<String> = []
        return entries.compactMap(\.turn).map(\.speaker).filter { speaker in
            guard speaker.promotedAt != nil,
                  let previous = speaker.previousDisplayName,
                  !previous.isEmpty,
                  !seen.contains(speaker.key)
            else { return false }
            seen.insert(speaker.key)
            return true
        }
    }

    /// Says who a speaker turned out to be, once. New turns are never
    /// announced: a caption stream announced continuously is unusable.
    private func announce(_ speakers: [LiveSpeakerRef]) {
        for speaker in speakers where !announcedPromotions.contains(speaker.key) {
            announcedPromotions.insert(speaker.key)
            guard let previous = speaker.previousDisplayName else { continue }
            let message = String(
                format: localized("%1$@ is now %2$@.", locale: locale),
                previous,
                NoteCaptureState.speakerName(for: speaker, locale: locale)
            )
            // AppKit's announcement notification is the macOS live-region
            // equivalent. The sheet posts it, not the note page, so a promotion
            // is announced once when both live surfaces are on screen.
            NSAccessibility.post(
                element: NSApp as Any,
                notification: .announcementRequested,
                userInfo: [
                    .announcement: message,
                    .priority: NSAccessibilityPriorityLevel.high.rawValue,
                ]
            )
        }
    }
}

// MARK: - Entries

/// One entry of the live transcript: a speaker turn, or the gap where cross
/// talk cost the live engine some speech.
///
/// Both live surfaces draw this, so the capture sheet and the note page's
/// transcript tab can never disagree about who said what.
struct TranscriptLiveEntryView: View {
    let entry: TranscriptLiveEntry

    var body: some View {
        switch entry {
        case .turn(let turn):
            TranscriptLiveTurnView(turn: turn)
        case .droppedSpeech(_, let source, _):
            TranscriptLiveDroppedSpeechRow(source: source)
        }
    }
}

/// One live turn: who is talking, when they started, and what they have said.
struct TranscriptLiveTurnView: View {
    /// The space between two turns, and the space a gap marker needs above and
    /// below it. Same measure as the finished transcript's turn stack.
    static let turnSpacing: CGFloat = 12

    @Environment(\.locale) private var locale
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let turn: TranscriptLiveTurn

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            header

            VStack(alignment: .leading, spacing: 4) {
                ForEach(turn.lines) { line in
                    TranscriptLiveLineText(line: line, isCurrentTurn: turn.isCurrent)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityIdentifier("note.page.capture.live.turn")
    }

    private var name: String {
        NoteCaptureState.speakerName(for: turn.speaker, locale: locale)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            // The dot only repeats the speaker the name beside it already gives.
            Circle()
                .fill(turn.speaker.isCurrentUser
                      ? AppColors.accent
                      : LibrarySpeakerColor.color(for: turn.speaker.key))
                .frame(width: 6, height: 6)
                .accessibilityHidden(true)

            Text(name)
                .font(AppTypography.labelSemibold)
                .foregroundStyle(AppColors.textPrimary)
                .contentTransition(reduceMotion ? .identity : .opacity)
                .animation(reduceMotion ? nil : AppTheme.Animation.fast, value: name)
                .overlay(alignment: .bottom) { promotionUnderline }
                // The transition belongs outside the overlay: it is what draws
                // and fades the rule as the emphasis window opens and closes.
                .animation(
                    reduceMotion ? nil : AppTheme.Animation.fast,
                    value: turn.promotion?.isRecent
                )

            if let promotion = turn.promotion {
                // The affix outlives the emphasis window on purpose: the sheet
                // is collapsed by default and the reader is usually looking at
                // the call window, so a 1.2 s cue alone carries nothing.
                Text(String(format: localized("was %@", locale: locale), promotion.previousDisplayName))
                    .font(AppTypography.caption)
                    .foregroundStyle(AppColors.textTertiary)
            }

            Spacer(minLength: 8)

            if let startOffset = turn.startOffset {
                Text(TranscriptSegmentPresentation.timestampText(startOffset))
                    .font(AppTypography.caption)
                    .foregroundStyle(AppColors.textTertiary)
                    .monospacedDigit()
                    .environment(\.layoutDirection, .leftToRight)
            }
        }
    }

    @ViewBuilder
    private var promotionUnderline: some View {
        if turn.promotion?.isRecent == true, !reduceMotion {
            Rectangle()
                .fill(AppColors.accent)
                .frame(height: 2)
                .offset(y: 3)
                .transition(.opacity)
        }
    }

    /// One element per turn, read as a sentence. The tail the engine may still
    /// rewrite is named rather than read as settled words.
    private var accessibilityLabel: String {
        var spoken: [String] = []
        let settled = turn.lines.map(\.text).filter { !$0.isEmpty }.joined(separator: " ")
        if !settled.isEmpty { spoken.append(settled) }
        let tail = turn.lines.compactMap(\.tentativeTail).joined(separator: " ")
        if !tail.isEmpty {
            spoken.append(String(format: localized("Still hearing: %@", locale: locale), tail))
        }
        return String(
            format: localized("%1$@ said: %2$@", locale: locale),
            name,
            spoken.joined(separator: " ")
        )
    }
}

/// The gap where the other channel was talking and the live engine was busy.
/// One quiet line, no dot and no bubble: it is not a turn, it is a note about
/// one that is missing.
struct TranscriptLiveDroppedSpeechRow: View {
    @Environment(\.locale) private var locale

    let source: CaptureSourceKind

    var body: some View {
        Text(text)
            .font(AppTypography.caption)
            .foregroundStyle(AppColors.textTertiary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(text)
            .accessibilityIdentifier("note.page.capture.live.dropped")
    }

    private var text: String {
        NoteCaptureState.droppedSpeechText(
            for: .channel(for: source),
            locale: locale
        )
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
    /// The turn's own currency. Every line of the newest turn reads in the
    /// primary ink, so inside a turn the line's own flag does not decide the
    /// colour. Nil leaves the line to speak for itself.
    var isCurrentTurn: Bool?

    var body: some View {
        composed
            .font(Self.metrics.font)
            .lineSpacing(Self.metrics.lineSpacing)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityIdentifier("note.page.capture.live.line")
    }

    private var composed: Text {
        let settled = Text(line.text)
            .foregroundStyle(
                (isCurrentTurn ?? line.isCurrent) ? AppColors.textPrimary : AppColors.textSecondary
            )
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
