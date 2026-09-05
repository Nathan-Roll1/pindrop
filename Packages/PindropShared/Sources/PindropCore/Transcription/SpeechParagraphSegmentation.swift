//
//  SpeechParagraphSegmentation.swift
//  PindropCore
//
//  Created on 2026-08-22.
//
//  Paragraph breaks for a note nobody else spoke in.
//
//  A microphone-only capture has one speaker, so diarization has nothing to
//  separate and the whole chunk arrives as one unbroken block of prose. What a
//  reader actually wants back is where the person stopped talking: the pauses
//  are the paragraph breaks, and they are the only structure the audio offers.
//
//  Everything here is pure. It takes the speech stretches a voice activity
//  detector found and the text the batch engine produced, and it decides where
//  the text is cut. No model, no store, no view.
//

import Foundation

/// Where a single-speaker transcript breaks into paragraphs.
public enum SpeechParagraphSegmentation {

    /// How long the silence has to be before it reads as a paragraph break.
    ///
    /// Ordinary speech leaves 0.2s to 0.7s between sentences for breath, so a
    /// threshold under 0.8s would cut a new paragraph at every full stop. A
    /// person changing subject, checking a note, or thinking stops for longer
    /// than a second. 1.2s sits in the middle of the usable band: low enough to
    /// catch a real change of thought, high enough that normal sentence
    /// breathing keeps the paragraph together. Silero also pads the end of each
    /// speech stretch, which shortens every measured gap, so erring high would
    /// miss breaks the person can hear.
    public static let paragraphPauseThreshold: TimeInterval = 1.2

    /// The identifier written for the one speaker of a microphone-only capture.
    ///
    /// Paragraph spans are persisted in the same payload diarized spans use, so
    /// a reader needs no new shape and old payloads keep decoding. One speaker
    /// identifier across every span is what tells the reader these are pause
    /// breaks and not speaker turns: the transcript has exactly one speaker.
    public static let soloSpeakerIdentifier = "self"

    /// The label written beside `soloSpeakerIdentifier`. The interface resolves
    /// the shown name itself, so this is only the untranslated fallback.
    public static let soloSpeakerLabel = "You"

    /// One stretch of speech with silence on both sides of it.
    public struct SpeechInterval: Sendable, Equatable {
        public let startTime: TimeInterval
        public let endTime: TimeInterval

        public init(startTime: TimeInterval, endTime: TimeInterval) {
            self.startTime = startTime
            self.endTime = endTime
        }

        public var duration: TimeInterval {
            endTime - startTime
        }
    }

    /// The paragraph spans for one chunk of a single-speaker transcript, or nil
    /// when the chunk reads as one block.
    ///
    /// Nil is the normal answer, not a failure: a chunk with one uninterrupted
    /// stretch of speech, a chunk with no usable timings, and a chunk the
    /// detector could not measure all read exactly as they read before this
    /// existed. Callers persist nil as no payload at all.
    ///
    /// The returned spans satisfy what a transcript read demands of a segment
    /// payload: they are ordered, they do not overlap, they stay inside the
    /// chunk, and joining their text with single spaces gives the chunk text
    /// back. That is what lets one reader draw pause breaks and speaker turns
    /// without knowing which it has.
    public static func paragraphSegments(
        text: String,
        speechIntervals: [SpeechInterval],
        chunkDuration: TimeInterval,
        pauseThreshold: TimeInterval = paragraphPauseThreshold,
        speakerId: String = soloSpeakerIdentifier,
        speakerLabel: String = soloSpeakerLabel
    ) -> [DiarizedTranscriptSegment]? {
        let sentences = self.sentences(in: text)
        guard sentences.count > 1, chunkDuration.isFinite, chunkDuration > 0 else {
            return nil
        }

        let groups = paragraphGroups(
            in: speechIntervals,
            chunkDuration: chunkDuration,
            pauseThreshold: pauseThreshold
        )
        guard groups.count > 1 else {
            return nil
        }

        let assignments = assign(sentences: sentences, to: groups)
        let segments = spans(
            sentences: sentences,
            assignments: assignments,
            groups: groups,
            speakerId: speakerId,
            speakerLabel: speakerLabel
        )
        // One span is what the caller already had. Writing it would only add a
        // payload that says nothing.
        return segments.count > 1 ? segments : nil
    }

    /// Convenience for callers holding the detector's own segments. Only the
    /// times are read; the samples are never copied.
    public static func paragraphSegments(
        text: String,
        voiceSegments: [VoiceSegment],
        chunkDuration: TimeInterval,
        pauseThreshold: TimeInterval = paragraphPauseThreshold,
        speakerId: String = soloSpeakerIdentifier,
        speakerLabel: String = soloSpeakerLabel
    ) -> [DiarizedTranscriptSegment]? {
        paragraphSegments(
            text: text,
            speechIntervals: voiceSegments.map {
                SpeechInterval(startTime: $0.startTime, endTime: $0.endTime)
            },
            chunkDuration: chunkDuration,
            pauseThreshold: pauseThreshold,
            speakerId: speakerId,
            speakerLabel: speakerLabel
        )
    }

    // MARK: - Grouping

    /// Merges the speech stretches that are separated by less than one paragraph
    /// pause, so what comes back is one entry per paragraph of speech.
    static func paragraphGroups(
        in speechIntervals: [SpeechInterval],
        chunkDuration: TimeInterval,
        pauseThreshold: TimeInterval
    ) -> [SpeechInterval] {
        let usable = speechIntervals
            .filter { $0.startTime.isFinite && $0.endTime.isFinite && $0.endTime > $0.startTime }
            .map {
                SpeechInterval(
                    startTime: min(max($0.startTime, 0), chunkDuration),
                    endTime: min(max($0.endTime, 0), chunkDuration)
                )
            }
            .filter { $0.endTime > $0.startTime }
            .sorted { $0.startTime < $1.startTime }

        var groups: [SpeechInterval] = []
        for interval in usable {
            guard let last = groups.last else {
                groups.append(interval)
                continue
            }
            // Overlapping detector output is merged too: a gap that is not
            // positive is not a pause.
            if interval.startTime - last.endTime < pauseThreshold {
                groups[groups.count - 1] = SpeechInterval(
                    startTime: last.startTime,
                    endTime: max(last.endTime, interval.endTime)
                )
                continue
            }
            groups.append(interval)
        }
        return groups
    }

    // MARK: - Alignment

    /// Which paragraph group each sentence belongs to.
    ///
    /// The batch engines this app runs return a plain string for a chunk, with
    /// no word or segment timings to align against, so the honest fallback is
    /// the only method available: each sentence is placed by where its middle
    /// falls in the total speaking time. It is approximate. It is also stable,
    /// monotonic, and never invents a break the detector did not hear, which is
    /// what matters for a paragraph boundary. If an engine that returns word
    /// timings is ever wired into the batch path, replace this with the nearest
    /// pause to the real word boundary.
    static func assign(
        sentences: [String],
        to groups: [SpeechInterval]
    ) -> [Int] {
        let totalSpeech = groups.reduce(0) { $0 + $1.duration }
        let totalCharacters = sentences.reduce(0) { $0 + $1.count }
        guard totalSpeech > 0, totalCharacters > 0 else {
            return Array(repeating: 0, count: sentences.count)
        }

        var cumulativeSpeech: [TimeInterval] = []
        cumulativeSpeech.reserveCapacity(groups.count)
        var runningSpeech: TimeInterval = 0
        for group in groups {
            runningSpeech += group.duration
            cumulativeSpeech.append(runningSpeech)
        }

        var assignments: [Int] = []
        assignments.reserveCapacity(sentences.count)
        var consumedCharacters = 0
        var lowestAllowedGroup = 0
        for sentence in sentences {
            let midpoint = Double(consumedCharacters) + Double(sentence.count) / 2
            consumedCharacters += sentence.count
            let speechPosition = midpoint / Double(totalCharacters) * totalSpeech
            let index = cumulativeSpeech.firstIndex { speechPosition <= $0 } ?? (groups.count - 1)
            // Text never moves backwards, whatever the rounding says.
            let assigned = max(index, lowestAllowedGroup)
            lowestAllowedGroup = assigned
            assignments.append(assigned)
        }
        return assignments
    }

    /// Builds one span per paragraph that got text.
    ///
    /// A group nothing landed in is absorbed by the paragraph that follows it,
    /// so the spans stay contiguous and no stretch of the recording belongs to
    /// nothing.
    private static func spans(
        sentences: [String],
        assignments: [Int],
        groups: [SpeechInterval],
        speakerId: String,
        speakerLabel: String
    ) -> [DiarizedTranscriptSegment] {
        var textsByGroup: [Int: [String]] = [:]
        for (sentence, group) in zip(sentences, assignments) {
            textsByGroup[group, default: []].append(sentence)
        }

        var segments: [DiarizedTranscriptSegment] = []
        var pendingStart: TimeInterval?
        for (index, group) in groups.enumerated() {
            let start = pendingStart ?? group.startTime
            guard let texts = textsByGroup[index], !texts.isEmpty else {
                pendingStart = start
                continue
            }
            pendingStart = nil
            segments.append(
                DiarizedTranscriptSegment(
                    speakerId: speakerId,
                    speakerLabel: speakerLabel,
                    startTime: start,
                    endTime: group.endTime,
                    confidence: 1,
                    text: texts.joined(separator: " ")
                )
            )
        }

        // Trailing silence belongs to the last thing that was said.
        if pendingStart != nil, let last = segments.last, let final = groups.last {
            segments[segments.count - 1] = DiarizedTranscriptSegment(
                speakerId: last.speakerId,
                speakerLabel: last.speakerLabel,
                startTime: last.startTime,
                endTime: max(last.endTime, final.endTime),
                confidence: last.confidence,
                text: last.text
            )
        }
        return segments
    }

    // MARK: - Sentences

    /// Splits text at sentence ends, keeping the terminator with the sentence it
    /// closes. Text with no terminator stays one sentence.
    static func sentences(in text: String) -> [String] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        var sentences: [String] = []
        var current = ""

        func flush() {
            let value = current.trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.isEmpty { sentences.append(value) }
            current = ""
        }

        var index = trimmed.startIndex
        while index < trimmed.endIndex {
            let character = trimmed[index]
            index = trimmed.index(after: index)
            if character.isNewline {
                flush()
                continue
            }
            current.append(character)
            guard isTerminator(character) else { continue }
            // Runs of terminators ("?!") and a closing quote stay on the line.
            while index < trimmed.endIndex,
                  isTerminator(trimmed[index]) || isClosingMark(trimmed[index]) {
                current.append(trimmed[index])
                index = trimmed.index(after: index)
            }
            if index == trimmed.endIndex || trimmed[index].isWhitespace {
                flush()
            }
        }
        flush()
        return sentences.isEmpty ? [trimmed] : sentences
    }

    private static func isTerminator(_ character: Character) -> Bool {
        character == "." || character == "!" || character == "?" || character == "…"
    }

    private static func isClosingMark(_ character: Character) -> Bool {
        character == "\"" || character == "”" || character == "'" || character == "’"
            || character == ")"
    }
}
