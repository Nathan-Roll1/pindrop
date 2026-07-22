// Created on 2026-07-22
//
// Focused storage-root spy coverage for package speech engines.
// Proves construction and load/download paths use injected ModelStorageLocations
// and never reconstruct default Application Support roots.

import AVFoundation
import FluidAudio
import Foundation
import Testing
import PindropCore
@testable import PindropSpeech

@MainActor
@Suite("Speech storage root injection")
struct SpeechStorageRootSpyTests {

    // MARK: - Recording spies

    @MainActor
    private final class RootRecordingEngine: TranscriptionEngine {
        private(set) var state: TranscriptionEngineState = .unloaded
        private(set) var loadCalls: [(name: String, downloadBase: URL?)] = []

        func loadModel(path: String) async throws {
            state = .ready
        }

        func loadModel(name: String, downloadBase: URL?) async throws {
            loadCalls.append((name, downloadBase))
            state = .ready
        }

        func transcribe(audioData: Data, options: TranscriptionOptions) async throws -> String {
            "ok"
        }

        func unloadModel() async {
            state = .unloaded
        }
    }

    @MainActor
    private final class RootRecordingDiarizer: SpeakerDiarizer {
        private(set) var state: SpeakerDiarizerState = .unloaded
        let mode: DiarizationMode = .offline
        let modelsDirectory: URL
        private(set) var loadModelsCallCount = 0

        init(modelsDirectory: URL) {
            self.modelsDirectory = modelsDirectory
        }

        func loadModels() async throws {
            loadModelsCallCount += 1
            state = .ready
        }

        func unloadModels() async {
            state = .unloaded
        }

        func diarize(
            samples: [Float],
            sampleRate: Int,
            options: DiarizationOptions
        ) async throws -> PindropCore.DiarizationResult {
            let speaker = Speaker(id: "S1", label: "Speaker 1", embedding: [0.1, 0.2])
            return PindropCore.DiarizationResult(
                segments: [
                    SpeakerSegment(
                        speaker: speaker,
                        startTime: 0,
                        endTime: 1,
                        confidence: 1
                    )
                ],
                speakers: [speaker],
                audioDuration: 1
            )
        }
    }

    private final class RootRecordingStreamingEngine: PindropSpeech.StreamingTranscriptionEngine {
        private(set) var state: StreamingTranscriptionState = .unloaded
        private(set) var loadNames: [String] = []
        let modelsRoot: URL

        init(modelsRoot: URL) {
            self.modelsRoot = modelsRoot
        }

        func loadModel(name: String) async throws {
            loadNames.append(name)
            state = .ready
        }

        func unloadModel() async {
            state = .unloaded
        }

        func startStreaming() async throws {
            state = .streaming
        }

        func stopStreaming() async throws -> String {
            state = .ready
            return "done"
        }

        func pauseStreaming() async {
            state = .paused
        }

        func resumeStreaming() async throws {
            state = .streaming
        }

        func processAudioChunk(_ samples: [Float]) async throws {}

        func processAudioBuffer(_ buffer: AVAudioPCMBuffer) async throws {}

        func setTranscriptionCallback(_ callback: @escaping StreamingTranscriptionCallback) async {}

        func setEndOfUtteranceCallback(_ callback: @escaping EndOfUtteranceCallback) async {}

        func reset() async {
            state = .ready
        }
    }

    private struct CapturedDownloadRoots {
        var whisperKitBases: [URL] = []
        var whisperKitPrewarmBases: [URL] = []
        var parakeetRepositories: [URL] = []
        var senseVoiceRoots: [URL] = []
        var senseVoiceLoadDirectories: [URL] = []
        var diarizationRoots: [URL] = []
        var streamingRoots: [(root: URL, folder: String)] = []
    }

    /// Mutable box so Sendable closures can record into a shared value.
    private final class Box<T>: @unchecked Sendable {
        var value: T
        init(_ value: T) { self.value = value }
    }

    private func makeRecordingOperations(
        capturing roots: Box<CapturedDownloadRoots>
    ) -> ModelManager.DownloadOperations {
        ModelManager.DownloadOperations(
            downloadWhisperKit: { _, downloadBase, onProgress in
                roots.value.whisperKitBases.append(downloadBase)
                onProgress(1.0)
            },
            prewarmWhisperKit: { _, downloadBase in
                roots.value.whisperKitPrewarmBases.append(downloadBase)
            },
            downloadAndLoadParakeet: { repositoryDirectory, _, onProgress in
                roots.value.parakeetRepositories.append(repositoryDirectory)
                onProgress(
                    DownloadUtils.DownloadProgress(
                        fractionCompleted: 1.0,
                        phase: .compiling(modelName: "")
                    )
                )
            },
            downloadSenseVoiceRepo: { fluidAudioModelsRoot, _, onProgress in
                roots.value.senseVoiceRoots.append(fluidAudioModelsRoot)
                onProgress(
                    DownloadUtils.DownloadProgress(
                        fractionCompleted: 1.0,
                        phase: .compiling(modelName: "")
                    )
                )
            },
            loadSenseVoiceModels: { repositoryDirectory, _ in
                roots.value.senseVoiceLoadDirectories.append(repositoryDirectory)
            },
            downloadOfflineDiarization: { fluidAudioModelsRoot, onProgress in
                roots.value.diarizationRoots.append(fluidAudioModelsRoot)
                onProgress(
                    DownloadUtils.DownloadProgress(
                        fractionCompleted: 0.5,
                        phase: .downloading(completedFiles: 1, totalFiles: 2)
                    )
                )
            },
            downloadStreamingRepo: { fluidAudioModelsRoot, repoFolderName in
                roots.value.streamingRoots.append((fluidAudioModelsRoot, repoFolderName))
            }
        )
    }

    private func assertNotDefaultApplicationSupport(_ url: URL) {
        #expect(!url.path.contains("/Library/Application Support/Pindrop"), "Unexpected default Pindrop path: \(url.path)")
        #expect(!url.path.contains("/Library/Application Support/FluidAudio"), "Unexpected default FluidAudio path: \(url.path)")
    }

    // MARK: - ModelManager download seams

    @Test func modelManagerWhisperKitDownloadUsesInjectedPindropRoot() async throws {
        let (locations, root) = try SpeechTestSupport.makeStorageLocations(label: "mm-whisper-spy")
        defer { try? FileManager.default.removeItem(at: root) }

        let captured = Box(CapturedDownloadRoots())
        let manager = ModelManager(
            storageLocations: locations,
            downloadOperations: makeRecordingOperations(capturing: captured)
        )

        try await manager.downloadModel(named: "openai_whisper-tiny")

        #expect(captured.value.whisperKitBases == [locations.pindropApplicationSupportRoot])
        #expect(captured.value.whisperKitPrewarmBases == [locations.pindropApplicationSupportRoot])
        for base in captured.value.whisperKitBases + captured.value.whisperKitPrewarmBases {
            #expect(base.path.hasPrefix(root.path))
            assertNotDefaultApplicationSupport(base)
        }
    }

    @Test func modelManagerParakeetDownloadUsesInjectedRepositoryDirectory() async throws {
        let (locations, root) = try SpeechTestSupport.makeStorageLocations(label: "mm-parakeet-spy")
        defer { try? FileManager.default.removeItem(at: root) }

        let captured = Box(CapturedDownloadRoots())
        let manager = ModelManager(
            storageLocations: locations,
            downloadOperations: makeRecordingOperations(capturing: captured)
        )
        let expected = ParakeetEngine.modelDirectory(
            for: .v2,
            fluidAudioModelsRoot: locations.fluidAudioModelsRoot
        )

        try await manager.downloadModel(named: "parakeet-tdt-0.6b-v2")

        #expect(captured.value.parakeetRepositories == [expected])
        #expect(captured.value.parakeetRepositories.first?.path.hasPrefix(locations.fluidAudioModelsRoot.path) == true)
        assertNotDefaultApplicationSupport(expected)
    }

    @Test func modelManagerSenseVoiceDownloadUsesInjectedFluidRootAndRepoDirectory() async throws {
        let (locations, root) = try SpeechTestSupport.makeStorageLocations(label: "mm-sense-spy")
        defer { try? FileManager.default.removeItem(at: root) }

        let captured = Box(CapturedDownloadRoots())
        let manager = ModelManager(
            storageLocations: locations,
            downloadOperations: makeRecordingOperations(capturing: captured)
        )
        let expectedRepo = SenseVoiceEngine.modelDirectory(
            fluidAudioModelsRoot: locations.fluidAudioModelsRoot
        )

        // Seed complete artifacts so modelsExist passes after the spy download.
        try seedSenseVoiceInt8Artifacts(at: expectedRepo)

        try await manager.downloadModel(named: "sensevoice-small")

        #expect(captured.value.senseVoiceRoots == [locations.fluidAudioModelsRoot])
        #expect(captured.value.senseVoiceLoadDirectories == [expectedRepo])
        assertNotDefaultApplicationSupport(locations.fluidAudioModelsRoot)
        assertNotDefaultApplicationSupport(expectedRepo)
    }

    @Test func modelManagerFeatureDownloadsUseInjectedFluidRoot() async throws {
        let (locations, root) = try SpeechTestSupport.makeStorageLocations(label: "mm-feature-spy")
        defer { try? FileManager.default.removeItem(at: root) }

        let captured = Box(CapturedDownloadRoots())
        let manager = ModelManager(
            storageLocations: locations,
            downloadOperations: makeRecordingOperations(capturing: captured)
        )

        // Diarization readiness requires artifacts after download; seed them for the spy path.
        try seedOfflineDiarizationArtifacts(at: locations.fluidAudioModelsRoot)

        try await manager.downloadFeatureModel(.diarization)
        try await manager.downloadFeatureModel(.streaming, streamingChunkProfile: .standard)

        #expect(captured.value.diarizationRoots == [locations.fluidAudioModelsRoot])
        #expect(captured.value.streamingRoots.count == 1)
        #expect(captured.value.streamingRoots.first?.root == locations.fluidAudioModelsRoot)
        #expect(captured.value.streamingRoots.first?.folder == StreamingChunkProfile.standard.repoFolderName)
        assertNotDefaultApplicationSupport(locations.fluidAudioModelsRoot)
    }

    // MARK: - TranscriptionService production paths

    @Test func transcriptionServiceLoadModelPassesExactDownloadBasesPerProvider() async throws {
        let (locations, root) = try SpeechTestSupport.makeStorageLocations(label: "svc-load-spy")
        defer { try? FileManager.default.removeItem(at: root) }

        let whisperEngine = RootRecordingEngine()
        let parakeetEngine = RootRecordingEngine()
        let senseEngine = RootRecordingEngine()

        let service = TranscriptionService(
            storageLocations: locations,
            engineFactory: { provider in
                switch provider {
                case .whisperKit: return whisperEngine
                case .parakeet: return parakeetEngine
                case .senseVoice: return senseEngine
                default:
                    throw TranscriptionService.TranscriptionError.modelLoadFailed("unexpected \(provider.rawValue)")
                }
            }
        )

        try await service.loadModel(modelName: "tiny", provider: .whisperKit)
        try await service.loadModel(modelName: "parakeet-tdt-0.6b-v3", provider: .parakeet)
        try await service.loadModel(modelName: "sensevoice-small", provider: .senseVoice)

        #expect(whisperEngine.loadCalls.map(\.name) == ["tiny"])
        #expect(whisperEngine.loadCalls.map(\.downloadBase) == [locations.pindropApplicationSupportRoot])

        let expectedParakeet = ParakeetEngine.modelDirectory(
            for: .v3,
            fluidAudioModelsRoot: locations.fluidAudioModelsRoot
        )
        #expect(parakeetEngine.loadCalls.map(\.name) == ["parakeet-tdt-0.6b-v3"])
        #expect(parakeetEngine.loadCalls.map(\.downloadBase) == [expectedParakeet])

        let expectedSense = SenseVoiceEngine.modelDirectory(
            fluidAudioModelsRoot: locations.fluidAudioModelsRoot
        )
        #expect(senseEngine.loadCalls.map(\.name) == ["sensevoice-small"])
        #expect(senseEngine.loadCalls.map(\.downloadBase) == [expectedSense])

        for url in [
            locations.pindropApplicationSupportRoot,
            expectedParakeet,
            expectedSense
        ] {
            #expect(url.path.hasPrefix(root.path))
            assertNotDefaultApplicationSupport(url)
        }
    }

    @Test func transcriptionServiceDefaultDiarizerFactoryReceivesFluidRoot() async throws {
        let (locations, root) = try SpeechTestSupport.makeStorageLocations(label: "svc-diarizer-spy")
        defer { try? FileManager.default.removeItem(at: root) }

        var capturedDirectories: [URL] = []
        var diarizer: RootRecordingDiarizer?
        let service = TranscriptionService(
            storageLocations: locations,
            engineFactory: { _ in RootRecordingEngine() },
            diarizerFactory: { modelsDirectory in
                capturedDirectories.append(modelsDirectory)
                let created = RootRecordingDiarizer(modelsDirectory: modelsDirectory)
                diarizer = created
                return created
            }
        )

        #expect(capturedDirectories.isEmpty) // factory not invoked at init

        _ = try await service.extractSpeakerProfileSegments(
            audioData: makeFloatAudioData(seconds: 1)
        )

        #expect(capturedDirectories == [locations.fluidAudioModelsRoot])
        #expect(diarizer?.modelsDirectory == locations.fluidAudioModelsRoot)
        #expect(diarizer?.loadModelsCallCount == 1)
        #expect(locations.fluidAudioModelsRoot.path.hasPrefix(root.path))
        assertNotDefaultApplicationSupport(locations.fluidAudioModelsRoot)
    }

    @Test func transcriptionServiceDefaultStreamingFactoryReceivesFluidRoot() async throws {
        let (locations, root) = try SpeechTestSupport.makeStorageLocations(label: "svc-stream-spy")
        defer { try? FileManager.default.removeItem(at: root) }

        var capturedRoots: [URL] = []
        var capturedProfiles: [StreamingChunkProfile] = []
        var engine: RootRecordingStreamingEngine?
        let service = TranscriptionService(
            storageLocations: locations,
            streamingEngineFactory: { profile, modelsRoot in
                capturedProfiles.append(profile)
                capturedRoots.append(modelsRoot)
                let created = RootRecordingStreamingEngine(modelsRoot: modelsRoot)
                engine = created
                return created
            },
            streamingChunkProfileProvider: { .standard },
            streamingBackendProvider: { .parakeet }
        )

        #expect(capturedRoots.isEmpty)

        try await service.prepareStreamingEngine()

        #expect(capturedProfiles == [.standard])
        #expect(capturedRoots == [locations.fluidAudioModelsRoot])
        #expect(engine?.modelsRoot == locations.fluidAudioModelsRoot)
        #expect(engine?.loadNames == [FeatureModelType.streamingRepoFolderName(for: .standard)])
        #expect(locations.fluidAudioModelsRoot.path.hasPrefix(root.path))
        assertNotDefaultApplicationSupport(locations.fluidAudioModelsRoot)
    }

    @Test func fluidSpeakerDiarizerAndNemotronRetainInjectedRoots() async throws {
        let (locations, root) = try SpeechTestSupport.makeStorageLocations(label: "engine-root-spy")
        defer { try? FileManager.default.removeItem(at: root) }

        let diarizer = FluidSpeakerDiarizer(modelsDirectory: locations.fluidAudioModelsRoot)
        #expect(diarizer.modelsDirectory == locations.fluidAudioModelsRoot)

        let nemotron = NemotronStreamingEngine(
            chunkProfile: .lowLatency,
            modelsRoot: locations.fluidAudioModelsRoot
        )
        let state = await nemotron.state
        let modelsRoot = await nemotron.modelsRoot
        #expect(state == .unloaded)
        #expect(modelsRoot == locations.fluidAudioModelsRoot)
        assertNotDefaultApplicationSupport(locations.fluidAudioModelsRoot)
    }

    // MARK: - Helpers

    private func makeFloatAudioData(seconds: TimeInterval, sampleRate: Int = 16_000) -> Data {
        let frameCount = max(1, Int(seconds * TimeInterval(sampleRate)))
        let samples = Array(repeating: Float(0.1), count: frameCount)
        return samples.withUnsafeBufferPointer { pointer in
            Data(buffer: pointer)
        }
    }

    private func seedSenseVoiceInt8Artifacts(at senseDir: URL) throws {
        try FileManager.default.createDirectory(at: senseDir, withIntermediateDirectories: true)
        let precision = SenseVoiceEngine.catalogPrecision
        var names = SenseVoiceEngine.requiredDownloadArtifacts(precision: precision)
        // modelsExist also requires vocab.json even though the download set omits it as aux.
        names.insert(ModelNames.SenseVoice.vocabularyFile)
        for name in names {
            let url = senseDir.appendingPathComponent(name)
            if name.hasSuffix(".mlmodelc") {
                try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
                FileManager.default.createFile(
                    atPath: url.appendingPathComponent("coremldata.bin").path,
                    contents: Data()
                )
            } else {
                FileManager.default.createFile(atPath: url.path, contents: Data("[]".utf8))
            }
        }
    }

    private func seedOfflineDiarizationArtifacts(at modelsRoot: URL) throws {
        let coreml = modelsRoot
            .appendingPathComponent(FeatureModelType.diarization.repoFolderName, isDirectory: true)
        try FileManager.default.createDirectory(at: coreml, withIntermediateDirectories: true)

        let coremlRequired = ModelNames.OfflineDiarizer.requiredModels.subtracting([
            ModelNames.OfflineDiarizer.pldaParameters
        ])
        for name in coremlRequired {
            FileManager.default.createFile(
                atPath: coreml.appendingPathComponent(name).path,
                contents: Data()
            )
        }
        FileManager.default.createFile(
            atPath: modelsRoot.appendingPathComponent("plda-parameters.json").path,
            contents: Data("{}".utf8)
        )
    }
}
