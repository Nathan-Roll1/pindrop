//
//  TranscriptionBackendTests.swift
//  PindropSpeechTests
//
//  Created on 2026-04-17.
//

import AVFoundation
import Foundation
import Testing
import PindropCore
@testable import PindropSpeech

@MainActor
@Suite
struct TranscriptionBackendTests {

   /// Minimal stub for StreamingTranscriptionEngine, scoped to this suite so we aren't
   /// coupled to TranscriptionServiceTests' private mock.
   /// Conforms to the PindropSpeech refinement (buffer + Core sample surface).
   @MainActor
   final class StubStreamingEngine: PindropSpeech.StreamingTranscriptionEngine {
      var state: StreamingTranscriptionState = .unloaded
      private(set) var loadCount = 0
      private(set) var unloadCount = 0

      func loadModel(name: String) async throws {
         loadCount += 1
         state = .ready
      }
      func unloadModel() async {
         unloadCount += 1
         state = .unloaded
      }
      func startStreaming() async throws { state = .streaming }
      func stopStreaming() async throws -> String {
         state = .ready
         return ""
      }
      func pauseStreaming() async { state = .paused }
      func resumeStreaming() async throws { state = .streaming }
      func processAudioChunk(_ samples: [Float]) async throws {}
      func processAudioBuffer(_ buffer: AVAudioPCMBuffer) async throws {}
      func setTranscriptionCallback(_ callback: @escaping StreamingTranscriptionCallback) {}
      func setEndOfUtteranceCallback(_ callback: @escaping EndOfUtteranceCallback) {}
      func reset() async { state = .ready }
   }

   // MARK: - TranscriptionService integration

   @Test func prepareStreamingEngineSwitchesEngineOnBackendChange() async throws {
      // Two-stage test: first a Nemotron backend → NemotronStreamingEngine; then an
      // Apple preference → Apple engine (on macOS 26+) or fallback with the flag set.
      let parakeetEngine = StubStreamingEngine()
      let appleEngine = StubStreamingEngine()
      var backend: TranscriptionBackend = .parakeet
      let service = TranscriptionService(
         storageLocations: try SpeechTestSupport.makeStorageLocations().locations,
         streamingEngineFactory: { _, _ in parakeetEngine  },
         appleSpeechEngineFactory: { appleEngine },
         streamingBackendProvider: { backend }
      )

      try await service.prepareStreamingEngine()
      #expect(parakeetEngine.state == .ready)

      backend = .appleSpeechTranscriber
      try await service.prepareStreamingEngine()
      #expect(appleEngine.state == .ready)
      // Parakeet should have been torn down on backend swap.
      #expect(parakeetEngine.unloadCount >= 1)
   }

   @Test func appleUnavailabilityFallsBackToParakeetAndSetsFlag() async throws {
      let parakeetEngine = StubStreamingEngine()
      // Simulate macOS < 26 by returning nil from the Apple factory.
      let service = TranscriptionService(
         storageLocations: try SpeechTestSupport.makeStorageLocations().locations,
         streamingEngineFactory: { _, _ in parakeetEngine  },
         appleSpeechEngineFactory: { nil },
         streamingBackendProvider: { .appleSpeechTranscriber }
      )

      try await service.prepareStreamingEngine()
      #expect(parakeetEngine.state == .ready)
      #expect(service.consumeAppleBackendFallbackFlag() == true)
      // Second read — the flag is one-shot.
      #expect(service.consumeAppleBackendFallbackFlag() == false)
   }
}
