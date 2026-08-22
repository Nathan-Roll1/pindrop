//
//  AudioPreprocessorTests.swift
//  PindropSpeechTests
//
//  Created on 2026-07-22.
//

import AVFoundation
import Foundation
import PindropCore
import Testing
@testable import PindropSpeech

@Suite
struct AudioPreprocessorTests {
    @Test func voiceIsolationPreservesAlignmentAndRecordingTail() async throws {
        let sampleRate = 16_000
        let tailStart = sampleRate - 640
        let samples = (0..<sampleRate).map { index in
            let time = Double(index) / Double(sampleRate)
            let voicedSignal =
                sin(2 * Double.pi * 120 * time)
                + 0.5 * sin(2 * Double.pi * 240 * time)
                + 0.25 * sin(2 * Double.pi * 360 * time)
            let amplitude = index >= tailStart ? 0.2 : 0.05
            return Float(voicedSignal * amplitude)
        }
        let input = samples.withUnsafeBufferPointer { Data(buffer: $0) }
        let sut = AppleSoundIsolationPreprocessor()

        let output = try await sut.process(audioData: input, mode: .voiceIsolation)

        #expect(output.count == input.count)
        let outputSamples = output.withUnsafeBytes { bytes in
            Array(bytes.bindMemory(to: Float.self))
        }
        #expect(outputSamples.allSatisfy { $0.isFinite })

        let windowFrameCount = 512
        let leadingEnergy = rootMeanSquare(outputSamples.prefix(windowFrameCount))
        let trailingEnergy = rootMeanSquare(outputSamples.suffix(windowFrameCount))

        #expect(leadingEnergy > 0, "Voice-isolation latency must not leave leading silence")
        #expect(trailingEnergy > 0, "Flushing latency must preserve the recording tail")
    }

    @Test func noneAndEmptyInputAreNoOps() async throws {
        let sut = AppleSoundIsolationPreprocessor()
        let unaligned = Data([1, 2, 3])

        #expect(try await sut.process(audioData: unaligned, mode: .none) == unaligned)
        #expect(try await sut.process(audioData: Data(), mode: .voiceIsolation).isEmpty)
    }

    @Test func voiceIsolationRejectsUnalignedFloatData() async {
        let sut = AppleSoundIsolationPreprocessor()

        await #expect(throws: AudioPreprocessingError.self) {
            try await sut.process(audioData: Data([1, 2, 3]), mode: .voiceIsolation)
        }
    }
    @Test func renderLoopConsumesPartialFramesForEveryRetryableStatus() async throws {
        let output = try await renderScript(
            [
                RenderStep(status: .insufficientDataFromInputNode, samples: [0, 1]),
                RenderStep(status: .cannotDoInCurrentContext, samples: [2]),
                RenderStep(status: .success, samples: [3, 4]),
            ],
            outputStartFrame: 1,
            outputFrameCount: 3,
            tailFrameCount: 1
        )

        #expect(output == [1, 2, 3])
    }

    @Test func renderLoopCountsOnlyZeroFrameResultsAsNoProgress() async throws {
        var retryCount = 0

        do {
            _ = try await renderScript(
                [
                    RenderStep(status: .cannotDoInCurrentContext, samples: []),
                    RenderStep(status: .cannotDoInCurrentContext, samples: []),
                    RenderStep(status: .cannotDoInCurrentContext, samples: []),
                ],
                outputStartFrame: 0,
                outputFrameCount: 1,
                tailFrameCount: 0,
                maximumConsecutiveNoProgressCount: 2,
                retryDelay: {
                    retryCount += 1
                }
            )
            Issue.record("Expected rendering to stall")
        } catch AudioPreprocessingError.renderingStalled {
            #expect(retryCount == 2)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test func renderLoopRejectsEngineErrorAndUnknownStatus() async throws {
        for status in [SoundIsolationRenderStatus.error, .unknown] {
            do {
                _ = try await renderScript(
                    [RenderStep(status: status, samples: [])],
                    outputStartFrame: 0,
                    outputFrameCount: 1,
                    tailFrameCount: 0
                )
                Issue.record("Expected status \(status) to fail")
            } catch AudioPreprocessingError.renderingFailed {
                // Expected.
            } catch {
                Issue.record("Unexpected error for status \(status): \(error)")
            }
        }
    }

    @Test func renderLoopCancellationInterruptsRetryDelay() async throws {
        let retryProbe = RetryProbe()
        let task = Task {
            try await renderScript(
                [
                    RenderStep(status: .cannotDoInCurrentContext, samples: []),
                    RenderStep(status: .success, samples: [1]),
                ],
                outputStartFrame: 0,
                outputFrameCount: 1,
                tailFrameCount: 0,
                retryDelay: {
                    try await retryProbe.delay()
                }
            )
        }

        await retryProbe.waitUntilEntered()
        task.cancel()

        await #expect(throws: CancellationError.self) {
            try await task.value
        }
    }

    private struct RenderStep {
        let status: SoundIsolationRenderStatus
        let samples: [Float]
    }

    private actor RetryProbe {
        private var isEntered = false

        func delay() async throws {
            isEntered = true
            try await Task.sleep(nanoseconds: 60_000_000_000)
        }

        func waitUntilEntered() async {
            while !isEntered {
                await Task.yield()
            }
        }
    }

    private func renderScript(
        _ script: [RenderStep],
        outputStartFrame: Int,
        outputFrameCount: Int,
        tailFrameCount: Int,
        maximumConsecutiveNoProgressCount: Int = 8,
        retryDelay: @escaping () async throws -> Void = {}
    ) async throws -> [Float] {
        let maximumFrameCount = max(
            1,
            script.map(\.samples.count).max() ?? 0
        )
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16_000,
            channels: 1,
            interleaved: false
        ),
        let renderBuffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: AVAudioFrameCount(maximumFrameCount)
        )
        else {
            throw AudioPreprocessingError.audioFormatUnavailable
        }

        var remainingSteps = script
        let data = try await SoundIsolationRenderLoop.run(
            outputStartFrame: outputStartFrame,
            outputFrameCount: outputFrameCount,
            tailFrameCount: tailFrameCount,
            maximumRenderFrameCount: AVAudioFrameCount(maximumFrameCount),
            maximumConsecutiveNoProgressCount: maximumConsecutiveNoProgressCount,
            renderBuffer: renderBuffer,
            render: { _, buffer in
                guard !remainingSteps.isEmpty else {
                    return .error
                }
                let step = remainingSteps.removeFirst()
                buffer.frameLength = AVAudioFrameCount(step.samples.count)
                if !step.samples.isEmpty,
                   let channel = buffer.floatChannelData?[0]
                {
                    step.samples.withUnsafeBufferPointer { source in
                        guard let baseAddress = source.baseAddress else { return }
                        channel.update(from: baseAddress, count: step.samples.count)
                    }
                }
                return step.status
            },
            retryDelay: retryDelay
        )

        return data.withUnsafeBytes { bytes in
            Array(bytes.bindMemory(to: Float.self))
        }
    }

    private func rootMeanSquare(_ samples: ArraySlice<Float>) -> Double {
        let squaredSum = samples.reduce(0.0) { result, sample in
            result + Double(sample * sample)
        }
        return sqrt(squaredSum / Double(samples.count))
    }

}
