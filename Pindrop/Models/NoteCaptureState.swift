//
//  NoteCaptureState.swift
//  Pindrop
//
//  Created on 2026-08-22.
//
//  Observable model for one note capture. `NoteCaptureController` is the only
//  writer; every view reads it. Keeping the mutation surface on this type (and
//  not on the views) means the capture UI can never disagree with the durable
//  session about what phase the capture is in.
//

import Foundation
import PindropCore

/// What the live speaker labels are doing, as the live surfaces draw it.
///
/// Only the degradations a reader can act on or is owed an explanation for are
/// named here. A slot that never earns a real name says nothing at all, because
/// "Speaker 2" is already an honest label.
enum LiveSpeakerLabelStatus: Equatable, Sendable {
    /// Never asked for: the capture records no system audio, or the setting is
    /// off. The microphone channel is already `You` at full confidence.
    case off
    /// Labels are loading or running.
    case running
    /// The streaming speaker model is not on disk. Nothing is fetched from the
    /// capture path, so the reader is offered the download instead.
    case modelMissing
    /// The bounded model load failed or ran out of time.
    case loadFailed
    /// Labels froze part way through and do not resume for this capture: the
    /// diarizer fell behind, or the partial-latency kill switch fired. Every
    /// label already on screen stays there.
    case paused
}

@MainActor
@Observable
final class NoteCaptureState {

    /// The named work a finalizing capture is doing, with progress where the
    /// stage can report it. `nil` progress means "running, length unknown"; the
    /// UI shows an indeterminate affordance rather than a fake percentage.
    enum FinalizationStage: Equatable {
        case sealingAudio
        case transcribing(Double?)
        case diarizing(Double?)
        case assembling
    }

    enum Phase: Equatable {
        case idle
        case starting
        case capturing
        case finalizing(FinalizationStage)
        case enhancing
        case completed
        /// Carries the `LocalizedError` text the person is shown.
        case failed(String)
    }

    private(set) var phase: Phase = .idle
    /// The note this capture writes to. Set as soon as the note exists, which is
    /// before audio starts, so the UI can open the note while it is still empty.
    private(set) var noteID: UUID?
    private(set) var sessionID: UUID?
    /// What asked for this capture. The shell reads it to decide where finished
    /// output lands: a capture started from the main window is already on
    /// screen, a hotkey capture must not pull a window forward mid-sentence.
    private(set) var origin: CaptureIntentOrigin?
    private(set) var includesSystemAudio = false
    private(set) var startedAt: Date?
    private(set) var audioLevel: Float = 0
    private(set) var bandLevels: AudioBandLevels = .zero
    /// The paragraphs the engine has settled on, in order, each pointed at the
    /// speaker it was attributed to. Empty while a capture has produced no words.
    private(set) var liveSpans: [LiveTranscriptSpan] = []
    /// The tail the engine may still rewrite. The live sheet draws it in the
    /// quiet ink so nobody reads an unsettled guess as a finished sentence.
    private(set) var liveTentative: LiveTentativeSpan?
    /// Why the enhanced panel could not be generated, or nil when nothing
    /// failed. A failed generation never fails the capture: the typed notes and
    /// the transcript are already durable, so the note page explains the gap and
    /// offers to try again.
    private(set) var enhancementFailureMessage: String?
    /// True once live transcription stopped early: the two-hour bound elapsed,
    /// or checkpoint persistence was disabled. The durable recording continues,
    /// so the UI explains the gap instead of implying the recording stopped.
    private(set) var isLiveTranscriptDegraded = false
    /// True while this capture records the call but only the microphone has ever
    /// reached the live engine. A different fact from `isLiveTranscriptDegraded`,
    /// which means the live text stopped growing: here the live text is growing
    /// and one side of the conversation is not in it.
    private(set) var isLiveTranscriptMicrophoneOnly = false
    /// What the live speaker labels are doing. `off` for every capture that
    /// never asked for them, which is every dictation and every note recorded
    /// from the microphone alone.
    private(set) var liveSpeakerLabelStatus: LiveSpeakerLabelStatus = .off
    /// What the last speaker-model download attempted from the note page's setup
    /// banner said went wrong, or nil. Not localized here: it is the model
    /// manager's own error text.
    private(set) var liveSpeakerDownloadFailure: String?
    /// True once every diarizer slot is in use. The live sheet states this as a
    /// capability and never as a headcount: the app has not counted the people
    /// on the call, and a confident wrong count costs more trust than silence.
    private(set) var isLiveSpeakerSlotCapacityReached = false
    /// True when finalize will run the offline speaker pass for this capture.
    /// Only then may a chip promise the speakers are checked again.
    private(set) var isOfflineSpeakerPassScheduled = false

    /// The reader's view, built once per span change instead of once per render.
    /// Live partials redraw the sheet several times a second for the length of a
    /// capture, and this walks every span and localizes every turn header.
    ///
    /// Ignored by observation on purpose: it is derived from `liveSpans`, which
    /// is observed, and letting a read from a view body publish a change here
    /// would invalidate the view that just read it.
    @ObservationIgnored private var copyTextCache: (localeIdentifier: String, text: String)?

    /// v1 has no pause. `AudioRecorder` cannot pause a durable spool and
    /// `CaptureSession.isValid` encodes state in revision parity, so a paused
    /// lifecycle state would mean rewriting the validator. The seam stays here
    /// so the capture bar can ask rather than assume.
    let canPause = false

    var isActive: Bool {
        switch phase {
        case .starting, .capturing, .finalizing, .enhancing:
            true
        case .idle, .completed, .failed:
            false
        }
    }

    var isCapturing: Bool {
        phase == .capturing
    }

    var failureMessage: String? {
        guard case .failed(let message) = phase else { return nil }
        return message
    }

    // MARK: - Transitions

    func beginStarting(includesSystemAudio: Bool, origin: CaptureIntentOrigin) {
        phase = .starting
        self.includesSystemAudio = includesSystemAudio
        self.origin = origin
        noteID = nil
        sessionID = nil
        startedAt = nil
        audioLevel = 0
        bandLevels = .zero
        liveSpans = []
        copyTextCache = nil
        liveTentative = nil
        isLiveTranscriptDegraded = false
        isLiveTranscriptMicrophoneOnly = false
        liveSpeakerLabelStatus = .off
        liveSpeakerDownloadFailure = nil
        isLiveSpeakerSlotCapacityReached = false
        isOfflineSpeakerPassScheduled = false
        enhancementFailureMessage = nil
    }

    func bindNote(id: UUID) {
        noteID = id
    }

    /// Forgets which note the capture wrote to. Used when the capture removed
    /// the note it had created for itself, so nothing points at a note that no
    /// longer exists.
    func clearNote() {
        noteID = nil
    }

    func bindSession(id: UUID) {
        sessionID = id
    }

    func beginCapturing(startedAt: Date) {
        self.startedAt = startedAt
        phase = .capturing
    }

    func updateLevels(level: Float, bands: AudioBandLevels) {
        audioLevel = level
        bandLevels = bands
    }

    /// Everything settled so far as one string, one paragraph per line. This is
    /// the checkpoint-contract view and the test view. It carries no names,
    /// because it has to stay equal to what the durable checkpoint holds.
    var liveTranscriptText: String {
        liveSpans.filter(\.isText).map(\.text).joined(separator: "\n")
    }

    /// The reader's view: one block per turn, headed by the speaker name, with
    /// dropped-speech markers spelled out. This is what Copy puts on the
    /// pasteboard and what the sheet exposes as its accessibility value.
    /// `liveTranscriptText` is deliberately not used for either.
    var liveTranscriptForCopy: String {
        liveTranscriptForCopy(locale: .current)
    }

    /// The copy view in one explicit locale. The property above reads the
    /// system locale; a caller that knows the app's selected interface locale
    /// passes it here instead, because the two can differ.
    func liveTranscriptForCopy(locale: Locale) -> String {
        if let cache = copyTextCache, cache.localeIdentifier == locale.identifier {
            return cache.text
        }
        let text = buildLiveTranscriptForCopy(locale: locale)
        copyTextCache = (localeIdentifier: locale.identifier, text: text)
        return text
    }

    private func buildLiveTranscriptForCopy(locale: Locale) -> String {
        var blocks: [String] = []
        var turnSpeaker: LiveSpeakerRef?
        var turnLines: [String] = []

        func flushTurn() {
            guard let speaker = turnSpeaker, !turnLines.isEmpty else {
                turnSpeaker = nil
                turnLines = []
                return
            }
            blocks.append(([Self.speakerName(for: speaker, locale: locale)] + turnLines).joined(separator: "\n"))
            turnSpeaker = nil
            turnLines = []
        }

        for span in liveSpans {
            switch span.kind {
            case .text:
                if turnSpeaker?.key != span.speaker.key { flushTurn() }
                turnSpeaker = span.speaker
                turnLines.append(span.text)
            case .droppedSpeech:
                flushTurn()
                blocks.append(Self.droppedSpeechText(for: span.speaker, locale: locale))
            }
        }
        flushTurn()
        return blocks.joined(separator: "\n\n")
    }

    /// The name one live speaker is shown under. Below the named tier the label
    /// names the channel, not the people on it: the system channel can carry
    /// several voices and the app has not counted them.
    ///
    /// `You` and `Speaker %d` come from the finished transcript's rule, so the
    /// live sheet and the finished transcript can never disagree about them. Two
    /// things are live-only: a promoted name outranks its slot number, because a
    /// header that reverts to `Speaker 2` after showing `Dana` is worse than
    /// either alone, and an unattributed channel reads `Call audio` rather than
    /// the finished transcript's `Speaker`.
    static func speakerName(for speaker: LiveSpeakerRef, locale: Locale) -> String {
        if let displayName = speaker.displayName, !displayName.isEmpty { return displayName }
        guard speaker.isCurrentUser || speaker.slotNumber != nil else {
            return localized("Call audio", locale: locale)
        }
        return TranscriptSegmentPresentation.speakerName(
            isCurrentUser: speaker.isCurrentUser,
            speakerNumber: speaker.slotNumber,
            speakerLabel: nil,
            locale: locale
        )
    }

    /// What a dropped-speech marker reads. It says where the words went, so a
    /// reader never takes a transcript with a hole in it as continuous.
    static func droppedSpeechText(for speaker: LiveSpeakerRef, locale: Locale) -> String {
        speaker.isCurrentUser
            ? localized("You spoke here. The finished note has it.", locale: locale)
            : localized("Someone else spoke here. The finished note has it.", locale: locale)
    }

    func updateLiveSpans(_ spans: [LiveTranscriptSpan]) {
        guard liveSpans != spans else { return }
        liveSpans = spans
        copyTextCache = nil
    }

    /// Says that this capture records the call but only the microphone has ever
    /// reached the live engine, so the live view can say where the rest went.
    func setLiveTranscriptMicrophoneOnly(_ isMicrophoneOnly: Bool) {
        guard isLiveTranscriptMicrophoneOnly != isMicrophoneOnly else { return }
        isLiveTranscriptMicrophoneOnly = isMicrophoneOnly
    }

    /// Records what the live speaker labels are doing.
    func setLiveSpeakerLabelStatus(_ status: LiveSpeakerLabelStatus) {
        guard liveSpeakerLabelStatus != status else { return }
        liveSpeakerLabelStatus = status
    }

    /// Why the last speaker-model download from the note page's banner failed.
    ///
    /// The banner is the surface the reader pressed, so it is the surface that
    /// owes them the reason. Without this the progress bar disappears and the
    /// same banner comes back saying nothing new.
    func setLiveSpeakerDownloadFailure(_ message: String?) {
        guard liveSpeakerDownloadFailure != message else { return }
        liveSpeakerDownloadFailure = message
    }

    /// Clears a setup fault once the models behind it are on disk.
    ///
    /// The labels stay off for the rest of this capture: nothing is loaded from
    /// the capture path, and a half-written bundle is exactly what that rule
    /// exists to keep out. The banner goes because its download was taken.
    func clearLiveSpeakerSetupIssue() {
        liveSpeakerDownloadFailure = nil
        switch liveSpeakerLabelStatus {
        case .modelMissing, .loadFailed:
            liveSpeakerLabelStatus = .off
        case .off, .running, .paused:
            break
        }
    }

    /// Says that every diarizer slot is now in use.
    func markLiveSpeakerSlotCapacityReached() {
        guard !isLiveSpeakerSlotCapacityReached else { return }
        isLiveSpeakerSlotCapacityReached = true
    }

    /// Says whether finalize will run the offline speaker pass for this capture.
    func setOfflineSpeakerPassScheduled(_ isScheduled: Bool) {
        guard isOfflineSpeakerPassScheduled != isScheduled else { return }
        isOfflineSpeakerPassScheduled = isScheduled
    }

    /// Records the unsettled tail. Committed text arrives on its own path, so a
    /// tentative update never rewrites what was already settled.
    func updateLiveTentative(_ tentative: LiveTentativeSpan?) {
        guard liveTentative != tentative else { return }
        liveTentative = tentative
    }

    func markLiveTranscriptDegraded() {
        isLiveTranscriptDegraded = true
    }

    func beginFinalizing(_ stage: FinalizationStage) {
        phase = .finalizing(stage)
        audioLevel = 0
        bandLevels = .zero
        // Nothing is pending once the microphone is closed: the engine's last
        // words either committed or never existed.
        liveTentative = nil
    }

    func beginEnhancing() {
        phase = .enhancing
        enhancementFailureMessage = nil
    }

    /// Records why the enhanced panel is missing. The capture is unaffected: the
    /// typed notes and the transcript stay exactly as they were.
    func recordEnhancementFailure(_ message: String) {
        enhancementFailureMessage = message
    }

    func clearEnhancementFailure(for sessionID: UUID) {
        guard self.sessionID == sessionID else { return }
        enhancementFailureMessage = nil
    }

    func complete() {
        phase = .completed
        audioLevel = 0
        bandLevels = .zero
    }

    func fail(_ message: String) {
        phase = .failed(message)
        audioLevel = 0
        bandLevels = .zero
    }

    /// Returns to idle without clearing which note the capture wrote to, so the
    /// note page can stay open on the note that was just recorded.
    func reset() {
        phase = .idle
        sessionID = nil
        startedAt = nil
        audioLevel = 0
        bandLevels = .zero
        liveSpans = []
        copyTextCache = nil
        liveTentative = nil
        isLiveTranscriptDegraded = false
        isLiveTranscriptMicrophoneOnly = false
        liveSpeakerLabelStatus = .off
        liveSpeakerDownloadFailure = nil
        isLiveSpeakerSlotCapacityReached = false
        isOfflineSpeakerPassScheduled = false
        enhancementFailureMessage = nil
    }
}
