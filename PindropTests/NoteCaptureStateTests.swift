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
        // A meeting whose offline speaker pass is scheduled, so every row of the
        // pipeline is one this capture runs.
        sut.setOfflineSpeakerPassScheduled(true)
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

        // The same capture with the system channel does run the speaker work,
        // but only once finalize has scheduled the offline pass.
        let meeting = NoteCaptureState()
        meeting.beginStarting(includesSystemAudio: true, origin: .mainWindow)
        meeting.setOfflineSpeakerPassScheduled(true)
        meeting.beginFinalizing(.transcribing(nil))
        #expect(status(of: .diarizing, in: meeting) == .pending)
        #expect(status(of: .matchingSpeakers, in: meeting) == .pending)
    }

    /// The system channel alone does not make the speaker stages run: the model
    /// has to be there and the setting has to be on. Without that, finalize
    /// never reports either stage, and a checklist that ticks them off claims
    /// work the reader did not get.
    @Test func aMeetingWithNoOfflineSpeakerPassProjectsBothSpeakerStagesAsSkipped() throws {
        let sut = NoteCaptureState()
        sut.beginStarting(includesSystemAudio: true, origin: .mainWindow)
        sut.beginFinalizing(.transcribing(0.5))

        #expect(status(of: .diarizing, in: sut) == .skipped)
        #expect(status(of: .matchingSpeakers, in: sut) == .skipped)

        // And they stay skipped once the pipeline has walked past them, rather
        // than turning into a check for work that never ran.
        sut.beginFinalizing(.assembling)
        #expect(status(of: .diarizing, in: sut) == .skipped)
        #expect(status(of: .matchingSpeakers, in: sut) == .skipped)

        sut.complete()
        #expect(status(of: .diarizing, in: sut) == .skipped)
        #expect(status(of: .matchingSpeakers, in: sut) == .skipped)
    }

    /// A capture that failed part way through still has a checklist to draw, and
    /// the failed step is what the page keys the dock on.
    @Test func aFailedCaptureRemembersTheStepItFailedOn() throws {
        let sut = NoteCaptureState()
        sut.beginStarting(includesSystemAudio: false, origin: .mainWindow)
        #expect(sut.failedFinalizationStep == nil)

        sut.beginFinalizing(.transcribing(0.4))
        // Still running: nothing failed yet.
        #expect(sut.failedFinalizationStep == nil)

        sut.fail("The transcription engine went away.")
        #expect(sut.failedFinalizationStep == .transcribing)

        // A capture that failed before finalization has no step to point at.
        let early = NoteCaptureState()
        early.beginStarting(includesSystemAudio: false, origin: .mainWindow)
        early.fail("The microphone was taken.")
        #expect(early.failedFinalizationStep == nil)
    }
}
