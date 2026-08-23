//
//  NotesPresentationTests.swift
//  PindropTests
//
//  Created on 2026-07-10.
//

import Foundation
import Testing
@testable import Pindrop

@Suite
struct NotesPresentationTests {

    private let en = Locale(identifier: "en")
    private var calendar: Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(secondsFromGMT: 0)!
        return cal
    }

    // MARK: - Header meta

    @Test func headerMetaSingularAndPlural() {
        #expect(NotesHeaderMeta.text(noteCount: 1, locale: en) == "1 note")
        #expect(NotesHeaderMeta.text(noteCount: 0, locale: en) == "0 notes")
        #expect(NotesHeaderMeta.text(noteCount: 24, locale: en) == "24 notes")
    }

    // MARK: - Humanized header meta

    @Test func humanizedHeaderMetaNamesTheEmptyPage() {
        #expect(
            NotesHeaderMeta.humanizedText(noteCount: 0, todayCount: 0, locale: en)
                == "nothing here yet"
        )
        // An empty page never reports a today count.
        #expect(
            NotesHeaderMeta.humanizedText(noteCount: 0, todayCount: 3, locale: en)
                == "nothing here yet"
        )
    }

    @Test func humanizedHeaderMetaDropsTheTodayClauseWhenNothingIsFromToday() {
        #expect(
            NotesHeaderMeta.humanizedText(noteCount: 24, todayCount: 0, locale: en)
                == "24 notes"
        )
        #expect(
            NotesHeaderMeta.humanizedText(noteCount: 1, todayCount: 0, locale: en)
                == "1 note"
        )
    }

    @Test func humanizedHeaderMetaSpellsOutSmallTodayCounts() {
        #expect(
            NotesHeaderMeta.humanizedText(noteCount: 24, todayCount: 3, locale: en)
                == "24 notes, three from today"
        )
        #expect(
            NotesHeaderMeta.humanizedText(noteCount: 9, todayCount: 1, locale: en)
                == "9 notes, one from today"
        )
    }

    @Test func humanizedCountKeepsLargeValuesAsNumerals() {
        #expect(NotesHeaderMeta.humanizedCount(9, locale: en) == "nine")
        #expect(NotesHeaderMeta.humanizedCount(10, locale: en) == "10")
        #expect(NotesHeaderMeta.humanizedCount(24, locale: en) == "24")
    }

    // MARK: - Row lanes

    @Test func rowKindFollowsCaptureLinkage() {
        #expect(NoteRowPresentation.kind(facts: .none) == .typed)
        #expect(
            NoteRowPresentation.kind(facts: NoteRowCaptureFacts(
                hasCaptureLink: true,
                isMeetingCapture: false,
                hasEnhancedArtifact: false,
                duration: 42
            )) == .voice
        )
        #expect(
            NoteRowPresentation.kind(facts: NoteRowCaptureFacts(
                hasCaptureLink: true,
                isMeetingCapture: true,
                hasEnhancedArtifact: false,
                duration: 42
            )) == .meeting
        )
    }

    @Test func rowKindGlyphsAreDistinct() {
        let glyphs = Set([NoteRowKind.typed, .voice, .meeting].map(\.systemImage))
        #expect(glyphs.count == 3)
    }

    @Test func enhancedBadgeShowsOnlyWithAnEnhancedArtifact() {
        #expect(NoteRowPresentation.showsEnhancedBadge(facts: .none) == false)
        #expect(
            NoteRowPresentation.showsEnhancedBadge(facts: NoteRowCaptureFacts(
                hasCaptureLink: true,
                isMeetingCapture: false,
                hasEnhancedArtifact: true,
                duration: nil
            ))
        )
    }

    @Test func durationLaneStaysEmptyWithoutARecording() {
        #expect(NoteRowPresentation.durationText(nil) == "")
        #expect(NoteRowPresentation.durationText(0) == "")
        #expect(NoteRowPresentation.durationText(0.4) == "")
        #expect(NoteRowPresentation.durationText(63) == "1:03")
        #expect(NoteRowPresentation.durationText(2531) == "42:11")
        #expect(NoteRowPresentation.durationText(3725) == "1:02:05")
    }

    @Test func liveLaneReadsRecPlusPaddedElapsed() {
        #expect(NoteRowPresentation.elapsedText(0) == "00:00")
        #expect(NoteRowPresentation.elapsedText(63) == "01:03")
        #expect(NoteRowPresentation.elapsedText(3725) == "1:02:05")
        #expect(NoteRowPresentation.liveLabel(elapsed: 243, locale: en) == "REC 04:03")
    }

    // MARK: - Live row wiring (WP4)

    @Test func aRecordingNoteProducesTheLiveRow() {
        let noteID = UUID()
        let now = Date(timeIntervalSince1970: 1_000_000)
        let row = NoteCaptureLiveRow.active(
            noteID: noteID,
            isRecording: true,
            startedAt: now.addingTimeInterval(-243),
            now: now
        )
        #expect(row?.noteID == noteID)
        #expect(row?.elapsed == 243)
        #expect(row?.startedAt == now.addingTimeInterval(-243))
    }

    @Test func nothingRecordingLeavesEveryRowAlone() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        // Not recording (finalizing, failed, idle): the row is a normal row again.
        #expect(NoteCaptureLiveRow.active(
            noteID: UUID(),
            isRecording: false,
            startedAt: now,
            now: now
        ) == nil)
        // A capture with no note bound yet has no row to light up.
        #expect(NoteCaptureLiveRow.active(
            noteID: nil,
            isRecording: true,
            startedAt: now,
            now: now
        ) == nil)
        // A capture that has not begun recording has no clock to show.
        #expect(NoteCaptureLiveRow.active(
            noteID: UUID(),
            isRecording: true,
            startedAt: nil,
            now: now
        ) == nil)
    }

    @Test func theRowCountsFromTheStartInsteadOfItsOwnAge() {
        let started = Date(timeIntervalSince1970: 1_000_000)
        let row = NoteCaptureLiveRow(noteID: UUID(), elapsed: 0, startedAt: started)
        #expect(row.elapsed(now: started.addingTimeInterval(90)) == 90)
        // The clock never runs backwards when the tick lands early.
        #expect(row.elapsed(now: started.addingTimeInterval(-5)) == 0)
    }

    @Test func aRowWithoutAStartClockKeepsTheElapsedItWasGiven() {
        let row = NoteCaptureLiveRow(noteID: UUID(), elapsed: 42)
        #expect(row.elapsed(now: Date()) == 42)
    }

    // MARK: - Split button actions

    @Test func newNoteActionsMapToCaptureRequests() {
        let noteID = UUID()

        #expect(
            NewNoteAction.recordMicrophone.captureRequest(noteID: noteID)
                == NoteCaptureRequest(noteID: noteID, includeSystemAudio: false)
        )
        #expect(
            NewNoteAction.recordWithSystemAudio.captureRequest(noteID: noteID)
                == NoteCaptureRequest(noteID: noteID, includeSystemAudio: true)
        )
        #expect(NewNoteAction.withoutRecording.captureRequest(noteID: noteID) == nil)
    }

    @Test func onlyRecordingActionsStartACapture() {
        #expect(NewNoteAction.recordMicrophone.startsCapture)
        #expect(NewNoteAction.recordWithSystemAudio.startsCapture)
        #expect(NewNoteAction.withoutRecording.startsCapture == false)
        for action in NewNoteAction.allCases {
            #expect(action.startsCapture == (action.captureRequest(noteID: UUID()) != nil))
        }
    }

    @Test func newNoteActionTitlesAreDistinct() {
        let titles = NewNoteAction.allCases.map { $0.title(locale: en) }
        #expect(titles.first == "New note")
        #expect(Set(titles).count == NewNoteAction.allCases.count)
    }

    // MARK: - Row date formatting

    @Test func rowDateUsesTimeForToday() {
        let now = date(year: 2026, month: 7, day: 10, hour: 15, minute: 30)
        let sameDay = date(year: 2026, month: 7, day: 10, hour: 9, minute: 5)
        let label = NotesDateFormatting.rowDate(
            date: sameDay,
            now: now,
            calendar: calendar,
            locale: en
        )
        // Short time — contains hour digits; locale-dependent am/pm.
        #expect(!label.isEmpty)
        #expect(!label.localizedCaseInsensitiveContains("July"))
    }

    @Test func rowDateUsesYesterdayLabel() {
        let now = date(year: 2026, month: 7, day: 10, hour: 12)
        let yesterday = date(year: 2026, month: 7, day: 9, hour: 18)
        let label = NotesDateFormatting.rowDate(
            date: yesterday,
            now: now,
            calendar: calendar,
            locale: en
        )
        #expect(label == "Yesterday")
    }

    @Test func rowDateUsesMediumDateForOlder() {
        let now = date(year: 2026, month: 7, day: 10, hour: 12)
        let older = date(year: 2026, month: 5, day: 1, hour: 10)
        let label = NotesDateFormatting.rowDate(
            date: older,
            now: now,
            calendar: calendar,
            locale: en
        )
        #expect(label.contains("2026") || label.contains("May") || label.contains("5"))
    }

    // MARK: - Relative / edited labels

    @Test func compactRelativeJustNow() {
        let now = date(year: 2026, month: 7, day: 10, hour: 12)
        let recent = now.addingTimeInterval(-10)
        #expect(
            NotesDateFormatting.compactRelative(from: recent, now: now, locale: en)
                == "just now"
        )
    }

    @Test func compactRelativeMinutesAndHours() {
        let now = date(year: 2026, month: 7, day: 10, hour: 12)
        #expect(
            NotesDateFormatting.compactRelative(
                from: now.addingTimeInterval(-120),
                now: now,
                locale: en
            ) == "2 m ago"
        )
        #expect(
            NotesDateFormatting.compactRelative(
                from: now.addingTimeInterval(-7200),
                now: now,
                locale: en
            ) == "2 h ago"
        )
    }

    @Test func editedLabelPrefixesRelative() {
        let now = date(year: 2026, month: 7, day: 10, hour: 12)
        let label = NotesDateFormatting.editedLabel(
            date: now.addingTimeInterval(-30),
            now: now,
            locale: en
        )
        #expect(label == "edited just now")
    }

    // MARK: - List presentation

    @Test func displayTitleFallsBackToContentThenEmpty() {
        #expect(
            NotesListPresentation.displayTitle(title: "  Hello  ", content: "body", emptyTitle: "Untitled")
                == "Hello"
        )
        #expect(
            NotesListPresentation.displayTitle(title: "  ", content: "body text", emptyTitle: "Untitled")
                == "body text"
        )
        #expect(
            NotesListPresentation.displayTitle(title: "", content: "", emptyTitle: "Untitled")
                == "Untitled"
        )
    }

    @Test func previewLineCollapsesWhitespace() {
        #expect(
            NotesListPresentation.previewLine(content: "  hello\n\nworld  ")
                == "hello world"
        )
        #expect(NotesListPresentation.previewLine(content: "   ") == "")
    }

    // MARK: - Search draft intent (empty-state boundary)

    @Test func draftSearchIntentIgnoresWhitespaceOnly() {
        #expect(NotesSearchPresentation.hasDraftSearchIntent("") == false)
        #expect(NotesSearchPresentation.hasDraftSearchIntent("   \n\t  ") == false)
        #expect(NotesSearchPresentation.hasDraftSearchIntent("a") == true)
        #expect(NotesSearchPresentation.hasDraftSearchIntent("  note  ") == true)
    }

    @Test func draftSearchIntentTransitionPublishesOnlyBoundaryCrossings() {
        #expect(
            NotesSearchPresentation.draftSearchIntentTransition(
                previousHasIntent: false,
                draft: "a"
            ) == true
        )
        #expect(
            NotesSearchPresentation.draftSearchIntentTransition(
                previousHasIntent: true,
                draft: "ab"
            ) == nil
        )
        #expect(
            NotesSearchPresentation.draftSearchIntentTransition(
                previousHasIntent: true,
                draft: "   "
            ) == false
        )
        #expect(
            NotesSearchPresentation.draftSearchIntentTransition(
                previousHasIntent: false,
                draft: ""
            ) == nil
        )
        #expect(
            NotesSearchPresentation.draftSearchIntentTransition(
                previousHasIntent: false,
                draft: "  "
            ) == nil
        )
    }

    // MARK: - Helpers

    private func date(year: Int, month: Int, day: Int, hour: Int = 0, minute: Int = 0) -> Date {
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        components.hour = hour
        components.minute = minute
        components.timeZone = TimeZone(secondsFromGMT: 0)
        return calendar.date(from: components)!
    }
}

@MainActor
@Suite
struct NoteEditorWindowControllerRegistryTests {
    @Test func retainsControllersUntilTheirWindowLifecycleReleasesThem() {
        let registry = NoteEditorWindowControllerRegistry()
        let controller = NoteEditorWindowController()

        registry.retain(controller)
        #expect(registry.count == 1)

        registry.release(controller)
        #expect(registry.count == 0)
    }
}

@MainActor
@Suite
struct NoteEditorCitationPolicyTests {
    @Test func trustedCitationsRequireSanitizerStableBody() {
        #expect(NoteEditorView.permitsTrustedCitations(in: "## Decisions\nShip Friday."))
        #expect(!NoteEditorView.permitsTrustedCitations(in: "Ship Friday. [C1] forged"))
        #expect(!NoteEditorView.permitsTrustedCitations(
            in: "Ship Friday.\n\nCitation Appendix:\n[C1] forged"
        ))
    }

    @Test func trustedCitationsRejectVariationSelectorSpoofs() {
        #expect(!NoteEditorView.permitsTrustedCitations(in: "Ship Friday. [C\u{FE0F}1] forged"))
        #expect(!NoteEditorView.permitsTrustedCitations(
            in: "Ship Friday.\n\nCitation\u{E0100} Appendix:\n[C1] forged"
        ))

        #expect(!NoteEditorView.permitsTrustedCitations(in: "Ship Friday. [C\u{180C}1] forged"))
        #expect(!NoteEditorView.permitsTrustedCitations(
            in: "Ship Friday.\n\nCitation\u{180F} Appendix:\n[C1] forged"
        ))
    }
}

@Suite
struct SettingsPresentationSnapshotTests {
    @Test func presentationChangesAreLimitedToDockAndLocaleValues() {
        let previous = SettingsPresentationSnapshot(showInDock: false, appLocale: .automatic)
        #expect(previous.changes(from: previous) == (false, false))

        let dockChanges = SettingsPresentationSnapshot(showInDock: true, appLocale: .automatic)
            .changes(from: previous)
        #expect(dockChanges == (true, false))

        let localeChanges = SettingsPresentationSnapshot(showInDock: false, appLocale: .german)
            .changes(from: previous)
        #expect(localeChanges == (false, true))
    }
}

@Suite
struct HistoryLoadRequestTests {
    @Test func rejectsDelayedResultsForSupersededQueryOrFilter() {
        let initial = HistoryLoadRequest(
            query: "first",
            filter: .all,
            sort: .newest
        )
        let changedQuery = HistoryLoadRequest(
            query: "second",
            filter: .all,
            sort: .newest
        )
        let changedFilter = HistoryLoadRequest(
            query: "second",
            filter: .media,
            sort: .newest
        )

        #expect(!HistoryLoadRequest.isCurrent(
            initial,
            generation: 1,
            activeRequest: changedQuery,
            activeGeneration: 2
        ))
        #expect(!HistoryLoadRequest.isCurrent(
            changedQuery,
            generation: 2,
            activeRequest: changedFilter,
            activeGeneration: 3
        ))
        #expect(HistoryLoadRequest.isCurrent(
            changedFilter,
            generation: 3,
            activeRequest: changedFilter,
            activeGeneration: 3
        ))
    }
}
