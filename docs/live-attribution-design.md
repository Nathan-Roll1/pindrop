# Pindrop Meeting Pillar: Live Attribution, Streaming Diarization, Meeting-First Entry, Flow Polish

Design document. Branch `feature/notes-that-record` (unshipped). Author: architecture pass, 2026-08-30. Revised after review round D (three adversarial reviews: architecture and concurrency, simplicity and scope, product and accessibility).

---

## 1. Overview, goals, non-goals

### 1.1 What we are building

Four independently shippable phases that take the "notes that record" shell from a single unattributed live paragraph to a meeting surface with per-speaker live turns, on-device streaming speaker labels, a meeting-first way in, and an honest stop-to-note flow.

| Phase | Ships | New models |
|---|---|---|
| 1 | Live turns attributed to the microphone ("You") or the system-audio channel ("Call audio") | none |
| 2 | Sortformer streaming diarization on the system channel, plus enrolled-name promotion | Sortformer streaming (CoreML) |
| 3 | Conference-call detection, "Record this call", meeting-note menu entry and presets | none |
| 4 | Visible pipeline stages, template picker reachability, mic-only recovery delivery, debris removal | none |

### 1.2 Goals

- The live transcript tells the reader who is talking, at a latency the reader accepts.
- Live labels are honest. They are provisional, they never claim more than the model knows, and the offline pass at finalize stays the record.
- Live loss is visible. When a channel loses the engine, the reader sees a marker, not a silent gap.
- Everything stays on device.
- Each phase lands green, bisectable, and shippable on its own.

### 1.3 Non-goals

- Full-mix live diarization (mic and system mixed into one diarizer input). Out of scope.
- Reading Zoom or Meet UI through Accessibility to harvest names. Out of scope.
- Reviving the pop-out note window. Out of scope.
- Calendar and EventKit. Not built, and no seam is invented for it either. A comment marks where a calendar source would attach.
- Changing any already-landed V15 `@Model` field layout. Forbidden (see section 7).

### 1.4 What the research settles

- Granola does not diarize live. Its live labels are channel-based: microphone is "Me", system audio is "Them". Named speakers come from scraping the conference app's UI, which we are not doing. This validates Phase 1 as a real product step, not a placeholder.
- FluidAudio 0.15.4 (already pinned, already vendored in `DerivedData/SourcePackages/checkouts/FluidAudio`) contains `SortformerDiarizer` with a complete streaming API. No dependency bump.
- Streaming diarization runs roughly 10 to 15 DER points worse than offline. FluidAudio's own guidance is: streaming for live labels, offline for the record. Our finalize pipeline already runs the offline pass, so the split is free.
- Sortformer's speaker cap is 4. Under our design the cap applies only to the system-audio channel, because the local user arrives on a separate channel. Effective capacity is 4 remote voices plus the local user.

---

## 2. Domain vocabulary

Name these once. Use them in code, tests, comments, and copy.

| Term | Meaning | Where it lives |
|---|---|---|
| **capture channel** | One physical audio source of a capture. Existing type `CaptureSourceKind` (`.microphone`, `.systemAudio`). Do not invent a second enum. | `PindropCore` |
| **`LiveSpeakerRef`** | Who a piece of live text is attributed to, plus how sure we are. | new, `PindropCore` |
| **`LiveSpeakerTier`** | The confidence tier of a `LiveSpeakerRef`: `.channel`, `.provisional`, `.named`. | new, `PindropCore` |
| **`LiveTranscriptSpan`** | One settled paragraph of live text with its speaker and its capture-time range. The live counterpart of `TranscriptSegmentSnapshot`. | new, `PindropCore` |
| **`LiveTurn`** | Consecutive spans of one speaker. Rendered with one header. Mirrors the existing `TranscriptTurn` (`TranscriptSegmentList.swift:28`). | new, app UI |
| **`LiveTurnBoundaryReason`** | Why a span or turn ended: `.channelChange`, `.speakerChange`, `.endOfUtterance`, `.idlePause`, `.sessionEnd`. | new, `PindropCore` |
| **`LiveChannelArbiter`** | Decides which capture channel owns the single streaming ASR engine at any instant. | new, `AudioRecorder` |
| **`LiveSpeakerGate`** | Per-channel speech detector. Tracks each channel's own adaptive noise floor and reports "speech" relative to it, never against a fixed absolute level. | new, `AudioRecorder` |
| **channel owner** | The capture channel currently feeding the ASR engine. | vocabulary only |
| **pending handover** | An ownership change the arbiter has decided but not applied, because it waits for a boundary the ASR engine itself produced. | vocabulary only |
| **dropped-speech marker** | A visible placeholder for speech that reached the durable spool but not the live engine, because the other channel owned it. | new, `PindropCore` |
| **capture time** | Seconds since the capture's first audio buffer. The single master timeline. All Phase 2 attribution is expressed in it. | vocabulary only |
| **fed watermark** | Seconds of audio the ASR engine has consumed, reported by the engine on its own emissions. Data carried with the text, never a clock read at arrival. | new, `PindropSpeech` (Phase 2) |
| **ownership run** | One contiguous stretch of one channel owning the engine, held as `(source, fedStart, captureStart)`. Two scalars are enough to convert the fed watermark to capture time inside the run. | new, app service layer (Phase 2) |
| **`LiveDiarizationEngine`** | Actor owning `SortformerDiarizer` on its own serial executor. Never touches the main actor. | new, `PindropSpeech` |
| **`LiveSpeakerEmbedder`** | Actor that turns a short clip of one voice into an offline-space 256-dim embedding for profile matching. | new, `PindropSpeech` |
| **speaker slot** | One of Sortformer's four output tracks on the system channel. | vocabulary only |
| **promotion** | A `LiveSpeakerRef` moving up a tier, for example `.provisional` "Speaker 2" becoming `.named` "Dana". | vocabulary only |
| **`ConferenceAudioMonitor`** | Watches Core Audio process objects for a conference app with the microphone open. | new, app service layer |

Reserved words we do not reuse: "diarization" alone always means the offline pass. Say "streaming diarization" or "live labels" for Phase 2.

---

## 3. Phase 1: live "You" and "Call audio" turns

### 3.1 The problem Phase 1 actually solves

Today, `MixedAudioCaptureBackend.forwardLiveBuffer` (`Pindrop/Services/AudioRecorder.swift:3239` to `:3255`) forwards system-audio buffers to the streaming engine when system audio is active, and microphone buffers only when it is not:

```swift
case .microphone:
    return !state.isStarting && state.microphone.isActive && !state.systemAudio.isActive
case .systemAudio:
    return state.systemAudio.isActive
```

In a meeting with system audio on, **the user's own voice never reaches the live transcript**. The live text is one growing paragraph with no attribution.

Phase 1 fixes both: both channels reach the live engine, and every settled paragraph carries the channel that produced it.

### 3.2 The core decision: one engine, exclusive channel ownership

`TranscriptionService` owns exactly one streaming engine (`private var streamingEngine`, plus a lease-count system at lines 263 to 266 and 1378 to 1408). Running two engines would mean a second Nemotron instance on the Neural Engine, doubled weights in memory, and a rewrite of the lease machinery. That is too much risk for Phase 1 and it fights the GPU and ANE contention lesson already learned in this codebase.

Instead: **`LiveChannelArbiter` gives one channel exclusive ownership of the engine at a time**, and hands over **only at a boundary the engine has already produced**. The channel that loses a cross-talk race loses only its *live* text, and the live view says so out loud. Its audio is still spooled durably and still transcribed by the offline pass at finalize. The record is complete; the preview is lossy and honest about it.

#### Why a handover waits for an engine boundary

`StreamingNemotronAsrManager.process(audioBuffer:)` accumulates samples and decodes only `while audioBuffer.count >= config.chunkSamples` (`DerivedData/SourcePackages/checkouts/FluidAudio/Sources/FluidAudio/ASR/Parakeet/Streaming/Nemotron/StreamingNemotronAsrManager.swift:262` to `:270`). `NemotronChunkSize` is **1120 ms** at `StreamingChunkProfile.standard` and **560 ms** at `.lowLatency` (`Packages/PindropShared/Sources/PindropSpeech/FeatureModelType.swift:15` to `:27`), and the profile is user-switchable at runtime.

Splicing a new channel into a partly filled accumulator puts two voices inside one decoded chunk. The result is one indivisible string containing both speakers, and no clock, splice map, or timestamp can separate it. A short silence pad does not help: a pad smaller than a chunk is simply concatenated.

So the arbiter never splices mid-chunk. It records a **pending handover**, and the consumer applies it at the next boundary the engine itself produced: an end-of-utterance final (`ingestFinal`) or an idle commit. At that instant the accumulator was just flushed and committed, so "everything committed so far belongs to A, everything after belongs to B" is exact **by commit ordering**, with no timestamps involved at all.

If no natural boundary arrives within `handoverCeilingSeconds`, the consumer force-flushes: it feeds exactly `chunkSamples - (fedSamples % chunkSamples)` samples of silence, which forces one decode, and applies the handover behind it.

**The honest bound: live attribution granularity is one ASR chunk.** A word spoken in the few hundred milliseconds before a handover can land in the outgoing speaker's paragraph. This design does not claim better, and the offline pass corrects it at finalize.

#### Ownership is gated on speech, not on level

A fixed absolute RMS floor does not work here, for two reasons.

- Microphone level depends on device gain and system-audio level depends on app volume. `AudioLevelNormalizer` already concedes this in its own doc comment (`AudioRecorder.swift:3482` to `:3487`). One constant cannot mean the same thing on both channels.
- A conference call's far end streams continuous room tone, and shared video or music on hold never drops below any fixed floor for half a second. With a fixed floor plus "system audio wins ties", system audio takes ownership on the first frame and never releases it. The local user's live text still never appears, which is the exact regression Phase 1 exists to fix.

`LiveSpeakerGate` therefore tracks a **per-channel adaptive noise floor** (a slow running minimum of short-term RMS, one instance per channel, fast attack and slow release) and reports speech only when short-term RMS exceeds that channel's own floor by `speechMarginDB`. Every arbiter rule reads the gate. No rule reads a raw level.

#### The echo gate: the microphone hears the speakers

`CoordinatorTranscriptionRoute.appliesVoiceIsolation` returns `false` for mixed system-audio captures (`Pindrop/AppCoordinator.swift:256` to `:265`: "Mixed system audio must stay raw: isolation would suppress the other speakers"), and there is no echo cancellation anywhere in the tree. On built-in speakers, the common meeting case, the microphone channel contains the remote audio.

Without a discriminator the arbiter grants the microphone ownership on an "mm-hmm", then keeps it under rules 3 and 5 because the microphone is still above its gate, hearing the remote through the speakers. The live transcript then prints the other person's words under the header `You`. That is the dishonesty section 1.2 forbids, on the one element Phase 1 exists to add.

Before the microphone may claim ownership the arbiter requires **both**:

1. Normalized cross-correlation of the two channels' 0.5 s RMS envelopes, over a 0 to 100 ms lag window, stays below `echoCorrelationCeiling`. Above it the microphone is hearing the speakers, and the claim is denied.
2. Microphone RMS exceeds system-audio RMS by `micDominanceMarginDB`, sustained for the whole claim window.

Both are `vDSP` work over scalars already computed for the gate, a few microseconds per buffer.

#### Arbiter rules

1. A capture with one channel: that channel owns the engine for the whole session. No arbitration, no gate, no echo check, no boundaries beyond pauses.
2. Ownership starts unowned. The first channel whose gate opens takes ownership. If both open in the same buffer, system audio wins (a remote voice is the harder loss).
3. The owner keeps ownership while its gate is open, or has been within the last `holdWindow`.
4. A challenger takes ownership only when **all** of these hold: the owner's gate has been shut for `releaseWindow`; the challenger's gate has been open for `claimWindow`; the owner has held the engine for at least `minimumOwnershipSeconds`; and, for a microphone challenger, both echo gates pass.
5. During cross talk the current owner keeps ownership. Flapping mid-sentence produces worse text than losing an interjection.
6. When the non-owner's gate stays open for `droppedSpeechSeconds` while it does not own the engine, the arbiter reports a **dropped-speech interval**. The live view draws a marker for it. Silent loss is not acceptable (section 3.5).

Constants (all injectable for tests, all on the arbiter):

```swift
/// How far above a channel's own tracked noise floor counts as speech.
static let speechMarginDB: Float = 9
/// How fast each channel's noise floor follows the signal down and back up.
static let floorAttackSeconds: TimeInterval = 0.20
static let floorReleaseSeconds: TimeInterval = 3.00

static let holdWindow: TimeInterval = 0.60
static let releaseWindow: TimeInterval = 0.50
static let claimWindow: TimeInterval = 0.25

/// Never hand over inside one ASR chunk. Derived from the active profile,
/// not guessed: 1.52 s at `.standard`, 0.96 s at `.lowLatency`.
static func minimumOwnershipSeconds(for profile: StreamingChunkProfile) -> TimeInterval {
    profile.nemotronChunkSize.seconds + 0.40
}

/// How long a pending handover waits for a natural engine boundary before the
/// consumer force-flushes a partial chunk of silence.
static let handoverCeilingSeconds: TimeInterval = 3.00

/// The microphone may not claim the engine while it is hearing the speakers.
static let echoCorrelationCeiling: Float = 0.55
static let micDominanceMarginDB: Float = 6

/// Unowned speech longer than this is reported as a visible gap.
static let droppedSpeechSeconds: TimeInterval = 1.00
```

`minimumOwnershipSeconds` also caps the handover rate at one per 1.52 s at `.standard`, so the worst-case forced-flush cost is under one chunk of silence per 1.5 s, and it is paid only when no natural boundary arrived. State this number in the implementation comment; an unbounded pad rate would let the 32-buffer ring drop real speech.

#### Locking

RMS, the gate, and the correlation are computed on the capture thread **outside every lock**. The arbiter keeps its own small lock over scalar state only. It never takes `AudioRecorder.stateLock`, which is also held from the main actor during `stopCapture` and `stopMeetingRecording` (`AudioRecorder.swift:3095` to `:3106`). A realtime IO thread blocking behind main-actor teardown is a dropout.

#### The meter path is not a bystander

Today `forwardLiveBuffer`'s exclusion rule is not only an ASR routing rule. It is what guarantees that only one Core Audio IO thread at a time enters the `deliver` closure, which is `AudioRecorder.onBuffer` at `:3923` to `:3933` and `:4029` to `:4041` and calls `levelNormalizer.scaled(bandLevelAnalyzer.process(buffer))`.

`ThreeBandLevelAnalyzer` (`:3415`) holds unguarded IIR state `lowState` and `midState`. `AudioLevelNormalizer` (`:3488`) holds an unguarded `envelope`, and its own doc comment says instances must only be used from the capture callback's serial context. Admitting both channels without changing this is an unsynchronized data race in the realtime audio path, plus filter-state cross-contamination between microphone and system audio that garbles the orb bands.

Phase 1 therefore gives **each source its own analyzer and normalizer instance**, mirroring the per-source pattern `noteAudioLevel` already uses at `:3277`. Each IO thread touches only its own pair. Each source publishes its latest `AudioBandLevels` under one small dedicated lock, and the meter reader merges the two. Cleanup item 1 owns this change, not only the ASR rule. Test: `bothChannelsMeterWithoutSharingFilterState`.

### 3.3 Data model changes, verbatim

**New file** `Packages/PindropShared/Sources/PindropCore/Capture/LiveAttribution.swift`:

```swift
//
//  LiveAttribution.swift
//  PindropCore
//
//  Created on 2026-09-01.
//
//  What a live transcript knows about who is talking, while it is still
//  talking. Live attribution is provisional by construction: the offline pass
//  at finalize is the record, and it replaces every label written here.
//

import Foundation

/// How much a live speaker label is worth.
///
/// The tiers are ordered. A label may move up a tier during a capture. It never
/// moves down: a name that was shown once is not taken away mid-recording.
public enum LiveSpeakerTier: String, Codable, Sendable, Equatable, Comparable {
    /// Attributed only by the capture channel the audio arrived on.
    case channel
    /// Attributed to one streaming-diarizer slot with no name yet.
    case provisional
    /// Matched to a participant profile.
    case named

    private var rank: Int {
        switch self {
        case .channel: 0
        case .provisional: 1
        case .named: 2
        }
    }

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rank < rhs.rank }
}

/// Who one piece of live text belongs to.
///
/// `key` groups every span of one speaker within one capture. It is stable for
/// the life of the capture even when the tier or the display name changes, so
/// the interface can promote a label in place instead of splitting a turn.
public struct LiveSpeakerRef: Codable, Sendable, Equatable, Hashable, Identifiable {
    public var id: String { key }

    public let key: String
    public let tier: LiveSpeakerTier
    /// True only for the microphone channel of the person recording.
    public let isCurrentUser: Bool
    /// The streaming-diarizer slot, 1-based, when the tier is `.provisional`
    /// or `.named`. The interface prints "Speaker \(slotNumber)" in its own
    /// language rather than trusting a model-supplied English string.
    public let slotNumber: Int?
    public let profileID: UUID?
    /// A profile's name. Nil at every tier below `.named`.
    public let displayName: String?
    /// When this reference last moved up a tier, and what it used to read.
    /// Both are nil until the first promotion. They are the whole state the
    /// interface needs to draw the relabel cue: the cue is *derived* from a
    /// time window against `promotedAt`, never stored as a one-shot flag,
    /// because SwiftUI cannot deliver "true for exactly one render pass".
    public let promotedAt: Date?
    public let previousDisplayName: String?

    public init(
        key: String,
        tier: LiveSpeakerTier,
        isCurrentUser: Bool = false,
        slotNumber: Int? = nil,
        profileID: UUID? = nil,
        displayName: String? = nil,
        promotedAt: Date? = nil,
        previousDisplayName: String? = nil
    ) {
        self.key = key
        self.tier = tier
        self.isCurrentUser = isCurrentUser
        self.slotNumber = slotNumber
        self.profileID = profileID
        self.displayName = displayName
        self.promotedAt = promotedAt
        self.previousDisplayName = previousDisplayName
    }

    /// The person recording. Their channel is known from the first sample, so
    /// this reference never changes during a capture.
    public static let currentUser = LiveSpeakerRef(
        key: "channel.microphone",
        tier: .channel,
        isCurrentUser: true
    )

    /// Everything arriving on the system-audio channel before any model has
    /// separated it. One reference covers every remote voice.
    public static let systemChannel = LiveSpeakerRef(
        key: "channel.systemAudio",
        tier: .channel
    )

    public static func channel(for source: CaptureSourceKind) -> LiveSpeakerRef {
        switch source {
        case .microphone: .currentUser
        case .systemAudio: .systemChannel
        }
    }
}

/// Why one span of live text ended.
public enum LiveTurnBoundaryReason: String, Codable, Sendable, Equatable {
    /// The other capture channel took the engine.
    case channelChange
    /// The non-owning channel spoke for long enough that the loss is worth
    /// showing. Closes the open span so the marker sits where the speech was.
    case crossTalkDropped
    /// The streaming diarizer reported a different speaker on the same channel.
    case speakerChange
    /// The engine reported a finished utterance.
    case endOfUtterance
    /// Nobody spoke for long enough to end a paragraph.
    case idlePause
    /// The capture stopped.
    case sessionEnd
}

/// What one entry in the live transcript is.
public enum LiveSpanKind: String, Codable, Sendable, Equatable {
    /// Words the live engine decoded.
    case text
    /// Speech the live engine never heard, because the other channel owned the
    /// engine. It carries no text. The durable spool has the audio and the
    /// finished note has the words, and the reader is told so rather than
    /// shown a transcript that reads as continuous.
    case droppedSpeech
}

/// One settled paragraph of live text with the speaker it belongs to, or one
/// marker for speech the live engine missed.
///
/// The live counterpart of `TranscriptSegmentSnapshot`. Times are capture time:
/// seconds since the capture's first audio buffer.
public struct LiveTranscriptSpan: Sendable, Equatable, Identifiable {
    /// Ordinal within the capture. Stable across relabels.
    public let id: Int
    public let kind: LiveSpanKind
    public let speaker: LiveSpeakerRef
    /// Always empty when `kind` is `.droppedSpeech`.
    public let text: String
    public let startOffset: TimeInterval
    public let duration: TimeInterval
    public let boundaryReason: LiveTurnBoundaryReason

    public var isText: Bool { kind == .text }

    public init(
        id: Int,
        kind: LiveSpanKind = .text,
        speaker: LiveSpeakerRef,
        text: String,
        startOffset: TimeInterval,
        duration: TimeInterval,
        boundaryReason: LiveTurnBoundaryReason
    ) {
        self.id = id
        self.kind = kind
        self.speaker = speaker
        self.text = text
        self.startOffset = startOffset
        self.duration = duration
        self.boundaryReason = boundaryReason
    }
}

/// The tail the engine may still rewrite, with the speaker it is being
/// attributed to right now. Drawn in the quiet ink.
public struct LiveTentativeSpan: Sendable, Equatable {
    public let speaker: LiveSpeakerRef
    public let text: String

    public init(speaker: LiveSpeakerRef, text: String) {
        self.speaker = speaker
        self.text = text
    }
}
```

**Changed** `Packages/PindropShared/Sources/PindropSpeech/StreamingRefinementCoordinator.swift`:

```swift
@MainActor
public protocol StreamingRefinementCommitObserver: AnyObject {
    /// `committedText` stays the append-only cumulative string the durable
    /// checkpoint holds. `spans` is that same text cut into paragraphs with the
    /// speaker each one was attributed to, plus any dropped-speech markers.
    ///
    /// The text spans are *derived*: they are `committedText` split on "\n",
    /// with speaker and timing metadata attached per index. They cannot drift
    /// from the checkpoint string, because they are not stored separately.
    /// The exact invariant, including the trailing boundary the artifact path
    /// appends, is:
    ///
    ///     committedText == spans.filter(\.isText).map(\.text)
    ///                           .joined(separator: "\n")
    ///                      + (isParagraphOpen ? "" : "\n")
    ///
    /// `spans` is empty for a session begun with
    /// `preservesArtifactParagraphs: false`, which is every dictation session.
    /// Dictation has one speaker and no paragraph structure to carry.
    func streamingRefinementCoordinator(
        _ coordinator: StreamingRefinementCoordinator,
        didCommitText committedText: String,
        spans: [LiveTranscriptSpan]
    )
}
```

New public surface on `StreamingRefinementCoordinator`:

```swift
/// Closes the current paragraph at the point already committed, and points
/// everything that follows at `speaker`. Safe to call when nothing is
/// pending: it still records the boundary so the next commit opens a new
/// span.
///
/// Phase 1 calls this only at a boundary the engine itself produced (an
/// end-of-utterance final or an idle commit), so "everything committed
/// belongs to the outgoing speaker" is exact by ordering. There is no
/// timestamp argument and no clock, because at that instant none is needed.
public func markBoundary(
    _ reason: LiveTurnBoundaryReason,
    speaker: LiveSpeakerRef
) async

/// Records speech the live engine never heard. Emits a `.droppedSpeech` span
/// attributed to `speaker`, carrying no text, between the surrounding
/// paragraphs. Does not touch `committedText`.
public func markDroppedSpeech(
    speaker: LiveSpeakerRef,
    startOffset: TimeInterval,
    duration: TimeInterval
) async

/// Re-points every span whose speaker key is `key` at `replacement`.
/// Text is never changed, only the label. Used by Phase 2 promotion.
///
/// Precondition: `key` is a slot key. Channel-tier keys are rejected, because
/// one channel key can cover several people (see section 4.5).
public func relabelSpeaker(slotKey key: String, to replacement: LiveSpeakerRef) async
```

Private state added:

```swift
private var spanMetadata: [SpanMetadata] = []   // one per committed paragraph
private var droppedMarkers: [LiveTranscriptSpan] = []
private var currentSpeaker: LiveSpeakerRef = .currentUser
private var currentSpanStartCaptureTime: TimeInterval = 0
private var pendingSpeaker: LiveSpeakerRef?
private var nextSpanID = 0
```

`spans` is not stored. It is computed by splitting `committedText` on `"\n"`, zipping the pieces with `spanMetadata`, and merging `droppedMarkers` in by `startOffset`. That is what makes the invariant above true by construction instead of by discipline.

**Phase 2 adds one thing to this file, and only one.** The diarizer's speaker changes arrive about a second after the audio that caused them, so they do need a retroactive split of an already-open span. Phase 2 therefore adds:

```swift
/// Raw-offset watermarks: where in the raw stream each capture time fell.
/// Appended inside `commitRawUpTo`, from the fed watermark the engine
/// reports on its own emissions (never a clock read at arrival time).
private var stamps: [(rawOffset: Int, captureTime: TimeInterval)] = []

/// Phase 2 overload. Binary-searches `stamps` for the last entry whose
/// `captureTime <= captureTime`, and splits the *open* span at that raw
/// offset. If `captureTime` precedes the open span's start, it clamps to the
/// start and logs. Already-closed spans are never re-split.
public func markBoundary(
    _ reason: LiveTurnBoundaryReason,
    speaker: LiveSpeakerRef,
    atCaptureTime captureTime: TimeInterval
) async
```

`beginSession` keeps the working-tree `preservesArtifactParagraphs` parameter and gains `initialSpeaker: LiveSpeakerRef = .currentUser`. Span tracking is gated on `preservesArtifactParagraphs`, so the dictation path allocates nothing new.

**Changed** `Pindrop/Models/NoteCaptureState.swift`. Delete the two live strings (lines 56 and 59), replace with spans:

```swift
/// The paragraphs the engine has settled on, in order, each pointed at the
/// speaker it was attributed to. Empty while a capture has produced no words.
private(set) var liveSpans: [LiveTranscriptSpan] = []
/// The tail the engine may still rewrite. The live sheet draws it in the
/// quiet ink so nobody reads an unsettled guess as a finished sentence.
private(set) var liveTentative: LiveTentativeSpan?

/// Everything settled so far as one string, one paragraph per line. This is
/// the checkpoint-contract view and the test view. It carries no names,
/// because it has to stay equal to what the durable checkpoint holds.
var liveTranscriptText: String {
    liveSpans.filter(\.isText).map(\.text).joined(separator: "\n")
}

/// The reader's view: one block per turn, headed by the speaker name, with
/// dropped-speech markers spelled out. This is what Copy puts on the
/// pasteboard and what the sheet exposes as its accessibility value.
/// `liveTranscriptText` is deliberately not used for either.
var liveTranscriptForCopy: String { get }

func updateLiveSpans(_ spans: [LiveTranscriptSpan])
func updateLiveTentative(_ tentative: LiveTentativeSpan?)
```

`updateLiveTranscript(_:)` (line 136) and `updateLiveTentativeTranscript(_:)` (line 143) are deleted, along with their four reset sites (lines 105 to 106, 158, 197 to 198). `isLiveTranscriptDegraded` and `markLiveTranscriptDegraded()` are unchanged.

**No clock, and no `LiveAudioClock`.** An earlier draft of this design built a splice-map inverter with tap-skew calibration and its own four-test suite. It is deleted, for two reasons.

- Phase 1 does not need it. Handovers happen only at engine-produced commit boundaries, so attribution is exact by commit ordering.
- It could not have worked anyway. It read `fedTimeNow` on the main actor when a partial arrived, but `TranscriptionService` coalesces partials to the latest value before delivery (`TranscriptionService.swift:298` to `:300`, delivery at `:1107` and `:2634`). The stamp would have been arbitrarily late, by more than the intervals it was trying to resolve, and one surviving partial can carry text from both sides of a handover under a single stamp.

Phase 2 does need a capture time for diarizer boundaries, and it gets one **as data, not as a clock read**:

- `NemotronStreamingEngine.processAudioBuffer` (`Transcription/NemotronStreamingEngine.swift:249`) counts fed samples inside the engine actor, and `StreamingTranscriptionResult` carries `fedSeconds` beside the `timestamp` field it already has at `:274` to `:278`. `setStreamingCallbacks(onPartial:)` widens from `(String)` to a payload type. Coalescing then loses intermediates, but the survivor still carries the watermark of the audio that produced it, so attribution error is bounded by one partial interval.
- The consumer keeps the **current ownership run** as three scalars, `(source, fedStart, captureStart)`. Inside one run fed seconds advance one for one with that channel's capture seconds, so `captureTime = captureStart + (fedSeconds - fedStart)`. No splice map, no tap-skew calibration, no inversion across history. Only the open run is ever needed, because a diarizer boundary can only split the open span.

This API widening is Phase 2 work and is budgeted in the Phase 2 commit list. Phase 1 does not touch `TranscriptionService`.

**Changed** `Pindrop/Services/AudioRecorder.swift`. The AsyncStream element becomes a packet, so the consumer can see handovers:

```swift
/// What the live pump carries. A handover and a dropped-speech interval are
/// events, not audio: the consumer acts on them without decoding anything.
enum LiveAudioPacket: @unchecked Sendable {
    case buffer(AVAudioPCMBuffer, source: CaptureSourceKind, captureTime: TimeInterval)
    /// The arbiter decided on a handover. The consumer holds it pending and
    /// applies it at the next engine-produced boundary, or force-flushes at
    /// `handoverCeilingSeconds`.
    case handoverPending(to: CaptureSourceKind, atCaptureTime: TimeInterval)
    /// The non-owner spoke for longer than `droppedSpeechSeconds`.
    case droppedSpeech(source: CaptureSourceKind, startCaptureTime: TimeInterval, duration: TimeInterval)
}

nonisolated(unsafe) var onLivePacket: ((LiveAudioPacket) -> Void)?
nonisolated(unsafe) var onDiarizationBuffer: ((AVAudioPCMBuffer, TimeInterval) -> Void)?
```

`onAudioBuffer` (`AudioRecorder.swift:3821`, raised at `:3933` and `:4041`) is deleted and its four `StreamingSessionController` call sites (`:980`, `:1012`, `:1020`, `:1033`) move to `onLivePacket`. Six test call sites move with them. `forwardLiveBuffer`'s source-exclusion rule is deleted and replaced by `LiveChannelArbiter.admit(source:buffer:)`, which returns `.forward`, `.drop`, or `.handoverPending(to:)`.

`onDiarizationBuffer` is declared in Phase 1 and left unused until Phase 2. It exists here because the diarizer must have its **own** sink from the start (section 4.2), and adding it later would mean reworking the packet type.

### 3.4 Streaming plumbing, end to end

```
mic tap (CoreAudio IO proc)  ─┐
                              ├─ converted to 16 kHz mono Float32 (existing ReusableAudioConverter)
system tap (CoreAudio IO proc)┘
                              │
        LiveSpeakerGate (per channel) + echo correlation
        LiveChannelArbiter.admit()   [capture thread, vDSP, arbiter's own lock, NEVER stateLock]
                              │
       ┌──────────────────────┴───────────────────────┐
       │                                              │
AsyncStream<LiveAudioPacket>                AsyncStream<(buffer, captureTime)>
 [bufferingNewest(32)]                       [system audio only, Phase 2,
       │                                      bufferingNewest(16)]
Task.detached(.userInitiated) #1             Task.detached(.utility) #2
       │                                              │
engine.processAudioBuffer(...)               diarizer.ingest(...)
   [engine actor]                             [LiveDiarizationEngine, own serial executor]
       │
on .handoverPending: hold it. Apply at the next ingestFinal or idle
commit. At handoverCeilingSeconds, feed chunkSamples - (fedSamples %
chunkSamples) of zeros to force one decode, then apply.
       │
Applying a handover, or a droppedSpeech packet, is ONE hop to the main
actor for coordinator.markBoundary(...) / markDroppedSpeech(...)
```

**Two streams, two consumers, on purpose.** `attachAudioForwarding` today is a single serial `for await` doing `try await engine.processAudioBuffer(buffer)` (`Pindrop/Services/StreamingSessionController.swift:992` to `:1017`). `SortformerDiarizer.process()` is a **synchronous** blocking CoreML call under the diarizer's own lock (`DerivedData/SourcePackages/checkouts/FluidAudio/Sources/FluidAudio/Diarizer/Sortformer/SortformerDiarizer.swift:386`). Awaiting it in the same loop head-of-line blocks the next ASR buffer by a full inference time, twice a second, which is the same class of regression commit 312f23a fixed. Worse, the ASR stream's `.bufferingNewest(32)` then drops the oldest buffers, so real speech disappears from the live transcript.

The diarizer must be **structurally incapable** of delaying the ASR feed. Separate streams, separate detached tasks, separate buffering policies, different priorities. Section 4.8's "stop feeding the diarizer" is then a policy with an actual mechanism behind it.

The per-buffer path still never touches the main actor. The only main-actor hops the arbiter introduces are one per applied handover and one per dropped-speech marker, a few per minute, not tens per second. This satisfies the standing rule from commit 312f23a and from the Nemotron warm-up memory.

#### The stop sequence, in order

`flushPendingAudioWork()` (`StreamingSessionController.swift:1019` to `:1027`) grows an explicit ordering. Get this wrong and two offline diarizer model instances are resident and contending for the Neural Engine at exactly the finalize moment, alongside Nemotron's offline retranscription pass.

1. `audioRecorder.onLivePacket = nil` and `onDiarizationBuffer = nil`. No new buffers can be enqueued.
2. Finish the diarizer continuation and `await` its consumer task.
3. `await LiveDiarizationEngine.finish()`, then drain its last segments and apply any final `.speakerChange`.
4. Finish the ASR continuation and `await` its consumer task.
5. `await coordinator.markBoundary(.sessionEnd, speaker: currentSpeaker)`.
6. `await LiveSpeakerEmbedder.unload()`, releasing its `OfflineDiarizerManager`. **This is a stated precondition of the offline pass**, not a best effort.
7. `await LiveDiarizationEngine.unload()`, releasing the Sortformer bundle.
8. `pumpEngine = nil`, then finalize begins.

`stopArtifactLiveTranscription` (`:976` to `:986`), which fires at the two-hour bound, runs steps 1 through 7 and leaves the durable spool running. The 45 s ring is released with the engine at step 7.

### 3.5 Turn assembly rules

A **span** (paragraph) ends when any of these happen:

| Trigger | Reason | Source |
|---|---|---|
| A pending handover is applied at an engine boundary | `.channelChange` | arbiter, applied by the consumer |
| The engine reports a finished utterance | `.endOfUtterance` | `ingestFinal` (this is what the working-tree diff already does) |
| No new raw characters for `idleCommitNanoseconds` | `.idlePause` | existing idle commit timer |
| The non-owner spoke for `droppedSpeechSeconds` | `.crossTalkDropped` | arbiter |
| The capture stops | `.sessionEnd` | `finishArtifactCapture` |
| (Phase 2) the diarizer reports a different slot while the system channel owns the engine | `.speakerChange` | `LiveDiarizationEngine` |

A **turn** ends when the speaker key changes. `.endOfUtterance` and `.idlePause` therefore make a new paragraph inside the same turn, which is exactly what the existing `TranscriptTurn.turns(in:)` grouping (`TranscriptSegmentList.swift:55`) already does for finished transcripts.

One extra rule for readability, matching the finished transcript: inside one turn, a gap of 2.0 s or more between the end of one span and the start of the next is drawn with paragraph spacing rather than run together. This falls out of `.idlePause` and needs no separate mechanism.

**Attribution of live text is by commit ordering, not by timestamp.** A handover is applied at the exact instant the engine flushed and committed a chunk, so every character committed before it belongs to the outgoing speaker and every character after it belongs to the incoming one. Nothing is estimated. The residual error is the sub-chunk tail described in section 3.2, and the design states that bound rather than pretending to correct it.

Phase 2 is the only place a boundary can arrive late, because a diarizer speaker change is reported about a second after the audio. That case, and only that case, uses the `stamps` array and the retroactive split described in section 3.3.

**Dropped speech is shown, not hidden.** Rule 5 of the arbiter deliberately loses the non-owner's live text during cross talk. A transcript that reads as continuous while a chunk of one side of the conversation is missing is the failure that matters most for a reader who cannot hear the call: they speak, someone answers over them, and the answer never appears with nothing on screen to say so.

When the arbiter reports a dropped-speech interval, the coordinator closes the open paragraph with `.crossTalkDropped` and inserts a `.droppedSpeech` span attributed to the channel that was talking. The interface draws it as one quiet line in `AppColors.textTertiary`, with no text bubble and no speaker dot:

- system-audio channel: `Someone else spoke here. The finished note has it.`
- microphone channel: `You spoke here. The finished note has it.`

Consecutive dropped intervals for the same channel with less than 2.0 s between them coalesce into one marker, so a long overlap does not produce a wall of markers.

### 3.6 UI specification

Reuse, do not rebuild. The finished-transcript turn stack already exists and already looks right.

**Reused as is:**

| Component or token | File | Role in the live view |
|---|---|---|
| `TranscriptSegmentBubble.bodyMetrics` (Newsreader 15/22) | `TranscriptSegmentList.swift:584` | live body text, unchanged face and rhythm |
| `TranscriptSegmentPresentation.speakerName(isCurrentUser:speakerNumber:speakerLabel:locale:)` | `TranscriptSegmentList.swift:344` | one localized naming rule for live and finished text |
| `LibrarySpeakerColor.color(for:)` plus the `isCurrentUser ? AppColors.accent` rule | `TranscriptSegmentList.swift:633` | the speaker dot |
| `AppColors.textPrimary` / `.textSecondary` / `.textTertiary` | `AppTheme` | current line, settled lines, tentative tail and dropped-speech markers |
| `AppTypography.overline`, `AppTypography.labelSemibold`, `AppTypography.caption` | `AppTheme` | the "Live transcript" label, the turn header, the turn start time |
| `ScrollViewReader`, the "Jump to live" pill, the drag handle | `LiveTranscriptSheet.swift` | unchanged |

**On the speaker dot colour.** `LibrarySpeakerColor` hashes a canonical key derived from the offline `speakerId` or label (`Pindrop/UI/Main/LibraryPresentation.swift:280` to `:291`). Hashing `"channel.systemAudio"` or a slot key gives a different hue than the finished transcript gives the same person, so the live view **does not claim** to match the finished colour below the `.named` tier. It uses the same colour *function* for visual consistency, and once a slot reaches `.named` it keys on `profileID`, at which point the hue does match. The hue change rides the relabel affix described below.

**Both live surfaces change together.** There are two, not one: `LiveTranscriptSheet` (`:116`) and `LiveTranscriptLines` on the note page transcript tab (`Pindrop/UI/Main/NotePageView.swift:2009`, rendered at `:1098`). Both call `TranscriptSegmentPresentation.liveLines`. Phase 1 routes **both** through `liveTurns` in the same commit. Leaving one behind means the sheet shows attributed turns while the transcript tab shows unattributed lines for a whole phase.

**Changed:** `TranscriptSegmentPresentation.liveLines(committed:tentative:)` becomes the per-turn line builder, and a new entry point groups the spans:

```swift
/// One speaker's run of live text, ready to draw.
struct TranscriptLiveTurn: Identifiable, Equatable, Sendable {
    let id: Int
    let speaker: LiveSpeakerRef
    let lines: [TranscriptLiveLine]
    /// The newest turn. Its lines read in the primary ink.
    let isCurrent: Bool
    /// Capture-time start of this turn. Nil for the newest turn, whose end is
    /// still moving.
    let startOffset: TimeInterval?
    /// Set once this turn's speaker has been promoted, and kept for the rest
    /// of the capture. Derived from `speaker.promotedAt` and
    /// `speaker.previousDisplayName`, never stored as a one-shot flag.
    let promotion: TranscriptLivePromotion?
}

/// What a promoted header shows.
struct TranscriptLivePromotion: Equatable, Sendable {
    /// For example "Speaker 2". Drawn as a quiet affix beside the new name.
    let previousDisplayName: String
    /// True while the promotion is inside the emphasis window. The caller
    /// passes `now`, so this is a pure function and a test can drive it.
    let isRecent: Bool
}

/// One line of live text, or one marker for speech the live engine missed.
enum TranscriptLiveEntry: Identifiable, Equatable, Sendable {
    case turn(TranscriptLiveTurn)
    case droppedSpeech(id: Int, source: CaptureSourceKind, startOffset: TimeInterval)
}

static func liveEntries(
    spans: [LiveTranscriptSpan],
    tentative: LiveTentativeSpan?,
    now: Date
) -> [TranscriptLiveEntry]
```

`liveLines(committed:tentative:)` keeps its current signature and behaviour and is called once per turn. `boundedLiveLines` stays private inside `liveLines` and is untouched.

Note that `TranscriptSegmentPresentation.sentences(in:)` already splits on newlines (`TranscriptSegmentList.swift:534` to `:537`), so calling `liveLines` per turn re-splits the turn's text on the paragraph newlines the coordinator inserted. That is the wanted behaviour, but it means one span is not one `TranscriptLiveLine`. The grouping test asserts the resulting line count, not only the grouping.

**Layout of one live turn** (matching `TranscriptSegmentBubble` metrics so the live sheet and the finished transcript read as one surface):

- Header row: 6 pt speaker dot, `AppColors.accent` when `speaker.isCurrentUser` and `LibrarySpeakerColor.color(for:)` otherwise, then the display name in `AppTypography.labelSemibold`.
- Header trailing: the turn's start time in `AppTypography.caption` and `AppColors.textTertiary`, on **every turn above the current one**. Their start offsets are settled and they are what a reader scrolling back needs in order to anchor what they are reading. The newest turn shows no time, because its end is still moving and a number that keeps changing is worse than none.
- Body: the turn's `TranscriptLiveLine` values, one per line, at `bodyMetrics`. Settled text in `AppColors.textPrimary` for the current turn and `AppColors.textSecondary` above it. The tentative tail in `AppColors.textTertiary`, unchanged.
- Dropped-speech marker: one caption line in `AppColors.textTertiary`, no dot, no bubble, full width, with 12 pt above and below.
- 12 pt of vertical space between turns, matching `TranscriptSegmentBubble` line 613.
- Collapsed sheet row: the newest turn's name, a middle dot, and the newest line, truncated to one line, in `AppColors.textSecondary`.

**Promotion is visible and it stays visible.** When a slot is promoted to a name, the header reads the new name followed by a quiet affix in `AppTypography.caption` and `AppColors.textTertiary`: `was Speaker 2`. The affix stays for the rest of the capture. For the first 1.2 s (`promotion.isRecent`) the name crossfades and a 2 pt `AppColors.accent` underline draws and fades beneath it.

The sheet already honours `accessibilityReduceMotion` (`LiveTranscriptSheet.swift:355` to `:366`). Under reduce motion the affix appears with no animation and no underline draw. The affix, not the animation, is what carries the information, which is why it is not a 1.2 s cue alone: the sheet is collapsed by default, the reader may have scrolled up, and the reader is usually looking at the call window.

**Accessibility of the live turn stack.** Today the live lines are bare `Text` views with an identifier and no label (`LiveTranscriptSheet.swift:373` to `:395`). Announcing a promoted name into a view VoiceOver has never described is noise, so Phase 1 gives the stack a model:

- Each turn is one accessibility element, `.accessibilityElement(children: .combine)`, with a label of the form `Dana said: <turn text>`. The tentative tail is named as such inside the label.
- A dropped-speech marker is its own element and reads its own line.
- New turns are **not** announced. A caption stream announced continuously is unusable.
- One announcement is posted, on promotion only: `Speaker 2 is now Dana.` It is a real sentence, not a bare name.
- The sheet's accessibility value is `liveTranscriptForCopy`, so VoiceOver reads names, not the checkpoint string.

### 3.7 What happens to the uncommitted work in progress

**Decision: land it first, then build on it. Do not supersede it.**

The working tree holds three things, verified against the diff:

1. `preservesArtifactParagraphs` on `StreamingRefinementCoordinator.beginSession`, default `false`, switched on only by `StreamingSessionController` for artifact (note-recording) sessions at line 317. It appends a `"\n"` boundary at every end-of-utterance final and every idle commit, teaches `startOfUtterance` and the tentative builder to treat a trailing newline as a sentence start, and strips the leading whitespace of a chunk that opens a new paragraph. Four new tests: `artifactFinalUtterancesBecomeParagraphsWithoutChangingFinalOutput`, `artifactFinalAddsABoundaryAfterAgreementAlreadyCommittedTheSentence`, `artifactIdleAddsABoundaryAfterAgreementAlreadyCommittedTheSentence`, `observerDoesNotAddParagraphsToAnOutputSession`.
2. `boundedLiveLines` inside `TranscriptSegmentPresentation.liveLines`, which splits any stretch over 24 words into 24-word lines and keeps long tentative text tentative across every one of them. Two new tests: `longTentativeTextIsBoundedWhileRemainingTentative`, `longUnpunctuatedTextIsBoundedIntoReadableLiveLines`.
3. A session guard on `NoteCaptureState.clearEnhancementFailure(for:)` plus its `NotePageView.swift:1709` call site. It extends the existing `stateKeepsAPanelFailureWithoutFailingTheCapture` test rather than adding a new one.

All three are correct and all three are prerequisites, not obstacles:

- The `"\n"` boundary is exactly the paragraph structure Phase 1 needs, and it is the only structure the append-only durable checkpoint can carry. Phase 1's text spans are the derived, labelled view of the same boundaries.
- `boundedLiveLines` is reused unchanged inside each turn.
- The session guard is orthogonal and belongs with Phase 4's flow work, but it is already written and already tested.

**The invariant, stated correctly.** `appendArtifactParagraphBoundaryIfNeeded` does `committedText.append("\n")`, so after any boundary the committed string ends with a newline that a plain join does not reproduce. The naive form `spans.map(\.text).joined(separator: "\n") == committedText` is false on day one. The invariant this design actually leans on is:

```
committedText == spans.filter(\.isText).map(\.text).joined(separator: "\n")
                 + (isParagraphOpen ? "" : "\n")
```

Because the text spans are derived by splitting `committedText` (section 3.3), this cannot drift. The test is named for the trailing boundary so the intent cannot be lost: `spansRebuildTheCommittedTextIncludingItsTrailingBoundary`.

Commit order at the head of Phase 1, split so one commit carries one intent:

- `P1.0a` `fix(notes): keep artifact paragraphs and bound long live lines` (the paragraph-boundary work plus `boundedLiveLines`, tests as written).
- `P1.0b` `fix(notes): guard enhancement failure clearing by session` (the `clearEnhancementFailure(for:)` guard and its `NotePageView.swift:1709` call site).

Then Phase 1 proceeds on top. Nothing in the diff is rewritten. The only later change to that code is that the `commitObserver` callback grows a `spans:` argument in `P1.4`, and the working tree's four coordinator tests are updated in the same commit to assert both the string and the spans.

### 3.7a The dictation path is unchanged, and that is tested

`StreamingSessionController`, `StreamingRefinementCoordinator`, and `AudioRecorder.onAudioBuffer` are also the shipped **dictation** pipeline (`liveTranscriptState`, `OverlayStreamingSink`, `AppCoordinator.swift:989` to `:1018`). Phase 1 deletes `onAudioBuffer`, changes the commit-observer signature, and adds an arbiter to the buffer path. None of that may change a single character the dictation overlay draws.

The guarantees, and how each is made provable:

- **Span tracking is off.** It is gated on `preservesArtifactParagraphs`, which `StreamingSessionController` sets only for artifact sessions (`:317`). A dictation session allocates no spans and emits no paragraph boundaries.
- **The arbiter is a no-op.** Rule 1: a single-source capture gives that source ownership for the whole session, with no gate, no echo check, no correlation, and no packets other than `.buffer`. Dictation is always microphone only.
- **There is no clock to be a no-op.** It was deleted.
- **The meter path is unchanged for one source.** Per-source analyzer instances with one source behave exactly as the single shared instance did.

Tests:

| Test | File | Proves |
|---|---|---|
| `anOutputSessionProducesNoSpans` | `StreamingRefinementCoordinatorTests` | the dictation path allocates nothing new |
| `anOutputSessionEmitsNoBoundariesBeyondTheEngineOwnPauses` | `StreamingRefinementCoordinatorTests` | no `.channelChange` and no `.crossTalkDropped` in dictation |
| `dictationCommittedAndTentativeTextIsByteIdenticalAcrossTheRefactor` | `StreamingRefinementCoordinatorTests` | the overlay's split does not move |
| `aSingleSourceCaptureNeverConsultsTheSpeakerGate` | `LiveChannelArbiterTests` | dictation pays nothing for arbitration |

### 3.8 Persistence in Phase 1

**None.** No new `@Model`, no new field, no change to what `checkpointVoiceNoteLiveTranscript` stores.

The durable checkpoint keeps holding the plain append-only committed text with `"\n"` paragraph boundaries. Live labels stay in memory for the life of the capture. The reasoning:

- Live labels are provisional. Finalize runs the offline diarization pass and rewrites every label from the durable audio, so a persisted live label would be overwritten within seconds of the capture ending.
- After a crash, recovery runs the same finalize path, so nothing is lost by not persisting them.
- The checkpoint's prefix-monotonic contract (`committedText.hasPrefix(latest.committedText)`, `Packages/PindropShared/Sources/PindropData/Services/CaptureSessionStore.swift:2365`) is preserved untouched. Relabelling a span changes no characters, and a dropped-speech marker adds none, so neither can break the contract.

This keeps Phase 1 entirely free of schema risk.

### 3.9 Phase 1 test list

`Packages/PindropShared/Tests/PindropSpeechTests/StreamingRefinementCoordinatorTests.swift`

| Test | Proves |
|---|---|
| `spansRebuildTheCommittedTextIncludingItsTrailingBoundary` | the derived spans and the checkpoint string never disagree, trailing newline included |
| `aChannelChangeStartsANewSpanAndANewTurn` | `markBoundary(.channelChange,...)` closes the paragraph and repoints the speaker |
| `aChannelChangeWithNothingPendingStillOpensANewSpan` | a handover during silence does not merge two speakers into one span |
| `everythingCommittedBeforeAHandoverStaysWithTheOutgoingSpeaker` | attribution by commit ordering, the whole Phase 1 mechanism |
| `endOfUtteranceMakesAParagraphNotATurn` | `.endOfUtterance` does not split a speaker's turn |
| `idlePauseMakesAParagraphNotATurn` | same for the idle timer |
| `aDroppedSpeechMarkerAddsNoCharactersToTheCommittedText` | markers cannot break the checkpoint contract |
| `relabelSpeakerChangesLabelsAndNeverText` | promotion is label-only, so the checkpoint contract holds |
| `relabelSpeakerRejectsAChannelKey` | the precondition from section 4.5 is enforced at the type's edge |
| `aSessionWithOneChannelProducesOneTurn` | mic-only capture is not paying for arbitration |
| `anOutputSessionProducesNoSpans` | the dictation path is untouched by span tracking |
| `anOutputSessionEmitsNoBoundariesBeyondTheEngineOwnPauses` | dictation sees no channel or cross-talk boundaries |
| `dictationCommittedAndTentativeTextIsByteIdenticalAcrossTheRefactor` | the overlay's split does not move |

`PindropTests/LiveChannelArbiterTests.swift` (new)

| Test | Proves |
|---|---|
| `theFirstChannelWithSpeechTakesTheEngine` | cold start, against the adaptive gate |
| `bothChannelsSpeakingAtOnceGivesTheEngineToSystemAudio` | the documented tie-break |
| `theOwnerKeepsTheEngineThroughCrossTalk` | no flapping mid-sentence |
| `aChallengerWaitsForTheOwnerToGoQuiet` | `releaseWindow` is enforced |
| `aShortNoiseBurstNeverTakesTheEngine` | `claimWindow` is enforced |
| `continuousRoomToneDoesNotLatchTheEngineToSystemAudio` | the adaptive floor, and the regression a fixed floor would have shipped |
| `theMicrophoneDoesNotTakeTheEngineWhenItIsHearingTheSpeakers` | the echo gate: remote words are never headed `You` |
| `noHandoverHappensInsideOneAsrChunk` | `minimumOwnershipSeconds` is derived from the active profile |
| `aPendingHandoverWaitsForAnEngineBoundary` | handovers are not spliced mid-chunk |
| `aPendingHandoverForceFlushesAtTheCeiling` | the silence fed is exactly the remainder of the open chunk |
| `aHandoverEmitsExactlyOneChannelChangeApplication` | the consumer cannot double-flush or double-commit |
| `aDroppedChannelProducesAVisibleGapMarker` | cross-talk loss is reported, not silent |
| `adjacentDroppedIntervalsCoalesceIntoOneMarker` | a long overlap does not produce a wall of markers |
| `aMicrophoneOnlyCaptureNeverEmitsAHandover` | single-source captures are untouched |
| `aSingleSourceCaptureNeverConsultsTheSpeakerGate` | dictation pays nothing for arbitration |
| `bothChannelsMeterWithoutSharingFilterState` | per-source analyzers, no realtime data race |

`PindropTests/TranscriptSegmentPresentationTests.swift` (extended)

| Test | Proves |
|---|---|
| `liveTurnsGroupConsecutiveSpansOfOneSpeakerAndCountTheirLines` | turn grouping matches the finished transcript's rule, and one span can yield several lines because `sentences(in:)` splits on newlines |
| `liveTurnsPutTheTentativeTailOnTheNewestTurn` | the quiet ink lands in the right place |
| `liveTurnsBoundLongUnpunctuatedTextInsideATurn` | `boundedLiveLines` survives the turn refactor |
| `liveEntriesDrawADroppedSpeechMarkerBetweenTurns` | the gap marker renders where the speech was |
| `everyTurnAboveTheCurrentOneCarriesAStartTime` | the newest turn alone has no timestamp |
| `aCaptureThatHasHeardNothingHasNoTurns` | empty state |

`PindropTests/NoteCaptureControllerTests.swift` (extended)

| Test | Proves |
|---|---|
| `aMeetingCaptureShowsBothChannelsInTheLiveTranscript` | the regression this phase exists to fix: mic text appears when system audio is on |
| `liveTranscriptTextJoinsSpansWithNewlines` | the checkpoint-contract view |
| `liveTranscriptForCopyCarriesSpeakerNamesAndGapMarkers` | the copy and accessibility path is not the checkpoint string |

### 3.10 Phase 1 localization

Add to `Localization/app/en.yml` and to all 30 other locale files, then `just l10n-sync`. Key paths are derived from the English text by `scripts/localization.py`; do not hand-write them.

| English | Where | Note |
|---|---|---|
| `You` | live turn header, microphone channel | already exists (`TranscriptSegmentPresentation.speakerName`), reused |
| `Call audio` | live turn header, system-audio channel before any model runs | new. It names the channel, not the people |
| `Speaker %d` | live turn header, Phase 2 slots | already exists, reused |
| `Live transcript` | sheet overline | already exists |
| `Someone else spoke here. The finished note has it.` | dropped-speech marker, system-audio channel | new |
| `You spoke here. The finished note has it.` | dropped-speech marker, microphone channel | new |
| `%1$@ said: %2$@` | VoiceOver label for one live turn | new |
| `Pindrop is transcribing only your microphone. The call audio is in the finished note.` | degraded notice, shown when system audio is present but the arbiter has never handed it the engine | new |

**On `Call audio`, not `Them`.** An earlier draft paired second-person `You` with the object pronoun `Them`. In English it reads as plural over a single remote voice ("Them: I think we ship Friday"). In translation a bare third-person plural pronoun forces gender and number choices the app has not earned (Spanish *ellos* and *ellas*, French *ils* and *elles*, and so on). The objection this design raised against `Others`, that it implies a group we have not counted, applies to `Them` word for word. `Call audio` claims no count and no gender, translates cleanly, and pairs with `You` without a grammatical mismatch. Phase 2 replaces it with `Speaker %d` anyway.

**On the degraded notice.** `LiveTranscriptSheet.degradedNotice` (`:318` to `:327`) draws its text with `.lineLimit(1)` inside a 36 pt collapsed row. The shipped string (`Live text stopped. The recording continues.`) fits; the new one does not. Phase 1 changes that view to `.lineLimit(2)` with `.fixedSize(horizontal: false, vertical: true)` and keeps the copy in active voice and under two caption lines. Every new chip in Phase 2 is checked against the same constraint before its copy is written.

---

## 4. Phase 2: streaming diarization and identity

### 4.1 Shape of the phase

Phase 2 replaces the single `Call audio` label with per-speaker labels on the system-audio channel, and promotes those labels to real names when a participant profile matches. The microphone channel is untouched: it is already `You` at the highest possible confidence, and it costs nothing.

Sortformer's 4-slot cap therefore buys us four remote voices, not three. The local user is a free fifth speaker.

### 4.2 The diarizer actor

**New file** `Packages/PindropShared/Sources/PindropSpeech/Transcription/LiveDiarizationEngine.swift`:

```swift
//
//  LiveDiarizationEngine.swift
//  PindropSpeech
//
//  Created on 2026-09-15.
//
//  Streaming speaker labels for the system-audio channel.
//
//  Deliberately an actor and deliberately not @MainActor: per-buffer audio
//  must never queue behind UI work. The orb renders at 30fps; a main-actor hop
//  per buffer starves live output and only bursts at stop.
//
//  Deliberately on its own serial executor, not the shared cooperative pool.
//  `SortformerDiarizer.process()` is a synchronous CoreML call that blocks
//  whatever thread runs it. Twice a second it would occupy a cooperative-pool
//  thread while the Nemotron engine actor holds another and the audio consumer
//  needs a third. That is the same starvation class as the shipped regression
//  fixed in 312f23a.
//
//  Live labels are provisional. FluidAudio's own benchmarks put streaming
//  diarization 10 to 15 DER points behind the offline pass, so the offline
//  pass at finalize stays the record and replaces everything written here.
//

import CoreML
import FluidAudio
import Foundation
import PindropCore

public actor LiveDiarizationEngine {

    public enum LiveDiarizationError: Error, LocalizedError {
        case modelUnavailable
        case modelLoadFailed(String)
        case processingFailed(String)

        public var errorDescription: String? {
            switch self {
            case .modelUnavailable:
                return "The live speaker model is not downloaded."
            case .modelLoadFailed(let message):
                return "The live speaker model could not be loaded: \(message)"
            case .processingFailed(let message):
                return "Live speaker labelling failed: \(message)"
            }
        }
    }

    /// One slot's newly settled speech on the system channel, in capture time.
    public struct SlotSegment: Sendable, Equatable {
        public let slotIndex: Int
        public let startCaptureTime: TimeInterval
        public let endCaptureTime: TimeInterval
        public let activity: Float
        public let isFinalized: Bool
    }

    /// `SortformerDiarizer` is a non-Sendable final class, so it cannot cross
    /// an actor boundary as an initializer argument. Tests inject a factory
    /// that runs inside the actor instead, which is also the only form strict
    /// concurrency accepts. The package is `swift-tools-version: 6.0` with
    /// `swiftLanguageModes: [.v5]`, so passing the instance directly would only
    /// warn today and break on the next language-mode bump.
    private let makeDiarizer: @Sendable () -> any Diarizer

    /// Keeps `process()` off the shared cooperative pool.
    private let queue = DispatchQueue(label: "com.pindrop.live-diarization", qos: .utility)
    public nonisolated var unownedExecutor: UnownedSerialExecutor { queue.asUnownedSerialExecutor() }

    private let modelsDirectory: URL
    private var diarizer: (any Diarizer)?
    /// The most recent system audio, kept so a slot can be cut out and embedded
    /// for profile matching. Sized to `ringSeconds`.
    private var ring: LiveAudioRing
    private var pendingSamples: [Float] = []
    /// Seconds the diarizer has actually consumed. The frame clock is only
    /// equal to capture time while this keeps up with the system tap, so any
    /// gap is filled with exactly its own duration of zeros before the next
    /// real audio is fed (see the `ingest` contract below).
    private var diarizerFedSeconds: TimeInterval = 0

    /// Sortformer emits 6 frames of 0.08 s per step, so a step needs about
    /// half a second of audio. Batch to that before calling `process()`.
    private static let processBatchSeconds: TimeInterval = 0.48
    private static let ringSeconds: TimeInterval = 45
}
```

Key methods and their contracts:

| Method | Isolation | Contract |
|---|---|---|
| `load() async throws` | actor | Loads the CoreML bundle with `.cpuAndNeuralEngine`, then runs one silent warm-up inference and discards the result. Throws `.modelUnavailable` when the bundle is absent or incomplete. Never downloads (see below). |
| `ingest(_ samples: ArraySlice<Float>, captureTime: TimeInterval) async` | actor | Appends to the ring and to `pendingSamples`. **If `captureTime` is ahead of `diarizerFedSeconds`, feeds exactly that gap in zeros first**, so the frame clock never slips against capture time. Calls `addAudio` and `process()` once `pendingSamples` reaches `processBatchSeconds`. |
| `drainSegments() async -> [SlotSegment]` | actor | Returns and clears the segments produced since the last drain. |
| `clip(from:to:) async -> [Float]?` | actor | Cuts a range out of the ring for profile matching. Returns nil when the range has aged out. |
| `finish() async -> [SlotSegment]` | actor | `finalizeSession()`, then a final drain. |
| `reset() async` | actor | New capture, same loaded model. |
| `unload() async` | actor | Releases the bundle and the ring. Called at step 7 of the stop sequence. |

**Buffer tap point.** The system channel is fed to `LiveDiarizationEngine` through **its own** `AsyncStream` and **its own** detached consumer (section 3.4), and **regardless of channel ownership**. The diarizer must hear the whole system stream to keep its speaker cache coherent, so `LiveChannelArbiter.admit` returns `.drop` only for the ASR path and always reports the buffer to `onDiarizationBuffer`.

**Why the frame clock cannot be trusted on its own.** Section 4.4 treats diarizer frame time as equal to system-channel capture time. Three paths falsify that: the stream's `.bufferingNewest` policy drops under backlog, the fall-behind rule in section 4.8 deliberately stops feeding, and a system tap glitch drops audio. Any drop shifts frame time against capture time **permanently and cumulatively**, so every later label lands on text from a different moment, silently, and gets worse the longer the meeting runs. That is the worst possible failure shape for a meeting feature.

The `ingest` contract above is the fix: the engine tracks `diarizerFedSeconds` and pads any gap with its exact duration in zeros before resuming. The frame clock then stays aligned by construction rather than by assumption.

**Cadence.** Buffers arrive at about 0.256 s each. `process()` is called after every second buffer, roughly twice a second, which matches Sortformer's 0.48 s step. Each call is one CoreML inference on a 1.12 s mel window, on the dedicated queue.

**Compute units, and an upstream trap.** `SortformerModels.load(config:mainModelPath:configuration:)` accepts a `configuration` argument and then **ignores it**, building its own `MLModelConfiguration` with `computeUnits = .all` (`SortformerModelInference.swift:76` to `:79`). That violates our standing `.cpuAndNeuralEngine` rule and is exactly the GPU-contention pattern that caused a shipped bug. Do not use that entry point. Use:

```swift
try await SortformerModels.loadFromHuggingFace(
    config: .balancedV2_1,
    cacheDirectory: modelsDirectory,
    computeUnits: .cpuAndNeuralEngine,
    progressHandler: nil
)
```

which threads `computeUnits` through `DownloadUtils.loadModels`. Open an upstream issue about the ignored `configuration` parameter so a future FluidAudio bump does not silently re-introduce `.all`.

**`loadFromHuggingFace` downloads, and it must never do so from the capture path.** That entry point routes through `DownloadUtils.loadModels` (`SortformerModelInference.swift:106` to `:140`), which fetches when the bundle is missing or partial. Called at capture start it can hit the network from the audio path, and it can re-download a partial bundle mid-capture, which is the known "corrupt decoder_joint bricked streaming" failure shape. Three rules make it safe:

1. **Readiness gates the call.** `ModelManager.isLiveDiarizationReady()` must return true first. It checks that the derived bundle filename exists and is non-empty (section 4.3). If it is false, `load()` throws `.modelUnavailable` and the capture degrades to `.channel` immediately, with no call made.
2. **The load is bounded.** Wrap it in a 3 s timeout. On timeout, abandon the load, log once, and degrade to `.channel`. A load that takes longer than that is downloading, and it must not.
3. **Downloads live in `ModelManager` and nowhere else.** The setup banner's `Download` action is the only path that fetches.

Test: `aMissingBundleDegradesInsteadOfDownloading`.

**The Neural Engine budget, stated plainly.** During a Phase 2 capture, Nemotron streaming and Sortformer streaming both request `.cpuAndNeuralEngine`. At a promotion attempt an `OfflineDiarizerManager` joins them for a few hundred milliseconds. At finalize, Nemotron's offline retranscription and `FluidSpeakerDiarizer` run, which is why step 6 of the stop sequence unloads the embedder first. A warm-up inference addresses cold-start cost, not steady-state contention, so section 8.3 adds a **measured** latency gate before Phase 2 merges, and section 4.8 adds a runtime kill switch.

**Preset.** `SortformerConfig.balancedV2_1`. Same ~1.04 s latency as `fastV2_1`, larger FIFO (188 versus 40), 20.57 percent DER on AMI SDM. Keep `.balancedV2` reachable behind a constant: FluidAudio notes v2.1 can degrade when many speakers overlap, and v2 handles crowded rooms better. `highContextV2*` is unusable here: about 30.4 s of latency is not live.

**Warm-up.** After load, feed 1.2 s of zeros through `addAudio` and call `process()` once, discarding the result. This is the same lesson as the Nemotron warm-up: the first inference after a CoreML load is slow enough to be visible, and the session start is exactly when it must not be.

### 4.3 Model download

`FeatureModelType` lives in `Packages/PindropShared/Sources/PindropSpeech/FeatureModelType.swift` and gains a case. It is a `String`-backed `Codable` enum used for readiness bookkeeping, not a persisted `@Model` field, so adding a case is safe.

```swift
public enum FeatureModelType: String, CaseIterable, Identifiable, Codable, Sendable {
    case vad = "vad"
    case diarization = "diarization"
    case liveDiarization = "liveDiarization"
    case streaming = "streaming"

    /// Live speaker labels are optional in the same way offline diarization is:
    /// they only matter when a recording has more than one voice in it.
    public static let required: [FeatureModelType] = [.vad, .streaming]

    public var repoFolderName: String {
        switch self {
        // ...
        case .liveDiarization:
            return "diar-streaming-sortformer-coreml"
        }
    }
}
```

The app-side presentation extension `Pindrop/Models/FeatureModelType.swift` has exhaustive `displayName` and `description` switches. It must gain the new case in the same commit or the app target does not compile. Those two strings are plain English in that file today and are not routed through `localized(...)`; the new case follows the same shape. Localizing that whole file is a separate cleanup and is not in scope here.

`ModelManager` (`Packages/PindropShared/Sources/PindropSpeech/ModelManager.swift`) gains, in the same commit:

- `downloadLiveDiarization` in its `DownloadOperations` struct (declared at line 658, defaulted at line 731 beside `downloadOfflineDiarization`).
- A case in the download switch beside `:1423`.
- **A case in `refreshDownloadedFeatureModels`** (`:1358`, which switches over `FeatureModelType.allCases` at `:1361`). Missing this arm is the silent failure mode: readiness reports "not downloaded" forever with nothing to point at.
- `isLiveDiarizationReady()`, mirroring `isOfflineDiarizationModelsReady(at:)` (line 1283).

`allCases` also drives the Models settings list (`ModelsSettingsView.swift:57` to `:65`), so a new row appears there. That is intended, and it is where the model's size and download state are shown.

**Do not spell the bundle filename.** The chosen preset is `SortformerConfig.balancedV2_1`, whose FluidAudio variant name is `SortformerNvidiaLow_v2.1` and whose `fileName` is `SortformerNvidiaLow_v2.1.mlmodelc` (`DerivedData/SourcePackages/checkouts/FluidAudio/Sources/FluidAudio/ModelNames.swift:645` to `:646`, `:671` to `:673`). `Sortformer_v2.1.mlmodelc` is `fastV2_1`, a different bundle. Asserting the wrong name makes readiness false after a successful download, and the feature never turns on with no error to show.

`isLiveDiarizationReady()` therefore derives the name from the preset constant rather than hard-coding it, and `liveDiarizationReadinessNeedsTheModelBundle` asserts against the derived name, so changing the preset cannot silently break readiness.

`sizeInMB` must be measured, not guessed, before the download copy ships. Enter the measured value; do not print an estimate to the user.

Download surface: `DiarizationSetupIssueBanner` (`Pindrop/UI/Components/DiarizationSetupNotice.swift:12`) already renders in two places, `HistoryView.swift:275` and `CapturePillarViews.swift:115`. Phase 2 **reuses** it on the note page rather than building a second model-missing surface. It is not debris; it is the component the note page should have been using.

### 4.4 Mapping diarizer segments onto live text

This is the hardest part of the design. Spelled out fully.

**Three clocks exist.**

1. **Capture time.** Seconds since the capture's first audio buffer. The master timeline.
2. **Fed watermark.** Seconds the ASR engine has consumed, reported by the engine on its own emissions. Inside one ownership run it advances one for one with that channel's capture seconds.
3. **Diarizer frame time.** Sortformer's `startFrame * 0.08`. The diarizer is fed **only** system audio and **all** of it, with every gap zero-filled to its exact duration (section 4.2), so diarizer frame time equals system-channel capture time.

**The mapping.**

- The consumer keeps the current ownership run as `(source, fedStart, captureStart)`. Inside the run, `captureTime = captureStart + (fedSeconds - fedStart)`. Three scalars, refreshed at each applied handover. No splice map, no inversion across history, no tap-skew calibration, because only the open span can ever be split.
- `LiveDiarizationEngine` reports `SlotSegment` in capture time directly.
- `StreamingRefinementCoordinator.commitRawUpTo` appends `(rawOffset, captureTime)` to `stamps` from the fed watermark the engine reported with the text (section 3.3). The watermark is data carried with the emission, so partial coalescing loses intermediates but never the watermark of the survivor.

So a committed span carries `[startOffset, startOffset + duration)` in capture time, and a diarizer segment carries `[startCaptureTime, endCaptureTime)` in capture time. Attribution is a plain overlap query:

```
speaker(span) = argmax over slots of  overlap(span.captureRange, slot.finalizedRanges)
```

with a tie broken toward the slot that owned the previous span, so a marginal overlap does not flip the label back and forth.

**Sub-turn granularity.** A single system-channel turn can hold two remote voices. Rather than cutting text proportionally (which would be guesswork), the diarizer **emits a boundary**: when a newly finalized `SlotSegment` names a different slot than the current one, `LiveDiarizationEngine` reports it and the consumer calls `coordinator.markBoundary(.speakerChange, speaker:, atCaptureTime:)` with the segment's start time. The coordinator binary-searches `stamps` and splits the open span at that raw offset, so text decoded from audio before the switch stays with the previous slot even though the boundary arrived a second late.

**A speaker change only applies while the system channel owns the engine.** The diarizer hears the system stream regardless of ownership, so slots keep switching while the **microphone** owns the engine, sometimes for many seconds. Applying those switches would close the user's own paragraph and head their next sentence `Speaker 3`. The consumer already knows the current owner, so it applies `.speakerChange` only when `currentOwner == .systemAudio`. Otherwise it records the change in the diarizer's own timeline, and the next `.channelChange` to system audio carries the correct initial speaker.

**Speaker changes need hysteresis, exactly as channel changes do.** Sortformer's frame duration is 0.08 s and overlapped speech churns slots. Without a floor, every finalized slot change becomes a paragraph cut plus a main-actor hop, the transcript shreds into one-word paragraphs under real overlap, and the "a few hops per minute" budget from section 3.4 is gone. Constants, stated beside the arbiter's:

```swift
/// A slot must hold the floor this long before its change may cut a paragraph.
static let minimumSlotTurnSeconds: TimeInterval = 1.00
/// And it must have this much finalized speech behind it.
static let minimumSlotFinalizedSeconds: TimeInterval = 0.40
```

Slot changes arriving inside the window are coalesced: the last one wins and only one boundary is emitted.

**Latency budget.** Sortformer `balancedV2_1` finalizes about 1.04 s behind real time. The retroactive split removes that lag from the attribution, so the label is correct even though it arrives late. What the reader sees is a turn header that appears roughly one second after the voice changed, on text that was already correctly split. That is the same feel as a live caption track and is acceptable.

**Degenerate cases.**

- The diarizer reports no finalized segment overlapping a span (silence-only span, or the diarizer is behind): the span keeps the `.channel` tier label `Call audio`, and it keeps it permanently (section 4.5).
- Two slots overlap the span roughly equally (real overlapped speech): keep the previous slot and log. Do not invent a third label.
- The boundary's capture time precedes the open span's start: clamp to the start and log. Closed spans are never re-split.

### 4.5 Confidence-tier state machine

```
                    first audio on the system channel
                                 │
                                 ▼
                          ┌────────────┐
                          │  .channel  │   label: "Call audio"
                          └─────┬──────┘
   the diarizer finalizes ANY segment for this slot, past a
   0.35 s noise gate. This is the FIRST finalized segment, not a
   sustained-speech threshold.
                                 │
                                 ▼
                        ┌────────────────┐
                        │  .provisional  │  label: "Speaker 2"
                        └───────┬────────┘
   the slot has ≥ 3.0 s of finalized speech AND an offline-space
   embedding of that speech matches a profile above the live
   thresholds (see section 4.6)
                                 │
                                 ▼
                          ┌────────────┐
                          │   .named   │   label: "Dana"
                          └────────────┘
```

**Why `.provisional` starts at the first finalized segment and not at 1.5 s.** A turn ends when the speaker key changes (section 3.5), and turn grouping in the shipped code keys on exactly that (`TranscriptSegmentList.swift:53` to `:82`). If a slot stays at `.channel` until it has accumulated 1.5 s, then every short turn, which is most of a real meeting ("yeah", "no, next week", "wait"), carries the same key `channel.systemAudio` and collapses under one `Call audio` header. Two people would share one header, which is silent misattribution of A's words to B.

Assigning slot identity at the first finalized segment matches the caption convention this design cites: a new voice becomes a generic `Speaker N` immediately, and only the promotion to a real name waits for sustained speech. `Call audio` then means "the diarizer has not resolved this yet", which is honest, instead of "several people", which is not.

Rules:

- **Tiers only go up during a capture.** A named speaker is never demoted to "Speaker 2" mid-recording. If a later match contradicts the first, log it and leave the label; finalize will settle it.
- **A slot is promoted, not a span.** `relabelSpeaker(slotKey:to:)` repoints every span of that slot at once, so the reader sees a consistent transcript rather than a name that starts partway down.
- **The `.channel` boundary is never crossed by a bulk relabel.** `relabelSpeaker` takes a **slot** key and rejects a channel key. Before any slot exists, every system-channel span carries `channel.systemAudio`, and those spans can belong to different people. Repointing them all at the first slot to appear would assert a false attribution, the one outcome section 4.8 forbids. So: **`Call audio` spans stay `Call audio` for the life of the capture.** They are a short prefix, because `.provisional` now begins at the first finalized segment, and finalize relabels them correctly anyway.
- **Promotion is visible and it stays visible.** The header keeps a `was Speaker 2` affix for the rest of the capture, with a 1.2 s emphasis window on top of it. See section 3.6 for the reduce-motion and VoiceOver behaviour. The rule from the research holds: never silently relabel text the reader has already read.
- **Slot numbers are stable and 1-based per capture**, assigned in the order slots first produce finalized speech. They are not Sortformer's raw indices, so a reader never sees "Speaker 4" before "Speaker 2".
- **Re-matching.** An unnamed or `.provisional` slot is re-checked at most once every 15 s, and only while it is below `.named`. A `.named` slot is never re-checked.

### 4.6 Enrolled-profile strategy

Three options were on the table. The constraint is real: `SortformerDiarizer.enrollSpeaker(withAudio:...)` wants raw samples, and `ParticipantProfile.centroidEmbeddingData` holds 256-dim centroids in the **offline** WeSpeaker space, which cannot prime Sortformer.

**Chosen: (b), post-hoc per-segment embedding match against profiles, using the offline embedding space on live segment audio.**

How it works:

1. `LiveDiarizationEngine` keeps a 45 s ring buffer of system audio.
2. When a slot crosses 3.0 s of finalized speech, the engine cuts that slot's finalized ranges out of the ring (up to 6 s, most recent first) and hands them to `LiveSpeakerEmbedder`.
3. `LiveSpeakerEmbedder` is a new actor in `PindropSpeech` owning its own `OfflineDiarizerManager`, configured with `withSpeakers(exactly: 1)` and the same `offlineClusteringThreshold` constant `FluidSpeakerDiarizer` already uses. It returns the single resulting speaker embedding, or nil.
4. The embedding goes to the existing `SpeakerIdentityService.bestMatch(for:)`, at **live thresholds**, not the offline ones. A match promotes the slot to `.named`.

Why this and not the others:

- Option (a), retained-audio evidence clips fed to `enrollSpeaker`, needs raw audio from past recordings. Audio retention defaults to 7 days, so most profiles have no audio at all, and the ones that do would need slicing and decoding at capture start, which is exactly the wrong moment. It also would not help a person who joins the call late.
- Option (c), defer all naming to finalize, is what already happens and is not a feature.
- Option (b) needs **no schema change**, reuses the embedding space the profiles are already in, reuses the matcher that was already built, and works for a speaker who appears in minute 40.

**The thresholds are new constants, not the offline ones.** `minimumSimilarityForAutoMatch` (0.72) and `minimumSimilarityMarginForAutoMatch` (0.08) are real (`Packages/PindropShared/Sources/PindropData/Services/SpeakerIdentityService.swift:66` to `:67`), but they were tuned against embeddings from a full-recording offline pass over long, aggregated per-speaker audio. Running the same embedder over a 3 to 6 second slice of conference-codec audio with `withSpeakers(exactly: 1)` produces a different similarity distribution. Applying the offline numbers unchanged is the single most likely way to put a **wrong name** on screen for forty minutes, which this design treats as the unacceptable outcome.

Phase 2 therefore adds `liveMinimumSimilarityForAutoMatch` and `liveMinimumSimilarityMarginForAutoMatch`, initialised conservatively **above** the offline values (start at 0.80 and 0.12), and sets them from a measured run over held-out clips before Phase 2 merges. The gated integration test in section 8.3 produces that measurement. Reusing 0.72 and 0.08 without the measurement is not an option; leaving slots at `.provisional` is always the safe answer.

**The embedding space must match, and it is checked.** Stored centroids are versioned by embedding space, which is why `SpeakerIdentityService.ensureCurrentEmbeddingSpace()` exists (`SpeakerIdentityService.swift:347`) and is called at the head of every mutating path there. `LiveSpeakerEmbedder` builds its **own** `OfflineDiarizerManager`, so nothing structurally guarantees it resolves the same model and the same space. A mismatch yields confidently wrong names.

The embedder therefore resolves the same `modelsDirectory` as `FluidSpeakerDiarizer`, and every promotion attempt calls `ensureCurrentEmbeddingSpace()` first. On mismatch the slot stays `.provisional` silently, with one log line. Test: `anEmbeddingSpaceMismatchNeverPromotes`.

**`.named` depends on a second optional model.** `LiveSpeakerEmbedder` needs `OfflineDiarizerManager`, which needs the `speaker-diarization-coreml` bundle, and that model is optional (`FeatureModelType.required == [.vad, .streaming]`). A user can have the live model and not the offline one, in which case `.named` is simply unreachable. Section 4.8 has a row for it, and the Phase 2 setup banner's `Download` action covers **both** bundles, not only the streaming one.

The cost of (b) is one extra `OfflineDiarizerManager` instance in memory during captures with live labels on. Mitigations: load it lazily on the first promotion attempt, not at capture start; unload it at step 6 of the stop sequence, which is a stated precondition of the offline pass and not a best effort.

**Critical isolation note.** `FluidSpeakerDiarizer` is `@MainActor` and its `diarize` runs `manager.process(audio:)` synchronously inside that isolation. Calling it for a live 6 s clip would block the main actor for hundreds of milliseconds and produce visible orb jank. `LiveSpeakerEmbedder` must be a separate actor with its own manager. Do not reach for `FluidSpeakerDiarizer` from the live path.

**Learning.** Phase 2 records **no** training evidence. The live path's confidence is too low to feed `SpeakerIdentityService.learnFromDictation`. Evidence keeps coming only from the offline pass at finalize, as today. This is a deliberate limit; revisit only with measurements.

### 4.7 Finalize reconciliation

`NoteCaptureController.finalize()` already runs the offline pass whenever `handle.capturesSystemAudio && diarizationDecision == .execute`, merges chunks, rebases segment times, and writes `diarizationSegmentsJSON`. The live labels are torn down and the finished transcript is drawn from the offline result. Phase 2 changes two things inside that flow, both of them writes into the existing JSON blob, which section 7.2 rules safe.

**1. The recorder must not end the meeting as "Speaker 2".**

`CaptureSessionStore+NoteViews.swift:375` marks the current user only when `!capturesSystemAudio` (or when a profile match happens to hit). So every meeting note today ends with the person who recorded it shown as an anonymous numbered speaker, after the live view said `You` for an hour. The offline pass has strictly **less** information than the microphone channel does here, and "the offline pass replaces every label" should not mean "the offline pass discards what we already knew for certain".

The arbiter already computes what is needed. Define a **mic-only range** as an interval where the microphone gate is open and the system gate is shut. That is the same pair of signals the echo gate reads (section 3.2), so it costs nothing extra, and it excludes the intervals where the microphone is hearing the speakers.

- During capture, the arbiter accumulates mic-only ranges in capture time.
- At finalize, those ranges are written into `diarizationSegmentsJSON` under a new key, alongside the segments. `DiarizedTranscriptSegment.decodeSegments(fromJSON:)` already degrades to nil on a malformed payload, so an older build reading a newer blob is safe.
- Any offline cluster whose speech overlaps mic-only ranges above a threshold is marked `isCurrentUser`, **without** requiring a profile match.

Test: `aMeetingCaptureMarksTheRecorderAsTheCurrentUserWithoutAProfileMatch`.

**2. The "checked again" line has to survive the wait.**

Finalize on a long meeting completes minutes after stop, usually while the reader is in another app. A line that is transient and dismissed "on the next interaction" is delivered almost only in the one case where the reader was already watching, and any relaunch loses it. That is not an honesty guarantee; it is a hope.

So `liveLabelsDiffered` is recorded inside `diarizationSegmentsJSON` too. The line shows **every time the note opens** until the reader dismisses it explicitly, and dismissal clears the flag:

> `Speaker names were checked again against the full recording.`  `Got it`

It is not dismissed by incidental interaction. A reader who watched "Dana" for forty minutes and then sees "Speaker 3" deserves to be told why, in one sentence, at a moment they are actually present for.

What the reader sees:

1. During capture: live turns with `You`, `Speaker 2`, `Dana`.
2. On stop: the live sheet collapses and the finalizing stage list appears (Phase 4). The transcript tab keeps drawing the live turns until durable segments exist (section 6.1).
3. On completion: the finished transcript replaces the live one. Names may differ from the live labels, because the offline pass is better.
4. If any name changed, the line above appears with its `Got it` action.

### 4.8 Failure and degradation modes

| Condition | Detection | Behaviour | Copy |
|---|---|---|---|
| Streaming model not downloaded | `ModelManager.isLiveDiarizationReady()` is false at capture start | Live labels stay at `.channel` for the whole capture. Everything else is unchanged. No load is attempted, so nothing can download from the capture path. `DiarizationSetupIssueBanner` appears on the note page with a download action covering **both** required bundles. | `Live speaker names need the speaker model. Download it to name people while you record.` Button: `Download` |
| Model load fails or times out | `LiveDiarizationEngine.load()` throws, or exceeds the 3 s bound | Same as above, plus a logged `Log.transcription.error`. Banner text names the failure. | `The live speaker model could not be loaded. Recording continues, and the finished note still names everyone.` |
| Offline diarization model missing | `OfflineDiarizerManager` cannot resolve its bundle at the first promotion attempt | Slots stop at `.provisional` for the whole capture. No user-facing message beyond the banner's download action, which already offers both bundles. One log line. | none |
| Embedding space mismatch | `ensureCurrentEmbeddingSpace()` reports a different space | Slots stay `.provisional`. One log line. Never a name. | none |
| All four slots in use | All four slots have finalized speech | Labels stay as they are. No new slot appears. One quiet chip on the live sheet, stating the **capability**, never a headcount. | `Live names cover up to four voices. Pindrop checks every speaker again when the recording ends.` |
| Diarizer falls behind | `process()` wall time exceeds its own step duration for 5 consecutive steps, or the diarizer stream reports drops | Stop feeding the diarizer, keep existing labels frozen, keep ASR untouched (they are separate streams, so ASR was never at risk from this). Log once. | `Live speaker names paused.` plus `Pindrop checks the speakers again when the recording ends.` only when the offline pass is actually scheduled for this capture |
| ASR partial latency regresses | Measured p95 partial arrival latency exceeds the section 8.3 budget for N consecutive windows | **Runtime kill switch**: live diarization is disabled for the rest of the capture, slots freeze, ASR recovers. This is the risk that actually matters, and the one the earlier draft detected on the wrong side. | `Live speaker names paused.` |
| Embedder unavailable or slow | `LiveSpeakerEmbedder` throws or exceeds a 2 s budget | Slots stay `.provisional`. No user-facing message: "Speaker 2" is already an honest label. | none |
| Overlapped speech | Two slots overlap a span equally | Keep the previous slot, log at debug. | none |

**No copy in this table states a fact the app cannot observe.** An earlier draft claimed `More than four voices are on this call`, inferred from slot reassignment churn. Churn rises with overlap and reverberation on two-speaker and three-speaker calls, so that line would have claimed more than four people on a call with two. In a product whose pitch is honest labels, a confident wrong count costs more trust than saying nothing. The replacement states what the feature covers and leaves the count unclaimed.

Every chip here is checked against the collapsed-row constraint from section 3.10 before its copy ships.

The rule threading all of these: **degradation is always toward a lower tier, never toward a wrong name, and never toward losing text.**

### 4.9 Phase 2 test list

`Packages/PindropShared/Tests/PindropSpeechTests/LiveDiarizationEngineTests.swift` (new, driven by a fake `Diarizer` injected through the `@Sendable () -> any Diarizer` factory, placed in `PindropTests/TestHelpers/`. The factory form is required: `SortformerDiarizer` is a non-Sendable `final class`, so passing an instance into an actor initializer crosses isolation.)

| Test | Proves |
|---|---|
| `theEngineBatchesAudioToTheModelStepSize` | `process()` is not called four times a second for no reason |
| `aFinalizedSlotChangeIsReportedOnce` | one boundary per real speaker change |
| `slotNumbersAreAssignedInFirstSpeechOrder` | the reader never sees Speaker 4 before Speaker 2 |
| `segmentTimesAreReportedInCaptureTime` | the happy-path frame-to-capture-time conversion |
| `aDroppedSystemBufferDoesNotShiftLaterSegmentTimes` | the gap is zero-filled to its exact duration, so the frame clock cannot slip |
| `theRingReturnsNilForARangeThatAgedOut` | the clip path fails safely instead of embedding garbage |
| `aFallingBehindEngineStopsFeedingAndKeepsItsLabels` | the back-pressure path |
| `aFallingBehindDiarizerNeverDelaysTheAsrConsumer` | the two streams are genuinely independent |
| `loadRunsOneWarmUpInferenceBeforeReportingReady` | the CoreML warm-up is not skipped |
| `aMissingBundleDegradesInsteadOfDownloading` | nothing fetches from the capture path |

`PindropTests/LiveAttributionTests.swift` (new)

| Test | Proves |
|---|---|
| `aSpanIsAttributedToTheSlotWithTheLargestOverlap` | the overlap query |
| `aMarginalOverlapDoesNotFlipTheLabelBack` | the tie-break toward the previous slot |
| `aSpanWithNoOverlapKeepsTheChannelLabel` | the honest fallback |
| `aSpeakerChangeBoundaryDoesNotStealEarlierText` | the retroactive split against `stamps` |
| `aSpeakerChangeIsIgnoredWhileTheMicrophoneOwnsTheEngine` | the user's own sentence is never headed `Speaker 3` |
| `slotChangesInsideTheHysteresisWindowCoalesceIntoOneBoundary` | overlap does not shred the transcript into one-word paragraphs |
| `aBoundaryBeforeTheOpenSpanClampsInsteadOfResplittingHistory` | closed spans are never re-split |

`PindropTests/LiveSpeakerPromotionTests.swift` (new)

| Test | Proves |
|---|---|
| `theFirstFinalizedSegmentMakesASlotProvisional` | slot identity is not withheld until 1.5 s |
| `twoShortSlotsDoNotShareATurn` | the misattribution this rule exists to prevent |
| `aSegmentBelowTheNoiseGateDoesNotOpenASlot` | the 0.35 s gate |
| `aChannelTierSpanIsNeverBulkRelabelled` | `Call audio` history is never claimed by the first slot |
| `aProfileMatchAboveThresholdPromotesEveryPastSpanOfThatSlot` | promotion repoints the whole slot, not one span |
| `aProfileMatchBelowTheLiveMarginDoesNotPromote` | the live margin, not the offline one, is what gates a name |
| `anEmbeddingSpaceMismatchNeverPromotes` | a versioned-centroid mismatch cannot produce a name |
| `aMissingOfflineModelLeavesSlotsProvisional` | the second optional dependency degrades quietly |
| `aNamedSlotIsNeverDemoted` | the up-only rule |
| `aNamedSlotIsNotReMatched` | the 15 s re-check does not run on named slots |
| `promotionKeepsAWasNameAffixForTheRestOfTheCapture` | the cue is derived from `promotedAt`, not a one-shot flag |
| `theRelabelEmphasisWindowExpiresButTheAffixDoesNot` | the same, from the other side |

`PindropTests/ModelManagerTests.swift` (extended)

| Test | Proves |
|---|---|
| `liveDiarizationIsNotRequired` | it never blocks first run |
| `liveDiarizationReadinessNeedsTheModelBundle` | an empty directory is not "ready", and the expected filename is derived from the preset |
| `refreshDownloadedFeatureModelsSeesLiveDiarization` | the second switch arm exists, so readiness is not stuck at "not downloaded" |

### 4.10 Phase 2 localization

| English | Where |
|---|---|
| `Speaker %d` | live turn header (already exists) |
| `was %@` | live turn header affix after a promotion |
| `%1$@ is now %2$@.` | VoiceOver announcement on promotion |
| `Live speaker names need the speaker model. Download it to name people while you record.` | setup banner |
| `Download` | setup banner button (already exists) |
| `The live speaker model could not be loaded. Recording continues, and the finished note still names everyone.` | setup banner, load failure |
| `Live names cover up to four voices. Pindrop checks every speaker again when the recording ends.` | live sheet chip, all four slots in use |
| `Live speaker names paused.` | live sheet chip |
| `Pindrop checks the speakers again when the recording ends.` | appended to the chip above, only when the offline pass is scheduled |
| `Speaker names were checked again against the full recording.` | note page, every open until dismissed |
| `Got it` | dismiss action for the line above |
| `Name speakers while recording` | Settings row title |
| `Show who is talking in the live transcript. Names are checked again when the recording ends.` | Settings row description |

---

## 5. Phase 3: meeting-first entry

### 5.1 What signal we can actually get

The app already creates Core Audio process taps (`CATapDescription(stereoMixdownOfProcesses:)` and `AudioHardwareCreateProcessTap`, `AudioRecorder.swift:2388` and `:2481`). The same framework generation exposes the audio process object list, so no new entitlement and no new permission are needed.

`ConferenceAudioMonitor` reads the following. Both properties landed in macOS 14.4, and the monitor attempts the read regardless of version, treating any error as "no call detected" (see the availability rule below):

- `kAudioHardwarePropertyProcessObjectList` on `kAudioObjectSystemObject`, giving one `AudioObjectID` per process that has touched audio.
- Per process: `kAudioProcessPropertyBundleID`, `kAudioProcessPropertyIsRunningInput`, `kAudioProcessPropertyIsRunningOutput`.

**The detection rule:**

> A conference call is in progress when a process whose bundle identifier is in `ConferenceAppCatalog` has **both** `isRunningInput` and `isRunningOutput` true, continuously, for 10 seconds.

The `isRunningInput` half is what makes this reliable. A browser playing a video has output only. A browser in a Meet call has the microphone open. Requiring both removes almost all false positives without any per-app special casing.

`ConferenceAppCatalog` is a static list, not a heuristic:

```
us.zoom.xos
com.microsoft.teams, com.microsoft.teams2
com.cisco.webexmeetingsapp, com.webex.meetingmanager
com.tinyspeck.slackmacgap
com.hnc.Discord
com.apple.FaceTime
com.google.Chrome, com.apple.Safari, org.mozilla.firefox,
com.microsoft.edgemac, com.brave.Browser, company.thebrowser.Browser
```

Browsers are in the list only because the `isRunningInput` requirement makes them safe. The catalog is a plain constant in `Pindrop/Services/ConferenceAppCatalog.swift` so adding an app is a one-line change.

**Polling.** A property listener on `kAudioHardwarePropertyProcessObjectList` catches processes appearing and disappearing. The running-input and running-output flags change without a list change, so add a 5 s poll while any catalog app is present, and no poll at all when none is. Idle cost is one array read every few seconds only when a conference app is running.

**Availability: reuse the answer the app already has.** An earlier draft added an `#available(macOS 14.4, *)` axis, an `.unsupported` monitor state, and a test for a version window measured in point releases. That is a second availability axis for no gain, because system audio capture already requires **macOS 14.2** (`AudioRecorder.swift:2322`, `:3847`, `:4387`, `:4392`). Below 14.2 there is no meeting feature to gate at all, and hiding the affordances at 14.4 would have stranded 14.2 and 14.3 users who can already record system audio.

The rule is two states, not three:

- If system audio capture is unavailable, every meeting affordance is hidden, for that reason and no other.
- If it is available, attempt the process-object read. A non-zero `OSStatus`, which is what 14.2 and 14.3 return for `kAudioHardwarePropertyProcessObjectList`, is treated as **no call detected**. No new `#available` axis, no third state, and the existing `aCallEndingClearsTheSignal` test already covers the shape of that fallback.

**Two facts worth writing down.** The app is **not sandboxed** (`Pindrop/Pindrop.entitlements` has no `com.apple.security.app-sandbox` key), which is why the process object list returns other processes at all. And `AudioObjectGetPropertyData` can block on `coreaudiod`, so every HAL property read runs off the main actor.

**EventKit is not built, and no seam is invented for it.** An earlier draft shipped a `MeetingScheduleSource` protocol, a `NullMeetingScheduleSource`, a `ScheduledMeeting` type, and a test asserting that an inert thing is inert. That is a protocol with one conformer and no caller, an injected dependency that is always the same value, and a test that cannot fail. When EventKit does land it will need a different shape anyway (permission state, refresh cadence, conference-link parsing), so the seam did not even buy the option it claimed to.

All four are deleted. `MeetingInvitationController` takes only `ConferenceAudioMonitor`, and one comment records where a calendar source would attach. That comment is the whole value the seam was providing.

### 5.2 The invitation flow, and permission handling

Two surfaces, split so the default path needs no permission at all.

**Surface A: the menu (default on, no permission).**

While `ConferenceAudioMonitor` reports a call, the menu bar menu shows a new item:

> `Record this call`

Selecting it starts a meeting note with system audio pre-enabled and origin `.menuBar`. The menu bar icon carries a small filled dot while a call is detected, using the existing status item image path. When no call is detected the item is absent, not disabled.

**Where the item goes matters.** `StatusBarController` puts `Start Recording` near the top of the menu, at `:191` to `:198`, and the note items are inserted after it by `syncNoteCaptureItems()`. Inserting a conditional item **above** `Start Recording` moves the primary action under the cursor exactly while a call is running, so a user reaching for `Start Recording` by muscle memory starts a meeting note by accident. `Record this call` therefore goes **below** the note items, in a slot whose position does not move, and `Start Recording` stays where it is.

**Surface B: a notification (default off, needs permission).**

A Settings row, `Notify me when a call starts`, off by default. Turning it on requests `UNUserNotificationCenter` authorization for `.alert` only, no sound. A meeting during a call is the worst possible moment for a sound.

When on and a call is detected:

- One notification, title `A call started`, body `Record it as a note?`, with two actions: `Record` and `Not now`.
- Rate limit: at most one per bundle identifier per 30 minutes, never while a capture is running, and never again for that bundle identifier after `Not now` until the call ends.
- If authorization is denied or later revoked, the row turns itself off and shows: `Notifications are turned off for Pindrop. Turn them on in System Settings to be asked about calls.`

**Surface C: one ask, once, at the moment it is relevant.**

Surfaces A and B alone ship a meeting feature almost nobody finds. The user is in a full-screen conference window. They do not open the menu bar during a call, and the status item dot is behind the call app on most setups. The notification that would reach them is off by default and lives in a Settings pane they have no reason to open. The likely outcome is that detection runs all day and the feature is never used.

So the notification stays opt-in, but Pindrop asks once, at a moment the question makes sense:

- The **first ever** detected call arms a one-time in-app ask.
- The ask is shown the next time the main window is visible, never over the call.
- Title `Pindrop noticed a call.` Body `Do you want a notification when a call starts?` Buttons `Notify me` and `No thanks`.
- Either answer is written to the settings key and the ask never appears again. `Notify me` runs the same authorization request the Settings row runs.

Tests: `theFirstDetectedCallArmsTheOneTimeAsk`, `theAskIsNeverShownTwice`, `theAskIsNotShownDuringACapture`.

The five-minutes-before and one-minute-before calendar prompts Granola uses are deliberately not built. They need a calendar, and the calendar is not in scope.

### 5.3 Menu bar restructure

Current items (`StatusBarController.swift:223` and `:231`):

```
New note
New note with system audio
```

Replaced by:

```
New meeting note
New note
Record this call            (only while a call is detected, below the note items)
```

- `Record this call` and `New meeting note` both request `[.microphone, .systemAudio]`.
- `New note` requests `[.microphone]` only.
- The `New note with system audio` **menu item** is deleted. `New meeting note` says the same thing in the words a person would use, and two items that differ by a source list is a settings control pretending to be a menu.

**The rename does not change output shape.** In Phase 3, `New meeting note` is **template-neutral**: it sets `requestedSourceKinds` and nothing else, so an enhanced note produced from it looks exactly like one produced from `New note with system audio` does today. Everyone who used the old item for a lecture, a podcast, or a one-to-one video call keeps the output they had.

The meeting template preset lands in Phase 4, in the same commit as the template picker (section 6.2), so the first release in which a meeting note is shaped differently is also the first release in which the reader can see which template did it and change it. Changing output shape behind a rename, one release before the control that would explain it, is not acceptable.

**The string is not deleted.** `New note with system audio` has a second, unrelated caller: `NotesPresentation.NoteCreationOption.title` (`Pindrop/UI/Main/NotesPresentation.swift:275`), which drives the notes-list new-note options. It is also asserted by `PindropTests/LocalizationKeyResolutionTests.swift:44`. Removing the string would regress a live surface to English in 30 locales and fail a test that is green today. Phase 3 deletes the **menu item only**, keeps the string, and updates `StatusBarControllerTests:118`. Whether `NoteCreationOption` should also change is a separate question and is not answered here.

The note page's record button dropdown (`NotePageView.swift:573`) keeps its two entries, `Record` and `Record with system audio`, because there the choice is about the note in front of you, not about starting something new.

### 5.4 Intent presets

No new persistence. `CaptureIntent` already carries `requestedSourceKinds` and `requestedTemplatePresetIdentifier`, and `CaptureIntentModel` (V15) already persists both.

```swift
extension CaptureIntent {
    /// A note that records a call: both channels. Phase 3 sets no template.
    /// Phase 4 adds `requestedTemplatePresetIdentifier` in the same commit as
    /// the picker that lets a reader see and change it.
    static func meetingNote(origin: CaptureIntentOrigin) throws -> CaptureIntent

    /// A note that records only the person holding the machine.
    static func soloNote(origin: CaptureIntentOrigin) throws -> CaptureIntent
}
```

`origin` gains no new case. A call started from the menu is `.menuBar`; one started from a notification action is `.automation`, which is the honest description and already exists.

### 5.5 Settings

New Settings section, `Meetings`:

| Control | Default | Notes |
|---|---|---|
| `Watch for calls` | on | Hidden entirely when system audio capture is unavailable. Turning it off stops the monitor and removes `Record this call`. |
| `Notify me when a call starts` | off | Disabled while `Watch for calls` is off. Requests notification permission when turned on. Also written by the one-time ask in section 5.2. |
| `Record system audio in meeting notes` | on | Feeds `CaptureIntent.meetingNote`. |
| `Name speakers while recording` | off | Phase 2's control. Backed by a **new** `@AppStorage` key, `liveSpeakerNamesEnabled`. |

**`Name speakers while recording` must not be bound to `diarizationFeatureEnabled`.** An earlier draft called the new row "the first user-visible home" for that existing flag. It is not a home for it; it is a different setting. `diarizationFeatureEnabled` gates the **finalize** diarization stage: `CaptureStageAssignmentResolver.diarizationSelection` returns `.disabled` when it is false (`Pindrop/Services/CaptureStageAssignmentResolver.swift:402`), and it is also read at `AppCoordinator.swift:7396`, through `SettingsStore.isFeatureEnabled` and `setFeatureEnabled` (`:1411` to `:1419`), and by `MCPToolDispatcher.swift:498`.

Binding the two would mean a user who turns off "Name speakers while recording" silently turns off speakers in the **finished note** as well, which contradicts this design's own repeated promise that the finished note still names everyone (sections 4.7 and 4.8).

So Phase 2 adds `liveSpeakerNamesEnabled`, default off, gating live labels only, and leaves `diarizationFeatureEnabled` alone. Both keys are reset in the test-mode path (`SettingsStore.swift:950`). If `diarizationFeatureEnabled` ever wants a UI home, it is a separate row with separate copy (`Name speakers in finished notes`), not a rename of this one. Test: `turningOffLiveSpeakerNamesLeavesTheFinalizeDiarizationStageEnabled`.

### 5.6 Phase 3 test list

`PindropTests/ConferenceAudioMonitorTests.swift` (new, against a `ConferenceAudioProcessProbe` protocol double in `PindropTests/TestHelpers/`)

| Test | Proves |
|---|---|
| `aConferenceAppWithInputAndOutputIsACall` | the core rule |
| `aBrowserPlayingVideoIsNotACall` | output without input is ignored, the main false-positive class |
| `aNonCatalogAppIsNeverACall` | the catalog is authoritative |
| `aCallMustHoldForTenSecondsBeforeItIsReported` | debounce |
| `aCallEndingClearsTheSignal` | teardown, and the shape of the fallback when the process-object read fails |
| `aFailedProcessListReadReportsNoCall` | 14.2 and 14.3 degrade to "no call", with no new availability axis |

`PindropTests/MeetingInvitationControllerTests.swift` (new)

| Test | Proves |
|---|---|
| `oneCallProducesAtMostOneNotification` | rate limit |
| `noNotificationWhileACaptureIsRunning` | no interruption of a live recording |
| `notNowSuppressesThatAppUntilTheCallEnds` | dismissal is respected |
| `deniedAuthorizationTurnsTheSettingOff` | the permission-revoked path |
| `theFirstDetectedCallArmsTheOneTimeAsk` | the discovery path exists at all |
| `theAskIsNeverShownTwice` | either answer is final |
| `theAskIsNotShownDuringACapture` | it never lands over a live recording |

`PindropTests/StatusBarControllerTests.swift` (extended)

| Test | Proves |
|---|---|
| `recordThisCallIsAbsentWithoutACall` | the item is hidden rather than disabled |
| `recordThisCallNeverMovesTheStartRecordingItem` | the muscle-memory rule |
| `newMeetingNoteRequestsBothSourcesAndNoTemplate` | Phase 3 changes sources, not output shape |
| `newNoteRequestsTheMicrophoneOnly` | the preset |

`PindropTests/SettingsStoreCaptureAssignmentResolverTests.swift` (extended)

| Test | Proves |
|---|---|
| `turningOffLiveSpeakerNamesLeavesTheFinalizeDiarizationStageEnabled` | the two flags are genuinely separate |

### 5.7 Phase 3 localization

| English | Where |
|---|---|
| `Record this call` | menu bar, while a call is detected |
| `New meeting note` | menu bar |
| `New note` | menu bar (already exists) |
| `A call started` | notification title |
| `Record it as a note?` | notification body |
| `Record` | notification action (already exists) |
| `Not now` | notification action |
| `Meetings` | Settings section |
| `Watch for calls` | Settings row |
| `Show a way to record when a meeting app opens your microphone.` | Settings row description |
| `Notify me when a call starts` | Settings row |
| `Notifications are turned off for Pindrop. Turn them on in System Settings to be asked about calls.` | Settings row, permission denied |
| `Record system audio in meeting notes` | Settings row |
| `Pindrop noticed a call.` | one-time ask, title |
| `Do you want a notification when a call starts?` | one-time ask, body |
| `Notify me` | one-time ask, accept |
| `No thanks` | one-time ask, decline |

`New note with system audio` **stays** in `Localization/app/*.yml`. Only the menu item is removed; `NotesPresentation.NoteCreationOption` still uses the string, and `LocalizationKeyResolutionTests.swift:44` still asserts it.

---

## 6. Phase 4: flow polish and cleanup

### 6.1 Visible pipeline stages between stop and enhanced

Today `NotePageView` shows one `StageProgressRow` for the current stage and nothing else. A reader who stops a 50-minute meeting sees "Finalizing" for several minutes with no idea what is happening or whether it is stuck.

**And the text they were reading disappears.** `NotePagePresentation.isTranscriptLive` is `state.capture.isRecording` (`:449`), so the moment stop is pressed the transcript pane switches to durable segments that do not exist yet. After a 50-minute meeting the reader watches everything they were reading vanish for several minutes while a row spins. The text is still in memory: `NoteCaptureState.beginFinalizing` clears only the tentative tail (`:152` to `:159`).

Phase 4 changes that predicate to keep drawing the live turns while `phase` is `.finalizing` or `.enhancing` **and** no durable segments exist, under one line:

> `Transcript so far. Pindrop is checking it against the recording.`

Test: `aFinalizingCaptureWithLiveSpansAndNoDurableTranscriptStillShowsText` in `NotePagePresentationTests`.

**State model.** `NoteCaptureState.FinalizationStage` (line 23) gains one case. It carries progress in associated values, so it cannot be `CaseIterable`; the checklist needs a plain ordered name list, which is what `FinalizationStep` is.

```swift
/// The named work a finalizing capture is doing, with progress where the
/// stage can report it. `nil` progress means "running, length unknown"; the
/// UI shows an indeterminate affordance rather than a fake percentage.
enum FinalizationStage: Equatable {
    case sealingAudio
    case transcribing(Double?)
    case diarizing(Double?)
    case matchingSpeakers
    case assembling

    var step: FinalizationStep {
        switch self {
        case .sealingAudio: .sealingAudio
        case .transcribing: .transcribing
        case .diarizing: .diarizing
        case .matchingSpeakers: .matchingSpeakers
        case .assembling: .assembling
        }
    }
}

/// One stage's name, with no progress attached, in the order the pipeline
/// runs them. `.enhancing` is a `Phase`, not a `FinalizationStage`, and it is
/// listed here because the reader sees one list from stop to done.
enum FinalizationStep: String, Equatable, CaseIterable, Sendable {
    case sealingAudio
    case transcribing
    case diarizing
    case matchingSpeakers
    case assembling
    case enhancing
}

/// What one stage is doing right now, for the checklist.
enum StageStatus: Equatable {
    case pending
    case running(Double?)
    /// The stage did not apply to this capture, for example diarization on a
    /// microphone-only note. Drawn quietly, never as a failure.
    case skipped
    case done
    case failed(String)
}

/// One row of the checklist. A tuple array cannot back a SwiftUI `ForEach`
/// without a wrapper, so the wrapper is the type.
struct FinalizationChecklistRow: Identifiable, Equatable {
    var id: FinalizationStep { step }
    let step: FinalizationStep
    let status: StageStatus
}

/// Every step of this capture in order, with its status. The interface draws
/// the whole list so the reader can see what is finished, what is running,
/// and what does not apply.
var finalizationChecklist: [FinalizationChecklistRow] { get }
```

`.matchingSpeakers` is the profile-matching pass that already runs inside finalize but has never had a name.

**UI.** The single `StageProgressRow` becomes a vertical checklist of `StageProgressRow` values. Done steps show a check in `AppColors.textSecondary`. The running step shows its name in `AppColors.textPrimary` with its determinate or indeterminate affordance. Skipped steps show their name in `AppColors.textTertiary` with the word `Skipped`. Pending steps show their name in `AppColors.textTertiary`.

**Stall affordance, with an action.** If the running step reports no progress change for 45 s, a line appears under it:

> `Still working. Long recordings take a while.`  `Show the transcript so far`

An earlier draft said there was no correct action to offer. There is one. The committed live transcript is already durable in the checkpoint, so a reader stuck at `Transcribing` for ten minutes on a 50-minute meeting can read and copy what Pindrop already heard. The action draws that checkpointed text read-only, using the same `liveTranscriptForCopy` shape as the live sheet.

**Failure states say where the audio went.** A failed row states the outcome and the next step in the house pattern rather than offering a bare retry:

> `Transcribing failed. The recording is saved. Try again, or open the audio from the note.`

Tests on the projection, in `NoteCaptureStateTests`:

| Test | Proves |
|---|---|
| `aFailedStageProjectsAFailedRowAndLeavesLaterStepsPending` | the failure branch |
| `aStageWithNoProgressForTheStallWindowProjectsTheStallAffordance` | the stall branch |
| `aMicrophoneOnlyCaptureProjectsIdentifyingSpeakersAsSkipped` | skipped is not failed |

### 6.2 Template picker reachability

The template that shapes the enhanced panel is chosen by `CaptureIntent.requestedTemplatePresetIdentifier` and can be regenerated per panel, but there is no way to reach the choice from the note page except by regenerating.

Add a template control in two places:

1. **Note page header**, beside the enhanced panel selector: a menu button showing the current template name. Choosing another template regenerates the panel through the existing `onGenerateEnhancedPanel` path. No new persistence: `CaptureEnhancedPanelModel` already freezes the template name per generation.
2. **Meeting start flow**: the record button dropdown gains a `Template` submenu listing the presets, which sets `requestedTemplatePresetIdentifier` on the intent before the capture starts.

Copy for the empty case: `No template. The note is written as plain notes.`

**The meeting template preset lands here, in this commit.** Phase 3's `New meeting note` is template-neutral on purpose (section 5.3). `P4.2` adds both the picker and `CaptureIntent.meetingNote`'s `requestedTemplatePresetIdentifier`, so the release that first shapes a meeting note differently is also the release in which the reader can see which template did it and pick another. Test: `theMeetingIntentCarriesTheMeetingTemplateOnlyOnceThePickerExists`.

### 6.3 Mic-only capture recovery delivery

`CaptureIntentModel` (V15) already persists `destination`, `destinationNoteID`, `requestedSourceKinds`, `requestedTemplatePresetIdentifier`, and `origin` for every capture. `NoteCaptureController.recoverInterruptedCaptures()` already loops interrupted sessions and re-runs the work items. What is missing is **delivery**: a recovered microphone-only capture finishes and lands nowhere the reader will look.

Design:

1. During recovery, restore the intent with `CaptureIntentModel.restoreIntent()`.
2. If `destination == .existingNote` and the note still exists, finalize into it, exactly as a live capture would.
3. If `destination == .newNote` and `destinationNoteID` was bound before the crash, finalize into that note.
4. If `destination == .newNote` and no note was ever bound, create one now, titled from the auto-naming path, and mark it recovered.
5. If the destination note has since been deleted, fall back to a new note. Never drop the transcript.
6. Every recovered note carries a `Recovered` chip in the library row and one line at the top of the note: `Recovered from a recording that was interrupted.`
7. `origin` is not used to steal focus. A recovered capture never pulls a window forward. It appears in the library and the note is there when the reader goes looking.

**Where "recovered" is stored, spelled out.** A chip and a note-top line must survive relaunch, and section 7.1 says Phase 4 adds no persistence. Both are true, because the state is **derived, not stored**. Left implicit, an implementer would add a field to a V15 `@Model` and brick the local store, which is the precise outcome section 7.2 exists to prevent.

The derivation: `CaptureFailureRecordModel.recoveredAt` already exists (`Packages/PindropShared/Sources/PindropData/Models/CaptureSessionModels.swift:555`) and carries `sessionID`. A note is "recovered" when a capture session bound to it has a failure record with a non-nil `recoveredAt`.

The cost matters, because the library list draws many rows. The query runs **once per library page load**, as one fetch of recovered `sessionID` values into a `Set`, and each row tests set membership. It is not a per-row fetch. Test: `theRecoveredChipIsDerivedWithOneFetchPerPage`.

Tests live in `PindropTests/NoteCaptureControllerTests.swift` beside the existing recovery tests:

| Test | Proves |
|---|---|
| `aRecoveredCaptureFinalizesIntoItsBoundNote` | the common case |
| `aRecoveredCaptureWithNoBoundNoteCreatesOne` | rule 4 |
| `aRecoveredCaptureWhoseNoteWasDeletedCreatesANewOne` | rule 5, the transcript is never dropped |
| `aRecoveredCaptureNeverRaisesAWindow` | rule 7 |
| `aRecoveredNoteIsIdentifiedWithoutAnyNewModelField` | the schema promise holds |

### 6.4 Justified cleanup and reuse list

Every item here either reduces risk for this work or was flagged by the debris audit. Nothing else.

| # | What | Why it is safe | Why it reduces risk | Rides |
|---|---|---|---|---|
| 1 | Replace the source-exclusion rule in `AudioRecorder.forwardLiveBuffer` (`:3239` to `:3255`) with `LiveChannelArbiter`, **and** give each source its own `ThreeBandLevelAnalyzer` and `AudioLevelNormalizer` | The exclusion rule is also the realtime serialization the meter path depends on (section 3.2). Per-source instances restore it without the exclusion | Deleting the rule alone is a data race in the realtime audio path plus filter-state cross-contamination in the orb bands | P1 |
| 2 | Delete `AudioRecorder.onAudioBuffer` (`:3821`, raised at `:3933` and `:4041`), replaced by `onLivePacket` | Four call sites in `StreamingSessionController` (`:980`, `:1012`, `:1020`, `:1033`) plus six in tests | A buffer callback that cannot express a handover would force a side channel | P1 |
| 3 | Delete `NoteCaptureState.liveTranscript` and `liveTentativeTranscript`, replaced by `liveSpans` and `liveTentative` plus the computed `liveTranscriptText` and `liveTranscriptForCopy` | Readers are `LiveTranscriptSheet`, `LiveTranscriptLines` (`NotePageView.swift:2009`), and the controller, all rewritten in this phase | Keeping both would let the string and the spans disagree, which is exactly the class of bug that is hard to see | P1 |
| 4 | **Reuse**, do not rebuild: render the existing `DiarizationSetupIssueBanner` (`DiarizationSetupNotice.swift:12`) on the note page | It already renders in `HistoryView.swift:275` and `CapturePillarViews.swift:115`, so its copy and layout are proven | Phase 2 needs a model-missing surface. Building a second one beside an existing identical one is the worst outcome. The banner takes an explicit condition so the note page's live-model-missing state and History's offline-model-missing state stay distinguishable in one component, never conflated | P2 |
| 5 | Delete the menu item `New note with system audio` (`StatusBarController.swift:231`) only. Keep the string and keep `NotesPresentation.swift:275` | `New meeting note` covers the menu case with better words. The string still has a live caller and a green test (`LocalizationKeyResolutionTests.swift:44`) | Three near-identical entry points is how entry points get out of sync. Deleting the string as well would regress the notes-list options to English in 30 locales | P3 |
| 6 | Delete the empty `Button(localized("Open in new window", locale: locale)) {}` (`NotePageView.swift:618`), its `headerActions.canOpenInNewWindow` gate, and its localization entry | The action is an empty closure. It has never done anything | A control that does nothing teaches the reader that controls might do nothing. `NoteEditorWindowController` stays: `NotesView` uses it for library notes | P4 |
| 7 | Delete `EnhancedCitationChip` (`EnhancedViewPresentation.swift:40`), the `EnhancedNoteBlock.citations` field, and the chip-building block in `make()` (lines 394 to 417) | Round B replaced the numeric chips and the `Sources` disclosure with `EnhancedSourcePeekRow` (`EnhancedNoteBody.swift:207`). No view reads `block.citations` | Phase 2 adds speaker provenance to panels. A dead citation type is exactly what a future implementer would wire up by mistake | P4 |
| 8 | Delete `NoteCaptureState.canPause` (`:74`) and its single test assertion | Hardcoded `false`. No code branches on it | A false affordance in a state model that Phase 3 and Phase 4 both extend. Its rationale is preserved in decision 26 below | P4 |

Not on the list, and deliberately so: `NoteEditorWindowController`, the `LiveTranscriptState` dictation path, `paragraphSegments` VAD gating, and anything in `AudioRecorder` beyond items 1 and 2. They are used, they work, and touching them is drive-by.

### 6.5 Phase 4 localization

**Reuse the shipped stage vocabulary. Do not rename it.** `NotePagePresentation.stageTitle` already localizes `Sealing audio`, `Transcribing`, `Identifying speakers`, and `Writing note` (`:585` to `:596`), and its own comment states that the vocabulary deliberately mirrors `MediaTranscriptionStage` so the same work is named the same way wherever it is shown. An earlier draft introduced `Finding speakers` and `Writing the note`, which buys nothing, churns 31 locale files, and splits two surfaces that are currently in sync.

| English | Where | Note |
|---|---|---|
| `Sealing audio` | stage checklist | already exists, reused |
| `Transcribing` | stage checklist | already exists, reused |
| `Identifying speakers` | stage checklist | already exists, reused |
| `Writing note` | stage checklist | already exists, reused |
| `Matching names` | stage checklist | new. The profile-matching pass has never had a name |
| `Skipped` | stage checklist, a stage that does not apply | new |
| `Still working. Long recordings take a while.` | stall line | new |
| `Show the transcript so far` | stall line action | new |
| `Transcribing failed. The recording is saved. Try again, or open the audio from the note.` | failed stage row | new |
| `Transcript so far. Pindrop is checking it against the recording.` | transcript pane while finalizing | new |
| `Recovered from a recording that was interrupted.` | note page, recovered note | new |
| `Recovered` | library row chip | new |
| `Template` | note header menu, record dropdown submenu | new |
| `No template. The note is written as plain notes.` | template menu, empty state | new |

`Open in new window` is removed from `Localization/app/*.yml`. `New note with system audio` is **not** removed (section 5.3).

---

## 7. Persistence and schema decisions

### 7.1 Summary

**No phase adds, removes, or changes a field on any existing `@Model`. No phase adds a new `@Model`. The schema stays at V15 and `StoreSchemaVersion` and `inferredStoreVersion` in `PindropApp.swift` are not touched.**

| Phase | New persistence | Mechanism |
|---|---|---|
| 1 | none | live spans and dropped-speech markers are in-memory only |
| 2 | two new **keys inside an existing JSON blob** | live labels stay in memory. At finalize, `diarizationSegmentsJSON` gains mic-only ranges (section 4.7) and `liveLabelsDiffered`. This is the "write new data inside an existing JSON attribute" class, which section 7.2 rules safe |
| 3 | none | `CaptureIntentModel` already carries sources, template, destination, and origin. Four new `@AppStorage` keys, which are not `@Model` fields |
| 4 | none | `CaptureEnhancedPanelModel` already freezes the template name per generation. The `Recovered` chip is derived from `CaptureFailureRecordModel.recoveredAt`, not stored (section 6.3) |

### 7.2 Brick-risk analysis

The developer's local store is stamped V15 and holds real notes. Shipped users are at V14 and below. Staged migration needs `Schema(versionedSchema:)` metadata plus matching `StoreSchemaVersion` and `inferredStoreVersion` entries in `PindropApp.swift`, and getting that wrong bricks stores irreversibly (issue #76).

Four classes of change, and what this design does with each:

| Class | Risk | Decision |
|---|---|---|
| Change a field on a landed V15 `@Model` (`CaptureEnhancedPanelModel`, `NoteViewStateModel`, `CaptureIntentModel`) | **Bricks the local store.** V15 is stamped; changing the layout under a stamped version means SwiftData reads a store whose on-disk shape does not match the described schema | Forbidden. Not done in any phase |
| Change a field on an older `@Model` (`ParticipantProfile`, `ParticipantTrainingEvidence`, `TranscriptionRecord`) | Bricks shipped stores unless a full staged migration lands | Forbidden. Not done in any phase |
| Add a new `@Model` type | Safe with a new schema version | Not needed. Avoided anyway, because it would still force a V16 and a migration step for no benefit |
| Write new data inside an existing JSON blob attribute (`TranscriptionRecord.diarizationSegmentsJSON`) | Safe. `DiarizedTranscriptSegment.decodeSegments(fromJSON:)` already degrades to nil on a malformed payload | **Used by Phase 2**, for mic-only ranges and `liveLabelsDiffered`. Nothing else needs it |

**The one invariant that must not break:** `checkpointVoiceNoteLiveTranscript` requires each checkpoint to extend the previous one as a prefix (`CaptureSessionStore.swift:2365`). Live attribution never edits committed characters, only labels, and a dropped-speech marker adds none. Labels are not persisted at all. The invariant holds by construction, and a test asserts it directly: `spansRebuildTheCommittedTextIncludingItsTrailingBoundary`.

**Nothing in Phase 4 adds a `@Model` field.** This is called out because the `Recovered` chip reads like persistence and is not. Its derivation is written down in section 6.3 precisely so that an implementer does not reach for a new field on a V15 model and brick the local store.

### 7.3 Non-model persistence that does change

Two `String`-backed enums used for bookkeeping, neither of them a `@Model` field:

- `FeatureModelType` gains `.liveDiarization`. Stored as raw strings in the downloaded-models set. Decoding an unknown case is already handled; adding a case is additive. The app-side presentation extension must gain the same case in the same commit, and so must `refreshDownloadedFeatureModels` (section 4.3).
- Settings gain five `@AppStorage` keys: four under the `Meetings` section, plus `liveSpeakerNamesEnabled` for Phase 2. `SettingsStore` already uses `@AppStorage` for everything, and the test-mode reset path at `:950` must set every new key to its off-in-tests value, matching the existing pattern. `diarizationFeatureEnabled` is not touched.

---

## 8. Build, test, and verification

### 8.1 Commands

Use `just` recipes. When a direct `xcodebuild` invocation is needed, **always** pass both flags:

```bash
xcodebuild test \
  -project Pindrop.xcodeproj \
  -scheme Pindrop \
  -testPlan Unit \
  -destination 'platform=macOS' \
  -derivedDataPath DerivedData \
  -enableCodeCoverage NO \
  -only-testing:PindropTests/LiveChannelArbiterTests
```

Why both flags matter:

- `-derivedDataPath DerivedData` keeps the build in the repo-local directory. The user-level DerivedData for this project goes stale and produces failures that look like source errors and are not. The `justfile` already passes this at line 38; ad-hoc commands must too.
- `-enableCodeCoverage NO` avoids a yyjson link failure that coverage instrumentation retriggers. `just test-coverage` exists for when coverage is actually wanted; do not enable it casually while iterating.

Package-level tests for `StreamingRefinementCoordinator` and `LiveDiarizationEngine` run through `just test-shared`, which is faster than the app scheme and is the right loop for Phase 1 and Phase 2 coordinator work.

### 8.2 Per-phase gate

Every phase must pass, in order, before it is considered landable:

1. `just build`
2. `just test-shared`
3. `just test`
4. No new warnings inside the changed files.
5. `just l10n-lint` for any phase that touched `Localization/`.

### 8.3 Per-phase specifics

**Phase 1**

- Focused loop: `-only-testing:PindropSharedPackageTests/StreamingRefinementCoordinatorTests`, then `-only-testing:PindropTests/LiveChannelArbiterTests`.
- Every new test must fail before the change. For the arbiter this is trivial (the type does not exist). For `aMeetingCaptureShowsBothChannelsInTheLiveTranscript` it is the point: it fails on today's `forwardLiveBuffer` rule.
- The dictation regression tests in section 3.7a must pass **unchanged** before and after every Phase 1 commit. They are the guard on the shared pipeline.
- No model download needed. Phase 1 runs fully in CI.

**Phase 2**

- All unit tests run against a fake `Diarizer` (through the factory) and a fake embedder. No model download in CI.
- One gated integration test behind `PINDROP_RUN_INTEGRATION_TESTS`, following the existing pattern: load the real Sortformer bundle, feed a fixture two-speaker WAV, assert that two slots appear and that the first slot's finalized time is under 2.0 s. This is the only test that proves the CoreML path works at all.
- **A second gated integration test produces the live match thresholds** (section 4.6). It embeds held-out 3 to 6 second clips of known speakers through `LiveSpeakerEmbedder` and reports the similarity distribution against their profile centroids. `liveMinimumSimilarityForAutoMatch` and `liveMinimumSimilarityMarginForAutoMatch` are set from that run. Phase 2 does not merge with the offline constants copied across.
- **A measured latency gate, before Phase 2 merges.** Record streaming partial arrival latency percentiles through the existing `PipelineMetrics` plumbing, with live diarization on and off, over the same fixture. p95 regression must stay under a budget stated in the pull request. If it does not, the phase does not merge; the runtime kill switch in section 4.8 is the safety net, not the plan.
- Before merging, check the measured `sizeInMB` against the value in `FeatureModelType`.

**Phase 3**

- All monitor tests run against a `ConferenceAudioProcessProbe` double. No real Core Audio in unit tests.
- One gated integration test that reads the real process object list and asserts it returns without error and that the app's own process appears. It asserts nothing about which apps are running. On macOS 14.2 and 14.3 the read fails, and the test asserts the fallback: no call detected, no crash.

**Phase 4**

- Mostly UI and state work. Checklist projection is tested directly on `NoteCaptureState`.
- The three deletions in the cleanup list (items 6, 7, 8) must each be their own commit so a bisect can isolate them.

### 8.4 Commit shape

One intent per commit. Suggested sequence:

```
P1.0a fix(notes): keep artifact paragraphs and bound long live lines   [working tree]
P1.0b fix(notes): guard enhancement failure clearing by session        [working tree]
P1.1  feat(audio): meter each capture source independently
P1.2  feat(audio): add the live speaker gate and channel arbiter
P1.3  feat(audio): carry live audio as packets and hand over at engine boundaries
P1.4  feat(notes): attribute committed live text to its capture channel
P1.5  feat(ui): draw both live surfaces as speaker turns
P1.6  chore(l10n): add the live attribution strings

P2.1  feat(models): download the streaming speaker model
P2.2  feat(speech): report the fed watermark on streaming emissions
P2.3  feat(speech): add the live diarization engine actor
P2.4  feat(notes): label system-audio turns from the streaming diarizer
P2.5  feat(speech): promote live speaker slots to enrolled names
P2.6  feat(notes): mark the recorder as the current user at finalize
P2.7  feat(ui): show the setup banner and the promotion affix
P2.8  chore(l10n): add the live speaker strings

P3.1  feat(app): detect a conference call from audio process state
P3.2  feat(ui): offer to record a detected call
P3.3  feat(ui): restructure the menu bar around meeting notes
P3.4  feat(settings): add the meetings section
P3.5  chore(l10n): add the meeting entry strings

P4.1  feat(ui): show every finalization stage
P4.2  feat(ui): make the template picker reachable and apply the meeting preset
P4.3  fix(notes): keep the live transcript visible until the durable one exists
P4.4  fix(notes): deliver recovered microphone-only captures
P4.5  chore(ui): remove the empty pop-out button
P4.6  chore(ui): remove the unrendered citation chip
P4.7  chore(notes): remove the unused pause seam
P4.8  chore(l10n): add the pipeline stage strings
```

`P1.1` lands first and alone: the per-source meter change is what makes admitting both channels safe, and it is independently verifiable.

`P2.2` is the `TranscriptionService` and engine API widening (`StreamingTranscriptionResult.fedSeconds`, the `onPartial` payload type). It is called out as its own commit because it is the one Phase 2 change that touches the shared dictation pipeline, and the section 3.7a regression tests gate it.

### 8.5 Manual smoke checklist

A microphone is required. The user runs this. Automated tests cannot cover any of it.

**After Phase 1**

1. Start a note with system audio off. Speak three sentences with pauses. Confirm: one turn headed `You`, three paragraphs, quiet ink on the tail.
2. Start a note with system audio on. Play a video, then talk over the gap between sentences. Confirm: turns alternate between `Call audio` and `You`, and your own words appear live. This is the regression Phase 1 exists to fix.
3. **The latch test, on continuous audio.** Play music or a call recording with no gaps at all. Talk over it. Confirm your words still reach the live transcript. A fixed RMS floor fails this step and step 2 hides the failure, which is why step 2 alone is not enough.
4. **The echo test, on built-in speakers, not headphones.** Join a call, put the far end on the internal speakers, and stay silent while they talk. Confirm: nothing is headed `You`. Then say "mm-hmm" and confirm the header changes only for your own words.
5. Talk at the same time as the system audio for five seconds. Confirm: the transcript does not flap between headers mid-sentence, and a dropped-speech marker appears for the side that lost.
6. Stop. Confirm: the finished transcript replaces the live one and nothing is lost.
7. Record for two minutes with heavy alternation. Watch the orb. Confirm: no stutter, no band glitching at handovers, and partials keep arriving smoothly rather than bursting at stop.
8. Run a plain dictation. Confirm the dictation path is unchanged: no paragraph breaks, no speaker headers, no markers.
9. Turn VoiceOver on and read back one live turn. Confirm it reads `<name> said: <text>` as one element, not a stream of unlabelled lines.

**After Phase 2**

10. Join a real call with two other people. Confirm: `Speaker 1` and `Speaker 2` appear within a few seconds of each person's first sentence, and that **short** interjections get their own header rather than sharing one.
11. If one of them has a participant profile, confirm the label promotes to their name, that the promotion is visible, and that the `was Speaker N` affix is still there a minute later.
12. Turn on Reduce Motion and repeat step 11. Confirm the affix still appears with no animation.
13. Confirm the promotion repoints that speaker's earlier slot turns, and that any `Call audio` text from before the first slot existed is left alone.
14. Stop and confirm the finished transcript's names, that **you** are marked as the current user rather than a numbered speaker, and the `Speaker names were checked again` line with its `Got it` action if any name changed. Quit and relaunch, reopen the note, and confirm the line is still there until dismissed.
15. Rename the model directory and start a capture. Confirm: the setup banner appears, recording continues, no download starts, and the finished note still has speakers.
16. Join a call with five or more people. Confirm the four-voice chip appears, that it does **not** claim a headcount, and that nothing crashes.

**After Phase 3**

17. Open Zoom and start a call. Confirm `Record this call` appears in the menu within about 15 s, below the note items, with `Start Recording` unmoved, and the icon shows the dot.
18. Leave the call. Confirm the item disappears.
19. Play a video in a browser with no call. Confirm nothing appears. This is the false-positive check.
20. Join a Meet call in a browser. Confirm the item appears.
21. On a first ever detected call, bring the main window forward. Confirm the one-time ask appears once. Answer it, trigger another call, and confirm it never appears again.
22. Turn on `Notify me when a call starts`, grant permission, start a call. Confirm one notification, no sound, and that `Record` starts a meeting note.
23. Choose `Not now` and confirm no second notification for that call.
24. Start `New meeting note` and let it finish. Confirm the enhanced note is shaped exactly as `New note with system audio` produced it before this phase.

**After Phase 4**

25. Record a 15-minute meeting. Stop. Confirm the transcript pane keeps showing what you were reading, under the `Transcript so far` line, instead of going blank.
26. Watch the checklist. Confirm every stage is named, that `Identifying speakers` shows `Skipped` on a microphone-only note, and that the stall line and its `Show the transcript so far` action appear only if a stage genuinely sits still.
27. Change the template from the note header and confirm the panel regenerates.
28. Force quit mid-capture on a microphone-only note. Relaunch. Confirm the note appears in the library with the `Recovered` chip and the transcript intact, and that no window was pulled forward.

---

## 9. Open decisions made, and why

Plain list. Read this section if you read nothing else.

1. **One ASR engine with an exclusive channel arbiter, not two parallel engines.** `TranscriptionService` is built around a single leased engine; a second Nemotron instance doubles ANE load and memory and rewrites the lease system for a preview that the offline pass replaces anyway.

2. **During cross talk the current channel owner keeps the engine, and the loss is drawn.** Flapping mid-sentence produces worse text than losing an interjection, and the lost audio is still spooled and still transcribed at finalize. But a transcript that reads as continuous while one side is missing is dishonest, so the arbiter reports a dropped-speech interval and the live view draws a marker for it.

3. **On a cold start with both channels in speech, system audio wins.** A remote voice is the harder loss. You already know what you said.

4. **Hand over only at a boundary the engine produced. No clock, no pad.** Nemotron decodes in fixed chunks (1120 ms standard, 560 ms low latency), so splicing mid-chunk puts two voices in one indivisible string and a sub-chunk silence pad does nothing. Handing over at an end-of-utterance final or an idle commit makes attribution exact by commit ordering. `LiveAudioClock` is deleted: it was precision theater over a coalesced, main-actor-delivered partial, and Phase 1 does not need it. Phase 2 gets its capture times from a **fed watermark carried as data** on the engine's own emissions plus a three-scalar ownership run, which is a fraction of the machinery for the one case that genuinely needs it.

5. **Live attribution granularity is one ASR chunk, and the document says so.** Words in the last few hundred milliseconds before a handover can land with the outgoing speaker. Stating the bound is better than a mechanism that claims to remove it and cannot.

6. **Ownership is gated on speech relative to each channel's own adaptive noise floor, never on an absolute RMS constant.** Mic level tracks device gain, system level tracks app volume, and a call's far end streams continuous room tone. A fixed floor would let system audio latch the engine for the whole call, which is the exact regression Phase 1 exists to fix.

7. **The microphone may not claim the engine while it is hearing the speakers.** Mixed system-audio captures stay raw (no voice isolation, no echo cancellation), so on built-in speakers the mic channel contains the remote audio. Envelope cross-correlation plus a 6 dB dominance margin gate the claim. Without this, Phase 1 prints the other person's words under the header `You`, which is worse than printing no header at all.

8. **Admitting both channels requires per-source meter instances.** The old exclusion rule was also the realtime serialization the meter path relied on. Deleting it alone is a data race on unguarded IIR and envelope state in the audio callback.

9. **Land the uncommitted working-tree diff first as `P1.0a` and `P1.0b`.** Its `"\n"` paragraph boundaries are the exact structure the span model needs, and they are the only structure the append-only durable checkpoint can carry. The `clearEnhancementFailure` session guard is a separate intent and gets its own commit, per this document's own one-intent rule.

10. **Text spans are derived from `committedText`, not stored beside it, and the invariant includes the trailing newline.** `committedText == spans.filter(\.isText).map(\.text).joined(separator: "\n") + (isParagraphOpen ? "" : "\n")`. The naive form was false on day one, and deriving the spans makes drift structurally impossible rather than test-enforced.

11. **The dictation path gets its own section and its own regression tests.** Phase 1 changes the pipeline dictation shares. Four tests assert the overlay's committed and tentative split is byte-identical and that a dictation session sees no arbitration at all.

12. **Span tracking is gated on `preservesArtifactParagraphs`.** That flag is already the line between a note recording and a dictation. Reusing it keeps the dictation path allocation-free and keeps the commit observer contract honest for both callers.

13. **Live speaker labels are never persisted.** Finalize runs the offline pass and rewrites every label from the durable audio, so a persisted live label would be overwritten within seconds. Not persisting them keeps the checkpoint's prefix-monotonic contract untouched.

14. **No new `@Model` and no changed `@Model` field in any phase.** The local store is stamped V15 with real notes. Phase 2 writes two new keys **inside** `diarizationSegmentsJSON`, which is the one safe class of persistence change, and everything else is met by existing types and in-memory state.

15. **The `Call audio` label, not `Them` and not `Others`.** `Others` implies a group we have counted. `Them` implies the same, reads as plural over one voice, and forces gender and number choices on 30 translators that the app has not earned. Naming the channel claims nothing. Phase 2 replaces it with `Speaker %d` anyway.

16. **`SortformerConfig.balancedV2_1`.** Same ~1.04 s latency as `fastV2_1` with a much larger FIFO and 20.57 percent DER on AMI SDM. `highContextV2*` is unusable at about 30.4 s of latency. Keep `.balancedV2` reachable as a constant, because FluidAudio notes v2.1 degrades with heavy overlap.

17. **Derive the bundle filename from the preset; never spell it.** `balancedV2_1` is `SortformerNvidiaLow_v2.1.mlmodelc`, not `Sortformer_v2.1.mlmodelc` (that is `fastV2_1`). Hard-coding the wrong name makes readiness false after a successful download, and the feature never turns on with nothing to point at.

18. **Do not use `SortformerModels.load(config:mainModelPath:configuration:)`.** It accepts a configuration and then ignores it, forcing `computeUnits = .all`, which is exactly the GPU-contention pattern that already shipped as a bug once. Use `loadFromHuggingFace(..., computeUnits: .cpuAndNeuralEngine)` and file an upstream issue.

19. **But `loadFromHuggingFace` downloads, so a readiness gate and a bounded timeout wrap it.** Called unguarded at capture start it can fetch from the audio path and re-download a partial bundle mid-capture, which is the known "corrupt decoder_joint" failure shape. Downloads stay in `ModelManager`. A missing bundle degrades to `.channel` immediately.

20. **The diarizer gets its own stream, its own detached consumer, and its own serial executor.** `SortformerDiarizer.process()` is synchronous blocking CoreML. Sharing the ASR consumer would head-of-line block the ASR feed twice a second and make the buffer ring drop real speech. Sharing the cooperative pool would starve it a different way.

21. **The diarizer zero-fills any gap to its exact duration.** Frame time only equals capture time while the diarizer hears everything. Drops from back pressure, from the fall-behind rule, or from a tap glitch would otherwise shift every later label, silently and cumulatively.

22. **A `.speakerChange` applies only while the system channel owns the engine, and only past a hysteresis floor.** Otherwise a remote voice switch would head the user's own sentence `Speaker 3`, and Sortformer's 0.08 s frames would shred the transcript into one-word paragraphs under overlap.

23. **A slot becomes `.provisional` at its first finalized segment, not at 1.5 s.** Turn grouping keys on the speaker key, so withholding slot identity collapses every short interjection under one `Call audio` header and attributes A's words to B. Sustained speech gates the **name**, not the identity.

24. **`relabelSpeaker` takes a slot key and rejects a channel key.** Bulk-relabelling `Call audio` history at the first slot to appear would assert a false attribution over text that may belong to several people. `Call audio` spans keep their label for the life of the capture.

25. **Enrollment strategy (b): embed live segment audio in the offline space and match against existing profile centroids.** Sortformer's `enrollSpeaker` needs raw audio, which most profiles do not have (7-day retention). Option (b) needs no schema change and works for someone who joins in minute 40.

26. **The live match thresholds are new, measured constants, not the offline ones.** 0.72 and 0.08 were tuned on full-recording aggregated audio. A 3 to 6 second slice of conference-codec audio has a different similarity distribution, and reusing them is the most likely way to put a wrong name on screen for forty minutes. Start above them and set them from a gated measurement run.

27. **The embedder asserts the current embedding space before any promotion.** Stored centroids are versioned; a mismatch would produce confidently wrong names. On mismatch the slot stays `.provisional`, silently.

28. **`LiveSpeakerEmbedder` is a separate actor with its own `OfflineDiarizerManager`, and it is unloaded before the offline pass runs.** `FluidSpeakerDiarizer` is `@MainActor` and runs its work synchronously inside that isolation. The unload ordering is a numbered step in the stop sequence, not a best effort, because two resident offline diarizers contending for the Neural Engine at finalize is the failure it prevents.

29. **Phase 2 records no training evidence.** Live confidence is too low to feed the learner. Evidence keeps coming only from the offline pass, as today.

30. **Tiers only go up during a capture.** A named speaker is never demoted mid-recording. Contradictions are logged and settled at finalize.

31. **A promotion relabels the whole slot, not one span.** A transcript where the name starts partway down is worse than either name alone.

32. **A promotion is visible and it stays visible.** The cue is **derived** from `promotedAt`, because "true for one render pass" is not something SwiftUI can deliver. A `was Speaker 2` affix persists for the rest of the capture, since the sheet is collapsed by default and the reader is usually looking at the call window. Under reduce motion the affix appears with no animation, and VoiceOver hears a sentence, not a bare name.

33. **The live turn stack has an accessibility model, and it does not announce every turn.** One element per turn, `children: .combine`, label `<name> said: <text>`. A continuously announced caption stream is unusable. Only promotion announces.

34. **`liveTranscriptText` is the checkpoint view; `liveTranscriptForCopy` is the reader's view.** The first has to equal the durable string and therefore cannot carry names. Copy and the sheet's accessibility value use the second.

35. **Every turn above the current one carries a start time.** Their offsets are settled, the sheet scrolls, and a reader who scrolls back needs an anchor. Only the newest turn, whose end is still moving, shows none.

36. **The recorder is marked as the current user at finalize, from mic-only ranges.** Today a meeting note ends with the person who recorded it shown as a numbered speaker, after the live view said `You` for an hour. The microphone channel knows better than the offline pass here, and mic-only ranges (mic gate open, system gate shut) are already computed by the echo gate.

37. **The "names were checked again" line is persisted and dismissed explicitly.** Finalize on a long meeting completes while the reader is in another app. A transient line dismissed by incidental interaction delivers the honesty guarantee only to a reader who was already watching.

38. **No chip states a headcount.** "More than four voices are on this call" was inferred from slot churn, which rises with overlap on two-speaker calls. The replacement states the capability and leaves the count unclaimed.

39. **Conference detection requires both `isRunningInput` and `isRunningOutput`.** Requiring the microphone removes almost every browser false positive without per-app heuristics.

40. **The default meeting affordance is a menu item, the notification is opt-in, and Pindrop asks once at the first detected call.** A menu item alone ships a feature nobody finds, because the user is in a full-screen call window. A one-time in-app ask, shown the next time the main window is visible, is the smallest honest way to make the notification reachable.

41. **`Record this call` goes below the note items, and `Start Recording` does not move.** A conditional item above the primary action shifts it under the cursor exactly when a call is running.

42. **Meeting affordances reuse the existing system-audio availability answer, and a failed process-object read means "no call".** System audio already requires macOS 14.2. A separate 14.4 axis would have stranded 14.2 and 14.3 users who can already record calls, for a version window measured in point releases. Two monitor states, not three.

43. **EventKit gets a comment, not a seam.** A protocol with one null conformer, no caller, and a test that cannot fail buys no option, and the real calendar source will need a different shape anyway.

44. **The `New note with system audio` menu item is deleted; the string is not.** `NotesPresentation.NoteCreationOption` still uses it and `LocalizationKeyResolutionTests:44` still asserts it. Deleting the string would regress a live surface to English in 30 locales.

45. **`New meeting note` is template-neutral in Phase 3. The meeting preset ships with the picker in Phase 4.** Changing the shape of a user's enhanced note behind a rename, one release before the control that would explain it, is not acceptable.

46. **`Name speakers while recording` gets a new key, `liveSpeakerNamesEnabled`.** `diarizationFeatureEnabled` gates the finalize diarization stage. Binding the row to it would mean turning off live names silently turns off names in the finished note, contradicting this document's own promise in three places.

47. **`FinalizationStage` stays non-`CaseIterable`; `FinalizationStep` carries the order and `FinalizationChecklistRow` carries the row.** Associated values block `CaseIterable` synthesis, and a tuple array cannot back a `ForEach`.

48. **The finalization checklist shows every step, and the stall and failure states offer a way to the text.** The committed live transcript is already durable, so `Show the transcript so far` is a real action, and a failed row says where the recording went instead of offering a bare retry.

49. **The live transcript stays on screen until the durable one exists.** `isTranscriptLive` currently flips at stop, so a reader watches a 50-minute meeting's transcript vanish for minutes. The text is still in memory.

50. **Reuse the shipped finalization stage strings.** `Identifying speakers` and `Writing note` already exist and deliberately mirror `MediaTranscriptionStage`. Renaming them churns 31 locale files and desyncs two surfaces for nothing.

51. **A recovered capture never steals focus, and the `Recovered` chip is derived, not stored.** It reads from `CaptureFailureRecordModel.recoveredAt` with one fetch per library page. Left implicit, an implementer would add a field to a V15 model and brick the store.

52. **`canPause` is deleted, and its rationale is recorded here instead.** v1 has no pause because `AudioRecorder` cannot pause a durable spool and `CaptureSession.isValid` encodes state in revision parity, so a paused lifecycle state would mean rewriting the validator. A hardcoded `false` that nothing branches on is not a seam; this paragraph is.

53. **`DiarizationSetupIssueBanner` is reused, not rebuilt, and it was never debris.** It already renders in `HistoryView` and `CapturePillarViews`. Phase 2 adds the note page as a third host, with an explicit condition so the live-model and offline-model states stay distinguishable.

54. **`NoteEditorWindowController` is not deleted.** `NotesView` uses it for library note pop-outs. Only the empty button on the note page goes.

55. **The cleanup list is eight items and stops there.** Each one either collides with this work or was named by the debris audit. Nothing else in `AudioRecorder`, `LiveTranscriptState`, or the VAD paragraph path is touched.

### 9.1 What was rejected from review round D, and why

- **Rejected: run the VAD model per channel to gate ownership.** The review's preferred fix for the absolute-RMS problem was per-channel Silero VAD, on the grounds that the model is already `required` and downloaded. The adaptive per-channel noise floor, which the same review offered as its minimum viable alternative, is taken instead. Two more model invocations per buffer on the realtime path is a large cost for a binary decision that a tracked floor plus the echo gate already makes, and the Neural Engine budget in section 4.2 is already the tightest constraint in Phase 2. If smoke steps 3 and 4 fail on real hardware, per-channel VAD is the escalation, and this line is where that decision gets revisited.
- **Rejected: widen the `onPartial` callback to carry a fed watermark in Phase 1.** The review correctly showed that reading a clock at partial-arrival time cannot work, and proposed carrying the watermark as data as a Phase 1 API change across `TranscriptionService`, both engines, and `StreamingSessionController`. The diagnosis is accepted in full; the timing is not. Phase 1 needs no watermark at all once handovers happen at engine-produced boundaries, so the API widening moves to `P2.2`, where the one feature that needs it lives. Phase 1 then does not touch `TranscriptionService`.
- **Rejected: emit the dropped-speech marker as a `LiveTurnBoundaryReason` alone.** A boundary reason cannot carry a span with no text without making the join invariant lie. The reason case is kept, and a `LiveSpanKind.droppedSpeech` carries the marker itself, which keeps the invariant exact.
- **Rejected: backfill `Call audio` spans through the overlap query when the first slot appears.** The review offered this as one of two acceptable rules. The other one, leaving them alone, is taken: the `.channel` window is now only the first fraction of a second, the backfill would add a code path that can be subtly wrong for no visible gain, and finalize relabels those spans correctly anyway.
