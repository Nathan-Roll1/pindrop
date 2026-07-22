//
//  TranscriptionBackendTests.swift
//  PindropTests
//
//  Created on 2026-04-17.
//
//  SettingsStore-backed backend selection remains app-owned.
//

import Foundation
import PindropCore
import Speech
import Testing
@testable import Pindrop

@MainActor
@Suite
struct TranscriptionBackendSettingsTests {

   private func makeCleanStore() -> SettingsStore {
      let store = SettingsStore()
      store.resetAllSettings()
      return store
   }

   @Test func defaultBackendIsParakeet() {
      let store = makeCleanStore()
      #expect(store.selectedTranscriptionBackend == .parakeet)
      #expect(store.resolvedTranscriptionBackend == .parakeet)
   }

   @Test func selectionRoundTripsThroughRawStorage() {
      let store = makeCleanStore()
      store.selectedTranscriptionBackend = .appleSpeechTranscriber
      #expect(store.transcriptionBackend == "apple")
      #expect(store.selectedTranscriptionBackend == .appleSpeechTranscriber)
   }

   @Test func applePreferenceResolvesToAppleOnlyWhenAvailable() {
      let store = makeCleanStore()
      store.selectedTranscriptionBackend = .appleSpeechTranscriber

      // `resolvedTranscriptionBackend` answers .apple only on hosts that expose
      // SpeechTranscriber. Mirror the same check we perform at the call site.
      let expected: TranscriptionBackend = SettingsStore.appleSpeechTranscriberAvailable
         ? .appleSpeechTranscriber
         : .parakeet
      #expect(store.resolvedTranscriptionBackend == expected)
   }

   @Test func availabilityMatchesSpeechTranscriberIsAvailable() {
      let expected: Bool
      if #available(macOS 26, *) {
         expected = SpeechTranscriber.isAvailable
      } else {
         expected = false
      }
      #expect(SettingsStore.appleSpeechTranscriberAvailable == expected)
   }
}
