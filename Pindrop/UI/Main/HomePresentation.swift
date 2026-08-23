//
//  HomePresentation.swift
//  Pindrop
//
//  Created on 2026-07-10.
//
//  Pure helpers for Home (Dashboard) presentation (U4). No SwiftUI / SwiftData side effects.
//

import CoreGraphics
import Foundation

// MARK: - Layout metrics (spec §9 — normative)

enum HomeLayoutMetrics {
    // Layout only. Type comes from `AppTypography` roles: hero sentence
    // `heroDisplayMetrics` / `heroDisplayEmphasisMetrics`, stats numbers
    // `statNumberMetrics`, stats and chart labels `statLabelMetrics`,
    // date kicker `overlineMetrics`.

    /// Page frame. Paper board 58: content padding 56 top and sides, 40 bottom.
    static let pagePadding: CGFloat = 56
    static let pageBottomPadding: CGFloat = 40

    /// Date kicker row. Paper board 58: 18 below the row before the hero.
    static let kickerBottomPadding: CGFloat = 18

    /// Hero sentence
    static let heroBottomPadding: CGFloat = 10

    /// Stats strip
    static let statsTopPadding: CGFloat = 36
    static let statsBottomPadding: CGFloat = 40
    static let statsDividerHeight: CGFloat = 40
    static let statsDividerWidth: CGFloat = 1
    static let statsGroupPadding: CGFloat = 32
    static let statsInnerGap: CGFloat = 4

    /// THIS WEEK chart
    static let chartTopPadding: CGFloat = 40
    static let chartSectionGap: CGFloat = 14
    static let chartBarAreaHeight: CGFloat = 92
    static let chartBarWidth: CGFloat = 24
    static let chartBarGap: CGFloat = 14
    static let chartBarTopRadius: CGFloat = 5
    static let chartBarBottomRadius: CGFloat = 2
    static let chartStubHeight: CGFloat = 4
    static let chartLabelGap: CGFloat = 8
    static let chartPanelGap: CGFloat = 24
    static let chartMinimumWidth: CGFloat = 280
    static let chartMaximumWidth: CGFloat = 780
    static let chartPanelDividerWidth: CGFloat = 1
    static let chartPanelDividerHeight: CGFloat = 156
    static let activityMinimumCellSize: CGFloat = 4
    /// Spec baseline cell size; wider windows keep scaling up to the maximum.
    static let activityBaseCellSize: CGFloat = 8
    static let activityMaximumCellSize: CGFloat = 14
    static let activityCellGap: CGFloat = 2
    /// Gap-to-cell ratio once cells grow past the baseline (8 pt cell → 2 pt gap
    /// stays continuous at the crossover).
    static let activityCellGapRatio: CGFloat = 0.25
    static let activityGridHeight: CGFloat = 92
}

// MARK: - Presentation helpers

enum HomePresentation {
    // MARK: Number / metric formatting

    /// Locale-aware grouping separators ("4,210" / "4.210").
    static func formatGrouped(_ number: Int, locale: Locale) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.locale = locale
        formatter.maximumFractionDigits = 0
        return formatter.string(from: NSNumber(value: number)) ?? "\(number)"
    }

    /// "1 word" or "4,210 words" (grouped count for plural).
    static func wordMetric(count: Int, locale: Locale) -> String {
        if count == 1 {
            return localized("1 word", locale: locale)
        }
        return String(
            format: localized("%@ words", locale: locale),
            formatGrouped(count, locale: locale)
        )
    }

    /// Integer WPM for the stats strip ("96").
    static func formatWPM(_ wpm: Double, locale: Locale) -> String {
        let rounded = Int(wpm.rounded())
        return formatGrouped(rounded, locale: locale)
    }

    /// Streak label: "0-day", "1-day", "14-day".
    static func streakLabel(days: Int, locale: Locale) -> String {
        if days == 0 {
            return localized("0-day", locale: locale)
        }
        if days == 1 {
            return localized("1-day", locale: locale)
        }
        return String(format: localized("%d-day", locale: locale), days)
    }

    // MARK: Day boundary

    /// Start of the next calendar day after `date` (local midnight).
    /// Used to schedule Home re-renders so WORDS TODAY / STREAK / kicker / today-bar
    /// do not stay frozen when the window is left open overnight.
    static func nextMidnight(after date: Date, calendar: Calendar = .current) -> Date {
        let startOfDay = calendar.startOfDay(for: date)
        if let next = calendar.date(byAdding: .day, value: 1, to: startOfDay) {
            return next
        }
        // Extremely defensive fallback (calendar arithmetic should not fail for gregorian).
        return date.addingTimeInterval(24 * 60 * 60)
    }

    // MARK: Date kicker

    /// Uppercase weekday + date, e.g. "WEDNESDAY, JULY 9".
    static func dateKicker(
        date: Date,
        locale: Locale,
        calendar: Calendar = .current
    ) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.calendar = calendar
        formatter.setLocalizedDateFormatFromTemplate("EEEE, MMMM d")
        return formatter.string(from: date).uppercased(with: locale)
    }

    // MARK: Hero sentence

    /// Segments of the localized hero sentence so the metric can be styled independently.
    /// Template is "You spoke %@ this week." — the metric placeholder may appear at any index.
    struct HeroSentenceParts: Equatable {
        let before: String
        let metric: String
        let after: String
    }

    static func heroSentenceParts(wordsThisWeek: Int, locale: Locale) -> HeroSentenceParts {
        let metric = wordMetric(count: wordsThisWeek, locale: locale)
        let template = localized("You spoke %@ this week.", locale: locale)
        return heroParts(template: template, metric: metric)
    }

    /// "1 session" or "12 sessions" (grouped count for plural). Trailing meta on
    /// the THIS WEEK chart header, where the old Sessions stat tile moved.
    static func sessionMetric(count: Int, locale: Locale) -> String {
        if count == 1 {
            return localized("1 session", locale: locale)
        }
        return String(
            format: localized("%@ sessions", locale: locale),
            formatGrouped(count, locale: locale)
        )
    }

    /// Splits a localized hero template around its `%@` metric placeholder so the
    /// metric can be styled independently. Falls back to a plain template when a
    /// locale omits the placeholder.
    private static func heroParts(template: String, metric: String) -> HeroSentenceParts {
        if let range = template.range(of: "%@") {
            return HeroSentenceParts(
                before: String(template[..<range.lowerBound]),
                metric: metric,
                after: String(template[range.upperBound...])
            )
        }
        return HeroSentenceParts(before: template, metric: metric, after: "")
    }

    // MARK: Sub-line (duration + time saved)

    /// Formats a duration as "2 h 38 m" / "2 h" / "38 m" / empty when zero.
    static func formatCompactDuration(_ duration: TimeInterval, locale: Locale) -> String {
        guard duration.isFinite, duration > 0 else { return "" }
        let totalMinutes = Int(duration.rounded(.down)) / 60
        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60

        if hours > 0 && minutes > 0 {
            return String(
                format: localized("%d h %d m", locale: locale),
                hours,
                minutes
            )
        }
        if hours > 0 {
            return String(format: localized("%d h", locale: locale), hours)
        }
        // Prefer at least 1 m when there is positive duration under a minute.
        return String(format: localized("%d m", locale: locale), max(1, minutes))
    }

    /// "2 h 38 m of dictation. About 1 h 51 m saved over typing it out."
    /// Two sentences, not one clause hung off a dash (spec: no sentence dashes).
    /// Empty-week: quiet empty string so the view can hide the sub-line or show a short empty hint.
    static func subLine(
        dictationDuration: TimeInterval,
        timeSaved: TimeInterval,
        locale: Locale
    ) -> String {
        let spoken = formatCompactDuration(dictationDuration, locale: locale)
        guard !spoken.isEmpty else { return "" }

        let saved = formatCompactDuration(timeSaved, locale: locale)
        if saved.isEmpty {
            return String(
                format: localized("%@ of dictation.", locale: locale),
                spoken
            )
        }
        return String(
            format: localized("%@ of dictation. About %@ saved over typing it out.", locale: locale),
            spoken,
            saved
        )
    }

    // MARK: Bar chart math

    /// Maps a weekday word count to bar height. Max bucket → full chart height; zero → stub.
    static func barHeight(
        words: Int,
        maxWords: Int,
        chartHeight: CGFloat = HomeLayoutMetrics.chartBarAreaHeight,
        stubHeight: CGFloat = HomeLayoutMetrics.chartStubHeight
    ) -> CGFloat {
        guard words > 0, maxWords > 0, chartHeight > 0 else {
            return stubHeight
        }
        let ratio = CGFloat(words) / CGFloat(maxWords)
        return max(stubHeight, ratio * chartHeight)
    }

    /// Whether the bar index is "today" within the calendar week ordered by `firstWeekday`.
    static func isTodayBarIndex(
        _ index: Int,
        now: Date,
        calendar: Calendar
    ) -> Bool {
        index == todayBarIndex(now: now, calendar: calendar)
    }

    static func todayBarIndex(now: Date, calendar: Calendar) -> Int {
        let weekday = calendar.component(.weekday, from: now)
        return (weekday - calendar.firstWeekday + 7) % 7
    }

    /// Past / today / future relative to `now` for a bar index in the firstWeekday-ordered week.
    enum BarDayKind: Equatable {
        case past
        case today
        case future
    }

    static func barDayKind(
        index: Int,
        now: Date,
        calendar: Calendar
    ) -> BarDayKind {
        let todayIndex = todayBarIndex(now: now, calendar: calendar)
        if index < todayIndex { return .past }
        if index == todayIndex { return .today }
        return .future
    }

    /// Short weekday labels ordered from `calendar.firstWeekday` (locale-aware).
    static func weekdayLabels(calendar: Calendar, locale: Locale) -> [String] {
        var cal = calendar
        cal.locale = locale
        let symbols = cal.veryShortWeekdaySymbols
        guard symbols.count == 7 else {
            return symbols
        }
        let first = cal.firstWeekday - 1 // 0-based into Sunday-first array
        return (0..<7).map { symbols[($0 + first) % 7] }
    }

    /// Full weekday names ordered from `calendar.firstWeekday` (for a11y).
    static func weekdayNames(calendar: Calendar, locale: Locale) -> [String] {
        var cal = calendar
        cal.locale = locale
        let symbols = cal.weekdaySymbols
        guard symbols.count == 7 else {
            return symbols
        }
        let first = cal.firstWeekday - 1
        return (0..<7).map { symbols[($0 + first) % 7] }
    }

    /// Accessibility label: "Monday, 812 words".
    static func barAccessibilityLabel(
        weekdayName: String,
        words: Int,
        locale: Locale
    ) -> String {
        if words == 1 {
            return String(
                format: localized("%@, 1 word", locale: locale),
                weekdayName
            )
        }
        return String(
            format: localized("%@, %@ words", locale: locale),
            weekdayName,
            formatGrouped(words, locale: locale)
        )
    }

    // MARK: Activity chart

    static func activityStartDate(now: Date, calendar: Calendar) -> Date? {
        calendar.date(byAdding: .day, value: -364, to: calendar.startOfDay(for: now))
    }

    static func activityLeadingBlankCount(startDate: Date, calendar: Calendar) -> Int {
        let weekday = calendar.component(.weekday, from: startDate)
        return (weekday - calendar.firstWeekday + 7) % 7
    }

    static func activityGridStartDate(startDate: Date, calendar: Calendar) -> Date? {
        calendar.date(
            byAdding: .day,
            value: -activityLeadingBlankCount(startDate: startDate, calendar: calendar),
            to: startDate
        )
    }

    // MARK: Activity grid sizing

    /// 53 week columns with 52 gaps between them.
    private static let activityWeekColumns: CGFloat = 53

    struct ActivityCellMetrics: Equatable {
        let cellSize: CGFloat
        let cellGap: CGFloat
    }

    /// Cell and gap size for the 53-column activity grid at `availableWidth`.
    /// Below the baseline the gap stays fixed and cells shrink toward the minimum;
    /// past it the gap scales with the cells so larger grids keep the same texture.
    static func activityCellMetrics(availableWidth: CGFloat) -> ActivityCellMetrics {
        let columns = activityWeekColumns
        let gaps = columns - 1
        let baseGap = HomeLayoutMetrics.activityCellGap
        guard availableWidth > 0 else {
            // Width unknown on the first layout pass → baseline design metrics.
            return ActivityCellMetrics(
                cellSize: HomeLayoutMetrics.activityBaseCellSize,
                cellGap: baseGap
            )
        }
        let fixedGapSize = (availableWidth - gaps * baseGap) / columns
        if fixedGapSize <= HomeLayoutMetrics.activityBaseCellSize {
            return ActivityCellMetrics(
                cellSize: max(HomeLayoutMetrics.activityMinimumCellSize, fixedGapSize),
                cellGap: baseGap
            )
        }
        let ratio = HomeLayoutMetrics.activityCellGapRatio
        let cellSize = min(
            HomeLayoutMetrics.activityMaximumCellSize,
            availableWidth / (columns + gaps * ratio)
        )
        return ActivityCellMetrics(cellSize: cellSize, cellGap: cellSize * ratio)
    }

    /// Extra height the activity grid needs beyond its baseline (8 pt cell / 2 pt gap)
    /// layout. The weekly bars and panel divider grow by the same amount so the
    /// bottom chart row stays visually balanced at large window sizes.
    static func chartRowGrowth(cellMetrics: ActivityCellMetrics) -> CGFloat {
        let baseline = HomeLayoutMetrics.activityBaseCellSize * 7
            + HomeLayoutMetrics.activityCellGap * 6
        let grid = cellMetrics.cellSize * 7 + cellMetrics.cellGap * 6
        return max(0, grid - baseline)
    }

    /// Width the activity heatmap receives inside the bottom chart row: the weekly
    /// panel is pinned to its minimum width by the heatmap's layout priority.
    static func activityAvailableWidth(chartRowWidth: CGFloat) -> CGFloat {
        chartRowWidth
            - HomeLayoutMetrics.chartMinimumWidth
            - HomeLayoutMetrics.chartPanelGap * 2
            - HomeLayoutMetrics.chartPanelDividerWidth
    }

    /// Four non-zero intensity levels, with zero reserved for an empty day.
    static func activityIntensity(words: Int, maxWords: Int) -> Int {
        guard words > 0, maxWords > 0 else { return 0 }
        return min(4, max(1, Int(ceil((Double(words) / Double(maxWords)) * 4))))
    }

    static func activityMonthLabel(
        weekIndex: Int,
        startDate: Date,
        calendar: Calendar,
        locale: Locale
    ) -> String {
        guard let weekStart = calendar.date(byAdding: .weekOfYear, value: weekIndex, to: startDate) else {
            return ""
        }
        if weekIndex > 0,
           let previousWeek = calendar.date(byAdding: .weekOfYear, value: weekIndex - 1, to: startDate),
           calendar.component(.month, from: previousWeek) == calendar.component(.month, from: weekStart) {
            return ""
        }

        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.calendar = calendar
        formatter.setLocalizedDateFormatFromTemplate("MMM")
        return formatter.string(from: weekStart)
    }

    static func activityAccessibilityLabel(
        date: Date,
        words: Int,
        calendar: Calendar,
        locale: Locale
    ) -> String {
        "\(activityDateLabel(date: date, calendar: calendar, locale: locale)), \(wordMetric(count: words, locale: locale))"
    }

    static func activityDateLabel(
        date: Date,
        calendar: Calendar,
        locale: Locale
    ) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.calendar = calendar
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter.string(from: date)
    }

    // MARK: Dictate action frame

    /// The hotkey as the page prints it. Falls back to the shipped default so the
    /// button and the empty state never say "Press  anywhere to start."
    static func dictationShortcut(_ hotkey: String, locale: Locale) -> String {
        let trimmed = hotkey.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? localized("⌥Space", locale: locale) : trimmed
    }

    /// What the one action frame on the Dictate page shows.
    ///
    /// Start and recording are the same frame: the CTA becomes the clock in
    /// place, so beginning a dictation never moves the page under the pointer.
    static func captureControl(
        isDictating: Bool,
        elapsed: TimeInterval,
        isStartAvailable: Bool,
        isCaptureBusy: Bool,
        hotkey: String,
        locale: Locale
    ) -> DictateCaptureControl {
        let shortcut = dictationShortcut(hotkey, locale: locale)
        if isDictating {
            return DictateCaptureControl(
                mode: .recording,
                startTitle: localized("Start dictating", locale: locale),
                shortcut: shortcut,
                isStartEnabled: false,
                disabledReason: nil,
                elapsedText: NoteRowPresentation.elapsedText(elapsed),
                stopTitle: localized("Stop", locale: locale)
            )
        }
        return DictateCaptureControl(
            mode: .start,
            startTitle: localized("Start dictating", locale: locale),
            shortcut: shortcut,
            isStartEnabled: isStartAvailable && !isCaptureBusy,
            // The old page shouted this in a warning block under the button. It
            // belongs on the button that will not press.
            disabledReason: isCaptureBusy
                ? localized("Finish the current capture before starting another.", locale: locale)
                : nil,
            elapsedText: "",
            stopTitle: localized("Stop", locale: locale)
        )
    }

    // MARK: Dictate stats

    /// The three tiles above the Recent list. Sessions used to be a fourth; it
    /// reads better as trailing meta on the THIS WEEK chart, where the week it
    /// counts is already named.
    static func statTiles(
        wordsToday: Int,
        wpmThisWeek: Double,
        streakDays: Int,
        locale: Locale
    ) -> [DictateStatTile] {
        [
            DictateStatTile(
                value: formatGrouped(wordsToday, locale: locale),
                label: localized("Words today", locale: locale)
            ),
            DictateStatTile(
                value: formatWPM(wpmThisWeek, locale: locale),
                label: localized("Words / min", locale: locale)
            ),
            DictateStatTile(
                value: streakLabel(days: streakDays, locale: locale),
                label: localized("Streak", locale: locale)
            )
        ]
    }

    // MARK: Dictate empty state

    /// First run: name the situation, then the next action. No slogan.
    static func emptyState(hotkey: String, locale: Locale) -> DictateEmptyState {
        DictateEmptyState(
            title: localized("No dictations yet.", locale: locale),
            guidance: String(
                format: localized("Press %@ anywhere to start.", locale: locale),
                dictationShortcut(hotkey, locale: locale)
            )
        )
    }
}

// MARK: - Dictate value types

/// The Dictate page's one action frame, decided without a window.
struct DictateCaptureControl: Equatable, Sendable {
    enum Mode: Equatable, Sendable {
        /// "Start dictating", with the hotkey printed inside the button.
        case start
        /// Elapsed clock, live level, Stop.
        case recording
    }

    let mode: Mode
    let startTitle: String
    /// The user's dictation hotkey, as printed inside the CTA and the empty state.
    let shortcut: String
    let isStartEnabled: Bool
    /// Why the CTA will not press. Nil when it will.
    let disabledReason: String?
    /// Zero-padded mm:ss (h:mm:ss past an hour). Empty outside `.recording`.
    let elapsedText: String
    let stopTitle: String
}

/// One tile in the Dictate stats strip.
struct DictateStatTile: Equatable, Sendable, Identifiable {
    let value: String
    let label: String

    var id: String { label }
}

/// The two lines the Dictate page shows before the first dictation.
struct DictateEmptyState: Equatable, Sendable {
    let title: String
    let guidance: String
}
