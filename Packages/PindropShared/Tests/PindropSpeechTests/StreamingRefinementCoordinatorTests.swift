//
//  StreamingRefinementCoordinatorTests.swift
//  PindropTests
//
//  Created on 2026-04-16.
//  Rewritten on 2026-04-17 for the Phase 2 committed/tentative architecture.
//
//  These tests are the contract for the streaming refinement coordinator. Key invariants:
//
//    1. `committedText` is append-only — once a prefix is committed, nothing (not a new
//       partial, not EOU, not idle commit) mutates or replaces it.
//    2. LocalAgreement-2 commits tokens once they've been agreed on across two successive
//       partials AND are at least K=2 tokens back from the trailing token of the current
//       partial.
//    3. Sentence boundaries commit the full agreement regardless of K.
//    4. Idle-commit timer promotes the tentative tail wholesale after the configured
//       idle threshold.
//    5. Deterministic cleanup (filler removal, capitalization) is applied — both to
//       newly-committed chunks and to the tentative tail, freshly on each update.
//    6. `ingestFinal` commits everything (EOU is authoritative).
//    7. At session stop, the final displayed text equals committedText + tentativeTail.
//

import Foundation
import Testing
import PindropCore
@testable import PindropSpeech

@MainActor
@Suite(.serialized)
struct StreamingRefinementCoordinatorTests {

   // MARK: - Fakes

   @MainActor
   final class FakeSink: StreamingRefinementOutputSink {
      private(set) var beganCount = 0
      private(set) var updates: [String] = []
      /// The two halves as they arrived. A sink that draws them in separate
      /// places (the note page does) sees this, not the composed string.
      private(set) var splits: [(committed: String, tentative: String)] = []
      private(set) var finished: (text: String, trailingSpace: Bool)?
      private(set) var cancelledCount = 0

      func beginStreamingInsertion() {
         beganCount += 1
      }

      func updateStreamingInsertion(committed: String, tentative: String) async throws {
         // Compose exactly like the coordinator's display path so the existing
         // string-level assertions keep testing the same user-visible output.
         updates.append(
            StreamingRefinementCoordinator.composeDisplay(
               committed: committed, tentative: tentative
            )
            .trimmingCharacters(in: .whitespacesAndNewlines)
         )
         splits.append((committed, tentative))
      }

      var lastSplit: (committed: String, tentative: String)? { splits.last }

      func finishStreamingInsertion(finalText: String, appendTrailingSpace: Bool) async throws {
         finished = (finalText, appendTrailingSpace)
      }

      func cancelStreamingInsertion() async {
         cancelledCount += 1
      }

      /// The longest displayed string across all updates — useful as a proxy for "what
      /// the user ultimately saw" when ordering doesn't matter.
      var lastUpdate: String? { updates.last }
   }

   @MainActor
   final class FakeCommitObserver: StreamingRefinementCommitObserver {
      private(set) var committedTexts: [String] = []
      /// Every spans array as it arrived, so a test can assert the labelling
      /// moved at the commit it was supposed to move at.
      private(set) var spanUpdates: [[LiveTranscriptSpan]] = []
      /// Whether each commit closed a paragraph at a boundary the engine
      /// produced. Only those may carry a pending channel handover.
      private(set) var engineBoundaryFlags: [Bool] = []

      func streamingRefinementCoordinator(
         _ coordinator: StreamingRefinementCoordinator,
         didCommitText committedText: String,
         spans: [LiveTranscriptSpan],
         reachedEngineBoundary: Bool
      ) {
         committedTexts.append(committedText)
         spanUpdates.append(spans)
         engineBoundaryFlags.append(reachedEngineBoundary)
      }

      var latestSpans: [LiveTranscriptSpan] { spanUpdates.last ?? [] }

      /// The committed text rebuilt from the spans, as section 3.7's invariant
      /// states it: the text spans joined by newline, plus the trailing boundary
      /// the artifact path appends when no paragraph is open.
      func rebuiltCommittedText(from spans: [LiveTranscriptSpan], isParagraphOpen: Bool) -> String {
         spans.filter(\.isText).map(\.text).joined(separator: "\n")
            + (isParagraphOpen ? "" : "\n")
      }
   }

   /// A streaming-diarizer slot, the only key `relabelSpeaker` accepts.
   private func slotSpeaker(
      _ number: Int,
      displayName: String? = nil,
      tier: LiveSpeakerTier = .provisional
   ) -> LiveSpeakerRef {
      LiveSpeakerRef(
         key: "slot.\(number)",
         tier: tier,
         slotNumber: number,
         displayName: displayName
      )
   }

   // MARK: - Helpers

   /// Convenience: idle commit disabled (-1 → 0 nanoseconds via max), stop wait short.
   private func makeCoordinator(
      stopWaitNs: UInt64 = 60_000_000,
      idleCommitNs: UInt64 = 0
   ) -> StreamingRefinementCoordinator {
      StreamingRefinementCoordinator(
         stopWaitNanoseconds: stopWaitNs,
         idleCommitNanoseconds: idleCommitNs
      )
   }

   // MARK: - Session lifecycle

   @Test func beginSessionCallsSinkBegin() async throws {
      let sink = FakeSink()
      let coord = makeCoordinator()

      coord.beginSession(outputSink: sink)

      #expect(sink.beganCount == 1)
   }

   @Test func endSessionIsIdempotent() {
      let sink = FakeSink()
      let coord = makeCoordinator()
      coord.beginSession(outputSink: sink)

      coord.endSession()
      coord.endSession()  // should not crash or re-log
   }

   @Test func artifactOnlySessionReportsCommittedTextWithoutOutputSink() async throws {
      let observer = FakeCommitObserver()
      let coord = makeCoordinator()
      coord.beginSession(commitObserver: observer, preservesArtifactParagraphs: true)

      await coord.ingestPartial("hello")
      #expect(observer.committedTexts.isEmpty)

      await coord.ingestFinal("hello world")
      let finalText = try await coord.finishSession(appendTrailingSpace: false)

      #expect(finalText == "Hello world")
      #expect(observer.committedTexts == ["Hello world\n"])
   }

   @Test func commitObserverNeverReceivesTentativeText() async {
      let observer = FakeCommitObserver()
      let coord = makeCoordinator()
      coord.beginSession(commitObserver: observer, preservesArtifactParagraphs: true)

      await coord.ingestPartial("tentative text")
      await coord.ingestPartial("tentative text that is still changing")

      #expect(observer.committedTexts.isEmpty)
   }

   @Test func commitObserverReceivesOrderedCumulativeText() async {
      let observer = FakeCommitObserver()
      let coord = makeCoordinator()
      coord.beginSession(commitObserver: observer, preservesArtifactParagraphs: true)

      // LocalAgreement-2 commits "one".
      await coord.ingestPartial("one")
      await coord.ingestPartial("one two")
      await coord.ingestPartial("one two three")
      await coord.ingestPartial("one two three four")

      // EOU commits the extension, and the final drain commits its later tentative tail.
      await coord.ingestFinal("one two three four five")
      await coord.ingestPartial("one two three four five six")
      _ = await coord.awaitFinalTextAndDrain()

      #expect(observer.committedTexts == [
         "One",
         "One two three four five\n",
         "One two three four five\nSix",
      ])
   }

   @Test func idleCommitReportsCumulativeCommittedText() async throws {
      let observer = FakeCommitObserver()
      let coord = makeCoordinator(idleCommitNs: 80_000_000)
      coord.beginSession(commitObserver: observer, preservesArtifactParagraphs: true)

      await coord.ingestPartial("thinking about something")
      #expect(observer.committedTexts.isEmpty)

      try await Task.sleep(nanoseconds: 200_000_000)

      #expect(observer.committedTexts == ["Thinking about something\n"])
   }

   @Test func commitObserverSuppressesDuplicateCommittedText() async {
      let observer = FakeCommitObserver()
      let coord = makeCoordinator()
      coord.beginSession(commitObserver: observer, preservesArtifactParagraphs: true)

      await coord.ingestFinal("hello")
      await coord.ingestFinal("hello")
      _ = await coord.awaitFinalTextAndDrain()

      #expect(observer.committedTexts == ["Hello\n"])
   }

   @Test func commitObserverDoesNotChangeOutputSinkBehavior() async throws {
      let sink = FakeSink()
      let observer = FakeCommitObserver()
      let coord = makeCoordinator()
      coord.beginSession(outputSink: sink, commitObserver: observer)

      await coord.ingestPartial("hello")
      #expect(sink.lastUpdate == "Hello")
      #expect(observer.committedTexts.isEmpty)

      _ = try await coord.finishSession(appendTrailingSpace: true)

      #expect(sink.finished?.text == "Hello")
      #expect(sink.finished?.trailingSpace == true)
      #expect(observer.committedTexts == ["Hello"])
   }

   @Test func artifactFinalUtterancesBecomeParagraphsWithoutChangingFinalOutput() async throws {
      let observer = FakeCommitObserver()
      let coord = makeCoordinator()
      coord.beginSession(commitObserver: observer, preservesArtifactParagraphs: true)

      await coord.ingestFinal("first thought")
      await coord.ingestFinal("first thought second thought")
      let finalText = try await coord.finishSession(appendTrailingSpace: false)

      #expect(observer.committedTexts == [
         "First thought\n",
         "First thought\nSecond thought\n",
      ])
      #expect(finalText == "First thought\nSecond thought")
      #expect(observer.spanUpdates.map { $0.map(\.text) } == [
         ["First thought"],
         ["First thought", "Second thought"],
      ])
      #expect(observer.latestSpans.allSatisfy { $0.speaker == .currentUser })
      #expect(observer.latestSpans.allSatisfy { $0.boundaryReason == .endOfUtterance })
   }

   @Test func artifactFinalAddsABoundaryAfterAgreementAlreadyCommittedTheSentence() async {
      let observer = FakeCommitObserver()
      let coord = makeCoordinator()
      coord.beginSession(commitObserver: observer, preservesArtifactParagraphs: true)

      await coord.ingestPartial("first thought.")
      await coord.ingestPartial("first thought.")
      await coord.ingestFinal("first thought.")

      #expect(observer.committedTexts == ["First thought.", "First thought.\n"])
      #expect(observer.spanUpdates.map { $0.map(\.text) } == [
         ["First thought."],
         ["First thought."],
      ])
      #expect(observer.latestSpans.first?.boundaryReason == .endOfUtterance)
   }

   @Test func artifactIdleAddsABoundaryAfterAgreementAlreadyCommittedTheSentence() async throws {
      let observer = FakeCommitObserver()
      let coord = makeCoordinator(idleCommitNs: 80_000_000)
      coord.beginSession(commitObserver: observer, preservesArtifactParagraphs: true)

      await coord.ingestPartial("first thought.")
      await coord.ingestPartial("first thought.")
      try await Task.sleep(nanoseconds: 200_000_000)

      #expect(observer.committedTexts == ["First thought.", "First thought.\n"])
      #expect(observer.spanUpdates.map { $0.map(\.text) } == [
         ["First thought."],
         ["First thought."],
      ])
      #expect(observer.latestSpans.first?.boundaryReason == .idlePause)
   }

   @Test func observerDoesNotAddParagraphsToAnOutputSession() async {
      let sink = FakeSink()
      let observer = FakeCommitObserver()
      let coord = makeCoordinator()
      coord.beginSession(outputSink: sink, commitObserver: observer)

      await coord.ingestFinal("first thought")
      await coord.ingestFinal("first thought second thought")

      #expect(sink.lastUpdate == "First thought second thought")
      #expect(observer.committedTexts == ["First thought", "First thought second thought"])
      // Dictation has one speaker and no paragraph structure to carry, so it
      // allocates no spans at all.
      #expect(observer.spanUpdates.allSatisfy { $0.isEmpty })
   }

   // MARK: - Live attribution spans

   @Test func spansRebuildTheCommittedTextIncludingItsTrailingBoundary() async throws {
      let observer = FakeCommitObserver()
      let coord = makeCoordinator()
      coord.beginSession(commitObserver: observer, preservesArtifactParagraphs: true)

      await coord.ingestFinal("first thought")
      // A paragraph opened by LocalAgreement is still open, so its rebuild takes
      // no trailing newline. The naive join is false on day one, which is why
      // the invariant carries the trailing-boundary term.
      await coord.ingestPartial("first thought second thought and")
      await coord.ingestPartial("first thought second thought and more")
      await coord.ingestPartial("first thought second thought and more words")
      await coord.markDroppedSpeech(speaker: .systemChannel, startOffset: 3, duration: 1.5)
      await coord.ingestFinal("first thought second thought and more words here")

      #expect(observer.committedTexts.count == observer.spanUpdates.count)
      var sawOpenParagraph = false
      var sawClosedParagraph = false
      for (committed, spans) in zip(observer.committedTexts, observer.spanUpdates) {
         let isParagraphOpen = !committed.hasSuffix("\n")
         if isParagraphOpen { sawOpenParagraph = true } else { sawClosedParagraph = true }
         #expect(observer.rebuiltCommittedText(from: spans, isParagraphOpen: isParagraphOpen) == committed)
      }
      #expect(sawOpenParagraph)
      #expect(sawClosedParagraph)
   }

   @Test func aChannelChangeStartsANewSpanAndANewTurn() async throws {
      let observer = FakeCommitObserver()
      let coord = makeCoordinator()
      coord.beginSession(
         commitObserver: observer,
         preservesArtifactParagraphs: true,
         initialSpeaker: .systemChannel
      )

      await coord.ingestFinal("they said this")
      await coord.markBoundary(.channelChange, speaker: .currentUser)
      await coord.ingestFinal("they said this and then I answered")

      let spans = observer.latestSpans
      #expect(spans.map(\.text) == ["They said this", "And then I answered"])
      #expect(spans.map(\.speaker) == [.systemChannel, .currentUser])
      #expect(spans.first?.boundaryReason == .channelChange)
   }

   @Test func aChannelChangeWithNothingPendingStillOpensANewSpan() async throws {
      let observer = FakeCommitObserver()
      let coord = makeCoordinator()
      coord.beginSession(
         commitObserver: observer,
         preservesArtifactParagraphs: true,
         initialSpeaker: .systemChannel
      )

      // The handover lands during silence: the paragraph was already closed by
      // the final that preceded it, so there is nothing to close.
      await coord.ingestFinal("they said this")
      await coord.markBoundary(.channelChange, speaker: .currentUser)
      await coord.markBoundary(.channelChange, speaker: .systemChannel)
      await coord.markBoundary(.channelChange, speaker: .currentUser)
      await coord.ingestFinal("they said this and then I answered")

      let spans = observer.latestSpans
      #expect(spans.count == 2)
      #expect(spans.map(\.speaker) == [.systemChannel, .currentUser])
   }

   @Test func everythingCommittedBeforeAHandoverStaysWithTheOutgoingSpeaker() async throws {
      let observer = FakeCommitObserver()
      let coord = makeCoordinator()
      coord.beginSession(
         commitObserver: observer,
         preservesArtifactParagraphs: true,
         initialSpeaker: .systemChannel
      )

      await coord.ingestFinal("one two")
      await coord.ingestFinal("one two three four")
      let beforeHandover = observer.latestSpans.map(\.text)
      await coord.markBoundary(.channelChange, speaker: .currentUser)
      await coord.ingestFinal("one two three four five six")

      let spans = observer.latestSpans
      // Attribution is by commit ordering, with no timestamp anywhere: every
      // character committed before the boundary belongs to the outgoing channel.
      #expect(spans.filter { $0.speaker == .systemChannel }.map(\.text) == beforeHandover)
      #expect(spans.filter { $0.speaker == .currentUser }.map(\.text) == ["Five six"])
   }

   @Test func aChannelChangeStampsTheNewTurnStartTime() async throws {
      let observer = FakeCommitObserver()
      let coord = makeCoordinator()
      coord.beginSession(
         commitObserver: observer,
         preservesArtifactParagraphs: true,
         initialSpeaker: .systemChannel
      )

      await coord.ingestFinal("one two")
      await coord.markBoundary(.channelChange, speaker: .currentUser, at: 12.5)
      await coord.ingestFinal("one two three four")

      let spans = observer.latestSpans
      // The first turn opened with the capture. Every turn after it carries the
      // capture time its channel took the engine at, which is the anchor a
      // reader scrolling back needs. The time never decides attribution: that is
      // still exact by commit ordering.
      #expect(spans.first(where: { $0.speaker == .systemChannel })?.startOffset == 0)
      #expect(spans.first(where: { $0.speaker == .currentUser })?.startOffset == 12.5)
   }

   @Test func endOfUtteranceMakesAParagraphNotATurn() async throws {
      let observer = FakeCommitObserver()
      let coord = makeCoordinator()
      coord.beginSession(commitObserver: observer, preservesArtifactParagraphs: true)

      await coord.ingestFinal("first thought")
      await coord.ingestFinal("first thought second thought")

      let spans = observer.latestSpans
      #expect(spans.count == 2)
      #expect(Set(spans.map(\.speaker.key)).count == 1)
      #expect(spans.first?.boundaryReason == .endOfUtterance)
   }

   @Test func idlePauseMakesAParagraphNotATurn() async throws {
      let observer = FakeCommitObserver()
      let coord = makeCoordinator(idleCommitNs: 80_000_000)
      coord.beginSession(commitObserver: observer, preservesArtifactParagraphs: true)

      await coord.ingestPartial("first thought")
      try await Task.sleep(nanoseconds: 200_000_000)
      await coord.ingestPartial("second thought")
      try await Task.sleep(nanoseconds: 200_000_000)

      let spans = observer.latestSpans
      #expect(spans.count == 2)
      #expect(Set(spans.map(\.speaker.key)).count == 1)
      #expect(spans.allSatisfy { $0.boundaryReason == .idlePause })
   }

   @Test func aDroppedSpeechMarkerAddsNoCharactersToTheCommittedText() async throws {
      let observer = FakeCommitObserver()
      let coord = makeCoordinator()
      coord.beginSession(commitObserver: observer, preservesArtifactParagraphs: true)

      await coord.ingestFinal("I was talking")
      let committedBefore = try #require(observer.committedTexts.last)
      await coord.markDroppedSpeech(speaker: .systemChannel, startOffset: 12, duration: 2.5)

      #expect(observer.committedTexts.last == committedBefore)
      let spans = observer.latestSpans
      #expect(spans.count == 2)
      let marker = try #require(spans.last)
      #expect(marker.kind == .droppedSpeech)
      #expect(marker.text.isEmpty)
      #expect(marker.speaker == .systemChannel)
      #expect(marker.startOffset == 12)
      #expect(marker.duration == 2.5)
      // The checkpoint's prefix-monotonic contract cannot be broken by a marker,
      // because the marker adds no characters.
      #expect(
         observer.rebuiltCommittedText(from: spans, isParagraphOpen: false)
            == observer.committedTexts.last
      )
   }

   @Test func relabelSpeakerChangesLabelsAndNeverText() async throws {
      let observer = FakeCommitObserver()
      let coord = makeCoordinator()
      let slot = slotSpeaker(2)
      coord.beginSession(
         commitObserver: observer,
         preservesArtifactParagraphs: true,
         initialSpeaker: slot
      )

      await coord.ingestFinal("first thought")
      await coord.markDroppedSpeech(speaker: slot, startOffset: 4, duration: 1.5)
      let textBefore = observer.latestSpans.map(\.text)
      let committedBefore = observer.committedTexts.last

      let named = slotSpeaker(2, displayName: "Dana", tier: .named)
      await coord.relabelSpeaker(slotKey: "slot.2", to: named)

      let spans = observer.latestSpans
      #expect(spans.map(\.text) == textBefore)
      #expect(observer.committedTexts.last == committedBefore)
      #expect(spans.allSatisfy { $0.speaker == named })
   }

   @Test func relabelSpeakerRejectsAChannelKey() async throws {
      let observer = FakeCommitObserver()
      let coord = makeCoordinator()
      coord.beginSession(
         commitObserver: observer,
         preservesArtifactParagraphs: true,
         initialSpeaker: .systemChannel
      )

      await coord.ingestFinal("first thought")
      let updateCount = observer.spanUpdates.count

      // One channel key can cover several people, so promoting it would put one
      // name on everyone the far end sent.
      await coord.relabelSpeaker(slotKey: LiveSpeakerRef.systemChannel.key, to: slotSpeaker(1))

      #expect(observer.spanUpdates.count == updateCount)
      #expect(observer.latestSpans.allSatisfy { $0.speaker == .systemChannel })
   }

   @Test func aSessionWithOneChannelProducesOneTurn() async throws {
      let observer = FakeCommitObserver()
      let coord = makeCoordinator()
      coord.beginSession(commitObserver: observer, preservesArtifactParagraphs: true)

      await coord.ingestFinal("first thought")
      await coord.ingestFinal("first thought second thought")
      await coord.ingestFinal("first thought second thought third thought")

      let spans = observer.latestSpans
      #expect(spans.count == 3)
      #expect(Set(spans.map(\.speaker.key)) == [LiveSpeakerRef.currentUser.key])
      #expect(spans.allSatisfy { $0.speaker.isCurrentUser })
   }

   // MARK: - Raw-offset stamps

   @Test func anArtifactSessionStampsEveryCommitWithTheReportedCaptureTime() async throws {
      let coord = makeCoordinator()
      coord.beginSession(preservesArtifactParagraphs: true)

      await coord.ingestFinal("first thought", captureTime: 4)
      await coord.ingestFinal("first thought second thought", captureTime: 9)

      #expect(coord.stamps.map(\.captureTime) == [4, 9])
      #expect(coord.stamps.map(\.rawOffset) == [13, 28])
   }

   @Test func aStampIsOnlyKeptWhenTheEmissionCarriedAWatermark() async throws {
      let coord = makeCoordinator()
      coord.beginSession(preservesArtifactParagraphs: true)

      // No ownership run yet, so the consumer has nothing to convert against.
      await coord.ingestFinal("first thought")
      #expect(coord.stamps.isEmpty)

      await coord.ingestFinal("first thought second thought", captureTime: 6)
      #expect(coord.stamps == [
         StreamingRefinementCoordinator.RawOffsetStamp(
            rawOffset: 28,
            captureTime: 6,
            // The committed length is where a late boundary cuts. It counts the
            // paragraph boundary this final appended, which is why it is one
            // character past the raw offset.
            committedLength: 29
         )
      ])
   }

   @Test func stampsStayOrderedWhenAWatermarkRepeatsOrGoesBackwards() async throws {
      let coord = makeCoordinator()
      coord.beginSession(preservesArtifactParagraphs: true)

      await coord.ingestFinal("first thought", captureTime: 5)
      // An idle commit carries no emission of its own, so it stamps against the
      // last watermark that arrived. A backwards watermark cannot be trusted
      // either: a binary search is only valid over a non-decreasing key.
      await coord.ingestFinal("first thought second thought", captureTime: 2)
      await coord.ingestFinal("first thought second thought third thought", captureTime: 11)

      #expect(coord.stamps.map(\.captureTime) == [5, 11])
      #expect(coord.stamps.map(\.rawOffset) == [28, 42])
      #expect(coord.stamps.map(\.captureTime) == coord.stamps.map(\.captureTime).sorted())
      #expect(coord.stamps.map(\.rawOffset) == coord.stamps.map(\.rawOffset).sorted())
   }

   // MARK: - The dictation path is unchanged

   @Test func aDictationSessionRecordsNoStamps() async throws {
      let sink = FakeSink()
      let coord = makeCoordinator()
      coord.beginSession(outputSink: sink)

      await coord.ingestPartial("the quick brown fox", captureTime: 1)
      await coord.ingestFinal("the quick brown fox jumps", captureTime: 2)

      #expect(coord.stamps.isEmpty)
      #expect(sink.lastUpdate == "The quick brown fox jumps")
   }

   @Test func anOutputSessionProducesNoSpans() async throws {
      let sink = FakeSink()
      let observer = FakeCommitObserver()
      let coord = makeCoordinator()
      coord.beginSession(outputSink: sink, commitObserver: observer)

      await coord.ingestFinal("first thought")
      await coord.ingestFinal("first thought second thought")

      #expect(!observer.committedTexts.isEmpty)
      #expect(observer.spanUpdates.allSatisfy { $0.isEmpty })
   }

   @Test func anOutputSessionEmitsNoBoundariesBeyondTheEngineOwnPauses() async throws {
      let sink = FakeSink()
      let observer = FakeCommitObserver()
      let coord = makeCoordinator()
      coord.beginSession(outputSink: sink, commitObserver: observer)

      await coord.ingestFinal("first thought")
      let committedBefore = observer.committedTexts
      // Dictation is microphone only, so the arbiter never issues a handover and
      // never reports cross-talk loss. Calling either anyway changes nothing.
      await coord.markBoundary(.channelChange, speaker: .systemChannel)
      await coord.markDroppedSpeech(speaker: .systemChannel, startOffset: 1, duration: 3)

      #expect(observer.committedTexts == committedBefore)
      #expect(observer.spanUpdates.allSatisfy { $0.isEmpty })
      #expect(sink.lastUpdate == "First thought")
   }

   @Test func dictationCommittedAndTentativeTextIsByteIdenticalAcrossTheRefactor() async throws {
      let sink = FakeSink()
      let observer = FakeCommitObserver()
      let coord = makeCoordinator()
      coord.beginSession(outputSink: sink, commitObserver: observer)

      await coord.ingestPartial("the quick brown")
      await coord.ingestPartial("the quick brown fox")
      await coord.ingestPartial("the quick brown fox jumps")
      await coord.ingestFinal("the quick brown fox jumps over")
      await coord.ingestPartial("the quick brown fox jumps over the lazy")

      let split = try #require(sink.lastSplit)
      #expect(split.committed == "The quick brown fox jumps over")
      #expect(split.tentative == " the lazy")
      #expect(observer.committedTexts.last == "The quick brown fox jumps over")
      #expect(sink.lastUpdate == "The quick brown fox jumps over the lazy")
   }

   // MARK: - Cumulative partials drive tentative display

   @Test func partialsAppearAsTentativeDisplay() async throws {
      let sink = FakeSink()
      let coord = makeCoordinator()
      coord.beginSession(outputSink: sink)

      await coord.ingestPartial("hello")
      await coord.ingestPartial("hello world")

      // Deterministic cleaner capitalizes the leading letter.
      #expect(sink.lastUpdate == "Hello world")
   }

   // MARK: - LocalAgreement-2 commit rule

   @Test func localAgreementCommitsTokenAfterTwoPartialsPlusK() async throws {
      let sink = FakeSink()
      let coord = makeCoordinator()
      coord.beginSession(outputSink: sink)

      // Single partial — no prior history to agree with — nothing committed.
      await coord.ingestPartial("one")
      // Agreement on "one" but only 0 tokens past it — still K=2 short.
      await coord.ingestPartial("one two")
      // Agreement on "one two" but only 1 token past — still K=2 short.
      await coord.ingestPartial("one two three")
      // Now "one" is 2 tokens back from "four" — commits.
      await coord.ingestPartial("one two three four")

      #expect(sink.lastUpdate == "One two three four")

      // Final drain so we can verify committed prefix is "One" (3 chars worth in raw,
      // with cleanup capitalization applied).
      let finalText = await coord.awaitFinalTextAndDrain()
      #expect(finalText == "One two three four")
   }

   @Test func localAgreementIgnoresMismatchedPartial() async throws {
      let sink = FakeSink()
      let coord = makeCoordinator()
      coord.beginSession(outputSink: sink)

      await coord.ingestPartial("hello")
      // Second partial disagrees — no commit possible.
      await coord.ingestPartial("goodbye world")
      // Third partial disagrees with both prior — still no commit.
      await coord.ingestPartial("foo bar baz")

      // Only the final tentative is visible. Committed is still empty.
      #expect(sink.lastUpdate == "Foo bar baz")
   }

   @Test func sentenceBoundaryCommitsWithoutWaitingForK() async throws {
      let sink = FakeSink()
      let coord = makeCoordinator()
      coord.beginSession(outputSink: sink)

      // Two agreeing partials ending in `.` — commit the whole agreement immediately.
      await coord.ingestPartial("hello world.")
      await coord.ingestPartial("hello world. next")

      // "hello world." is already committed (2 tokens, both agreed, last ends with `.`).
      // Further partials that extend must not rewrite that prefix.
      await coord.ingestPartial("hello world. next sentence")

      #expect(sink.lastUpdate == "Hello world. Next sentence")
   }

   // MARK: - Committed text is append-only

   @Test func committedTextIsNeverRewrittenByNewPartials() async throws {
      let sink = FakeSink()
      let coord = makeCoordinator()
      coord.beginSession(outputSink: sink)

      // Drive enough partials to commit "one":
      await coord.ingestPartial("one")
      await coord.ingestPartial("one two")
      await coord.ingestPartial("one two three")
      await coord.ingestPartial("one two three four")

      let displayedAfterCommit = sink.lastUpdate
      #expect(displayedAfterCommit == "One two three four")

      // Now send a new partial that DISAGREES about the later tokens. The committed "One"
      // must stay; the tentative portion can rewrite freely.
      await coord.ingestPartial("one five six seven eight nine")

      let afterRewrite = sink.lastUpdate ?? ""
      // Committed prefix "One" is preserved.
      #expect(afterRewrite.hasPrefix("One "))
      // The rewritten tail made it in.
      #expect(afterRewrite.contains("five six seven"))
   }

   @Test func displayPreservesSpaceWhenTentativeTailLosesLeadingWhitespace() async throws {
      let sink = FakeSink()
      let coord = makeCoordinator()
      coord.beginSession(outputSink: sink)

      await coord.ingestPartial("hello")
      await coord.ingestPartial("hello world")
      await coord.ingestPartial("hello world again")
      await coord.ingestPartial("hello world again today")

      await coord.ingestPartial("helloworld again today tomorrow")

      #expect(sink.lastUpdate == "Hello world again today tomorrow")
   }

   @Test func committedChunksPreserveSpaceWhenCleanedChunkHasNoLeadingWhitespace() async throws {
      let sink = FakeSink()
      let coord = makeCoordinator()
      coord.beginSession(outputSink: sink)

      await coord.ingestFinal("hello")
      await coord.ingestFinal("helloworld")

      let finalText = await coord.awaitFinalTextAndDrain()
      #expect(finalText == "Hello world")
   }

   // MARK: - ingestFinal (EOU) commits everything

   @Test func ingestFinalCommitsAllText() async throws {
      let sink = FakeSink()
      let coord = makeCoordinator()
      coord.beginSession(outputSink: sink)

      await coord.ingestPartial("hello")
      await coord.ingestFinal("hello world this is final")

      // Everything is committed — a later partial CAN'T downgrade this.
      let finalText = await coord.awaitFinalTextAndDrain()
      #expect(finalText == "Hello world this is final")
   }

   @Test func ingestEmptyFinalClearsState() async throws {
      let sink = FakeSink()
      let coord = makeCoordinator()
      coord.beginSession(outputSink: sink)

      await coord.ingestPartial("some text")
      await coord.ingestFinal("")

      let finalText = await coord.awaitFinalTextAndDrain()
      #expect(finalText == "")
   }

   // MARK: - Idle commit

   @Test func idleTimerCommitsTentativeTailWholesale() async throws {
      let sink = FakeSink()
      // 80 ms idle threshold so the test can wait past it cheaply.
      let coord = makeCoordinator(idleCommitNs: 80_000_000)
      coord.beginSession(outputSink: sink)

      await coord.ingestPartial("thinking about something")

      // Wait beyond the idle threshold.
      try await Task.sleep(nanoseconds: 200_000_000)

      // Drain to ensure the idle-committed state is reflected.
      let finalText = await coord.awaitFinalTextAndDrain()
      #expect(finalText == "Thinking about something")
   }

   // MARK: - Deterministic cleanup is applied

   @Test func fillerTokensAreRemovedInTentativeDisplay() async throws {
      let sink = FakeSink()
      let coord = makeCoordinator()
      coord.beginSession(outputSink: sink)

      await coord.ingestPartial("so um i was thinking")

      #expect(sink.lastUpdate == "So I was thinking")
   }

   @Test func cleanupAppliedToCommittedChunksAtCommitTime() async throws {
      let sink = FakeSink()
      let coord = makeCoordinator()
      coord.beginSession(outputSink: sink)

      // Force commit of a prefix containing filler, via LocalAgreement-2.
      await coord.ingestPartial("um hello there")
      await coord.ingestPartial("um hello there friend")
      await coord.ingestPartial("um hello there friend how")
      await coord.ingestPartial("um hello there friend how are")

      // Final drain includes the full text, all cleaned.
      let finalText = await coord.awaitFinalTextAndDrain()
      // "um" should be removed; first letter capitalized; rest preserved.
      #expect(finalText == "Hello there friend how are")
   }

   // MARK: - Final display equals committed + tentative

   @Test func awaitFinalTextAndDrainReturnsComposedDisplay() async throws {
      let sink = FakeSink()
      let coord = makeCoordinator()
      coord.beginSession(outputSink: sink)

      await coord.ingestPartial("hello")
      await coord.ingestPartial("hello world")

      let finalText = await coord.awaitFinalTextAndDrain()
      #expect(finalText == "Hello world")
   }

   @Test func finishSessionCallsSinkFinishWithTrailingSpaceFlag() async throws {
      let sink = FakeSink()
      let coord = makeCoordinator()
      coord.beginSession(outputSink: sink)
      await coord.ingestPartial("hello world")

      _ = try await coord.finishSession(appendTrailingSpace: true)

      #expect(sink.finished?.text == "Hello world")
      #expect(sink.finished?.trailingSpace == true)
   }

   // MARK: - Cancel

   @Test func cancelSessionAsksSinkToCancel() async throws {
      let sink = FakeSink()
      let coord = makeCoordinator()
      coord.beginSession(outputSink: sink)

      await coord.cancelSession()

      #expect(sink.cancelledCount == 1)
   }

   // MARK: - Integration: simulated long stream

   /// Simulates Parakeet's session-level cumulative stream: partials grow, EOU commits a
   /// checkpoint, further partials continue extending the whole transcript. Asserts the
   /// committed text ends up sane across two sentence boundaries.
   @Test func simulatedLongStreamStaysStable() async throws {
      let sink = FakeSink()
      let coord = makeCoordinator()
      coord.beginSession(outputSink: sink)

      let utteranceA = "hello world how are you doing today"
      var buildup = ""
      for token in utteranceA.split(separator: " ").map(String.init) {
         buildup = buildup.isEmpty ? token : buildup + " " + token
         await coord.ingestPartial(buildup)
      }
      let afterFirst = buildup + "."
      await coord.ingestFinal(afterFirst)

      // Second utterance continues the session-level cumulative stream.
      let utteranceB = "i am doing great thanks for asking"
      for token in utteranceB.split(separator: " ").map(String.init) {
         buildup = buildup + " " + token
         await coord.ingestPartial(buildup)
      }
      let afterSecond = buildup + "."
      await coord.ingestFinal(afterSecond)

      let finalText = await coord.awaitFinalTextAndDrain()

      // Committed output includes both utterances, cleanly capitalized.
      #expect(finalText.hasPrefix("Hello world how are you doing today."))
      #expect(finalText.contains("I am doing great thanks for asking."))
   }

   // MARK: - The split the sink is told about

   // A sink that draws committed text and tentative text in two different
   // places has to be told when the tail moves from one to the other. The
   // composed string does not change when that happens, so a guard that only
   // watches the composition leaves the old tail on screen beside the same
   // words in the committed half, and the person who just stopped talking
   // reads their last few words twice.

   @Test func idleCommitTellsTheSinkTheTentativeTailIsGone() async throws {
      let sink = FakeSink()
      let coord = makeCoordinator(idleCommitNs: 80_000_000)
      coord.beginSession(outputSink: sink)

      await coord.ingestPartial("the last few words")
      try await Task.sleep(nanoseconds: 200_000_000)

      let split = try #require(sink.lastSplit)
      #expect(split.committed == "The last few words")
      #expect(split.tentative.isEmpty)
   }

   @Test func stopDrainTellsTheSinkTheTentativeTailIsGone() async throws {
      let sink = FakeSink()
      let coord = makeCoordinator()
      coord.beginSession(outputSink: sink)

      await coord.ingestPartial("the last few words")
      _ = await coord.awaitFinalTextAndDrain()

      let split = try #require(sink.lastSplit)
      #expect(split.committed == "The last few words")
      #expect(split.tentative.isEmpty)
   }

   @Test func aCommitThatChangesNothingIsStillNotResent() async throws {
      let sink = FakeSink()
      let coord = makeCoordinator()
      coord.beginSession(outputSink: sink)

      await coord.ingestPartial("hello there")
      _ = await coord.awaitFinalTextAndDrain()
      let countAfterDrain = sink.splits.count
      _ = await coord.awaitFinalTextAndDrain()

      #expect(sink.splits.count == countAfterDrain)
   }

   // MARK: - Metrics wiring

   @Test func metricsAreEmittedAtEndSessionForActiveSession() async throws {
      let sink = FakeSink()
      let coord = makeCoordinator()
      coord.beginSession(outputSink: sink)
      await coord.ingestPartial("hello")
      await coord.ingestFinal("hello")

      // Just verifying end-of-session doesn't crash; the actual log output is covered by
      // StreamingStabilityMetricsTests. No user-visible assertion here beyond basic
      // state hygiene.
      coord.endSession()
   }
}
