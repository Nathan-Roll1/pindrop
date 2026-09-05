//
//  DashboardStats.swift
//  PindropCore
//
//  Created on 2026-07-09.
//
//  Pure windowed stats for the Home dashboard. Computation is intentionally free of
//  SwiftData and the real clock. Record to StatsSample adaptation lives in PindropData.
//

import Foundation

// MARK: - Input

/// Lightweight stats input so unit tests never need SwiftData models.
public struct StatsSample: Equatable, Sendable {
    public let timestamp: Date
    public let wordCount: Int
    public let duration: TimeInterval
    public let sourceKind: MediaSourceKind

    public init(
        timestamp: Date,
        wordCount: Int,
        duration: TimeInterval,
        sourceKind: MediaSourceKind = .voiceRecording
    ) {
        self.timestamp = timestamp
        self.wordCount = wordCount
        self.duration = duration
        self.sourceKind = sourceKind
    }

    public init(
        timestamp: Date,
        text: String,
        duration: TimeInterval,
        sourceKind: MediaSourceKind = .voiceRecording
    ) {
        self.timestamp = timestamp
        self.wordCount = text.wordCount
        self.duration = duration
        self.sourceKind = sourceKind
    }
}

// MARK: - Result

public struct DashboardStats: Equatable, Sendable {
    public let wordsToday: Int
    public let wordsThisWeek: Int
    public let sessionsToday: Int
    public let sessionsThisWeek: Int
    /// Total words this week divided by total spoken duration in minutes. Zero when duration is 0.
    public let wpmThisWeek: Double
    /// Consecutive calendar days with at least one sample, ending today when today has activity,
    /// or ending yesterday when today is empty but yesterday is not. Zero when neither
    /// today nor yesterday has activity.
    public let streakDays: Int
    /// Seven word-count buckets for the calendar week containing `now`, ordered from
    /// `calendar.firstWeekday` through the rest of the week (locale-aware Mon-Sun or Sun-Sat).
    public let wordsPerWeekday: [Int]
    /// Daily word-count buckets for the rolling 365-day period ending today,
    /// ordered oldest to newest.
    public let wordsPerActivityDay: [Int]
    public let dictationDurationThisWeek: TimeInterval
    /// Estimated typing time at 40 WPM minus actual dictation duration for the week, floored at 0.
    public let timeSavedThisWeek: TimeInterval

    public init(
        wordsToday: Int,
        wordsThisWeek: Int,
        sessionsToday: Int,
        sessionsThisWeek: Int,
        wpmThisWeek: Double,
        streakDays: Int,
        wordsPerWeekday: [Int],
        wordsPerActivityDay: [Int],
        dictationDurationThisWeek: TimeInterval,
        timeSavedThisWeek: TimeInterval
    ) {
        self.wordsToday = wordsToday
        self.wordsThisWeek = wordsThisWeek
        self.sessionsToday = sessionsToday
        self.sessionsThisWeek = sessionsThisWeek
        self.wpmThisWeek = wpmThisWeek
        self.streakDays = streakDays
        self.wordsPerWeekday = wordsPerWeekday
        self.wordsPerActivityDay = wordsPerActivityDay
        self.dictationDurationThisWeek = dictationDurationThisWeek
        self.timeSavedThisWeek = timeSavedThisWeek
    }

    public static let empty = DashboardStats(
        wordsToday: 0,
        wordsThisWeek: 0,
        sessionsToday: 0,
        sessionsThisWeek: 0,
        wpmThisWeek: 0,
        streakDays: 0,
        wordsPerWeekday: Array(repeating: 0, count: 7),
        wordsPerActivityDay: Array(repeating: 0, count: 365),
        dictationDurationThisWeek: 0,
        timeSavedThisWeek: 0
    )
}

// MARK: - Service

public enum DashboardStatsService {
    /// Assumed typing speed used for the time-saved estimate (words per minute).
    public static let typingWPM: Double = 40

    /// Stateless computation over pre-built samples. Uses only the injected calendar and `now`.
    public static func compute(
        samples: [StatsSample],
        calendar: Calendar,
        now: Date
    ) -> DashboardStats {
        aggregate(calendar: calendar, now: now) { visit in
            for sample in samples where sample.sourceKind == .voiceRecording {
                visit(sample.timestamp, sample.wordCount, sample.duration)
            }
        }
    }

    /// Shared aggregation loop for sample inputs.
    private static func aggregate(
        calendar: Calendar,
        now: Date,
        enumerate: (_ visit: (_ timestamp: Date, _ wordCount: Int, _ duration: TimeInterval) -> Void) -> Void
    ) -> DashboardStats {
        guard let weekInterval = calendar.dateInterval(of: .weekOfYear, for: now) else {
            return .empty
        }

        let startOfToday = calendar.startOfDay(for: now)
        guard let startOfTomorrow = calendar.date(byAdding: .day, value: 1, to: startOfToday) else {
            return .empty
        }

        var wordsToday = 0
        var sessionsToday = 0
        var wordsThisWeek = 0
        var sessionsThisWeek = 0
        var dictationDurationThisWeek: TimeInterval = 0
        var wordsPerWeekday = Array(repeating: 0, count: 7)
        var wordsPerActivityDay = Array(repeating: 0, count: 365)
        var activeDayStarts = Set<Date>()
        let activityStart = calendar.date(byAdding: .day, value: -364, to: startOfToday)

        enumerate { timestamp, wordCount, duration in
            let dayStart = calendar.startOfDay(for: timestamp)
            activeDayStarts.insert(dayStart)

            if let activityStart,
               dayStart >= activityStart,
               dayStart < startOfTomorrow,
               let dayOffset = calendar.dateComponents([.day], from: activityStart, to: dayStart).day,
               wordsPerActivityDay.indices.contains(dayOffset) {
                wordsPerActivityDay[dayOffset] += wordCount
            }

            let isToday = timestamp >= startOfToday && timestamp < startOfTomorrow
            if isToday {
                wordsToday += wordCount
                sessionsToday += 1
            }

            let isThisWeek = timestamp >= weekInterval.start && timestamp < weekInterval.end
            if isThisWeek {
                wordsThisWeek += wordCount
                sessionsThisWeek += 1
                dictationDurationThisWeek += duration

                let weekday = calendar.component(.weekday, from: timestamp)
                let index = weekdayIndex(weekday: weekday, firstWeekday: calendar.firstWeekday)
                wordsPerWeekday[index] += wordCount
            }
        }

        let wpmThisWeek: Double
        if dictationDurationThisWeek > 0 {
            let minutes = dictationDurationThisWeek / 60.0
            wpmThisWeek = Double(wordsThisWeek) / minutes
        } else {
            wpmThisWeek = 0
        }

        let typingSeconds = (Double(wordsThisWeek) / typingWPM) * 60.0
        let timeSavedThisWeek = max(0, typingSeconds - dictationDurationThisWeek)

        let streakDays = computeStreakDays(
            activeDayStarts: activeDayStarts,
            calendar: calendar,
            now: now
        )

        return DashboardStats(
            wordsToday: wordsToday,
            wordsThisWeek: wordsThisWeek,
            sessionsToday: sessionsToday,
            sessionsThisWeek: sessionsThisWeek,
            wpmThisWeek: wpmThisWeek,
            streakDays: streakDays,
            wordsPerWeekday: wordsPerWeekday,
            wordsPerActivityDay: wordsPerActivityDay,
            dictationDurationThisWeek: dictationDurationThisWeek,
            timeSavedThisWeek: timeSavedThisWeek
        )
    }

    // MARK: - Streak

    /// Consecutive calendar days with at least one record.
    ///
    /// The streak ends on today when today has at least one sample. If today is still
    /// empty, the streak may end on yesterday (user has not dictated yet today but was
    /// active yesterday). If both today and yesterday are empty, the streak is 0.
    private static func computeStreakDays(
        activeDayStarts: Set<Date>,
        calendar: Calendar,
        now: Date
    ) -> Int {
        let todayStart = calendar.startOfDay(for: now)
        guard let yesterdayStart = calendar.date(byAdding: .day, value: -1, to: todayStart) else {
            return 0
        }

        let anchor: Date
        if activeDayStarts.contains(todayStart) {
            anchor = todayStart
        } else if activeDayStarts.contains(yesterdayStart) {
            anchor = yesterdayStart
        } else {
            return 0
        }

        var count = 0
        var day = anchor
        while activeDayStarts.contains(day) {
            count += 1
            guard let previous = calendar.date(byAdding: .day, value: -1, to: day) else {
                break
            }
            day = previous
        }
        return count
    }

    /// Maps a Gregorian weekday (1=Sunday ... 7=Saturday) to a 0...6 index ordered by `firstWeekday`.
    private static func weekdayIndex(weekday: Int, firstWeekday: Int) -> Int {
        (weekday - firstWeekday + 7) % 7
    }
}
