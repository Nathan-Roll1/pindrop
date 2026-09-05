//
//  CaptureArbiter.swift
//  Pindrop
//
//  Created on 2026-08-22.
//
//  The only seam between `NoteCaptureController` and the application shell.
//
//  Capture admission, the recording/processing flags, the status item, the
//  floating indicator and the batch model all live on `AppCoordinator`. The
//  controller owns the note-capture lifecycle but must not own any of those, so
//  it talks to exactly one protocol and never to the coordinator type. That
//  keeps the controller testable against a stub and keeps a second capture
//  entry point from inventing its own gates.
//

import Foundation
import PindropCore
import PindropSpeech

/// One admitted capture start. Opaque on purpose: the arbiter decides what a
/// claim owns, and the controller only has to give the same value back.
struct CaptureClaim: Equatable, Sendable {
    let id: UInt64

    init(id: UInt64) {
        self.id = id
    }
}

enum CaptureArbiterError: Error, LocalizedError, Equatable {
    case captureBusy

    var errorDescription: String? {
        switch self {
        case .captureBusy:
            localized(
                "Finish the active transcription before starting another one.",
                locale: .autoupdatingCurrent
            )
        }
    }
}

/// The host's view of one note capture.
///
/// Members fall into two groups: admission and lifecycle notifications (the
/// arbitration proper), and the shell collaborators the finalization pipeline
/// cannot run without (the active batch model, transcription options, progress,
/// and where finished output lands).
@MainActor
protocol CaptureArbiter: AnyObject {

    // MARK: - Admission

    /// True when any capture or post-capture work is already running.
    var isCaptureBusy: Bool { get }

    /// True once the host started shutting down or preparing for termination.
    /// Every long capture step re-reads this so a quit never races a start.
    var isCaptureHostStopping: Bool { get }

    /// Admits one capture start, or throws `CaptureArbiterError.captureBusy`.
    func claimCapture() throws -> CaptureClaim

    /// Releases the claim once the start sequence finishes, succeeded or not.
    /// A stale claim is ignored, so a superseded start cannot free a newer one.
    func release(_ claim: CaptureClaim)

    /// Whether this exact claim still owns the start window.
    func isClaimCurrent(_ claim: CaptureClaim) -> Bool

    // MARK: - Lifecycle notifications

    func captureDidBegin(startedAt: Date)
    func captureDidEnterProcessing()
    func captureDidEnd(message: String?)

    /// The capture finished with nothing to transcribe. Silence is not a failure
    /// the person has to dismiss, so the host says so once and moves on.
    func captureDidFinishWithoutSpeech()

    // MARK: - Shell collaborators

    /// The batch model currently loaded, so an assignment that names the same
    /// model does not reload it.
    var activeBatchModelName: String? { get }

    /// Loads and activates the batch model one capture stage was assigned.
    func activateBatchModel(named name: String, providerIdentifier: String) async throws

    /// Transcription options for note-capture batch work (language, vocabulary
    /// bias, preprocessing).
    func captureTranscriptionOptions() -> TranscriptionOptions

    /// One finalization progress report. `detail` is already user-facing.
    func captureDidReportProgress(
        stage: NoteCaptureState.FinalizationStage,
        detail: String,
        errorMessage: String?
    )

    /// The note this capture writes to now exists and can be shown.
    func captureDidCreateNote(id: UUID)

    /// The capture produced this history record.
    func captureDidProduceRecord(id: UUID)

    /// A failure worth surfacing on the host (the coordinator's error banner).
    func captureDidObserveError(_ error: Error)
}
