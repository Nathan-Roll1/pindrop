//
//  StreamingRefinementCoordinator.swift
//  PindropSpeech
//
//  Created on 2026-04-16.
//  Phase 2 rewrite on 2026-04-17: committed/tentative split with LocalAgreement-2.
//
//  Sits between streaming transcription callbacks (from TranscriptionService) and the
//  output sink. Maintains a committed/tentative split of the running transcript:
//
//    - `committedText` grows monotonically. Once a chunk is committed, the text visible in
//      the user's target app for that chunk never changes.
//    - `tentativeTail` is the cleaned form of whatever the engine has emitted since the last
//      commit boundary. It can be replaced freely on each partial.
//    - Displayed text = `committedText + tentativeTail` (trimmed at the outer edges).
//
//  # Commit rules
//
//    - LocalAgreement-2: when the last two cumulative partials share a token-prefix of
//      length N, every token that is >= K=2 positions back from the trailing token of the
//      current partial is safe to commit. This is the textbook streaming-stability rule
//      shared by Whisper-Streaming and Google's Partial Rewriting work.
//    - Sentence boundary: if the last agreed token ends in `.`, `?`, or `!`, commit the
//      full agreement regardless of K: punctuation is a strong stability signal.
//    - Idle commit: if no new partial arrives within `idleCommitNanoseconds`, commit
//      the current tentative tail wholesale. Covers the end-of-thought case where the
//      user pauses mid-utterance without EOU firing.
//    - Final (EOU): the full emitted text is committed unconditionally.
//
//  # Deterministic cleanup
//
//  `DeterministicTranscriptCleaner` is applied to each chunk at commit time and to the
//  tentative tail each time it is recomputed. Committed text is never re-cleaned, so
//  cleanup rules that change context-dependent output (e.g. sentence-case) do not produce
//  visible churn.
//
//  Live LLM refinement has been removed. Post-stop holistic enhancement remains a host
//  concern outside this coordinator.
//

import Foundation
import PindropCore

// MARK: - Protocols

@MainActor
public protocol StreamingRefinementOutputSink: AnyObject {
    func beginStreamingInsertion()
    /// Push the latest committed/tentative split to the sink. The composed display string
    /// is `StreamingRefinementCoordinator.composeDisplay(committed:tentative:)`: sinks
    /// that only need one string should compose with that helper so display semantics
    /// stay identical everywhere.
    func updateStreamingInsertion(committed: String, tentative: String) async throws
    func finishStreamingInsertion(finalText: String, appendTrailingSpace: Bool) async throws
    /// Abort the session and discard any in-flight display state. Nothing is ever
    /// inserted into the target app before `finishStreamingInsertion`, so there is no
    /// text to remove.
    func cancelStreamingInsertion() async
}

/// Receives cumulative text after the coordinator has committed a stable prefix. Tentative
/// text is never reported.
@MainActor
public protocol StreamingRefinementCommitObserver: AnyObject {
    /// `committedText` stays the append-only cumulative string the durable
    /// checkpoint holds. `spans` is that same text cut into paragraphs with the
    /// speaker each one was attributed to, plus any dropped-speech markers.
    ///
    /// The text spans are *derived*: they are `committedText` split on "\n",
    /// with speaker and timing metadata attached per index. They cannot drift
    /// from the checkpoint string, because they are not stored separately.
    /// The exact invariant, including the trailing boundary the artifact path
    /// appends, is:
    ///
    ///     committedText == spans.filter(\.isText).map(\.text)
    ///                           .joined(separator: "\n")
    ///                      + (isParagraphOpen ? "" : "\n")
    ///
    /// `spans` is empty for a session begun with
    /// `preservesArtifactParagraphs: false`, which is every dictation session.
    /// Dictation has one speaker and no paragraph structure to carry.
    ///
    /// `reachedEngineBoundary` is true only when this commit closed a paragraph
    /// at a boundary the engine produced itself. It is what says a pending
    /// channel handover may be applied now. A label-only change and an
    /// app-written boundary both report false, because the engine's accumulator
    /// is untouched by either and splicing a channel there would put two voices
    /// inside one decoded chunk.
    func streamingRefinementCoordinator(
        _ coordinator: StreamingRefinementCoordinator,
        didCommitText committedText: String,
        spans: [LiveTranscriptSpan],
        reachedEngineBoundary: Bool
    )
}

// MARK: - Coordinator

@MainActor
public final class StreamingRefinementCoordinator {

    /// Bounded wait after session stop for the last-in-flight work to finish before we
    /// finalize. With live refinement removed, nothing is typically in flight here: kept
    /// in the API for call-site stability.
    public nonisolated static let defaultStopWaitNanoseconds: UInt64 = 500_000_000  // 500 ms

    /// How long after the last partial arrives before we promote the current tentative
    /// tail to committedText wholesale. Keeps the "end of thought" feel of iOS dictation
    /// while letting paused speech solidify quickly: 2s read as laggy in practice.
    public nonisolated static let defaultIdleCommitNanoseconds: UInt64 = 1_200_000_000  // 1.2 s

    /// LocalAgreement-N parameter. K=2: commit a token once it has been agreed on across
    /// two partials AND there are at least two newer tokens past it.
    public static let localAgreementK: Int = 2

    private weak var outputSink: StreamingRefinementOutputSink?
    private weak var commitObserver: StreamingRefinementCommitObserver?
    private var preservesArtifactParagraphs = false
    private let cleaner: DeterministicTranscriptCleaner
    private let stopWaitNanoseconds: UInt64
    private let idleCommitNanoseconds: UInt64

    // MARK: Session state

    private var isSessionActive = false

    /// Latest cumulative raw transcript observed from the engine. Never trimmed on the way
    /// in: we need the original whitespace to correctly extract committed/tentative
    /// slices.
    private var rawCumulative = ""

    /// Previous partial we observed, used as the "prior" side of LocalAgreement-2.
    private var previousPartial = ""

    /// Number of leading characters of `rawCumulative` that have been committed.
    /// Monotonically non-decreasing within a session.
    private var committedRawLength = 0

    /// Cleaned, user-visible committed text. Grows by appending cleaned chunks. Never
    /// mutated once appended.
    private var committedText = ""

    /// Cleaned tentative tail: derived fresh from `rawCumulative[committedRawLength...]`
    /// on each partial. Replaced wholesale.
    private var tentativeTail = ""

    /// Last string we handed to the output sink. Used to suppress redundant updates.
    private var currentlyDisplayed = ""

    /// The two halves exactly as the sink last received them.
    ///
    /// The composed display is not enough to decide whether the sink is up to
    /// date. Promoting the tentative tail wholesale (idle commit, stop drain)
    /// leaves the composition byte-identical while the split moves, and a sink
    /// that draws the two halves in separate places would keep the old tail
    /// beside the same words in the committed half. That is the last few words
    /// appearing twice the moment a person stops talking.
    private var deliveredCommitted = ""
    private var deliveredTentative = ""

    /// Last committed string delivered to the observer. Kept separately from display state
    /// because display updates may contain tentative text.
    private var lastObservedCommittedText = ""

    // MARK: Live attribution

    /// What one committed paragraph is, apart from its characters.
    ///
    /// The characters are never held here. A span's text is cut out of
    /// `committedText` at read time, which is what keeps the derived spans and
    /// the durable checkpoint from ever disagreeing.
    private struct SpanMetadata {
        let id: Int
        var speaker: LiveSpeakerRef
        var startOffset: TimeInterval
        var duration: TimeInterval
        var boundaryReason: LiveTurnBoundaryReason
    }

    /// One dropped-speech marker and where it belongs in paragraph order.
    ///
    /// Ordered by the paragraph count at the moment it was recorded rather than
    /// by `startOffset`: Phase 1 has no clock for a text span, so commit
    /// ordering is the only ordering that is exact.
    private struct DroppedMarker {
        var span: LiveTranscriptSpan
        let paragraphIndex: Int
    }

    /// One per committed paragraph, in paragraph order.
    private var spanMetadata: [SpanMetadata] = []
    private var droppedMarkers: [DroppedMarker] = []
    private var currentSpeaker: LiveSpeakerRef = .currentUser
    /// Capture time the open paragraph started at. Phase 1 learns a capture time
    /// only from a dropped-speech interval, so it moves only there.
    private var currentSpanStartCaptureTime: TimeInterval = 0
    /// The speaker the next paragraph adopts, set by `markBoundary`.
    private var pendingSpeaker: LiveSpeakerRef?
    private var nextSpanID = 0

    /// Sleeps for `idleCommitNanoseconds` after the last partial and commits the tentative
    /// tail if not cancelled.
    private var idleCommitTask: Task<Void, Never>?

    // MARK: Metrics

    private var stabilityMetrics = StreamingStabilityMetrics()
    private var sessionNumber = 0

    public init(
        cleaner: DeterministicTranscriptCleaner = DeterministicTranscriptCleaner(),
        stopWaitNanoseconds: UInt64 = StreamingRefinementCoordinator.defaultStopWaitNanoseconds,
        idleCommitNanoseconds: UInt64 =
            StreamingRefinementCoordinator.defaultIdleCommitNanoseconds
    ) {
        self.cleaner = cleaner
        self.stopWaitNanoseconds = stopWaitNanoseconds
        self.idleCommitNanoseconds = idleCommitNanoseconds
    }

    // MARK: - Session control

    /// Starts a new session. When an output sink is supplied, the coordinator drives its
    /// streaming insertion lifecycle; artifact-only callers can omit it and observe only
    /// stable, cumulative committed text through `commitObserver`.
    public func beginSession(
        outputSink: StreamingRefinementOutputSink? = nil,
        commitObserver: StreamingRefinementCommitObserver? = nil,
        preservesArtifactParagraphs: Bool = false,
        initialSpeaker: LiveSpeakerRef = .currentUser
    ) {
        self.outputSink = outputSink
        self.commitObserver = commitObserver
        self.preservesArtifactParagraphs = preservesArtifactParagraphs
        spanMetadata.removeAll()
        droppedMarkers.removeAll()
        currentSpeaker = initialSpeaker
        currentSpanStartCaptureTime = 0
        pendingSpeaker = nil
        nextSpanID = 0
        isSessionActive = true
        rawCumulative = ""
        previousPartial = ""
        committedRawLength = 0
        committedText = ""
        tentativeTail = ""
        currentlyDisplayed = ""
        deliveredCommitted = ""
        deliveredTentative = ""
        lastObservedCommittedText = ""
        idleCommitTask?.cancel()
        idleCommitTask = nil
        stabilityMetrics.reset()
        sessionNumber += 1
        outputSink?.beginStreamingInsertion()
        Log.transcription.debug("StreamingRefinement: session begin (v2)")
    }

    /// Handle a non-final cumulative partial from the transcriber. Updates internal state,
    /// advances the LocalAgreement-2 commit boundary if possible, and pushes the newly
    /// composed display to the output sink.
    public func ingestPartial(_ text: String) async {
        guard isSessionActive else { return }
        rawCumulative = text
        stabilityMetrics.recordPartial(text)
        advanceCommitBoundary(using: text)
        previousPartial = text
        restartIdleCommitTimer()
        await applyCurrentDisplay()
    }

    /// Handle a finalized utterance from the transcriber. EOU is authoritative:
    /// the entire text becomes committed immediately. Post-EOU partials continue
    /// extending `rawCumulative`, so we leave `rawCumulative` and `previousPartial` in place
    /// so LocalAgreement-2 can keep working against a sensible prior.
    public func ingestFinal(_ text: String) async {
        guard isSessionActive else { return }
        idleCommitTask?.cancel()
        idleCommitTask = nil
        guard !text.isEmpty else {
            // Empty EOU: clear the in-flight state without touching committedText.
            rawCumulative = ""
            committedRawLength = 0
            previousPartial = ""
            tentativeTail = ""
            await applyCurrentDisplay()
            return
        }
        rawCumulative = text
        stabilityMetrics.recordPartial(text)
        commitRawUpTo(
            charOffset: text.count,
            reason: "EOU-final",
            endsArtifactParagraph: .endOfUtterance
        )
        previousPartial = text
        await applyCurrentDisplay()
    }

    /// Wait briefly, then commit anything still tentative and return the final display
    /// text. Caller is responsible for calling `finishStreamingInsertion` on the sink if it
    /// needs to do post-processing (dictionary replacements etc.) first.
    @discardableResult
    public func awaitFinalTextAndDrain() async -> String {
        guard isSessionActive else { return currentlyDisplayed }
        idleCommitTask?.cancel()
        idleCommitTask = nil
        if committedRawLength < rawCumulative.count {
            commitRawUpTo(charOffset: rawCumulative.count, reason: "drain")
            await applyCurrentDisplay()
        }
        return currentlyDisplayed
    }

    /// Convenience: drains then calls `finishStreamingInsertion` on the sink.
    @discardableResult
    public func finishSession(appendTrailingSpace: Bool) async throws -> String {
        let finalText = await awaitFinalTextAndDrain()
        defer { endSession() }
        if let sink = outputSink, isSessionActive {
            try await sink.finishStreamingInsertion(
                finalText: finalText,
                appendTrailingSpace: appendTrailingSpace
            )
        }
        return finalText
    }

    /// Marks the session inactive. Safe to call multiple times. Emits the one-line
    /// stability summary the first time called for an active session.
    public func endSession() {
        let wasActive = isSessionActive
        isSessionActive = false
        idleCommitTask?.cancel()
        idleCommitTask = nil
        if wasActive {
            stabilityMetrics.recordFinal(currentlyDisplayed)
            let summary = stabilityMetrics.summaryLine(sessionNumber: sessionNumber)
            Log.transcription.info("\(summary)")
        }
        clearSessionDependencies()
    }

    /// Drop the session and ask the sink to cancel its streaming insertion.
    public func cancelSession() async {
        guard isSessionActive else { return }
        idleCommitTask?.cancel()
        idleCommitTask = nil
        isSessionActive = false
        let sink = outputSink
        clearSessionDependencies()
        if let sink {
            await sink.cancelStreamingInsertion()
        }
    }

    private func clearSessionDependencies() {
        outputSink = nil
        commitObserver = nil
        lastObservedCommittedText = ""
    }

    // MARK: - LocalAgreement-2

    private func advanceCommitBoundary(using newPartial: String) {
        let newTokens = StreamingTokenizer.tokenize(newPartial)
        guard !newTokens.isEmpty else { return }

        let previousTokens = StreamingTokenizer.tokenize(previousPartial)
        let agreementCount = StreamingTokenizer.commonTokenPrefix(newTokens, previousTokens)
        guard agreementCount > 0 else { return }

        let lastAgreedEndsInSentence =
            StreamingTokenizer.endsWithSentenceTerminator(newTokens[agreementCount - 1])

        let commitTokenCount: Int
        if lastAgreedEndsInSentence {
            commitTokenCount = agreementCount
        } else {
            commitTokenCount = max(0, agreementCount - Self.localAgreementK)
        }
        guard commitTokenCount > 0 else { return }

        let targetEndOffset = newTokens[commitTokenCount - 1].endCharOffset
        if targetEndOffset > committedRawLength {
            commitRawUpTo(charOffset: targetEndOffset, reason: "LocalAgreement-2")
        }
    }

    /// Commit raw characters from `committedRawLength..<charOffset`, running them through
    /// the deterministic cleaner with the correct utterance-start hint before appending to
    /// `committedText`. No-op if there is nothing new to commit.
    private func commitRawUpTo(
        charOffset: Int,
        reason: String,
        endsArtifactParagraph: LiveTurnBoundaryReason? = nil
    ) {
        let clamped = min(max(charOffset, committedRawLength), rawCumulative.count)
        guard clamped > committedRawLength else {
            if let endsArtifactParagraph {
                appendArtifactParagraphBoundaryIfNeeded(endsArtifactParagraph)
            }
            return
        }

        let startIndex = rawCumulative.index(
            rawCumulative.startIndex, offsetBy: committedRawLength
        )
        let endIndex = rawCumulative.index(rawCumulative.startIndex, offsetBy: clamped)
        let rawChunk = String(rawCumulative[startIndex..<endIndex])

        let startOfUtterance =
            committedText.isEmpty
            || committedText.last?.isNewline == true
            || Self.endsWithSentenceTerminator(committedText)
        var cleanedChunk = cleaner.clean(
            rawChunk,
            startOfUtterance: startOfUtterance,
            priorWord: Self.lastWord(of: committedText)
        )
        if committedText.last?.isNewline == true {
            cleanedChunk = String(cleanedChunk.drop(while: \Character.isWhitespace))
        }

        committedText = Self.appendingWithSafeBoundary(
            cleanedChunk,
            to: committedText
        )
        syncSpanMetadata()
        if let endsArtifactParagraph {
            appendArtifactParagraphBoundaryIfNeeded(endsArtifactParagraph, notifyObserver: false)
        }
        committedRawLength = clamped
        notifyCommitObserverIfNeeded(
            reachedEngineBoundary: endsArtifactParagraph?.isEngineProduced ?? false
        )

        Log.transcription.debug(
            "StreamingRefinement: committed +\(cleanedChunk.count) chars via \(reason) — committed=\(self.committedText.count), committedRawLength=\(self.committedRawLength)/\(self.rawCumulative.count)"
        )
    }

    private func recomputeTentativeTail() {
        guard committedRawLength <= rawCumulative.count else {
            tentativeTail = ""
            return
        }
        let startIndex = rawCumulative.index(
            rawCumulative.startIndex, offsetBy: committedRawLength
        )
        let rawTail = String(rawCumulative[startIndex...])
        let startOfUtterance =
            committedText.isEmpty
            || committedText.last?.isNewline == true
            || Self.endsWithSentenceTerminator(committedText)
        tentativeTail = cleaner.clean(
            rawTail,
            startOfUtterance: startOfUtterance,
            priorWord: Self.lastWord(of: committedText)
        )
        if committedText.last?.isNewline == true {
            tentativeTail = String(tentativeTail.drop(while: \Character.isWhitespace))
        }
    }

    /// Closes the open artifact paragraph, if there is one, and records why it
    /// ended. Returns true when a boundary was actually appended.
    @discardableResult
    private func appendArtifactParagraphBoundaryIfNeeded(
        _ reason: LiveTurnBoundaryReason,
        notifyObserver: Bool = true
    ) -> Bool {
        guard preservesArtifactParagraphs,
              !committedText.isEmpty,
              committedText.last?.isNewline != true
        else {
            return false
        }
        committedText.append("\n")
        if !spanMetadata.isEmpty {
            spanMetadata[spanMetadata.count - 1].boundaryReason = reason
        }
        if notifyObserver {
            notifyCommitObserverIfNeeded(reachedEngineBoundary: reason.isEngineProduced)
        }
        return true
    }

    // MARK: - Live attribution

    /// Closes the current paragraph at the point already committed, and points
    /// everything that follows at `speaker`. Safe to call when nothing is
    /// pending: it still records the boundary so the next commit opens a new
    /// span.
    ///
    /// Phase 1 calls this only at a boundary the engine itself produced (an
    /// end-of-utterance final or an idle commit), so "everything committed
    /// belongs to the outgoing speaker" is exact by ordering. No clock decides
    /// that, and none is consulted here.
    ///
    /// `startCaptureTime` is only what the new turn's header shows a reader who
    /// scrolls back: the capture time its channel took the engine at. It never
    /// decides which speaker a character belongs to. Left nil, the new turn
    /// keeps the offset the previous one opened at, which is what the first turn
    /// of a capture wants.
    public func markBoundary(
        _ reason: LiveTurnBoundaryReason,
        speaker: LiveSpeakerRef,
        at startCaptureTime: TimeInterval? = nil
    ) async {
        guard isSessionActive, preservesArtifactParagraphs else { return }
        let closed = appendArtifactParagraphBoundaryIfNeeded(reason)
        pendingSpeaker = speaker
        if let startCaptureTime {
            // Monotonic: a span never opens before the one above it closed.
            currentSpanStartCaptureTime = max(currentSpanStartCaptureTime, startCaptureTime)
        }
        if closed {
            await applyCurrentDisplay()
        } else if !spanMetadata.isEmpty, committedText.hasSuffix("\n") {
            // The engine's own boundary already closed this paragraph, which is
            // the only place Phase 1 applies a handover. The channel change is
            // the later fact and it is the one that says why what follows is a
            // new turn rather than another paragraph of the same one.
            spanMetadata[spanMetadata.count - 1].boundaryReason = reason
            notifyCommitObserverOfSpanChange()
        }
    }

    /// Records speech the live engine never heard. Emits a `.droppedSpeech` span
    /// attributed to `speaker`, carrying no text, between the surrounding
    /// paragraphs. Does not touch `committedText`.
    public func markDroppedSpeech(
        speaker: LiveSpeakerRef,
        startOffset: TimeInterval,
        duration: TimeInterval
    ) async {
        guard isSessionActive, preservesArtifactParagraphs else { return }
        // The marker has to sit where the speech was, so the paragraph that was
        // open while the other channel talked ends here.
        let closed = appendArtifactParagraphBoundaryIfNeeded(.crossTalkDropped, notifyObserver: false)
        droppedMarkers.append(
            DroppedMarker(
                span: LiveTranscriptSpan(
                    id: takeSpanID(),
                    kind: .droppedSpeech,
                    speaker: speaker,
                    text: "",
                    startOffset: startOffset,
                    duration: duration,
                    boundaryReason: .crossTalkDropped
                ),
                paragraphIndex: spanMetadata.count
            )
        )
        currentSpanStartCaptureTime = max(currentSpanStartCaptureTime, startOffset + duration)
        notifyCommitObserverOfSpanChange()
        if closed {
            await applyCurrentDisplay()
        }
    }

    /// Re-points every span whose speaker key is `key` at `replacement`.
    /// Text is never changed, only the label. Used by Phase 2 promotion.
    ///
    /// Precondition: `key` is a slot key. Channel-tier keys are rejected, because
    /// one channel key can cover several people.
    public func relabelSpeaker(slotKey key: String, to replacement: LiveSpeakerRef) async {
        guard isSessionActive, preservesArtifactParagraphs else { return }
        guard key != LiveSpeakerRef.currentUser.key, key != LiveSpeakerRef.systemChannel.key else {
            Log.transcription.warning(
                "StreamingRefinement: refused to relabel channel key \(key); one channel covers several people"
            )
            return
        }

        var changed = false
        for index in spanMetadata.indices where spanMetadata[index].speaker.key == key {
            spanMetadata[index].speaker = replacement
            changed = true
        }
        for index in droppedMarkers.indices where droppedMarkers[index].span.speaker.key == key {
            let existing = droppedMarkers[index].span
            droppedMarkers[index].span = LiveTranscriptSpan(
                id: existing.id,
                kind: existing.kind,
                speaker: replacement,
                text: existing.text,
                startOffset: existing.startOffset,
                duration: existing.duration,
                boundaryReason: existing.boundaryReason
            )
            changed = true
        }
        if currentSpeaker.key == key {
            currentSpeaker = replacement
            changed = true
        }
        if pendingSpeaker?.key == key {
            pendingSpeaker = replacement
            changed = true
        }
        guard changed else { return }
        notifyCommitObserverOfSpanChange()
    }

    /// The committed text cut into paragraphs, with the dropped-speech markers
    /// merged back in at the paragraph they were recorded between.
    ///
    /// Nothing here is stored. Deriving the text at read time is what makes the
    /// invariant in `StreamingRefinementCommitObserver` true by construction
    /// instead of by discipline.
    private func currentSpans() -> [LiveTranscriptSpan] {
        guard preservesArtifactParagraphs else { return [] }
        let paragraphs = committedParagraphs()
        var spans: [LiveTranscriptSpan] = []
        spans.reserveCapacity(paragraphs.count + droppedMarkers.count)
        var markerIndex = 0
        for (index, paragraph) in paragraphs.enumerated() {
            while markerIndex < droppedMarkers.count,
                  droppedMarkers[markerIndex].paragraphIndex <= index {
                spans.append(droppedMarkers[markerIndex].span)
                markerIndex += 1
            }
            guard index < spanMetadata.count else { break }
            let metadata = spanMetadata[index]
            spans.append(
                LiveTranscriptSpan(
                    id: metadata.id,
                    kind: .text,
                    speaker: metadata.speaker,
                    text: paragraph,
                    startOffset: metadata.startOffset,
                    duration: metadata.duration,
                    boundaryReason: metadata.boundaryReason
                )
            )
        }
        while markerIndex < droppedMarkers.count {
            spans.append(droppedMarkers[markerIndex].span)
            markerIndex += 1
        }
        return spans
    }

    /// `committedText` split on the paragraph boundaries the artifact path
    /// appends. The trailing boundary produces no empty last paragraph.
    private func committedParagraphs() -> [String] {
        guard !committedText.isEmpty else { return [] }
        var paragraphs = committedText.components(separatedBy: "\n")
        if committedText.hasSuffix("\n") { paragraphs.removeLast() }
        return paragraphs
    }

    /// Keeps one metadata row per committed paragraph. Called after every append
    /// to `committedText`, before any boundary is added.
    private func syncSpanMetadata() {
        guard preservesArtifactParagraphs else { return }
        let paragraphCount = committedParagraphs().count
        while spanMetadata.count < paragraphCount {
            if let pending = pendingSpeaker {
                currentSpeaker = pending
                pendingSpeaker = nil
            }
            spanMetadata.append(
                SpanMetadata(
                    id: takeSpanID(),
                    speaker: currentSpeaker,
                    startOffset: currentSpanStartCaptureTime,
                    // Phase 1 has no clock: the engine reports no fed watermark
                    // yet, so a text span's length is unknown until Phase 2.
                    duration: 0,
                    // What the open paragraph would end as if the capture stopped
                    // now. Every other reason overwrites it when it closes.
                    boundaryReason: .sessionEnd
                )
            )
        }
    }

    private func takeSpanID() -> Int {
        defer { nextSpanID += 1 }
        return nextSpanID
    }

    // MARK: - Idle commit timer

    private func restartIdleCommitTimer() {
        idleCommitTask?.cancel()
        guard idleCommitNanoseconds > 0 else { return }
        let delay = idleCommitNanoseconds
        idleCommitTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: delay)
            guard !Task.isCancelled, let self else { return }
            await self.handleIdleCommit()
        }
    }

    private func handleIdleCommit() async {
        guard isSessionActive else { return }
        idleCommitTask = nil
        guard committedRawLength < rawCumulative.count else {
            appendArtifactParagraphBoundaryIfNeeded(.idlePause)
            await applyCurrentDisplay()
            return
        }
        Log.transcription.debug(
            "StreamingRefinement: idle commit fired — committing tentative tail (\(self.rawCumulative.count - self.committedRawLength) raw chars)"
        )
        commitRawUpTo(
            charOffset: rawCumulative.count,
            reason: "idle",
            endsArtifactParagraph: .idlePause
        )
        await applyCurrentDisplay()
    }

    // MARK: - Display

    private func notifyCommitObserverIfNeeded(reachedEngineBoundary: Bool) {
        guard committedText != lastObservedCommittedText else { return }
        lastObservedCommittedText = committedText
        commitObserver?.streamingRefinementCoordinator(
            self,
            didCommitText: committedText,
            spans: currentSpans(),
            reachedEngineBoundary: reachedEngineBoundary
        )
    }

    /// Reports a change that moved the labels without moving one character, so
    /// the duplicate-text suppression above would otherwise swallow it. The
    /// engine flushed nothing here, so this can never carry a handover.
    private func notifyCommitObserverOfSpanChange() {
        lastObservedCommittedText = committedText
        commitObserver?.streamingRefinementCoordinator(
            self,
            didCommitText: committedText,
            spans: currentSpans(),
            reachedEngineBoundary: false
        )
    }

    private func applyCurrentDisplay() async {
        recomputeTentativeTail()
        let displayed = Self.composeDisplay(committed: committedText, tentative: tentativeTail)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let displayChanged = displayed != currentlyDisplayed
        // The sink is told about the split, so the split is what decides
        // whether it is stale. A commit that only moves the tail across the
        // boundary changes nothing about the composed text and everything
        // about who owns those words.
        let splitChanged = committedText != deliveredCommitted
            || tentativeTail != deliveredTentative
        guard displayChanged || splitChanged else { return }
        if displayChanged {
            // Stability is a fact about what the person reads, not about
            // bookkeeping, so a split-only update is not a display update.
            stabilityMetrics.recordDisplayUpdate(displayed)
            currentlyDisplayed = displayed
        }
        deliveredCommitted = committedText
        deliveredTentative = tentativeTail
        do {
            try await outputSink?.updateStreamingInsertion(
                committed: committedText,
                tentative: tentativeTail
            )
        } catch {
            Log.output.error(
                "Streaming refinement display update failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Helpers

    private static func endsWithSentenceTerminator(_ text: String) -> Bool {
        for character in text.reversed() {
            if character.isWhitespace { continue }
            return character == "." || character == "?" || character == "!"
        }
        return false
    }

    /// Compose the user-visible display string from the committed/tentative split. The
    /// single source of truth for how the two halves join: sinks, overlay views, and
    /// tests must all compose through this so display semantics stay identical.
    public static func composeDisplay(committed: String, tentative: String) -> String {
        appendingWithSafeBoundary(tentative, to: committed)
    }

    private static func appendingWithSafeBoundary(_ suffix: String, to prefix: String) -> String {
        guard !prefix.isEmpty, !suffix.isEmpty else { return prefix + suffix }
        guard let last = prefix.last, let first = suffix.first else { return prefix + suffix }
        if last.isWhitespace || first.isWhitespace { return prefix + suffix }
        if isPunctuationThatAttachesToPreviousWord(first) { return prefix + suffix }
        if isOpeningPunctuationThatAttachesToNextWord(last) { return prefix + suffix }
        if last.isLetter || last.isNumber, first.isLetter || first.isNumber {
            return prefix + " " + suffix
        }
        return prefix + suffix
    }

    private static func isPunctuationThatAttachesToPreviousWord(_ character: Character) -> Bool {
        ".,;:?!)]}".contains(character)
    }

    private static func isOpeningPunctuationThatAttachesToNextWord(_ character: Character) -> Bool {
        "([{".contains(character)
    }

    /// The last whitespace-delimited token of `text`, with trailing whitespace stripped.
    /// Returns nil when `text` has no word content. Used as the `priorWord` hint into
    /// `DeterministicTranscriptCleaner` so the spoken-punctuation rule can fire even when
    /// the trigger word ("period", "comma", "semicolon", ...) lands as the first token of
    /// a freshly-committed chunk while its antecedent lives in already-committed text.
    private static func lastWord(of text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let range = trimmed.rangeOfCharacter(from: .whitespaces, options: .backwards) {
            return String(trimmed[range.upperBound...])
        }
        return trimmed
    }
}

// MARK: - Tokenizer

/// Simple whitespace-delimited tokenizer that preserves per-token end offsets inside the
/// original string. Good enough for LocalAgreement-2's purposes on space-separated output.
public enum StreamingTokenizer {

    public struct Token: Equatable, Sendable {
        public let text: String
        public let startCharOffset: Int
        /// Offset of the first character NOT in this token, so `string[..<endCharOffset]`
        /// gives everything up through and including the token.
        public let endCharOffset: Int

        public init(text: String, startCharOffset: Int, endCharOffset: Int) {
            self.text = text
            self.startCharOffset = startCharOffset
            self.endCharOffset = endCharOffset
        }
    }

    public static func tokenize(_ text: String) -> [Token] {
        guard !text.isEmpty else { return [] }
        var tokens: [Token] = []
        var currentStart: Int? = nil
        var currentChars: [Character] = []

        for (offset, character) in text.enumerated() {
            if character.isWhitespace {
                if let start = currentStart {
                    tokens.append(
                        Token(
                            text: String(currentChars),
                            startCharOffset: start,
                            endCharOffset: offset
                        )
                    )
                    currentStart = nil
                    currentChars.removeAll(keepingCapacity: true)
                }
            } else {
                if currentStart == nil {
                    currentStart = offset
                }
                currentChars.append(character)
            }
        }
        if let start = currentStart {
            tokens.append(
                Token(
                    text: String(currentChars),
                    startCharOffset: start,
                    endCharOffset: text.count
                )
            )
        }
        return tokens
    }

    /// Number of leading tokens that are equal (case-sensitive) in both sequences.
    public static func commonTokenPrefix(_ a: [Token], _ b: [Token]) -> Int {
        var count = 0
        while count < a.count && count < b.count && a[count].text == b[count].text {
            count += 1
        }
        return count
    }

    public static func endsWithSentenceTerminator(_ token: Token) -> Bool {
        guard let last = token.text.last else { return false }
        return last == "." || last == "?" || last == "!"
    }
}
