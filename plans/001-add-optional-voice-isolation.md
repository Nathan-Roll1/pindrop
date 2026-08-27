# Plan 001: Add optional Apple voice isolation before microphone transcription

> **Executor instructions**: Follow this plan step by step. Run every verification command and confirm the expected result before moving to the next step. If anything in the "STOP conditions" section occurs, stop and report; do not improvise. When done, update the status row for this plan in `plans/README.md` unless a reviewer told you they maintain the index.
>
> **Drift check (run first)**: `git diff --stat 233d89e..HEAD -- Packages/PindropShared/Sources/PindropCore/Transcription/TranscriptionEngine.swift Packages/PindropShared/Sources/PindropSpeech/TranscriptionService.swift Pindrop/Services/SettingsStore.swift Pindrop/AppCoordinator.swift Pindrop/Services/StreamingSessionController.swift Pindrop/UI/Settings/DictationSettingsView.swift PindropTests/SettingsStoreTests.swift Packages/PindropShared/Tests/PindropSpeechTests PindropUITests/PindropUITests.swift Localization/app Pindrop/Localization/Localizable.xcstrings Pindrop/Generated`
> If an in-scope file changed since this plan was written, compare the "Current state" excerpts against live code before proceeding. A material mismatch is a STOP condition.

## Status

- **Priority**: P1
- **Effort**: M
- **Risk**: MED
- **Depends on**: none
- **Category**: direction
- **Planned at**: commit `233d89e`, 2026-07-22

## Why this matters

Pindrop currently sends raw 16 kHz mono microphone PCM directly into batch transcription. Noisy rooms can lower recognition quality. Apple ships a public, local `AUSoundIsolation` effect on macOS 13+, so Pindrop's macOS 14 deployment target can add an off-by-default preprocessing toggle without a new model download, cloud service, or third-party dependency.

The first version should process only final microphone dictation audio. It must not alter retained audio, imported media, meeting/system-audio captures, or live streaming partials. Processing failures must preserve the existing transcription path.

## Current state

- `Pindrop/Services/AudioRecorder.swift:1073-1467` — production microphone capture uses `CoreAudioInputCaptureBackend` and a Core Audio device IO callback, not an `AVAudioEngine` graph. The callback converts native input to 16 kHz mono Float32 and spools it:

  ```swift
  guard let convertedBuffer = asrConverter.convert(
      sourceBuffer,
      from: sourceFormat,
      to: targetFormat
  ) else { return }
  if !audioStorage.enqueue(convertedBuffer) { ... }
  onBuffer(convertedBuffer)
  ```

- `Pindrop/Services/AudioRecorder.swift:2696-2724` — `AudioRecorder.stopRecording()` materializes the file-backed 16 kHz Float32 spool as `Data` and returns it to callers.
- `Packages/PindropShared/Sources/PindropCore/Transcription/TranscriptionEngine.swift:10-18` — `TranscriptionOptions` currently carries only language and vocabulary bias.
- `Packages/PindropShared/Sources/PindropSpeech/TranscriptionService.swift:484-544` — the central batch entry validates non-empty audio, marks the service transcribing, then passes the same `Data` to `transcribeWithOptionalDiarization`.
- `Pindrop/AppCoordinator.swift:3437-3445` — `makeTranscriptionOptions` centralizes normal batch options. Its callers include microphone dictation, note append, quick capture, manual meeting capture, and imported media, so voice isolation must be opt-in per call rather than implicitly enabled for every caller.
- `Pindrop/Services/StreamingSessionController.swift:318-353` — streaming finalization re-transcribes the complete recorded waveform offline. This is the correct place for the setting to affect final streaming output; live partials should stay on the existing raw-buffer path.
- `Pindrop/UI/Settings/DictationSettingsView.swift:49-89` — the Dictation pane's first card owns microphone selection. Put the new control in this card.
- `Pindrop/Services/SettingsStore.swift:90-110,227-228,972-996` — typed defaults, `@AppStorage`, and reset logic are the established preference pattern.
- `PindropUITests/PindropUITests.swift:48-61` — `testDictationTabFixtureLaunches` is the existing UI fixture test to extend.

### Verified Apple platform facts

- [`kAudioUnitSubType_AUSoundIsolation`](https://developer.apple.com/documentation/audiotoolbox/kaudiounitsubtype_ausoundisolation) is public on macOS 13+.
- The installed macOS 26.5 SDK declares the unit as an Apple effect that isolates a specified sound type (`AudioToolbox.framework/.../AUComponent.h:468-485`).
- The public parameters are wet/dry mix and sound type. Standard voice isolation is available on macOS 13+; high-quality voice isolation is macOS 15+ (`AudioUnitParameters.h:706-726`).
- `AVAudioIONode.setVoiceProcessingEnabled` is a different capture/communications path. It requires device rendering, both I/O nodes in voice-processing mode, and a stopped engine; it does not support manual rendering (`AVAudioIONode.h:126-155`). Do not use it for this feature.
- Control Center microphone modes are user-selected. Public `AVCaptureDevice.preferredMicrophoneMode` and `activeMicrophoneMode` are read-only; the app can only present the system microphone-mode UI (`AVCaptureDevice.h:2568-2641`). Do not use private Control Center symbols.
- A local spike on the current M5 Pro successfully rendered `AUSoundIsolation` offline at 16 kHz mono. Five seconds of the repository's AMI fixture rendered in 0.056 seconds with standard voice isolation and 0.089 seconds with high-quality isolation. These timings establish feasibility on this machine only, not a cross-device performance guarantee.

## Commands you will need

| Purpose | Command | Expected on success |
|---|---|---|
| Localization generation | `just l10n-sync` | exits 0 and updates generated catalogs/Swift metadata |
| Localization validation | `just l10n-lint` | exits 0 with no missing locale entries |
| Shared package tests | `just shared-test` | exits 0; all PindropShared tests pass |
| App unit tests | `just test` | exits 0; Unit test plan passes |
| Settings UI fixture | `just test-ui` | exits 0; UI test plan passes |
| Debug build | `just build` | exits 0 with no new warnings from this change |

## Suggested executor toolkit

- Load `axiom-media`, `axiom-concurrency`, and `axiom-testing` if available before implementation.
- Use Apple SDK headers and the Apple documentation URL above as ground truth. Do not substitute undocumented/private microphone-mode APIs.

## Scope

**In scope**:

- `Packages/PindropShared/Sources/PindropCore/Transcription/TranscriptionEngine.swift`
- `Packages/PindropShared/Sources/PindropSpeech/AudioPreprocessor.swift` (create)
- `Packages/PindropShared/Sources/PindropSpeech/TranscriptionService.swift`
- `Packages/PindropShared/Tests/PindropCoreTests/TranscriptionOptionsTests.swift` (create only if no existing options test fits)
- `Packages/PindropShared/Tests/PindropSpeechTests/AudioPreprocessorTests.swift` (create)
- `Packages/PindropShared/Tests/PindropSpeechTests/TranscriptionServiceTests.swift`
- `Pindrop/Services/SettingsStore.swift`
- `Pindrop/AppCoordinator.swift`
- `Pindrop/Services/StreamingSessionController.swift`
- `Pindrop/UI/Settings/DictationSettingsView.swift`
- `PindropTests/SettingsStoreTests.swift`
- `PindropTests/StreamingSessionControllerTests.swift`
- `PindropUITests/PindropUITests.swift`
- `Localization/app/*.yml` for every shipped locale
- Generated localization artifacts produced by `just l10n-sync`: `Pindrop/Localization/Localizable.xcstrings`, `Pindrop/Generated/LocalizationMetadata.swift`, and `Pindrop/Generated/L10nKeys.swift`
- `plans/README.md` status row only

**Out of scope**:

- Changes to `CoreAudioInputCaptureBackend` or `AVAudioEngineCaptureBackend`.
- Real-time processing of streaming buffers or live partial transcripts.
- Imported files, URL media, manual meeting capture, system-audio capture, or mixed capture.
- Control Center microphone-mode automation or private APIs.
- RNNoise, WebRTC Audio Processing, bundled ML models, cloud denoisers, strength sliders, automatic noise detection, telemetry, or audio-retention format changes.
- High-quality voice mode on macOS 15+. Start with the standard voice type across all supported systems; promote high-quality mode only after a separate quality corpus comparison.

## Git workflow

- Branch: `advisor/001-optional-voice-isolation`
- Keep commits scoped by contract: domain/processor, routing/tests, then UI/localization.
- Do not push or open a pull request unless instructed.

## Steps

### Step 1: Add the domain option and persisted preference

1. In `TranscriptionEngine.swift`, add a public `AudioPreprocessingMode: Sendable, Equatable` with exactly `.none` and `.voiceIsolation`.
2. Add `audioPreprocessingMode` to `TranscriptionOptions`, defaulting to `.none`. Preserve source compatibility for every existing initializer call.
3. In `SettingsStore`, add `Defaults.voiceIsolationEnabled = false`, an `@AppStorage("voiceIsolationEnabled", store: SettingsStoreRuntime.appStorageStore)` Boolean, and reset it to the default in the existing reset method.
4. Add tests that prove the option and stored preference default off, can be enabled, and reset to off. Isolate the test `UserDefaults` suite using the existing `SettingsStoreTests` pattern.

**Verify**: `just shared-test && just test` -> both commands exit 0; existing option callers still compile and preference tests pass.

### Step 2: Implement a cancellable offline Apple sound-isolation processor

Create `Packages/PindropShared/Sources/PindropSpeech/AudioPreprocessor.swift` with:

1. A small `AudioPreprocessing` protocol suitable for dependency injection into `TranscriptionService`. It accepts 16 kHz mono Float32 `Data` plus a mode and returns processed `Data` asynchronously. The protocol/concrete type must be safely sendable; prefer an actor that owns no cross-call mutable `AVAudioEngine` state.
2. An `AppleSoundIsolationPreprocessor` implementation for `.voiceIsolation`:
   - Reject non-Float32-aligned input with a typed, localized processing error.
   - Treat empty data and `.none` as no-ops.
   - Instantiate an Apple effect with component type `kAudioUnitType_Effect`, subtype `kAudioUnitSubType_AUSoundIsolation`, and manufacturer `kAudioUnitManufacturer_Apple`.
   - Set `kAUSoundIsolationParam_SoundToIsolate` to `kAUSoundIsolationSoundType_Voice`. Do not select the macOS 15 high-quality type in this plan.
   - Feed a 16 kHz mono Float32 buffer through `AVAudioEngine` offline manual rendering. Use a maximum render block of 1024 frames; the probed unit reported `maximumFramesToRender == 1156`.
   - Preallocate the output once and append/copy rendered frames without creating a new `Data` object for every block. Keep peak memory bounded by the existing 40 MB/10-minute ASR limit.
   - Preserve the input frame count and return exactly the same byte count.
   - Check cancellation inside the render loop, stop the engine in all paths, and never log sample contents.
3. Do not cache a live engine across calls in the first implementation. Simpler per-call ownership prevents stale render state and makes cancellation/cleanup deterministic.

Add a real, hardware-free processor test using a short synthesized 16 kHz mono Float32 buffer. Assert the call completes, output byte count equals input byte count, and every output sample is finite. This test exercises manual rendering only; it must not request microphone access.

**Verify**: `just shared-test` -> exits 0 and the new processor test passes on macOS 14+.

### Step 3: Apply preprocessing centrally and fail open

1. Inject `any AudioPreprocessing` into `TranscriptionService` with a production default of `AppleSoundIsolationPreprocessor`. Preserve existing initializer call sites through a default argument.
2. In the central batch `transcribe(...)` entry, after non-empty validation and generation/state ownership are established but before diarization/transcription, process only when `options.audioPreprocessingMode == .voiceIsolation`.
3. Cancellation is not a recoverable preprocessing failure: rethrow `CancellationError` immediately.
4. For any other preprocessing error, log one warning through the existing transcription logger and continue with the original `audioData`. Optional isolation must never turn a valid recording into a failed transcription.
5. Pass the processed data through both diarization and transcription. Callers must continue holding the raw `Data`; do not replace data used by retention/history outside the service.
6. Extend `TranscriptionServiceTests` with an injected spy processor and capturing engine to prove:
   - `.none` skips the processor and sends original bytes to the engine.
   - `.voiceIsolation` sends processor output to the engine.
   - a non-cancellation processor error falls back to original bytes and transcription succeeds.
   - processor cancellation propagates and restores service state.

**Verify**: `just shared-test` -> exits 0; all four service contracts pass.

### Step 4: Route the setting only through microphone dictation flows

1. Change `AppCoordinator.makeTranscriptionOptions` to accept an explicit Boolean such as `appliesVoiceIsolation`, defaulting to `false`. Map it to `.voiceIsolation` only when both that argument and `settingsStore.voiceIsolationEnabled` are true.
2. Pass `appliesVoiceIsolation: true` from exactly these final microphone paths:
   - note append (`stopRecordingAndTranscribeForNoteAppend`),
   - quick capture (`stopRecordingAndTranscribeForQuickCapture`),
   - ordinary batch dictation (`stopRecordingAndTranscribe`).
3. Leave manual recording/meeting capture and imported-media callers on the default `false` path.
4. In `StreamingSessionController.finalize`, set `.voiceIsolation` on the offline re-transcription options when the preference is enabled. Do not alter `processAudioBuffer`, streaming-engine input, or live partial text.
5. Add/extend `StreamingSessionControllerTests` so the final offline transcription receives voice isolation when enabled and `.none` when disabled.
6. Confirm raw `recordedAudioData` remains the value used for retained audio and any later raw-audio ownership outside `TranscriptionService`.

**Verify**: `just test` -> exits 0; microphone finalization tests pass, and existing media/manual-capture tests remain unchanged.

### Step 5: Add the Dictation settings control and translations

1. Add a `SettingsRow` under the existing Microphone card in `DictationSettingsView`:
   - title: `Voice isolation`
   - subtitle: `Reduce background noise before transcription`
   - control: `SettingsToggle(isOn: $settings.voiceIsolationEnabled, ...)`
   - accessibility identifier: `settings.toggle.voiceIsolation`
2. Keep the setting off by default. Do not add a strength selector or high-quality mode picker.
3. Add both strings to every shipped locale's YAML source under `Localization/app/`; do not edit generated catalogs by hand.
4. Run `just l10n-sync`, then `just l10n-lint`.
5. Extend `testDictationTabFixtureLaunches` to assert `settings.toggle.voiceIsolation` exists.

**Verify**: `just l10n-sync && just l10n-lint && just test-ui` -> all exit 0; the Dictation fixture finds the toggle.

### Step 6: Run end-to-end gates

1. Run `just shared-test`.
2. Run `just test`.
3. Run `just test-ui`.
4. Run `just build`.
5. Launch the built app, open Settings > Dictation, and verify the off-by-default toggle persists after closing/reopening Settings.
6. With a short noisy microphone recording, compare the same sentence with the toggle off and on. Confirm both complete transcription, the enabled run adds only post-stop processing latency, and retained audio remains raw if retention is enabled. Record observations in the pull-request description; do not add subjective claims to product copy.

**Verify**: all four commands exit 0; the app completes both off/on microphone transcription scenarios without a crash or permission change.

## Test plan

- `TranscriptionOptionsTests`: default `.none`; explicit `.voiceIsolation` survives equality.
- `AudioPreprocessorTests`: real offline render, same byte count, finite output, cancellation cleanup if a deterministic cancellation seam is practical.
- `TranscriptionServiceTests`: skip/off, processed-data routing, fail-open, cancellation propagation.
- `SettingsStoreTests`: default false, persistence, reset.
- `StreamingSessionControllerTests`: final offline options reflect the preference; live streaming path is untouched.
- `PindropUITests.testDictationTabFixtureLaunches`: voice-isolation control exists.
- Full `just shared-test`, `just test`, `just test-ui`, and `just build` gates.

## Done criteria

- [ ] Voice isolation is off by default and user-configurable in Settings > Dictation.
- [ ] Only final microphone dictation audio is processed; imports, meetings, system audio, mixed audio, retained audio, and live partials are unchanged.
- [ ] Standard Apple `AUSoundIsolation` runs locally through offline manual rendering at 16 kHz mono.
- [ ] Successful processing preserves frame/byte count and reaches both diarization and transcription.
- [ ] Non-cancellation processing errors fall back to raw audio; cancellation still cancels.
- [ ] Every shipped locale contains both new strings; localization sync/lint passes.
- [ ] `just shared-test`, `just test`, `just test-ui`, and `just build` all exit 0.
- [ ] No undocumented/private Apple API or new third-party dependency is present.
- [ ] No file outside the in-scope list is modified except build-generated ignored artifacts.
- [ ] `plans/README.md` marks plan 001 DONE.

## STOP conditions

Stop and report instead of improvising if:

- `kAudioUnitSubType_AUSoundIsolation` cannot instantiate or cannot enter offline manual rendering on the minimum supported macOS 14 runtime.
- The unit cannot render 16 kHz mono Float32 while preserving frame count.
- Implementing the processor requires changing the production Core Audio capture backend.
- The change cannot distinguish ordinary microphone dictation from manual meeting/system/mixed capture.
- The processor requires microphone permission during hardware-free manual rendering.
- Fail-open behavior would hide cancellation or leave `TranscriptionService.state == .transcribing`.
- The live code materially differs from the cited current-state paths after the drift check.

## Maintenance notes

- Review the processor's actor isolation, cancellation, engine teardown, and allocation behavior closely. The 10-minute input cap is 40 MB; avoid per-render-block `Data` allocations.
- Standard voice isolation is deliberately chosen for consistency with macOS 14. Evaluate high-quality voice isolation separately against a noisy-speech corpus and on older Apple Silicon before changing the default implementation.
- Voice isolation can suppress non-dominant speakers. Keep it out of diarized meeting/manual capture unless a separate product decision and quality evaluation explicitly expand scope.
- If live partials later need isolation, design a stateful real-time processor independently. Do not retrofit capture-path voice processing into this offline service without device-route and streaming-latency tests.
