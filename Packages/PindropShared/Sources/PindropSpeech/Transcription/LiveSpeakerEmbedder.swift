//
//  LiveSpeakerEmbedder.swift
//  PindropSpeech
//
//  Created on 2026-08-31.
//
//  One embedding of one live speaker slot, in the offline embedding space the
//  participant profiles are already stored in.
//
//  Deliberately its own actor with its own `OfflineDiarizerManager`.
//  `FluidSpeakerDiarizer` is @MainActor and runs `process(audio:)` synchronously
//  inside that isolation, so calling it for a live six second clip would block
//  the main actor for hundreds of milliseconds and show up as orb jank. The live
//  path never reaches for it.
//
//  Deliberately on its own serial executor as well: the embedding pass is CoreML
//  work, and a cooperative-pool thread held by it is a thread the streaming
//  engine and the audio consumers are not using.
//

import Foundation
import FluidAudio
import PindropCore

/// Turns a clip of one speaker into one embedding, or says it cannot.
///
/// Nil is the only failure the live path needs: a slot that cannot be embedded
/// stays `Speaker 2`, which is already an honest label.
public protocol LiveSpeakerEmbedding: AnyObject, Sendable {
    /// One embedding in the offline space, or nil when the models are missing,
    /// the budget ran out, or the clip held no speech.
    func embed(_ samples: [Float]) async -> [Float]?
    /// Releases the models. Called at step 6 of the stop sequence, which is a
    /// stated precondition of the offline pass rather than a best effort.
    func unload() async
}

public actor LiveSpeakerEmbedder: LiveSpeakerEmbedding {

    /// Wall bound on one promotion attempt, including the first lazy load.
    ///
    /// A load that runs past it leaves the slot provisional and is retried at
    /// the next attempt, by which time the models are usually resident.
    public static let embedBudgetSeconds: TimeInterval = 2

    /// The rate the offline pass requires. Live clips come out of the diarizer's
    /// ring, which holds the resampled system tap.
    public nonisolated static let sampleRate: Int = 16_000

    /// Keeps the CoreML pass off the shared cooperative pool.
    private let queue = DispatchSerialQueue(label: "com.pindrop.live-speaker-embedder", qos: .utility)
    public nonisolated var unownedExecutor: UnownedSerialExecutor { queue.asUnownedSerialExecutor() }

    /// The same FluidAudio models root `FluidSpeakerDiarizer` resolves, so both
    /// produce embeddings in the same space. A different root here would mean
    /// scoring one space's vectors against another's centroids, which is how a
    /// confidently wrong name gets on screen.
    private let modelsDirectory: URL
    private var models: OfflineDiarizerModels?
    /// True once the models are known to be absent. The bundle does not appear
    /// mid-capture, so one failed load is the answer for the whole capture.
    private var isUnavailable = false

    /// `OfflineDiarizerModels` is not `Sendable` and the budget race has to carry
    /// it out of a detached task. Only this actor touches the value once the race
    /// resolves, so the wrapper is a narrow escape hatch and not a claim about
    /// the type.
    private struct LoadedOfflineModels: @unchecked Sendable {
        let models: OfflineDiarizerModels
    }

    public init(modelsDirectory: URL) {
        self.modelsDirectory = modelsDirectory
    }

    public func embed(_ samples: [Float]) async -> [Float]? {
        guard !isUnavailable, !samples.isEmpty else { return nil }
        guard let models = await loadedModels() else { return nil }

        do {
            var config = OfflineDiarizerConfig.default
            config.clustering.threshold = FluidSpeakerDiarizer.offlineClusteringThreshold
            // One clip, one voice. The slot is the separation the streaming
            // diarizer already made; this pass only has to describe it.
            config = config.withSpeakers(exactly: 1)
            try config.validate()

            let manager = OfflineDiarizerManager(config: config)
            manager.initialize(models: models)
            let result = try await manager.process(audio: samples)
            return embedding(
                segments: result.segments,
                speakerDatabase: result.speakerDatabase
            )
        } catch {
            Log.transcription.info(
                "Live speaker embedding failed, the slot stays provisional: \(error.localizedDescription)"
            )
            return nil
        }
    }

    public func unload() {
        models = nil
    }

    // MARK: - Private

    /// The models, loading them at the first promotion attempt rather than at
    /// capture start: most captures never promote anything, and capture start is
    /// the worst moment to spend on a model load.
    private func loadedModels() async -> OfflineDiarizerModels? {
        if let models { return models }

        let directory = modelsDirectory
        let loadTask = Task.detached(priority: .utility) {
            LoadedOfflineModels(models: try await OfflineDiarizerModels.load(from: directory))
        }
        let deadline = Task.detached(priority: .utility) { [budget = Self.embedBudgetSeconds] in
            try await Task.sleep(nanoseconds: UInt64(budget * 1_000_000_000))
            loadTask.cancel()
        }
        defer { deadline.cancel() }

        do {
            let loaded = try await loadTask.value
            models = loaded.models
            return loaded.models
        } catch is CancellationError {
            // Retried at the next attempt: the models may simply be slow to
            // page in, and one slow load is not a missing bundle.
            Log.transcription.info(
                "Live speaker embedder exceeded its \(Self.embedBudgetSeconds)s budget; slots stay provisional"
            )
            return nil
        } catch {
            isUnavailable = true
            Log.transcription.info(
                "Live speaker names need the offline speaker model: \(error.localizedDescription)"
            )
            return nil
        }
    }

    /// The single speaker's vector, preferring the longest segment's own
    /// embedding and falling back to the speaker database, exactly as the
    /// offline pass resolves it.
    private func embedding(
        segments: [TimedSpeakerSegment],
        speakerDatabase: [String: [Float]]?
    ) -> [Float]? {
        let longest = segments
            .max { ($0.endTimeSeconds - $0.startTimeSeconds) < ($1.endTimeSeconds - $1.startTimeSeconds) }
        if let longest, !longest.embedding.isEmpty { return longest.embedding }
        if let speakerID = longest?.speakerId,
           let stored = speakerDatabase?[speakerID],
           !stored.isEmpty {
            return stored
        }
        if let single = speakerDatabase?.values.first, !single.isEmpty { return single }
        return nil
    }
}
