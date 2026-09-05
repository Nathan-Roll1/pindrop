//
//  AudioRecorderTests.swift
//  PindropTests
//
//  Created on 2026-01-25.
//

import AVFoundation
import CryptoKit
import Foundation
import Testing
@testable import Pindrop
import PindropCore
import PindropSpeech

@MainActor
@Suite
struct AudioRecorderTests {
    private typealias Fixture = (
        sut: AudioRecorder,
        mockPermission: MockPermissionProvider,
        mockBackend: MockAudioCaptureBackend,
        mockSystemBackend: MockAudioCaptureBackend
    )

    private func makeFixture() throws -> Fixture {
        let mockPermission = MockPermissionProvider()
        let mockBackend = MockAudioCaptureBackend(identifier: "microphone")
        let mockSystemBackend = MockAudioCaptureBackend(identifier: "system")
        let sut = try AudioRecorder(
            permissionManager: mockPermission,
            captureBackend: mockBackend,
            systemAudioCaptureBackend: mockSystemBackend
        )
        return (sut, mockPermission, mockBackend, mockSystemBackend)
    }

    private func makeSpoolPlan(includeSystemAudio: Bool) -> MeetingCaptureSpoolPlan {
        MeetingCaptureSpoolPlan(
            libraryRootURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("pindrop-spool-\(UUID().uuidString)", isDirectory: true),
            sessionID: UUID(),
            microphoneSourceID: UUID(),
            systemAudioSourceID: includeSystemAudio ? UUID() : nil
        )
    }

    @Test func audioRecorderInitialization() throws {
        let fixture = try makeFixture()
        #expect(fixture.sut.isRecording == false)
    }

    @Test func startRecordingRequestsPermission() async throws {
        let fixture = try makeFixture()
        fixture.mockPermission.grantPermission = true

        try await fixture.sut.startRecording()

        #expect(fixture.mockPermission.requestPermissionCallCount == 1)
    }

    @Test func startSystemAudioRecordingRequestsSystemPermissionOnly() async throws {
        let fixture = try makeFixture()

        try await fixture.sut.startRecording(configuration: AudioRecordingConfiguration(mode: .systemAudio))

        #expect(fixture.mockPermission.requestPermissionCallCount == 0)
        #expect(fixture.mockPermission.requestSystemAudioPermissionCallCount == 1)
        #expect(fixture.mockSystemBackend.startCaptureCallCount == 1)
    }

    @Test func startMixedRecordingRequestsBothPermissions() async throws {
        let fixture = try makeFixture()

        try await fixture.sut.startRecording(configuration: AudioRecordingConfiguration(mode: .microphoneAndSystemAudio))

        #expect(fixture.mockPermission.requestPermissionCallCount == 1)
        #expect(fixture.mockPermission.requestSystemAudioPermissionCallCount == 1)
        #expect(fixture.mockBackend.startCaptureCallCount == 1)
        #expect(fixture.mockSystemBackend.startCaptureCallCount == 1)
    }

    @Test func startRecordingSetsIsRecordingFlag() async throws {
        let fixture = try makeFixture()
        fixture.mockPermission.grantPermission = true

        #expect(fixture.sut.isRecording == false)

        try await fixture.sut.startRecording()

        #expect(fixture.sut.isRecording)
        #expect(fixture.mockBackend.startCaptureCallCount == 1)
    }

    @Test func startRecordingForwardsAudioBufferCallback() async throws {
        let fixture = try makeFixture()
        fixture.mockPermission.grantPermission = true
        let sampleBuffer = try #require(
            MockAudioCaptureBackend.makeSynthesizedBuffer(format: fixture.mockBackend.targetFormat),
            "Expected synthesized sample buffer"
        )
        var receivedFrameLength: AVAudioFrameCount?

        fixture.sut.onLivePacket = { packet in
            guard case .buffer(let buffer, _, _) = packet else { return }
            receivedFrameLength = buffer.frameLength
        }

        try await fixture.sut.startRecording()
        fixture.mockBackend.capturedOnBuffer?(sampleBuffer)
        await Task.yield()
        await Task.yield()

        #expect(receivedFrameLength == sampleBuffer.frameLength)
    }

    @Test func concurrentStartRecordingOnlyRequestsPermissionOnce() async throws {
        let fixture = try makeFixture()
        fixture.mockPermission.grantPermission = true
        fixture.mockPermission.delayNanoseconds = 50_000_000

        async let firstStartResult = fixture.sut.startRecording()
        async let secondStartResult = fixture.sut.startRecording()

        let firstResult = try await firstStartResult
        let secondResult = try await secondStartResult

        let successfulStarts = [firstResult, secondResult].filter { $0 }.count
        #expect(successfulStarts == 1)
        #expect(fixture.mockPermission.requestPermissionCallCount == 1)
        #expect(fixture.mockBackend.startCaptureCallCount == 1)
        #expect(fixture.sut.isRecording)
    }

    @Test func stopRecordingReturnsAudioData() async throws {
        let fixture = try makeFixture()
        fixture.mockPermission.grantPermission = true
        let buffer = try #require(
            MockAudioCaptureBackend.makeSynthesizedBuffer(format: fixture.mockBackend.targetFormat),
            "Expected synthesized audio buffer"
        )
        fixture.mockBackend.simulatedBuffers = [buffer]

        try await fixture.sut.startRecording()
        let audioData = try await fixture.sut.stopRecording()

        #expect(audioData.count > 0)
        #expect(fixture.sut.isRecording == false)
        #expect(fixture.mockBackend.stopCaptureCallCount == 1)
    }

    @Test func stopRecordingPreservesAllPCMBytesAcrossBuffers() async throws {
        let fixture = try makeFixture()
        fixture.mockPermission.grantPermission = true
        let firstBuffer = try #require(
            MockAudioCaptureBackend.makeSynthesizedBuffer(
                format: fixture.mockBackend.targetFormat,
                frameCount: 8,
                frequency: 100
            )
        )
        let secondBuffer = try #require(
            MockAudioCaptureBackend.makeSynthesizedBuffer(
                format: fixture.mockBackend.targetFormat,
                frameCount: 8,
                frequency: 200
            )
        )
        fixture.mockBackend.simulatedBuffers = [firstBuffer, secondBuffer]

        try await fixture.sut.startRecording()
        let data = try await fixture.sut.stopRecording()

        let expected = [firstBuffer, secondBuffer].reduce(into: Data()) { data, buffer in
            data.append(contentsOf:
                UnsafeRawBufferPointer(
                    start: buffer.floatChannelData![0],
                    count: Int(buffer.frameLength) * MemoryLayout<Float>.size
                )
            )
        }
        #expect(data == expected)
    }

    @Test func stopRecordingWithoutStartingThrowsError() async throws {
        let fixture = try makeFixture()

        do {
            _ = try await fixture.sut.stopRecording()
            Issue.record("Should have thrown notRecording error")
        } catch AudioRecorderError.notRecording {
        } catch {
            Issue.record("Unexpected error: \(error.localizedDescription)")
        }
    }

    @Test func audioFormatConfiguration() throws {
        let fixture = try makeFixture()
        let format = fixture.sut.targetFormat

        #expect(format.sampleRate == 16000.0)
        #expect(format.channelCount == 1)
        #expect(format.commonFormat == .pcmFormatFloat32)
    }

    @Test func multipleRecordingSessions() async throws {
        let fixture = try makeFixture()
        fixture.mockPermission.grantPermission = true
        let buffer = try #require(
            MockAudioCaptureBackend.makeSynthesizedBuffer(format: fixture.mockBackend.targetFormat),
            "Expected synthesized audio buffer"
        )
        fixture.mockBackend.simulatedBuffers = [buffer]

        try await fixture.sut.startRecording()
        let firstData = try await fixture.sut.stopRecording()
        #expect(firstData.count > 0)

        fixture.mockBackend.simulatedBuffers = [buffer]

        try await fixture.sut.startRecording()
        let secondData = try await fixture.sut.stopRecording()
        #expect(secondData.count > 0)

        #expect(fixture.mockBackend.startCaptureCallCount == 2)
        #expect(fixture.mockBackend.stopCaptureCallCount == 2)
    }

    @Test func startRecordingThrowsWhenPermissionDenied() async throws {
        let fixture = try makeFixture()
        fixture.mockPermission.grantPermission = false

        do {
            try await fixture.sut.startRecording()
            Issue.record("Should have thrown permissionDenied")
        } catch AudioRecorderError.permissionDenied {
        } catch {
            Issue.record("Unexpected error: \(error.localizedDescription)")
        }

        #expect(fixture.sut.isRecording == false)
        #expect(fixture.mockBackend.startCaptureCallCount == 0)
    }

    @Test func startRecordingThrowsWhenSystemAudioPermissionDenied() async throws {
        let fixture = try makeFixture()
        fixture.mockPermission.grantSystemAudioPermission = false

        do {
            try await fixture.sut.startRecording(configuration: AudioRecordingConfiguration(mode: .systemAudio))
            Issue.record("Should have thrown systemAudioPermissionDenied")
        } catch AudioRecorderError.systemAudioPermissionDenied {
        } catch {
            Issue.record("Unexpected error: \(error.localizedDescription)")
        }

        #expect(fixture.mockSystemBackend.startCaptureCallCount == 0)
    }

    @Test func startRecordingThrowsWhenBackendFails() async throws {
        let fixture = try makeFixture()
        fixture.mockPermission.grantPermission = true
        fixture.mockBackend.shouldThrowOnStart = AudioRecorderError.engineStartFailed("Mock engine failure")

        do {
            try await fixture.sut.startRecording()
            Issue.record("Should have thrown engineStartFailed")
        } catch AudioRecorderError.engineStartFailed {
        } catch {
            Issue.record("Unexpected error: \(error.localizedDescription)")
        }

        #expect(fixture.sut.isRecording == false)
    }

    @Test func cancelRecording() async throws {
        let fixture = try makeFixture()
        fixture.mockPermission.grantPermission = true

        try await fixture.sut.startRecording()
        #expect(fixture.sut.isRecording)

        fixture.sut.cancelRecording()

        #expect(fixture.sut.isRecording == false)
        #expect(fixture.mockBackend.cancelCaptureCallCount == 1)
    }

    @Test func resetAudioEngine() async throws {
        let fixture = try makeFixture()
        fixture.mockPermission.grantPermission = true

        try await fixture.sut.startRecording()
        fixture.sut.resetAudioEngine()

        #expect(fixture.sut.isRecording == false)
        #expect(fixture.mockBackend.resetCallCount == 2)
    }

    @Test func setPreferredInputDeviceUIDForwardsSelectionToCaptureBackend() throws {
        let fixture = try makeFixture()

        try fixture.sut.setPreferredInputDeviceUID("usb-mic")

        #expect(fixture.mockBackend.setPreferredInputDeviceUIDCallCount == 1)
        #expect(fixture.mockBackend.lastPreferredInputDeviceUID == "usb-mic")
    }

    @Test func setPreferredInputDeviceUIDCanUpdateActiveCaptureBackend() async throws {
        let fixture = try makeFixture()
        fixture.mockPermission.grantPermission = true

        try await fixture.sut.startRecording()
        try fixture.sut.setPreferredInputDeviceUID("usb-mic")

        #expect(fixture.mockBackend.startCaptureCallCount == 1)
        #expect(fixture.mockBackend.setPreferredInputDeviceUIDCallCount == 1)
        #expect(fixture.mockBackend.lastPreferredInputDeviceUID == "usb-mic")
    }

    @Test func setPreferredInputDeviceUIDIgnoresDuplicateSelection() throws {
        let fixture = try makeFixture()

        try fixture.sut.setPreferredInputDeviceUID("usb-mic")
        try fixture.sut.setPreferredInputDeviceUID("usb-mic")

        #expect(fixture.mockBackend.setPreferredInputDeviceUIDCallCount == 1)
        #expect(fixture.mockBackend.lastPreferredInputDeviceUID == "usb-mic")
    }

    @Test func setPreferredInputDeviceUIDFailurePreservesActiveRecording() async throws {
        let fixture = try makeFixture()
        fixture.mockPermission.grantPermission = true

        try await fixture.sut.startRecording()
        fixture.mockBackend.shouldThrowOnSetPreferredInputDeviceUID = AudioRecorderError.engineStartFailed("switch failed")

        var caughtError: Error?
        do {
            try fixture.sut.setPreferredInputDeviceUID("missing-mic")
        } catch {
            caughtError = error
        }

        #expect(caughtError != nil)
        #expect(fixture.sut.isRecording)
        #expect(fixture.mockBackend.isCapturing)
        #expect(fixture.mockBackend.startCaptureCallCount == 1)
        #expect(fixture.mockBackend.setPreferredInputDeviceUIDCallCount == 1)
    }

    @Test func captureBackendFailureClearsRecordingState() async throws {
        let fixture = try makeFixture()
        fixture.mockPermission.grantPermission = true

        var reportedError: Error?
        fixture.sut.onCaptureError = { error in
            reportedError = error
        }

        try await fixture.sut.startRecording()
        fixture.mockBackend.capturedOnError?(AudioRecorderError.engineStartFailed("device disappeared"))
        await Task.yield()

        #expect(fixture.sut.isRecording == false)
        #expect(fixture.mockBackend.cancelCaptureCallCount == 1)
        #expect(reportedError != nil)
    }

    @Test func delayedCallbacksFromStoppedSessionCannotAffectNewSession() async throws {
        let fixture = try makeFixture()
        fixture.mockPermission.grantPermission = true
        let sampleBuffer = try #require(
            MockAudioCaptureBackend.makeSynthesizedBuffer(format: fixture.mockBackend.targetFormat)
        )
        fixture.mockBackend.simulatedBuffers = [sampleBuffer]

        var deliveredBuffers = 0
        fixture.sut.onLivePacket = { packet in
            guard case .buffer = packet else { return }
            deliveredBuffers += 1
        }

        try await fixture.sut.startRecording()
        let staleBuffer = try #require(fixture.mockBackend.capturedOnBuffer)
        let staleError = try #require(fixture.mockBackend.capturedOnError)
        _ = try await fixture.sut.stopRecording()

        try await fixture.sut.startRecording()
        staleBuffer(sampleBuffer)
        staleError(AudioRecorderError.engineStartFailed("late callback from session A"))
        await Task.yield()
        await Task.yield()

        #expect(fixture.sut.isRecording)
        #expect(deliveredBuffers == 0)
        #expect(fixture.mockBackend.cancelCaptureCallCount == 0)
    }

    @Test func captureLimitKeepsRecorderActiveForControlledFinalization() async throws {
        let fixture = try makeFixture()
        fixture.mockPermission.grantPermission = true
        var receivedLimitSignal = false
        fixture.sut.onCaptureError = { error in
            if case .recordingLimitReached = error as? AudioRecorderError {
                receivedLimitSignal = true
            }
        }

        try await fixture.sut.startRecording()
        fixture.mockBackend.capturedOnError?(
            AudioRecorderError.recordingLimitReached(maximumDuration: 600)
        )
        await Task.yield()

        #expect(receivedLimitSignal)
        #expect(fixture.sut.isRecording)
        #expect(fixture.mockBackend.cancelCaptureCallCount == 0)
    }

    @Test func stopRecordingYieldsMainActorWhileBackendFinalizes() async throws {
        let mockPermission = MockPermissionProvider()
        mockPermission.grantPermission = true
        let mockBackend = DelayedMockAudioCaptureBackend()
        let mockSystemBackend = MockAudioCaptureBackend(identifier: "system")
        let sut = try AudioRecorder(
            permissionManager: mockPermission,
            captureBackend: mockBackend,
            systemAudioCaptureBackend: mockSystemBackend
        )

        let buffer = try #require(
            MockAudioCaptureBackend.makeSynthesizedBuffer(format: mockBackend.targetFormat),
            "Expected synthesized audio buffer"
        )
        mockBackend.simulatedBuffers = [buffer]

        try await sut.startRecording()
        #expect(sut.isRecording)

        let stopTask = Task { try await sut.stopRecording() }

        // Stop clears isRecording before the detached backend finalization returns.
        // Wait for the backend's explicit start signal rather than inferring it from elapsed time.
        await mockBackend.waitUntilStopCaptureStarts()
        defer { mockBackend.allowStopCaptureToFinish() }
        #expect(mockBackend.hasStartedStopCapture)
        #expect(sut.isRecording == false)

        var concurrentMainActorTicks = 0
        for _ in 0..<20 {
            await Task { @MainActor in
                concurrentMainActorTicks += 1
            }.value
        }
        #expect(concurrentMainActorTicks == 20)

        mockBackend.allowStopCaptureToFinish()
        let data = try await stopTask.value

        #expect(data.count > 0)
        #expect(sut.isRecording == false)
        #expect(mockBackend.stopCaptureCallCount == 1)
    }

    @Test func startRecordingWaitsForFinalizationBeforeReusingBackend() async throws {
        let mockPermission = MockPermissionProvider()
        mockPermission.grantPermission = true
        let mockBackend = DelayedMockAudioCaptureBackend()
        let mockSystemBackend = MockAudioCaptureBackend(identifier: "system")
        let sut = try AudioRecorder(
            permissionManager: mockPermission,
            captureBackend: mockBackend,
            systemAudioCaptureBackend: mockSystemBackend
        )

        let buffer = try #require(
            MockAudioCaptureBackend.makeSynthesizedBuffer(format: mockBackend.targetFormat),
            "Expected synthesized audio buffer"
        )
        mockBackend.simulatedBuffers = [buffer]

        try await sut.startRecording()
        #expect(mockBackend.startCaptureCallCount == 1)

        let stopTask = Task { try await sut.stopRecording() }
        await mockBackend.waitUntilStopCaptureStarts()
        defer { mockBackend.allowStopCaptureToFinish() }

        // Finalization owns the backend off the main actor. A concurrent start must
        // not call startCapture/reset on that same instance until ownership returns.
        let startTask = Task { try await sut.startRecording() }

        for _ in 0..<30 {
            await Task.yield()
        }

        #expect(mockBackend.startCaptureCallCount == 1)
        #expect(mockBackend.stopCaptureCallCount == 1)

        sut.resetAudioEngine()
        #expect(
            mockBackend.resetCallCount == 0,
            "reset must not touch a backend still owned by detached finalization"
        )

        mockBackend.allowStopCaptureToFinish()
        let data = try await stopTask.value
        #expect(data.count > 0)

        let started = try await startTask.value
        #expect(started)
        #expect(
            mockBackend.startCaptureCallCount == 2,
            "start may reuse the backend only after finalization releases ownership"
        )
    }


    @Test(.timeLimit(.minutes(1)))
    func meterDeliveryCoalescesLatestOverallAndBandsPreservingCallbackOrder() async throws {
        let fixture = try makeFixture()
        fixture.mockPermission.grantPermission = true

        var deliveredLevels: [Float] = []
        var deliveredBands: [AudioBandLevels] = []
        var deliveryOrder: [String] = []

        try await fixture.sut.startRecording()

        let buffer = try #require(
            MockAudioCaptureBackend.makeSynthesizedBuffer(
                format: fixture.mockBackend.targetFormat,
                frameCount: 320,
                frequency: 440
            ),
            "Expected synthesized sample buffer"
        )

        let emissionCount = 48
        let latestSourceLevel: Float = 0
        let burst = AudioCaptureCallbackBurst(
            buffer: buffer,
            emissionCount: emissionCount,
            onBuffer: fixture.mockBackend.capturedOnBuffer,
            onAudioLevel: fixture.mockBackend.capturedOnAudioLevel
        )
        let (latestPairDelivered, latestPairContinuation) = AsyncStream.makeStream(
            of: Void.self,
            bufferingPolicy: .bufferingNewest(1)
        )

        await confirmation(
            "A current level and bands snapshot is delivered in level-before-bands order"
        ) { confirm in
            var didConfirmLatestPair = false

            func confirmLatestDeliveredPairIfReady() {
                guard !didConfirmLatestPair, deliveredLevels.last == latestSourceLevel else {
                    return
                }

                let latestSnapshotIsOrderedPair =
                    deliveryOrder.suffix(2).elementsEqual(["level", "bands"])
                guard latestSnapshotIsOrderedPair else { return }

                didConfirmLatestPair = true
                confirm()
                latestPairContinuation.yield()
            }

            fixture.sut.onAudioLevel = { level in
                deliveredLevels.append(level)
                deliveryOrder.append("level")
                confirmLatestDeliveredPairIfReady()
            }
            fixture.sut.onAudioBandLevels = { bands in
                deliveredBands.append(bands)
                deliveryOrder.append("bands")
                confirmLatestDeliveredPairIfReady()
            }

            await Task.detached(priority: .userInitiated) {
                burst.run()
                // A distinct final value makes the coalescer's contractually retained
                // latest level observable even when every stale burst value is dropped.
                burst.onBuffer?(burst.buffer)
                burst.onAudioLevel?(latestSourceLevel)
            }.value
            let receivedLatestPair = await withTaskGroup(of: Bool.self) { group in
                group.addTask {
                    for await _ in latestPairDelivered {
                        return true
                    }
                    return false
                }
                group.addTask {
                    do {
                        try await Task.sleep(for: .seconds(1))
                        return false
                    } catch {
                        return false
                    }
                }

                let firstResult = await group.next() ?? false
                group.cancelAll()
                return firstResult
            }

            fixture.sut.onAudioLevel = nil
            fixture.sut.onAudioBandLevels = nil
            latestPairContinuation.finish()
            #expect(
                receivedLatestPair,
                "Timed out waiting for the coalescer's latest level and a delivered level/bands pair"
            )
        }

        let lastLevel = try #require(deliveredLevels.last)
        _ = try #require(deliveredBands.last)

        // The coalescer may supersede any stale source sample, but it must retain
        // and eventually deliver the distinct latest overall level.
        #expect(lastLevel == latestSourceLevel)
        #expect(deliveredLevels.count <= emissionCount + 1)
        #expect(deliveredBands.count <= emissionCount + 1)
        // Only the delivered snapshot containing the current values is ordered;
        // stale source samples may have been superseded before any callback.
        #expect(deliveryOrder.suffix(2).elementsEqual(["level", "bands"]))
    }

    /// Short, quiet tones. Short so the filters' carried state is a large share
    /// of each buffer, quiet so no band saturates at full scale and hides it.
    private func makeToneBuffer(
        format: AVAudioFormat,
        frequency: Float,
        amplitude: Float,
        frameCount: AVAudioFrameCount = 128
    ) throws -> AVAudioPCMBuffer {
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount))
        buffer.frameLength = frameCount
        let channelData = try #require(buffer.floatChannelData)
        let sampleRate = Float(format.sampleRate)
        for frame in 0..<Int(frameCount) {
            channelData[0][frame] = amplitude * sin(2.0 * Float.pi * frequency * Float(frame) / sampleRate)
        }
        return buffer
    }

    @Test func bothChannelsMeterWithoutSharingFilterState() throws {
        let format = MockAudioCaptureBackend(identifier: "microphone").targetFormat
        // A quiet near voice against loud low-frequency call audio: the case
        // where shared filter state and a shared gain envelope both show.
        let microphoneBuffer = try makeToneBuffer(format: format, frequency: 180, amplitude: 0.01)
        let systemBuffer = try makeToneBuffer(format: format, frequency: 60, amplitude: 0.3)

        // Microphone metered on its own pair: the reading a mic-only capture shows.
        let soloAnalyzer = ThreeBandLevelAnalyzer()
        let soloNormalizer = AudioLevelNormalizer()
        var microphoneAlone = AudioBandLevels.zero
        for _ in 0..<6 {
            _ = soloNormalizer.normalize(0.2)
            microphoneAlone = soloNormalizer.scaled(soloAnalyzer.process(microphoneBuffer))
        }

        // Both channels admitted through one shared filter pair, the way the
        // recorder metered before per-source isolation. Kept in the test so the
        // shared-state regression cannot come back unnoticed.
        let sharedAnalyzer = ThreeBandLevelAnalyzer()
        let sharedNormalizer = AudioLevelNormalizer()
        var microphoneThroughSharedPair = AudioBandLevels.zero
        for _ in 0..<6 {
            _ = sharedNormalizer.normalize(0.2)
            microphoneThroughSharedPair = sharedNormalizer.scaled(sharedAnalyzer.process(microphoneBuffer))
            _ = sharedNormalizer.normalize(0.3)
            _ = sharedNormalizer.scaled(sharedAnalyzer.process(systemBuffer))
        }
        #expect(microphoneThroughSharedPair != microphoneAlone)

        // Both channels admitted through the bank, one pair each.
        let sut = CaptureSourceMeterBank()
        var mergedBands = AudioBandLevels.zero
        for _ in 0..<6 {
            _ = sut.meter(level: 0.2, from: .microphone)
            _ = sut.meter(microphoneBuffer, from: .microphone)
            _ = sut.meter(level: 0.3, from: .systemAudio)
            mergedBands = sut.meter(systemBuffer, from: .systemAudio)
        }

        // The microphone reads exactly as it would with no system audio present.
        #expect(sut.latestBands(for: .microphone) == microphoneAlone)
        let systemBands = sut.latestBands(for: .systemAudio)
        #expect(systemBands != microphoneAlone)
        // The reader merges the two: the indicator still shows one waveform.
        #expect(mergedBands.low == max(microphoneAlone.low, systemBands.low))
        #expect(mergedBands.mid == max(microphoneAlone.mid, systemBands.mid))
        #expect(mergedBands.high == max(microphoneAlone.high, systemBands.high))
    }

    @Test func singleSourceMeteringMatchesTheSharedPairItReplaces() throws {
        let format = MockAudioCaptureBackend(identifier: "microphone").targetFormat
        let microphoneBuffer = try makeToneBuffer(format: format, frequency: 180, amplitude: 0.01)

        let analyzer = ThreeBandLevelAnalyzer()
        let normalizer = AudioLevelNormalizer()
        var expectedLevels: [Float] = []
        var expectedBands: [AudioBandLevels] = []
        for step in 0..<8 {
            expectedLevels.append(normalizer.normalize(0.1 + Float(step) * 0.05))
            expectedBands.append(normalizer.scaled(analyzer.process(microphoneBuffer)))
        }

        let sut = CaptureSourceMeterBank()
        var levels: [Float] = []
        var bands: [AudioBandLevels] = []
        for step in 0..<8 {
            levels.append(sut.meter(level: 0.1 + Float(step) * 0.05, from: .microphone))
            bands.append(sut.meter(microphoneBuffer, from: .microphone))
        }

        #expect(levels == expectedLevels)
        #expect(bands == expectedBands)
    }

    @Test func coreAudioInputFormatUsesInputStreamVirtualFormat() throws {
        let expectedStreamID = AudioStreamID(42)
        var requestedStreamID: AudioStreamID?

        let sourceStream = try CoreAudioInputFormatResolver.resolve(
            streamIDs: [expectedStreamID]
        ) { streamID in
            requestedStreamID = streamID
            return Self.makeFloatStreamDescription(sampleRate: 48_000)
        }

        #expect(requestedStreamID == expectedStreamID)
        #expect(sourceStream.streamID == expectedStreamID)
        #expect(sourceStream.bufferIndex == 0)
        #expect(sourceStream.format.sampleRate == 48_000)
        #expect(sourceStream.format.channelCount == 1)
    }

    @Test func coreAudioInputFormatTracksSelectedStreamBufferIndex() throws {
        let sourceStream = try CoreAudioInputFormatResolver.resolve(
            streamIDs: [AudioStreamID(10), AudioStreamID(20)]
        ) { streamID in
            if streamID == 10 {
                return AudioStreamBasicDescription()
            }
            return Self.makeFloatStreamDescription(sampleRate: 44_100)
        }

        #expect(sourceStream.streamID == 20)
        #expect(sourceStream.bufferIndex == 1)
        #expect(sourceStream.format.sampleRate == 44_100)
    }

    @Test func coreAudioInputFormatRejectsMissingInputStreams() {
        do {
            _ = try CoreAudioInputFormatResolver.resolve(streamIDs: []) { _ in
                AudioStreamBasicDescription()
            }
            Issue.record("Expected missing input streams to fail")
        } catch AudioRecorderError.engineStartFailed(let message) {
            #expect(message == "No microphone input stream is available")
        } catch {
            Issue.record("Unexpected error: \(error.localizedDescription)")
        }
    }


    @Test func sourceSeparatedStopRetainsBothSourcesAndMixedProjection() async throws {
        let fixture = try makeFixture()
        let microphoneBuffer = try #require(
            MockAudioCaptureBackend.makeSynthesizedBuffer(
                format: fixture.mockBackend.targetFormat,
                frameCount: 20_000,
                frequency: 100
            )
        )
        let systemBuffer = try #require(
            MockAudioCaptureBackend.makeSynthesizedBuffer(
                format: fixture.mockSystemBackend.targetFormat,
                frameCount: 20_000,
                frequency: 200
            )
        )
        fixture.mockBackend.simulatedBuffers = [microphoneBuffer]
        fixture.mockSystemBackend.simulatedBuffers = [systemBuffer]

        try await fixture.sut.startRecording(
            configuration: AudioRecordingConfiguration(mode: .microphoneAndSystemAudio)
        )
        let result = try await fixture.sut.stopSourceSeparatedRecording()
        let microphone = try #require(result.microphone.capturedFile)
        let systemAudio = try #require(result.systemAudio.capturedFile)

        #expect(result.mixedAudioData?.count == Int(microphoneBuffer.frameLength) * MemoryLayout<Float>.size)
        #expect(FileManager.default.fileExists(atPath: microphone.fileURL.path))
        #expect(FileManager.default.fileExists(atPath: systemAudio.fileURL.path))

        result.discard()
        result.discard()
        #expect(!FileManager.default.fileExists(atPath: microphone.fileURL.path))
        #expect(!FileManager.default.fileExists(atPath: systemAudio.fileURL.path))
    }

    @Test func sourceSeparatedStartKeepsMicrophoneWhenSystemFails() async throws {
        let fixture = try makeFixture()
        fixture.mockSystemBackend.shouldThrowOnStart = AudioRecorderError.engineStartFailed("system unavailable")
        fixture.mockBackend.simulatedBuffers = [
            try #require(MockAudioCaptureBackend.makeSynthesizedBuffer(format: fixture.mockBackend.targetFormat))
        ]

        try await fixture.sut.startRecording(
            configuration: AudioRecordingConfiguration(mode: .microphoneAndSystemAudio)
        )
        let result = try await fixture.sut.stopSourceSeparatedRecording()
        defer { result.discard() }

        #expect(result.mixedAudioData?.isEmpty == false)
        #expect(result.microphone.capturedFile != nil)
        #expect(result.systemAudio.capturedFile == nil)
        #expect(result.systemAudio.failure?.stage == .start)
        #expect(fixture.mockBackend.stopCaptureCallCount == 1)
        #expect(fixture.mockSystemBackend.stopCaptureCallCount == 0)
    }

    @Test func sourceSeparatedStartKeepsSystemWhenMicrophoneFails() async throws {
        let fixture = try makeFixture()
        fixture.mockBackend.shouldThrowOnStart = AudioRecorderError.engineStartFailed("microphone unavailable")
        fixture.mockSystemBackend.simulatedBuffers = [
            try #require(MockAudioCaptureBackend.makeSynthesizedBuffer(format: fixture.mockSystemBackend.targetFormat))
        ]

        try await fixture.sut.startRecording(
            configuration: AudioRecordingConfiguration(mode: .microphoneAndSystemAudio)
        )
        let result = try await fixture.sut.stopSourceSeparatedRecording()
        defer { result.discard() }

        #expect(result.mixedAudioData?.isEmpty == false)
        #expect(result.microphone.capturedFile == nil)
        #expect(result.microphone.failure?.stage == .start)
        #expect(result.systemAudio.capturedFile != nil)
        #expect(fixture.mockBackend.stopCaptureCallCount == 0)
        #expect(fixture.mockSystemBackend.stopCaptureCallCount == 1)
    }

    @Test func sourceSeparatedStartReportsAggregateOnlyWhenBothSourcesFail() async throws {
        let fixture = try makeFixture()
        fixture.mockBackend.shouldThrowOnStart = AudioRecorderError.engineStartFailed("microphone unavailable")
        fixture.mockSystemBackend.shouldThrowOnStart = AudioRecorderError.engineStartFailed("system unavailable")

        do {
            try await fixture.sut.startRecording(
                configuration: AudioRecordingConfiguration(mode: .microphoneAndSystemAudio)
            )
            Issue.record("Expected aggregate source failure")
        } catch let error as AudioCaptureSourcesUnavailableError {
            #expect(error.microphone.stage == .start)
            #expect(error.systemAudio.stage == .start)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        #expect(fixture.mockBackend.startCaptureCallCount == 1)
        #expect(fixture.mockSystemBackend.startCaptureCallCount == 1)
        #expect(fixture.sut.isRecording == false)
    }

    @Test func sourceSeparatedRuntimeFailureKeepsSiblingRecording() async throws {
        let fixture = try makeFixture()
        fixture.mockSystemBackend.simulatedBuffers = [
            try #require(MockAudioCaptureBackend.makeSynthesizedBuffer(format: fixture.mockSystemBackend.targetFormat))
        ]
        var terminalError: Error?
        fixture.sut.onCaptureError = { terminalError = $0 }

        try await fixture.sut.startRecording(
            configuration: AudioRecordingConfiguration(mode: .microphoneAndSystemAudio)
        )
        fixture.mockBackend.capturedOnError?(AudioRecorderError.engineStartFailed("microphone disconnected"))
        await Task.yield()
        await Task.yield()

        #expect(fixture.sut.isRecording)
        #expect(terminalError == nil)
        let result = try await fixture.sut.stopSourceSeparatedRecording()
        defer { result.discard() }
        #expect(result.microphone.failure?.stage == .runtime)
        #expect(result.systemAudio.capturedFile != nil)
        #expect(result.mixedAudioData?.isEmpty == false)
    }

    // MARK: - Live transcript during durable capture

    @Test func sourceSeparatedCaptureForwardsBothChannelsForLiveTranscript() throws {
        let microphone = MockAudioCaptureBackend(identifier: "microphone")
        let systemAudio = MockAudioCaptureBackend(identifier: "system")
        let backend = MixedAudioCaptureBackend(
            microphoneBackend: microphone,
            systemAudioBackend: systemAudio
        )
        var forwarded: [AVAudioPCMBuffer] = []

        try backend.startCapture(
            onBuffer: { forwarded.append($0) },
            onAudioLevel: { _ in },
            onError: { _ in }
        )
        let microphoneBuffer = try #require(
            MockAudioCaptureBackend.makeSynthesizedBuffer(format: microphone.targetFormat)
        )
        let systemBuffer = try #require(
            MockAudioCaptureBackend.makeSynthesizedBuffer(format: systemAudio.targetFormat, frequency: 220)
        )
        // The microphone used to be excluded whenever system audio was running,
        // which is why a person's own voice never reached the live transcript of
        // a meeting. Ownership of the streaming engine is the arbiter's call now.
        microphone.capturedOnBuffer?(microphoneBuffer)
        systemAudio.capturedOnBuffer?(systemBuffer)
        backend.cancelCapture()

        #expect(forwarded.count == 2)
        #expect(forwarded.first === microphoneBuffer)
        #expect(forwarded.last === systemBuffer)
    }

    @Test func sourceSeparatedLiveTranscriptFallsBackWhenSystemAudioFails() throws {
        let microphone = MockAudioCaptureBackend(identifier: "microphone")
        let systemAudio = MockAudioCaptureBackend(identifier: "system")
        systemAudio.shouldThrowOnStart = AudioRecorderError.systemAudioCaptureFailed("tap unavailable")
        let backend = MixedAudioCaptureBackend(
            microphoneBackend: microphone,
            systemAudioBackend: systemAudio
        )
        var forwarded: [AVAudioPCMBuffer] = []

        try backend.startCapture(
            onBuffer: { forwarded.append($0) },
            onAudioLevel: { _ in },
            onError: { _ in }
        )
        let microphoneBuffer = try #require(
            MockAudioCaptureBackend.makeSynthesizedBuffer(format: microphone.targetFormat)
        )
        microphone.capturedOnBuffer?(microphoneBuffer)
        backend.cancelCapture()

        #expect(forwarded.count == 1)
        #expect(forwarded.first === microphoneBuffer)
    }

    @Test func durableCaptureForwardsSystemAudioToTheStreamingPump() async throws {
        let fixture = try makeFixture()
        let plan = makeSpoolPlan(includeSystemAudio: true)
        var pumpedSources: [CaptureSourceKind] = []
        fixture.sut.onLivePacket = { packet in
            guard case .buffer(_, let source, _) = packet else { return }
            pumpedSources.append(source)
        }

        try await fixture.sut.startMeetingRecording(spoolPlan: plan) { _ in }
        // Both gates need a floor before either can read as speech, so the
        // capture opens on room tone and only then does the far end talk.
        try feedLiveBuffers(fixture: fixture, microphoneAmplitude: 0.001, systemAmplitude: 0.001, count: 3)
        try feedLiveBuffers(fixture: fixture, microphoneAmplitude: 0.001, systemAmplitude: 0.5, count: 6)
        _ = try await fixture.sut.stopMeetingRecording()
        fixture.sut.onLivePacket = nil

        #expect(!pumpedSources.isEmpty)
        #expect(pumpedSources.allSatisfy { $0 == .systemAudio })
    }

    /// Feeds one interleaved run of buffers to both capture children, at the
    /// amplitudes each channel is meant to carry.
    private func feedLiveBuffers(
        fixture: Fixture,
        microphoneAmplitude: Float,
        systemAmplitude: Float,
        count: Int
    ) throws {
        for _ in 0..<count {
            let microphoneBuffer = try #require(
                MockAudioCaptureBackend.makeSynthesizedBuffer(
                    format: fixture.mockBackend.targetFormat,
                    amplitude: microphoneAmplitude
                )
            )
            let systemBuffer = try #require(
                MockAudioCaptureBackend.makeSynthesizedBuffer(
                    format: fixture.mockSystemBackend.targetFormat,
                    frequency: 220,
                    amplitude: systemAmplitude
                )
            )
            fixture.mockBackend.capturedOnBuffer?(microphoneBuffer)
            fixture.mockSystemBackend.capturedOnBuffer?(systemBuffer)
        }
    }

    @Test func micOnlyDurableCaptureSpoolsTheMicrophoneAndNeverStartsSystemAudio() async throws {
        let fixture = try makeFixture()
        fixture.mockBackend.simulatedBuffers = [
            try #require(MockAudioCaptureBackend.makeSynthesizedBuffer(format: fixture.mockBackend.targetFormat))
        ]
        let plan = makeSpoolPlan(includeSystemAudio: false)

        try await fixture.sut.startMeetingRecording(spoolPlan: plan) { _ in }

        #expect(fixture.mockPermission.requestSystemAudioPermissionCallCount == 0)
        #expect(fixture.mockBackend.configuredMeetingSources == [.microphone])
        #expect(fixture.mockSystemBackend.configuredMeetingSources.isEmpty)
        #expect(fixture.mockSystemBackend.startCaptureCallCount == 0)

        let result = try await fixture.sut.stopMeetingRecording()

        #expect(result.sealedChunks.count == 1)
        #expect(result.sealedChunks.allSatisfy { $0.sourceID == plan.microphoneSourceID })
        #expect(result.systemAudioFailure == nil)
        #expect(fixture.mockSystemBackend.stopMeetingRecordingCallCount == 0)
        for chunk in result.sealedChunks {
            try? FileManager.default.removeItem(at: chunk.fileURL)
        }
    }

    @Test func dualSourceDurableCaptureStillSpoolsBothSources() async throws {
        let fixture = try makeFixture()
        fixture.mockBackend.simulatedBuffers = [
            try #require(MockAudioCaptureBackend.makeSynthesizedBuffer(format: fixture.mockBackend.targetFormat))
        ]
        fixture.mockSystemBackend.simulatedBuffers = [
            try #require(MockAudioCaptureBackend.makeSynthesizedBuffer(format: fixture.mockSystemBackend.targetFormat))
        ]
        let plan = makeSpoolPlan(includeSystemAudio: true)

        try await fixture.sut.startMeetingRecording(spoolPlan: plan) { _ in }

        #expect(fixture.mockPermission.requestSystemAudioPermissionCallCount == 1)
        #expect(fixture.mockBackend.configuredMeetingSources == [.microphone])
        #expect(fixture.mockSystemBackend.configuredMeetingSources == [.systemAudio])

        let result = try await fixture.sut.stopMeetingRecording()
        let sourceIDs = Set(result.sealedChunks.map(\.sourceID))

        #expect(sourceIDs == Set(plan.sourceIDs))
        for chunk in result.sealedChunks {
            try? FileManager.default.removeItem(at: chunk.fileURL)
        }
    }

    @Test func mixedRuntimeFailureSchedulesChildCancellationOutsideChildCallback() async throws {
        let microphone = CallbackQueueAudioCaptureBackend(identifier: "microphone")
        let systemAudio = CallbackQueueAudioCaptureBackend(identifier: "system")
        let backend = MixedAudioCaptureBackend(
            microphoneBackend: microphone,
            systemAudioBackend: systemAudio
        )

        try backend.startCapture(onBuffer: { _ in }, onAudioLevel: { _ in }, onError: { _ in })
        microphone.emitDeferredError(AudioRecorderError.engineStartFailed("microphone disconnected"))
        await microphone.waitUntilCancelled()

        #expect(microphone.cancelWasCalledFromCallbackQueue == false)
        #expect(systemAudio.isCapturing)
        backend.cancelCapture()
    }

    @Test func sourceSeparatedStopReportsBothSourceFailuresWithoutThrowing() async throws {
        let fixture = try makeFixture()
        fixture.mockBackend.shouldThrowOnStop = AudioRecorderError.engineStartFailed("microphone stop failed")
        fixture.mockSystemBackend.shouldThrowOnStop = AudioRecorderError.engineStartFailed("system stop failed")

        try await fixture.sut.startRecording(
            configuration: AudioRecordingConfiguration(mode: .microphoneAndSystemAudio)
        )
        let result = try await fixture.sut.stopSourceSeparatedRecording()
        defer { result.discard() }

        #expect(result.mixedAudioData == nil)
        #expect(result.microphone.failure?.stage == .stop)
        #expect(result.systemAudio.failure?.stage == .stop)
        #expect(fixture.mockBackend.stopCaptureCallCount == 1)
        #expect(fixture.mockSystemBackend.stopCaptureCallCount == 1)
    }

    @Test func legacyMixedStopStillReturnsACompatibilityProjection() async throws {
        let fixture = try makeFixture()
        fixture.mockBackend.simulatedBuffers = [
            try #require(MockAudioCaptureBackend.makeSynthesizedBuffer(format: fixture.mockBackend.targetFormat))
        ]
        fixture.mockSystemBackend.simulatedBuffers = [
            try #require(MockAudioCaptureBackend.makeSynthesizedBuffer(format: fixture.mockSystemBackend.targetFormat))
        ]

        try await fixture.sut.startRecording(
            configuration: AudioRecordingConfiguration(mode: .microphoneAndSystemAudio)
        )
        let data = try await fixture.sut.stopRecording()

        #expect(data.isEmpty == false)
        #expect(fixture.mockBackend.stopCaptureCallCount == 1)
        #expect(fixture.mockSystemBackend.stopCaptureCallCount == 1)
    }

    @Test func cancellingSourceSeparatedStopDrainsAndDiscardsEverySourceFile() async throws {
        let permission = MockPermissionProvider()
        let microphone = DelayedMockAudioCaptureBackend()
        let systemAudio = MockAudioCaptureBackend(identifier: "system")
        let sut = try AudioRecorder(
            permissionManager: permission,
            captureBackend: microphone,
            systemAudioCaptureBackend: systemAudio
        )
        microphone.simulatedBuffers = [
            try #require(MockAudioCaptureBackend.makeSynthesizedBuffer(format: microphone.targetFormat))
        ]
        systemAudio.simulatedBuffers = [
            try #require(MockAudioCaptureBackend.makeSynthesizedBuffer(format: systemAudio.targetFormat))
        ]

        try await sut.startRecording(configuration: AudioRecordingConfiguration(mode: .microphoneAndSystemAudio))
        let stopTask = Task { @MainActor () -> Bool in
            do {
                _ = try await sut.stopSourceSeparatedRecording()
                return false
            } catch is CancellationError {
                return true
            } catch {
                return false
            }
        }
        await microphone.waitUntilStopCaptureStarts()
        stopTask.cancel()
        microphone.allowStopCaptureToFinish()

        #expect(await stopTask.value)
        let microphoneFile = try #require(microphone.producedFileURL)
        let systemAudioFile = try #require(systemAudio.producedFileURL)
        #expect(!FileManager.default.fileExists(atPath: microphoneFile.path))
        #expect(!FileManager.default.fileExists(atPath: systemAudioFile.path))
    }
#if DEBUG
    @Test func mixedStartJoinsDeferredChildCancellationBeforeReusingChild() async throws {
        let microphone = BlockingCancellationAudioCaptureBackend(identifier: "microphone")
        let systemAudio = CallbackQueueAudioCaptureBackend(identifier: "system")
        let backend = MixedAudioCaptureBackend(
            microphoneBackend: microphone,
            systemAudioBackend: systemAudio
        )
        let joinAttempted = TestAsyncSignal()
        let joinFinished = TestJoinProbe()
        let shouldObserveJoins = TestBoolean()
        backend.configureTestingChildTeardownJoinObservers(
            beforeJoin: {
                if shouldObserveJoins.value {
                    joinAttempted.signal()
                }
            },
            afterJoin: {
                if shouldObserveJoins.value {
                    joinFinished.record(cancellationFinished: microphone.cancellationHasFinished)
                }
            }
        )

        try backend.startCapture(onBuffer: { _ in }, onAudioLevel: { _ in }, onError: { _ in })
        shouldObserveJoins.set(true)
        microphone.emitRuntimeFailure(AudioRecorderError.engineStartFailed("microphone disconnected"))
        await microphone.waitUntilCancellationStarts()

        let startFinished = TestAsyncSignal()
        let sendableBackend = UnsafeSendableBox(backend)
        let startTask = Task.detached { [sendableBackend, startFinished] in
            defer { startFinished.signal() }
            return (try? sendableBackend.value.startCapture(
                onBuffer: { _ in },
                onAudioLevel: { _ in },
                onError: { _ in }
            )) != nil
        }
        await joinAttempted.wait()

        #expect(microphone.startCaptureCallCount == 1)
        microphone.allowCancellationToFinish()
        await startFinished.wait()

        #expect(await startTask.value)
        #expect(joinFinished.observedOnlyAfterCancellationFinished)
        #expect(microphone.cancelledCaptureGenerations == [1])
        #expect(microphone.isCapturing)
        backend.cancelCapture()
    }

    @Test func systemTapCallbackLifecycleTeardownReturnsBeforeControlQueueAndBarriersNextStart() async throws {
        guard #available(macOS 14.2, *) else { return }

        let tap = UnsafeSendableBox(try SystemAudioTapCaptureBackend())
        let callbackStarted = TestAsyncSignal()
        let controlTeardownEntered = TestAsyncSignal()
        let callbackActionsMayRun = DispatchSemaphore(value: 0)
        let callbackActionsReturned = TestAsyncSignal()
        let callbackMayFinish = DispatchSemaphore(value: 0)
        let callbackFinished = TestBoolean()
        let callbackStartWasRejected = TestBoolean()
        let callbackStopWasRejected = TestBoolean()
        let startAttempted = TestAsyncSignal()
        let startFinished = TestAsyncSignal()
        let successfulStartCount = TestCounter()
        let storageDiscardCount = TestCounter()

        tap.value.configureTestingStorageDiscardObserver {
            storageDiscardCount.increment()
        }
        tap.value.configureTestingStartCaptureOverride(
            {
                successfulStartCount.increment()
            },
            onAttempt: {
                startAttempted.signal()
            }
        )
        tap.value.enqueueTestingCallback {
            callbackStarted.signal()
            callbackActionsMayRun.wait()

            do {
                try tap.value.startCapture(onBuffer: { _ in }, onAudioLevel: { _ in }, onError: { _ in })
            } catch let error as AudioRecorderError {
                if case let .systemAudioCaptureFailed(message) = error,
                   message == "System audio capture cannot be started from its audio callback" {
                    callbackStartWasRejected.set(true)
                }
            } catch {
            }
            tap.value.cancelCapture()
            tap.value.reset()
            do {
                _ = try tap.value.stopCapture()
            } catch let error as AudioRecorderError {
                if case let .systemAudioCaptureFailed(message) = error,
                   message == "System audio capture cannot be stopped from its audio callback" {
                    callbackStopWasRejected.set(true)
                }
            } catch {
            }

            callbackActionsReturned.signal()
            callbackMayFinish.wait()
            callbackFinished.set(true)
        }
        await callbackStarted.wait()
        tap.value.enqueueTestingFailureTeardown {
            controlTeardownEntered.signal()
        }
        await controlTeardownEntered.wait()

        callbackActionsMayRun.signal()
        await callbackActionsReturned.wait()

        #expect(callbackStartWasRejected.value)
        #expect(callbackStopWasRejected.value)
        #expect(successfulStartCount.value == 0)
        #expect(storageDiscardCount.value == 0)

        let startTask = Task.detached { [tap, startFinished] in
            defer { startFinished.signal() }
            try tap.value.startCapture(onBuffer: { _ in }, onAudioLevel: { _ in }, onError: { _ in })
        }
        await startAttempted.wait()
        #expect(successfulStartCount.value == 0)

        callbackMayFinish.signal()
        await startFinished.wait()
        try await startTask.value

        #expect(callbackFinished.value)
        #expect(successfulStartCount.value == 1)
        #expect(storageDiscardCount.value == 5)
    }

    @Test func systemTapFailureTeardownJoinsCallbacksBeforeConcurrentCancelAndReset() async throws {
        guard #available(macOS 14.2, *) else { return }

        let tap = UnsafeSendableBox(try SystemAudioTapCaptureBackend())
        let callbackStarted = TestAsyncSignal()
        let callbackMayFinish = DispatchSemaphore(value: 0)
        let callbackFinished = TestBoolean()
        let resetProbe = TestConverterResetProbe()
        tap.value.configureTestingConverterResetObserver {
            resetProbe.record(callbackFinished: callbackFinished.value)
        }
        tap.value.enqueueTestingCallback {
            callbackStarted.signal()
            callbackMayFinish.wait()
            callbackFinished.set(true)
        }
        tap.value.enqueueTestingFailureTeardown()
        await callbackStarted.wait()

        let cancelEntered = TestAsyncSignal()
        let cancelFinished = TestAsyncSignal()
        let cancelTask = Task.detached { [tap, cancelEntered, cancelFinished] in
            cancelEntered.signal()
            tap.value.cancelCapture()
            cancelFinished.signal()
        }
        let resetEntered = TestAsyncSignal()
        let resetFinished = TestAsyncSignal()
        let resetTask = Task.detached { [tap, resetEntered, resetFinished] in
            resetEntered.signal()
            tap.value.reset()
            resetFinished.signal()
        }
        await cancelEntered.wait()
        await resetEntered.wait()
        await Task.yield()

        #expect(resetProbe.resetCount == 0)
        callbackMayFinish.signal()
        await cancelFinished.wait()
        await resetFinished.wait()
        _ = await cancelTask.value
        _ = await resetTask.value

        #expect(resetProbe.resetCount == 3)
        #expect(resetProbe.didResetBeforeCallbackFinished == false)
    }
#endif

    @Test func audioPCMFileTakeFileURLTransfersNativeRetentionOwnershipOnce() throws {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("pindrop-native-transfer-\(UUID().uuidString).pcm")
        try Data([1, 2, 3, 4]).write(to: fileURL)

        let transferredURL: URL
        do {
            let spool = AudioPCMFile(fileURL: fileURL, byteCount: 4, sampleRate: 48_000)
            transferredURL = try #require(spool.takeFileURL())
            #expect(spool.takeFileURL() == nil)
            spool.discard()
        }

        #expect(transferredURL == fileURL)
        #expect(FileManager.default.fileExists(atPath: transferredURL.path))

        let nativeAudio = AudioCaptureNativeAudio(fileURL: transferredURL, sampleRate: 48_000)
        nativeAudio.discard()
        nativeAudio.discard()
        #expect(!FileManager.default.fileExists(atPath: transferredURL.path))
    }

    @Test func sourceProjectionReusesEagerDataForBothCapturedSources() throws {
        let eagerProjection = Data([9, 8, 7, 6])
        let fixture = try makeSourceSeparatedResult(
            microphoneData: Data([1, 1, 1, 1]),
            systemAudioData: Data([2, 2, 2, 2]),
            eagerProjection: eagerProjection
        )
        defer { fixture.result.discard() }

        let projection = try fixture.result.projectionData(
            retainingMicrophone: true,
            systemAudio: true
        )
        #expect(projection == eagerProjection)
    }

    @Test func sourceProjectionMaterializesEachSoleRetainedSourceWithoutDeletingOwners() throws {
        let microphoneData = Data([1, 2, 3, 4])
        let systemAudioData = Data([5, 6, 7, 8])
        let fixture = try makeSourceSeparatedResult(
            microphoneData: microphoneData,
            systemAudioData: systemAudioData,
            eagerProjection: Data([9, 9, 9, 9])
        )

        let microphoneURL = try #require(fixture.microphoneURL)
        let systemAudioURL = try #require(fixture.systemAudioURL)

        let microphoneProjection = try fixture.result.projectionData(
            retainingMicrophone: true,
            systemAudio: false
        )
        let systemAudioProjection = try fixture.result.projectionData(
            retainingMicrophone: false,
            systemAudio: true
        )

        #expect(microphoneProjection == microphoneData)
        #expect(systemAudioProjection == systemAudioData)
        #expect(FileManager.default.fileExists(atPath: microphoneURL.path))
        #expect(FileManager.default.fileExists(atPath: systemAudioURL.path))

        fixture.result.discard()
        #expect(!FileManager.default.fileExists(atPath: microphoneURL.path))
        #expect(!FileManager.default.fileExists(atPath: systemAudioURL.path))
    }

    @Test func sourceProjectionUsesTheCapturedPartialBackendSource() async throws {
        let fixture = try makeFixture()
        let microphoneBuffer = try #require(
            MockAudioCaptureBackend.makeSynthesizedBuffer(
                format: fixture.mockBackend.targetFormat,
                frameCount: 8,
                frequency: 100
            )
        )
        fixture.mockBackend.simulatedBuffers = [microphoneBuffer]
        fixture.mockSystemBackend.shouldThrowOnStart = AudioRecorderError.engineStartFailed("system unavailable")

        try await fixture.sut.startRecording(
            configuration: AudioRecordingConfiguration(mode: .microphoneAndSystemAudio)
        )
        let result = try await fixture.sut.stopSourceSeparatedRecording()
        defer { result.discard() }

        let expected = Data(
            bytes: microphoneBuffer.floatChannelData![0],
            count: Int(microphoneBuffer.frameLength) * MemoryLayout<Float>.size
        )
        let projection = try result.projectionData(retainingMicrophone: true, systemAudio: false)
        #expect(projection == expected)
    }

    @Test func sourceProjectionReturnsNilWhenNoSourcesAreRetained() throws {
        let fixture = try makeSourceSeparatedResult(
            microphoneData: nil,
            systemAudioData: nil,
            eagerProjection: nil
        )
        defer { fixture.result.discard() }

        let projection = try fixture.result.projectionData(
            retainingMicrophone: false,
            systemAudio: false
        )
        #expect(projection == nil)
    }

    @Test func sourceProjectionRejectsAnUncapturedRequestedSource() throws {
        let fixture = try makeSourceSeparatedResult(
            microphoneData: Data([1, 2, 3, 4]),
            systemAudioData: nil,
            eagerProjection: Data([1, 2, 3, 4])
        )
        defer { fixture.result.discard() }

        #expect(throws: AudioRecorderError.self) {
            _ = try fixture.result.projectionData(retainingMicrophone: false, systemAudio: true)
        }
    }

    private func makeSourceSeparatedResult(
        microphoneData: Data?,
        systemAudioData: Data?,
        eagerProjection: Data?
    ) throws -> (result: SourceSeparatedRecordingResult, microphoneURL: URL?, systemAudioURL: URL?) {
        let microphone = try makeSourceOutcome(data: microphoneData, isMicrophone: true)
        let systemAudio = try makeSourceOutcome(data: systemAudioData, isMicrophone: false)
        return (
            SourceSeparatedRecordingResult(
                mixedAudioData: eagerProjection,
                microphone: microphone.outcome,
                systemAudio: systemAudio.outcome
            ),
            microphone.url,
            systemAudio.url
        )
    }

    private func makeSourceOutcome(
        data: Data?,
        isMicrophone: Bool
    ) throws -> (outcome: AudioCaptureSourceStopOutcome, url: URL?) {
        guard let data else {
            return (
                .failed(
                    AudioCaptureSourceFailure(
                        source: isMicrophone ? .microphone : .systemAudio,
                        stage: .start,
                        error: AudioRecorderError.notRecording
                    )
                ),
                nil
            )
        }

        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("pindrop-source-projection-\(UUID().uuidString).pcm")
        try data.write(to: fileURL)
        return (
            .captured(
                AudioPCMFile(fileURL: fileURL, byteCount: data.count, sampleRate: 16_000)
            ),
            fileURL
        )
    }

    private static func makeFloatStreamDescription(
        sampleRate: Double
    ) -> AudioStreamBasicDescription {
        AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kLinearPCMFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 4,
            mFramesPerPacket: 1,
            mBytesPerFrame: 4,
            mChannelsPerFrame: 1,
            mBitsPerChannel: 32,
            mReserved: 0
        )
    }

}

#if DEBUG
private final class UnsafeSendableBox<Value>: @unchecked Sendable {
    let value: Value

    init(_ value: Value) {
        self.value = value
    }
}

private final class TestAsyncSignal: @unchecked Sendable {
    private let lock = NSLock()
    private var isSignalled = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func signal() {
        let drainedWaiters = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            guard !isSignalled else { return [] }
            isSignalled = true
            let currentWaiters = self.waiters
            self.waiters.removeAll()
            return currentWaiters
        }
        for waiter in drainedWaiters {
            waiter.resume()
        }
    }

    func wait() async {
        await withCheckedContinuation { continuation in
            let shouldResume = lock.withLock { () -> Bool in
                if isSignalled {
                    return true
                }
                waiters.append(continuation)
                return false
            }
            if shouldResume {
                continuation.resume()
            }
        }
    }
}

private final class TestBoolean: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = false

    var value: Bool {
        lock.withLock { storage }
    }

    func set(_ value: Bool) {
        lock.withLock {
            storage = value
        }
    }
}

private final class TestCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = 0

    var value: Int {
        lock.withLock { storage }
    }

    func increment() {
        lock.withLock {
            storage += 1
        }
    }
}

private final class TestJoinProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var didObserveEarlyJoin = false

    var observedOnlyAfterCancellationFinished: Bool {
        lock.withLock { !didObserveEarlyJoin }
    }

    func record(cancellationFinished: Bool) {
        lock.withLock {
            didObserveEarlyJoin = didObserveEarlyJoin || !cancellationFinished
        }
    }
}

private final class TestConverterResetProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var resetCountStorage = 0
    private var didResetBeforeCallbackFinishedStorage = false

    var resetCount: Int {
        lock.withLock { resetCountStorage }
    }

    var didResetBeforeCallbackFinished: Bool {
        lock.withLock { didResetBeforeCallbackFinishedStorage }
    }

    func record(callbackFinished: Bool) {
        lock.withLock {
            resetCountStorage += 1
            didResetBeforeCallbackFinishedStorage =
                didResetBeforeCallbackFinishedStorage || !callbackFinished
        }
    }
}

private final class BlockingCancellationAudioCaptureBackend: AudioCaptureBackend, @unchecked Sendable {
    let identifier: String
    let targetFormat = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!

    private let stateLock = NSLock()
    private let cancellationMayFinish = DispatchSemaphore(value: 0)
    private let cancellationStarted = TestAsyncSignal()
    private var isCapturingStorage = false
    private var cancellationHasFinishedStorage = false
    private var shouldBlockNextCancellation = true
    private var captureGeneration = 0
    private var startCaptureCallCountStorage = 0
    private var cancelledCaptureGenerationsStorage: [Int] = []
    private var capturedOnError: ((Error) -> Void)?

    var isCapturing: Bool {
        stateLock.withLock { isCapturingStorage }
    }

    var cancellationHasFinished: Bool {
        stateLock.withLock { cancellationHasFinishedStorage }
    }

    var startCaptureCallCount: Int {
        stateLock.withLock { startCaptureCallCountStorage }
    }

    var cancelledCaptureGenerations: [Int] {
        stateLock.withLock { cancelledCaptureGenerationsStorage }
    }

    init(identifier: String) {
        self.identifier = identifier
    }

    func startCapture(
        onBuffer: @escaping (AVAudioPCMBuffer) -> Void,
        onAudioLevel: @escaping (Float) -> Void,
        onError: @escaping (Error) -> Void
    ) throws {
        stateLock.withLock {
            captureGeneration += 1
            startCaptureCallCountStorage += 1
            isCapturingStorage = true
            capturedOnError = onError
        }
        _ = onBuffer
        _ = onAudioLevel
    }

    func stopCapture() throws -> AudioPCMFile {
        stateLock.withLock {
            isCapturingStorage = false
        }
        throw AudioRecorderError.notRecording
    }

    func cancelCapture() {
        let shouldBlock = stateLock.withLock { () -> Bool in
            cancelledCaptureGenerationsStorage.append(captureGeneration)
            isCapturingStorage = false
            let shouldBlock = shouldBlockNextCancellation
            shouldBlockNextCancellation = false
            return shouldBlock
        }
        cancellationStarted.signal()
        if shouldBlock {
            cancellationMayFinish.wait()
        }
        stateLock.withLock {
            cancellationHasFinishedStorage = true
        }
    }

    func reset() {
        cancelCapture()
    }

    func setPreferredInputDeviceUID(_ uid: String) throws {}

    func emitRuntimeFailure(_ error: Error) {
        let callback = stateLock.withLock { capturedOnError }
        callback?(error)
    }

    func waitUntilCancellationStarts() async {
        await cancellationStarted.wait()
    }

    func allowCancellationToFinish() {
        cancellationMayFinish.signal()
    }
}
#endif

/// Backend that blocks inside `stopCapture` so stop finalization can be observed
/// yielding the main actor. Lives only in this test file (production mocks stay lean).
private final class DelayedMockAudioCaptureBackend: AudioCaptureBackend, @unchecked Sendable {
    let identifier: String
    private let stateLock = NSLock()
    private var isCapturingStorage = false
    var isCapturing: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return isCapturingStorage
    }
    let targetFormat: AVAudioFormat

    var simulatedBuffers: [AVAudioPCMBuffer] = []
    private let stopMayFinish = DispatchSemaphore(value: 0)
    private var stopStartedStorage = false
    private var stopStartWaiters: [CheckedContinuation<Void, Never>] = []
    private var producedFileURLStorage: URL?

    private(set) var startCaptureCallCount = 0
    private(set) var stopCaptureCallCount = 0
    private(set) var cancelCaptureCallCount = 0
    private(set) var resetCallCount = 0

    var capturedOnBuffer: ((AVAudioPCMBuffer) -> Void)?
    var capturedOnAudioLevel: ((Float) -> Void)?
    var capturedOnError: ((Error) -> Void)?

    var hasStartedStopCapture: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return stopStartedStorage
    }

    var producedFileURL: URL? {
        stateLock.lock()
        defer { stateLock.unlock() }
        return producedFileURLStorage
    }

    init(identifier: String = "delayed-microphone") {
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
        self.targetFormat = AVAudioFormat(streamDescription: &streamDescription)!
    }

    func startCapture(
        onBuffer: @escaping (AVAudioPCMBuffer) -> Void,
        onAudioLevel: @escaping (Float) -> Void,
        onError: @escaping (Error) -> Void
    ) throws {
        startCaptureCallCount += 1
        capturedOnBuffer = onBuffer
        capturedOnAudioLevel = onAudioLevel
        capturedOnError = onError
        stateLock.lock()
        isCapturingStorage = true
        stateLock.unlock()
    }

    func stopCapture() throws -> AudioPCMFile {
        stateLock.lock()
        stopCaptureCallCount += 1
        stopStartedStorage = true
        let waiters = stopStartWaiters
        stopStartWaiters.removeAll()
        stateLock.unlock()
        for waiter in waiters {
            waiter.resume()
        }
        stopMayFinish.wait()
        stateLock.lock()
        isCapturingStorage = false
        stateLock.unlock()
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
            .appendingPathComponent("pindrop-test-delayed-audio-\(UUID().uuidString).pcm")
        try data.write(to: fileURL)
        stateLock.lock()
        producedFileURLStorage = fileURL
        stateLock.unlock()
        return AudioPCMFile(
            fileURL: fileURL,
            byteCount: data.count,
            sampleRate: targetFormat.sampleRate
        )
    }

    func cancelCapture() {
        stateLock.lock()
        cancelCaptureCallCount += 1
        isCapturingStorage = false
        stateLock.unlock()
    }

    func reset() {
        stateLock.lock()
        resetCallCount += 1
        isCapturingStorage = false
        stateLock.unlock()
    }

    func waitUntilStopCaptureStarts() async {
        await withCheckedContinuation { continuation in
            stateLock.lock()
            if stopStartedStorage {
                stateLock.unlock()
                continuation.resume()
            } else {
                stopStartWaiters.append(continuation)
                stateLock.unlock()
            }
        }
    }

    func allowStopCaptureToFinish() {
        stopMayFinish.signal()
    }

    func setPreferredInputDeviceUID(_ uid: String) throws {}
}

/// Delivers errors from a dedicated callback queue and records whether teardown
/// was re-entered on that queue.
private final class CallbackQueueAudioCaptureBackend: AudioCaptureBackend, @unchecked Sendable {
    let identifier: String
    let targetFormat = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!

    private let stateLock = NSLock()
    private let callbackQueue: DispatchQueue
    private let callbackQueueKey = DispatchSpecificKey<Bool>()
    private var isCapturingStorage = false
    private var capturedOnError: ((Error) -> Void)?
    private var cancellationWaiters: [CheckedContinuation<Void, Never>] = []
    private var cancelCallCount = 0
    private var cancelWasCalledFromCallbackQueueStorage = false

    var isCapturing: Bool {
        stateLock.withLock { isCapturingStorage }
    }

    var cancelWasCalledFromCallbackQueue: Bool {
        stateLock.withLock { cancelWasCalledFromCallbackQueueStorage }
    }

    init(identifier: String) {
        self.identifier = identifier
        self.callbackQueue = DispatchQueue(label: "tech.watzon.pindrop.tests.\(identifier)")
        callbackQueue.setSpecific(key: callbackQueueKey, value: true)
    }

    func startCapture(
        onBuffer: @escaping (AVAudioPCMBuffer) -> Void,
        onAudioLevel: @escaping (Float) -> Void,
        onError: @escaping (Error) -> Void
    ) throws {
        stateLock.withLock {
            isCapturingStorage = true
            capturedOnError = onError
        }
        _ = onBuffer
        _ = onAudioLevel
    }

    func stopCapture() throws -> AudioPCMFile {
        stateLock.withLock {
            isCapturingStorage = false
        }
        throw AudioRecorderError.notRecording
    }

    func cancelCapture() {
        let waiters = stateLock.withLock { () -> [CheckedContinuation<Void, Never>] in
            cancelCallCount += 1
            cancelWasCalledFromCallbackQueueStorage =
                cancelWasCalledFromCallbackQueueStorage ||
                DispatchQueue.getSpecific(key: callbackQueueKey) == true
            isCapturingStorage = false
            let waiters = cancellationWaiters
            cancellationWaiters.removeAll()
            return waiters
        }
        for waiter in waiters {
            waiter.resume()
        }
    }

    func reset() {
        cancelCapture()
    }

    func setPreferredInputDeviceUID(_ uid: String) throws {}

    func emitDeferredError(_ error: Error) {
        callbackQueue.async { [weak self] in
            guard let self else { return }
            let callback = self.stateLock.withLock { self.capturedOnError }
            callback?(error)
        }
    }

    func waitUntilCancelled() async {
        await withCheckedContinuation { continuation in
            stateLock.withLock {
                if cancelCallCount > 0 {
                    continuation.resume()
                } else {
                    cancellationWaiters.append(continuation)
                }
            }
        }
    }
}

/// Immutable capture-thread work item. The callbacks are supplied by AudioRecorder and are
/// specifically required to accept backend-thread delivery; the audio buffer is read-only here.
private final class AudioCaptureCallbackBurst: @unchecked Sendable {
    let buffer: AVAudioPCMBuffer
    let emissionCount: Int
    let onBuffer: ((AVAudioPCMBuffer) -> Void)?
    let onAudioLevel: ((Float) -> Void)?

    init(
        buffer: AVAudioPCMBuffer,
        emissionCount: Int,
        onBuffer: ((AVAudioPCMBuffer) -> Void)?,
        onAudioLevel: ((Float) -> Void)?
    ) {
        self.buffer = buffer
        self.emissionCount = emissionCount
        self.onBuffer = onBuffer
        self.onAudioLevel = onAudioLevel
    }

    func run() {
        for index in 0..<emissionCount {
            onBuffer?(buffer)
            onAudioLevel?(Float(index + 1) / Float(emissionCount))
        }
    }
}


@Suite
struct AudioPCMFileStorageTests {
    @Test func spoolsPCMBuffersAndReturnsFinalDataInOrder() throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
        let first = try #require(MockAudioCaptureBackend.makeSynthesizedBuffer(format: format, frameCount: 4, frequency: 100))
        let second = try #require(MockAudioCaptureBackend.makeSynthesizedBuffer(format: format, frameCount: 4, frequency: 200))
        let storage = AudioPCMFileStorage()

        try storage.start()
        #expect(storage.enqueue(first))
        #expect(storage.enqueue(second))
        let completed = try storage.finish()
        let result = try #require(completed)
        let data = try result.consumeData(maximumByteCount: 1024)

        #expect(result.sampleRate == 16_000)
        #expect(data.count == 8 * MemoryLayout<Float>.size)
        let samples = data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        #expect(samples == [
            first.floatChannelData![0][0], first.floatChannelData![0][1], first.floatChannelData![0][2], first.floatChannelData![0][3],
            second.floatChannelData![0][0], second.floatChannelData![0][1], second.floatChannelData![0][2], second.floatChannelData![0][3],
        ])
    }

    @Test func slowWriterUsesBoundedHandoffAndRejectsOverflow() throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
        let buffer = try #require(MockAudioCaptureBackend.makeSynthesizedBuffer(format: format, frameCount: 4))
        let storage = AudioPCMFileStorage(pendingWriteLimit: 1, writerDelayNanoseconds: 100_000_000)

        try storage.start()
        #expect(storage.enqueue(buffer))
        #expect(storage.enqueue(buffer) == false)
        let completed = try storage.finish()
        let result = try #require(completed)
        result.discard()
    }

    @Test func materializationRejectsDataOverConfiguredLimit() throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
        let buffer = try #require(MockAudioCaptureBackend.makeSynthesizedBuffer(format: format, frameCount: 8))
        let storage = AudioPCMFileStorage()

        try storage.start()
        #expect(storage.enqueue(buffer))
        let completed = try storage.finish()
        let result = try #require(completed)
        defer { result.discard() }

        #expect(throws: AudioRecorderError.self) {
            _ = try result.consumeData(maximumByteCount: 4)
        }
    }

    @Test func limitPreservesAlreadyWrittenPCMForControlledFinalization() throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
        let first = try #require(MockAudioCaptureBackend.makeSynthesizedBuffer(format: format, frameCount: 4, frequency: 100))
        let second = try #require(MockAudioCaptureBackend.makeSynthesizedBuffer(format: format, frameCount: 4, frequency: 200))
        let overLimit = try #require(MockAudioCaptureBackend.makeSynthesizedBuffer(format: format, frameCount: 4, frequency: 300))
        var reachedLimit = false
        let storage = AudioPCMFileStorage(maximumByteCount: 8 * MemoryLayout<Float>.size)

        try storage.start(onLimitReached: { _ in reachedLimit = true })
        #expect(storage.enqueue(first))
        #expect(storage.enqueue(second))
        #expect(storage.enqueue(overLimit))

        let finished = try storage.finish()
        let completed = try #require(finished)
        let data = try completed.consumeData(maximumByteCount: 1024)
        #expect(reachedLimit)
        #expect(data.count == 8 * MemoryLayout<Float>.size)
    }

    @Test func enqueueSnapshotsSamplesBeforeBorrowedSourceCanMutate() throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
        let source = try #require(MockAudioCaptureBackend.makeSynthesizedBuffer(format: format, frameCount: 4))
        let expected = Array(UnsafeBufferPointer(start: source.floatChannelData![0], count: 4))
        let storage = AudioPCMFileStorage(writerDelayNanoseconds: 100_000_000)

        try storage.start()
        #expect(storage.enqueue(source))
        for index in 0..<4 { source.floatChannelData![0][index] = -1 }

        let finished = try storage.finish()
        let completed = try #require(finished)
        let data = try completed.consumeData(maximumByteCount: 1024)
        let actual = data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        #expect(actual == expected)
    }

    @Test func exhaustedSlabPoolRejectsThenRecyclesInWriteOrder() throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
        let first = try #require(MockAudioCaptureBackend.makeSynthesizedBuffer(format: format, frameCount: 4, frequency: 100))
        let second = try #require(MockAudioCaptureBackend.makeSynthesizedBuffer(format: format, frameCount: 4, frequency: 200))
        let storage = AudioPCMFileStorage(pendingWriteLimit: 1, writerDelayNanoseconds: 30_000_000)

        try storage.start()
        #expect(storage.enqueue(first))
        #expect(storage.enqueue(second) == false)
        Thread.sleep(forTimeInterval: 0.06) // Writer returns the sole slab off callback.
        #expect(storage.enqueue(second))

        let finished = try storage.finish()
        let completed = try #require(finished)
        let data = try completed.consumeData(maximumByteCount: 1024)
        let samples = data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        #expect(samples == [
            first.floatChannelData![0][0], first.floatChannelData![0][1], first.floatChannelData![0][2], first.floatChannelData![0][3],
            second.floatChannelData![0][0], second.floatChannelData![0][1], second.floatChannelData![0][2], second.floatChannelData![0][3],
        ])
    }

    @Test func multiSlabFIFOPreservesCaptureOrderAcrossOneWriterWakeup() throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
        var buffers: [AVAudioPCMBuffer] = []
        for frequency: Float in [100, 200, 300, 400] {
            let buffer = try #require(
                MockAudioCaptureBackend.makeSynthesizedBuffer(
                    format: format,
                    frameCount: 4,
                    frequency: frequency
                )
            )
            buffers.append(buffer)
        }
        let storage = AudioPCMFileStorage(pendingWriteLimit: 4, writerDelayNanoseconds: 20_000_000)

        try storage.start()
        for buffer in buffers { #expect(storage.enqueue(buffer)) }

        let finished = try storage.finish()
        let completed = try #require(finished)
        let data = try completed.consumeData(maximumByteCount: 1024)
        let samples = data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        var expected: [Float] = []
        for buffer in buffers {
            expected.append(contentsOf: (0..<4).map { buffer.floatChannelData![0][$0] })
        }
        #expect(samples == expected)
    }

    @Test func discardIsIdempotentAndStorageCanRestartAfterPendingSlabs() throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
        let first = try #require(MockAudioCaptureBackend.makeSynthesizedBuffer(format: format, frameCount: 4, frequency: 100))
        let second = try #require(MockAudioCaptureBackend.makeSynthesizedBuffer(format: format, frameCount: 4, frequency: 200))
        let storage = AudioPCMFileStorage(pendingWriteLimit: 2, writerDelayNanoseconds: 20_000_000)

        try storage.start()
        #expect(storage.enqueue(first))
        #expect(storage.enqueue(second))
        storage.discard()
        storage.discard()

        try storage.start()
        #expect(storage.enqueue(second))
        let finished = try storage.finish()
        let completed = try #require(finished)
        let data = try completed.consumeData(maximumByteCount: 1024)
        let samples = data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        #expect(samples == (0..<4).map { second.floatChannelData![0][$0] })
    }

    @Test func repeatedFinishRestartMaintainsFIFOSequences() throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
        let storage = AudioPCMFileStorage(pendingWriteLimit: 3)

        for frequency: Float in [100, 200, 300, 400, 500, 600] {
            let buffer = try #require(
                MockAudioCaptureBackend.makeSynthesizedBuffer(
                    format: format,
                    frameCount: 4,
                    frequency: frequency
                )
            )
            try storage.start()
            #expect(storage.enqueue(buffer))
            let finished = try storage.finish()
            let completed = try #require(finished)
            let data = try completed.consumeData(maximumByteCount: 1024)
            let samples = data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
            #expect(samples == (0..<4).map { buffer.floatChannelData![0][$0] })
        }
    }

    @Test func durableSpoolRotatesExactlyAtBoundariesAndSealsTail() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AudioPCMFileStorageTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
        let fullChunk = try #require(
            MockAudioCaptureBackend.makeSynthesizedBuffer(format: format, frameCount: 4, frequency: 100)
        )
        let tail = try #require(
            MockAudioCaptureBackend.makeSynthesizedBuffer(format: format, frameCount: 2, frequency: 200)
        )
        let storage = AudioPCMFileStorage(pendingWriteLimit: 20)
        let sealedLock = NSLock()
        var sealed: [AudioPCMFileStorage.SealedDurableChunk] = []

        try storage.startDurable(
            chunkByteCount: 4 * MemoryLayout<Float>.size,
            inProgressURL: { sequence in
                directory.appendingPathComponent("chunk-\(String(format: "%05d", sequence)).pcm.inprogress")
            },
            onChunkSealed: { chunk in
                sealedLock.withLock { sealed.append(chunk) }
            },
            onWriteFailure: { _ in Issue.record("durable writer failed unexpectedly") }
        )
        for _ in 0..<18 {
            #expect(storage.enqueue(fullChunk))
        }
        #expect(storage.enqueue(tail))

        let terminal = storage.finishDurable()
        let chunks = sealedLock.withLock { sealed }
        #expect(terminal.failure == nil)
        #expect(chunks.count == 19)
        #expect(chunks.map(\.sequence) == Array(0..<19))
        #expect(chunks.dropLast().allSatisfy { $0.byteCount == 16 && $0.duration == 0.00025 })
        #expect(chunks.last?.byteCount == 8)
        #expect(abs((chunks.last?.startOffset ?? .infinity) - 18 * 0.00025) <= 1.0 / 16_000.0)
        for chunk in chunks {
            #expect(FileManager.default.fileExists(atPath: chunk.fileURL.path))
            #expect(!FileManager.default.fileExists(atPath: "\(chunk.fileURL.path).inprogress"))
            let expectedHash = SHA256.hash(data: try Data(contentsOf: chunk.fileURL))
                .map { String(format: "%02x", $0) }
                .joined()
            #expect(chunk.sha256 == expectedHash)
        }
    }

    @Test func durableDiscardSealsTailInsteadOfDeletingIt() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AudioPCMFileStorageTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
        let tail = try #require(
            MockAudioCaptureBackend.makeSynthesizedBuffer(format: format, frameCount: 3, frequency: 100)
        )
        let storage = AudioPCMFileStorage()
        let sealedLock = NSLock()
        var sealed: [AudioPCMFileStorage.SealedDurableChunk] = []

        try storage.startDurable(
            chunkByteCount: 16,
            inProgressURL: { _ in directory.appendingPathComponent("tail.pcm.inprogress") },
            onChunkSealed: { chunk in sealedLock.withLock { sealed.append(chunk) } },
            onWriteFailure: { _ in Issue.record("durable writer failed unexpectedly") }
        )
        #expect(storage.enqueue(tail))
        storage.discard()

        let chunks = sealedLock.withLock { sealed }
        let chunk = try #require(chunks.first)
        #expect(chunk.byteCount == 12)
        #expect(FileManager.default.fileExists(atPath: chunk.fileURL.path))
    }

    @Test func durableFinishDrainsLaggingSealCallbacks() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AudioPCMFileStorageTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
        let buffer = try #require(
            MockAudioCaptureBackend.makeSynthesizedBuffer(format: format, frameCount: 4, frequency: 100)
        )
        let callbackCompleted = NSLock()
        var didCompleteCallback = false
        let storage = AudioPCMFileStorage()

        try storage.startDurable(
            chunkByteCount: 16,
            inProgressURL: { _ in directory.appendingPathComponent("chunk.pcm.inprogress") },
            onChunkSealed: { _ in
                Thread.sleep(forTimeInterval: 0.02)
                callbackCompleted.withLock { didCompleteCallback = true }
            },
            onWriteFailure: { _ in Issue.record("durable writer failed unexpectedly") }
        )
        #expect(storage.enqueue(buffer))
        let terminal = storage.finishDurable()

        #expect(terminal.failure == nil)
        #expect(callbackCompleted.withLock { didCompleteCallback })
    }

    @Test func oneDurableWriterFailureDoesNotDiscardSiblingChunks() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AudioPCMFileStorageTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
        let buffer = try #require(
            MockAudioCaptureBackend.makeSynthesizedBuffer(format: format, frameCount: 4, frequency: 100)
        )
        let microphone = AudioPCMFileStorage()
        let systemAudio = AudioPCMFileStorage()

        try microphone.startDurable(
            chunkByteCount: 16,
            inProgressURL: { _ in directory.appendingPathComponent("microphone.pcm.inprogress") },
            onChunkSealed: { _ in },
            onWriteFailure: { _ in Issue.record("microphone writer failed unexpectedly") }
        )
        try systemAudio.startDurable(
            chunkByteCount: 16,
            inProgressURL: { _ in URL(fileURLWithPath: "/dev/null/chunk.pcm.inprogress") },
            onChunkSealed: { _ in },
            onWriteFailure: { _ in }
        )
        #expect(microphone.enqueue(buffer))
        #expect(systemAudio.enqueue(buffer))

        let microphoneTerminal = microphone.finishDurable()
        let systemAudioTerminal = systemAudio.finishDurable()
        #expect(microphoneTerminal.failure == nil)
        #expect(microphoneTerminal.chunks.count == 1)
        #expect(FileManager.default.fileExists(atPath: microphoneTerminal.chunks[0].fileURL.path))
        #expect(systemAudioTerminal.failure != nil)
    }
}

@Suite
struct AudioLevelNormalizerTests {
    @Test func quietSourceIsBoostedToVisualRange() {
        let sut = AudioLevelNormalizer()

        // A soft mic whose speech peaks sit around 0.15 raw: after a few updates
        // the envelope tracks 0.15 and peaks land near full scale.
        var last: Float = 0
        for _ in 0..<5 {
            last = sut.normalize(0.15)
        }

        #expect(last > 0.85)
        #expect(last <= 1.0)
    }

    @Test func loudSourceIsNotAmplifiedPastFullScale() {
        let sut = AudioLevelNormalizer()

        let normalized = sut.normalize(0.9)

        #expect(normalized <= 1.0)
        #expect(normalized > 0.85)
    }

    @Test func silenceIsNotBoostedToFullScale() {
        let sut = AudioLevelNormalizer()

        // Room noise well under the envelope floor must stay visually quiet even
        // though nothing louder has been heard.
        let normalized = sut.normalize(0.01)

        #expect(normalized < 0.2)
    }

    @Test func gainRelaxesSlowlyAfterLoudPassage() {
        let sut = AudioLevelNormalizer()

        _ = sut.normalize(0.9)
        let gainAfterLoud = sut.currentGain
        // A handful of quiet updates should barely move the gain (slow release).
        for _ in 0..<10 {
            _ = sut.normalize(0.01)
        }

        #expect(sut.currentGain < gainAfterLoud * 1.2)
    }

    @Test func bandsScaleByASharedGain() {
        let sut = AudioLevelNormalizer()
        _ = sut.normalize(0.15)

        let bands = sut.scaled(AudioBandLevels(low: 0.12, mid: 0.06, high: 0.03))

        // Relative structure preserved: low > mid > high with the same ratios.
        #expect(bands.low > bands.mid)
        #expect(bands.mid > bands.high)
        #expect(abs(bands.mid / bands.low - 0.5) < 0.01)
        #expect(bands.low <= 1.0)
    }

    @Test func resetClearsTheEnvelope() {
        let sut = AudioLevelNormalizer()
        _ = sut.normalize(0.9)
        let adaptedGain = sut.currentGain

        sut.reset()

        #expect(sut.currentGain > adaptedGain)
    }
}

@Suite
struct OrbWaveformResponseTests {
    @Test func inputAtOrBelowBaselineKeepsEveryTraceFlat() {
        let loudBands = AudioBandLevels(low: 1, mid: 1, high: 1)

        let below = OrbWaveformResponse.levels(
            bands: loudBands,
            overall: OrbWaveformResponse.baselineLevel - 0.001
        )
        let atBaseline = OrbWaveformResponse.levels(
            bands: loudBands,
            overall: OrbWaveformResponse.baselineLevel
        )

        #expect(below == .zero)
        #expect(atBaseline == .zero)
    }

    @Test func individualBandsRemainFlatBelowTheirFloor() {
        let response = OrbWaveformResponse.levels(
            bands: AudioBandLevels(
                low: OrbWaveformResponse.bandFloor,
                mid: 0.5,
                high: OrbWaveformResponse.bandFloor - 0.001
            ),
            overall: 1
        )

        #expect(response.low == 0)
        #expect(response.mid > 0)
        #expect(response.high == 0)
    }

    @Test func responsePreservesBandOrderingAndCapsPeakMotion() {
        let response = OrbWaveformResponse.levels(
            bands: AudioBandLevels(low: 1, mid: 0.6, high: 0.25),
            overall: 1
        )

        #expect(response.low > response.mid)
        #expect(response.mid > response.high)
        #expect(response.low <= OrbWaveformResponse.maximumResponse)
        #expect(response.mid <= OrbWaveformResponse.maximumResponse)
        #expect(response.high <= OrbWaveformResponse.maximumResponse)
    }

    @Test func ordinarySpeechLevelsProduceVisibleMotion() {
        let response = OrbWaveformResponse.levels(
            bands: AudioBandLevels(low: 0.3, mid: 0.25, high: 0.18),
            overall: 0.2
        )

        #expect(response.low > 0.18)
        #expect(response.mid > 0.12)
        #expect(response.high > 0.05)
    }
}
