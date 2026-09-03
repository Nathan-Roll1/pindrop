//
//  NoteCaptureStateTests.swift
//  PindropTests
//
//  Created on 2026-09-03.
//
//  The finalization checklist is the only thing a reader has to look at between
//  stop and a finished note, so its projection is pinned here rather than in a
//  view test: every branch a long meeting can reach (a failure, a stall, a stage
//  that never runs) has to read honestly without a window.
//

import Foundation
import PindropCore
import Testing

@testable import Pindrop

@MainActor
@Suite
struct NoteCaptureStateTests {

    /// A clock the test moves by hand, so the 45 s stall window is asserted in
    /// microseconds rather than waited out.
    private final class TestClock {
        var now = Date(timeIntervalSince1970: 1_000_000)
        func read() -> Date { now }
    }

    private func status(
        of step: FinalizationStep,
        in state: NoteCaptureState
    ) -> StageStatus? {
        state.finalizationChecklist.first { $0.step == step }?.status
    }

    @Test func aFailedStageProjectsAFailedRowAndLeavesLaterStepsPending() throws {
        let sut = NoteCaptureState()
        sut.beginStarting(includesSystemAudio: true, origin: .mainWindow)
        sut.beginFinalizing(.sealingAudio)
        sut.beginFinalizing(.transcribing(0.4))
        sut.fail("The transcription engine went away.")

        #expect(status(of: .sealingAudio, in: sut) == .done)
        #expect(status(of: .transcribing, in: sut) == .failed("The transcription engine went away."))
        #expect(status(of: .diarizing, in: sut) == .pending)
        #expect(status(of: .matchingSpeakers, in: sut) == .pending)
        #expect(status(of: .assembling, in: sut) == .pending)
        #expect(status(of: .enhancing, in: sut) == .pending)

        // The checklist is the whole pipeline in order, every time.
        #expect(sut.finalizationChecklist.map(\.step) == FinalizationStep.allCases)
    }

    @Test func aStageWithNoProgressForTheStallWindowProjectsTheStallAffordance() throws {
        let clock = TestClock()
        let sut = NoteCaptureState(now: clock.read)
        sut.beginStarting(includesSystemAudio: true, origin: .mainWindow)
        sut.beginFinalizing(.transcribing(0.2))
        #expect(!sut.isFinalizationStalled)

        clock.now += NoteCaptureState.stallWindow - 1
        #expect(!sut.isFinalizationStalled)

        clock.now += 1
        #expect(sut.isFinalizationStalled)

        // Any reported progress means the stage is not stuck, so the window
        // starts over rather than latching for the rest of the capture.
        sut.beginFinalizing(.transcribing(0.3))
        #expect(!sut.isFinalizationStalled)

        // A capture that is not finalizing has no stage to stall on.
        clock.now += NoteCaptureState.stallWindow
        sut.complete()
        #expect(!sut.isFinalizationStalled)
    }

    @Test func aMicrophoneOnlyCaptureProjectsIdentifyingSpeakersAsSkipped() throws {
        let sut = NoteCaptureState()
        sut.beginStarting(includesSystemAudio: false, origin: .mainWindow)
        sut.beginFinalizing(.transcribing(nil))

        #expect(status(of: .diarizing, in: sut) == .skipped)
        // Skipped is never failed: nothing went wrong, the work does not apply.
        #expect(status(of: .diarizing, in: sut) != .pending)
        #expect(status(of: .assembling, in: sut) == .pending)

        // The same capture with the system channel does run the speaker work.
        let meeting = NoteCaptureState()
        meeting.beginStarting(includesSystemAudio: true, origin: .mainWindow)
        meeting.beginFinalizing(.transcribing(nil))
        #expect(status(of: .diarizing, in: meeting) == .pending)
    }
}
