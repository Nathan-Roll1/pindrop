//
//  AudioCaptureContracts.swift
//  PindropSpeech
//
//  Created on 2026-07-22.
//
//  Portable capture mode/config/error DTOs plus AVFoundation-backed
//  AudioCaptureBackend and native PCM helpers. Hardware backends
//  (AVAudioEngine, CoreAudio, system tap, mixed capture) stay in the app.
//

import AVFoundation
import Foundation

// MARK: - Recording Mode / Configuration / Errors

public enum AudioRecordingMode: String, CaseIterable, Equatable, Sendable {
    case microphone
    case systemAudio
    case microphoneAndSystemAudio

    public var requiresMicrophonePermission: Bool {
        switch self {
        case .microphone, .microphoneAndSystemAudio:
            return true
        case .systemAudio:
            return false
        }
    }

    public var requiresSystemAudioPermission: Bool {
        switch self {
        case .microphone:
            return false
        case .systemAudio, .microphoneAndSystemAudio:
            return true
        }
    }

    /// English source key for library list labels. Localized presentation lives in the app target.
    public var libraryDisplayName: String {
        switch self {
        case .microphone:
            return "Microphone Recording"
        case .systemAudio:
            return "System Audio Recording"
        case .microphoneAndSystemAudio:
            return "Mixed Recording"
        }
    }
}

public struct AudioRecordingConfiguration: Equatable, Sendable {
    public var mode: AudioRecordingMode

    public init(mode: AudioRecordingMode) {
        self.mode = mode
    }

    public static let microphone = AudioRecordingConfiguration(mode: .microphone)
}

public enum AudioRecorderError: Error, LocalizedError, Equatable, Sendable {
    case permissionDenied
    case systemAudioPermissionDenied
    case notRecording
    case engineStartFailed(String)
    case systemAudioCaptureFailed(String)
    case unsupportedCaptureMode(String)
    case audioFormatCreationFailed
    case recordingTooLong(maximumDuration: TimeInterval)
    /// A controlled signal: the valid ASR spool is full and must be finalized.
    case recordingLimitReached(maximumDuration: TimeInterval)
    case audioWriterBacklogExceeded

    public var errorDescription: String? {
        switch self {
        case .permissionDenied:
            return "Microphone permission denied"
        case .systemAudioPermissionDenied:
            return "System audio capture permission denied or unavailable"
        case .notRecording:
            return "Not currently recording"
        case .engineStartFailed(let message):
            return "Audio engine failed to start: \(message)"
        case .systemAudioCaptureFailed(let message):
            return "System audio capture failed: \(message)"
        case .unsupportedCaptureMode(let message):
            return message
        case .audioFormatCreationFailed:
            return "Failed to create audio format"
        case .recordingTooLong(let maximumDuration):
            return "Recording exceeded the maximum duration of \(Int(maximumDuration / 60)) minutes"
        case .recordingLimitReached(let maximumDuration):
            return "Recording reached the maximum duration of \(Int(maximumDuration / 60)) minutes and is being finalized"
        case .audioWriterBacklogExceeded:
            return "Audio capture could not keep up with disk writing"
        }
    }
}

// MARK: - Native PCM + Backend Protocol

/// Native-rate mono PCM collected alongside the 16 kHz ASR feed. Retention encodes
/// this so kept audio isn't telephone-bandwidth (the target format exists for the
/// recognizer, not for listening).
public final class AudioCaptureNativeAudio {
    private var fileURL: URL?
    public let sampleRate: Double

    public init(fileURL: URL, sampleRate: Double) {
        self.fileURL = fileURL
        self.sampleRate = sampleRate
    }

    /// Transfers the temporary PCM file to the retention encoder. The caller owns
    /// deletion after this returns a URL.
    public func takeFileURL() -> URL? {
        defer { fileURL = nil }
        return fileURL
    }

    public func discard() {
        if let fileURL { try? FileManager.default.removeItem(at: fileURL) }
        fileURL = nil
    }

    deinit { discard() }
}

public struct AudioPCMFile {
    public let fileURL: URL
    public let byteCount: Int
    public let sampleRate: Double

    public init(fileURL: URL, byteCount: Int, sampleRate: Double) {
        self.fileURL = fileURL
        self.byteCount = byteCount
        self.sampleRate = sampleRate
    }

    public func consumeData(maximumByteCount: Int) throws -> Data {
        defer { try? FileManager.default.removeItem(at: fileURL) }
        guard byteCount <= maximumByteCount else {
            throw AudioRecorderError.recordingTooLong(
                maximumDuration: Double(maximumByteCount) / Double(16_000 * MemoryLayout<Float>.size)
            )
        }
        return try Data(contentsOf: fileURL)
    }

    public func discard() {
        try? FileManager.default.removeItem(at: fileURL)
    }
}

/// Abstracts audio capture hardware, enabling mock-based testing.
/// Production backends (AVAudioEngine, CoreAudio, system tap, mixed) live in the app target.
public protocol AudioCaptureBackend: AnyObject {
    var isCapturing: Bool { get }
    var targetFormat: AVAudioFormat { get }
    /// When true, capture also accumulates buffers at the device's native sample
    /// rate for retention-quality encoding. Set before `startCapture`.
    var retainsNativeAudio: Bool { get set }

    func startCapture(
        onBuffer: @escaping (AVAudioPCMBuffer) -> Void,
        onAudioLevel: @escaping (Float) -> Void,
        onError: @escaping (Error) -> Void
    ) throws
    /// Stops capture and returns the file-backed 16 kHz mono Float32 PCM spool.
    func stopCapture() throws -> AudioPCMFile
    /// Drains the native-rate copy collected during the last capture, if enabled.
    func collectNativeAudio() -> AudioCaptureNativeAudio?
    func cancelCapture()
    func reset()
    func setPreferredInputDeviceUID(_ uid: String) throws
}

extension AudioCaptureBackend {
    // Backends that never feed retention (system-audio tap, test mocks) opt out.
    public var retainsNativeAudio: Bool {
        get { false }
        set {}
    }

    public func collectNativeAudio() -> AudioCaptureNativeAudio? { nil }
}
