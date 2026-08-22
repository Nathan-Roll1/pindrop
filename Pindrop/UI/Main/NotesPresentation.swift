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

    static let none = NoteRowCaptureFacts(
        hasCaptureLink: false,
        isMeetingCapture: false,
        hasEnhancedArtifact: false,
        duration: nil
    )
}

/// A capture currently bound to a note, driving the live row treatment.
///
/// TODO(WP4/P4): `NoteCaptureController` will publish this. No observable today
/// records which note a capture is attached to, so `NotesView` binds it to `nil`
/// and no row renders live.
struct NoteCaptureLiveRow: Equatable, Sendable {
    let noteID: UUID
    let elapsed: TimeInterval

    init(noteID: UUID, elapsed: TimeInterval) {
        self.noteID = noteID
        self.elapsed = elapsed
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

    /// Trailing lane of a live row: "REC 04:03".
    static func liveLabel(elapsed: TimeInterval, locale: Locale) -> String {
        String(format: localized("REC %@", locale: locale), elapsedText(elapsed))
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

    /// Note-row date lane (88 pt): time today, weekday yesterday, else medium date.
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
            return localized("Yesterday", locale: locale)
        }
        return mediumDateFormatter(locale: locale).string(from: date)
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
