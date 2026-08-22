//
//  MockAudioCaptureBackend.swift
//  PindropTests
//
//  Created on 2026-02-08.
//

import AVFoundation
import CryptoKit
import Foundation
@testable import Pindrop
import PindropCore
import PindropSpeech

final class MockAudioCaptureBackend: MeetingAudioCaptureBackend {
    let identifier: String
    private(set) var isCapturing: Bool = false

    let targetFormat: AVAudioFormat

    var shouldThrowOnStart: Error?
    var shouldThrowOnStop: Error?
    var shouldThrowOnSetPreferredInputDeviceUID: Error?
    var simulatedBuffers: [AVAudioPCMBuffer] = []

    var startCaptureCallCount: Int = 0
    var stopCaptureCallCount: Int = 0
    var cancelCaptureCallCount: Int = 0
    var resetCallCount: Int = 0
    var setPreferredInputDeviceUIDCallCount: Int = 0
    var lastPreferredInputDeviceUID: String?
    private(set) var producedFileURL: URL?

    var capturedOnBuffer: ((AVAudioPCMBuffer) -> Void)?
    var capturedOnAudioLevel: ((Float) -> Void)?
    var capturedOnError: ((Error) -> Void)?

    // MARK: - Durable meeting capture

    private(set) var meetingSpoolPlan: MeetingCaptureSpoolPlan?
    private(set) var meetingSpoolSourceID: UUID?
    /// Every source this backend was asked to spool, in configuration order.
    private(set) var configuredMeetingSources: [CaptureSourceKind] = []
    private(set) var stopMeetingRecordingCallCount = 0
    private var meetingSource: CaptureSourceKind?
    private var meetingChunkSealedCallback: ((SealedAudioSourceChunk) -> Void)?

    init(identifier: String = UUID().uuidString) {
        self.identifier = identifier
        var streamDescription = AudioStreamBasicDescription(
            mSampleRate: 16000.0,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kLinearPCMFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 4,
            mFramesPerPacket: 1,
            mBytesPerFrame: 4,
            mChannelsPerFrame: 1,
            mBitsPerChannel: 32,
            mReserved: 0
        )
        // Force unwrap is safe here — known-good parameters for 16kHz mono Float32
        self.targetFormat = AVAudioFormat(streamDescription: &streamDescription)!
    }

    func startCapture(
        onBuffer: @escaping (AVAudioPCMBuffer) -> Void,
        onAudioLevel: @escaping (Float) -> Void,
        onError: @escaping (Error) -> Void
    ) throws {
        startCaptureCallCount += 1
        if let error = shouldThrowOnStart { throw error }
        capturedOnBuffer = onBuffer
        capturedOnAudioLevel = onAudioLevel
        capturedOnError = onError
        isCapturing = true
    }

    func stopCapture() throws -> AudioPCMFile {
        stopCaptureCallCount += 1
        if let error = shouldThrowOnStop { throw error }
        isCapturing = false
        let data = simulatedBuffers.reduce(into: Data()) { data, buffer in
            guard let channelData = buffer.floatChannelData else { return }
            data.append(contentsOf:
                UnsafeRawBufferPointer(
                    start: channelData[0],
                    count: Int(buffer.frameLength) * MemoryLayout<Float>.size
                )
            )
        }
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("pindrop-test-audio-\(UUID().uuidString).pcm")
        try data.write(to: fileURL)
        producedFileURL = fileURL
        return AudioPCMFile(
            fileURL: fileURL,
            byteCount: data.count,
            sampleRate: targetFormat.sampleRate
        )
    }

    func cancelCapture() {
        cancelCaptureCallCount += 1
        isCapturing = false
    }

    func reset() {
        resetCallCount += 1
        isCapturing = false
    }

    func setPreferredInputDeviceUID(_ uid: String) throws {
        setPreferredInputDeviceUIDCallCount += 1
        lastPreferredInputDeviceUID = uid
        if let error = shouldThrowOnSetPreferredInputDeviceUID {
            throw error
        }
    }

    /// Mirrors the production contract: a source the plan does not spool is
    /// rejected, so a mic-only plan can never configure a system-audio child.
    func configureMeetingRecording(
        spoolPlan: MeetingCaptureSpoolPlan,
        source: CaptureSourceKind,
        onChunkSealed: @escaping (SealedAudioSourceChunk) -> Void
    ) throws {
        let sourceID: UUID? = switch source {
        case .microphone: spoolPlan.microphoneSourceID
        case .systemAudio: spoolPlan.systemAudioSourceID
        }
        guard let sourceID else {
            throw AudioRecorderError.engineStartFailed(
                "This capture plan has no \(source.rawValue) source to spool"
            )
        }
        meetingSpoolPlan = spoolPlan
        meetingSpoolSourceID = sourceID
        meetingSource = source
        configuredMeetingSources.append(source)
        meetingChunkSealedCallback = onChunkSealed
    }

    /// Seals one chunk per capture from the simulated buffers, so a durable stop
    /// returns real files with real digests.
    func stopMeetingRecording() -> MeetingRecordingStopResult {
        stopMeetingRecordingCallCount += 1
        isCapturing = false
        guard let spoolPlan = meetingSpoolPlan,
              let sourceID = meetingSpoolSourceID,
              let source = meetingSource else {
            return MeetingRecordingStopResult(
                sealedChunks: [],
                microphoneFailure: nil,
                systemAudioFailure: nil
            )
        }
        meetingSpoolPlan = nil
        meetingSpoolSourceID = nil
        meetingSource = nil
        meetingChunkSealedCallback = nil

        let data = simulatedBuffers.reduce(into: Data()) { data, buffer in
            guard let channelData = buffer.floatChannelData else { return }
            data.append(contentsOf:
                UnsafeRawBufferPointer(
                    start: channelData[0],
                    count: Int(buffer.frameLength) * MemoryLayout<Float>.size
                )
            )
        }
        let fileURL = CaptureSourceArtifactPath.sourceURL(
            libraryRootURL: spoolPlan.libraryRootURL,
            sessionID: spoolPlan.sessionID,
            sourceID: sourceID,
            chunkSequence: 0
        )
        try? FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? data.write(to: fileURL)
        let chunk = SealedAudioSourceChunk(
            sessionID: spoolPlan.sessionID,
            sourceID: sourceID,
            sequence: 0,
            startOffset: 0,
            duration: Double(data.count / MemoryLayout<Float>.size) / targetFormat.sampleRate,
            fileURL: fileURL,
            relativePath: CaptureSourceArtifactPath.relativePath(
                sessionID: spoolPlan.sessionID,
                sourceID: sourceID,
                chunkSequence: 0
            ),
            byteCount: Int64(data.count),
            sha256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        )
        _ = source
        return MeetingRecordingStopResult(
            sealedChunks: [chunk],
            microphoneFailure: nil,
            systemAudioFailure: nil
        )
    }

    // MARK: - Test Helpers

    static func makeSynthesizedBuffer(
        format: AVAudioFormat,
        frameCount: AVAudioFrameCount = 1600,
        frequency: Float = 440.0
    ) -> AVAudioPCMBuffer? {
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
            return nil
        }
        buffer.frameLength = frameCount

        guard let channelData = buffer.floatChannelData else { return nil }
        let sampleRate = Float(format.sampleRate)

        for frame in 0..<Int(frameCount) {
            let sample = sin(2.0 * Float.pi * frequency * Float(frame) / sampleRate)
            channelData[0][frame] = sample * 0.5
        }

        return buffer
    }
}
