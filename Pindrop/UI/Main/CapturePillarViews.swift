//
//  CapturePillarViews.swift
//  Pindrop
//
//  The three focused capture destinations. Dictate keeps the retrospective
//  dashboard (hero, stats, recent, charts) with a start action under the hero;
//  Voice Note and Meeting pair an editorial header with their own recent items.
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
    let isCaptureBusy: Bool
    let onStartDictation: (() -> Void)?
    let onOpenLibrary: (() -> Void)?
    let onShowMoreStats: (() -> Void)?
    let onOpenLibraryRecord: ((UUID) -> Void)?
    let onDownloadDiarizationModel: (() -> Void)?

    init(
        settingsStore: SettingsStore,
        recordingState: RecordingFeatureState? = nil,
        isCaptureBusy: Bool = false,
        onStartDictation: (() -> Void)? = nil,
        onOpenLibrary: (() -> Void)? = nil,
        onShowMoreStats: (() -> Void)? = nil,
        onOpenLibraryRecord: ((UUID) -> Void)? = nil,
        onDownloadDiarizationModel: (() -> Void)? = nil
    ) {
        self.settingsStore = settingsStore
        self.recordingState = recordingState
        self.isCaptureBusy = isCaptureBusy
        self.onStartDictation = onStartDictation
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

                HStack(alignment: .top, spacing: 16) {
                    heroBlock(now: now, stats: dashboardStats)
                    Spacer(minLength: 0)
                    dictateStartRow
                }
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
        .accessibilityIdentifier("main.destination.dictate")
    }

    /// The one action the old dashboard lacked: start a dictation from the page.
    /// Sits top-right of the hero. Shortcut display observes SettingsStore inside
    /// the row so the rest of the page stays isolated from settings publications.
    private var dictateStartRow: some View {
        DictateStartRow(
            settingsStore: settingsStore,
            isBusy: isCaptureBusy,
            isStartAvailable: onStartDictation != nil,
            onStart: { onStartDictation?() }
        )
        .padding(.top, 24)
    }

    // MARK: - Hero

    private func heroBlock(now: Date, stats: DashboardStats) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(HomePresentation.dateKicker(date: now, locale: locale, calendar: calendar))
                .font(FontLoader.font(family: .inter, size: HomeLayoutMetrics.kickerSize, weight: .semibold))
                .foregroundStyle(AppColors.textTertiary)
                .tracking(HomeLayoutMetrics.kickerTrackingEm * HomeLayoutMetrics.kickerSize)

            if isFirstRun {
                DashboardFirstRunWelcome()
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
                        CaptureRecentRow(record: record) {
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

// MARK: - Voice Note

struct VoiceNoteView: View {
    @Environment(\.locale) private var locale
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \NoteSchema.Note.createdAt, order: .reverse) private var allNotes: [NoteSchema.Note]
    @ObservedObject private var settingsStore: SettingsStore
    let isCaptureBusy: Bool
    let onStartVoiceNote: (() -> Void)?
    let onOpenNotes: (() -> Void)?

    init(
        settingsStore: SettingsStore,
        isCaptureBusy: Bool = false,
        onStartVoiceNote: (() -> Void)? = nil,
        onOpenNotes: (() -> Void)? = nil
    ) {
        _settingsStore = ObservedObject(wrappedValue: settingsStore)
        self.isCaptureBusy = isCaptureBusy
        self.onStartVoiceNote = onStartVoiceNote
        self.onOpenNotes = onOpenNotes
    }

    private var calendar: Calendar { Calendar.current }

    /// Voice notes are the notes backed by a captured transcript.
    private var voiceNotes: [NoteSchema.Note] {
        allNotes.filter { $0.sourceTranscriptionID != nil }
    }

    private var recentVoiceNotes: [NoteSchema.Note] {
        Array(voiceNotes.prefix(5))
    }

    var body: some View {
        TimelineView(HomeDayBoundarySchedule(calendar: calendar)) { _ in
            content(now: Date())
        }
    }

    private func content(now: Date) -> some View {
        ScrollView(showsIndicators: true) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .top, spacing: 16) {
                    CaptureEditorialHeader(
                        kicker: HomePresentation.dateKicker(date: now, locale: locale, calendar: calendar),
                        heroParts: HomePresentation.voiceNoteHeroParts(
                            notesThisWeek: voiceNotesThisWeek(now: now),
                            locale: locale
                        ),
                        subline: shortcutSubline
                    )
                    Spacer(minLength: 0)
                    CaptureStartRow(
                        startTitle: localized("Start voice note", locale: locale),
                        startIdentifier: "main.capture.voiceNote.start",
                        shortcut: nil,
                        isBusy: isCaptureBusy,
                        isStartAvailable: onStartVoiceNote != nil,
                        onStart: { onStartVoiceNote?() }
                    )
                    .padding(.top, 24)
                }

                recentSection
            }
            .padding(.horizontal, 40)
            .padding(.top, 40)
            .padding(.bottom, 40)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(AppColors.contentBackground)
        .accessibilityIdentifier("main.destination.voiceNote")
    }

    private func voiceNotesThisWeek(now: Date) -> Int {
        guard let weekStart = calendar.dateInterval(of: .weekOfYear, for: now)?.start else {
            return 0
        }
        return voiceNotes.reduce(0) { $0 + ($1.createdAt >= weekStart ? 1 : 0) }
    }

    /// The page-specific hint: voice notes are meant to be captured from anywhere.
    /// Only mentions the shortcuts that are actually configured.
    private var shortcutSubline: String {
        let hold = settingsStore.quickCapturePTTHotkey
        let toggle = settingsStore.quickCaptureToggleHotkey
        switch (hold.isEmpty, toggle.isEmpty) {
        case (false, false):
            return String(
                format: localized("Hold %1$@ or press %2$@ anywhere.", locale: locale),
                hold, toggle
            )
        case (false, true):
            return String(format: localized("Hold %@ anywhere.", locale: locale), hold)
        case (true, false):
            return String(format: localized("Press %@ anywhere.", locale: locale), toggle)
        case (true, true):
            return ""
        }
    }

    // MARK: - Recent voice notes

    private var recentSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionHeader(title: localized("Recent", locale: locale), isFirst: true) {
                if let onOpenNotes {
                    CaptureRecentLink(
                        title: localized("Open Notes", locale: locale),
                        identifier: "capture.voiceNote.openNotes",
                        action: onOpenNotes
                    )
                }
            }
            .padding(.top, 40)

            if recentVoiceNotes.isEmpty {
                Text(localized("Your voice notes will show up here.", locale: locale))
                    .font(AppTypography.body)
                    .foregroundStyle(AppColors.textTertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 12)
            } else {
                VStack(spacing: 0) {
                    ForEach(recentVoiceNotes) { note in
                        VoiceNoteRow(note: note) {
                            openInEditor(note)
                        }
                    }
                }
                .padding(.top, 4)
            }
        }
    }

    private func openInEditor(_ note: NoteSchema.Note) {
        NoteEditorWindowControllerRegistry.shared.presentEditor(
            note: note,
            isNewNote: false,
            modelContainer: modelContext.container
        )
    }
}

// MARK: - Meeting

struct MeetingView: View {
    @Environment(\.locale) private var locale
    @Query(sort: \TranscriptionRecord.timestamp, order: .reverse) private var transcriptions: [TranscriptionRecord]
    @State private var showMeetingCaptureOptions = false
    let recordingState: RecordingFeatureState?
    let isCaptureBusy: Bool
    let onStartMeeting: ((Int?) -> Bool)?
    let onOpenLibrary: (() -> Void)?
    let onOpenLibraryRecord: ((UUID) -> Void)?
    let onDownloadDiarizationModel: (() -> Void)?

    init(
        recordingState: RecordingFeatureState? = nil,
        isCaptureBusy: Bool = false,
        onStartMeeting: ((Int?) -> Bool)? = nil,
        onOpenLibrary: (() -> Void)? = nil,
        onOpenLibraryRecord: ((UUID) -> Void)? = nil,
        onDownloadDiarizationModel: (() -> Void)? = nil
    ) {
        self.recordingState = recordingState
        self.isCaptureBusy = isCaptureBusy
        self.onStartMeeting = onStartMeeting
        self.onOpenLibrary = onOpenLibrary
        self.onOpenLibraryRecord = onOpenLibraryRecord
        self.onDownloadDiarizationModel = onDownloadDiarizationModel
    }

    private var calendar: Calendar { Calendar.current }

    private var meetings: [TranscriptionRecord] {
        transcriptions.filter { $0.resolvedSourceKind == .manualCapture }
    }

    private var recentMeetings: [TranscriptionRecord] {
        Array(meetings.prefix(5))
    }

    var body: some View {
        TimelineView(HomeDayBoundarySchedule(calendar: calendar)) { _ in
            content(now: Date())
        }
    }

    private func content(now: Date) -> some View {
        let weekStats = meetingWeekStats(now: now)
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

                HStack(alignment: .top, spacing: 16) {
                    CaptureEditorialHeader(
                        kicker: HomePresentation.dateKicker(date: now, locale: locale, calendar: calendar),
                        heroParts: HomePresentation.meetingHeroParts(
                            meetingsThisWeek: weekStats.count,
                            locale: locale
                        ),
                        subline: HomePresentation.meetingSubLine(
                            meetingDuration: weekStats.duration,
                            locale: locale
                        )
                    )
                    Spacer(minLength: 0)
                    CaptureStartRow(
                        startTitle: localized("Record Meeting…", locale: locale),
                        startIdentifier: "main.capture.meeting.start",
                        shortcut: nil,
                        isBusy: isCaptureBusy,
                        isStartAvailable: onStartMeeting != nil,
                        onStart: { showMeetingCaptureOptions = true }
                    )
                    .padding(.top, 24)
                }

                recentSection
            }
            .padding(.horizontal, 40)
            .padding(.top, 40)
            .padding(.bottom, 40)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(AppColors.contentBackground)
        .sheet(isPresented: $showMeetingCaptureOptions) {
            MeetingCaptureOptionsSheet(isStartAvailable: !isCaptureBusy) { expectedSpeakerCount in
                guard !isCaptureBusy, let onStartMeeting else { return false }
                return onStartMeeting(expectedSpeakerCount)
            }
        }
        .accessibilityIdentifier("main.destination.meeting")
    }

    private func meetingWeekStats(now: Date) -> (count: Int, duration: TimeInterval) {
        guard let weekStart = calendar.dateInterval(of: .weekOfYear, for: now)?.start else {
            return (0, 0)
        }
        var count = 0
        var duration: TimeInterval = 0
        for meeting in meetings where meeting.timestamp >= weekStart {
            count += 1
            duration += meeting.duration
        }
        return (count, duration)
    }

    // MARK: - Recent meetings

    private var recentSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionHeader(title: localized("Recent", locale: locale), isFirst: true) {
                if let onOpenLibrary {
                    CaptureRecentLink(
                        title: localized("Open Library", locale: locale),
                        identifier: "capture.meeting.openLibrary",
                        action: onOpenLibrary
                    )
                }
            }
            .padding(.top, 40)

            if recentMeetings.isEmpty {
                Text(localized("Your recorded meetings will show up here.", locale: locale))
                    .font(AppTypography.body)
                    .foregroundStyle(AppColors.textTertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 12)
            } else {
                VStack(spacing: 0) {
                    ForEach(recentMeetings) { record in
                        CaptureRecentRow(record: record) {
                            onOpenLibraryRecord?(record.id)
                        }
                    }
                }
                .padding(.top, 4)
            }
        }
    }
}

// MARK: - Shared capture chrome

/// Editorial header shared by the capture destinations: date kicker, hero
/// sentence with an accented metric, and an optional supporting line.
private struct CaptureEditorialHeader: View {
    let kicker: String
    let heroParts: HomePresentation.HeroSentenceParts
    let subline: String

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(kicker)
                .font(FontLoader.font(family: .inter, size: HomeLayoutMetrics.kickerSize, weight: .semibold))
                .foregroundStyle(AppColors.textTertiary)
                .tracking(HomeLayoutMetrics.kickerTrackingEm * HomeLayoutMetrics.kickerSize)

            captureHeroText(parts: heroParts)
                .padding(.top, 6)
                .padding(.bottom, HomeLayoutMetrics.heroBottomPadding)

            if !subline.isEmpty {
                Text(subline)
                    .font(AppTypography.bodyMeta)
                    .foregroundStyle(AppColors.textSecondary)
                    .lineSpacing(AppTypography.bodyMetaLineSpacing)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Hero sentence with the metric in accented italic Newsreader, shared by all
/// three capture destinations.
private func captureHeroText(parts: HomePresentation.HeroSentenceParts) -> some View {
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

/// Primary start button with an optional shortcut hint and the busy warning.
/// Sits at the trailing edge of the hero row on each capture page.
private struct CaptureStartRow: View {
    @Environment(\.locale) private var locale
    let startTitle: String
    let startIdentifier: String
    let shortcut: String?
    let isBusy: Bool
    let isStartAvailable: Bool
    let onStart: () -> Void

    var body: some View {
        VStack(alignment: .trailing, spacing: 8) {
            HStack(alignment: .center, spacing: 12) {
                if let shortcut, !shortcut.isEmpty {
                    Text(shortcut)
                        .font(AppTypography.monoSmall)
                        .foregroundStyle(AppColors.textTertiary)
                        .monospacedDigit()
                        .environment(\.layoutDirection, .leftToRight)
                }

                PrimaryButton(
                    title: startTitle,
                    systemImage: "record.circle",
                    isEnabled: isStartAvailable && !isBusy,
                    action: onStart
                )
                .keyboardFocusRing(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .accessibilityIdentifier(startIdentifier)
                .accessibilityHint(isBusy ? localized("Finish the current capture before starting another.", locale: locale) : "")
            }

            if isBusy {
                VStack(alignment: .trailing, spacing: 2) {
                    Label(localized("Capture in progress", locale: locale), systemImage: "record.circle.fill")
                    Text(localized("Finish the current capture before starting another.", locale: locale))
                }
                .font(AppTypography.caption)
                .foregroundStyle(AppColors.warning)
                .accessibilityElement(children: .combine)
            }
        }
        .accessibilityElement(children: .contain)
    }
}

/// Dictate's start row observes SettingsStore for the hotkey hint so the rest
/// of the page stays isolated from unrelated settings publications.
private struct DictateStartRow: View {
    @ObservedObject var settingsStore: SettingsStore
    let isBusy: Bool
    let isStartAvailable: Bool
    let onStart: () -> Void
    @Environment(\.locale) private var locale

    var body: some View {
        CaptureStartRow(
            startTitle: localized("Start dictating", locale: locale),
            startIdentifier: "main.capture.dictate.start",
            shortcut: settingsStore.toggleHotkey,
            isBusy: isBusy,
            isStartAvailable: isStartAvailable,
            onStart: onStart
        )
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
        // Row chrome includes 24 pt horizontal padding; counteract outer 40 so lanes
        // sit flush with the page content edge the way Library rows do.
        .padding(.horizontal, -24)
    }
}

/// One voice note row: title, one-line snippet, capture time.
private struct VoiceNoteRow: View {
    @Environment(\.locale) private var locale
    let note: NoteSchema.Note
    let action: () -> Void

    @State private var isHovered = false

    private static let rowTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        return formatter
    }()

    var body: some View {
        Button(action: action) {
            HStack(alignment: .center, spacing: 12) {
                Text(Self.rowTimeFormatter.string(from: note.createdAt))
                    .font(AppTypography.monoSmall)
                    .foregroundStyle(AppColors.textTertiary)
                    .monospacedDigit()
                    .frame(width: 64, alignment: .leading)

                Image(systemName: "note.text")
                    .font(.system(size: 13))
                    .foregroundStyle(AppColors.textTertiary)

                VStack(alignment: .leading, spacing: 2) {
                    Text(note.title.isEmpty ? localized("Untitled", locale: locale) : note.title)
                        .font(AppTypography.body.weight(.medium))
                        .foregroundStyle(AppColors.textPrimary)
                        .lineLimit(1)

                    if !note.content.isEmpty {
                        Text(note.content)
                            .font(AppTypography.caption)
                            .foregroundStyle(AppColors.textSecondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }

                Spacer(minLength: 8)
            }
            .padding(.vertical, 10)
            .padding(.horizontal, 24)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isHovered ? AppColors.sidebarItemHover : Color.clear)
        )
        .keyboardFocusRing(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .onHover { isHovered = $0 }
        // Counteract the outer 40 pt page padding so rows sit flush like Library rows.
        .padding(.horizontal, -24)
    }
}

/// Diarization setup warning/download banner shared by Dictate and Meeting.
private struct DiarizationSetupIssueBanner: View {
    @Environment(\.locale) private var locale
    let message: String
    let isDownloading: Bool
    let progress: Double
    let onDownload: (() -> Void)?

    var body: some View {
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

            if !isDownloading, onDownload != nil {
                Button(localized("Download model", locale: locale)) {
                    onDownload?()
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

// MARK: - First-run welcome

private struct DashboardFirstRunWelcome: View {
    @Environment(\.locale) private var locale

    var body: some View {
        Text(localized("Speak. It's written.", locale: locale))
            .font(FontLoader.font(family: .newsreader, size: HomeLayoutMetrics.heroFontSize, weight: .regular))
            .foregroundStyle(AppColors.textPrimary)
            .tracking(HomeLayoutMetrics.heroTrackingEm * HomeLayoutMetrics.heroFontSize)
            .lineSpacing(HomeLayoutMetrics.heroLineHeight - HomeLayoutMetrics.heroFontSize)
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

#Preview("Voice Note - With Data") {
    VoiceNoteView(settingsStore: SettingsStore())
        .modelContainer(PreviewContainer.withSampleNotes)
        .frame(width: 800, height: 700)
        .preferredColorScheme(.light)
}

#Preview("Meeting - With Data") {
    MeetingView()
        .modelContainer(PreviewContainer.withSampleData)
        .frame(width: 800, height: 700)
        .preferredColorScheme(.light)
}
