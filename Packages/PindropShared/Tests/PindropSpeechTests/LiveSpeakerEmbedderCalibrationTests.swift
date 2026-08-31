//
//  LiveSpeakerEmbedderCalibrationTests.swift
//  PindropSpeechTests
//
//  Created on 2026-08-31.
//
//  The measurement that sets `liveMinimumSimilarityForAutoMatch` and
//  `liveMinimumSimilarityMarginForAutoMatch`.
//
//  This is a harness, not a check. It cuts single-speaker clips of the length a
//  live promotion actually uses, embeds them the way the live path does, and
//  prints the same-speaker and cross-speaker similarity distributions. The two
//  live constants are read off that output by a person; they are not tuned by
//  anything here, and the only thing asserted is that the run completed.
//
//  Gated because it needs the real offline speaker bundle on disk. Run it with:
//
//      PINDROP_RUN_INTEGRATION_TESTS=1 swift test --package-path Packages/PindropShared \
//          --filter LiveSpeakerEmbedderCalibrationTests
//

import AVFoundation
import Foundation
import Testing

@testable import PindropSpeech

private enum LiveEmbedderCalibrationSupport {

    nonisolated static var fixtureRoot: URL {
        if let configured = ProcessInfo.processInfo.environment["PINDROP_DIARIZATION_FIXTURE_ROOT"] {
            return URL(fileURLWithPath: configured, isDirectory: true)
        }
        return Bundle.module.resourceURL!
            .appendingPathComponent("Fixtures/Diarization/Generated", isDirectory: true)
    }

    /// The real download location, because the bundle this needs is the one the
    /// app itself downloads. Override it to point at a scratch copy.
    nonisolated static var modelsRoot: URL {
        if let configured = ProcessInfo.processInfo.environment["PINDROP_FLUID_AUDIO_MODELS_ROOT"] {
            return URL(fileURLWithPath: configured, isDirectory: true)
        }
        return FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("FluidAudio", isDirectory: true)
            .appendingPathComponent("Models", isDirectory: true)
    }
}

private let liveEmbedderCalibrationPrerequisitesAvailable: Bool = {
    guard ProcessInfo.processInfo.environment["PINDROP_RUN_INTEGRATION_TESTS"] == "1" else { return false }
    let root = LiveEmbedderCalibrationSupport.fixtureRoot
    return FileManager.default.fileExists(atPath: root.appendingPathComponent("ami-en2002a-0-60.wav").path)
        && FileManager.default.fileExists(atPath: root.appendingPathComponent("ami-en2002a-0-60.json").path)
}()

@Suite(
    .serialized,
    .enabled(
        if: liveEmbedderCalibrationPrerequisitesAvailable,
        "Live embedder calibration fixtures are unavailable"
    )
)
struct LiveSpeakerEmbedderCalibrationTests {

    /// The clip length a promotion attempt uses: at least the finalized-speech
    /// floor, at most the clip bound.
    private static let minimumClipSeconds: TimeInterval = 3.0
    private static let maximumClipSeconds: TimeInterval = 6.0
    private static let sampleRate: Double = 16_000

    private struct ReferenceSegment: Decodable {
        let speaker: String
        let start: TimeInterval
        let end: TimeInterval
    }

    private struct Clip {
        let speaker: String
        let samples: [Float]
    }

    @Test func liveClipSimilarityDistributionsAreReported() async throws {
        let audio = try Self.readMono16kWAV(
            LiveEmbedderCalibrationSupport.fixtureRoot
                .appendingPathComponent("ami-en2002a-0-60.wav")
        )
        let reference = try JSONDecoder().decode(
            [ReferenceSegment].self,
            from: Data(
                contentsOf: LiveEmbedderCalibrationSupport.fixtureRoot
                    .appendingPathComponent("ami-en2002a-0-60.json")
            )
        )

        let clips = Self.singleSpeakerClips(in: reference, audio: audio)
        let embedder = LiveSpeakerEmbedder(
            modelsDirectory: LiveEmbedderCalibrationSupport.modelsRoot
        )
        defer { Task { await embedder.unload() } }

        var embeddingsBySpeaker: [String: [[Float]]] = [:]
        for clip in clips {
            guard let embedding = await embedder.embed(clip.samples) else { continue }
            embeddingsBySpeaker[clip.speaker, default: []].append(embedding)
        }

        // A centroid comes from held-out clips, never from the clip it is scored
        // against: scoring a clip against a centroid it helped build reports a
        // similarity the live path can never see.
        var centroids: [String: [Float]] = [:]
        var probes: [String: [[Float]]] = [:]
        for (speaker, embeddings) in embeddingsBySpeaker where embeddings.count >= 2 {
            let split = embeddings.count / 2
            guard let centroid = Self.centroid(of: Array(embeddings.prefix(split))) else { continue }
            centroids[speaker] = centroid
            probes[speaker] = Array(embeddings.suffix(from: split))
        }

        var sameSpeaker: [Float] = []
        var crossSpeaker: [Float] = []
        for (speaker, speakerProbes) in probes {
            for probe in speakerProbes {
                for (other, centroid) in centroids {
                    let similarity = Self.cosineSimilarity(probe, centroid)
                    guard similarity.isFinite else { continue }
                    if other == speaker {
                        sameSpeaker.append(similarity)
                    } else {
                        crossSpeaker.append(similarity)
                    }
                }
            }
        }

        print("LiveSpeakerEmbedder calibration")
        print("  clips=\(clips.count) embedded=\(embeddingsBySpeaker.values.map(\.count).reduce(0, +))")
        print("  speakers=\(embeddingsBySpeaker.keys.sorted())")
        Self.report("same speaker", sameSpeaker)
        Self.report("cross speaker", crossSpeaker)
        if let sameLow = Self.percentile(sameSpeaker, 5), let crossHigh = Self.percentile(crossSpeaker, 95) {
            // The two numbers the live constants come from: a threshold under
            // the same-speaker floor and over the cross-speaker ceiling, and the
            // margin between them.
            print("  suggested similarity floor: between \(crossHigh) and \(sameLow)")
        }

        // The only assertion. Everything above is measurement, and a run that
        // reports "no clips" is itself a finding about the fixture.
        #expect(Bool(true))
    }

    // MARK: - Clips

    /// Reference segments of promotion length that no other speaker overlaps.
    ///
    /// Overlapped audio would describe two voices, and an embedding of two
    /// voices is exactly the measurement error this run exists to avoid.
    private static func singleSpeakerClips(
        in reference: [ReferenceSegment],
        audio: [Float]
    ) -> [Clip] {
        var clips: [Clip] = []
        for segment in reference.sorted(by: { $0.start < $1.start }) {
            let overlapped = reference.contains { other in
                other.speaker != segment.speaker
                    && other.start < segment.end
                    && other.end > segment.start
            }
            guard !overlapped else { continue }
            let duration = min(segment.end - segment.start, maximumClipSeconds)
            guard duration >= minimumClipSeconds else { continue }
            let first = Int(segment.start * sampleRate)
            let last = min(audio.count, first + Int(duration * sampleRate))
            guard first >= 0, last > first else { continue }
            clips.append(Clip(speaker: segment.speaker, samples: Array(audio[first..<last])))
        }
        return clips
    }

    // MARK: - Statistics

    private static func centroid(of embeddings: [[Float]]) -> [Float]? {
        guard let width = embeddings.first?.count, width > 0 else { return nil }
        var sum = [Float](repeating: 0, count: width)
        var counted = 0
        for embedding in embeddings where embedding.count == width {
            for index in 0..<width { sum[index] += embedding[index] }
            counted += 1
        }
        guard counted > 0 else { return nil }
        return sum.map { $0 / Float(counted) }
    }

    private static func cosineSimilarity(_ lhs: [Float], _ rhs: [Float]) -> Float {
        guard lhs.count == rhs.count, !lhs.isEmpty else { return .nan }
        var dot: Float = 0
        var leftNorm: Float = 0
        var rightNorm: Float = 0
        for index in 0..<lhs.count {
            dot += lhs[index] * rhs[index]
            leftNorm += lhs[index] * lhs[index]
            rightNorm += rhs[index] * rhs[index]
        }
        guard leftNorm > 0, rightNorm > 0 else { return .nan }
        return dot / (leftNorm.squareRoot() * rightNorm.squareRoot())
    }

    private static func percentile(_ values: [Float], _ percentile: Double) -> Float? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let rank = Int((percentile / 100 * Double(sorted.count)).rounded(.up)) - 1
        return sorted[min(max(rank, 0), sorted.count - 1)]
    }

    private static func report(_ label: String, _ values: [Float]) {
        guard !values.isEmpty else {
            print("  \(label): no samples")
            return
        }
        let percentiles = [5, 25, 50, 75, 95]
            .compactMap { point -> String? in
                guard let value = percentile(values, Double(point)) else { return nil }
                return "p\(point)=\(value)"
            }
            .joined(separator: " ")
        print("  \(label): n=\(values.count) min=\(values.min()!) max=\(values.max()!) \(percentiles)")
    }

    private static func readMono16kWAV(_ url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
        let frameCount = AVAudioFrameCount(file.length)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount)!
        try file.read(into: buffer)
        guard let channel = buffer.floatChannelData?[0] else { return [] }
        return Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
    }
}
