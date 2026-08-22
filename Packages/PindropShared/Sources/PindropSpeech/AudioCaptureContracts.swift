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
import PindropCore

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

/// A single-owner temporary PCM spool. Copies share its deletion ownership; the
/// underlying file is removed exactly once, either explicitly or on deallocation.
public final class AudioPCMFile: @unchecked Sendable {
    public let fileURL: URL
    public let byteCount: Int
    public let sampleRate: Double

    private let ownershipLock = NSLock()
    private var ownsFile = true

    public init(fileURL: URL, byteCount: Int, sampleRate: Double) {
        self.fileURL = fileURL
        self.byteCount = byteCount
        self.sampleRate = sampleRate
    }

    /// Materializes the ASR projection incrementally without transferring file
    /// ownership. Callers that retain the source spool can use this safely.
    public func materializeData(maximumByteCount: Int) throws -> Data {
        guard byteCount <= maximumByteCount else {
            throw AudioRecorderError.recordingTooLong(
                maximumDuration: Double(maximumByteCount) / Double(16_000 * MemoryLayout<Float>.size)
            )
        }

        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }

        var data = Data()
        data.reserveCapacity(byteCount)
        while data.count < byteCount {
            let chunk = handle.readData(ofLength: min(64 * 1024, byteCount - data.count))
            guard !chunk.isEmpty else {
                throw AudioRecorderError.engineStartFailed("Audio PCM spool ended before its recorded length")
            }
            data.append(chunk)
        }
        guard handle.readData(ofLength: 1).isEmpty else {
            throw AudioRecorderError.recordingTooLong(
                maximumDuration: Double(maximumByteCount) / Double(16_000 * MemoryLayout<Float>.size)
            )
        }
        return data
    }

    /// Transfers deletion ownership of the temporary PCM file to the caller.
    /// Subsequent calls, `discard()`, and deinitialization leave the file intact.
    public func takeFileURL() -> URL? {
        ownershipLock.withLock {
            guard ownsFile else { return nil }
            ownsFile = false
            return fileURL
        }
    }

    /// Materializes the spool and transfers ownership out of this instance.
    public func consumeData(maximumByteCount: Int) throws -> Data {
        defer { discard() }
        return try materializeData(maximumByteCount: maximumByteCount)
    }

    public func discard() {
        let shouldRemoveFile = ownershipLock.withLock {
            guard ownsFile else { return false }
            ownsFile = false
            return true
        }
        guard shouldRemoveFile else { return }
        try? FileManager.default.removeItem(at: fileURL)
    }

    deinit { discard() }
}

public enum AudioCaptureSourceFailureStage: String, Equatable, Sendable {
    case start
    case runtime
    case stop
}

/// Sendable, persistence-safe description of a source-specific capture failure.
public struct AudioCaptureSourceFailure: Error, Equatable, Sendable {
    public let source: CaptureSourceKind
    public let stage: AudioCaptureSourceFailureStage
    public let errorDomain: String
    public let errorCode: String?
    public let message: String

    public init(
        source: CaptureSourceKind,
        stage: AudioCaptureSourceFailureStage,
        errorDomain: String,
        errorCode: String?,
        message: String
    ) {
        self.source = source
        self.stage = stage
        self.errorDomain = errorDomain
        self.errorCode = errorCode
        self.message = message
    }

    public init(source: CaptureSourceKind, stage: AudioCaptureSourceFailureStage, error: Error) {
        let error = error as NSError
        self.init(
            source: source,
            stage: stage,
            errorDomain: error.domain,
            errorCode: String(error.code),
            message: error.localizedDescription
        )
    }
}

public enum AudioCaptureSourceStopOutcome: @unchecked Sendable {
    case captured(AudioPCMFile)
    case failed(AudioCaptureSourceFailure)

    public var capturedFile: AudioPCMFile? {
        guard case .captured(let file) = self else { return nil }
        return file
    }

    public var failure: AudioCaptureSourceFailure? {
        guard case .failed(let failure) = self else { return nil }
        return failure
    }

    public func discard() {
        capturedFile?.discard()
    }
}

public struct SourceSeparatedAudioCaptureStopResult: @unchecked Sendable {
    public let microphone: AudioCaptureSourceStopOutcome
    public let systemAudio: AudioCaptureSourceStopOutcome

    public init(
        microphone: AudioCaptureSourceStopOutcome,
        systemAudio: AudioCaptureSourceStopOutcome
    ) {
        self.microphone = microphone
        self.systemAudio = systemAudio
    }
}

/// File-metadata-only terminal outcome for durable meeting capture. Sealed
/// chunks are persistent artifacts: this result never owns their deletion.
public struct MeetingRecordingStopResult: Sendable {
    public let sealedChunks: [SealedAudioSourceChunk]
    public let microphoneFailure: AudioCaptureSourceFailure?
    public let systemAudioFailure: AudioCaptureSourceFailure?

    public init(
        sealedChunks: [SealedAudioSourceChunk],
        microphoneFailure: AudioCaptureSourceFailure?,
        systemAudioFailure: AudioCaptureSourceFailure?
    ) {
        self.sealedChunks = sealedChunks
        self.microphoneFailure = microphoneFailure
        self.systemAudioFailure = systemAudioFailure
    }
}

public struct AudioCaptureSourcesUnavailableError: Error, Equatable, Sendable {
    public let microphone: AudioCaptureSourceFailure
    public let systemAudio: AudioCaptureSourceFailure

    public init(microphone: AudioCaptureSourceFailure, systemAudio: AudioCaptureSourceFailure) {
        self.microphone = microphone
        self.systemAudio = systemAudio
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

/// Opt-in capability for backends that retain each meeting source separately.
/// `AudioCaptureBackend.stopCapture()` remains the compatibility mixed projection.
public protocol SourceSeparatedAudioCaptureBackend: AudioCaptureBackend {
    func stopSourceSeparatedCapture() throws -> SourceSeparatedAudioCaptureStopResult
}

/// Opt-in capability for direct-to-library rotating meeting capture. The
/// recorder configures each physical source before invoking the ordinary capture
/// start method, so all existing temporary capture APIs remain unchanged.
public protocol MeetingAudioCaptureBackend: AudioCaptureBackend {
    func configureMeetingRecording(
        spoolPlan: MeetingCaptureSpoolPlan,
        source: CaptureSourceKind,
        onChunkSealed: @escaping (SealedAudioSourceChunk) -> Void
    ) throws

    /// Stops hardware if needed, drains the writer, and seals any non-empty tail.
    /// It is idempotent after a runtime failure or cancellation.
    func stopMeetingRecording() -> MeetingRecordingStopResult
}
