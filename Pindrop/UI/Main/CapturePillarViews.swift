//
//  CapturePillarViews.swift
//  Pindrop
//
//  The three focused capture destinations. Dictate keeps the retrospective
//  dashboard below its persistent start surface.
//

import SwiftUI
import SwiftData
import PindropCore
import PindropData

struct DictateView: View {
    @Environment(\.layoutDirection) private var layoutDirection
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
    let isCaptureBusy: Bool
    let onStartDictation: (() -> Void)?
    let onOpenLibrary: (() -> Void)?
    let onShowMoreStats: (() -> Void)?
    let onOpenLibraryRecord: ((UUID) -> Void)?
    let onOpenShortcuts: (() -> Void)?
    let onDownloadDiarizationModel: (() -> Void)?

    init(
        settingsStore: SettingsStore,
        recordingState: RecordingFeatureState? = nil,
        isCaptureBusy: Bool = false,
        onStartDictation: (() -> Void)? = nil,
        onOpenLibrary: (() -> Void)? = nil,
        onShowMoreStats: (() -> Void)? = nil,
        onOpenLibraryRecord: ((UUID) -> Void)? = nil,
        onOpenShortcuts: (() -> Void)? = nil,
        onDownloadDiarizationModel: (() -> Void)? = nil
    ) {
        self.settingsStore = settingsStore
        self.recordingState = recordingState
        self.isCaptureBusy = isCaptureBusy
        self.onStartDictation = onStartDictation
        self.onOpenLibrary = onOpenLibrary
        self.onShowMoreStats = onShowMoreStats
        self.onOpenLibraryRecord = onOpenLibraryRecord
        self.onOpenShortcuts = onOpenShortcuts
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
                    diarizationSetupIssueBanner(
                        message: setupIssue,
                        isDownloading: recordingState?.isDiarizationModelDownloading ?? false,
                        progress: recordingState?.diarizationModelDownloadProgress ?? 0.0
                    )
                    .padding(.bottom, 16)
                }

                CapturePillarSurface(
                    title: localized("Dictate", locale: locale),
                    description: localized("Speak, then Pindrop writes in the app you are using.", locale: locale),
                    symbol: "waveform",
                    startTitle: localized("Start dictating", locale: locale),
                    startIdentifier: "main.capture.dictate.start",
                    currentShortcut: settingsStore.toggleHotkey,
                    isBusy: isCaptureBusy,
                    isStartAvailable: onStartDictation != nil,
                    onStart: { onStartDictation?() }
                )
                .padding(.bottom, 20)
                CaptureSupportLinks(
                    prefix: "capture.dictate",
                    onOpenShortcuts: onOpenShortcuts
                )

                if isFirstRun {
                    firstRunLibraryState
                        .padding(.top, 32)
                } else {
                    heroBlock(now: now, stats: dashboardStats)
                    statsStrip(stats: dashboardStats)
                    recentSection
                    chartRowWidthProbe
                    thisWeekChart(now: now, stats: dashboardStats)
                }
            }
            .padding(.horizontal, 40)
            .padding(.top, 40)
            .padding(.bottom, 40)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(
                minHeight: isFirstRun ? 560 : 0,
                alignment: isFirstRun ? .center : .topLeading
            )
        }
        .background(AppColors.contentBackground)
        .accessibilityIdentifier("main.destination.dictate")
    }

    private var firstRunLibraryState: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(localized("Library", locale: locale))
                .font(AppTypography.sectionHeader)
                .foregroundStyle(AppColors.textTertiary)
                .tracking(0.88)

            Text(localized("Your latest dictations will show up here.", locale: locale))
                .font(AppTypography.body)
                .foregroundStyle(AppColors.textSecondary)

            if let onOpenLibrary {
                SecondaryButton(
                    title: localized("Open Library", locale: locale),
                    systemImage: "books.vertical",
                    action: onOpenLibrary
                )
                .keyboardFocusRing(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .accessibilityIdentifier("capture.dictate.openLibrary")
            }
        }
    }

    private func diarizationSetupIssueBanner(
        message: String,
        isDownloading: Bool,
        progress: Double
    ) -> some View {
        HStack(spacing: 12) {
            Image(systemName: isDownloading ? "arrow.down.circle" : "exclamationmark.triangle")
                .font(.system(size: 14))
                .foregroundStyle(isDownloading ? AppColors.accent : AppColors.warning)

            if isDownloading {
                VStack(alignment: .leading, spacing: 4) {
                    Text(message)
                        .font(AppTypography.caption)
                        .foregroundStyle(AppColors.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)

                    ProgressView(value: min(max(progress, 0), 1))
                        .progressViewStyle(.linear)
                        .tint(AppColors.accent)
                        .frame(maxWidth: 180)
                        .accessibilityValue("\(Int(progress * 100))%")
                }
            } else {
                Text(message)
                    .font(AppTypography.caption)
                    .foregroundStyle(AppColors.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 8)

            if !isDownloading, onDownloadDiarizationModel != nil {
                Button(localized("Download model", locale: locale)) {
                    onDownloadDiarizationModel?()
                }
                .buttonStyle(.plain)
                .font(AppTypography.caption.weight(.semibold))
                .foregroundStyle(AppColors.accent)
                .accessibilityIdentifier("diarizationSetupIssueDownloadButton")
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(AppColors.warningBackground)
        )
    }

    // MARK: - Hero

    private func heroBlock(now: Date, stats: DashboardStats) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(HomePresentation.dateKicker(date: now, locale: locale, calendar: calendar))
                .font(FontLoader.font(family: .inter, size: HomeLayoutMetrics.kickerSize, weight: .semibold))
                .foregroundStyle(AppColors.textTertiary)
                .tracking(HomeLayoutMetrics.kickerTrackingEm * HomeLayoutMetrics.kickerSize)

            if isFirstRun {
                DashboardFirstRunWelcome(settingsStore: settingsStore)
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
        let heroFont = FontLoader.font(
            family: .newsreader,
            size: HomeLayoutMetrics.heroFontSize,
            weight: .regular
        )
        let metricFont = FontLoader.font(
            family: .newsreader,
            size: HomeLayoutMetrics.heroFontSize,
            weight: .medium,
            italic: true
        )
        let tracking = HomeLayoutMetrics.heroTrackingEm * HomeLayoutMetrics.heroFontSize
        let lineSpacing = HomeLayoutMetrics.heroLineHeight - HomeLayoutMetrics.heroFontSize

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

    // MARK: - Stats strip

    private func statsStrip(stats: DashboardStats) -> some View {
        HStack(spacing: 0) {
            homeStat(
                value: HomePresentation.formatGrouped(stats.wordsToday, locale: locale),
                label: localized("Words today", locale: locale)
            )

            statsDivider

            homeStat(
                value: HomePresentation.formatWPM(stats.wpmThisWeek, locale: locale),
                label: localized("Words / min", locale: locale)
            )

            statsDivider

            homeStat(
                value: HomePresentation.formatGrouped(stats.sessionsThisWeek, locale: locale),
                label: localized("Sessions", locale: locale)
            )

            statsDivider

            homeStat(
                value: HomePresentation.streakLabel(days: stats.streakDays, locale: locale),
                label: localized("Streak", locale: locale)
            )

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
                .font(FontLoader.font(
                    family: .jetbrainsMono,
                    size: HomeLayoutMetrics.statsNumberSize,
                    weight: .medium
                ))
                .foregroundStyle(AppColors.textPrimary)
                .monospacedDigit()

            Text(label.uppercased(with: locale))
                .font(FontLoader.font(
                    family: .inter,
                    size: HomeLayoutMetrics.statsLabelSize,
                    weight: .semibold
                ))
                .foregroundStyle(AppColors.textTertiary)
                .tracking(HomeLayoutMetrics.statsLabelTrackingEm * HomeLayoutMetrics.statsLabelSize)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(value), \(label)")
    }

    // MARK: - Recent

    private var recentSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionHeader(title: localized("Recent", locale: locale), isFirst: true) {
                if let onOpenLibrary {
                    Button {
                        onOpenLibrary()
                    } label: {
                        HStack(spacing: 3) {
                            Text(localized("Open Library", locale: locale))
                            Image(systemName: "arrow.right")
                                .flipsForRightToLeftLayoutDirection(true)
                        }
                        .font(FontLoader.font(family: .inter, size: 11, weight: .semibold))
                        .foregroundStyle(AppColors.accent)
                    }
                    .buttonStyle(.plain)
                    .keyboardFocusRing(RoundedRectangle(cornerRadius: 5, style: .continuous))
                    .accessibilityIdentifier("capture.dictate.openLibrary")
                }
            }

            if recentRecords.isEmpty {
                emptyRecentHint
                    .padding(.top, 16)
            } else {
                VStack(spacing: 0) {
                    ForEach(recentRecords) { record in
                        homeRecentRow(record)
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

    private static let rowTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        return formatter
    }()

    private func homeRecentRow(_ record: TranscriptionRecord) -> some View {
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

        return LibraryRowChrome(
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
                    action: { onOpenLibraryRecord?(record.id) }
                )
            },
            action: {
                onOpenLibraryRecord?(record.id)
            }
        )
        // Row chrome includes 24 pt horizontal padding; counteract outer 40 so lanes
        // sit flush with the page content edge the way Library rows do.
        .padding(.horizontal, -24)
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

// MARK: - Capture pillars

struct VoiceNoteView: View {
    @Environment(\.locale) private var locale
    @ObservedObject private var settingsStore: SettingsStore
    let isCaptureBusy: Bool
    let onStartVoiceNote: (() -> Void)?
    let onOpenNotes: (() -> Void)?
    let onOpenShortcuts: (() -> Void)?

    init(
        settingsStore: SettingsStore,
        isCaptureBusy: Bool = false,
        onStartVoiceNote: (() -> Void)? = nil,
        onOpenNotes: (() -> Void)? = nil,
        onOpenShortcuts: (() -> Void)? = nil
    ) {
        _settingsStore = ObservedObject(wrappedValue: settingsStore)
        self.isCaptureBusy = isCaptureBusy
        self.onStartVoiceNote = onStartVoiceNote
        self.onOpenNotes = onOpenNotes
        self.onOpenShortcuts = onOpenShortcuts
    }

    var body: some View {
        CapturePillarPage {
            CapturePillarSurface(
                title: localized("Voice Note", locale: locale),
                description: localized("Capture a thought and keep it in Notes.", locale: locale),
                symbol: "note.text.badge.plus",
                startTitle: localized("Start voice note", locale: locale),
                startIdentifier: "main.capture.voiceNote.start",
                currentShortcut: nil,
                isBusy: isCaptureBusy,
                isStartAvailable: onStartVoiceNote != nil,
                onStart: { onStartVoiceNote?() }
            )
            VoiceNoteShortcutSummary(
                holdShortcut: settingsStore.quickCapturePTTHotkey,
                toggleShortcut: settingsStore.quickCaptureToggleHotkey,
                onOpenShortcuts: onOpenShortcuts
            )
            .padding(.top, 32)
            CaptureSupportLinks(prefix: "capture.voiceNote", onOpenNotes: onOpenNotes)
                .padding(.top, 32)
        }
        .accessibilityIdentifier("main.destination.voiceNote")
    }
}

struct MeetingView: View {
    @Environment(\.locale) private var locale
    @State private var showMeetingCaptureOptions = false
    let isCaptureBusy: Bool
    let onStartMeeting: ((Int?) -> Bool)?
    let onOpenLibrary: (() -> Void)?
    let onOpenShortcuts: (() -> Void)?

    init(
        isCaptureBusy: Bool = false,
        onStartMeeting: ((Int?) -> Bool)? = nil,
        onOpenLibrary: (() -> Void)? = nil,
        onOpenShortcuts: (() -> Void)? = nil
    ) {
        self.isCaptureBusy = isCaptureBusy
        self.onStartMeeting = onStartMeeting
        self.onOpenLibrary = onOpenLibrary
        self.onOpenShortcuts = onOpenShortcuts
    }

    var body: some View {
        CapturePillarPage {
            CapturePillarSurface(
                title: localized("Meeting", locale: locale),
                description: localized("Record microphone and system audio, then keep the meeting in Library.", locale: locale),
                symbol: "person.2.wave.2",
                startTitle: localized("Record Meeting…", locale: locale),
                startIdentifier: "main.capture.meeting.start",
                currentShortcut: nil,
                isBusy: isCaptureBusy,
                isStartAvailable: onStartMeeting != nil,
                onStart: { showMeetingCaptureOptions = true }
            )
            MeetingCaptureSummary()
                .padding(.top, 32)
            CaptureSupportLinks(prefix: "capture.meeting", onOpenShortcuts: onOpenShortcuts)
                .padding(.top, 20)
            Text(localized("Library", locale: locale))
                .font(AppTypography.sectionHeader)
                .foregroundStyle(AppColors.textTertiary)
                .tracking(0.88)
                .padding(.top, 40)
            CaptureSupportLinks(prefix: "capture.meeting", onOpenLibrary: onOpenLibrary)
                .padding(.top, 10)
        }
        .sheet(isPresented: $showMeetingCaptureOptions) {
            MeetingCaptureOptionsSheet(isStartAvailable: !isCaptureBusy) { expectedSpeakerCount in
                guard !isCaptureBusy, let onStartMeeting else { return false }
                return onStartMeeting(expectedSpeakerCount)
            }
        }
        .accessibilityIdentifier("main.destination.meeting")
    }
}

private struct CapturePillarPage<Content: View>: View {
    private let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                content
            }
            .frame(maxWidth: 640, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 40)
            .padding(.vertical, 40)
            .frame(minHeight: 560, alignment: .center)
        }
        .background(AppColors.contentBackground)
    }
}

/// The one state-bearing instrument surface on each capture destination.
private struct CapturePillarSurface: View {
    @Environment(\.locale) private var locale
    let title: String
    let description: String
    let symbol: String
    let startTitle: String
    let startIdentifier: String
    let currentShortcut: String?
    let isBusy: Bool
    let isStartAvailable: Bool
    let onStart: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Image(systemName: symbol)
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(AppColors.accent)
                    .accessibilityHidden(true)
                Text(title)
                    .font(FontLoader.font(family: .newsreader, size: 34, weight: .regular))
                    .foregroundStyle(AppColors.textPrimary)
            }
            Text(description)
                .font(AppTypography.body)
                .foregroundStyle(AppColors.textSecondary)
                .lineSpacing(AppTypography.bodyLineSpacing)
                .fixedSize(horizontal: false, vertical: true)
            HStack(alignment: .center, spacing: 12) {
                PrimaryButton(
                    title: startTitle,
                    systemImage: "record.circle",
                    isEnabled: isStartAvailable && !isBusy,
                    action: onStart
                )
                .keyboardFocusRing(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .accessibilityIdentifier(startIdentifier)
                .accessibilityHint(isBusy ? localized("Finish the current capture before starting another.", locale: locale) : "")

                if let currentShortcut, !currentShortcut.isEmpty {
                    Text(currentShortcut)
                        .font(AppTypography.monoSmall)
                        .foregroundStyle(AppColors.textTertiary)
                        .monospacedDigit()
                        .environment(\.layoutDirection, .leftToRight)
                }
            }

            if isBusy {
                VStack(alignment: .leading, spacing: 2) {
                    Label(localized("Capture in progress", locale: locale), systemImage: "record.circle.fill")
                    Text(localized("Finish the current capture before starting another.", locale: locale))
                }
                .font(AppTypography.caption)
                .foregroundStyle(AppColors.warning)
                .accessibilityElement(children: .combine)
            }
        }
        .padding(.vertical, 28)
        .accessibilityElement(children: .contain)
    }
}

private struct CaptureSupportLinks: View {
    @Environment(\.locale) private var locale
    let prefix: String
    var onOpenLibrary: (() -> Void)?
    var onOpenNotes: (() -> Void)?
    var onOpenShortcuts: (() -> Void)?

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) { links }
            VStack(alignment: .leading, spacing: 8) { links }
        }
    }

    @ViewBuilder private var links: some View {
        if let onOpenLibrary {
            link(localized("Open Library", locale: locale), "books.vertical", "\(prefix).openLibrary", onOpenLibrary)
        }
        if let onOpenNotes {
            link(localized("Open Notes", locale: locale), "note.text", "\(prefix).openNotes", onOpenNotes)
        }
        if let onOpenShortcuts {
            link(localized("Change shortcut", locale: locale), "keyboard", "\(prefix).openShortcuts", onOpenShortcuts)
        }
    }

    private func link(_ title: String, _ systemImage: String, _ identifier: String, _ action: @escaping () -> Void) -> some View {
        SecondaryButton(title: title, systemImage: systemImage, action: action)
            .keyboardFocusRing(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .accessibilityIdentifier(identifier)
    }
}

private struct VoiceNoteShortcutSummary: View {
    @Environment(\.locale) private var locale

    let holdShortcut: String
    let toggleShortcut: String
    let onOpenShortcuts: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(localized("Shortcuts", locale: locale))
                .font(AppTypography.sectionHeader)
                .foregroundStyle(AppColors.textTertiary)
                .tracking(0.88)

            shortcutRow(
                title: localized("Voice Note — Hold", locale: locale),
                value: displayValue(holdShortcut)
            )
            shortcutRow(
                title: localized("Voice Note — Toggle", locale: locale),
                value: displayValue(toggleShortcut)
            )

            CaptureSupportLinks(
                prefix: "capture.voiceNote",
                onOpenShortcuts: onOpenShortcuts
            )
            .padding(.top, 2)
        }
        .frame(maxWidth: 360, alignment: .leading)
    }

    private func shortcutRow(title: String, value: String) -> some View {
        HStack(spacing: 12) {
            Text(title)
                .font(AppTypography.body)
                .foregroundStyle(AppColors.textSecondary)
            Spacer(minLength: 16)
            Text(value)
                .font(AppTypography.monoSmall)
                .foregroundStyle(AppColors.textPrimary)
                .monospacedDigit()
                .environment(\.layoutDirection, .leftToRight)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title), \(value)")
    }

    private func displayValue(_ shortcut: String) -> String {
        shortcut.isEmpty ? localized("Not set", locale: locale) : shortcut
    }
}

private struct MeetingCaptureSummary: View {
    @Environment(\.locale) private var locale

    var body: some View {
        HStack(spacing: 24) {
            Text(localized("Expected speakers", locale: locale))
                .font(AppTypography.body)
                .foregroundStyle(AppColors.textSecondary)
                .frame(width: 160, alignment: .leading)
            Text(localized("Automatic", locale: locale))
                .font(AppTypography.monoSmall)
                .foregroundStyle(AppColors.textPrimary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "\(localized("Expected speakers", locale: locale)), \(localized("Automatic", locale: locale))"
        )
        .frame(maxWidth: 360, alignment: .leading)
    }
}

// MARK: - Meeting capture options

/// Start invokes the callback with `nil` (Automatic) or `1...20`. The sheet
/// dismisses only after the coordinator accepts the capture start.
struct MeetingCaptureOptionsSheet: View {
    @Environment(\.locale) private var locale
    @Environment(\.dismiss) private var dismiss
    let isStartAvailable: Bool
    let onStart: (Int?) -> Bool
    @State private var selectedOption: Int = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(localized("Record Meeting…", locale: locale))
                .font(AppTypography.headline)
                .foregroundStyle(AppColors.textPrimary)
            VStack(alignment: .leading, spacing: 8) {
                Text(localized("Expected speakers", locale: locale))
                    .font(AppTypography.body)
                    .foregroundStyle(AppColors.textSecondary)
                Picker(localized("Expected speakers", locale: locale), selection: $selectedOption) {
                    Text(localized("Automatic", locale: locale)).tag(0)
                    ForEach(1...20, id: \.self) { Text("\($0)").tag($0) }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .accessibilityIdentifier("meetingExpectedSpeakerPicker")
            }
            HStack {
                Spacer()
                Button(localized("Cancel", locale: locale)) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("meetingCaptureCancelButton")
                Button(localized("Start Recording", locale: locale)) {
                    if onStart(selectedOption == 0 ? nil : selectedOption) {
                        dismiss()
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!isStartAvailable)
                .accessibilityIdentifier("meetingCaptureStartButton")
            }
        }
        .padding(24)
        .frame(minWidth: 360)
        .accessibilityIdentifier("meetingCaptureOptionsSheet")
    }
}

// MARK: - Weekly bars (hover/selection isolated)

/// Owns weekly-bar selection and hover so pointer movement invalidates only this subtree.
private struct DashboardWeeklyBarsChart: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let buckets: [Int]
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
            )

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
                .font(FontLoader.font(
                    family: .inter,
                    size: HomeLayoutMetrics.statsLabelSize,
                    weight: .semibold
                ))
                .foregroundStyle(AppColors.textTertiary)
                .tracking(HomeLayoutMetrics.statsLabelTrackingEm * HomeLayoutMetrics.statsLabelSize)
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

// MARK: - First-run welcome (settings observation isolated)

/// Only this child observes SettingsStore so unrelated settings changes do not
/// invalidate the rest of the Dashboard.
private struct DashboardFirstRunWelcome: View {
    @ObservedObject var settingsStore: SettingsStore
    @Environment(\.locale) private var locale

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(localized("Speak. It's written.", locale: locale))
                .font(FontLoader.font(family: .newsreader, size: HomeLayoutMetrics.heroFontSize, weight: .regular))
                .foregroundStyle(AppColors.textPrimary)
                .tracking(HomeLayoutMetrics.heroTrackingEm * HomeLayoutMetrics.heroFontSize)
                .lineSpacing(HomeLayoutMetrics.heroLineHeight - HomeLayoutMetrics.heroFontSize)

            let hotkey = settingsStore.toggleHotkey.isEmpty
                ? localized("⌥Space", locale: locale)
                : settingsStore.toggleHotkey
            Text(String(format: localized("Press %@ anywhere to start dictating.", locale: locale), hotkey))
                .font(AppTypography.bodyMeta)
                .foregroundStyle(AppColors.textSecondary)
        }
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
