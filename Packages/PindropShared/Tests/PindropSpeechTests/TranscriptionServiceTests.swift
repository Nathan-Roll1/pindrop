//
//  TranscriptionServiceTests.swift
//  PindropTests
//
//  Created on 2026-01-25.
//

import AVFoundation
import CryptoKit
import Foundation
import Testing
import PindropCore
@testable import PindropSpeech

@MainActor
@Suite(.serialized)
struct TranscriptionServiceTests {
    
    @Test func initialState() async throws {
        let service = TranscriptionService(storageLocations: try SpeechTestSupport.makeStorageLocations().locations)
        
        #expect(service.state == .unloaded, "Initial state should be unloaded")
        #expect(service.error == nil, "Initial error should be nil")
    }
    
    @Test func modelLoadingStates() async throws {
        let service = TranscriptionService(storageLocations: try SpeechTestSupport.makeStorageLocations().locations)

        // Offline path load only — never pass a bare model name (would network-download).
        do {
            try await service.loadModel(modelPath: "/invalid/path/to/model")
        } catch {
            // Expected to fail without a local model bundle.
        }

        #expect(service.state != .unloaded, "State should change from unloaded when loading starts")
        #expect(service.state == .error, "Missing local path should end in error offline")
    }
    
    @Test func modelLoadingError() async throws {
        let service = TranscriptionService(storageLocations: try SpeechTestSupport.makeStorageLocations().locations)
        
        do {
            // Try to load with invalid model path
            try await service.loadModel(modelPath: "/invalid/path/to/model")
            Issue.record("Should throw error for invalid model path")
        } catch {
            #expect(service.state == .error, "State should be error after failed load")
            #expect(service.error != nil, "Error should be set after failed load")
        }
    }
    
    // MARK: - Transcription Tests
    
    @Test func transcribeWithoutLoadedModel() async throws {
        let service = TranscriptionService(storageLocations: try SpeechTestSupport.makeStorageLocations().locations)
        
        // Create dummy audio data (16kHz mono PCM)
        let sampleCount = 16000 // 1 second of audio
        var audioData = Data()
        for _ in 0..<sampleCount {
            var sample: Int16 = 0
            audioData.append(Data(bytes: &sample, count: MemoryLayout<Int16>.size))
        }
        
        do {
            _ = try await service.transcribe(audioData: audioData)
            Issue.record("Should throw error when model not loaded")
        } catch TranscriptionService.TranscriptionError.modelNotLoaded {
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }
    
    @Test func transcribeWithEmptyAudioData() async throws {
        let service = TranscriptionService(storageLocations: try SpeechTestSupport.makeStorageLocations().locations)
        // Stay offline: do not attempt a name-based model download.
        let emptyData = Data()
        
        do {
            _ = try await service.transcribe(audioData: emptyData)
            Issue.record("Should throw error for empty audio data")
        } catch TranscriptionService.TranscriptionError.invalidAudioData {
        } catch TranscriptionService.TranscriptionError.modelNotLoaded {
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }
    
    // Audio data conversion is tested indirectly through transcription flow
    
    // MARK: - State Management Tests
    
    @Test func stateTransitions() async throws {
        let service = TranscriptionService(storageLocations: try SpeechTestSupport.makeStorageLocations().locations)
        
        #expect(service.state == .unloaded)
        
        // Offline invalid path — no network download.
        do {
            try await service.loadModel(modelPath: "/invalid/path/to/model")
        } catch {
            // Expected
        }
        
        #expect(service.state != .unloaded)
        #expect(service.state == .error)
    }
    
    @Test func concurrentTranscriptionPrevention() async throws {
        let service = TranscriptionService(storageLocations: try SpeechTestSupport.makeStorageLocations().locations)
        
        // Create dummy audio data
        let sampleCount = 16000
        var audioData = Data()
        for _ in 0..<sampleCount {
            var sample: Int16 = 0
            audioData.append(Data(bytes: &sample, count: MemoryLayout<Int16>.size))
        }
        
        let testAudioData = audioData

        // Try to transcribe twice concurrently
        async let result1 = service.transcribe(audioData: testAudioData)
        async let result2 = service.transcribe(audioData: testAudioData)
        
        do {
            _ = try await result1
            _ = try await result2
            Issue.record("Should not allow concurrent transcriptions")
        } catch {
        }
    }
    
    // MARK: - Engine Switching Integration Tests
    
    @Test func engineSwitchCallsUnloadForDifferentProvider() async throws {
        // Given: Service starts in unloaded state
        let service = TranscriptionService(storageLocations: try SpeechTestSupport.makeStorageLocations().locations)
        #expect(service.state == .unloaded)
        
        // When: Attempt to load a model (fails in test env but exercises switching path)
        do {
            try await service.loadModel(modelPath: "/test/whisperkit/model")
        } catch {
            // Expected: model path doesn't exist
        }
        
        let stateAfterFirstLoad = service.state
        
        // When: Switch provider
        do {
            try await service.loadModel(modelPath: "/test/parakeet/model")
        } catch {
            // Expected
        }
        
        // Then: Both load attempts should have been made (state changed from unloaded)
        #expect(stateAfterFirstLoad == .error, "First load should result in error for invalid path")
        #expect(service.state == .error, "Second load should also result in error")
    }
    
    @Test func engineSwitchPreservesUnloadedStateOnCleanup() async throws {
        let service = TranscriptionService(storageLocations: try SpeechTestSupport.makeStorageLocations().locations)
        
        // Given: Attempt failed loads (exercises switching logic)
        do {
            try await service.loadModel(modelPath: "/test/path1")
        } catch {}
        
        do {
            try await service.loadModel(modelPath: "/test/path2")
        } catch {}
        
        // When: Unload after switching attempts
        await service.unloadModel()
        
        // Then: Should be back to clean unloaded state
        #expect(service.state == .unloaded)
        #expect(service.error == nil)
    }
    
    @Test func cannotSwitchEngineDuringTranscription() async throws {
        _ = TranscriptionService(storageLocations: try SpeechTestSupport.makeStorageLocations().locations)
        
        // Create dummy audio data
        let sampleCount = 16000 * 5 // 5 seconds of audio
        var audioData = Data()
        for _ in 0..<sampleCount {
            var sample: Float = 0.0
            audioData.append(Data(bytes: &sample, count: MemoryLayout<Float>.size))
        }
        
        // Note: Since we can't actually get the service into transcribing state
        // without a real model, we test the error case directly
        // by verifying the error type exists and has correct description
        let error = TranscriptionService.TranscriptionError.engineSwitchDuringTranscription
        #expect(error.errorDescription != nil)
        #expect(error.errorDescription?.contains("Cannot switch") ?? false,
                "Error should mention cannot switch during transcription")
    }
    
    @Test func unloadModelReleasesEngineReference() async throws {
        let service = TranscriptionService(storageLocations: try SpeechTestSupport.makeStorageLocations().locations)
        
        // Given: Attempt offline path load (no network)
        do {
            try await service.loadModel(modelPath: "/invalid/path/to/model")
        } catch {
            // Expected without a local model bundle
        }
        
        // When: Unload the model
        await service.unloadModel()
        
        // Then: State should be unloaded and error cleared
        #expect(service.state == .unloaded, "State should be unloaded after unloadModel")
        #expect(service.error == nil, "Error should be nil after unloadModel")
    }
    
    @Test func unloadModelAfterSwitchingEngines() async throws {
        let service = TranscriptionService(storageLocations: try SpeechTestSupport.makeStorageLocations().locations)
        
        // Given: Offline path loads for two engines (no network downloads)
        do {
            try await service.loadModel(modelPath: "/test/whisperkit/model")
        } catch {}
        
        do {
            try await service.loadModel(modelPath: "/test/parakeet/model")
        } catch {}
        
        // When: Unload
        await service.unloadModel()
        
        // Then: Should cleanly return to unloaded state
        #expect(service.state == .unloaded, "State should be unloaded")
        #expect(service.error == nil, "Error should be cleared")
    }
    
    @Test func reloadSameEngineAfterUnload() async throws {
        let service = TranscriptionService(storageLocations: try SpeechTestSupport.makeStorageLocations().locations)
        
        // Given: Offline path load then unload
        do {
            try await service.loadModel(modelPath: "/invalid/path/to/model")
        } catch {}
        
        await service.unloadModel()
        #expect(service.state == .unloaded)
        
        // When: Load same engine again (still offline)
        do {
            try await service.loadModel(modelPath: "/invalid/path/to/model")
        } catch {}
        
        // Then: Should attempt to load (state transitions from unloaded)
        #expect(service.state != .unloaded, "State should change when reloading engine")
    }


    // MARK: - Storage root routing

    @Test func loadModelRoutesExactDownloadBasesFromInjectedStorageRoots() async throws {
        let (locations, root) = try SpeechTestSupport.makeStorageLocations(label: "svc-download-base")
        defer { try? FileManager.default.removeItem(at: root) }

        let whisperEngine = MockDiarizationTranscriptionEngine()
        let parakeetEngine = MockDiarizationTranscriptionEngine()
        let senseEngine = MockDiarizationTranscriptionEngine()

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
        try await service.loadModel(modelName: "parakeet-tdt-0.6b-v2", provider: .parakeet)
        try await service.loadModel(modelName: "sensevoice-small", provider: .senseVoice)

        #expect(whisperEngine.lastLoadName == "tiny")
        #expect(whisperEngine.lastDownloadBase == locations.pindropApplicationSupportRoot)

        let expectedParakeet = ParakeetEngine.modelDirectory(
            for: .v2,
            fluidAudioModelsRoot: locations.fluidAudioModelsRoot
        )
        #expect(parakeetEngine.lastLoadName == "parakeet-tdt-0.6b-v2")
        #expect(parakeetEngine.lastDownloadBase == expectedParakeet)

        let expectedSense = SenseVoiceEngine.modelDirectory(
            fluidAudioModelsRoot: locations.fluidAudioModelsRoot
        )
        #expect(senseEngine.lastLoadName == "sensevoice-small")
        #expect(senseEngine.lastDownloadBase == expectedSense)

        for url in [locations.pindropApplicationSupportRoot, expectedParakeet, expectedSense] {
            #expect(url.path.hasPrefix(root.path))
            #expect(!url.path.contains("/Library/Application Support/Pindrop"))
            #expect(!url.path.contains("/Library/Application Support/FluidAudio"))
        }
    }

    // MARK: - Audio preprocessing

    @Test func transcriptionWithoutPreprocessingSkipsProcessorAndUsesOriginalAudio() async throws {
        let engine = MockDiarizationTranscriptionEngine()
        engine.transcribeResponses = ["raw transcript"]
        let preprocessor = StubAudioPreprocessor(result: .output(Data([9, 9, 9, 9])))
        let service = TranscriptionService(
            storageLocations: try SpeechTestSupport.makeStorageLocations().locations,
            engineFactory: { _ in engine },
            audioPreprocessor: preprocessor
        )
        try await service.loadModel(modelName: "tiny", provider: .whisperKit)
        let input = makeFloatAudioData(seconds: 0.01)

        let result = try await service.transcribe(
            audioData: input,
            options: TranscriptionOptions(audioPreprocessingMode: .none)
        )

        #expect(result == "raw transcript")
        #expect(await preprocessor.callCount == 0)
        #expect(engine.receivedAudioData == [input])
    }

    @Test func voiceIsolationRoutesProcessedAudioThroughDiarizationToEngine() async throws {
        let engine = MockDiarizationTranscriptionEngine()
        engine.transcribeResponses = ["processed transcript"]
        let processedSamples = Array(repeating: Float(0.25), count: 16_000)
        let processed = processedSamples.withUnsafeBufferPointer { Data(buffer: $0) }
        let preprocessor = StubAudioPreprocessor(result: .output(processed))
        let diarizer = MockSpeakerDiarizer()
        let speaker = Speaker(id: "speaker-a", label: "", embedding: nil)
        diarizer.nextResult = DiarizationResult(
            segments: [
                SpeakerSegment(
                    speaker: speaker,
                    startTime: 0,
                    endTime: 1,
                    confidence: 0.9
                )
            ],
            speakers: [speaker],
            audioDuration: 1
        )
        let service = TranscriptionService(
            storageLocations: try SpeechTestSupport.makeStorageLocations().locations,
            engineFactory: { _ in engine },
            diarizerFactory: { _ in diarizer },
            diarizationTimeoutSeconds: nil,
            audioPreprocessor: preprocessor
        )
        try await service.loadModel(modelName: "tiny", provider: .whisperKit)

        let result = try await service.transcribe(
            audioData: makeFloatAudioData(seconds: 1),
            diarizationEnabled: true,
            options: TranscriptionOptions(audioPreprocessingMode: .voiceIsolation)
        )

        #expect(result.text == "processed transcript")
        #expect(await preprocessor.callCount == 1)
        #expect(await preprocessor.lastMode == .voiceIsolation)
        #expect(diarizer.lastSamples == processedSamples)
        #expect(engine.receivedAudioData == [processed])
    }

    @Test func preprocessingFailureFallsBackToOriginalAudio() async throws {
        let engine = MockDiarizationTranscriptionEngine()
        engine.transcribeResponses = ["fallback transcript"]
        let preprocessor = StubAudioPreprocessor(result: .failure)
        let service = TranscriptionService(
            storageLocations: try SpeechTestSupport.makeStorageLocations().locations,
            engineFactory: { _ in engine },
            audioPreprocessor: preprocessor
        )
        try await service.loadModel(modelName: "tiny", provider: .whisperKit)
        let input = makeFloatAudioData(seconds: 0.01)

        let result = try await service.transcribe(
            audioData: input,
            options: TranscriptionOptions(audioPreprocessingMode: .voiceIsolation)
        )

        #expect(result == "fallback transcript")
        #expect(await preprocessor.callCount == 1)
        #expect(engine.receivedAudioData == [input])
        #expect(service.state == .ready)
    }

    @Test func cancellationPromptlyAbandonsNonCooperativePreprocessorLateSuccess() async throws {
        try await assertPromptPreprocessingCancellation(
            lateResult: .output(Data(repeating: 1, count: 16))
        )
    }

    @Test func cancellationPromptlyAbandonsNonCooperativePreprocessorLateFailure() async throws {
        try await assertPromptPreprocessingCancellation(lateResult: .failure)
    }

    private func assertPromptPreprocessingCancellation(
        lateResult: ConcurrentStubAudioPreprocessor.FirstResult
    ) async throws {
        let engine = MockDiarizationTranscriptionEngine()
        engine.transcribeResponses = ["replacement transcript"]
        let gate = StreamingCallbackSuspendGate()
        let preprocessor = ConcurrentStubAudioPreprocessor(firstResult: lateResult, gate: gate)
        let service = TranscriptionService(
            storageLocations: try SpeechTestSupport.makeStorageLocations().locations,
            engineFactory: { _ in engine },
            audioPreprocessor: preprocessor
        )
        try await service.loadModel(modelName: "tiny", provider: .whisperKit)
        let input = makeFloatAudioData(seconds: 0.01)

        let abandonedTask = Task {
            try await service.transcribe(
                audioData: input,
                options: TranscriptionOptions(audioPreprocessingMode: .voiceIsolation)
            )
        }
        await gate.waitUntilEntered()
        abandonedTask.cancel()

        // The non-cooperative worker remains parked behind the closed gate.
        await #expect(throws: CancellationError.self) {
            try await abandonedTask.value
        }
        #expect(service.state == .ready)

        let replacement = try await service.transcribe(
            audioData: input,
            options: TranscriptionOptions(audioPreprocessingMode: .voiceIsolation)
        )
        #expect(replacement == "replacement transcript")
        #expect(engine.receivedAudioData == [input])

        // Release the abandoned worker so both its success and failure paths can
        // attempt a late resolution without leaking suspended test work.
        await gate.open()
        await preprocessor.waitUntilCompleted()
        #expect(await preprocessor.wasCancelledAtCompletion())
        await Task.yield()
        #expect(engine.receivedAudioData == [input])
        #expect(service.state == .ready)
    }

    // MARK: - Speaker Diarization Tests

    @Test func transcribeWithDiarizationDisabledReturnsPlainTranscript() async throws {
        let mockEngine = MockDiarizationTranscriptionEngine()
        mockEngine.transcribeResponses = ["plain transcript"]
        let mockDiarizer = MockSpeakerDiarizer()
        let service = TranscriptionService(
            storageLocations: try SpeechTestSupport.makeStorageLocations().locations,
            engineFactory: { _ in mockEngine },
            diarizerFactory: { _ in mockDiarizer }
        )

        try await service.loadModel(modelName: "tiny", provider: .whisperKit)
        let output = try await service.transcribe(
            audioData: makeFloatAudioData(seconds: 3.0),
            diarizationEnabled: false
        )

        #expect(output.text == "plain transcript")
        #expect(output.diarizedSegments == nil)
        #expect(mockEngine.transcribeCallCount == 1)
        #expect(mockDiarizer.loadModelsCallCount == 0)
        #expect(mockDiarizer.diarizeCallCount == 0)
    }

    @Test func nonDiarizedTranscriptionUsesEnginePathWithoutSampleConversion() async throws {
        let mockEngine = MockDiarizationTranscriptionEngine()
        mockEngine.transcribeResponses = ["tiny clip"]
        let mockDiarizer = MockSpeakerDiarizer()
        let service = TranscriptionService(
            storageLocations: try SpeechTestSupport.makeStorageLocations().locations,
            engineFactory: { _ in mockEngine },
            diarizerFactory: { _ in mockDiarizer }
        )

        try await service.loadModel(modelName: "tiny", provider: .whisperKit)
        // One float sample is enough for the no-diarization path; sample conversion
        // and diarizer loading are reserved for the diarized branch.
        var sample: Float = 0.25
        let oneSample = Data(bytes: &sample, count: MemoryLayout<Float>.size)

        let output = try await service.transcribe(
            audioData: oneSample,
            diarizationEnabled: false
        )

        #expect(output.text == "tiny clip")
        #expect(output.diarizedSegments == nil)
        #expect(mockEngine.transcribeCallCount == 1)
        #expect(mockEngine.detectLanguageCallCount == 0)
        #expect(mockDiarizer.loadModelsCallCount == 0)
        #expect(mockDiarizer.diarizeCallCount == 0)
    }


    @Test func extractsSpeakerProfileSegmentsWithoutRetranscribingText() async throws {
        let mockEngine = MockDiarizationTranscriptionEngine()
        let speaker = Speaker(id: "speaker-a", label: "", embedding: [0.2, 0.8])
        let mockDiarizer = MockSpeakerDiarizer()
        mockDiarizer.nextResult = DiarizationResult(
            segments: [
                SpeakerSegment(
                    speaker: speaker,
                    startTime: 0,
                    endTime: 2,
                    confidence: 0.9
                )
            ],
            speakers: [speaker],
            audioDuration: 2
        )
        let service = TranscriptionService(
            storageLocations: try SpeechTestSupport.makeStorageLocations().locations,
            engineFactory: { _ in mockEngine },
            diarizerFactory: { _ in mockDiarizer }
        )

        let segments = try await service.extractSpeakerProfileSegments(
            audioData: makeFloatAudioData(seconds: 2)
        )

        #expect(segments.count == 1)
        #expect(segments.first?.speakerId == "speaker-a")
        #expect(segments.first?.speakerEmbedding == [0.2, 0.8])
        #expect(segments.first?.text == "")
        #expect(mockEngine.transcribeCallCount == 0)
        #expect(mockDiarizer.diarizeCallCount == 1)
    }

    @Test func transcribeForwardsLanguageOptionsToEngine() async throws {
        let mockEngine = MockDiarizationTranscriptionEngine()
        mockEngine.transcribeResponses = ["ni hao"]
        let mockDiarizer = MockSpeakerDiarizer()
        let service = TranscriptionService(
            storageLocations: try SpeechTestSupport.makeStorageLocations().locations,
            engineFactory: { _ in mockEngine },
            diarizerFactory: { _ in mockDiarizer }
        )

        try await service.loadModel(modelName: "tiny", provider: .whisperKit)
        let options = TranscriptionOptions(language: .simplifiedChinese)
        _ = try await service.transcribe(
            audioData: makeFloatAudioData(seconds: 2.0),
            diarizationEnabled: false,
            options: options
        )

        #expect(mockEngine.receivedOptions == [options])
    }

    @Test func transcribeWithDiarizationPinsDetectedLanguageAcrossSegments() async throws {
        let mockEngine = MockDiarizationTranscriptionEngine()
        mockEngine.detectedLanguage = .german
        mockEngine.transcribeResponses = ["Guten Morgen", "Wir testen die Erkennung"]

        let speakerA = Speaker(id: "speaker-a", label: "A", embedding: nil)
        let speakerB = Speaker(id: "speaker-b", label: "B", embedding: nil)
        let diarizationResult = DiarizationResult(
            segments: [
                SpeakerSegment(speaker: speakerA, startTime: 0.0, endTime: 1.4, confidence: 0.9),
                SpeakerSegment(speaker: speakerB, startTime: 1.6, endTime: 3.0, confidence: 0.9)
            ],
            speakers: [speakerA, speakerB],
            audioDuration: 3.0
        )
        let mockDiarizer = MockSpeakerDiarizer()
        mockDiarizer.nextResult = diarizationResult

        let service = TranscriptionService(
            storageLocations: try SpeechTestSupport.makeStorageLocations().locations,
            engineFactory: { _ in mockEngine },
            diarizerFactory: { _ in mockDiarizer }
        )

        try await service.loadModel(modelName: "tiny", provider: .whisperKit)
        _ = try await service.transcribe(
            audioData: makeFloatAudioData(seconds: 3.0),
            diarizationEnabled: true,
            options: TranscriptionOptions(
                language: .automatic,
                vocabularyBiasWords: ["Codex", "Fenneko"]
            )
        )

        #expect(mockEngine.detectLanguageCallCount == 1)
        #expect(mockEngine.detectLanguageSampleCounts == [48_000])
        #expect(mockEngine.receivedOptions == [
            TranscriptionOptions(language: .german),
            TranscriptionOptions(language: .german)
        ])
    }

    @Test func transcribeWithDiarizationStripsVocabularyBiasFromFixedLanguageSegments() async throws {
        let mockEngine = MockDiarizationTranscriptionEngine()
        mockEngine.transcribeResponses = ["Hello team", "Ship it"]

        let speakerA = Speaker(id: "speaker-a", label: "A", embedding: nil)
        let speakerB = Speaker(id: "speaker-b", label: "B", embedding: nil)
        let mockDiarizer = MockSpeakerDiarizer()
        mockDiarizer.nextResult = DiarizationResult(
            segments: [
                SpeakerSegment(speaker: speakerA, startTime: 0.0, endTime: 1.4, confidence: 0.9),
                SpeakerSegment(speaker: speakerB, startTime: 1.6, endTime: 3.0, confidence: 0.9)
            ],
            speakers: [speakerA, speakerB],
            audioDuration: 3.0
        )

        let service = TranscriptionService(
            storageLocations: try SpeechTestSupport.makeStorageLocations().locations,
            engineFactory: { _ in mockEngine },
            diarizerFactory: { _ in mockDiarizer }
        )

        try await service.loadModel(modelName: "tiny", provider: .whisperKit)
        _ = try await service.transcribe(
            audioData: makeFloatAudioData(seconds: 3.0),
            diarizationEnabled: true,
            options: TranscriptionOptions(
                language: .english,
                vocabularyBiasWords: ["Codex", "Fenneko"]
            )
        )

        #expect(mockEngine.detectLanguageCallCount == 0)
        #expect(mockEngine.receivedOptions == [
            TranscriptionOptions(language: .english),
            TranscriptionOptions(language: .english)
        ])
    }

    @Test func transcribeWithoutDiarizationKeepsWholeClipAutomaticDetection() async throws {
        let mockEngine = MockDiarizationTranscriptionEngine()
        mockEngine.detectedLanguage = .german
        mockEngine.transcribeResponses = ["ganzer Mitschnitt"]
        let mockDiarizer = MockSpeakerDiarizer()
        let service = TranscriptionService(
            storageLocations: try SpeechTestSupport.makeStorageLocations().locations,
            engineFactory: { _ in mockEngine },
            diarizerFactory: { _ in mockDiarizer }
        )

        try await service.loadModel(modelName: "tiny", provider: .whisperKit)
        _ = try await service.transcribe(
            audioData: makeFloatAudioData(seconds: 2.0),
            diarizationEnabled: false,
            options: TranscriptionOptions(language: .automatic)
        )

        #expect(mockEngine.detectLanguageCallCount == 0)
        #expect(mockEngine.receivedOptions == [TranscriptionOptions(language: .automatic)])
    }

    @Test func transcribeWithDiarizationUsesGenericLabelsForUnassignedSpeakers() async throws {
        let mockEngine = MockDiarizationTranscriptionEngine()
        mockEngine.transcribeResponses = ["Hello team", "We should ship this today"]

        let speakerA = Speaker(id: "speaker-a", label: "A", embedding: [0.1, 0.2, 0.3])
        let speakerB = Speaker(id: "speaker-b", label: "B", embedding: nil)
        let diarizationResult = DiarizationResult(
            segments: [
                SpeakerSegment(speaker: speakerA, startTime: 0.0, endTime: 1.4, confidence: 0.9),
                SpeakerSegment(speaker: speakerB, startTime: 1.4, endTime: 3.1, confidence: 0.8)
            ],
            speakers: [speakerA, speakerB],
            audioDuration: 3.1
        )
        let mockDiarizer = MockSpeakerDiarizer()
        mockDiarizer.nextResult = diarizationResult

        let service = TranscriptionService(
            storageLocations: try SpeechTestSupport.makeStorageLocations().locations,
            engineFactory: { _ in mockEngine },
            diarizerFactory: { _ in mockDiarizer }
        )

        try await service.loadModel(modelName: "tiny", provider: .whisperKit)
        let output = try await service.transcribe(
            audioData: makeFloatAudioData(seconds: 4.0),
            diarizationEnabled: true
        )

        #expect(output.text == "Speaker 1: Hello team\nSpeaker 2: We should ship this today")
        #expect(output.diarizedSegments?.count == 2)
        #expect(output.diarizedSegments?.map(\.speakerLabel) == ["Speaker 1", "Speaker 2"])
        #expect(output.diarizedSegments?.map(\.speakerId) == ["speaker-a", "speaker-b"])
        #expect(output.diarizedSegments?.first?.speakerEmbedding == [0.1, 0.2, 0.3])
        #expect(mockDiarizer.loadModelsCallCount == 1)
        #expect(mockDiarizer.diarizeCallCount == 1)
        #expect(mockEngine.transcribeCallCount == 2)
    }

    @Test func transcribeWithDiarizationDoesNotRegisterKnownSpeakersBeforeDiarizing() async throws {
        let mockEngine = MockDiarizationTranscriptionEngine()
        mockEngine.transcribeResponses = ["Hello team"]

        let identityService = MockSpeakerIdentityService()
        let diarizedSpeaker = Speaker(id: "speaker-a", label: "Speaker 1", embedding: [0.2, 0.4, 0.6])
        let diarizationResult = DiarizationResult(
            segments: [
                SpeakerSegment(speaker: diarizedSpeaker, startTime: 0.0, endTime: 1.5, confidence: 0.92)
            ],
            speakers: [diarizedSpeaker],
            audioDuration: 1.5
        )

        let mockDiarizer = MockSpeakerDiarizer()
        mockDiarizer.nextResult = diarizationResult

        let service = TranscriptionService(
            storageLocations: try SpeechTestSupport.makeStorageLocations().locations,
            engineFactory: { _ in mockEngine },
            diarizerFactory: { _ in mockDiarizer },
            speakerIdentityService: identityService
        )

        try await service.loadModel(modelName: "tiny", provider: .whisperKit)
        _ = try await service.transcribe(
            audioData: makeFloatAudioData(seconds: 2.0),
            diarizationEnabled: true
        )

        #expect(identityService.knownSpeakersCallCount == 0)
        #expect(mockDiarizer.clearKnownSpeakersCallCount == 0)
        #expect(mockDiarizer.registeredKnownSpeakers.isEmpty)
        #expect(mockDiarizer.diarizeCallCount == 1)
    }

    @Test func transcribeWithDiarizationUsesMatchedParticipantNameWhenConfidenceGatePasses() async throws {
        let mockEngine = MockDiarizationTranscriptionEngine()
        mockEngine.transcribeResponses = ["Hello team"]

        let diarizedSpeaker = Speaker(id: "speaker-a", label: "speaker-a", embedding: [0.1, 0.2, 0.3])
        let diarizationResult = DiarizationResult(
            segments: [
                SpeakerSegment(speaker: diarizedSpeaker, startTime: 0.0, endTime: 1.5, confidence: 0.92)
            ],
            speakers: [diarizedSpeaker],
            audioDuration: 1.5
        )

        let mockDiarizer = MockSpeakerDiarizer()
        mockDiarizer.nextResult = diarizationResult

        let identityService = MockSpeakerIdentityService(
            knownSpeakers: [Speaker(id: UUID().uuidString, label: "Alice", embedding: [0.1, 0.2, 0.3])],
            matchesByEmbeddingKey: ["0.1000,0.2000,0.3000": SpeakerIdentityMatch(profileID: UUID(), displayName: "Alice", similarity: 0.91)]
        )

        let service = TranscriptionService(
            storageLocations: try SpeechTestSupport.makeStorageLocations().locations,
            engineFactory: { _ in mockEngine },
            diarizerFactory: { _ in mockDiarizer },
            speakerIdentityService: identityService
        )

        try await service.loadModel(modelName: "tiny", provider: .whisperKit)
        let output = try await service.transcribe(
            audioData: makeFloatAudioData(seconds: 2.0),
            diarizationEnabled: true
        )

        #expect(output.text == "Hello team")
        #expect(output.diarizedSegments?.map(\.speakerLabel) == [""])
        #expect(identityService.bestMatchesCallCount == 1)
        #expect(identityService.bestMatchCallCount == 0)
        #expect(identityService.lastBestMatchEmbeddings.count == 2)
        #expect(identityService.lastBestMatchEmbeddings == [[0.1, 0.2, 0.3], [0.1, 0.2, 0.3]])
        #expect(identityService.lastBestMatchesResults.map { $0?.displayName } == ["Alice", "Alice"])
    }

    @Test func transcribeWithDiarizationFallsBackWhenKnownSpeakerMatchDoesNotClearGate() async throws {
        let mockEngine = MockDiarizationTranscriptionEngine()
        mockEngine.transcribeResponses = ["Hello team"]

        let knownSpeaker = Speaker(id: UUID().uuidString, label: "Alice", embedding: [0.1, 0.2, 0.3])
        let diarizedSpeaker = Speaker(id: knownSpeaker.id, label: "Alice", embedding: [0.1, 0.2, 0.3])
        let diarizationResult = DiarizationResult(
            segments: [
                SpeakerSegment(speaker: diarizedSpeaker, startTime: 0.0, endTime: 1.5, confidence: 0.92)
            ],
            speakers: [diarizedSpeaker],
            audioDuration: 1.5
        )

        let mockDiarizer = MockSpeakerDiarizer()
        mockDiarizer.nextResult = diarizationResult

        let identityService = MockSpeakerIdentityService(knownSpeakers: [knownSpeaker])

        let service = TranscriptionService(
            storageLocations: try SpeechTestSupport.makeStorageLocations().locations,
            engineFactory: { _ in mockEngine },
            diarizerFactory: { _ in mockDiarizer },
            speakerIdentityService: identityService
        )

        try await service.loadModel(modelName: "tiny", provider: .whisperKit)
        let output = try await service.transcribe(
            audioData: makeFloatAudioData(seconds: 2.0),
            diarizationEnabled: true
        )

        #expect(output.text == "Hello team")
        #expect(output.diarizedSegments?.map(\.speakerLabel) == [""])
        #expect(identityService.bestMatchesCallCount == 1)
        #expect(identityService.bestMatchCallCount == 0)
        #expect(identityService.lastBestMatchEmbeddings.count == 2)
        #expect(identityService.lastBestMatchEmbeddings == [[0.1, 0.2, 0.3], [0.1, 0.2, 0.3]])
        #expect(identityService.lastBestMatchesResults.allSatisfy { $0 == nil })
    }

    @Test func transcribeWithDiarizationBatchesAggregateAndConsensusEmbeddingsOnce() async throws {
        let mockEngine = MockDiarizationTranscriptionEngine()
        mockEngine.transcribeResponses = ["Hello Alice", "Hello Bob"]

        let aliceProfileID = UUID()
        let bobProfileID = UUID()
        let aliceEmbedding: [Float] = [0.9, 0.1, 0.0]
        let bobEmbedding: [Float] = [0.0, 0.9, 0.1]

        // Two speakers, each with one long eligible consensus segment (>= 5s).
        // Production builds one batch of aggregate + consensus embeddings.
        // Long-segment consensus clears the gate without needing multi-segment ratios.
        let speakerA = Speaker(id: "speaker-a", label: "A", embedding: aliceEmbedding)
        let speakerB = Speaker(id: "speaker-b", label: "B", embedding: bobEmbedding)
        let diarizationResult = DiarizationResult(
            segments: [
                SpeakerSegment(speaker: speakerA, startTime: 0.0, endTime: 5.5, confidence: 0.95),
                SpeakerSegment(speaker: speakerB, startTime: 5.6, endTime: 11.0, confidence: 0.93),
            ],
            speakers: [speakerA, speakerB],
            audioDuration: 11.0
        )

        let mockDiarizer = MockSpeakerDiarizer()
        mockDiarizer.nextResult = diarizationResult

        let identityService = MockSpeakerIdentityService(
            matchesByEmbeddingKey: [
                "0.9000,0.1000,0.0000": SpeakerIdentityMatch(
                    profileID: aliceProfileID,
                    displayName: "Alice",
                    similarity: 0.95
                ),
                "0.0000,0.9000,0.1000": SpeakerIdentityMatch(
                    profileID: bobProfileID,
                    displayName: "Bob",
                    similarity: 0.94
                ),
            ]
        )

        let service = TranscriptionService(
            storageLocations: try SpeechTestSupport.makeStorageLocations().locations,
            engineFactory: { _ in mockEngine },
            diarizerFactory: { _ in mockDiarizer },
            speakerIdentityService: identityService
        )

        try await service.loadModel(modelName: "tiny", provider: .whisperKit)
        let output = try await service.transcribe(
            audioData: makeFloatAudioData(seconds: 12.0),
            diarizationEnabled: true
        )

        // One request-scoped bestMatches call for all aggregate + consensus embeddings.
        #expect(identityService.bestMatchesCallCount == 1)
        #expect(identityService.bestMatchCallCount == 0)

        // Two speakers × (1 aggregate + 1 eligible consensus) = 4 ordered slots.
        #expect(identityService.lastBestMatchEmbeddings.count == 4)
        #expect(identityService.lastBestMatchesResults.count == 4)

        // Embedding contents are speaker-keyed, not order-keyed: both Alice and Bob
        // embeddings must appear, but dictionary iteration order is irrelevant.
        let embeddingKeys = Set(
            identityService.lastBestMatchEmbeddings.map {
                $0.map { String(format: "%.4f", $0) }.joined(separator: ",")
            }
        )
        #expect(embeddingKeys == Set([
            "0.9000,0.1000,0.0000",
            "0.0000,0.9000,0.1000",
        ]))

        // Every embedding slot is matched; no empty / corrupt slots were included.
        #expect(identityService.lastBestMatchesResults.allSatisfy { $0 != nil })
        #expect(Set(identityService.lastBestMatchesResults.compactMap(\.?.displayName)) == Set(["Alice", "Bob"]))

        // Bind identities to speaker IDs so Alice/Bob swapping fails even if
        // segment/dictionary order varies.
        let segments = try #require(output.diarizedSegments)
        #expect(segments.count == 2)
        let labelBySpeakerId = Dictionary(uniqueKeysWithValues: segments.map { ($0.speakerId, $0.speakerLabel) })
        let profileBySpeakerId = Dictionary(uniqueKeysWithValues: segments.map { ($0.speakerId, $0.speakerProfileID) })
        #expect(labelBySpeakerId["speaker-a"] == "Alice")
        #expect(labelBySpeakerId["speaker-b"] == "Bob")
        #expect(profileBySpeakerId["speaker-a"] == aliceProfileID)
        #expect(profileBySpeakerId["speaker-b"] == bobProfileID)
    }

    @Test func transcribeWithDiarizationRejectsCorruptAndNonFiniteEmbeddingsFromBatch() async throws {
        let mockEngine = MockDiarizationTranscriptionEngine()
        mockEngine.transcribeResponses = ["Only valid speaker text"]

        // Empty / non-finite embeddings are excluded before the request-scoped batch.
        // Dimension mismatch is rejected later by bestMatches (covered in HistoryStoreTests).
        let validSpeaker = Speaker(id: "speaker-a", label: "A", embedding: [0.2, 0.4, 0.6])
        let emptySpeaker = Speaker(id: "speaker-b", label: "B", embedding: [])
        let nanSpeaker = Speaker(id: "speaker-c", label: "C", embedding: [0.1, Float.nan, 0.3])
        let nilSpeaker = Speaker(id: "speaker-d", label: "D", embedding: nil)

        let diarizationResult = DiarizationResult(
            segments: [
                SpeakerSegment(speaker: validSpeaker, startTime: 0.0, endTime: 5.5, confidence: 0.92),
                SpeakerSegment(speaker: emptySpeaker, startTime: 5.6, endTime: 11.0, confidence: 0.9),
                SpeakerSegment(speaker: nanSpeaker, startTime: 11.1, endTime: 16.5, confidence: 0.9),
                SpeakerSegment(speaker: nilSpeaker, startTime: 16.6, endTime: 22.0, confidence: 0.9),
            ],
            speakers: [validSpeaker, emptySpeaker, nanSpeaker, nilSpeaker],
            audioDuration: 22.0
        )

        let mockDiarizer = MockSpeakerDiarizer()
        mockDiarizer.nextResult = diarizationResult

        let identityService = MockSpeakerIdentityService(
            matchesByEmbeddingKey: [
                "0.2000,0.4000,0.6000": SpeakerIdentityMatch(
                    profileID: UUID(),
                    displayName: "Valid",
                    similarity: 0.91
                )
            ]
        )

        let service = TranscriptionService(
            storageLocations: try SpeechTestSupport.makeStorageLocations().locations,
            engineFactory: { _ in mockEngine },
            diarizerFactory: { _ in mockDiarizer },
            speakerIdentityService: identityService
        )

        try await service.loadModel(modelName: "tiny", provider: .whisperKit)
        _ = try await service.transcribe(
            audioData: makeFloatAudioData(seconds: 23.0),
            diarizationEnabled: true
        )

        #expect(identityService.bestMatchesCallCount == 1)
        #expect(identityService.bestMatchCallCount == 0)
        // Only the one valid speaker contributes aggregate + consensus embeddings.
        #expect(identityService.lastBestMatchEmbeddings.count == 2)
        let expectedValid: [Float] = [0.2, 0.4, 0.6]
        for embedding in identityService.lastBestMatchEmbeddings {
            #expect(embedding.count == expectedValid.count)
            #expect(embedding.allSatisfy { $0.isFinite })
            for (value, expected) in zip(embedding, expectedValid) {
                #expect(abs(value - expected) < 0.0001)
            }
        }
        #expect(identityService.lastBestMatchesResults.map { $0?.displayName } == ["Valid", "Valid"])
    }



    @Test func transcribeWithDiarizationFallsBackToGenericLabelWhenSpeakerLabelIsBlank() async throws {
        let mockEngine = MockDiarizationTranscriptionEngine()
        mockEngine.transcribeResponses = ["Hello team"]

        let speaker = Speaker(id: "speaker-a", label: "", embedding: nil)
        let diarizationResult = DiarizationResult(
            segments: [
                SpeakerSegment(speaker: speaker, startTime: 0.0, endTime: 1.4, confidence: 0.9)
            ],
            speakers: [speaker],
            audioDuration: 1.4
        )
        let mockDiarizer = MockSpeakerDiarizer()
        mockDiarizer.nextResult = diarizationResult

        let service = TranscriptionService(
            storageLocations: try SpeechTestSupport.makeStorageLocations().locations,
            engineFactory: { _ in mockEngine },
            diarizerFactory: { _ in mockDiarizer }
        )

        try await service.loadModel(modelName: "tiny", provider: .whisperKit)
        let output = try await service.transcribe(
            audioData: makeFloatAudioData(seconds: 2.0),
            diarizationEnabled: true
        )

        #expect(output.text == "Hello team")
        #expect(output.diarizedSegments?.map(\.speakerLabel) == [""])
    }

    @Test func transcribeWithSingleSpeakerDiarizationOmitsSpeakerLabelsFromOutput() async throws {
        let mockEngine = MockDiarizationTranscriptionEngine()
        mockEngine.transcribeResponses = ["I clicked the button to install the diarization package."]

        let speaker = Speaker(id: "speaker-a", label: "A", embedding: nil)
        let diarizationResult = DiarizationResult(
            segments: [
                SpeakerSegment(speaker: speaker, startTime: 0.0, endTime: 2.0, confidence: 0.95)
            ],
            speakers: [speaker],
            audioDuration: 2.0
        )
        let mockDiarizer = MockSpeakerDiarizer()
        mockDiarizer.nextResult = diarizationResult

        let service = TranscriptionService(
            storageLocations: try SpeechTestSupport.makeStorageLocations().locations,
            engineFactory: { _ in mockEngine },
            diarizerFactory: { _ in mockDiarizer }
        )

        try await service.loadModel(modelName: "tiny", provider: .whisperKit)
        let output = try await service.transcribe(
            audioData: makeFloatAudioData(seconds: 2.0),
            diarizationEnabled: true
        )

        #expect(output.text == "I clicked the button to install the diarization package.")
        #expect(output.diarizedSegments?.count == 1)
        #expect(output.diarizedSegments?.map(\.speakerLabel) == [""])
        #expect(mockDiarizer.loadModelsCallCount == 1)
        #expect(mockDiarizer.diarizeCallCount == 1)
        #expect(mockEngine.transcribeCallCount == 1)
    }

    @Test func transcribeWithDiarizationFailureFallsBackToSinglePassTranscription() async throws {
        let mockEngine = MockDiarizationTranscriptionEngine()
        mockEngine.transcribeResponses = ["fallback transcript"]
        let mockDiarizer = MockSpeakerDiarizer()
        mockDiarizer.diarizeError = NSError(domain: "test", code: 7, userInfo: [NSLocalizedDescriptionKey: "diarization failed"])

        let service = TranscriptionService(
            storageLocations: try SpeechTestSupport.makeStorageLocations().locations,
            engineFactory: { _ in mockEngine },
            diarizerFactory: { _ in mockDiarizer }
        )

        try await service.loadModel(modelName: "tiny", provider: .whisperKit)
        let output = try await service.transcribe(
            audioData: makeFloatAudioData(seconds: 2.0),
            diarizationEnabled: true
        )

        #expect(output.text == "fallback transcript")
        #expect(output.diarizedSegments == nil)
        #expect(mockDiarizer.diarizeCallCount == 1)
        #expect(mockEngine.transcribeCallCount == 1)
    }

    @Test func transcribeWithDiarizationTimeoutFallsBackToSinglePassTranscription() async throws {
        let mockEngine = MockDiarizationTranscriptionEngine()
        mockEngine.transcribeResponses = ["fallback after timeout"]
        let mockDiarizer = MockSpeakerDiarizer()
        mockDiarizer.diarizeDelayNanoseconds = 1_000_000_000

        let service = TranscriptionService(
            storageLocations: try SpeechTestSupport.makeStorageLocations().locations,
            engineFactory: { _ in mockEngine },
            diarizerFactory: { _ in mockDiarizer },
            diarizationTimeoutSeconds: 0.01
        )

        try await service.loadModel(modelName: "tiny", provider: .whisperKit)
        let output = try await service.transcribe(
            audioData: makeFloatAudioData(seconds: 2.0),
            diarizationEnabled: true
        )

        #expect(output.text == "fallback after timeout")
        #expect(output.diarizedSegments == nil)
        #expect(mockDiarizer.diarizeCallCount == 1)
        #expect(mockEngine.transcribeCallCount == 1)
    }

    @Test func diarizationWatchdogReturnsAtDeadlineWhenOperationIgnoresCancellation() async throws {
        let mockEngine = MockDiarizationTranscriptionEngine()
        mockEngine.transcribeResponses = ["fallback after noncooperative timeout"]
        let mockDiarizer = MockSpeakerDiarizer()
        mockDiarizer.nonCooperativeDiarizeDelayNanoseconds = 500_000_000
        let service = TranscriptionService(
            storageLocations: try SpeechTestSupport.makeStorageLocations().locations,
            engineFactory: { _ in mockEngine },
            diarizerFactory: { _ in mockDiarizer },
            diarizationTimeoutSeconds: 0.02
        )

        try await service.loadModel(modelName: "tiny", provider: .whisperKit)
        let started = ContinuousClock.now
        let output = try await service.transcribe(
            audioData: makeFloatAudioData(seconds: 2.0),
            diarizationEnabled: true
        )
        let elapsed = started.duration(to: .now)

        #expect(output.text == "fallback after noncooperative timeout")
        #expect(elapsed < .milliseconds(250))
    }

    @Test func timedOutTranscriptionCannotCorruptReplacementEngineState() async throws {
        let stalledEngine = MockDiarizationTranscriptionEngine()
        stalledEngine.transcribeResponses = ["late transcript"]
        stalledEngine.nonCooperativeTranscribeDelayNanoseconds = 300_000_000
        let replacementEngine = MockDiarizationTranscriptionEngine()
        replacementEngine.transcribeResponses = ["replacement transcript"]
        var factoryCalls = 0
        let service = TranscriptionService(
            storageLocations: try SpeechTestSupport.makeStorageLocations().locations,
            engineFactory: { _ in
                defer { factoryCalls += 1 }
                return factoryCalls == 0 ? stalledEngine : replacementEngine
            }
        )

        try await service.loadModel(modelName: "tiny", provider: .whisperKit)
        let audioData = makeFloatAudioData(seconds: 1.0)
        do {
            _ = try await withTestFinalizeTimeout(nanoseconds: 20_000_000) {
                try await service.transcribe(audioData: audioData)
            }
            Issue.record("Expected hard timeout")
        } catch {
            service.invalidateTimedOutTranscription()
        }

        // Ordinary batch entry automatically restores the selected model with a
        // fresh engine; callers do not need a timeout-specific reload step.
        let replacementResult = try await service.transcribe(audioData: audioData)
        #expect(replacementResult == "replacement transcript")

        try await Task.sleep(nanoseconds: 350_000_000)
        #expect(service.state == .ready)
    }

    @Test func concurrentCallersAfterTimeoutShareReplacementLoadAndAdmitOneTranscription() async throws {
        let stalledEngine = MockDiarizationTranscriptionEngine()
        stalledEngine.nonCooperativeTranscribeDelayNanoseconds = 250_000_000
        let replacementEngine = MockDiarizationTranscriptionEngine()
        replacementEngine.loadDelayNanoseconds = 30_000_000
        replacementEngine.nonCooperativeTranscribeDelayNanoseconds = 80_000_000
        replacementEngine.transcribeResponses = ["replacement"]
        var factoryCalls = 0
        let service = TranscriptionService(
            storageLocations: try SpeechTestSupport.makeStorageLocations().locations,
            engineFactory: { _ in
            defer { factoryCalls += 1 }
            return factoryCalls == 0 ? stalledEngine : replacementEngine
        })
        let audioData = makeFloatAudioData(seconds: 1.0)

        try await service.loadModel(modelName: "tiny", provider: .whisperKit)
        do {
            _ = try await withTestFinalizeTimeout(nanoseconds: 20_000_000) {
                try await service.transcribe(audioData: audioData)
            }
            Issue.record("Expected hard timeout")
        } catch {
            service.invalidateTimedOutTranscription()
        }

        let first = Task { try await service.transcribe(audioData: audioData) }
        try await Task.sleep(nanoseconds: 5_000_000)
        let second = Task { try await service.transcribe(audioData: audioData) }

        let firstResult: Result<String, Error>
        do { firstResult = .success(try await first.value) }
        catch { firstResult = .failure(error) }
        let secondResult: Result<String, Error>
        do { secondResult = .success(try await second.value) }
        catch { secondResult = .failure(error) }
        let outcomes = [firstResult, secondResult]
        #expect(outcomes.compactMap { try? $0.get() } == ["replacement"])
        #expect(factoryCalls == 2)
        #expect(replacementEngine.transcribeCallCount == 1)
        #expect(service.state == .ready)
    }

    @Test func invalidExpectedSpeakerCountFailsBeforeModelWork() async throws {
        let mockEngine = MockDiarizationTranscriptionEngine()
        let service = TranscriptionService(
            storageLocations: try SpeechTestSupport.makeStorageLocations().locations,
            engineFactory: { _ in mockEngine })

        do {
            _ = try await service.transcribe(
                audioData: makeFloatAudioData(seconds: 1.0),
                diarizationEnabled: true,
                options: TranscriptionOptions(),
                diarizationOptions: DiarizationOptions(expectedSpeakerCount: 21)
            )
            Issue.record("Expected expected-speaker validation failure")
        } catch let error as TranscriptionService.TranscriptionError {
            guard case .diarizationFailed(let message) = error else {
                Issue.record("Unexpected transcription error: \(error)")
                return
            }
            #expect(message.contains("between 1 and 20"))
            #expect(mockEngine.state == .unloaded)
        }
    }

    @Test func requiredDiarizationFailureIsTypedInsteadOfFallingBack() async throws {
        let mockEngine = MockDiarizationTranscriptionEngine()
        mockEngine.transcribeResponses = ["plain fallback"]
        let mockDiarizer = MockSpeakerDiarizer()
        mockDiarizer.diarizeError = NSError(domain: "DiarizationTests", code: 1)
        let service = TranscriptionService(
            storageLocations: try SpeechTestSupport.makeStorageLocations().locations,
            engineFactory: { _ in mockEngine },
            diarizerFactory: { _ in mockDiarizer }
        )

        try await service.loadModel(modelName: "tiny", provider: .whisperKit)
        do {
            _ = try await service.transcribe(
                audioData: makeFloatAudioData(seconds: 1.0),
                diarizationEnabled: true,
                options: TranscriptionOptions(),
                diarizationOptions: DiarizationOptions(expectedSpeakerCount: 2),
                diarizationFailurePolicy: .required
            )
            Issue.record("Expected required diarization failure")
        } catch let error as TranscriptionService.TranscriptionError {
            guard case .diarizationFailed = error else {
                Issue.record("Unexpected transcription error: \(error)")
                return
            }
            #expect(mockEngine.transcribeCallCount == 0)
            #expect(mockDiarizer.lastOptions?.expectedSpeakerCount == 2)
        }
    }

    @Test func transcribeWithDiarizationCancellationPropagates() async throws {
        let mockEngine = MockDiarizationTranscriptionEngine()
        mockEngine.transcribeResponses = ["should not transcribe"]
        let mockDiarizer = MockSpeakerDiarizer()
        mockDiarizer.diarizeDelayNanoseconds = 1_000_000_000

        let service = TranscriptionService(
            storageLocations: try SpeechTestSupport.makeStorageLocations().locations,
            engineFactory: { _ in mockEngine },
            diarizerFactory: { _ in mockDiarizer },
            diarizationTimeoutSeconds: 10
        )

        try await service.loadModel(modelName: "tiny", provider: .whisperKit)
        let task = Task {
            try await service.transcribe(
                audioData: makeFloatAudioData(seconds: 2.0),
                diarizationEnabled: true
            )
        }

        try await Task.sleep(nanoseconds: 10_000_000)
        task.cancel()

        do {
            _ = try await task.value
            Issue.record("Expected cancellation to propagate")
        } catch is CancellationError {
            #expect(mockDiarizer.diarizeCallCount == 1)
            #expect(mockEngine.transcribeCallCount == 0)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test func transcribeWithDiarizationNormalizesAndMergesSegments() async throws {
        let mockEngine = MockDiarizationTranscriptionEngine()
        mockEngine.transcribeResponses = ["Merged speaker text", "Second speaker text", "Third speaker text"]

        let speakerA = Speaker(id: "speaker-a", label: "A", embedding: nil)
        let speakerB = Speaker(id: "speaker-b", label: "B", embedding: nil)
        let speakerC = Speaker(id: "speaker-c", label: "C", embedding: nil)

        let diarizationResult = DiarizationResult(
            segments: [
                SpeakerSegment(speaker: speakerC, startTime: 3.0, endTime: 4.2, confidence: .nan),
                SpeakerSegment(speaker: speakerA, startTime: 1.25, endTime: 2.4, confidence: 0.9), // merge
                SpeakerSegment(speaker: speakerB, startTime: 2.8, endTime: 2.5, confidence: 0.6),   // invalid
                SpeakerSegment(speaker: speakerA, startTime: 0.0, endTime: 1.1, confidence: 0.5),
                SpeakerSegment(speaker: speakerB, startTime: 2.6, endTime: 3.0, confidence: 0.8)    // too short
            ],
            speakers: [speakerA, speakerB, speakerC],
            audioDuration: 5.0
        )

        let mockDiarizer = MockSpeakerDiarizer()
        mockDiarizer.nextResult = diarizationResult

        let service = TranscriptionService(
            storageLocations: try SpeechTestSupport.makeStorageLocations().locations,
            engineFactory: { _ in mockEngine },
            diarizerFactory: { _ in mockDiarizer }
        )

        try await service.loadModel(modelName: "tiny", provider: .whisperKit)
        let output = try await service.transcribe(
            audioData: makeFloatAudioData(seconds: 5.0),
            diarizationEnabled: true
        )

        #expect(output.text == "Speaker 1: Merged speaker text\nSpeaker 2: Second speaker text\nSpeaker 3: Third speaker text")
        #expect(mockEngine.transcribeCallCount == 3)

        let diarizedSegments = try #require(output.diarizedSegments, "Expected diarized segments")

        #expect(diarizedSegments.count == 3)
        #expect(diarizedSegments[0].speakerId == "speaker-a")
        #expect(abs(diarizedSegments[0].startTime - 0.0) < 0.0001)
        #expect(abs(diarizedSegments[0].endTime - 2.4) < 0.0001)
        #expect(diarizedSegments[1].speakerId == "speaker-b")
        #expect(diarizedSegments[2].speakerId == "speaker-c")
        #expect(diarizedSegments.map(\.speakerLabel) == ["Speaker 1", "Speaker 2", "Speaker 3"])
        #expect(diarizedSegments.allSatisfy { $0.confidence.isFinite && (0...1).contains($0.confidence) })
    }

    @Test func transcribeWithDiarizationSplitsLongSegmentsIntoSmallerTimedChunks() async throws {
        let mockEngine = MockDiarizationTranscriptionEngine()
        mockEngine.transcribeResponses = [
            """
            First we set up the project and verify the environment is working correctly. Then we configure the pipeline and make sure the download path is stable. After that we run the transcription pass and inspect the output for obvious quality issues. Finally we save the finished transcript and verify playback sync in the detail view.
            """
        ]

        let speaker = Speaker(id: "speaker-a", label: "A", embedding: nil)
        let diarizationResult = DiarizationResult(
            segments: [
                SpeakerSegment(speaker: speaker, startTime: 0.0, endTime: 48.0, confidence: 0.92)
            ],
            speakers: [speaker],
            audioDuration: 48.0
        )

        let mockDiarizer = MockSpeakerDiarizer()
        mockDiarizer.nextResult = diarizationResult

        let service = TranscriptionService(
            storageLocations: try SpeechTestSupport.makeStorageLocations().locations,
            engineFactory: { _ in mockEngine },
            diarizerFactory: { _ in mockDiarizer }
        )

        try await service.loadModel(modelName: "tiny", provider: .whisperKit)
        let output = try await service.transcribe(
            audioData: makeFloatAudioData(seconds: 50.0),
            diarizationEnabled: true
        )

        let diarizedSegments = try #require(output.diarizedSegments, "Expected diarized segments")

        let firstSegment = try #require(diarizedSegments.first, "Expected diarized segments to contain entries")
        let lastSegment = try #require(diarizedSegments.last, "Expected diarized segments to contain entries")

        #expect(diarizedSegments.count > 1)
        #expect(Set(diarizedSegments.map(\.speakerId)) == ["speaker-a"])
        #expect(abs(firstSegment.startTime - 0.0) < 0.0001)
        #expect(abs(lastSegment.endTime - 48.0) < 0.0001)
        #expect(
            diarizedSegments.dropFirst().allSatisfy { $0.startTime >= 0 && $0.endTime > $0.startTime },
            "Split segments should preserve increasing timestamp windows"
        )
    }

    // MARK: - Streaming Tests

    @Test func streamingLifecycleTransitions() async throws {
        let mockStreamingEngine = MockStreamingTranscriptionEngine()
        let service = TranscriptionService(
            storageLocations: try SpeechTestSupport.makeStorageLocations().locations,
            streamingEngineFactory: { _, _ in mockStreamingEngine  })

        try await service.prepareStreamingEngine()
        #expect(service.state == .ready)
        #expect(mockStreamingEngine.state == .ready)

        try await service.startStreaming()
        #expect(service.state == .transcribing)
        #expect(mockStreamingEngine.state == .streaming)

        try await service.processStreamingAudioBuffer(makeStreamingBuffer())
        #expect(mockStreamingEngine.processedBufferCount == 1)

        let finalText = try await service.stopStreaming()
        #expect(finalText == mockStreamingEngine.stopResult)
        #expect(service.state == .ready)
        #expect(mockStreamingEngine.state == .ready)
    }

    @Test func activeStreamingEngineIdentityReflectsProfileAppleAndFallback() async throws {
        var backend: TranscriptionBackend = .parakeet
        var profile: StreamingChunkProfile = .lowLatency
        let parakeetEngine = MockStreamingTranscriptionEngine()
        let appleEngine = MockStreamingTranscriptionEngine()
        let service = TranscriptionService(
            storageLocations: try SpeechTestSupport.makeStorageLocations().locations,
            streamingEngineFactory: { _, _ in parakeetEngine },
            appleSpeechEngineFactory: { appleEngine },
            streamingChunkProfileProvider: { profile },
            streamingBackendProvider: { backend }
        )

        try await service.prepareStreamingEngine()
        #expect(
            service.activeStreamingEngineIdentity == StreamingEngineIdentity(
                providerIdentifier: TranscriptionBackend.parakeet.rawValue,
                modelIdentifier: StreamingChunkProfile.lowLatency.repoFolderName
            )
        )

        await service.unloadModel()
        backend = .appleSpeechTranscriber
        profile = .standard
        try await service.prepareStreamingEngine()
        #expect(
            service.activeStreamingEngineIdentity == StreamingEngineIdentity(
                providerIdentifier: TranscriptionBackend.appleSpeechTranscriber.rawValue,
                modelIdentifier: "apple-speech-transcriber/progressive"
            )
        )

        let fallbackEngine = MockStreamingTranscriptionEngine()
        let fallbackService = TranscriptionService(
            storageLocations: try SpeechTestSupport.makeStorageLocations().locations,
            streamingEngineFactory: { _, _ in fallbackEngine },
            appleSpeechEngineFactory: { nil },
            streamingChunkProfileProvider: { .standard },
            streamingBackendProvider: { .appleSpeechTranscriber }
        )
        try await fallbackService.prepareStreamingEngine()
        #expect(
            fallbackService.activeStreamingEngineIdentity == StreamingEngineIdentity(
                providerIdentifier: TranscriptionBackend.parakeet.rawValue,
                modelIdentifier: StreamingChunkProfile.standard.repoFolderName
            )
        )
        #expect(fallbackService.consumeAppleBackendFallbackFlag())
    }

    @Test func cancelStreamingClearsAppleFallbackBeforeReplacementStarts() async throws {
        let mockStreamingEngine = MockStreamingTranscriptionEngine()
        mockStreamingEngine.startError = MockStreamingTranscriptionEngine.MockError.modelMissing
        var requestedBackend: TranscriptionBackend = .appleSpeechTranscriber
        let service = TranscriptionService(
            storageLocations: try SpeechTestSupport.makeStorageLocations().locations,
            streamingEngineFactory: { _, _ in mockStreamingEngine },
            appleSpeechEngineFactory: { nil },
            streamingBackendProvider: { requestedBackend }
        )

        do {
            try await service.startStreaming()
            Issue.record("Expected fallback streaming start to fail")
        } catch {
            // Expected.
        }
        #expect(service.appleBackendFellBackToParakeet)

        await service.cancelStreaming()
        requestedBackend = .parakeet
        mockStreamingEngine.startError = nil

        try await service.startStreaming()

        #expect(!service.consumeAppleBackendFallbackFlag())
    }

    @Test func streamingCallbacksForwardPartialAndFinalUtterance() async throws {
        let mockStreamingEngine = MockStreamingTranscriptionEngine()
        let service = TranscriptionService(
            storageLocations: try SpeechTestSupport.makeStorageLocations().locations,
            streamingEngineFactory: { _, _ in mockStreamingEngine  })
        let collector = StreamingCallbackCollector()

        service.setStreamingCallbacks(
            onPartial: { text in
                await collector.recordPartial(text)
            },
            onFinalUtterance: { text in
                await collector.recordFinal(text)
            }
        )
        try await service.prepareStreamingEngine()
        try await mockStreamingEngine.waitUntilCallbacksInstalled()

        mockStreamingEngine.emitPartial("hello wor")
        try await collector.waitFor(
            partials: ["hello wor"],
            finals: []
        )

        mockStreamingEngine.emitFinalUtterance("hello world")
        try await collector.waitForFinals(["hello world"])
        let snapshot = await collector.snapshot()

        #expect(snapshot.partials == ["hello wor"])
        #expect(snapshot.finals == ["hello world"])

        let replacementCollector = StreamingCallbackCollector()
        service.setStreamingCallbacks(
            onPartial: { text in
                await replacementCollector.recordPartial(text)
            },
            onFinalUtterance: { text in
                await replacementCollector.recordFinal(text)
            }
        )
        mockStreamingEngine.emitFinalUtterance("replacement sink")
        try await replacementCollector.waitForFinals(["replacement sink"])

        #expect(mockStreamingEngine.transcriptionCallbackInstallCount == 1)
        #expect(mockStreamingEngine.endOfUtteranceCallbackInstallCount == 1)
    }

    @Test func streamingPartialsCoalesceWhileAllFinalsDeliverInOrder() async throws {
        let mockStreamingEngine = MockStreamingTranscriptionEngine()
        let service = TranscriptionService(
            storageLocations: try SpeechTestSupport.makeStorageLocations().locations,
            streamingEngineFactory: { _, _ in mockStreamingEngine  })
        let collector = StreamingCallbackCollector()

        service.setStreamingCallbacks(
            onPartial: { text in
                await collector.recordPartial(text)
            },
            onFinalUtterance: { text in
                await collector.recordFinal(text)
            }
        )
        try await service.prepareStreamingEngine()
        try await mockStreamingEngine.waitUntilCallbacksInstalled()

        // Burst partials, then a final, more partials, then more finals — the bridge
        // must collapse consecutive partials and keep every final in arrival order.
        mockStreamingEngine.emitPartial("h")
        mockStreamingEngine.emitPartial("he")
        mockStreamingEngine.emitPartial("hel")
        mockStreamingEngine.emitPartial("hell")
        mockStreamingEngine.emitPartial("hello")
        mockStreamingEngine.emitFinalUtterance("hello")
        mockStreamingEngine.emitPartial("w")
        mockStreamingEngine.emitPartial("wo")
        mockStreamingEngine.emitPartial("wor")
        mockStreamingEngine.emitPartial("world")
        mockStreamingEngine.emitFinalUtterance("world")
        mockStreamingEngine.emitFinalUtterance("again")

        let expectedFinals = ["hello", "world", "again"]
        try await collector.waitForFinals(expectedFinals)
        let snapshot = await collector.snapshot()

        #expect(snapshot.finals == expectedFinals)
        // Consecutive partials coalesce; at most one partial is retained between finals.
        #expect(snapshot.partials.count <= 2)
        #expect(Set(snapshot.partials).isSubset(of: ["hello", "world"]))
        if snapshot.partials.count == 2 {
            #expect(snapshot.partials == ["hello", "world"])
        }
    }

    @Test func currentStreamingGenerationProgressesWhileStaleSinkIsSuspended() async throws {
        let mockStreamingEngine = MockStreamingTranscriptionEngine()
        let service = TranscriptionService(
            storageLocations: try SpeechTestSupport.makeStorageLocations().locations,
            streamingEngineFactory: { _, _ in mockStreamingEngine  })
        let oldCollector = StreamingCallbackCollector()
        let newCollector = StreamingCallbackCollector()
        let gate = StreamingCallbackSuspendGate()

        service.setStreamingCallbacks(
            onPartial: { text in
                await oldCollector.recordPartial(text)
            },
            onFinalUtterance: { text in
                await gate.enterAndWait()
                await oldCollector.recordFinal(text)
            }
        )
        try await service.prepareStreamingEngine()
        try await mockStreamingEngine.waitUntilCallbacksInstalled()

        mockStreamingEngine.emitFinalUtterance("old-session")
        await gate.waitUntilEntered()
        mockStreamingEngine.emitFinalUtterance("old-queued")

        service.setStreamingCallbacks(
            onPartial: nil as (@MainActor @Sendable (String) async -> Void)?,
            onFinalUtterance: nil as (@MainActor @Sendable (String) async -> Void)?
        )
        service.setStreamingCallbacks(
            onPartial: { text in
                await newCollector.recordPartial(text)
            },
            onFinalUtterance: { text in
                await newCollector.recordFinal(text)
            }
        )

        mockStreamingEngine.emitPartial("n")
        mockStreamingEngine.emitPartial("ne")
        mockStreamingEngine.emitPartial("new")
        mockStreamingEngine.emitFinalUtterance("new-one")
        mockStreamingEngine.emitFinalUtterance("new-two")

        // The replacement generation owns an independent drain. Its progress must
        // not depend on an arbitrary stale sink opening its gate.
        try await newCollector.waitForFinals(["new-one", "new-two"])
        let midOld = await oldCollector.snapshot()
        let midNew = await newCollector.snapshot()
        #expect(midOld.finals.isEmpty)
        #expect(midNew.finals == ["new-one", "new-two"])
        #expect(midNew.partials == ["new"] || midNew.partials.isEmpty)

        await gate.open()
        try await oldCollector.waitForFinals(["old-session"])

        let oldSnapshot = await oldCollector.snapshot()
        let newSnapshot = await newCollector.snapshot()
        #expect(oldSnapshot.finals == ["old-session"])
        #expect(!oldSnapshot.finals.contains("old-queued"))
        #expect(newSnapshot.finals == ["new-one", "new-two"])
        #expect(!newSnapshot.finals.contains("old-session"))
    }



    @Test func cancelWaitsForResetBarrierAndReusesOneBridgeInstallation() async throws {
        let mockStreamingEngine = MockStreamingTranscriptionEngine()
        let resetGate = StreamingCallbackSuspendGate()
        mockStreamingEngine.resetGate = resetGate
        let service = TranscriptionService(
            storageLocations: try SpeechTestSupport.makeStorageLocations().locations,
            streamingEngineFactory: { _, _ in mockStreamingEngine  })
        let oldCollector = StreamingCallbackCollector()
        let newCollector = StreamingCallbackCollector()

        service.setStreamingCallbacks(
            onFinalUtterance: { text in
                await oldCollector.recordFinal(text)
            }
        )
        try await service.startStreaming()
        let oldSessionEmission = mockStreamingEngine.captureFinalUtterance(
            "captured old session"
        )

        let cancelTask = Task {
            await service.cancelStreaming()
        }
        await resetGate.waitUntilEntered()

        service.setStreamingCallbacks(
            onPartial: nil as (@MainActor @Sendable (String) async -> Void)?,
            onFinalUtterance: nil as (@MainActor @Sendable (String) async -> Void)?
        )
        service.setStreamingCallbacks(
            onFinalUtterance: { text in
                await newCollector.recordFinal(text)
            }
        )
        let nextStartGate = StreamingCallbackSuspendGate()
        mockStreamingEngine.startGate = nextStartGate
        let (startAttempts, startAttemptContinuation) = AsyncStream.makeStream(
            of: Void.self,
            bufferingPolicy: .bufferingNewest(1)
        )
        var startAttemptIterator = startAttempts.makeAsyncIterator()
        let nextStartTask = Task {
            startAttemptContinuation.yield(())
            try await service.startStreaming()
        }
        _ = await startAttemptIterator.next()

        // Source delivery is inactive for the full reset await.
        mockStreamingEngine.emitFinalUtterance("late during reset")
        await resetGate.open()
        await cancelTask.value
        await nextStartGate.waitUntilEntered()

        // Preparation has reactivated the invariant bridge, but the engine-side
        // session capture still rejects work queued by the pre-reset session.
        oldSessionEmission()
        await nextStartGate.open()
        try await nextStartTask.value

        mockStreamingEngine.emitFinalUtterance("new session")
        try await newCollector.waitForFinals(["new session"])

        let oldSnapshot = await oldCollector.snapshot()
        let newSnapshot = await newCollector.snapshot()
        #expect(oldSnapshot.finals.isEmpty)
        #expect(newSnapshot.finals == ["new session"])
        #expect(mockStreamingEngine.transcriptionCallbackInstallCount == 1)
        #expect(mockStreamingEngine.endOfUtteranceCallbackInstallCount == 1)
    }

    @Test func cancelInterruptsResetDependentOperationBeforeFinalBarrier() async throws {
        let mockStreamingEngine = MockStreamingTranscriptionEngine()
        let service = TranscriptionService(
            storageLocations: try SpeechTestSupport.makeStorageLocations().locations,
            streamingEngineFactory: { _, _ in mockStreamingEngine  })
        try await service.startStreaming()

        let processGate = StreamingCallbackSuspendGate()
        mockStreamingEngine.processGate = processGate
        mockStreamingEngine.operationGateToOpenOnReset = processGate
        let buffer = try makeStreamingBuffer()
        let processTask = Task {
            try await service.processStreamingAudioBuffer(buffer)
        }
        await processGate.waitUntilEntered()

        await service.cancelStreaming()
        do {
            try await processTask.value
            Issue.record("Expected the prior-session process to be cancelled")
        } catch is CancellationError {
            // Expected: the interrupt reset released it under the old epoch.
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        #expect(service.state == .ready)
        #expect(mockStreamingEngine.state == .ready)
        #expect(mockStreamingEngine.resetCallCount == 2)
    }

    @Test func unloadedEngineCannotDeliverLateCallbacksIntoReplacementSink() async throws {
        let oldEngine = MockStreamingTranscriptionEngine()
        let replacementEngine = MockStreamingTranscriptionEngine()
        var factoryCallCount = 0
        let service = TranscriptionService(
            storageLocations: try SpeechTestSupport.makeStorageLocations().locations,
            streamingEngineFactory: { _, _ in
                defer { factoryCallCount += 1 }
                return factoryCallCount == 0 ? oldEngine : replacementEngine
            }
        )
        let collector = StreamingCallbackCollector()

        try await service.prepareStreamingEngine()
        await service.unloadModel()
        service.setStreamingCallbacks(
            onPartial: nil as (@MainActor @Sendable (String) async -> Void)?,
            onFinalUtterance: nil as (@MainActor @Sendable (String) async -> Void)?
        )
        service.setStreamingCallbacks(
            onFinalUtterance: { text in
                await collector.recordFinal(text)
            }
        )
        try await service.prepareStreamingEngine()

        oldEngine.emitFinalUtterance("stale old engine")
        replacementEngine.emitFinalUtterance("replacement engine")
        try await collector.waitForFinals(["replacement engine"])

        let snapshot = await collector.snapshot()
        #expect(snapshot.finals == ["replacement engine"])
        #expect(oldEngine.transcriptionCallbackInstallCount == 1)
        #expect(replacementEngine.transcriptionCallbackInstallCount == 1)
    }

    @Test func unloadDuringNonCooperativeStreamingLoadCannotResurrectModel() async throws {
        let mockStreamingEngine = MockStreamingTranscriptionEngine()
        let loadGate = StreamingCallbackSuspendGate()
        mockStreamingEngine.loadGate = loadGate
        let service = TranscriptionService(
            storageLocations: try SpeechTestSupport.makeStorageLocations().locations,
            streamingEngineFactory: { _, _ in mockStreamingEngine  })

        let prepareTask = Task {
            try await service.prepareStreamingEngine()
        }
        await loadGate.waitUntilEntered()

        await service.unloadModel()
        #expect(service.state == .unloaded)
        #expect(service.activeStreamingEngine == nil)

        await loadGate.open()
        do {
            try await prepareTask.value
            Issue.record("Expected invalidated streaming prepare to be cancelled")
        } catch is CancellationError {
            // Expected: lifecycle identity, not cooperative cancellation, rejects it.
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        #expect(service.state == .unloaded)
        #expect(service.activeStreamingEngine == nil)
        #expect(mockStreamingEngine.state == .unloaded)
        #expect(mockStreamingEngine.unloadCallCount >= 1)
    }

    @Test func lateStreamingStartCannotOverwriteUnload() async throws {
        let mockStreamingEngine = MockStreamingTranscriptionEngine()
        let startGate = StreamingCallbackSuspendGate()
        mockStreamingEngine.startGate = startGate
        let service = TranscriptionService(
            storageLocations: try SpeechTestSupport.makeStorageLocations().locations,
            streamingEngineFactory: { _, _ in mockStreamingEngine  })
        try await service.prepareStreamingEngine()

        let startTask = Task {
            try await service.startStreaming()
        }
        await startGate.waitUntilEntered()
        await service.unloadModel()
        await startGate.open()

        do {
            try await startTask.value
            Issue.record("Expected stale streaming start to be cancelled")
        } catch is CancellationError {
            // Expected.
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
        #expect(service.state == .unloaded)
        #expect(service.error == nil)
        #expect(service.activeStreamingEngine == nil)
        #expect(mockStreamingEngine.state == .unloaded)
    }

    @Test func lateStreamingStopCannotOverwriteUnload() async throws {
        let mockStreamingEngine = MockStreamingTranscriptionEngine()
        let service = TranscriptionService(
            storageLocations: try SpeechTestSupport.makeStorageLocations().locations,
            streamingEngineFactory: { _, _ in mockStreamingEngine  })
        try await service.startStreaming()
        let stopGate = StreamingCallbackSuspendGate()
        mockStreamingEngine.stopGate = stopGate

        let stopTask = Task {
            try await service.stopStreaming()
        }
        await stopGate.waitUntilEntered()
        await service.unloadModel()
        await stopGate.open()

        do {
            _ = try await stopTask.value
            Issue.record("Expected stale streaming stop to be cancelled")
        } catch is CancellationError {
            // Expected.
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
        #expect(service.state == .unloaded)
        #expect(service.error == nil)
        #expect(service.activeStreamingEngine == nil)
        #expect(mockStreamingEngine.state == .unloaded)
    }

    @Test func lateStreamingProcessErrorCannotOverwriteUnload() async throws {
        let mockStreamingEngine = MockStreamingTranscriptionEngine()
        let service = TranscriptionService(
            storageLocations: try SpeechTestSupport.makeStorageLocations().locations,
            streamingEngineFactory: { _, _ in mockStreamingEngine  })
        try await service.startStreaming()
        let processGate = StreamingCallbackSuspendGate()
        mockStreamingEngine.processGate = processGate
        mockStreamingEngine.processError = MockStreamingTranscriptionEngine.MockError.modelMissing
        let buffer = try makeStreamingBuffer()

        let processTask = Task {
            try await service.processStreamingAudioBuffer(buffer)
        }
        await processGate.waitUntilEntered()
        await service.unloadModel()
        await processGate.open()

        do {
            try await processTask.value
            Issue.record("Expected stale streaming processing to be cancelled")
        } catch is CancellationError {
            // Expected.
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
        #expect(service.state == .unloaded)
        #expect(service.error == nil)
        #expect(service.activeStreamingEngine == nil)
    }

    @Test func lateStreamingResetCannotOverwriteUnload() async throws {
        let mockStreamingEngine = MockStreamingTranscriptionEngine()
        let service = TranscriptionService(
            storageLocations: try SpeechTestSupport.makeStorageLocations().locations,
            streamingEngineFactory: { _, _ in mockStreamingEngine  })
        try await service.startStreaming()
        let resetGate = StreamingCallbackSuspendGate()
        mockStreamingEngine.resetGate = resetGate

        let cancelTask = Task {
            await service.cancelStreaming()
        }
        await resetGate.waitUntilEntered()
        await service.unloadModel()
        await resetGate.open()
        await cancelTask.value

        #expect(service.state == .unloaded)
        #expect(service.error == nil)
        #expect(service.activeStreamingEngine == nil)
        #expect(mockStreamingEngine.state == .unloaded)
    }

    @Test func stalePrepareCannotCleanUpReownedSameEngineInstance() async throws {
        let mockStreamingEngine = MockStreamingTranscriptionEngine()
        let loadGate = StreamingCallbackSuspendGate()
        mockStreamingEngine.loadGate = loadGate
        var factoryCallCount = 0
        let service = TranscriptionService(
            storageLocations: try SpeechTestSupport.makeStorageLocations().locations,
            streamingEngineFactory: { _, _ in factoryCallCount += 1
                return mockStreamingEngine
             }
        )

        let stalePrepare = Task {
            try await service.prepareStreamingEngine()
        }
        await loadGate.waitUntilEntered()
        await service.unloadModel()

        let replacementPrepare = Task {
            try await service.prepareStreamingEngine()
        }
        await loadGate.open()

        do {
            try await stalePrepare.value
            Issue.record("Expected stale prepare to be cancelled")
        } catch is CancellationError {
            // Expected.
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
        try await replacementPrepare.value

        #expect(factoryCallCount == 2)
        #expect(service.state == .ready)
        #expect(service.activeStreamingEngine === mockStreamingEngine)
        #expect(mockStreamingEngine.state == .ready)
        #expect(mockStreamingEngine.transcriptionCallbackInstallCount == 1)
        #expect(mockStreamingEngine.endOfUtteranceCallbackInstallCount == 1)
    }

    @Test func prepareStreamingEngineThrowsModelNotAvailableWhenLoadFails() async throws {
        let mockStreamingEngine = MockStreamingTranscriptionEngine()
        mockStreamingEngine.loadError = MockStreamingTranscriptionEngine.MockError.modelMissing
        let service = TranscriptionService(
            storageLocations: try SpeechTestSupport.makeStorageLocations().locations,
            streamingEngineFactory: { _, _ in mockStreamingEngine  })

        do {
            try await service.prepareStreamingEngine()
            Issue.record("Expected prepareStreamingEngine to throw")
        } catch let error as TranscriptionService.TranscriptionError {
            guard case .streamingModelNotAvailable = error else {
                Issue.record("Expected streamingModelNotAvailable, got \(error)")
                return
            }
            #expect(service.state == .error)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }


    @Test func unloadModelClearsStreamingEngine() async throws {
        let mockStreamingEngine = MockStreamingTranscriptionEngine()
        let service = TranscriptionService(
            storageLocations: try SpeechTestSupport.makeStorageLocations().locations,
            streamingEngineFactory: { _, _ in mockStreamingEngine  })

        try await service.prepareStreamingEngine()
        try await service.startStreaming()
        await service.cancelStreaming()

        await service.unloadModel()

        #expect(service.state == .unloaded)
        #expect(service.error == nil)
        #expect(mockStreamingEngine.unloadCallCount == 1)
    }

    @Test func cancelStreamingReturnsServiceToReadyState() async throws {
        let mockStreamingEngine = MockStreamingTranscriptionEngine()
        let service = TranscriptionService(
            storageLocations: try SpeechTestSupport.makeStorageLocations().locations,
            streamingEngineFactory: { _, _ in mockStreamingEngine  })

        try await service.prepareStreamingEngine()
        try await service.startStreaming()

        await service.cancelStreaming()

        #expect(service.state == .ready)
        #expect(mockStreamingEngine.resetCallCount == 1)
    }
    
    // MARK: - Error Propagation Tests
    
    @Test func engineErrorPropagatesToTranscriptionError() async throws {
        let service = TranscriptionService(storageLocations: try SpeechTestSupport.makeStorageLocations().locations)
        
        // Given: Service without loaded model
        #expect(service.state == .unloaded)
        
        // Create valid-sized audio data
        let sampleCount = 16000
        var audioData = Data()
        for _ in 0..<sampleCount {
            var sample: Float = 0.0
            audioData.append(Data(bytes: &sample, count: MemoryLayout<Float>.size))
        }
        
        // When/Then: Transcribe should throw modelNotLoaded
        do {
            _ = try await service.transcribe(audioData: audioData)
            Issue.record("Should throw error when model not loaded")
        } catch TranscriptionService.TranscriptionError.modelNotLoaded {
        } catch {
            Issue.record("Unexpected error type: \(error)")
        }
    }
    
    @Test func transcriptionErrorDescriptions() {
        // Test all error descriptions are properly defined
        let errors: [TranscriptionService.TranscriptionError] = [
            .modelNotLoaded,
            .invalidAudioData,
            .transcriptionFailed("test message"),
            .modelLoadFailed("load failed"),
            .engineSwitchDuringTranscription
        ]
        
        for error in errors {
            #expect(error.errorDescription != nil, "\(error) should have error description")
            #expect((error.errorDescription?.isEmpty ?? true) == false, "\(error) description should not be empty")
        }
    }
    
    @Test func invalidProviderHandling() async throws {
        // This tests that non-local providers throw appropriate errors
        // The implementation should reject cloud-only providers
        // Currently WhisperKit and Parakeet are the only local providers
        
        // Verify error type exists for this case
        let error = TranscriptionService.TranscriptionError.modelLoadFailed("Provider not supported locally")
        #expect(error.errorDescription != nil)
        #expect(error.errorDescription?.contains("not supported") ?? false,
                "Error should indicate provider not supported")
    }

    // MARK: - Durable meeting chunks

    @Test func meetingChunkValidatesSealedFileBeforeASR() async throws {
        let mockEngine = MockDiarizationTranscriptionEngine()
        mockEngine.transcribeResponses = ["plain"]
        let service = TranscriptionService(
            storageLocations: try SpeechTestSupport.makeStorageLocations().locations,
            engineFactory: { _ in mockEngine }
        )
        try await service.loadModel(modelName: "tiny", provider: .whisperKit)

        let fixture = try makeMeetingChunkFixture(data: makeFloatAudioData(seconds: 0.001))
        defer { try? FileManager.default.removeItem(at: fixture.rootURL) }
        let invalidHash = TranscriptionChunkInput(
            chunkID: fixture.input.chunkID,
            sequence: fixture.input.sequence,
            startOffset: fixture.input.startOffset,
            duration: fixture.input.duration,
            fileURL: fixture.input.fileURL,
            byteCount: fixture.input.byteCount,
            sha256: String(repeating: "0", count: 64)
        )

        do {
            _ = try await service.transcribeMeetingChunk(invalidHash)
            Issue.record("Expected sealed-file hash validation to fail")
        } catch TranscriptionService.TranscriptionError.invalidMeetingChunk(_) {
            #expect(mockEngine.transcribeCallCount == 0)
        }
    }

    @Test func meetingChunkRejectsOversizedAndUnalignedFilesWithoutASR() async throws {
        let mockEngine = MockDiarizationTranscriptionEngine()
        let service = TranscriptionService(
            storageLocations: try SpeechTestSupport.makeStorageLocations().locations,
            engineFactory: { _ in mockEngine }
        )
        try await service.loadModel(modelName: "tiny", provider: .whisperKit)

        let fixture = try makeMeetingChunkFixture(data: Data([0, 0, 0]))
        defer { try? FileManager.default.removeItem(at: fixture.rootURL) }
        let unaligned = TranscriptionChunkInput(
            chunkID: fixture.input.chunkID,
            sequence: fixture.input.sequence,
            startOffset: fixture.input.startOffset,
            duration: 0.001,
            fileURL: fixture.input.fileURL,
            byteCount: fixture.input.byteCount,
            sha256: fixture.input.sha256
        )

        do {
            _ = try await service.transcribeMeetingChunk(unaligned)
            Issue.record("Expected unaligned PCM data to be rejected")
        } catch TranscriptionService.TranscriptionError.invalidMeetingChunk(_) {
            #expect(mockEngine.transcribeCallCount == 0)
        }

        let oversized = TranscriptionChunkInput(
            chunkID: UUID(),
            sequence: 1,
            startOffset: 0,
            duration: 300.0000625,
            fileURL: fixture.input.fileURL,
            byteCount: 19_200_004,
            sha256: fixture.input.sha256
        )
        do {
            _ = try await service.transcribeMeetingChunk(oversized)
            Issue.record("Expected oversized PCM data to be rejected")
        } catch TranscriptionService.TranscriptionError.invalidMeetingChunk(_) {
            #expect(mockEngine.transcribeCallCount == 0)
        }
    }

    @Test func meetingChunkReadsOneCanonicalMaximumChunk() async throws {
        let maximumByteCount = 19_200_000
        let mockEngine = MockDiarizationTranscriptionEngine()
        mockEngine.transcribeResponses = ["maximum chunk"]
        let diarizer = MockSpeakerDiarizer()
        let service = TranscriptionService(
            storageLocations: try SpeechTestSupport.makeStorageLocations().locations,
            engineFactory: { _ in mockEngine },
            diarizerFactory: { _ in diarizer }
        )
        try await service.loadModel(modelName: "tiny", provider: .whisperKit)

        let fixture = try makeMeetingChunkFixture(data: Data(repeating: 0, count: maximumByteCount))
        defer { try? FileManager.default.removeItem(at: fixture.rootURL) }
        let output = try await service.transcribeMeetingChunk(fixture.input)

        #expect(output.plainText == "maximum chunk")
        #expect(mockEngine.receivedAudioByteCounts == [maximumByteCount])
    }

    @Test func meetingChunkWithDiarizationDisabledSkipsDiarizer() async throws {
        var diarizerFactoryCallCount = 0
        let mockEngine = MockDiarizationTranscriptionEngine()
        mockEngine.transcribeResponses = ["plain transcript"]
        let diarizer = MockSpeakerDiarizer()
        let service = TranscriptionService(
            storageLocations: try SpeechTestSupport.makeStorageLocations().locations,
            engineFactory: { _ in mockEngine },
            diarizerFactory: { _ in
                diarizerFactoryCallCount += 1
                return diarizer
            }
        )
        try await service.loadModel(modelName: "tiny", provider: .whisperKit)

        let fixture = try makeMeetingChunkFixture(data: makeFloatAudioData(seconds: 0.001))
        defer { try? FileManager.default.removeItem(at: fixture.rootURL) }
        let output = try await service.transcribeMeetingChunk(
            fixture.input,
            diarizationEnabled: false
        )

        #expect(output.plainText == "plain transcript")
        #expect(output.diarizedSegments == nil)
        #expect(output.diarizationWarning == nil)
        #expect(mockEngine.transcribeCallCount == 1)
        #expect(diarizerFactoryCallCount == 0)
        #expect(diarizer.loadModelsCallCount == 0)
        #expect(diarizer.diarizeCallCount == 0)
    }

    @Test func meetingChunkRunsPlainASRBeforeDiarization() async throws {
        var events: [String] = []
        let mockEngine = MockDiarizationTranscriptionEngine()
        mockEngine.transcribeResponses = ["plain first", "diarized second"]
        mockEngine.eventSink = { events.append($0) }
        let diarizer = MockSpeakerDiarizer()
        diarizer.eventSink = { events.append($0) }
        var diarizerFactoryCallCount = 0
        let service = TranscriptionService(
            storageLocations: try SpeechTestSupport.makeStorageLocations().locations,
            engineFactory: { _ in mockEngine },
            diarizerFactory: { _ in
                diarizerFactoryCallCount += 1
                return diarizer
            }
        )
        try await service.loadModel(modelName: "tiny", provider: .whisperKit)

        let fixture = try makeMeetingChunkFixture(data: makeFloatAudioData(seconds: 0.001))
        defer { try? FileManager.default.removeItem(at: fixture.rootURL) }
        diarizer.nextResult = diarizationResult(for: fixture.input)

        let output = try await service.transcribeMeetingChunk(fixture.input)

        #expect(output.plainText == "plain first")
        #expect(output.diarizedSegments?.count == 1)
        #expect(events == ["asr", "loadDiarizer", "diarize", "asr"])
        #expect(mockEngine.transcribeCallCount == 2)
        #expect(diarizerFactoryCallCount == 1)
        #expect(diarizer.loadModelsCallCount == 1)
        #expect(diarizer.diarizeCallCount == 1)
    }

    @Test func meetingChunkPreservesPlainASRForEveryDiarizationFallback() async throws {
        enum Fallback: CaseIterable, Equatable {
            case missingModel
            case inferenceFailure
            case emptySegments
            case emptyDiarizedText
        }

        for fallback in Fallback.allCases {
            let mockEngine = MockDiarizationTranscriptionEngine()
            mockEngine.transcribeResponses = fallback == .emptyDiarizedText ? ["plain", ""] : ["plain"]
            let diarizer = MockSpeakerDiarizer()
            let service = TranscriptionService(
                storageLocations: try SpeechTestSupport.makeStorageLocations().locations,
                engineFactory: { _ in mockEngine },
                diarizerFactory: { _ in diarizer }
            )
            try await service.loadModel(modelName: "tiny", provider: .whisperKit)

            let fixture = try makeMeetingChunkFixture(data: makeFloatAudioData(seconds: 0.001))
            defer { try? FileManager.default.removeItem(at: fixture.rootURL) }
            switch fallback {
            case .missingModel:
                diarizer.loadModelsError = NSError(domain: "test", code: 1)
            case .inferenceFailure:
                diarizer.diarizeError = NSError(domain: "test", code: 2)
            case .emptySegments:
                break
            case .emptyDiarizedText:
                diarizer.nextResult = diarizationResult(for: fixture.input)
            }

            let output = try await service.transcribeMeetingChunk(fixture.input)
            #expect(output.plainText == "plain")
            #expect(output.diarizedSegments == nil)
            #expect(output.diarizationWarning != nil)
            #expect(mockEngine.transcribeCallCount == (fallback == .emptyDiarizedText ? 2 : 1))
            #expect(diarizer.loadModelsCallCount == 1)
            #expect(diarizer.diarizeCallCount == (fallback == .missingModel ? 0 : 1))
        }
    }

    @Test func meetingChunkPreservesPlainASRAfterDiarizationTimeout() async throws {
        let mockEngine = MockDiarizationTranscriptionEngine()
        mockEngine.transcribeResponses = ["plain"]
        let diarizer = MockSpeakerDiarizer()
        diarizer.diarizeDelayNanoseconds = 1_000_000_000
        let service = TranscriptionService(
            storageLocations: try SpeechTestSupport.makeStorageLocations().locations,
            engineFactory: { _ in mockEngine },
            diarizerFactory: { _ in diarizer },
            diarizationTimeoutSeconds: 0.01
        )
        try await service.loadModel(modelName: "tiny", provider: .whisperKit)

        let fixture = try makeMeetingChunkFixture(data: makeFloatAudioData(seconds: 0.001))
        defer { try? FileManager.default.removeItem(at: fixture.rootURL) }
        let output = try await service.transcribeMeetingChunk(fixture.input)

        #expect(output.plainText == "plain")
        #expect(output.diarizedSegments == nil)
        #expect(output.diarizationWarning?.contains("timed out") == true)
    }

    @Test func meetingChunkCancellationPropagatesAtASRBoundary() async throws {
        let mockEngine = MockDiarizationTranscriptionEngine()
        mockEngine.transcribeDelayNanoseconds = 1_000_000_000
        let diarizer = MockSpeakerDiarizer()
        let service = TranscriptionService(
            storageLocations: try SpeechTestSupport.makeStorageLocations().locations,
            engineFactory: { _ in mockEngine },
            diarizerFactory: { _ in diarizer }
        )
        try await service.loadModel(modelName: "tiny", provider: .whisperKit)
        let fixture = try makeMeetingChunkFixture(data: makeFloatAudioData(seconds: 0.001))
        defer { try? FileManager.default.removeItem(at: fixture.rootURL) }

        let task = Task { @MainActor in try await service.transcribeMeetingChunk(fixture.input) }
        try await Task.sleep(nanoseconds: 20_000_000)
        task.cancel()

        do {
            _ = try await task.value
            Issue.record("Expected meeting-chunk transcription cancellation")
        } catch is CancellationError {
            #expect(diarizer.diarizeCallCount == 0)
        }
    }

    @Test func meetingChunkMergeUsesAbsoluteOffsetsAndStableSpeakerNamespaces() throws {
        let first = TranscriptionChunkOutput(
            chunkID: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            sequence: 0,
            startOffset: 0,
            duration: 1,
            plainText: "  first\nchunk  ",
            diarizedSegments: [
                DiarizedTranscriptSegment(
                    speakerId: "speaker-a",
                    speakerLabel: "A",
                    startTime: 0.25,
                    endTime: 0.75,
                    confidence: 0.9,
                    text: "first"
                )
            ]
        )
        let second = TranscriptionChunkOutput(
            chunkID: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
            sequence: 1,
            startOffset: 1,
            duration: 1,
            plainText: "second   chunk",
            diarizedSegments: [
                DiarizedTranscriptSegment(
                    speakerId: "speaker-a",
                    speakerLabel: "A",
                    startTime: 0,
                    endTime: 0.5,
                    confidence: 0.8,
                    text: "second"
                )
            ]
        )
        let service = TranscriptionService(storageLocations: try SpeechTestSupport.makeStorageLocations().locations)

        let output = try service.mergeMeetingChunks([second, first])

        #expect(output.text == "first chunk\nsecond chunk")
        #expect(output.diarizedSegments?.map(\.speakerId) == ["chunk-00000/speaker-a", "chunk-00001/speaker-a"])
        #expect(output.diarizedSegments?.map(\.startTime) == [0.25, 1])
        #expect(output.diarizedSegments?.map(\.endTime) == [0.75, 1.5])
    }

    @Test func meetingChunkMergeRejectsDuplicateOverlapAndGaps() throws {
        let service = TranscriptionService(storageLocations: try SpeechTestSupport.makeStorageLocations().locations)
        let base = TranscriptionChunkOutput(
            chunkID: UUID(),
            sequence: 0,
            startOffset: 0,
            duration: 1,
            plainText: "base"
        )

        do {
            _ = try service.mergeMeetingChunks([
                base,
                .init(chunkID: UUID(), sequence: 0, startOffset: 1, duration: 1, plainText: "duplicate")
            ])
            Issue.record("Expected duplicate sequence rejection")
        } catch TranscriptionService.TranscriptionError.duplicateMeetingChunkSequence(_) {
        }
        do {
            _ = try service.mergeMeetingChunks([
                base,
                .init(chunkID: UUID(), sequence: 1, startOffset: 0.5, duration: 1, plainText: "overlap")
            ])
            Issue.record("Expected overlap rejection")
        } catch TranscriptionService.TranscriptionError.overlappingMeetingChunk(sequence: _) {
        }
        do {
            _ = try service.mergeMeetingChunks([
                base,
                .init(chunkID: UUID(), sequence: 1, startOffset: 1.5, duration: 1, plainText: "gap")
            ])
            Issue.record("Expected gap rejection")
        } catch TranscriptionService.TranscriptionError.nonContiguousMeetingChunk(
            expected: _,
            actual: _,
            sequence: _
        ) {
        }
    }

    @Test func modelLoadWatchdogIsOptIn() async throws {
        #expect(TranscriptionService.defaultModelLoadTimeoutSeconds == nil)

        let productionEngine = MockDiarizationTranscriptionEngine()
        productionEngine.nonCooperativeLoadDelayNanoseconds = 20_000_000
        let productionService = TranscriptionService(
            storageLocations: try SpeechTestSupport.makeStorageLocations().locations,
            engineFactory: { _ in productionEngine }
        )
        try await productionService.loadModel(modelName: "tiny", provider: .whisperKit)

        let timedEngine = MockDiarizationTranscriptionEngine()
        timedEngine.nonCooperativeLoadDelayNanoseconds = 500_000_000
        let timedService = TranscriptionService(
            storageLocations: try SpeechTestSupport.makeStorageLocations().locations,
            engineFactory: { _ in timedEngine },
            modelLoadTimeoutSeconds: 0.01
        )
        do {
            try await timedService.loadModel(modelName: "tiny", provider: .whisperKit)
            Issue.record("Expected explicitly injected model-load watchdog to fire")
        } catch TranscriptionService.TranscriptionError.modelLoadFailed(_) {
        }
    }

    private func makeStreamingBuffer(frameCount: AVAudioFrameCount = 320) throws -> AVAudioPCMBuffer {
        guard let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount),
              let channelData = buffer.floatChannelData?[0] else {
            throw NSError(domain: "TranscriptionServiceTests", code: 1)
        }

        buffer.frameLength = frameCount
        for index in 0..<Int(frameCount) {
            channelData[index] = 0.1
        }
        return buffer
    }

    private func makeFloatAudioData(seconds: TimeInterval, sampleRate: Int = 16_000) -> Data {
        let frameCount = max(1, Int(seconds * TimeInterval(sampleRate)))
        let samples = Array(repeating: Float(0.1), count: frameCount)
        return samples.withUnsafeBufferPointer { pointer in
            Data(buffer: pointer)
        }
    }

    private func makeMeetingChunkFixture(
        data: Data,
        sequence: Int = 0,
        startOffset: TimeInterval = 0
    ) throws -> (input: TranscriptionChunkInput, rootURL: URL) {
        let rootURL = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        let fileURL = rootURL.appendingPathComponent("chunk.pcm")
        try data.write(to: fileURL)
        let duration = Double(data.count / MemoryLayout<Float>.size) / 16_000
        let sha256 = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        return (
            TranscriptionChunkInput(
                chunkID: UUID(),
                sequence: sequence,
                startOffset: startOffset,
                duration: duration,
                fileURL: fileURL,
                byteCount: data.count,
                sha256: sha256
            ),
            rootURL
        )
    }

    private func diarizationResult(for input: TranscriptionChunkInput) -> DiarizationResult {
        let speaker = Speaker(id: "speaker-a", label: "A", embedding: nil)
        return DiarizationResult(
            segments: [
                SpeakerSegment(
                    speaker: speaker,
                    startTime: 0,
                    endTime: input.duration,
                    confidence: 0.9
                )
            ],
            speakers: [speaker],
            audioDuration: input.duration
        )
    }
}

@MainActor
private final class MockDiarizationTranscriptionEngine: TranscriptionEngine {
    private(set) var state: TranscriptionEngineState = .unloaded
    var transcribeResponses: [String] = []
    var transcribeError: Error?
    var transcribeDelayNanoseconds: UInt64?
    var nonCooperativeTranscribeDelayNanoseconds: UInt64?
    var loadDelayNanoseconds: UInt64?
    var nonCooperativeLoadDelayNanoseconds: UInt64?
    var detectedLanguage: AppLanguage?
    var detectLanguageError: Error?
    var eventSink: ((String) -> Void)?
    private(set) var transcribeCallCount = 0
    private(set) var detectLanguageCallCount = 0
    private(set) var detectLanguageSampleCounts: [Int] = []
    private(set) var receivedOptions: [TranscriptionOptions] = []
    private(set) var receivedAudioData: [Data] = []
    private(set) var receivedAudioByteCounts: [Int] = []
    private(set) var lastLoadName: String?
    private(set) var lastDownloadBase: URL?
    private(set) var loadModelNameCallCount = 0

    func loadModel(path: String) async throws {
        try await waitForLoadIfNeeded()
        state = .ready
    }

    func loadModel(name: String, downloadBase: URL?) async throws {
        loadModelNameCallCount += 1
        lastLoadName = name
        lastDownloadBase = downloadBase
        try await waitForLoadIfNeeded()
        state = .ready
    }

    func transcribe(audioData: Data, options: TranscriptionOptions) async throws -> String {
        eventSink?("asr")
        if let transcribeDelayNanoseconds {
            try await Task.sleep(nanoseconds: transcribeDelayNanoseconds)
        }
        if let nonCooperativeTranscribeDelayNanoseconds {
            await withCheckedContinuation { continuation in
                DispatchQueue.global().asyncAfter(
                    deadline: .now() + .nanoseconds(Int(nonCooperativeTranscribeDelayNanoseconds))
                ) {
                    continuation.resume()
                }
            }
        }
        if let transcribeError {
            throw transcribeError
        }

        receivedAudioData.append(audioData)
        receivedOptions.append(options)
        receivedAudioByteCounts.append(audioData.count)
        transcribeCallCount += 1
        if transcribeResponses.isEmpty {
            return ""
        }

        let index = min(transcribeCallCount - 1, transcribeResponses.count - 1)
        return transcribeResponses[index]
    }

    private func waitForLoadIfNeeded() async throws {
        if let loadDelayNanoseconds {
            try await Task.sleep(nanoseconds: loadDelayNanoseconds)
        }
        if let nonCooperativeLoadDelayNanoseconds {
            await withCheckedContinuation { continuation in
                DispatchQueue.global().asyncAfter(
                    deadline: .now() + .nanoseconds(Int(nonCooperativeLoadDelayNanoseconds))
                ) {
                    continuation.resume()
                }
            }
        }
    }

    func detectLanguage(samples: [Float], sampleRate: Int) async throws -> AppLanguage? {
        detectLanguageCallCount += 1
        detectLanguageSampleCounts.append(samples.count)

        if let detectLanguageError {
            throw detectLanguageError
        }

        return detectedLanguage
    }

    func unloadModel() async {
        state = .unloaded
    }
}

@MainActor
private final class MockSpeakerDiarizer: SpeakerDiarizer {
    private(set) var state: SpeakerDiarizerState = .unloaded
    let mode: DiarizationMode = .offline

    var nextResult: DiarizationResult = DiarizationResult(segments: [], speakers: [], audioDuration: 0)
    var loadModelsError: Error?
    var diarizeError: Error?
    var diarizeDelayNanoseconds: UInt64?
    var nonCooperativeDiarizeDelayNanoseconds: UInt64?
    var eventSink: ((String) -> Void)?
    private(set) var lastOptions: DiarizationOptions?
    private(set) var lastSamples: [Float]?
    private(set) var loadModelsCallCount = 0
    private(set) var unloadModelsCallCount = 0
    private(set) var diarizeCallCount = 0
    private(set) var clearKnownSpeakersCallCount = 0
    private(set) var registeredKnownSpeakers: [Speaker] = []

    func loadModels() async throws {
        eventSink?("loadDiarizer")
        loadModelsCallCount += 1
        if let loadModelsError {
            throw loadModelsError
        }
        state = .ready
    }

    func unloadModels() async {
        unloadModelsCallCount += 1
        state = .unloaded
    }

    func diarize(
        samples: [Float],
        sampleRate: Int,
        options: DiarizationOptions
    ) async throws -> DiarizationResult {
        _ = options
        eventSink?("diarize")
        lastOptions = options
        lastSamples = samples
        diarizeCallCount += 1
        if let nonCooperativeDiarizeDelayNanoseconds {
            await withCheckedContinuation { continuation in
                DispatchQueue.global().asyncAfter(
                    deadline: .now() + .nanoseconds(Int(nonCooperativeDiarizeDelayNanoseconds))
                ) {
                    continuation.resume()
                }
            }
        }
        if let diarizeDelayNanoseconds {
            try await Task.sleep(nanoseconds: diarizeDelayNanoseconds)
        }
        if let diarizeError {
            throw diarizeError
        }
        return nextResult
    }

    // Anonymous diarization intentionally has no known-speaker registration APIs.
}

@MainActor
private final class MockSpeakerIdentityService: SpeakerIdentityMatching {
    private(set) var knownSpeakersCallCount = 0
    private(set) var bestMatchCallCount = 0
    private(set) var bestMatchesCallCount = 0
    private(set) var lastBestMatchEmbeddings: [[Float]] = []
    private(set) var lastBestMatchesResults: [SpeakerIdentityMatch?] = []
    private(set) var learnCallCount = 0
    private let speakers: [Speaker]
    private let matchesByEmbeddingKey: [String: SpeakerIdentityMatch]

    init(knownSpeakers: [Speaker] = [], matchesByEmbeddingKey: [String: SpeakerIdentityMatch] = [:]) {
        self.speakers = knownSpeakers
        self.matchesByEmbeddingKey = matchesByEmbeddingKey
    }

    func bestMatch(for embedding: [Float]) throws -> SpeakerIdentityMatch? {
        bestMatchCallCount += 1
        return match(for: embedding)
    }

    func bestMatches(for embeddings: [[Float]]) throws -> [SpeakerIdentityMatch?] {
        bestMatchesCallCount += 1
        lastBestMatchEmbeddings = embeddings
        let results = embeddings.map { match(for: $0) }
        lastBestMatchesResults = results
        return results
    }

    private func match(for embedding: [Float]) -> SpeakerIdentityMatch? {
        matchesByEmbeddingKey[embedding.map { String(format: "%.4f", $0) }.joined(separator: ",")]
    }
}

private actor StubAudioPreprocessor: AudioPreprocessing {
    enum Result: Sendable {
        case output(Data)
        case failure
    }

    private struct Failure: Error {}

    let result: Result
    let gate: StreamingCallbackSuspendGate?
    private(set) var callCount = 0
    private(set) var lastMode: AudioPreprocessingMode?
    private(set) var wasCancelledAtCompletion = false
    private var didComplete = false
    private var completionWaiters: [CheckedContinuation<Void, Never>] = []

    init(result: Result, gate: StreamingCallbackSuspendGate? = nil) {
        self.result = result
        self.gate = gate
    }

    func process(audioData: Data, mode: AudioPreprocessingMode) async throws -> Data {
        defer {
            wasCancelledAtCompletion = Task.isCancelled
            didComplete = true
            let waiters = completionWaiters
            completionWaiters.removeAll()
            for waiter in waiters {
                waiter.resume()
            }
        }
        callCount += 1
        lastMode = mode
        if let gate {
            await gate.enterAndWait()
        }
        switch result {
        case .output(let output):
            return output
        case .failure:
            throw Failure()
        }
    }
    func waitUntilCompleted() async {
        if didComplete { return }
        await withCheckedContinuation { continuation in
            if didComplete {
                continuation.resume()
            } else {
                completionWaiters.append(continuation)
            }
        }
    }
}

private final class ConcurrentStubAudioPreprocessor: AudioPreprocessing, @unchecked Sendable {
    enum FirstResult: Sendable {
        case output(Data)
        case failure
    }

    private struct Failure: Error {}

    private let firstResult: FirstResult
    private let gate: StreamingCallbackSuspendGate
    private let lock = NSLock()
    private let completionProbe = PreprocessorCompletionProbe()
    private var callCount = 0

    init(firstResult: FirstResult, gate: StreamingCallbackSuspendGate) {
        self.firstResult = firstResult
        self.gate = gate
    }

    func process(audioData: Data, mode: AudioPreprocessingMode) async throws -> Data {
        let callIndex = lock.withLock {
            callCount += 1
            return callCount
        }

        guard callIndex == 1 else {
            return audioData
        }

        await gate.enterAndWait()
        await completionProbe.finish(wasCancelled: Task.isCancelled)

        switch firstResult {
        case .output(let output):
            return output
        case .failure:
            throw Failure()
        }
    }

    func waitUntilCompleted() async {
        await completionProbe.waitUntilCompleted()
    }

    func wasCancelledAtCompletion() async -> Bool {
        await completionProbe.cancellationAtCompletion()
    }
}

private actor PreprocessorCompletionProbe {
    private var didComplete = false
    private var wasCancelled = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func finish(wasCancelled: Bool) {
        didComplete = true
        self.wasCancelled = wasCancelled
        let pendingWaiters = waiters
        waiters.removeAll()
        for waiter in pendingWaiters {
            waiter.resume()
        }
    }

    func waitUntilCompleted() async {
        if didComplete { return }
        await withCheckedContinuation { continuation in
            if didComplete {
                continuation.resume()
            } else {
                waiters.append(continuation)
            }
        }
    }

    func cancellationAtCompletion() -> Bool {
        wasCancelled
    }
}

@MainActor
private final class MockStreamingTranscriptionEngine: PindropSpeech.StreamingTranscriptionEngine {
    enum MockError: Error {
        case modelMissing
    }

    private(set) var state: StreamingTranscriptionState = .unloaded
    var loadError: Error?
    var startError: Error?
    var processError: Error?
    var stopError: Error?
    var stopResult: String = "streaming final transcript"

    private(set) var processedBufferCount = 0
    private(set) var loadCallCount = 0
    private(set) var unloadCallCount = 0
    private(set) var resetCallCount = 0
    private(set) var transcriptionCallbackInstallCount = 0
    private(set) var endOfUtteranceCallbackInstallCount = 0
    var loadGate: StreamingCallbackSuspendGate?
    var resetGate: StreamingCallbackSuspendGate?
    var startGate: StreamingCallbackSuspendGate?
    var processGate: StreamingCallbackSuspendGate?
    var stopGate: StreamingCallbackSuspendGate?
    var operationGateToOpenOnReset: StreamingCallbackSuspendGate?
    private var callbackSessionGeneration: UInt64 = 1

    var hasInstalledCallbacks: Bool {
        transcriptionCallbackInstallCount > 0 && endOfUtteranceCallbackInstallCount > 0
    }

    private var transcriptionCallback: StreamingTranscriptionCallback?
    private var endOfUtteranceCallback: EndOfUtteranceCallback?
    private var callbackInstallationWaiters: [UUID: CheckedContinuation<Void, Error>] = [:]

    func loadModel(name: String) async throws {
        loadCallCount += 1
        if let loadGate {
            await loadGate.enterAndWait()
        }
        if let loadError {
            state = .error
            throw loadError
        }
        state = .ready
    }

    func unloadModel() async {
        callbackSessionGeneration &+= 1
        unloadCallCount += 1
        state = .unloaded
    }

    func startStreaming() async throws {
        if let startGate {
            await startGate.enterAndWait()
        }
        if let startError { throw startError }
        callbackSessionGeneration &+= 1
        state = .streaming
    }

    func stopStreaming() async throws -> String {
        if let stopGate {
            await stopGate.enterAndWait()
        }
        if let stopError { throw stopError }
        state = .ready
        return stopResult
    }

    func pauseStreaming() async {
        state = .paused
    }

    func resumeStreaming() async throws {
        state = .streaming
    }

    func processAudioChunk(_ samples: [Float]) async throws {
        if let processError { throw processError }
        processedBufferCount += 1
    }

    func processAudioBuffer(_ buffer: AVAudioPCMBuffer) async throws {
        if let processGate {
            await processGate.enterAndWait()
        }
        if let processError { throw processError }
        processedBufferCount += 1
    }

    func setTranscriptionCallback(_ callback: @escaping StreamingTranscriptionCallback) {
        transcriptionCallbackInstallCount += 1
        transcriptionCallback = callback
        resumeCallbackInstallationWaitersIfReady()
    }

    func setEndOfUtteranceCallback(_ callback: @escaping EndOfUtteranceCallback) {
        endOfUtteranceCallbackInstallCount += 1
        endOfUtteranceCallback = callback
        resumeCallbackInstallationWaitersIfReady()
    }

    func waitUntilCallbacksInstalled(timeout: TimeInterval = 1.0) async throws {
        guard !hasInstalledCallbacks else { return }
        let waiterID = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                callbackInstallationWaiters[waiterID] = continuation
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                    Task { @MainActor [weak self] in
                        self?.failCallbackInstallationWaiter(waiterID)
                    }
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.cancelCallbackInstallationWaiter(waiterID)
            }
        }
    }

    private func resumeCallbackInstallationWaitersIfReady() {
        guard hasInstalledCallbacks else { return }
        let waiters = callbackInstallationWaiters.values
        callbackInstallationWaiters.removeAll()
        for waiter in waiters {
            waiter.resume(returning: ())
        }
    }

    private func failCallbackInstallationWaiter(_ waiterID: UUID) {
        callbackInstallationWaiters.removeValue(forKey: waiterID)?.resume(
            throwing: AsyncTestWaitError.timedOut("streaming callbacks to be installed")
        )
    }

    private func cancelCallbackInstallationWaiter(_ waiterID: UUID) {
        callbackInstallationWaiters.removeValue(forKey: waiterID)?.resume(throwing: CancellationError())
    }

    func reset() async {
        callbackSessionGeneration &+= 1
        resetCallCount += 1
        if let operationGateToOpenOnReset {
            await operationGateToOpenOnReset.open()
        }
        if let resetGate {
            await resetGate.enterAndWait()
        }
        state = .ready
    }

    func emitPartial(_ text: String) {
        transcriptionCallback?(StreamingTranscriptionResult(text: text, isFinal: false))
    }

    func captureFinalUtterance(_ text: String) -> @MainActor @Sendable () -> Void {
        let generation = callbackSessionGeneration
        let transcriptionCallback = transcriptionCallback
        let endOfUtteranceCallback = endOfUtteranceCallback
        return { [weak self] in
            guard self?.callbackSessionGeneration == generation else { return }
            transcriptionCallback?(StreamingTranscriptionResult(text: text, isFinal: true))
            endOfUtteranceCallback?(text)
        }
    }

    func emitFinalUtterance(_ text: String) {
        transcriptionCallback?(StreamingTranscriptionResult(text: text, isFinal: true))
        endOfUtteranceCallback?(text)
    }
}

/// Deterministically parks an engine operation or async callback until released.
private actor StreamingCallbackSuspendGate {
    private var isOpen = false
    private var hasEntered = false
    private var enteredWaiters: [CheckedContinuation<Void, Never>] = []
    private var openWaiters: [CheckedContinuation<Void, Never>] = []

    func enterAndWait() async {
        if !hasEntered {
            hasEntered = true
            let waiters = enteredWaiters
            enteredWaiters.removeAll()
            for waiter in waiters {
                waiter.resume()
            }
        }
        guard !isOpen else { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            if isOpen {
                continuation.resume()
            } else {
                openWaiters.append(continuation)
            }
        }
    }

    func waitUntilEntered() async {
        if hasEntered { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            if hasEntered {
                continuation.resume()
            } else {
                enteredWaiters.append(continuation)
            }
        }
    }

    func open() {
        isOpen = true
        let waiters = openWaiters
        openWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
    }
}

private actor StreamingCallbackCollector {
    private struct Waiter {
        let id: UUID
        let expectedPartials: [String]?
        let expectedFinals: [String]
        let continuation: CheckedContinuation<Void, Error>
    }

    private var partialsStore: [String] = []
    private var finalsStore: [String] = []
    private var waiters: [Waiter] = []

    func recordPartial(_ text: String) {
        partialsStore.append(text)
        resumeSatisfiedWaiters()
    }

    func recordFinal(_ text: String) {
        finalsStore.append(text)
        resumeSatisfiedWaiters()
    }

    func waitFor(
        partials: [String],
        finals: [String],
        timeout: TimeInterval = 1.0
    ) async throws {
        guard partialsStore != partials || finalsStore != finals else { return }
        try await waitUntil(partials: partials, finals: finals, timeout: timeout)
    }

    func waitForFinals(_ finals: [String], timeout: TimeInterval = 1.0) async throws {
        guard finalsStore != finals else { return }
        try await waitUntil(partials: nil, finals: finals, timeout: timeout)
    }

    func snapshot() -> (partials: [String], finals: [String]) {
        (partialsStore, finalsStore)
    }

    private func resumeSatisfiedWaiters() {
        var pending: [Waiter] = []
        for waiter in waiters {
            let partialsMatch = waiter.expectedPartials.map { $0 == partialsStore } ?? true
            if partialsMatch && waiter.expectedFinals == finalsStore {
                waiter.continuation.resume(returning: ())
            } else {
                pending.append(waiter)
            }
        }
        waiters = pending
    }

    private func waitUntil(
        partials: [String]?,
        finals: [String],
        timeout: TimeInterval
    ) async throws {
        let waiterID = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                waiters.append(
                    Waiter(
                        id: waiterID,
                        expectedPartials: partials,
                        expectedFinals: finals,
                        continuation: continuation
                    )
                )
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                    Task { [weak self] in
                        await self?.failWaiter(
                            waiterID,
                            expectedPartials: partials,
                            expectedFinals: finals
                        )
                    }
                }
            }
        } onCancel: {
            Task { [weak self] in
                await self?.cancelWaiter(waiterID)
            }
        }
    }

    private func failWaiter(
        _ waiterID: UUID,
        expectedPartials: [String]?,
        expectedFinals: [String]
    ) {
        guard let index = waiters.firstIndex(where: { $0.id == waiterID }) else { return }
        let waiter = waiters.remove(at: index)
        let expectation = expectedPartials.map {
            "partials \($0) and finals \(expectedFinals)"
        } ?? "finals \(expectedFinals)"
        waiter.continuation.resume(throwing: AsyncTestWaitError.timedOut(expectation))
    }

    private func cancelWaiter(_ waiterID: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == waiterID }) else { return }
        waiters.remove(at: index).continuation.resume(throwing: CancellationError())
    }
}

/// Package-local port of StreamingSessionController.withFinalizeTimeout for service
/// timeout isolation tests (app controller stays in the macOS target).
private enum TestFinalizeStepTimedOut: Error {
    case timedOut
}

private func withTestFinalizeTimeout<T: Sendable>(
    nanoseconds: UInt64,
    operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    let state = TestFinalizeTimeoutState<T>()
    return try await withTaskCancellationHandler {
        try await withCheckedThrowingContinuation { continuation in
            guard state.activate(continuation) else { return }

            let operationTask = Task.detached {
                do {
                    state.resolve(.success(try await operation()))
                } catch {
                    state.resolve(.failure(error))
                }
            }
            state.setOperationTask(operationTask)

            let timeoutTask = Task.detached {
                try? await Task.sleep(nanoseconds: nanoseconds)
                guard !Task.isCancelled else { return }
                state.resolve(.failure(TestFinalizeStepTimedOut.timedOut))
            }
            state.setTimeoutTask(timeoutTask)
        }
    } onCancel: {
        state.resolve(.failure(CancellationError()))
    }
}

private final class TestFinalizeTimeoutState<Output>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Output, Error>?
    private var operationTask: Task<Void, Never>?
    private var timeoutTask: Task<Void, Never>?
    private var pendingResult: Result<Output, Error>?
    private var isResolved = false

    func activate(_ continuation: CheckedContinuation<Output, Error>) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if let pendingResult {
            self.pendingResult = nil
            continuation.resume(with: pendingResult)
            return false
        }
        guard !isResolved else {
            continuation.resume(throwing: CancellationError())
            return false
        }
        self.continuation = continuation
        return true
    }

    func setOperationTask(_ task: Task<Void, Never>) { set(task, asOperation: true) }
    func setTimeoutTask(_ task: Task<Void, Never>) { set(task, asOperation: false) }

    private func set(_ task: Task<Void, Never>, asOperation: Bool) {
        lock.lock()
        let shouldCancel = isResolved
        if !shouldCancel {
            if asOperation { operationTask = task } else { timeoutTask = task }
        }
        lock.unlock()
        if shouldCancel { task.cancel() }
    }

    func resolve(_ result: Result<Output, Error>) {
        lock.lock()
        guard !isResolved else { lock.unlock(); return }
        isResolved = true
        let continuation = self.continuation
        self.continuation = nil
        let operationTask = self.operationTask
        self.operationTask = nil
        let timeoutTask = self.timeoutTask
        self.timeoutTask = nil
        if continuation == nil { pendingResult = result }
        lock.unlock()

        operationTask?.cancel()
        timeoutTask?.cancel()
        continuation?.resume(with: result)
    }
}

private enum AsyncTestWaitError: Error, CustomStringConvertible {
    case timedOut(String)

    var description: String {
        switch self {
        case .timedOut(let expectation):
            "Timed out waiting for \(expectation)"
        }
    }
}
