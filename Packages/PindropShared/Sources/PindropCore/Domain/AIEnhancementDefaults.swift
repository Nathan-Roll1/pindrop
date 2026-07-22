//
//  AIEnhancementDefaults.swift
//  PindropCore
//
//  Created on 2026-07-22.
//

import Foundation

/// Canonical English default prompts shared by settings, built-in preset matching,
/// and AI enhancement call sites. Bytes must stay stable across hosts.
public enum AIEnhancementDefaults: Sendable {
    /// Default transcription / general text enhancement prompt.
    /// Matches legacy `SettingsStore.Defaults.aiEnhancementPrompt` and
    /// `AIEnhancementService.defaultSystemPrompt`.
    public static let transcriptionPrompt =
        "You are a text enhancement assistant. Improve the grammar, punctuation, and formatting of the provided text while preserving its original meaning and tone. Return only the enhanced text without any additional commentary."

    /// Alias of `transcriptionPrompt` for call sites that historically used
    /// `AIEnhancementService.defaultSystemPrompt`.
    public static let systemPrompt = transcriptionPrompt

    /// Default note-body formatting prompt.
    /// Matches legacy `SettingsStore.Defaults.noteEnhancementPrompt`.
    public static let notePrompt = """
        You are a note formatting assistant. Transform the transcribed text into a well-structured note.

        Rules:
        - Fix grammar, punctuation, and spelling errors
        - For longer content (3+ paragraphs), add markdown formatting:
          - Use headers (## or ###) to organize sections
          - Use bullet points or numbered lists where appropriate
          - Use **bold** for emphasis on key terms
        - For shorter content, keep it simple with minimal formatting
        - Preserve the original meaning and tone
        - Do not add content that wasn't in the original
        - Return only the formatted note without any commentary
        """
}
