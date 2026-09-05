//
//  DashboardStatsServiceTests.swift
//  PindropTests
//
//  Created on 2026-07-09.
//
//  App-retained presentation/analytics cases. Portable DashboardStatsService sample
//  computation lives in Packages/PindropShared/Tests/PindropCoreTests.
//

import Foundation
import Testing
@testable import Pindrop
import PindropCore

@Suite
struct DashboardStatsPresentationTests {
    @Test func activityIntensity_usesFourNonzeroLevels() {
        #expect(HomePresentation.activityIntensity(words: 0, maxWords: 100) == 0)
        #expect(HomePresentation.activityIntensity(words: 1, maxWords: 100) == 1)
        #expect(HomePresentation.activityIntensity(words: 25, maxWords: 100) == 1)
        #expect(HomePresentation.activityIntensity(words: 26, maxWords: 100) == 2)
        #expect(HomePresentation.activityIntensity(words: 75, maxWords: 100) == 3)
        #expect(HomePresentation.activityIntensity(words: 100, maxWords: 100) == 4)
    }
}

@Suite("Stats page analytics")
struct StatsPageAnalyticsTests {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        calendar.firstWeekday = 2
        return calendar
    }

    private func date(_ day: Int, hour: Int = 12) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 7, day: day, hour: hour))!
    }

    private func record(
        day: Int,
        hour: Int = 12,
        words: Int,
        duration: TimeInterval = 60,
        source: MediaSourceKind = .voiceRecording,
        destination: String? = nil,
        enhanced: Bool = false
    ) -> StatsRecord {
        StatsRecord(
            timestamp: date(day, hour: hour),
            words: words,
            duration: duration,
            sourceKind: source,
            destinationApp: destination,
            isEnhanced: enhanced
        )
    }

    @Test func computesOverviewFromVoiceDictationsOnly() {
        let snapshot = StatsService.compute(
            records: [
                record(day: 9, words: 100, duration: 60, destination: "Notes", enhanced: true),
                record(day: 10, words: 200, duration: 120, destination: "Mail"),
                record(day: 11, words: 300, duration: 300, source: .manualCapture),
                record(day: 11, words: 400, duration: 400, source: .importedFile),
                record(day: 11, words: 500, duration: 500, source: .webLink)
            ],
            range: .sevenDays,
            calendar: calendar,
            now: date(11, hour: 18)
        )

        #expect(snapshot.totalWords == 300)
        #expect(snapshot.totalSessions == 2)
        #expect(snapshot.totalDuration == 180)
        #expect(snapshot.activeDays == 2)
        #expect(snapshot.longestStreak == 2)
        #expect(snapshot.enhancedSessions == 1)
        #expect(snapshot.averageWordsPerSession == 150)
        #expect(snapshot.averageSessionDuration == 90)
        #expect(snapshot.averageWPM == 100)
        #expect(snapshot.activity.count == 2)
        #expect(snapshot.sources == [
            StatsCategoryBucket(id: MediaSourceKind.voiceRecording.rawValue, words: 300, sessions: 2, duration: 180)
        ])
    }

    @Test func averagesPipelineLatenciesOverRecordsThatCapturedThem() {
        let snapshot = StatsService.compute(
            records: [
                StatsRecord(
                    timestamp: date(10),
                    words: 100, duration: 60,
                    sourceKind: .voiceRecording, destinationApp: nil, isEnhanced: true,
                    transcriptionSeconds: 1.0,
                    enhancementSeconds: 2.0,
                    totalPipelineSeconds: 4.0
                ),
                StatsRecord(
                    timestamp: date(11),
                    words: 100, duration: 60,
                    sourceKind: .voiceRecording, destinationApp: nil, isEnhanced: false,
                    transcriptionSeconds: 3.0,
                    enhancementSeconds: nil,
                    totalPipelineSeconds: 6.0
                ),
                // Pre-metrics record: must not drag averages toward zero.
                record(day: 11, words: 100)
            ],
            range: .sevenDays,
            calendar: calendar,
            now: date(11, hour: 18)
        )

        #expect(snapshot.averageTranscriptionSeconds == 2.0)
        #expect(snapshot.averageEnhancementSeconds == 2.0)
        #expect(snapshot.averageTotalPipelineSeconds == 5.0)
    }

    @Test func pipelineLatencyAveragesAreZeroWithoutInstrumentedRecords() {
        let snapshot = StatsService.compute(
            records: [record(day: 10, words: 100)],
            range: .sevenDays,
            calendar: calendar,
            now: date(11, hour: 18)
        )

        #expect(snapshot.averageTranscriptionSeconds == 0)
        #expect(snapshot.averageEnhancementSeconds == 0)
        #expect(snapshot.averageTotalPipelineSeconds == 0)
    }

    @Test func rangeAndFutureRecordsAreExcluded() {
        let snapshot = StatsService.compute(
            records: [
                record(day: 1, words: 500),
                record(day: 10, words: 100),
                record(day: 12, words: 900)
            ],
            range: .sevenDays,
            calendar: calendar,
            now: date(11, hour: 18)
        )

        #expect(snapshot.totalWords == 100)
        #expect(snapshot.totalSessions == 1)
    }

    @Test func groupsWeekdaysHoursAndDestinations() {
        let snapshot = StatsService.compute(
            records: [
                record(day: 10, hour: 9, words: 100, destination: "Notes"),
                record(day: 10, hour: 9, words: 50, destination: "Notes"),
                record(day: 11, hour: 14, words: 75, destination: nil)
            ],
            range: .thirtyDays,
            calendar: calendar,
            now: date(11, hour: 18)
        )

        #expect(snapshot.weekdays.count == 7)
        #expect(snapshot.hours.count == 24)
        #expect(snapshot.hours.first(where: { $0.id == "9" })?.words == 150)
        #expect(snapshot.destinations.first?.id == "Notes")
        #expect(snapshot.destinations.last?.id == "__unknown__")
    }

    @Test func emptyInputProducesEmptySnapshot() {
        #expect(
            StatsService.compute(
                records: [], range: .allTime, calendar: calendar, now: date(11)
            ) == .empty
        )
    }
}
