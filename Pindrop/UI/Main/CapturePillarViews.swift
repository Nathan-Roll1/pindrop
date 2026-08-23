//
//  CapturePillarViews.swift
//  Pindrop
//
//  The Dictate destination: the retrospective dashboard (hero, stats, recent,
//  charts) with one action frame on the kicker row. That frame starts a
//  dictation and then becomes it, so the page never moves under the pointer.
//  The Voice Note and Meeting pillars merged into the one Notes page (WP2).
//

import SwiftUI
import SwiftData
import PindropCore
import PindropData

struct DictateView: View {
    @Environment(\.locale) private var locale
    @Query(sort: \TranscriptionRecord.timestamp, order: .reverse) private var transcriptions: [TranscriptionRecord]
    /// Shared settings reference — not observed at the root so unrelated
    /// SettingsStore publications do not invalidate the retrospective content.
    private let settingsStore: SettingsStore
    /// Aggregation cache keyed by record projection + calendar day. Hover/selection
    /// live in chart children so pointer movement cannot invalidate this work.
    @State private var statsCache = DashboardStatsCache()
    @State private var chartRowWidth: CGFloat = 0

    let recordingState: RecordingFeatureState?
    /// Dictation's own recording state. Read only inside `DictateActionFrame`,
    /// never in this body: its clock ticks ten times a second, and the page
    /// around it must not redraw with it.
    let dictationState: FloatingIndicatorState?
    let isCaptureBusy: Bool
    /// True while a note capture owns the recorder. The action frame then keeps
    /// its start face: that recording belongs to the note, not to this page.
    let isNoteCaptureActive: Bool
    let onStartDictation: (() -> Void)?
    let onStopDictation: (() -> Void)?
    let onOpenLibrary: (() -> Void)?
    let onShowMoreStats: (() -> Void)?
    let onOpenLibraryRecord: ((UUID) -> Void)?
    let onDownloadDiarizationModel: (() -> Void)?

    /// Keyboard selection in the Recent list (↑/↓ move, Return opens, Esc clears).
    @State private var selectedRecordID: UUID?

    init(
        settingsStore: SettingsStore,
        recordingState: RecordingFeatureState? = nil,
        dictationState: FloatingIndicatorState? = nil,
        isCaptureBusy: Bool = false,
        isNoteCaptureActive: Bool = false,
        onStartDictation: (() -> Void)? = nil,
        onStopDictation: (() -> Void)? = nil,
        onOpenLibrary: (() -> Void)? = nil,
        onShowMoreStats: (() -> Void)? = nil,
        onOpenLibraryRecord: ((UUID) -> Void)? = nil,
        onDownloadDiarizationModel: (() -> Void)? = nil
    ) {
        self.settingsStore = settingsStore
        self.recordingState = recordingState
        self.dictationState = dictationState
        self.isCaptureBusy = isCaptureBusy
        self.isNoteCaptureActive = isNoteCaptureActive
        self.onStartDictation = onStartDictation
        self.onStopDictation = onStopDictation
        self.onOpenLibrary = onOpenLibrary
        self.onShowMoreStats = onShowMoreStats
        self.onOpenLibraryRecord = onOpenLibraryRecord
        self.onDownloadDiarizationModel = onDownloadDiarizationModel
    }

    // MARK: - Stats

    private var calendar: Calendar { Calendar.current }

    private var recentRecords: [TranscriptionRecord] {
        Array(transcriptions.prefix(5))
    }

    private var isFirstRun: Bool {
        transcriptions.isEmpty
    }

    /// Sendable value projection for cache invalidation (data changes, not object identity).
    private var recordProjection: [StatsSample] {
        transcriptions.asStatsSamples()
    }

    private func stats(now: Date) -> DashboardStats {
        statsCache.stats(
            for: DashboardStatsCache.Key(
                samples: recordProjection,
                dayStart: calendar.startOfDay(for: now),
                firstWeekday: calendar.firstWeekday,
                timeZoneIdentifier: calendar.timeZone.identifier
            ),
            calendar: calendar,
            now: now
        )
    }

    // MARK: - Body

    var body: some View {
        TimelineView(HomeDayBoundarySchedule(calendar: calendar)) { _ in
            homeContent(now: Date())
        }
    }

    private func homeContent(now: Date) -> some View {
        let dashboardStats = stats(now: now)
        return ScrollView(showsIndicators: true) {
            VStack(alignment: .leading, spacing: 0) {
                if let setupIssue = recordingState?.setupIssue {
                    DiarizationSetupIssueBanner(
                        message: setupIssue,
                        isDownloading: recordingState?.isDiarizationModelDownloading ?? false,
                        progress: recordingState?.diarizationModelDownloadProgress ?? 0.0,
                        onDownload: onDownloadDiarizationModel
                    )
                    .padding(.bottom, 16)
                }

                kickerRow(now: now)
                heroBlock(now: now, stats: dashboardStats)
                statsStrip(stats: dashboardStats)
                recentSection
                chartRowWidthProbe
                thisWeekChart(now: now, stats: dashboardStats)
            }
            .padding(.horizontal, 40)
            .padding(.top, 40)
            .padding(.bottom, 40)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(AppColors.contentBackground)
        .listKeyboardSelection(isSearchFieldFocused: false) { command in
            handleRecentListCommand(command)
        }
        .accessibilityIdentifier("main.destination.dictate")
    }

    /// Date kicker on the left, the one action frame on the right at the page
    /// padding. The frame starts a dictation and then becomes that dictation.
    private func kickerRow(now: Date) -> some View {
        // Centered, not baseline-aligned: both labels are vertically centred in
        // the 36 pt frame, so their baselines land together anyway, and the row
        // cannot collapse if the frame stops exposing a text baseline.
        HStack(alignment: .center, spacing: 16) {
            Text(HomePresentation.dateKicker(date: now, locale: locale, calendar: calendar))
                .font(AppTypography.overline)
                .foregroundStyle(AppColors.textTertiary)
                .tracking(AppTypography.overlineTracking)

            Spacer(minLength: 0)

            DictateActionFrame(
                settingsStore: settingsStore,
                dictationState: dictationState,
                isCaptureBusy: isCaptureBusy,
                isNoteCaptureActive: isNoteCaptureActive,
                isStartAvailable: onStartDictation != nil,
                onStart: { onStartDictation?() },
                onStop: { onStopDictation?() }
            )
        }
    }

    // MARK: - Hero

    private func heroBlock(now: Date, stats: DashboardStats) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if isFirstRun {
                DictateEmptyHero(settingsStore: settingsStore)
                    .padding(.top, 8)
                    .padding(.bottom, HomeLayoutMetrics.heroBottomPadding)
            } else {
                heroSentence(stats: stats)
                    .padding(.top, 6)
                    .padding(.bottom, HomeLayoutMetrics.heroBottomPadding)

                let sub = HomePresentation.subLine(
                    dictationDuration: stats.dictationDurationThisWeek,
                    timeSaved: stats.timeSavedThisWeek,
                    locale: locale
                )
                if !sub.isEmpty {
                    Text(sub)
                        .font(AppTypography.bodyMeta)
                        .foregroundStyle(AppColors.textSecondary)
                        .lineSpacing(AppTypography.bodyMetaLineSpacing)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }


    private func heroSentence(stats: DashboardStats) -> some View {
        let parts = HomePresentation.heroSentenceParts(
            wordsThisWeek: stats.wordsThisWeek,
            locale: locale
        )
        return captureHeroText(parts: parts)
    }

    // MARK: - Stats strip

    private func statsStrip(stats: DashboardStats) -> some View {
        let tiles = HomePresentation.statTiles(
            wordsToday: stats.wordsToday,
            wpmThisWeek: stats.wpmThisWeek,
            streakDays: stats.streakDays,
            locale: locale
        )
        return HStack(spacing: 0) {
            ForEach(Array(tiles.enumerated()), id: \.element.id) { index, tile in
                if index > 0 {
                    statsDivider
                }
                homeStat(value: tile.value, label: tile.label)
            }

            Spacer(minLength: 0)
        }
        .padding(.top, HomeLayoutMetrics.statsTopPadding)
        .padding(.bottom, HomeLayoutMetrics.statsBottomPadding)
    }

    private var statsDivider: some View {
        Rectangle()
            .fill(AppColors.border)
            .frame(width: HomeLayoutMetrics.statsDividerWidth, height: HomeLayoutMetrics.statsDividerHeight)
            .padding(.horizontal, HomeLayoutMetrics.statsGroupPadding)
    }

    private func homeStat(value: String, label: String) -> some View {
        VStack(alignment: .leading, spacing: HomeLayoutMetrics.statsInnerGap) {
            Text(value)
                .font(AppTypography.statNumber)
                .foregroundStyle(AppColors.textPrimary)
                .monospacedDigit()

            Text(label.uppercased(with: locale))
                .font(AppTypography.statLabel)
                .foregroundStyle(AppColors.textTertiary)
                .tracking(AppTypography.statLabelTracking)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(value), \(label)")
    }

    // MARK: - Recent

    private var recentSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionHeader(title: localized("Recent", locale: locale), isFirst: true) {
                if let onOpenLibrary {
                    CaptureRecentLink(
                        title: localized("Open Library", locale: locale),
                        identifier: "capture.dictate.openLibrary",
                        action: onOpenLibrary
                    )
                }
            }

            if recentRecords.isEmpty {
                emptyRecentHint
                    .padding(.top, 16)
            } else {
                VStack(spacing: 0) {
                    ForEach(recentRecords) { record in
                        CaptureRecentRow(
                            record: record,
                            isSelected: selectedRecordID == record.id
                        ) {
                            selectedRecordID = record.id
                            onOpenLibraryRecord?(record.id)
                        }
                    }
                }
                .padding(.top, 4)
            }
        }
    }

    private var emptyRecentHint: some View {
        Text(localized("Your latest dictations will show up here.", locale: locale))
            .font(AppTypography.body)
            .foregroundStyle(AppColors.textTertiary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 12)
    }

    /// Keyboard selection over the Recent list. There is nothing to delete from
    /// this page, so Delete falls through to whoever else wants it.
    private func handleRecentListCommand(_ command: ListKeyboardCommand) -> Bool {
        let records = recentRecords
        switch command {
        case .moveUp:
            return moveRecentSelection(delta: -1, records: records)
        case .moveDown:
            return moveRecentSelection(delta: 1, records: records)
        case .activate:
            guard let selectedRecordID, records.contains(where: { $0.id == selectedRecordID }) else {
                return false
            }
            onOpenLibraryRecord?(selectedRecordID)
            return true
        case .clearSelection:
            guard selectedRecordID != nil else { return false }
            selectedRecordID = nil
            return true
        case .delete:
            return false
        }
    }

    private func moveRecentSelection(delta: Int, records: [TranscriptionRecord]) -> Bool {
        guard !records.isEmpty else { return false }
        let current = selectedRecordID.flatMap { id in records.firstIndex { $0.id == id } }
        guard let next = ListSelectionNavigation.moveIndex(
            current: current,
            count: records.count,
            delta: delta
        ) else {
            return false
        }
        selectedRecordID = records[next].id
        return true
    }

    // MARK: - THIS WEEK chart

    /// Measures the width proposed to the chart row. Must be a sibling of the row,
    /// not attached to it: the heatmap's fixed-size cells give the row itself a
    /// minimum width, so measuring the row would ratchet — once grown, it could
    /// never report a narrower width to shrink back from.
    private var chartRowWidthProbe: some View {
        GeometryReader { proxy in
            Color.clear.onChange(of: proxy.size.width, initial: true) { _, width in
                chartRowWidth = width
            }
        }
        .frame(height: 0)
        .accessibilityHidden(true)
    }

    private func thisWeekChart(now: Date, stats: DashboardStats) -> some View {
        let heatmapWidth = HomePresentation.activityAvailableWidth(chartRowWidth: chartRowWidth)
        let cellMetrics = HomePresentation.activityCellMetrics(availableWidth: heatmapWidth)
        let rowGrowth = HomePresentation.chartRowGrowth(cellMetrics: cellMetrics)

        return HStack(alignment: .top, spacing: HomeLayoutMetrics.chartPanelGap) {
            DashboardWeeklyBarsChart(
                buckets: stats.wordsPerWeekday,
                sessionsThisWeek: stats.sessionsThisWeek,
                now: now,
                locale: locale,
                calendar: calendar,
                barAreaHeight: HomeLayoutMetrics.chartBarAreaHeight + rowGrowth
            )
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(
                minWidth: HomeLayoutMetrics.chartMinimumWidth,
                maxWidth: HomeLayoutMetrics.chartMaximumWidth,
                alignment: .leading
            )

            Rectangle()
                .fill(AppColors.border)
                .frame(
                    width: HomeLayoutMetrics.chartPanelDividerWidth,
                    height: HomeLayoutMetrics.chartPanelDividerHeight + rowGrowth
                )
                .padding(.top, 6)

            DashboardActivityHeatmap(
                buckets: stats.wordsPerActivityDay,
                streakDays: stats.streakDays,
                now: now,
                locale: locale,
                calendar: calendar,
                cellMetrics: cellMetrics,
                availableWidth: heatmapWidth,
                onShowMoreStats: onShowMoreStats
            )
            // minWidth 0 keeps the fixed-size grid from becoming the row's minimum
            // width: without it the window could grow but never shrink back, since
            // the probe would only ever see the already-grown width.
            .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
            .layoutPriority(1)
        }
        .padding(.top, HomeLayoutMetrics.chartTopPadding)
    }
}

// MARK: - Shared capture chrome

/// Hero sentence with the metric in accented italic Newsreader.
private func captureHeroText(parts: HomePresentation.HeroSentenceParts) -> some View {
    let heroFont = AppTypography.heroDisplay
    let metricFont = AppTypography.heroDisplayEmphasis
    let tracking = AppTypography.heroDisplayTracking
    let lineSpacing = AppTypography.heroDisplayLineSpacing

    return (
        Text(parts.before)
            .font(heroFont)
            .foregroundStyle(AppColors.textPrimary)
        + Text(parts.metric)
            .font(metricFont)
            .foregroundStyle(AppColors.accent)
        + Text(parts.after)
            .font(heroFont)
            .foregroundStyle(AppColors.textPrimary)
    )
    .tracking(tracking)
    .lineSpacing(lineSpacing)
    .fixedSize(horizontal: false, vertical: true)
}

// MARK: - Dictate action frame

/// Metrics both faces of the action frame share. One height, so starting a
/// dictation swaps the contents of the frame without moving the page.
private enum DictateActionFrameMetrics {
    static let height: CGFloat = 36
    static let cornerRadius: CGFloat = 8
    static let contentGap: CGFloat = 8
    static let dotSize: CGFloat = 8
    static let startHorizontalPadding: CGFloat = 16
    static let recordingHorizontalPadding: CGFloat = 14
    static let recordingGap: CGFloat = 12
}

/// The one action on the Dictate page: start a dictation, then be that dictation.
///
/// The hotkey is read here, at the leaf, so unrelated `SettingsStore`
/// publications cannot invalidate the dashboard behind it.
private struct DictateActionFrame: View {
    @ObservedObject var settingsStore: SettingsStore
    /// `nil` in previews and test mode: the frame then only offers start.
    var dictationState: FloatingIndicatorState?
    let isCaptureBusy: Bool
    let isNoteCaptureActive: Bool
    let isStartAvailable: Bool
    let onStart: () -> Void
    let onStop: () -> Void

    @Environment(\.locale) private var locale

    var body: some View {
        if let dictationState {
            DictateLiveActionFrame(
                dictationState: dictationState,
                hotkey: settingsStore.toggleHotkey,
                isCaptureBusy: isCaptureBusy,
                isNoteCaptureActive: isNoteCaptureActive,
                isStartAvailable: isStartAvailable,
                onStart: onStart,
                onStop: onStop
            )
        } else {
            DictateActionFrameFace(
                control: HomePresentation.captureControl(
                    isDictating: false,
                    elapsed: 0,
                    isStartAvailable: isStartAvailable,
                    isCaptureBusy: isCaptureBusy,
                    hotkey: settingsStore.toggleHotkey,
                    locale: locale
                ),
                levels: nil,
                onStart: onStart,
                onStop: onStop
            )
        }
    }
}

/// The face that watches dictation. Observing the clock here keeps its ten
/// ticks a second inside this frame instead of the whole dashboard.
private struct DictateLiveActionFrame: View {
    @ObservedObject var dictationState: FloatingIndicatorState
    let hotkey: String
    let isCaptureBusy: Bool
    /// A note capture drives the same recorder and the same meters. It owns the
    /// global capture bar at the bottom of the page, so this frame stays a CTA.
    let isNoteCaptureActive: Bool
    let isStartAvailable: Bool
    let onStart: () -> Void
    let onStop: () -> Void

    @Environment(\.locale) private var locale

    @ViewBuilder
    var body: some View {
        let isDictating = dictationState.isRecording && !isNoteCaptureActive
        let control = HomePresentation.captureControl(
            isDictating: isDictating,
            elapsed: dictationState.recordingDuration,
            isStartAvailable: isStartAvailable,
            isCaptureBusy: isCaptureBusy,
            hotkey: hotkey,
            locale: locale
        )
        if isDictating {
            // Meters are sampled inside `CaptureLevelBars`, never in this body.
            DictateActionFrameFace(
                control: control,
                levels: sampleLevels,
                onStart: onStart,
                onStop: onStop
            )
        } else {
            DictateActionFrameFace(
                control: control,
                levels: nil,
                onStart: onStart,
                onStop: onStop
            )
        }
    }

    @MainActor
    private func sampleLevels() -> CaptureLevelSample {
        CaptureLevelSample(level: dictationState.audioLevel, bands: dictationState.bandLevels)
    }
}

/// Draws whichever face `DictateCaptureControl` asked for.
private struct DictateActionFrameFace: View {
    let control: DictateCaptureControl
    var levels: (@MainActor () -> CaptureLevelSample)?
    let onStart: () -> Void
    let onStop: () -> Void

    @Environment(\.locale) private var locale

    var body: some View {
        Group {
            switch control.mode {
            case .start: startButton
            case .recording: recordingBar
            }
        }
        .frame(height: DictateActionFrameMetrics.height)
    }

    // MARK: Start

    private var startButton: some View {
        Button(action: onStart) {
            HStack(spacing: DictateActionFrameMetrics.contentGap) {
                Circle()
                    .fill(AppColors.contentBackground)
                    .frame(
                        width: DictateActionFrameMetrics.dotSize,
                        height: DictateActionFrameMetrics.dotSize
                    )

                Text(control.startTitle)
                    .font(AppTypography.labelStrongSelected)
                    .foregroundStyle(AppColors.contentBackground)

                Text(control.shortcut)
                    .font(AppTypography.monoSmall)
                    .foregroundStyle(AppColors.contentBackground.opacity(0.72))
                    .environment(\.layoutDirection, .leftToRight)
            }
            .padding(.horizontal, DictateActionFrameMetrics.startHorizontalPadding)
            .frame(height: DictateActionFrameMetrics.height)
            .background(
                RoundedRectangle(
                    cornerRadius: DictateActionFrameMetrics.cornerRadius,
                    style: .continuous
                )
                .fill(control.isStartEnabled ? AppColors.accent : AppColors.accent.opacity(0.4))
            )
        }
        .buttonStyle(.plain)
        .focusRing(.rounded(.sm))
        .disabled(!control.isStartEnabled)
        .help(control.disabledReason ?? "")
        .accessibilityIdentifier("main.capture.dictate.start")
        .accessibilityLabel(control.startTitle)
        .accessibilityHint(control.disabledReason ?? "")
    }

    // MARK: Recording

    private var recordingBar: some View {
        HStack(spacing: DictateActionFrameMetrics.recordingGap) {
            Circle()
                .fill(AppColors.recording)
                .frame(
                    width: DictateActionFrameMetrics.dotSize,
                    height: DictateActionFrameMetrics.dotSize
                )
                .accessibilityHidden(true)

            Text(control.elapsedText)
                .font(AppTypography.monoTimeLarge)
                .foregroundStyle(AppColors.textPrimary)
                .monospacedDigit()
                .environment(\.layoutDirection, .leftToRight)
                .accessibilityLabel(localized("Recording", locale: locale))
                .accessibilityValue(control.elapsedText)

            if let levels {
                CaptureLevelBars(sample: levels)
            }

            DictateStopButton(title: control.stopTitle, action: onStop)
        }
        .padding(.horizontal, DictateActionFrameMetrics.recordingHorizontalPadding)
        .frame(height: DictateActionFrameMetrics.height)
        .background(
            RoundedRectangle(
                cornerRadius: DictateActionFrameMetrics.cornerRadius,
                style: .continuous
            )
            .fill(AppColors.errorBackground)
        )
        .overlay(
            RoundedRectangle(
                cornerRadius: DictateActionFrameMetrics.cornerRadius,
                style: .continuous
            )
            .strokeBorder(AppColors.border, lineWidth: 1)
        )
        .accessibilityElement(children: .contain)
    }
}

/// Quiet button inside the recording frame: page fill, line border, radius 6.
private struct DictateStopButton: View {
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(AppTypography.labelSemibold)
                .foregroundStyle(AppColors.textPrimary)
                .padding(.vertical, 5)
                .padding(.horizontal, 12)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(AppColors.contentBackground)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(AppColors.border, lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
        .focusRing(.rounded(.sm))
        .accessibilityIdentifier("main.capture.dictate.stop")
        .accessibilityLabel(title)
    }
}

/// Section header with a trailing navigation link ("Open Library →").
private struct CaptureRecentLink: View {
    let title: String
    let identifier: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 3) {
                Text(title)
                Image(systemName: "arrow.right")
                    .flipsForRightToLeftLayoutDirection(true)
            }
            .font(FontLoader.font(family: .inter, size: 11, weight: .semibold))
            .foregroundStyle(AppColors.accent)
        }
        .buttonStyle(.plain)
        .keyboardFocusRing(RoundedRectangle(cornerRadius: 5, style: .continuous))
        .accessibilityIdentifier(identifier)
    }
}

/// One transcription row in a capture page's Recent section. Same chrome as the
/// Library rows so the destinations read as one app.
private struct CaptureRecentRow: View {
    @Environment(\.locale) private var locale
    @Environment(\.layoutDirection) private var layoutDirection
    let record: TranscriptionRecord
    /// Set by ↑/↓ keyboard selection over the Recent list.
    var isSelected: Bool = false
    let action: () -> Void

    private static let rowTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        return formatter
    }()

    var body: some View {
        let kind = record.resolvedSourceKind
        let hasAudio = TranscriptionDetailAccess.shouldShowPlayback(for: record)
        let isExpired = record.managedMediaPath == nil && kind == .voiceRecording
        let preview: String = {
            if kind == .manualCapture {
                if let title = record.preferredTitle, !title.isEmpty { return title }
            }
            let text = record.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if text.isEmpty {
                return record.preferredTitle ?? localized("Untitled", locale: locale)
            }
            return text
        }()
        let previewMeta: String? = {
            guard kind == .manualCapture else { return nil }
            let meta = record.meetingMetadataString(locale: locale)
            return meta.isEmpty ? nil : meta
        }()
        let showExpiredChip = isExpired || (!hasAudio && record.duration > 0 && kind == .voiceRecording)

        LibraryRowChrome(
            timeText: Self.rowTimeFormatter.string(from: record.timestamp),
            preview: preview,
            previewMeta: previewMeta,
            destination: LibraryKindPresentation.destinationPill(
                appName: record.destinationAppName,
                layoutDirection: layoutDirection
            ),
            icon: {
                Image(systemName: LibraryKindPresentation.systemImage(for: kind))
                    .font(.system(size: 13))
                    .foregroundStyle(AppColors.textTertiary)
            },
            playChip: {
                PlayChip(
                    durationText: formatDuration(record.duration),
                    isExpired: showExpiredChip,
                    action: action
                )
            },
            action: action
        )
        .background {
            if isSelected {
                AppColors.accent.opacity(0.06)
            }
        }
        // Row chrome includes 24 pt horizontal padding; counteract outer 40 so lanes
        // sit flush with the page content edge the way Library rows do.
        .padding(.horizontal, -24)
    }
}

// MARK: - Weekly bars (hover/selection isolated)

/// Owns weekly-bar selection and hover so pointer movement invalidates only this subtree.
private struct DashboardWeeklyBarsChart: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let buckets: [Int]
    /// Trailing meta on the header. It used to be a fourth stat tile; the week
    /// it counts is the week this chart already draws.
    let sessionsThisWeek: Int
    let now: Date
    let locale: Locale
    let calendar: Calendar
    let barAreaHeight: CGFloat

    @State private var selectedWeekdayIndex: Int?
    @State private var hoveredWeekdayIndex: Int?
    @State private var chartHasAppeared = false

    var body: some View {
        let maxWords = buckets.max() ?? 0
        let labels = HomePresentation.weekdayLabels(calendar: calendar, locale: locale)
        let names = HomePresentation.weekdayNames(calendar: calendar, locale: locale)
        let todayIndex = HomePresentation.todayBarIndex(now: now, calendar: calendar)
        let activeIndex = hoveredWeekdayIndex.flatMap { $0 <= todayIndex ? $0 : nil }
            ?? selectedWeekdayIndex.flatMap { $0 <= todayIndex ? $0 : nil }
            ?? todayIndex
        let activeWords = activeIndex < buckets.count ? buckets[activeIndex] : 0
        let activeName = activeIndex < names.count ? names[activeIndex] : ""

        VStack(alignment: .leading, spacing: HomeLayoutMetrics.chartSectionGap) {
            SectionHeader(
                title: localized("This week", locale: locale),
                trailing: HomePresentation.wordMetric(count: activeWords, locale: locale),
                isFirst: true
            ) {
                Text(HomePresentation.sessionMetric(count: sessionsThisWeek, locale: locale))
                    .font(AppTypography.captionMedium)
                    .foregroundStyle(AppColors.textTertiary)
                    .accessibilityIdentifier("capture.dictate.sessionsMeta")
            }

            ZStack(alignment: .bottom) {
                Rectangle()
                    .fill(AppColors.border)
                    .frame(height: 1)
                    .padding(.bottom, 19)

                HStack(alignment: .bottom, spacing: HomeLayoutMetrics.chartBarGap) {
                    ForEach(0..<7, id: \.self) { index in
                        let words = index < buckets.count ? buckets[index] : 0
                        let kind = HomePresentation.barDayKind(index: index, now: now, calendar: calendar)
                        let height: CGFloat = {
                            if kind == .future {
                                return 0
                            }
                            return HomePresentation.barHeight(
                                words: words,
                                maxWords: maxWords,
                                chartHeight: barAreaHeight
                            )
                        }()
                        let isActive = index == activeIndex
                        let barColor: Color = isActive ? AppColors.accent : AppColors.border
                        let labelColor: Color = isActive ? AppColors.accent : AppColors.textTertiary
                        let weekdayLabel = index < labels.count ? labels[index] : ""
                        let weekdayName = index < names.count ? names[index] : weekdayLabel

                        Button {
                            selectedWeekdayIndex = index
                        } label: {
                            VStack(spacing: HomeLayoutMetrics.chartLabelGap) {
                                UnevenRoundedRectangle(
                                    topLeadingRadius: HomeLayoutMetrics.chartBarTopRadius,
                                    bottomLeadingRadius: HomeLayoutMetrics.chartBarBottomRadius,
                                    bottomTrailingRadius: HomeLayoutMetrics.chartBarBottomRadius,
                                    topTrailingRadius: HomeLayoutMetrics.chartBarTopRadius,
                                    style: .continuous
                                )
                                .fill(barColor)
                                .frame(
                                    width: HomeLayoutMetrics.chartBarWidth,
                                    height: chartHasAppeared ? height : 0
                                )
                                .frame(maxHeight: barAreaHeight, alignment: .bottom)
                                .animation(
                                    reduceMotion
                                        ? nil
                                        : .easeOut(duration: 0.42).delay(Double(index) * 0.035),
                                    value: chartHasAppeared
                                )
                                .appAnimation(.normal, value: words)

                                Text(weekdayLabel)
                                    .font(FontLoader.font(
                                        family: .inter,
                                        size: 11,
                                        weight: isActive ? .semibold : .medium
                                    ))
                                    .foregroundStyle(labelColor)
                            }
                            .frame(width: HomeLayoutMetrics.chartBarWidth)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .disabled(kind == .future)
                        .keyboardFocusRing(RoundedRectangle(cornerRadius: 6, style: .continuous))
                        .appAnimation(.fast, value: isActive)
                        .onHover { hovering in
                            guard kind != .future else { return }
                            if hovering {
                                hoveredWeekdayIndex = index
                            } else if hoveredWeekdayIndex == index {
                                hoveredWeekdayIndex = nil
                            }
                        }
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(
                            HomePresentation.barAccessibilityLabel(
                                weekdayName: weekdayName,
                                words: words,
                                locale: locale
                            )
                        )
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Text(activeName.uppercased(with: locale))
                .font(AppTypography.statLabel)
                .foregroundStyle(AppColors.textTertiary)
                .tracking(AppTypography.statLabelTracking)
                .appAnimation(.fast, value: activeIndex)
        }
        .onAppear {
            chartHasAppeared = true
        }
    }
}

// MARK: - Activity heatmap (hover isolated)

/// Owns the 53×7 activity grid structure. Hover invalidation is confined to
/// individual cells for scale/tooltip chrome; only the hovered week column is
/// promoted in the outer HStack so tooltips stack above later weeks.
private struct DashboardActivityHeatmap: View {
    let buckets: [Int]
    let streakDays: Int
    let now: Date
    let locale: Locale
    let calendar: Calendar
    let cellMetrics: HomePresentation.ActivityCellMetrics
    let availableWidth: CGFloat
    var onShowMoreStats: (() -> Void)?

    /// Outer-week stacking only — not per-cell grid state. Invalidates the
    /// heatmap when the pointer crosses week boundaries, not every day cell.
    @State private var elevatedWeekIndex: Int?

    var body: some View {
        let maxWords = buckets.max() ?? 0
        let startDate = HomePresentation.activityStartDate(now: now, calendar: calendar)
        let leadingBlankCount = startDate.map {
            HomePresentation.activityLeadingBlankCount(startDate: $0, calendar: calendar)
        } ?? 0
        let gridStartDate = startDate.flatMap {
            HomePresentation.activityGridStartDate(startDate: $0, calendar: calendar)
        }

        VStack(alignment: .leading, spacing: HomeLayoutMetrics.chartSectionGap) {
            SectionHeader(title: localized("Activity", locale: locale), isFirst: true) {
                Button {
                    onShowMoreStats?()
                } label: {
                    HStack(spacing: 3) {
                        Text(localized("View all", locale: locale))
                        Image(systemName: "arrow.right")
                            .flipsForRightToLeftLayoutDirection(true)
                    }
                    .font(FontLoader.font(family: .inter, size: 11, weight: .semibold))
                    .foregroundStyle(AppColors.accent)
                }
                .buttonStyle(.plain)
                .keyboardFocusRing(RoundedRectangle(cornerRadius: 5, style: .continuous))
                .accessibilityIdentifier("capture.dictate.showMoreStats")
                .help(localized("View all", locale: locale))
            }

            if let startDate, let gridStartDate {
                let cellSize = cellMetrics.cellSize
                let cellGap = cellMetrics.cellGap

                VStack(alignment: .leading, spacing: 7) {
                    HStack(spacing: cellGap) {
                        ForEach(0..<53, id: \.self) { weekIndex in
                            Text(HomePresentation.activityMonthLabel(
                                weekIndex: weekIndex,
                                startDate: gridStartDate,
                                calendar: calendar,
                                locale: locale
                            ))
                            .font(FontLoader.font(family: .inter, size: 9, weight: .medium))
                            .foregroundStyle(AppColors.textTertiary)
                            .fixedSize(horizontal: true, vertical: false)
                            .frame(width: cellSize, alignment: .leading)
                        }
                    }

                    HStack(spacing: cellGap) {
                        ForEach(0..<53, id: \.self) { weekIndex in
                            VStack(spacing: cellGap) {
                                ForEach(0..<7, id: \.self) { dayIndex in
                                    let gridIndex = weekIndex * 7 + dayIndex
                                    let bucketIndex = gridIndex - leadingBlankCount

                                    if buckets.indices.contains(bucketIndex) {
                                        let words = buckets[bucketIndex]
                                        let date = calendar.date(
                                            byAdding: .day,
                                            value: bucketIndex,
                                            to: startDate
                                        ) ?? startDate
                                        let isToday = calendar.isDate(date, inSameDayAs: now)
                                        let intensity = HomePresentation.activityIntensity(
                                            words: words,
                                            maxWords: maxWords
                                        )
                                        let cellX = CGFloat(weekIndex) * (cellSize + cellGap)
                                        // Month-label row (~18 pt) + day offset.
                                        let cellY = 18 + CGFloat(dayIndex) * (cellSize + cellGap)

                                        DashboardActivityHeatmapCell(
                                            date: date,
                                            words: words,
                                            intensity: intensity,
                                            isToday: isToday,
                                            cellSize: cellSize,
                                            dayIndex: dayIndex,
                                            cellX: cellX,
                                            cellY: cellY,
                                            availableWidth: availableWidth,
                                            locale: locale,
                                            calendar: calendar
                                        )
                                    } else {
                                        Color.clear
                                            .frame(width: cellSize, height: cellSize)
                                            .accessibilityHidden(true)
                                    }
                                }
                            }
                            // Elevate the whole week column while the pointer is
                            // inside it so a cell tooltip can paint above later
                            // weeks. Cell-local hover still owns the tooltip.
                            .onHover { hovering in
                                if hovering {
                                    elevatedWeekIndex = weekIndex
                                } else if elevatedWeekIndex == weekIndex {
                                    elevatedWeekIndex = nil
                                }
                            }
                            .zIndex(elevatedWeekIndex == weekIndex ? 1 : 0)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(
                    height: HomeLayoutMetrics.activityGridHeight
                        + HomePresentation.chartRowGrowth(cellMetrics: cellMetrics),
                    alignment: .top
                )

                HStack(spacing: 4) {
                    Text(localized("Streak", locale: locale).uppercased(with: locale))
                    Text(HomePresentation.streakLabel(days: streakDays, locale: locale))
                        .foregroundStyle(AppColors.textSecondary)

                    Spacer(minLength: 8)

                    ForEach(0...4, id: \.self) { intensity in
                        RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                            .fill(DashboardActivityHeatmapCell.activityColor(intensity: intensity))
                            .frame(width: 7, height: 7)
                    }
                }
                .font(FontLoader.font(family: .inter, size: 9, weight: .semibold))
                .foregroundStyle(AppColors.textTertiary)
            }
        }
    }
}

/// One activity cell owns its own hover state so enter/exit invalidates only
/// that cell (plus its local tooltip) rather than the full 371-cell grid.
/// Week-column stacking is promoted by `DashboardActivityHeatmap`.
private struct DashboardActivityHeatmapCell: View {
    let date: Date
    let words: Int
    let intensity: Int
    let isToday: Bool
    let cellSize: CGFloat
    let dayIndex: Int
    let cellX: CGFloat
    let cellY: CGFloat
    let availableWidth: CGFloat
    let locale: Locale
    let calendar: Calendar

    @State private var isHovered = false

    var body: some View {
        let corner = min(3, cellSize / 4)
        // Tooltip positions match the previous grid-level overlay math so
        // edge clamping near left/right and top/bottom stays identical.
        let tooltipX = min(
            max(0, cellX - 76),
            max(0, availableWidth - 160)
        )
        let tooltipY = dayIndex < 4
            ? cellY + cellSize + 6
            : max(0, cellY - 48)

        RoundedRectangle(cornerRadius: corner, style: .continuous)
            .fill(Self.activityColor(intensity: intensity))
            .frame(width: cellSize, height: cellSize)
            .overlay {
                if isToday || isHovered {
                    RoundedRectangle(cornerRadius: corner, style: .continuous)
                        .strokeBorder(
                            isHovered ? AppColors.textPrimary : AppColors.accent,
                            lineWidth: isHovered ? 1.5 : 1
                        )
                }
            }
            .scaleEffect(isHovered ? 1.35 : 1)
            .contentShape(Rectangle())
            .onHover { hovering in
                isHovered = hovering
            }
            .appAnimation(.fast, value: isHovered)
            .accessibilityLabel(HomePresentation.activityAccessibilityLabel(
                date: date,
                words: words,
                calendar: calendar,
                locale: locale
            ))
            // Tooltip is drawn as an unconstrained overlay so it is not clipped
            // by the cell's layout size; only this cell invalidates on hover.
            // Intra-week day stacking uses local zIndex; cross-week stacking is
            // handled by the parent week column.
            .overlay(alignment: .topLeading) {
                if isHovered {
                    activityTooltip
                        .offset(x: tooltipX - cellX, y: tooltipY - cellY)
                        .allowsHitTesting(false)
                }
            }
            .zIndex(isHovered ? 1 : 0)
    }

    private var activityTooltip: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(HomePresentation.activityDateLabel(
                date: date,
                calendar: calendar,
                locale: locale
            ).uppercased(with: locale))
                .font(FontLoader.font(family: .inter, size: 9, weight: .semibold))
                .foregroundStyle(AppColors.textTertiary)
                .lineLimit(1)

            Text(HomePresentation.wordMetric(count: words, locale: locale))
                .font(FontLoader.font(family: .jetbrainsMono, size: 11, weight: .medium))
                .foregroundStyle(AppColors.textPrimary)
                .monospacedDigit()
                .lineLimit(1)
        }
        .frame(width: 136, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(AppColors.elevatedSurface, in: .rect(cornerRadius: 7))
        .overlay {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .strokeBorder(AppColors.border, lineWidth: 1)
        }
        .shadow(color: AppColors.shadowColor.opacity(0.18), radius: 8, y: 4)
    }

    static func activityColor(intensity: Int) -> Color {
        switch intensity {
        case 1: AppColors.accent.opacity(0.24)
        case 2: AppColors.accent.opacity(0.44)
        case 3: AppColors.accent.opacity(0.68)
        case 4: AppColors.accent
        default: AppColors.border.opacity(0.55)
        }
    }
}

// MARK: - Empty state

/// Before the first dictation: name the situation, then the next action. The
/// hotkey is read here so the rest of the page stays off `SettingsStore`.
private struct DictateEmptyHero: View {
    @ObservedObject var settingsStore: SettingsStore
    @Environment(\.locale) private var locale

    var body: some View {
        let state = HomePresentation.emptyState(
            hotkey: settingsStore.toggleHotkey,
            locale: locale
        )
        return VStack(alignment: .leading, spacing: 10) {
            Text(state.title)
                .font(AppTypography.heroDisplay)
                .foregroundStyle(AppColors.textPrimary)
                .tracking(AppTypography.heroDisplayTracking)
                .lineSpacing(AppTypography.heroDisplayLineSpacing)

            Text(state.guidance)
                .font(AppTypography.bodyMeta)
                .foregroundStyle(AppColors.textSecondary)
                .lineSpacing(AppTypography.bodyMetaLineSpacing)
        }
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("capture.dictate.emptyState")
    }
}

// MARK: - Dashboard stats cache

/// Recomputes dashboard aggregates only when the record projection or calendar day changes.
/// Class init stays nonisolated for `@State` default construction under Swift 5.9;
/// mutation is method-isolated (`@MainActor` accessors only).
private final class DashboardStatsCache {
    struct Key: Equatable {
        let samples: [StatsSample]
        let dayStart: Date
        let firstWeekday: Int
        let timeZoneIdentifier: String
    }

    private var key: Key?
    private var value: DashboardStats = .empty

    @MainActor
    func stats(for key: Key, calendar: Calendar, now: Date) -> DashboardStats {
        if self.key == key {
            return value
        }
        self.key = key
        value = DashboardStatsService.compute(
            samples: key.samples,
            calendar: calendar,
            now: now
        )
        return value
    }
}

// MARK: - Day-boundary timeline

/// Fires once per calendar midnight (local), not on a fixed wall-clock interval.
/// Cheap: no per-minute / per-second ticks while the Home window is open.
private struct HomeDayBoundarySchedule: TimelineSchedule {
    let calendar: Calendar

    func entries(from startDate: Date, mode: TimelineScheduleMode) -> Entries {
        Entries(calendar: calendar, startDate: startDate)
    }

    struct Entries: Sequence, IteratorProtocol {
        let calendar: Calendar
        private var upcoming: Date

        init(calendar: Calendar, startDate: Date) {
            self.calendar = calendar
            self.upcoming = HomePresentation.nextMidnight(after: startDate, calendar: calendar)
        }

        mutating func next() -> Date? {
            let value = upcoming
            // Advance by one calendar day from this midnight so DST stays correct.
            upcoming = HomePresentation.nextMidnight(after: value, calendar: calendar)
            return value
        }
    }
}

#Preview("Dictate - With Data") {
    DictateView(settingsStore: SettingsStore())
        .modelContainer(PreviewContainer.withSampleData)
        .frame(width: 800, height: 700)
        .preferredColorScheme(.light)
}

#Preview("Dictate - Empty") {
    DictateView(settingsStore: SettingsStore())
        .modelContainer(PreviewContainer.empty)
        .frame(width: 800, height: 700)
        .preferredColorScheme(.light)
}

#Preview("Dictate - Dark") {
    DictateView(settingsStore: SettingsStore())
        .modelContainer(PreviewContainer.withSampleData)
        .frame(width: 800, height: 700)
        .preferredColorScheme(.dark)
}

#Preview("Dictate - Recording") {
    let dictationState = FloatingIndicatorState()
    dictationState.isRecording = true
    dictationState.recordingDuration = 125

    return DictateView(
        settingsStore: SettingsStore(),
        dictationState: dictationState
    )
    .modelContainer(PreviewContainer.withSampleData)
    .frame(width: 800, height: 700)
    .preferredColorScheme(.light)
}
