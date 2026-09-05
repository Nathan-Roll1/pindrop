//
//  AudioPreprocessor.swift
//  PindropSpeech
//
//  Created on 2026-07-22.
//

import AudioToolbox
import AVFoundation
import Foundation
import PindropCore

public protocol AudioPreprocessing: Sendable {
    func process(
        audioData: Data,
        mode: AudioPreprocessingMode
    ) async throws -> Data
}

public enum AudioPreprocessingError: Error, LocalizedError, Sendable {
    case invalidFloat32Data
    case audioFormatUnavailable
    case frameCountTooLarge
    case parameterConfigurationFailed(OSStatus)
    case renderingStalled
    case renderingFailed(String)

    public var errorDescription: String? {
        switch self {
        case .invalidFloat32Data:
            return "Audio preprocessing requires Float32-aligned PCM data."
        case .audioFormatUnavailable:
            return "The audio preprocessing format could not be created."
        case .frameCountTooLarge:
            return "The audio input is too large to preprocess."
        case .parameterConfigurationFailed(let status):
            return "Voice isolation could not be configured (status \(status))."
        case .renderingStalled:
            return "Voice isolation stopped producing audio."
        case .renderingFailed(let message):
            return "Voice isolation rendering failed: \(message)"
        }
    }
}

enum SoundIsolationRenderStatus: Equatable {
    case success
    case insufficientDataFromInputNode
    case cannotDoInCurrentContext
    case error
    case unknown

    init(_ status: AVAudioEngineManualRenderingStatus) {
        switch status {
        case .success:
            self = .success
        case .insufficientDataFromInputNode:
            self = .insufficientDataFromInputNode
        case .cannotDoInCurrentContext:
            self = .cannotDoInCurrentContext
        case .error:
            self = .error
        @unknown default:
            self = .unknown
        }
    }
}

struct SoundIsolationRenderLoop {
    typealias Render = (
        _ requestedFrameCount: AVAudioFrameCount,
        _ buffer: AVAudioPCMBuffer
    ) throws -> SoundIsolationRenderStatus

    static func run(
        outputStartFrame: Int,
        outputFrameCount: Int,
        tailFrameCount: Int,
        maximumRenderFrameCount: AVAudioFrameCount,
        maximumConsecutiveNoProgressCount: Int,
        renderBuffer: AVAudioPCMBuffer,
        render: Render,
        retryDelay: () async throws -> Void = {
            try await Task.sleep(nanoseconds: 1_000_000)
        }
    ) async throws -> Data {
        let outputEndFrame = outputStartFrame + outputFrameCount
        let totalFrameCount = outputEndFrame + tailFrameCount
        var output = Data(count: outputFrameCount * MemoryLayout<Float>.size)
        var totalFramesRendered = 0
        var outputFramesWritten = 0
        var consecutiveNoProgressCount = 0

        while totalFramesRendered < totalFrameCount {
            try Task.checkCancellation()

            let requestedFrames = AVAudioFrameCount(
                min(
                    Int(maximumRenderFrameCount),
                    totalFrameCount - totalFramesRendered
                )
            )
            renderBuffer.frameLength = 0
            let status = try render(requestedFrames, renderBuffer)

            switch status {
            case .success, .insufficientDataFromInputNode, .cannotDoInCurrentContext:
                break
            case .error:
                throw AudioPreprocessingError.renderingFailed(
                    "the audio engine returned an error status"
                )
            case .unknown:
                throw AudioPreprocessingError.renderingFailed(
                    "the audio engine returned an unknown status"
                )
            }

            let renderedFrameCount = Int(renderBuffer.frameLength)
            if renderedFrameCount > 0 {
                guard let renderedChannel = renderBuffer.floatChannelData?[0] else {
                    throw AudioPreprocessingError.audioFormatUnavailable
                }

                consecutiveNoProgressCount = 0
                let renderStartFrame = totalFramesRendered
                let renderEndFrame = renderStartFrame + renderedFrameCount
                let copyStartFrame = max(renderStartFrame, outputStartFrame)
                let copyEndFrame = min(renderEndFrame, outputEndFrame)

                if copyStartFrame < copyEndFrame {
                    let sourceOffset = copyStartFrame - renderStartFrame
                    let destinationOffset = copyStartFrame - outputStartFrame
                    let copyFrameCount = copyEndFrame - copyStartFrame
                    output.withUnsafeMutableBytes { outputBytes in
                        guard let outputBase = outputBytes.baseAddress else { return }
                        memcpy(
                            outputBase.advanced(
                                by: destinationOffset * MemoryLayout<Float>.size
                            ),
                            renderedChannel.advanced(by: sourceOffset),
                            copyFrameCount * MemoryLayout<Float>.size
                        )
                    }
                    outputFramesWritten += copyFrameCount
                }

                totalFramesRendered = renderEndFrame
                continue
            }

            consecutiveNoProgressCount += 1
            guard consecutiveNoProgressCount <= maximumConsecutiveNoProgressCount else {
                throw AudioPreprocessingError.renderingStalled
            }
            if status == .cannotDoInCurrentContext {
                try await retryDelay()
            }
        }

        guard outputFramesWritten == outputFrameCount else {
            throw AudioPreprocessingError.renderingStalled
        }
        try Task.checkCancellation()
        return output
    }
}


public struct AppleSoundIsolationPreprocessor: AudioPreprocessing {
    private static let sampleRate = 16_000.0
    private static let channelCount: AVAudioChannelCount = 1
    private static let maximumRenderFrameCount: AVAudioFrameCount = 1_024
    private static let maximumConsecutiveNoProgressCount = 8

    public init() {}

    public func process(
        audioData: Data,
        mode: AudioPreprocessingMode
    ) async throws -> Data {
        guard mode == .voiceIsolation, !audioData.isEmpty else {
            return audioData
        }
        guard audioData.count.isMultiple(of: MemoryLayout<Float>.size) else {
            throw AudioPreprocessingError.invalidFloat32Data
        }

        try Task.checkCancellation()

        let frameCount = audioData.count / MemoryLayout<Float>.size
        guard frameCount <= Int(AVAudioFrameCount.max) else {
            throw AudioPreprocessingError.frameCountTooLarge
        }
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Self.sampleRate,
            channels: Self.channelCount,
            interleaved: false
        ),
        let inputBuffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: AVAudioFrameCount(frameCount)
        ),
        let inputChannel = inputBuffer.floatChannelData?[0]
        else {
            throw AudioPreprocessingError.audioFormatUnavailable
        }

        inputBuffer.frameLength = AVAudioFrameCount(frameCount)
        audioData.withUnsafeBytes { bytes in
            guard let source = bytes.baseAddress else { return }
            memcpy(inputChannel, source, audioData.count)
        }

        let component = AudioComponentDescription(
            componentType: kAudioUnitType_Effect,
            componentSubType: kAudioUnitSubType_AUSoundIsolation,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0,
            componentFlagsMask: 0
        )
        let effect = AVAudioUnitEffect(audioComponentDescription: component)
        let parameterStatus = AudioUnitSetParameter(
            effect.audioUnit,
            kAUSoundIsolationParam_SoundToIsolate,
            kAudioUnitScope_Global,
            0,
            AudioUnitParameterValue(kAUSoundIsolationSoundType_Voice),
            0
        )
        guard parameterStatus == noErr else {
            throw AudioPreprocessingError.parameterConfigurationFailed(parameterStatus)
        }

        let engine = AVAudioEngine()

        do {
            try engine.enableManualRenderingMode(
                .offline,
                format: format,
                maximumFrameCount: Self.maximumRenderFrameCount
            )

            let player = AVAudioPlayerNode()
            defer {
                player.stop()
                engine.stop()
                engine.disableManualRenderingMode()
            }

            engine.attach(player)
            engine.attach(effect)
            engine.connect(player, to: effect, format: format)
            engine.connect(effect, to: engine.mainMixerNode, format: format)

            guard let renderBuffer = AVAudioPCMBuffer(
                pcmFormat: engine.manualRenderingFormat,
                frameCapacity: engine.manualRenderingMaximumFrameCount
            ) else {
                throw AudioPreprocessingError.audioFormatUnavailable
            }

            player.scheduleBuffer(
                inputBuffer,
                at: nil,
                options: [],
                completionCallbackType: .dataConsumed,
                completionHandler: nil
            )
            try engine.start()

            let latencyFrameCount = Int(ceil(effect.latency * Self.sampleRate))
            let tailFrameCount = Int(ceil(effect.auAudioUnit.tailTime * Self.sampleRate))
            let flushFrameCount = latencyFrameCount + tailFrameCount
            guard flushFrameCount <= Int(AVAudioFrameCount.max) else {
                throw AudioPreprocessingError.frameCountTooLarge
            }
            if flushFrameCount > 0 {
                guard let flushBuffer = AVAudioPCMBuffer(
                    pcmFormat: format,
                    frameCapacity: AVAudioFrameCount(flushFrameCount)
                ),
                let flushChannel = flushBuffer.floatChannelData?[0]
                else {
                    throw AudioPreprocessingError.audioFormatUnavailable
                }
                flushBuffer.frameLength = AVAudioFrameCount(flushFrameCount)
                memset(flushChannel, 0, flushFrameCount * MemoryLayout<Float>.size)
                player.scheduleBuffer(
                    flushBuffer,
                    at: nil,
                    options: [],
                    completionCallbackType: .dataConsumed,
                    completionHandler: nil
                )
            }
            player.play()

            return try await SoundIsolationRenderLoop.run(
                outputStartFrame: latencyFrameCount,
                outputFrameCount: frameCount,
                tailFrameCount: tailFrameCount,
                maximumRenderFrameCount: Self.maximumRenderFrameCount,
                maximumConsecutiveNoProgressCount: Self.maximumConsecutiveNoProgressCount,
                renderBuffer: renderBuffer
            ) { requestedFrameCount, buffer in
                SoundIsolationRenderStatus(
                    try engine.renderOffline(requestedFrameCount, to: buffer)
                )
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as AudioPreprocessingError {
            throw error
        } catch {
            throw AudioPreprocessingError.renderingFailed(error.localizedDescription)
        }
    }
}
