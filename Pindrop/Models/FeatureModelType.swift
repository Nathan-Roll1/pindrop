//
//  FeatureModelType.swift
//  Pindrop
//
//  Created on 2026-01-30.
//
//  Presentation helpers for PindropSpeech.FeatureModelType.
//  Size, required-or-not, and repository folder mapping live in the package.
//

import Foundation
import PindropSpeech

extension FeatureModelType {
    var displayName: String {
        switch self {
        case .vad:
            return "Voice Activity Detection"
        case .diarization:
            return "Speaker Diarization"
        case .streaming:
            return "Streaming Transcription"
        }
    }

    var description: String {
        switch self {
        case .vad:
            return "Hears when you stop speaking, so a recorded note breaks into paragraphs"
        case .diarization:
            return "Identifies different speakers in recordings"
        case .streaming:
            return "Real-time transcription as you speak"
        }
    }

    var formattedSize: String {
        if sizeInMB >= 1000 {
            return String(format: "%.1f GB", Double(sizeInMB) / 1000.0)
        } else {
            return "\(sizeInMB) MB"
        }
    }

    var iconName: String {
        switch self {
        case .vad:
            return "waveform.badge.mic"
        case .diarization:
            return "person.2.wave.2"
        case .streaming:
            return "text.bubble"
        }
    }
}
