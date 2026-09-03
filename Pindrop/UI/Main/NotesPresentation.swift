//
//  NotesPresentation.swift
//  Pindrop
//
//  Created on 2026-07-10.
//
//  Pure helpers for Notes page + note editor presentation (U5). No SwiftUI side effects.
//

import Foundation

// MARK: - Header meta

enum NotesHeaderMeta {
    /// "1 note" / "N notes"
    static func text(noteCount: Int, locale: Locale) -> String {
        if noteCount == 1 {
            return localized("1 note", locale: locale)
        }
        // Use the catalog format key ("%lld notes") so plural stays lowercase "notes".
        return String(format: localized("%lld notes", locale: locale), locale: locale, noteCount)
    }

    /// Notes page header meta, humanized: "24 notes, three from today".
    /// An empty page reads "nothing here yet" instead of "0 notes"; a page with
    /// nothing from today drops the trailing clause.
    static func humanizedText(noteCount: Int, todayCount: Int, locale: Locale) -> String {
        guard noteCount > 0 else {
            return localized("nothing here yet", locale: locale)
        }
        let total = text(noteCount: noteCount, locale: locale)
        guard todayCount > 0 else { return total }
        return String(
            format: localized("%1$@, %2$@ from today", locale: locale),
            total,
            humanizedCount(todayCount, locale: locale)
        )
    }

    /// Small counts read as words ("three"); 10 and up stay numerals so the
    /// line does not turn into "twenty-four from today".
    static func humanizedCount(_ value: Int, locale: Locale) -> String {
        let formatter = NumberFormatter()
        formatter.locale = locale
        guard value > 0, value < 10 else {
            formatter.numberStyle = .decimal
            return formatter.string(from: NSNumber(value: value)) ?? "\(value)"
        }
        formatter.numberStyle = .spellOut
        return formatter.string(from: NSNumber(value: value)) ?? "\(value)"
    }
}

// MARK: - Note row lanes

/// The glyph lane of a Notes-list row, derived from the note's capture linkage.
enum NoteRowKind: Equatable, Sendable {
    /// Typed note with no capture behind it.
    case typed
    /// Note backed by a microphone capture.
    case voice
    /// Note backed by a capture that also recorded system audio.
    case meeting

    var systemImage: String {
        switch self {
        case .typed: "doc.text"
        case .voice: "mic"
        case .meeting: "waveform.badge.mic"
        }
    }
}

/// What the store layer knows about one note's capture linkage. Kept as a value
/// type so row presentation stays testable without SwiftData.
///
/// `hasEnhancedArtifact` is deliberately coarse for WP2: a V15 enhanced panel or
/// a legacy generated note reference both count. WP6 refines it into per-template
/// panel state.
struct NoteRowCaptureFacts: Equatable, Sendable {
    var hasCaptureLink: Bool
    var isMeetingCapture: Bool
    var hasEnhancedArtifact: Bool
    var duration: TimeInterval?
    /// An interruption stopped the recording and startup recovery finished it.
    /// Derived per page from the capture failure records, never stored.
    var isRecovered: Bool

    init(
        hasCaptureLink: Bool,
        isMeetingCapture: Bool,
        hasEnhancedArtifact: Bool,
        duration: TimeInterval?,
        isRecovered: Bool = false
    ) {
        self.hasCaptureLink = hasCaptureLink
        self.isMeetingCapture = isMeetingCapture
        self.hasEnhancedArtifact = hasEnhancedArtifact
        self.duration = duration
        self.isRecovered = isRecovered
    }

    static let none = NoteRowCaptureFacts(
        hasCaptureLink: false,
        isMeetingCapture: false,
        hasEnhancedArtifact: false,
        duration: nil
    )
}

/// A capture currently bound to a note, driving the live row treatment.
///
/// `startedAt` is what the row actually counts from. Passing the clock instead of
/// a ticking number means the list is handed one unchanging value for the whole
/// recording: only the live row re-renders each second, not every row in it.
struct NoteCaptureLiveRow: Equatable, Sendable {
    let noteID: UUID
    /// Elapsed time at the moment this value was made. Used when there is no
    /// `startedAt` to count from.
    let elapsed: TimeInterval
    let startedAt: Date?

    init(noteID: UUID, elapsed: TimeInterval, startedAt: Date? = nil) {
        self.noteID = noteID
        self.elapsed = elapsed
        self.startedAt = startedAt
    }

    /// The live row for the Notes list, or nil when no note is being recorded.
    ///
    /// A capture that is still starting has no clock yet, and a capture that
    /// finished recording is no longer live: both leave the list alone.
    static func active(
        noteID: UUID?,
        isRecording: Bool,
        startedAt: Date?,
        now: Date = Date()
    ) -> NoteCaptureLiveRow? {
        guard isRecording, let noteID, let startedAt else { return nil }
        return NoteCaptureLiveRow(
            noteID: noteID,
            elapsed: max(0, now.timeIntervalSince(startedAt)),
            startedAt: startedAt
        )
    }

    /// Seconds to show on the row at `now`.
    func elapsed(now: Date) -> TimeInterval {
        guard let startedAt else { return elapsed }
        return max(0, now.timeIntervalSince(startedAt))
    }
}

enum NoteRowPresentation {
    static func kind(facts: NoteRowCaptureFacts) -> NoteRowKind {
        guard facts.hasCaptureLink else { return .typed }
        return facts.isMeetingCapture ? .meeting : .voice
    }

    /// The 74 pt badge lane only fills when an enhanced artifact exists.
    static func showsEnhancedBadge(facts: NoteRowCaptureFacts) -> Bool {
        facts.hasEnhancedArtifact
    }

    /// A note whose recording was interrupted and finished by startup recovery
    /// says so, because its words arrived without anybody watching.
    static func showsRecoveredChip(facts: NoteRowCaptureFacts) -> Bool {
        facts.isRecovered
    }

    /// Mono duration lane. Sub-second and missing durations render nothing so
    /// typed notes leave the lane empty instead of showing "0:00".
    static func durationText(_ duration: TimeInterval?) -> String {
        guard let duration, duration >= 1 else { return "" }
        let total = Int(duration.rounded())
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%d:%02d", minutes, seconds)
    }

    /// Trailing lane of a live row: "REC 4:03".
    static func liveLabel(elapsed: TimeInterval, locale: Locale) -> String {
        String(format: localized("REC %@", locale: locale), liveElapsedText(elapsed))
    }

    /// One spoken sentence for a Notes-list row.
    ///
    /// The row is a lane grid: a glyph, a title, a preview, a badge slot, a
    /// duration, a time. VoiceOver reads it as one element, so every lane that
    /// only carries meaning visually is named here. The glyph lane becomes a
    /// word, and a live row says it is recording instead of reading three empty
    /// lanes.
    static func accessibilityLabel(
        title: String,
        facts: NoteRowCaptureFacts,
        isPinned: Bool = false,
        liveElapsed: TimeInterval? = nil,
        dateText: String = "",
        locale: Locale
    ) -> String {
        var parts: [String] = [kindLabel(facts: facts, locale: locale), title]

        if isPinned {
            parts.append(localized("Pinned", locale: locale))
        }

        if let liveElapsed {
            parts.append(localized("Recording", locale: locale))
            parts.append(elapsedText(liveElapsed))
            return parts.filter { !$0.isEmpty }.joined(separator: ", ")
        }

        if showsRecoveredChip(facts: facts) {
            parts.append(localized("Recovered", locale: locale))
        }
        if showsEnhancedBadge(facts: facts) {
            parts.append(localized("Enhanced", locale: locale))
        }
        parts.append(durationText(facts.duration))
        parts.append(dateText)
        return parts.filter { !$0.isEmpty }.joined(separator: ", ")
    }

    /// The word behind the glyph lane.
    static func kindLabel(facts: NoteRowCaptureFacts, locale: Locale) -> String {
        switch kind(facts: facts) {
        case .typed: localized("Note", locale: locale)
        case .voice: localized("Voice note", locale: locale)
        case .meeting: localized("Meeting note", locale: locale)
        }
    }

    /// Zero-padded mm:ss (h:mm:ss past an hour) for the live lane.
    static func elapsedText(_ elapsed: TimeInterval) -> String {
        let total = max(0, Int(elapsed.rounded()))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%02d:%02d", minutes, seconds)
    }

    /// The live clocks (capture bar, dictate pill, REC lane, playback pill) print
    /// unpadded minutes per the design boards: "0:23", not "00:23". Transcript
    /// time codes keep the padded clock (`elapsedText`).
    static func liveElapsedText(_ elapsed: TimeInterval) -> String {
        let total = max(0, Int(elapsed.rounded()))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%d:%02d", minutes, seconds)
    }
}

// MARK: - New note actions

/// The three ways to start a note from the split "New note" button (and the
/// menu-bar items). Only the recording legs produce a capture request.
enum NewNoteAction: Equatable, Sendable, CaseIterable {
    /// Primary segment and ⌘N: a note that records the microphone.
    case recordMicrophone
    /// Menu item: also captures system audio (the old meeting pillar).
    case recordWithSystemAudio
    /// Menu item: a plain typed note.
    case withoutRecording

    var startsCapture: Bool {
        switch self {
        case .recordMicrophone, .recordWithSystemAudio: true
        case .withoutRecording: false
        }
    }

    /// The capture to start after the note exists, or `nil` when the action only
    /// creates and opens a note.
    func captureRequest(noteID: UUID) -> NoteCaptureRequest? {
        switch self {
        case .recordMicrophone:
            NoteCaptureRequest(noteID: noteID, includeSystemAudio: false)
        case .recordWithSystemAudio:
            NoteCaptureRequest(noteID: noteID, includeSystemAudio: true)
        case .withoutRecording:
            nil
        }
    }

    func title(locale: Locale) -> String {
        switch self {
        case .recordMicrophone:
            localized("New note", locale: locale)
        case .recordWithSystemAudio:
            localized("New note with system audio", locale: locale)
        case .withoutRecording:
            localized("New note without recording", locale: locale)
        }
    }
}

// MARK: - Date / relative labels

enum NotesDateFormatting {
    /// Compact relative label for pinned cards, e.g. "edited just now", "edited 2 h ago".
    static func editedLabel(
        date: Date,
        now: Date = Date(),
        locale: Locale = Locale(identifier: "en")
    ) -> String {
        let relative = compactRelative(from: date, now: now, locale: locale)
        return String(
            format: localized("edited %@", locale: locale),
            relative
        )
    }

    /// Note-row date lane (88 pt): time today and yesterday, else medium date.
    /// The boards print the clock for both days ("1:30 PM", "4:48 PM"); the day
    /// name lives on the section header instead.
    static func rowDate(
        date: Date,
        now: Date = Date(),
        calendar: Calendar = .current,
        locale: Locale = Locale(identifier: "en")
    ) -> String {
        if calendar.isDate(date, inSameDayAs: now) {
            return timeFormatter(locale: locale).string(from: date)
        }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
           calendar.isDate(date, inSameDayAs: yesterday) {
            return timeFormatter(locale: locale).string(from: date)
        }
        return mediumDateFormatter(locale: locale).string(from: date)
    }

    /// The note page's date chip: "Today, 1:12 PM" / "Yesterday, 4:48 PM", else
    /// a medium date. The chip names the day; the list row does not.
    static func chipDate(
        date: Date,
        now: Date = Date(),
        calendar: Calendar = .current,
        locale: Locale = Locale(identifier: "en")
    ) -> String {
        let time = timeFormatter(locale: locale).string(from: date)
        if calendar.isDate(date, inSameDayAs: now) {
            return String(
                format: localized("%1$@, %2$@", locale: locale),
                localized("Today", locale: locale),
                time
            )
        }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
           calendar.isDate(date, inSameDayAs: yesterday) {
            return String(
                format: localized("%1$@, %2$@", locale: locale),
                localized("Yesterday", locale: locale),
                time
            )
        }
        return mediumDateFormatter(locale: locale).string(from: date)
    }

    /// The meeting detail's meta date: "Today, 8:02 AM" / "Yesterday, 3:14 PM",
    /// else a medium date with the time kept.
    static func detailDate(
        date: Date,
        now: Date = Date(),
        calendar: Calendar = .current,
        locale: Locale = Locale(identifier: "en")
    ) -> String {
        if calendar.isDate(date, inSameDayAs: now) {
            return chipDate(date: date, now: now, calendar: calendar, locale: locale)
        }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
           calendar.isDate(date, inSameDayAs: yesterday) {
            return chipDate(date: date, now: now, calendar: calendar, locale: locale)
        }
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        formatter.locale = locale
        return formatter.string(from: date)
    }

    /// Footer-style "edited just now" without the "edited" prefix when used alone.
    static func compactRelative(
        from date: Date,
        now: Date = Date(),
        locale: Locale = Locale(identifier: "en")
    ) -> String {
        let interval = now.timeIntervalSince(date)
        if interval < 45 {
            return localized("just now", locale: locale)
        }
        if interval < 3600 {
            let minutes = max(1, Int(interval / 60))
            return String(format: localized("%d m ago", locale: locale), minutes)
        }
        if interval < 86_400 {
            let hours = max(1, Int(interval / 3600))
            return String(format: localized("%d h ago", locale: locale), hours)
        }
        let days = max(1, Int(interval / 86_400))
        if days < 7 {
            return String(format: localized("%d d ago", locale: locale), days)
        }
        return mediumDateFormatter(locale: locale).string(from: date)
    }

    // MARK: Formatters

    private static func timeFormatter(locale: Locale) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        return formatter
    }

    private static func mediumDateFormatter(locale: Locale) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter
    }
}

// MARK: - Note list content helpers

enum NotesListPresentation {
    static func displayTitle(title: String, content: String, emptyTitle: String) -> String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        let preview = content.trimmingCharacters(in: .whitespacesAndNewlines)
        if preview.isEmpty { return emptyTitle }
        if preview.count > 80 { return String(preview.prefix(80)) + "…" }
        return preview
    }

    /// One-line body preview with whitespace collapsed.
    static func previewLine(content: String, empty: String = "") -> String {
        let collapsed = content
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return collapsed.isEmpty ? empty : collapsed
    }
}
