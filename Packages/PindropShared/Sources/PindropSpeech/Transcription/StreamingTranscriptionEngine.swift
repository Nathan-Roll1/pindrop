//
//  StreamingTranscriptionEngine.swift
//  PindropSpeech
//
//  Created on 2026-01-30.
//  Extracted to PindropSpeech on 2026-07-22.
//
//  AVFoundation refinement of the Foundation-only streaming engine contract from
//  PindropCore. Result/state/callback types and the sample-array surface live in
//  Core; buffer processing stays here so Core never imports AVFoundation.
//

import AVFoundation
import Foundation
import PindropCore

/// Streaming engines that accept native PCM buffers in addition to float samples.
///
/// Deliberately NOT `@MainActor`: per-buffer decode must never queue behind UI work.
/// A busy render loop (the orb animates at 30fps) starves main-actor hops to ~10/sec
/// while audio arrives at ~50/sec, so partials pile up and burst out only at stop.
/// Async requirements throughout let each conformer pick its isolation: Nemotron is
/// an actor; the Apple engine stays `@MainActor` (isolated witnesses satisfy async
/// requirements via a hop).
public protocol StreamingTranscriptionEngine: PindropCore.StreamingTranscriptionEngine {
    func processAudioBuffer(_ buffer: AVAudioPCMBuffer) async throws
}
