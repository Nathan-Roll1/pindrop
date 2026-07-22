//
//  SpeakerDiarizer.swift
//  PindropSpeech
//
//  Created on 2026-01-30.
//  Extracted to PindropSpeech on 2026-07-22.
//
//  Diarization DTOs and the SpeakerDiarizer protocol live in PindropCore. This
//  file keeps a stable Speech-module import path for TranscriptionService and
//  engine factories without redeclaring Core types.
//

import Foundation
import PindropCore

// Core owns:
// - Speaker, SpeakerSegment, DiarizationResult
// - DiarizedTranscriptSegment, TranscriptionOutput
// - SpeakerDiarizerState, DiarizationMode, DiarizationOptions
// - SpeakerDiarizer protocol + default audioData/samples helpers
//
// Concrete adapters (FluidSpeakerDiarizer) live beside this file.
