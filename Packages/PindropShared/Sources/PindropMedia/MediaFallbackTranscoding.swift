//
//  MediaFallbackTranscoding.swift
//  PindropMedia
//
//  Host-injected fallback for formats AVFoundation cannot prepare directly.
//  Desktop hosts may implement this with ffmpeg; the package never discovers
//  or launches external processes.
//

import Foundation

/// Optional host-provided transcoder used when AVFoundation cannot open or
/// decode a media file directly.
///
/// Implementations write a PCM WAV (or any AVAudioFile-readable container)
/// to `destinationURL`. The package owns temporary destination paths and
/// non-cancellation cleanup. On `CancellationError`, hosts that spawn external
/// processes must fully reap the child before removing residual destination
/// output, and must not leave residual process state.
public protocol MediaFallbackTranscoding: Sendable {
    func transcodeToPCM(sourceURL: URL, destinationURL: URL) async throws
}
