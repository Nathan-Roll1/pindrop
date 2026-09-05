//
//  OverlayStreamingSink.swift
//  Pindrop
//
//  Created on 2026-06-05.
//
//  StreamingRefinementOutputSink that renders the live transcript in Pindrop's own
//  floating-indicator overlay instead of typing into the target app. The target app
//  receives the final text exactly once, via a single atomic paste when the session
//  finishes — there is no live keystroke synthesis, no diffing, and nothing to undo
//  on cancel.
//
//  `StreamingSessionController` injects final output so the sink stays testable.
//  `OutputManager` pastes in direct-insert mode and copies in clipboard mode.
//

import Foundation
import PindropSpeech

@MainActor
final class OverlayStreamingSink: StreamingRefinementOutputSink {

    private let transcriptState: LiveTranscriptState
    private let finalOutput: @MainActor (
        String,
        @MainActor () throws -> Void
    ) async throws -> OutputManager.OutputResult
    private let onClipboardFallback: (@MainActor (OutputManager.OutputResult) -> Void)?

    private var nextGeneration: UInt64 = 0
    private var currentGeneration: UInt64?

    init(
        transcriptState: LiveTranscriptState,
        finalOutput: @escaping @MainActor (
            String,
            @MainActor () throws -> Void
        ) async throws -> OutputManager.OutputResult,
        onClipboardFallback: (@MainActor (OutputManager.OutputResult) -> Void)? = nil
    ) {
        self.transcriptState = transcriptState
        self.finalOutput = finalOutput
        self.onClipboardFallback = onClipboardFallback
    }

    func beginStreamingInsertion() {
        nextGeneration &+= 1
        currentGeneration = nextGeneration
        transcriptState.begin()
    }

    func updateStreamingInsertion(committed: String, tentative: String) async throws {
        transcriptState.update(committed: committed, tentative: tentative)
    }

    func finishStreamingInsertion(finalText: String, appendTrailingSpace: Bool) async throws {
        _ = try await finishStreamingInsertionReturningResult(
            finalText: finalText,
            appendTrailingSpace: appendTrailingSpace,
            ownerValidation: {}
        )
    }

    func finishStreamingInsertionReturningResult(
        finalText: String,
        appendTrailingSpace: Bool,
        ownerValidation: @escaping @MainActor () throws -> Void
    ) async throws -> OutputManager.OutputResult? {
        let generation = currentGeneration
        defer { endTranscript(for: generation) }
        guard !finalText.isEmpty else { return nil }

        let output = appendTrailingSpace ? finalText + " " : finalText
        let result = try await finalOutput(output, ownerValidation)
        if result.didCopyToClipboard {
            onClipboardFallback?(result)
        }
        return result
    }

    func cancelStreamingInsertion() async {
        endTranscript(for: currentGeneration)
    }

    private func endTranscript(for generation: UInt64?) {
        guard let generation, currentGeneration == generation else { return }
        currentGeneration = nil
        transcriptState.end()
    }
}
