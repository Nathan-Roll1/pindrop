//
//  NoteCaptureController.swift
//  Pindrop
//
//  Created on 2026-08-22.
//
//  The single owner of the note-capture lifecycle: start, live transcription,
//  finish, finalization, generated notes, cancellation, and the shutdown
//  checkpoint.
//
//  Every note capture runs the durable source-separated path, microphone-only
//  captures included. That is what removes the ten-minute cap the in-memory
//  voice-note path had: audio is spooled into sealed chunks as it arrives, so a
//  capture is only bounded by disk. A microphone-only capture creates no
//  system-audio source row, so finalization is never asked to explain a source
//  that recorded nothing.
//
//  The controller talks to the application shell through `CaptureArbiter` only.
//

import AVFoundation
import Foundation
import PindropAI
import PindropCore
import PindropData
import PindropMedia
import PindropSpeech

@MainActor
final class NoteCaptureController {

    // MARK: - Errors

    enum NoteCaptureError: Error, LocalizedError, Equatable {
        case captureAlreadyActive
        case recorderDidNotStart
        case noRetainedSources
        case missingMixedAudio
        case noteUnavailable

        var errorDescription: String? {
            switch self {
            case .captureAlreadyActive:
                localized("A note capture is already running.", locale: .autoupdatingCurrent)
            case .recorderDidNotStart:
                localized("The recorder did not start.", locale: .autoupdatingCurrent)
            case .noRetainedSources:
                localized("No audio was recorded for this note.", locale: .autoupdatingCurrent)
            case .missingMixedAudio:
                localized("The recorded audio could not be prepared for transcription.", locale: .autoupdatingCurrent)
            case .noteUnavailable:
                localized("The note this recording belongs to could not be opened.", locale: .autoupdatingCurrent)
            }
        }
    }

    /// Terminal cancellation cleanup that must be retried rather than lost.
    enum TerminalPersistenceError: Error {
        case cancellation(Error)
    }

    // MARK: - Assignment decisions

    enum CaptureAssignmentExecutionDecision: Equatable {
        case execute
        case skip
    }

    enum LiveArtifactCaptureAdmission: Equatable {
        case capture
        case deactivate
    }

    enum CaptureAssignmentExecutionStep: Equatable {
        case assignmentSnapshot
        case stageCall
    }

    enum NoteGenerationExecutionStep: Equatable {
        case assignmentSnapshot
        case runtimeResolution
        case stageFailureRecorded
        case stageCall
        case rawFallback
    }

    enum MeetingNoteGenerationExecutionDecision: Equatable {
        case skipDisabled
        case skipUnavailable
        case rejectInvalidAssignment
        case resolveRuntime
    }

    enum MeetingNoteGenerationFailure: String, Error, Equatable, Sendable, LocalizedError {
        case assignmentUnavailable = "assignment-unavailable"
        case disabled = "assignment-disabled"
        case unavailable = "assignment-best-effort-unavailable"
        case runtimeUnavailable = "runtime-unavailable"
        case promptUnavailable = "prompt-unavailable"
        case derivationFailed = "source-derivation-failed"
        case generationFailed = "generation-failed"
        case emptyOutput = "empty-output"
        case sourceChanged = "source-changed"
        case saveFailed = "save-failed"
        case generatedNoteDiscoveryFailed = "generated-note-discovery-failed"

        var retryable: Bool {
            switch self {
            case .disabled, .unavailable:
                false
            case .assignmentUnavailable,
                    .runtimeUnavailable,
                    .promptUnavailable,
                    .derivationFailed,
                    .generationFailed,
                    .emptyOutput,
                    .sourceChanged,
                    .saveFailed,
                    .generatedNoteDiscoveryFailed:
                true
            }
        }

        var message: String {
            switch self {
            case .assignmentUnavailable:
                "Meeting note generation assignment was unavailable."
            case .disabled:
                "Meeting note generation was disabled when capture started."
            case .unavailable:
                "Meeting note generation was unavailable when capture started."
            case .runtimeUnavailable:
                "Meeting note generation runtime was unavailable."
            case .promptUnavailable:
                "Meeting note generation prompt was unavailable."
            case .derivationFailed:
                "Meeting note sources could not be derived."
            case .generationFailed:
                "Meeting note generation failed."
            case .emptyOutput:
                "Meeting note generation returned empty content."
            case .sourceChanged:
                "Meeting note sources changed before the generated note could be saved."
            case .saveFailed:
                "Generated meeting note could not be saved."
            case .generatedNoteDiscoveryFailed:
                "Existing generated meeting note could not be verified."
            }
        }

        var errorDescription: String? { message }

        var category: MeetingNoteGenerationFailureCategory {
            switch self {
            case .assignmentUnavailable, .disabled, .unavailable:
                .assignment
            case .runtimeUnavailable, .promptUnavailable:
                .configuration
            case .derivationFailed, .sourceChanged:
                .sourceDerivation
            case .generationFailed, .emptyOutput:
                .providerOutput
            case .saveFailed, .generatedNoteDiscoveryFailed:
                .persistence
            }
        }
    }

    enum MeetingNoteGenerationFailureCategory: String, Equatable {
        case assignment
        case configuration
        case sourceDerivation = "source-derivation"
        case providerOutput = "provider-output"
        case persistence
    }

    // MARK: - Chunk work

    struct MeetingChunkWorkItem: Equatable {
        let sequence: Int
        let chunkID: UUID
        let startOffset: TimeInterval
        let duration: TimeInterval
        let microphone: PindropData.MeetingChunkCheckpoint?
        let systemAudio: PindropData.MeetingChunkCheckpoint?
    }

    enum MeetingChunkWorkItemError: Error, Equatable {
        case duplicateSourceSequence(sourceID: UUID, sequence: Int)
        case mismatchedStartOffset(sequence: Int)
    }

    private struct MeetingSourceSequence: Hashable {
        let sourceID: UUID
        let sequence: Int
    }

    /// One live note capture. `generation` makes ownership exact: a stale task
    /// can never clear or finalize a capture that replaced it.
    private struct NoteCaptureContext {
        let handle: PindropCore.NoteCaptureHandle
        let noteID: UUID
        let spoolPlan: MeetingCaptureSpoolPlan
        let generation: UInt64
        let expectedSpeakerCount: Int?
    }

    // MARK: - Dependencies

    private let audioRecorder: AudioRecorder
    private let streamingSession: StreamingSessionController
    private let captureSessionStore: PindropData.CaptureSessionStore
    private let notesStore: PindropData.NotesStore
    private let historyStore: PindropData.HistoryStore
    private let mediaIngestionService: MediaIngestionService
    private let assignmentResolver: CaptureStageAssignmentResolver
    private let aiEnhancementService: PindropAI.AIEnhancementService
    private let transcriptionService: PindropSpeech.TranscriptionService
    private let settingsStore: SettingsStore
    private let toastService: ToastService
    private unowned let arbiter: any CaptureArbiter

    let state: NoteCaptureState

    // MARK: - Lifecycle state

    private var context: NoteCaptureContext?
    private var generation: UInt64 = 0
    /// The handle of a start still inside its claim window. Retained so a quit
    /// mid-start can cancel exactly that capture.
    private var pendingStartHandle: PindropCore.NoteCaptureHandle?
    /// Retained when terminal cancellation cleanup failed, so the next attempt
    /// retries the same handle instead of leaving orphaned media.
    private var pendingCancellationHandle: PindropCore.NoteCaptureHandle?

    var activeHandle: PindropCore.NoteCaptureHandle? { context?.handle }
    var activeNoteID: UUID? { context?.noteID }
    var isActive: Bool { context != nil }
    var hasPendingStart: Bool { pendingStartHandle != nil }

    init(
        audioRecorder: AudioRecorder,
        streamingSession: StreamingSessionController,
        captureSessionStore: PindropData.CaptureSessionStore,
        notesStore: PindropData.NotesStore,
        historyStore: PindropData.HistoryStore,
        mediaIngestionService: MediaIngestionService,
        assignmentResolver: CaptureStageAssignmentResolver,
        aiEnhancementService: PindropAI.AIEnhancementService,
        transcriptionService: PindropSpeech.TranscriptionService,
        settingsStore: SettingsStore,
        toastService: ToastService,
        arbiter: any CaptureArbiter,
        state: NoteCaptureState
    ) {
        self.audioRecorder = audioRecorder
        self.streamingSession = streamingSession
        self.captureSessionStore = captureSessionStore
        self.notesStore = notesStore
        self.historyStore = historyStore
        self.mediaIngestionService = mediaIngestionService
        self.assignmentResolver = assignmentResolver
        self.aiEnhancementService = aiEnhancementService
        self.transcriptionService = transcriptionService
        self.settingsStore = settingsStore
        self.toastService = toastService
        self.arbiter = arbiter
        self.state = state
        streamingSession.onArtifactLiveTextChanged = { [weak self] text in
            self?.updateLiveTranscript(text)
        }
    }

    // MARK: - Start

    /// Starts one note capture and returns the note it writes to.
    ///
    /// The note is created before audio starts so the person can type into it
    /// immediately, and so a crash one second later still has somewhere to
    /// deliver the recording. The recorded intent is bound to that note in the
    /// same breath.
    @discardableResult
    func startNote(
        request: NoteCaptureRequest,
        origin: CaptureIntentOrigin
    ) async throws -> UUID {
        guard context == nil, !arbiter.isCaptureHostStopping else {
            throw NoteCaptureError.captureAlreadyActive
        }
        let claim = try arbiter.claimCapture()
        defer { arbiter.release(claim) }

        state.beginStarting(includesSystemAudio: request.includeSystemAudio)
        do {
            return try await performStart(request: request, origin: origin, claim: claim)
        } catch {
            if !Self.isTaskCancellation(error) {
                state.fail(error.localizedDescription)
            } else {
                state.reset()
            }
            throw error
        }
    }

    private func performStart(
        request: NoteCaptureRequest,
        origin: CaptureIntentOrigin,
        claim: CaptureClaim
    ) async throws -> UUID {
        try ensureClaimCurrent(claim)

        let startedAt = Date.now
        let preferredInputUID = audioRecorder.currentPreferredInputDeviceUID
            ?? settingsStore.selectedInputDeviceUID
        let microphoneDisplayName = AudioDeviceManager.inputDevices()
            .first(where: { $0.uid == preferredInputUID })?
            .displayName ?? "Microphone"
        // A capture that makes its own note only learns the note identifier once
        // the note is committed, so the intent starts as `newNote` and is bound
        // a moment later. A capture aimed at an existing note says so now.
        let handle = try captureSessionStore.startNoteCapture(
            startedAt: startedAt,
            includeSystemAudio: request.includeSystemAudio,
            intent: CaptureIntentRequest(
                destination: request.noteID == nil ? .newNote : .existingNote,
                destinationNoteID: request.noteID,
                origin: origin
            ),
            microphoneDisplayName: microphoneDisplayName,
            systemAudioDisplayName: request.includeSystemAudio ? "System Audio" : nil
        )
        pendingStartHandle = handle
        state.bindSession(id: handle.sessionID)

        do {
            try ensureClaimCurrent(claim)
            let noteID = try resolveDestinationNote(for: handle, request: request, at: startedAt)
            state.bindNote(id: noteID)

            let assignments = try captureStartAssignments(sessionID: handle.sessionID)
            try ensureClaimCurrent(claim)
            let spoolPlan = try await mediaIngestionService.makeMeetingCaptureSpoolPlan(
                sessionID: handle.sessionID,
                microphoneSourceID: handle.microphoneSourceID,
                systemAudioSourceID: handle.systemAudioSourceID
            )
            try ensureClaimCurrent(claim)

            generation &+= 1
            let context = NoteCaptureContext(
                handle: handle,
                noteID: noteID,
                spoolPlan: spoolPlan,
                generation: generation,
                expectedSpeakerCount: request.expectedSpeakerCount
            )
            self.context = context

            try ensureClaimCurrent(claim)
            let didStartRecording = try await audioRecorder.startMeetingRecording(
                spoolPlan: spoolPlan,
                onChunkSealed: { [weak self] chunk in
                    Task { @MainActor [weak self] in
                        self?.recordSealedChunk(chunk, for: context)
                    }
                }
            )
            try ensureClaimCurrent(claim)
            guard didStartRecording else {
                throw NoteCaptureError.recorderDidNotStart
            }
            try ensureCurrent(context)

            // Audio is already being spooled, so the capture is live now. Live
            // transcription can take seconds to load its engine; the person must
            // not watch a "starting" state while the recorder is running.
            arbiter.captureDidBegin(startedAt: startedAt)
            state.beginCapturing(startedAt: startedAt)
            arbiter.captureDidCreateNote(id: noteID)

            await beginLiveTranscriptionIfAssigned(
                assignments: assignments,
                handle: handle,
                context: context
            )
            try ensureCurrent(context)
            Log.audio.info("Note capture started session=\(handle.sessionID.uuidString)")
            return noteID
        } catch {
            try await handleStartFailure(error, handle: handle, claim: claim)
            throw error
        }
    }

    /// Recovers the durable session after a failed start, then rethrows.
    private func handleStartFailure(
        _ error: Error,
        handle: PindropCore.NoteCaptureHandle,
        claim: CaptureClaim
    ) async throws {
        streamingSession.cancelArtifactCaptureDetached(for: handle)
        guard arbiter.isClaimCurrent(claim) else {
            if context?.handle == handle {
                audioRecorder.resetAudioEngine()
            }
            do {
                try await cancelCapture(handle)
            } catch {
                reportTerminalPersistenceFailure(error)
            }
            throw CancellationError()
        }

        let nsError = error as NSError
        if let context, context.handle == handle {
            if Self.isTaskCancellation(error) {
                try await cancelCapture(handle, activeContext: context)
            } else {
                try captureSessionStore.failMeetingCapture(
                    handle,
                    stage: nil,
                    errorDomain: nsError.domain,
                    errorCode: String(nsError.code),
                    message: error.localizedDescription,
                    at: .now
                )
            }
            clearContext(ifCurrent: context)
        } else {
            try captureSessionStore.failMeetingCapture(
                handle,
                stage: nil,
                errorDomain: nsError.domain,
                errorCode: String(nsError.code),
                message: error.localizedDescription,
                at: .now
            )
        }
    }

    /// The note a capture writes to: the one the request names, or a fresh
    /// anchor note created for this session.
    private func resolveDestinationNote(
        for handle: PindropCore.NoteCaptureHandle,
        request: NoteCaptureRequest,
        at timestamp: Date
    ) throws -> UUID {
        if let noteID = request.noteID {
            guard (try? notesStore.fetch(id: noteID)) != nil else {
                throw NoteCaptureError.noteUnavailable
            }
            _ = try captureSessionStore.ensureMeetingHumanAnchor(
                handle,
                noteID: noteID,
                at: timestamp
            )
            return noteID
        }

        let anchor = try captureSessionStore.ensureMeetingHumanAnchor(
            handle,
            title: localized("Untitled Note", locale: settingsStore.selectedAppLocale.locale),
            at: timestamp
        )
        bindIntentDestination(sessionID: handle.sessionID, noteID: anchor.noteID)
        return anchor.noteID
    }

    /// Starts live transcription when the frozen assignment admits it. A live
    /// stream that cannot start never fails the capture: the durable spool is
    /// what the note is made from.
    private func beginLiveTranscriptionIfAssigned(
        assignments: [CaptureStageAssignment],
        handle: PindropCore.NoteCaptureHandle,
        context: NoteCaptureContext
    ) async {
        guard let liveAssignment = assignments.first(where: { $0.stage == .liveTranscription }),
              Self.liveArtifactCaptureAdmission(for: liveAssignment) == .capture else {
            streamingSession.deactivate()
            state.markLiveTranscriptDegraded()
            return
        }
        let didBegin = await streamingSession.beginArtifactCapture(
            for: handle,
            assignment: liveAssignment
        )
        guard isCurrent(context) else {
            streamingSession.cancelArtifactCaptureDetached(for: handle)
            return
        }
        if !didBegin {
            state.markLiveTranscriptDegraded()
            Log.transcription.warning("Note capture continues without live transcription")
        }
    }

    // MARK: - Stop

    /// Finishes the capture and runs finalization to a completed session.
    ///
    /// `operationGuard` is the caller's staleness check (an explicit cancel, a
    /// superseding operation). It runs between every durable step so a cancelled
    /// finalization stops at a checkpoint rather than half-writing one.
    func stop(operationGuard: (@MainActor () throws -> Void)? = nil) async throws {
        guard let context else {
            throw AudioRecorderError.notRecording
        }
        let guardCurrent: @MainActor () throws -> Void = { [weak self] in
            guard let self else { throw CancellationError() }
            try operationGuard?()
            try self.ensureCurrent(context)
        }

        do {
            state.beginFinalizing(.sealingAudio)
            arbiter.captureDidReportProgress(
                stage: .sealingAudio,
                detail: localized("Sealing the recording.", locale: settingsStore.selectedAppLocale.locale),
                errorMessage: nil
            )
            await streamingSession.finishArtifactCapture(for: context.handle)
            try guardCurrent()
            try captureSessionStore.beginMeetingFinalization(context.handle, at: .now)
            let stopResult = try await audioRecorder.stopMeetingRecording()
            try guardCurrent()
            for chunk in stopResult.sealedChunks {
                recordSealedChunk(chunk, for: context)
            }
            let recovery = try await reconcileArtifacts(
                handle: context.handle,
                spoolPlan: context.spoolPlan,
                operationGuard: guardCurrent
            )
            try guardCurrent()
            try finishSources(
                handle: context.handle,
                artifacts: recovery.sealedChunks,
                recoveryFailures: recovery.failures,
                stopResult: stopResult
            )

            arbiter.captureDidEnterProcessing()
            state.beginFinalizing(.transcribing(nil))
            let recordID = try captureSessionStore.reserveMeetingTranscriptionRecordID(context.handle)
            try await finalize(
                context.handle,
                spoolPlan: context.spoolPlan,
                expectedSpeakerCount: context.expectedSpeakerCount,
                operationGuard: guardCurrent
            )
            try guardCurrent()
            clearContext(ifCurrent: context)
            state.complete()
            // The record notification already posts the success message; a
            // second one here would overwrite it with the same text.
            arbiter.captureDidProduceRecord(id: recordID)
            arbiter.captureDidEnd(message: nil)
        } catch is CancellationError {
            // A lifecycle interruption retains the session for startup recovery.
            // An operation that a newer one superseded must leave the capture to
            // whoever superseded it, so only a still-current operation cancels.
            let operationIsStillCurrent: Bool
            if let operationGuard {
                operationIsStillCurrent = (try? operationGuard()) != nil
            } else {
                operationIsStillCurrent = true
            }
            if isCurrent(context), operationIsStillCurrent {
                do {
                    try await cancelCapture(context.handle, activeContext: context)
                } catch {
                    reportTerminalPersistenceFailure(error)
                    throw error
                }
                state.reset()
                arbiter.captureDidEnd(
                    message: localized("Recording canceled.", locale: settingsStore.selectedAppLocale.locale)
                )
            }
            throw CancellationError()
        } catch {
            // Chunk and history failures are durable and retryable: keep the
            // context so a retry or cancel still owns the exact capture.
            state.fail(error.localizedDescription)
            arbiter.captureDidEnd(message: error.localizedDescription)
            throw error
        }
    }

    // MARK: - Cancel

    /// Terminally cancels the active capture. The caller is responsible for
    /// tearing the recorder down (`resetAudioEngine`), exactly as the cancel
    /// path did before this moved.
    func cancel() async {
        guard let context else { return }
        streamingSession.cancelArtifactCaptureDetached(for: context.handle)
        do {
            try await cancelCapture(context.handle, activeContext: context)
        } catch {
            reportTerminalPersistenceFailure(error)
        }
        state.reset()
        arbiter.captureDidEnd(
            message: localized("Recording canceled.", locale: settingsStore.selectedAppLocale.locale)
        )
    }

    /// Terminal cancellation is exact-handle scoped: a delayed duplicate must
    /// never clear or delete a successor. Active-capture callers tear the
    /// recorder down first.
    func cancelCapture(_ handle: PindropCore.NoteCaptureHandle) async throws {
        try await cancelCapture(handle, activeContext: nil)
    }

    private func cancelCapture(
        _ handle: PindropCore.NoteCaptureHandle,
        activeContext: NoteCaptureContext?
    ) async throws {
        do {
            try captureSessionStore.cancelMeetingCapture(handle, at: .now)
        } catch {
            if pendingCancellationHandle == nil || pendingCancellationHandle == handle {
                pendingCancellationHandle = handle
            }
            throw TerminalPersistenceError.cancellation(error)
        }

        if let activeContext {
            clearContext(ifCurrent: activeContext)
        }
        if pendingStartHandle == handle {
            pendingStartHandle = nil
        }

        do {
            try await mediaIngestionService.removeMeetingCaptureArtifacts(for: handle.sessionID)
        } catch {
            if pendingCancellationHandle == nil || pendingCancellationHandle == handle {
                pendingCancellationHandle = handle
            }
            throw TerminalPersistenceError.cancellation(error)
        }

        if pendingCancellationHandle == handle {
            pendingCancellationHandle = nil
        }
    }

    /// Cancels a start that never became the active capture.
    func cancelPendingStartHandle() async throws {
        guard let handle = pendingCancellationHandle ?? pendingStartHandle else { return }
        guard context?.handle != handle else { return }
        try await cancelCapture(handle, activeContext: nil)
    }

    /// Retains an interrupted capture for startup recovery after an audio
    /// capture failure. The session stays resumable rather than being cancelled.
    func interruptActiveCapture(with failure: Error) {
        guard let context else { return }
        streamingSession.cancelArtifactCaptureDetached(for: context.handle)
        let nsError = failure as NSError
        do {
            try captureSessionStore.interruptMeetingCapture(
                context.handle,
                errorDomain: nsError.domain,
                errorCode: String(nsError.code),
                message: failure.localizedDescription,
                at: .now
            )
            clearContext(ifCurrent: context)
            state.fail(failure.localizedDescription)
        } catch {
            reportTerminalPersistenceFailure(error)
        }
    }

    func reportTerminalPersistenceFailure(_ error: Error) {
        arbiter.captureDidObserveError(error)
        Log.app.error("Note capture terminal cancellation cleanup deferred: \(error)")
    }

    // MARK: - Termination

    /// Seals and inventories an active capture before the app is allowed to quit.
    ///
    /// This must run in the same package as the rest of the lifecycle: a partial
    /// extraction that left the checkpoint behind would make quit-mid-capture
    /// unrecoverable.
    func checkpointForTermination() async {
        do {
            try await cancelPendingStartHandle()
        } catch {
            reportTerminalPersistenceFailure(error)
        }
        guard let context else { return }
        await checkpointInterruption(context)
        clearContext(ifCurrent: context)
        state.reset()
    }

    /// Best-effort synchronous fallback for callers that cannot await
    /// `checkpointForTermination`. It launches no background work: it can only
    /// persist an interruption against the exact handles it already owns.
    func checkpointForSynchronousShutdown() {
        if let handle = pendingStartHandle, handle != context?.handle {
            do {
                try captureSessionStore.interruptMeetingCapture(
                    handle,
                    errorDomain: "Pindrop",
                    errorCode: "lifecycle-sync-shutdown",
                    message: "Note capture was interrupted before startup completed.",
                    at: .now
                )
            } catch {
                reportTerminalPersistenceFailure(error)
            }
            pendingStartHandle = nil
        }
        guard let context else { return }
        streamingSession.cancelArtifactCaptureDetached(for: context.handle)
        do {
            try captureSessionStore.beginMeetingFinalization(context.handle, at: .now)
            try captureSessionStore.interruptMeetingCapture(
                context.handle,
                errorDomain: "Pindrop",
                errorCode: "lifecycle-sync-shutdown",
                message: "Note capture was interrupted before its tail could be sealed.",
                at: .now
            )
        } catch {
            Log.app.warning(
                "Could not persist synchronous note capture interruption: \(error.localizedDescription)"
            )
        }
        self.context = nil
        state.reset()
    }

    private func checkpointInterruption(_ context: NoteCaptureContext) async {
        do {
            try ensureCurrent(context)
            streamingSession.cancelArtifactCaptureDetached(for: context.handle)
            try captureSessionStore.beginMeetingFinalization(context.handle, at: .now)

            let stopResult = try await audioRecorder.stopMeetingRecording()
            try ensureCurrent(context)
            for chunk in stopResult.sealedChunks {
                try ensureCurrent(context)
                try captureSessionStore.recordSealedMeetingChunk(context.handle, chunk: chunk, at: .now)
            }
            let recovery = try await reconcileArtifacts(
                handle: context.handle,
                spoolPlan: context.spoolPlan,
                operationGuard: { try self.ensureCurrent(context) }
            )
            try ensureCurrent(context)
            try finishSources(
                handle: context.handle,
                artifacts: recovery.sealedChunks,
                recoveryFailures: recovery.failures,
                stopResult: stopResult
            )
            try ensureCurrent(context)
            try captureSessionStore.interruptMeetingCapture(
                context.handle,
                errorDomain: "Pindrop",
                errorCode: "lifecycle-shutdown",
                message: "Note capture was interrupted by application shutdown and can be resumed.",
                at: .now
            )
        } catch {
            let nsError = error as NSError
            if isCurrent(context) {
                try? captureSessionStore.interruptMeetingCapture(
                    context.handle,
                    errorDomain: nsError.domain,
                    errorCode: String(nsError.code),
                    message: "Note capture was interrupted during shutdown: \(error.localizedDescription)",
                    at: .now
                )
            }
        }
    }

    // MARK: - Live signals

    func updateAudioLevel(_ level: Float) {
        guard state.isCapturing else { return }
        state.updateLevels(level: level, bands: state.bandLevels)
    }

    func updateBandLevels(_ bands: AudioBandLevels) {
        guard state.isCapturing else { return }
        state.updateLevels(level: state.audioLevel, bands: bands)
    }

    private func updateLiveTranscript(_ text: String) {
        guard state.isActive else { return }
        state.updateLiveTranscript(text)
        if streamingSession.isArtifactLiveTranscriptDegraded {
            state.markLiveTranscriptDegraded()
        }
    }

    // MARK: - Ownership

    private func isCurrent(_ context: NoteCaptureContext) -> Bool {
        generation == context.generation && self.context?.handle == context.handle
    }

    private func ensureCurrent(_ context: NoteCaptureContext) throws {
        try Task.checkCancellation()
        guard !arbiter.isCaptureHostStopping, isCurrent(context) else {
            throw CancellationError()
        }
    }

    private func clearContext(ifCurrent context: NoteCaptureContext) {
        guard isCurrent(context) else { return }
        self.context = nil
        pendingStartHandle = nil
    }

    private func ensureClaimCurrent(_ claim: CaptureClaim) throws {
        try Task.checkCancellation()
        guard arbiter.isClaimCurrent(claim), !arbiter.isCaptureHostStopping else {
            throw CancellationError()
        }
    }

    // MARK: - Durable chunk bookkeeping

    private func recordSealedChunk(
        _ chunk: SealedAudioSourceChunk,
        for context: NoteCaptureContext
    ) {
        guard isCurrent(context), !arbiter.isCaptureHostStopping else { return }
        do {
            try captureSessionStore.recordSealedMeetingChunk(context.handle, chunk: chunk, at: .now)
        } catch {
            // The writer already sealed the artifact durably. Stop and recovery
            // inventory reconcile this advisory callback if its checkpoint was
            // interrupted.
            Log.audio.warning(
                "Deferred note chunk checkpoint \(chunk.sequence): \(error.localizedDescription)"
            )
        }
    }

    func reconcileArtifacts(
        handle: PindropCore.NoteCaptureHandle,
        spoolPlan: MeetingCaptureSpoolPlan,
        operationGuard: () throws -> Void
    ) async throws -> MeetingArtifactRecoveryResult {
        let recovery = try await mediaIngestionService.recoverMeetingArtifacts(for: spoolPlan)
        try operationGuard()
        let failures = recovery.failures.map(Self.chunkFailure(from:))
        try operationGuard()
        try captureSessionStore.reconcileMeetingInventory(
            handle,
            sealedChunks: recovery.sealedChunks,
            failures: failures,
            at: .now
        )
        return recovery
    }

    func finishSources(
        handle: PindropCore.NoteCaptureHandle,
        artifacts: [SealedAudioSourceChunk],
        recoveryFailures: [MeetingArtifactRecoveryFailure] = [],
        stopResult: MeetingRecordingStopResult?
    ) throws {
        let microphoneHasChunks = artifacts.contains { $0.sourceID == handle.microphoneSourceID }
        func sourceUnavailable(for sourceID: UUID) -> MeetingArtifactRecoveryFailure? {
            recoveryFailures.first {
                $0.sourceID == sourceID && $0.kind == .sourceUnavailable
            }
        }
        var failures: [PindropData.FailedMeetingSource] = []
        if !microphoneHasChunks {
            failures.append(Self.sourceFailure(
                sourceID: handle.microphoneSourceID,
                recoveryFailure: sourceUnavailable(for: handle.microphoneSourceID),
                failure: stopResult?.microphoneFailure
            ))
        }
        // A microphone-only capture has no system-audio source row, so there is
        // nothing to explain for it.
        if let systemAudioSourceID = handle.systemAudioSourceID,
           !artifacts.contains(where: { $0.sourceID == systemAudioSourceID }) {
            failures.append(Self.sourceFailure(
                sourceID: systemAudioSourceID,
                recoveryFailure: sourceUnavailable(for: systemAudioSourceID),
                failure: stopResult?.systemAudioFailure
            ))
        }
        try captureSessionStore.finishMeetingSources(handle, sourceFailures: failures, at: .now)
    }

    private static func sourceFailure(
        sourceID: UUID,
        recoveryFailure: MeetingArtifactRecoveryFailure? = nil,
        failure: AudioCaptureSourceFailure?
    ) -> PindropData.FailedMeetingSource {
        if let recoveryFailure {
            return PindropData.FailedMeetingSource(
                sourceID: sourceID,
                errorDomain: "PindropMedia",
                errorCode: String(describing: recoveryFailure.kind),
                message: recoveryFailure.message,
                occurredAt: .now
            )
        }
        if let failure {
            return PindropData.FailedMeetingSource(
                sourceID: sourceID,
                errorDomain: failure.errorDomain,
                errorCode: failure.errorCode,
                message: failure.message,
                occurredAt: .now
            )
        }
        return PindropData.FailedMeetingSource(
            sourceID: sourceID,
            errorDomain: "PindropSpeech.AudioCapture",
            errorCode: "no-durable-chunks",
            message: "The capture source stopped without sealing any durable audio chunks.",
            occurredAt: .now
        )
    }

    private static func chunkFailure(
        from failure: MeetingArtifactRecoveryFailure
    ) -> PindropData.MeetingChunkFailure {
        PindropData.MeetingChunkFailure(
            sourceID: failure.sourceID,
            sequence: failure.sequence,
            stage: .finalTranscription,
            invalidatesSource: failure.kind == .sourceUnavailable,
            errorDomain: "PindropMedia",
            errorCode: String(describing: failure.kind),
            message: failure.message,
            isRetryable: failure.isRetryable,
            occurredAt: .now
        )
    }

    private func resolvedArtifacts(
        _ artifacts: [SealedAudioSourceChunk],
        operationGuard: () throws -> Void
    ) async throws -> [SealedAudioSourceChunk] {
        var resolved: [SealedAudioSourceChunk] = []
        resolved.reserveCapacity(artifacts.count)
        for artifact in artifacts {
            let fileURL = try await mediaIngestionService.resolveArtifactURL(for: artifact)
            try operationGuard()
            resolved.append(SealedAudioSourceChunk(
                sessionID: artifact.sessionID,
                sourceID: artifact.sourceID,
                sequence: artifact.sequence,
                startOffset: artifact.startOffset,
                duration: artifact.duration,
                fileURL: fileURL,
                relativePath: artifact.relativePath,
                byteCount: artifact.byteCount,
                sha256: artifact.sha256
            ))
        }
        return resolved
    }

    private func transcriptionOutput(
        checkpoint: PindropData.MeetingTranscriptionCheckpoint,
        workItem: MeetingChunkWorkItem
    ) -> TranscriptionChunkOutput {
        let segments: [DiarizedTranscriptSegment]? = checkpoint.segmentsJSON.flatMap {
            (encoded: String) -> [DiarizedTranscriptSegment]? in
            guard let data = encoded.data(using: .utf8) else { return nil }
            return try? JSONDecoder().decode([DiarizedTranscriptSegment].self, from: data)
        }
        return TranscriptionChunkOutput(
            chunkID: workItem.chunkID,
            sequence: checkpoint.sequence,
            startOffset: checkpoint.startOffset,
            duration: checkpoint.duration,
            plainText: checkpoint.text,
            diarizedSegments: segments
        )
    }

    // MARK: - Finalization

    /// Runs finalization for one capture, live or recovered.
    func finalize(
        _ handle: PindropCore.NoteCaptureHandle,
        spoolPlan: MeetingCaptureSpoolPlan,
        expectedSpeakerCount: Int?,
        operationGuard: () throws -> Void
    ) async throws {
        try operationGuard()
        let startAssignments = try captureStartAssignments(sessionID: handle.sessionID)
        guard let finalAssignment = startAssignments.first(where: { $0.stage == .finalTranscription }) else {
            throw CaptureStageAssignmentError.missingModelIdentifier(providerKind: .disabled)
        }
        guard let diarizationAssignment = startAssignments.first(where: { $0.stage == .diarization }) else {
            throw CaptureStageAssignmentError.missingModelIdentifier(providerKind: .disabled)
        }
        let plan = try captureSessionStore.makeMeetingFinalizationPlan(handle)
        let workItems = try Self.meetingChunkWorkItems(
            sourceChunks: plan.sourceChunks,
            failedSequences: plan.failedSequences,
            handle: handle
        )
        let needsFinalModelActivation = Self.meetingFinalizationNeedsFinalModelActivation(
            workItems: workItems,
            completedASRSequences: plan.completedASRSequences
        )
        guard let finalModelIdentifier = Self.finalHistoryModelIdentifier(from: finalAssignment) else {
            // The batch stage cannot run. A microphone-only capture still has the
            // committed live text, so the recording is kept rather than lost.
            try await completeFromLiveTranscript(
                handle,
                workItems: workItems,
                operationGuard: operationGuard
            )
            return
        }
        if needsFinalModelActivation {
            try await activateAssignedFinalModel(finalAssignment)
            try operationGuard()
        }

        // Speaker attribution needs at least two voices to be worth its cost. A
        // microphone-only capture is single-speaker by construction, so the
        // stage is skipped cleanly instead of labelling one speaker.
        let diarizationDecision = Self.captureAssignmentExecutionDecision(for: diarizationAssignment)
        let diarizationEnabled = handle.capturesSystemAudio && diarizationDecision == .execute
        if case .bestEffortUnavailable = diarizationAssignment.providerKind {
            try captureSessionStore.recordMeetingFinalizationFailure(
                handle,
                stage: .diarization,
                domain: "PindropSpeech",
                code: "assignment-unavailable",
                message: "Diarization was unavailable at capture assignment and was skipped.",
                retryable: false,
                at: .now
            )
        }
        let recovery = try await mediaIngestionService.recoverMeetingArtifacts(for: spoolPlan)
        try operationGuard()
        let artifacts = try await resolvedArtifacts(recovery.sealedChunks, operationGuard: operationGuard)
        try operationGuard()
        let artifactsBySourceAndSequence = Dictionary(
            uniqueKeysWithValues: artifacts.map {
                (MeetingSourceSequence(sourceID: $0.sourceID, sequence: $0.sequence), $0)
            }
        )
        var outputs: [TranscriptionChunkOutput] = plan.completedASRCheckpoints.compactMap { checkpoint in
            guard let workItem = workItems.first(where: { $0.sequence == checkpoint.sequence }) else {
                return nil
            }
            return transcriptionOutput(checkpoint: checkpoint, workItem: workItem)
        }
        var warningCount = 0

        for workItem in workItems where !plan.completedASRSequences.contains(workItem.sequence) {
            try operationGuard()
            guard Self.shouldCreateMeetingTranscriptionInput(for: workItem) else {
                // `failedSequences` retains the persisted scoped failure as an
                // empty timed window.
                warningCount += 1
                outputs.append(Self.meetingOutputPlaceholder(for: workItem))
                reportTranscribingProgress(
                    handle: handle,
                    completed: outputs.count,
                    total: workItems.count,
                    detail: "Chunk \(workItem.sequence + 1) unavailable; preserving its timed gap.",
                    errorMessage: nil
                )
                continue
            }

            let microphone = workItem.microphone.flatMap {
                artifactsBySourceAndSequence[MeetingSourceSequence(sourceID: $0.sourceID, sequence: $0.sequence)]
            }
            let systemAudio = workItem.systemAudio.flatMap {
                artifactsBySourceAndSequence[MeetingSourceSequence(sourceID: $0.sourceID, sequence: $0.sequence)]
            }
            guard microphone != nil || systemAudio != nil else {
                try captureSessionStore.recordMeetingFinalizationFailure(
                    handle,
                    sequence: workItem.sequence,
                    stage: .finalTranscription,
                    domain: "PindropMedia",
                    code: "missing-meeting-chunk",
                    message: "No deterministic source artifact was found for this note chunk.",
                    retryable: true,
                    at: .now
                )
                warningCount += 1
                outputs.append(Self.meetingOutputPlaceholder(for: workItem))
                reportTranscribingProgress(
                    handle: handle,
                    completed: outputs.count,
                    total: workItems.count,
                    detail: "Chunk \(workItem.sequence + 1) failed; preserving its timed gap.",
                    errorMessage: nil
                )
                continue
            }

            try await transcribeWorkItem(
                workItem,
                microphone: microphone,
                systemAudio: systemAudio,
                handle: handle,
                spoolPlan: spoolPlan,
                finalAssignmentAttempt: finalAssignment.attempt,
                diarizationEnabled: diarizationEnabled,
                expectedSpeakerCount: expectedSpeakerCount,
                outputs: &outputs,
                warningCount: &warningCount,
                totalChunks: workItems.count,
                operationGuard: operationGuard
            )
        }

        try operationGuard()
        let refreshedPlan = try captureSessionStore.makeMeetingFinalizationPlan(handle)
        let missingFinalASRSequences = Self.missingMeetingFinalASRSequences(
            workItems: workItems,
            completedASRSequences: refreshedPlan.completedASRSequences
        )
        guard missingFinalASRSequences.isEmpty else {
            throw CaptureSessionStoreError.meetingCaptureHasIncompleteFinalTranscript(
                sessionID: handle.sessionID,
                sequences: missingFinalASRSequences
            )
        }
        setFinalizingStage(.assembling, for: handle)
        let refreshedOutputs: [TranscriptionChunkOutput] = refreshedPlan.completedASRCheckpoints.compactMap { checkpoint in
            guard let workItem = workItems.first(where: { $0.sequence == checkpoint.sequence }) else {
                return nil
            }
            return transcriptionOutput(checkpoint: checkpoint, workItem: workItem)
        }
        let merged = try transcriptionService.mergeMeetingChunks(
            Self.meetingOutputPlaceholders(workItems: workItems, outputs: refreshedOutputs)
        )
        let finalText = Self.normalizedText(merged.text)
        guard !Self.isEffectivelyEmpty(finalText) else {
            let failure = NoteCaptureError.noRetainedSources
            try captureSessionStore.failMeetingCapture(
                handle,
                stage: .finalTranscription,
                errorDomain: "PindropSpeech",
                errorCode: "no-transcribed-output",
                message: failure.localizedDescription,
                at: .now
            )
            throw failure
        }

        let recordID: UUID
        if let reserved = refreshedPlan.reservedTranscriptionRecordID {
            recordID = reserved
        } else {
            recordID = try captureSessionStore.reserveMeetingTranscriptionRecordID(handle)
        }
        do {
            let record = try historyStore.save(
                text: finalText,
                originalText: nil,
                duration: workItems.map { $0.startOffset + $0.duration }.max() ?? 0,
                modelUsed: finalModelIdentifier,
                enhancedWith: nil,
                diarizationSegmentsJSON: Self.encodeDiarizationSegmentsJSON(merged.diarizedSegments),
                sourceKind: .manualCapture,
                sourceDisplayName: handle.capturesSystemAudio ? "Meeting recording" : "Note recording",
                id: recordID
            )
            try await Self.completeMeetingAfterHistory(
                recordID: record.id,
                operationGuard: operationGuard,
                generateNote: {
                    try await self.generateNoteIfNeeded(handle, operationGuard: operationGuard)
                },
                onGenerationFailure: { failure in
                    self.recordNoteGenerationFailure(
                        failure,
                        handle: handle,
                        attempt: Self.captureAssignmentAttempt(for: .noteGeneration)
                    )
                },
                complete: { transcriptionRecordID in
                    try self.captureSessionStore.completeMeetingCapture(
                        handle,
                        transcriptionRecordID: transcriptionRecordID,
                        at: .now
                    )
                }
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch let failure as MeetingNoteGenerationFailure {
            throw failure
        } catch {
            let nsError = error as NSError
            try? captureSessionStore.recordMeetingHistoryFailure(
                handle,
                errorDomain: nsError.domain,
                errorCode: String(nsError.code),
                message: error.localizedDescription,
                at: .now
            )
            throw error
        }
    }

    /// Completes a capture whose batch transcription stage cannot run, using the
    /// live text that was already committed. Losing a recording because the
    /// final-ASR assignment went away would be the worst possible outcome.
    private func completeFromLiveTranscript(
        _ handle: PindropCore.NoteCaptureHandle,
        workItems: [MeetingChunkWorkItem],
        operationGuard: () throws -> Void
    ) async throws {
        try operationGuard()
        let checkpoint = try? captureSessionStore.latestLiveTranscriptCheckpoint(for: handle)
        let finalText = Self.normalizedText(checkpoint?.committedText ?? "")
        guard !Self.isEffectivelyEmpty(finalText) else {
            let failure = NoteCaptureError.noRetainedSources
            try captureSessionStore.failMeetingCapture(
                handle,
                stage: .finalTranscription,
                errorDomain: "PindropSpeech",
                errorCode: "no-transcribed-output",
                message: failure.localizedDescription,
                at: .now
            )
            throw failure
        }

        setFinalizingStage(.assembling, for: handle)
        // Completion requires one final-ASR revision per sealed chunk. The live
        // engine produced one transcript for the whole capture, so it is
        // attributed to the first window and the rest stay empty rather than
        // inventing text for them.
        for (index, workItem) in workItems.enumerated() {
            _ = try captureSessionStore.recordMeetingTranscriptionChunk(
                handle,
                sourceChunkSequence: workItem.sequence,
                startOffset: workItem.startOffset,
                duration: workItem.duration,
                text: index == 0 ? finalText : "",
                languageCode: settingsStore.selectedAppLanguage.rawValue,
                at: .now
            )
        }
        let plan = try captureSessionStore.makeMeetingFinalizationPlan(handle)
        let recordID: UUID
        if let reserved = plan.reservedTranscriptionRecordID {
            recordID = reserved
        } else {
            recordID = try captureSessionStore.reserveMeetingTranscriptionRecordID(handle)
        }
        let record = try historyStore.save(
            text: finalText,
            originalText: nil,
            duration: workItems.map { $0.startOffset + $0.duration }.max() ?? 0,
            modelUsed: "live-transcription",
            enhancedWith: nil,
            diarizationSegmentsJSON: nil,
            sourceKind: .manualCapture,
            sourceDisplayName: handle.capturesSystemAudio ? "Meeting recording" : "Note recording",
            id: recordID
        )
        try await Self.completeMeetingAfterHistory(
            recordID: record.id,
            operationGuard: operationGuard,
            generateNote: {
                try await self.generateNoteIfNeeded(handle, operationGuard: operationGuard)
            },
            onGenerationFailure: { failure in
                self.recordNoteGenerationFailure(
                    failure,
                    handle: handle,
                    attempt: Self.captureAssignmentAttempt(for: .noteGeneration)
                )
            },
            complete: { transcriptionRecordID in
                try self.captureSessionStore.completeMeetingCapture(
                    handle,
                    transcriptionRecordID: transcriptionRecordID,
                    at: .now
                )
            }
        )
    }

    private func transcribeWorkItem(
        _ workItem: MeetingChunkWorkItem,
        microphone: SealedAudioSourceChunk?,
        systemAudio: SealedAudioSourceChunk?,
        handle: PindropCore.NoteCaptureHandle,
        spoolPlan: MeetingCaptureSpoolPlan,
        finalAssignmentAttempt: Int,
        diarizationEnabled: Bool,
        expectedSpeakerCount: Int?,
        outputs: inout [TranscriptionChunkOutput],
        warningCount: inout Int,
        totalChunks: Int,
        operationGuard: () throws -> Void
    ) async throws {
        let mixed = try await mediaIngestionService.makeMixedMeetingChunk(
            sessionID: handle.sessionID,
            sequence: workItem.sequence,
            microphone: microphone,
            systemAudio: systemAudio
        )
        try operationGuard()
        guard let byteCount = Int(exactly: mixed.byteCount) else {
            await removeMixedChunk(
                mixed,
                handle: handle,
                sequence: workItem.sequence,
                operationGuard: operationGuard
            )
            throw NoteCaptureError.missingMixedAudio
        }
        let input = TranscriptionChunkInput(
            chunkID: workItem.chunkID,
            sequence: workItem.sequence,
            startOffset: workItem.startOffset,
            duration: workItem.duration,
            fileURL: spoolPlan.libraryRootURL.appendingPathComponent(mixed.relativePath),
            byteCount: byteCount,
            sha256: mixed.sha256
        )
        do {
            if diarizationEnabled {
                setFinalizingStage(.diarizing(nil), for: handle)
            }
            let output = try await transcriptionService.transcribeMeetingChunk(
                input,
                options: arbiter.captureTranscriptionOptions(),
                diarizationOptions: .init(expectedSpeakerCount: expectedSpeakerCount),
                diarizationEnabled: diarizationEnabled
            )
            try operationGuard()
            let segmentsJSON = Self.encodeDiarizationSegmentsJSON(output.diarizedSegments)
            try captureSessionStore.recordMeetingTranscriptionChunk(
                handle,
                sourceChunkSequence: output.sequence,
                startOffset: output.startOffset,
                duration: output.duration,
                text: output.plainText,
                segmentsJSON: segmentsJSON,
                languageCode: settingsStore.selectedAppLanguage.rawValue,
                assignmentAttempt: finalAssignmentAttempt,
                at: .now
            )
            outputs.append(output)
            if let warning = output.diarizationWarning {
                warningCount += 1
                try captureSessionStore.recordMeetingFinalizationFailure(
                    handle,
                    sequence: output.sequence,
                    stage: .diarization,
                    domain: "PindropSpeech",
                    code: "best-effort-warning",
                    message: warning,
                    retryable: false,
                    at: .now
                )
            }
            await removeMixedChunk(
                mixed,
                handle: handle,
                sequence: workItem.sequence,
                operationGuard: operationGuard
            )
            reportTranscribingProgress(
                handle: handle,
                completed: outputs.count,
                total: totalChunks,
                detail: "Transcribed \(outputs.count) chunk\(outputs.count == 1 ? "" : "s")\(warningCount == 0 ? "" : "; \(warningCount) warning\(warningCount == 1 ? "" : "s")")",
                errorMessage: nil
            )
        } catch is CancellationError {
            await removeMixedChunk(
                mixed,
                handle: handle,
                sequence: workItem.sequence,
                operationGuard: operationGuard
            )
            throw CancellationError()
        } catch {
            try operationGuard()
            let nsError = error as NSError
            try captureSessionStore.recordMeetingFinalizationFailure(
                handle,
                sequence: workItem.sequence,
                stage: .finalTranscription,
                domain: nsError.domain,
                code: String(nsError.code),
                message: error.localizedDescription,
                retryable: true,
                at: .now
            )
            await removeMixedChunk(
                mixed,
                handle: handle,
                sequence: workItem.sequence,
                operationGuard: operationGuard
            )
            outputs.append(Self.meetingOutputPlaceholder(for: workItem))
            reportTranscribingProgress(
                handle: handle,
                completed: outputs.count,
                total: totalChunks,
                detail: "Chunk \(workItem.sequence + 1) failed; continuing with durable siblings.",
                errorMessage: error.localizedDescription
            )
        }
    }

    private func removeMixedChunk(
        _ mixed: ManagedMixedMeetingChunkArtifact,
        handle: PindropCore.NoteCaptureHandle,
        sequence: Int,
        operationGuard: () throws -> Void
    ) async {
        do {
            try await mediaIngestionService.removeMixedMeetingChunk(mixed)
        } catch {
            guard (try? operationGuard()) != nil else { return }
            let nsError = error as NSError
            try? captureSessionStore.recordMeetingFinalizationFailure(
                handle,
                sequence: sequence,
                stage: .finalTranscription,
                domain: nsError.domain,
                code: String(nsError.code),
                message: "Could not remove derived note chunk: \(error.localizedDescription)",
                retryable: true,
                at: .now
            )
        }
    }

    private func reportTranscribingProgress(
        handle: PindropCore.NoteCaptureHandle,
        completed: Int,
        total: Int,
        detail: String,
        errorMessage: String?
    ) {
        let progress = Self.meetingChunkProgress(completed: completed, total: total)
        setFinalizingStage(.transcribing(progress), for: handle)
        arbiter.captureDidReportProgress(
            stage: .transcribing(progress),
            detail: detail,
            errorMessage: errorMessage
        )
    }

    /// Moves the observable phase only for the capture the UI is showing.
    /// Startup recovery finalizes captures no live state describes.
    private func setFinalizingStage(
        _ stage: NoteCaptureState.FinalizationStage,
        for handle: PindropCore.NoteCaptureHandle
    ) {
        guard state.sessionID == handle.sessionID else { return }
        state.beginFinalizing(stage)
    }

    // MARK: - Assignments

    func captureStartAssignments(sessionID: UUID) throws -> [CaptureStageAssignment] {
        try Self.captureStartAssignmentStages.map { stage in
            try captureAssignment(
                sessionID: sessionID,
                stage: stage,
                attempt: Self.captureAssignmentAttempt(for: stage)
            )
        }
    }

    private func captureAssignment(
        sessionID: UUID,
        stage: CapturePipelineStage,
        attempt: Int
    ) throws -> CaptureStageAssignment {
        let activeBatchModelName = arbiter.activeBatchModelName
        return try captureSessionStore.resolveAssignment(
            sessionID: sessionID,
            stage: stage,
            attempt: attempt
        ) { [assignmentResolver] in
            try assignmentResolver.select(
                stage: stage,
                attempt: attempt,
                activeBatchModelName: activeBatchModelName
            )
        }
    }

    private func activateAssignedFinalModel(_ assignment: CaptureStageAssignment) async throws {
        guard Self.assignedFinalModelNeedsActivation(
            assignment,
            activeModelName: arbiter.activeBatchModelName
        ) else {
            return
        }
        guard let modelName = assignment.modelIdentifier else {
            throw CaptureStageAssignmentResolverError.unknownBatchModel("missing-final-model")
        }
        try await arbiter.activateBatchModel(
            named: modelName,
            providerIdentifier: assignment.providerIdentifier
        )
    }

    /// Binds a `newNote` capture intent to the note the capture just created.
    ///
    /// The bind only improves crash recovery, so a failure never fails the note
    /// the person is recording: it is logged and the capture continues.
    private func bindIntentDestination(sessionID: UUID, noteID: UUID) {
        do {
            try captureSessionStore.updateIntentDestination(sessionID: sessionID, noteID: noteID)
        } catch {
            Log.app.warning(
                "Failed to bind capture intent to its note: \(error.localizedDescription)"
            )
        }
    }

    // MARK: - Generated note

    /// Generates the enhanced note for a finished capture.
    ///
    /// Decision 5 of the plan: every recorded note gets one on finish, meetings
    /// and microphone-only notes alike. P5 lifts this into `NoteEnhancementService`;
    /// the seam here is deliberately one call.
    func generateNoteIfNeeded(
        _ handle: PindropCore.NoteCaptureHandle,
        operationGuard: () throws -> Void
    ) async throws {
        let attempt = Self.captureAssignmentAttempt(for: .noteGeneration)
        // Recovery finalizes captures that no live state describes; only the
        // capture the UI is showing may move its phase.
        if state.sessionID == handle.sessionID {
            state.beginEnhancing()
        }

        do {
            let existing = try captureSessionStore.generatedMeetingNote(
                handle,
                assignmentAttempt: attempt
            )
            guard Self.shouldGenerateMeetingNote(existingGeneratedNote: existing != nil) else {
                return
            }
        } catch {
            if Self.isTaskCancellation(error) { throw CancellationError() }
            try operationGuard()
            throw MeetingNoteGenerationFailure.generatedNoteDiscoveryFailed
        }

        let assignment: CaptureStageAssignment
        do {
            assignment = try captureAssignment(
                sessionID: handle.sessionID,
                stage: .noteGeneration,
                attempt: attempt
            )
        } catch {
            if Self.isTaskCancellation(error) { throw CancellationError() }
            try operationGuard()
            throw MeetingNoteGenerationFailure.assignmentUnavailable
        }

        switch Self.meetingNoteGenerationExecutionDecision(for: assignment) {
        case .skipDisabled:
            try operationGuard()
            recordNoteGenerationFailure(.disabled, handle: handle, attempt: attempt)
            return
        case .skipUnavailable:
            try operationGuard()
            recordNoteGenerationFailure(.unavailable, handle: handle, attempt: attempt)
            return
        case .rejectInvalidAssignment:
            try operationGuard()
            throw MeetingNoteGenerationFailure.assignmentUnavailable
        case .resolveRuntime:
            break
        }

        guard let persistedAssignment = Self.noteGenerationRuntimeAssignment(from: assignment) else {
            try operationGuard()
            throw MeetingNoteGenerationFailure.runtimeUnavailable
        }

        let runtime: ResolvedAssignment
        do {
            runtime = try assignmentResolver.resolveNoteGenerationRuntime(for: persistedAssignment)
        } catch {
            if Self.isTaskCancellation(error) { throw CancellationError() }
            try operationGuard()
            throw MeetingNoteGenerationFailure.runtimeUnavailable
        }

        guard let prompt = runtime.prompt,
              Self.canExecutePersistedNoteGeneration(resolvedPrompt: prompt) else {
            try operationGuard()
            throw MeetingNoteGenerationFailure.promptUnavailable
        }

        let source: MeetingNoteSourceBundle
        do {
            let preflight = try captureSessionStore.meetingGeneratedNotePreflight(
                handle,
                assignmentAttempt: attempt
            )
            guard let anchor = try captureSessionStore.meetingHumanAnchor(handle),
                  anchor.noteID == preflight.humanAnchor.noteID else {
                throw CaptureSessionStoreError.meetingHumanAnchorUnavailable(handle.sessionID)
            }
            let currentAnchor = try notesStore.fetch(id: anchor.noteID)
            let refreshedPlan = try captureSessionStore.makeMeetingFinalizationPlan(handle)
            source = try MeetingNoteDerivation.make(
                humanNoteContent: currentAnchor.content,
                checkpoints: refreshedPlan.completedASRCheckpoints
            )
        } catch {
            if Self.isTaskCancellation(error) { throw CancellationError() }
            try operationGuard()
            throw MeetingNoteGenerationFailure.derivationFailed
        }

        let enhancedNote: AIEnhancementService.EnhancedNote
        do {
            enhancedNote = try await aiEnhancementService.generateMeetingNote(
                evidence: source.evidenceInput,
                assignment: runtime,
                formatPrompt: prompt
            )
            try operationGuard()
        } catch {
            if Self.isTaskCancellation(error) { throw CancellationError() }
            try operationGuard()
            throw MeetingNoteGenerationFailure.generationFailed
        }

        let content = MeetingNoteDerivation.sanitizingGeneratedContent(
            Self.normalizedText(enhancedNote.content)
        )
        guard !content.isEmpty else {
            try operationGuard()
            throw MeetingNoteGenerationFailure.emptyOutput
        }

        do {
            let title = Self.generatedMeetingNoteTitle(
                enhancedNote.title,
                fallback: localized("Untitled Note", locale: settingsStore.selectedAppLocale.locale)
            )
            _ = try captureSessionStore.saveGeneratedMeetingNote(
                handle,
                title: title,
                content: content,
                source: source,
                assignmentAttempt: attempt,
                at: .now
            )
        } catch {
            if Self.isTaskCancellation(error) { throw CancellationError() }
            try operationGuard()
            throw Self.meetingNoteGenerationSaveFailure(for: error)
        }
    }

    func recordNoteGenerationFailure(
        _ failure: MeetingNoteGenerationFailure,
        handle: PindropCore.NoteCaptureHandle,
        attempt: Int
    ) {
        do {
            try captureSessionStore.recordStageFailure(
                sessionID: handle.sessionID,
                stage: .noteGeneration,
                attempt: attempt,
                domain: "PindropMeetingNotes",
                code: failure.rawValue,
                message: failure.message,
                retryable: failure.retryable,
                at: .now
            )
        } catch {
            Log.app.error(
                "Note generation failure persistence failed code=\(failure.rawValue) category=\(failure.category.rawValue)"
            )
        }
        Log.app.warning(
            "Note generation failure code=\(failure.rawValue) category=\(failure.category.rawValue) message=\(failure.message)"
        )
    }

    // MARK: - Pure decisions

    static let captureStartAssignmentStages: [CapturePipelineStage] = [
        .liveTranscription,
        .finalTranscription,
        .diarization,
        .noteGeneration
    ]

    static func captureAssignmentAttempt(for stage: CapturePipelineStage) -> Int {
        // Capture retries are represented by new attempts. Initial execution,
        // recovery, and every chunk share the durable first attempt.
        1
    }

    static func captureAssignmentExecutionDecision(
        for assignment: CaptureStageAssignment
    ) -> CaptureAssignmentExecutionDecision {
        switch assignment.providerKind {
        case .disabled, .bestEffortUnavailable:
            .skip
        case .streamingSpeech, .batchSpeech, .localDiarization, .generativeAI:
            .execute
        }
    }

    static func liveArtifactCaptureAdmission(
        for assignment: CaptureStageAssignment
    ) -> LiveArtifactCaptureAdmission {
        guard case .liveTranscription = assignment.stage,
              assignment.providerKind == .streamingSpeech else {
            return .deactivate
        }
        return .capture
    }

    static func captureAssignmentExecutionOrder(
        for assignment: CaptureStageAssignment
    ) -> [CaptureAssignmentExecutionStep] {
        switch captureAssignmentExecutionDecision(for: assignment) {
        case .execute:
            [.assignmentSnapshot, .stageCall]
        case .skip:
            [.assignmentSnapshot]
        }
    }

    static func assignedFinalModelNeedsActivation(
        _ assignment: CaptureStageAssignment,
        activeModelName: String?
    ) -> Bool {
        guard case .finalTranscription = assignment.stage else { return false }
        return assignment.modelIdentifier != nil
            && assignment.modelIdentifier != activeModelName
    }

    static func noteGenerationRuntimeAssignment(
        from persistedAssignment: CaptureStageAssignment
    ) -> CaptureStageAssignment? {
        guard case .noteGeneration = persistedAssignment.stage,
              persistedAssignment.providerKind == .generativeAI else {
            return nil
        }
        return persistedAssignment
    }

    static func canExecutePersistedNoteGeneration(resolvedPrompt: String?) -> Bool {
        guard let resolvedPrompt else { return false }
        return !normalizedText(resolvedPrompt).isEmpty
    }

    static func shouldGenerateMeetingNote(existingGeneratedNote: Bool) -> Bool {
        !existingGeneratedNote
    }

    static func generatedMeetingNoteTitle(_ title: String, fallback: String) -> String {
        let sanitizedTitle = MeetingNoteDerivation.sanitizingGeneratedContent(
            normalizedText(title)
        )
        return sanitizedTitle.isEmpty ? fallback : sanitizedTitle
    }

    static func meetingNoteGenerationExecutionDecision(
        for assignment: CaptureStageAssignment
    ) -> MeetingNoteGenerationExecutionDecision {
        switch assignment.providerKind {
        case .disabled:
            .skipDisabled
        case .bestEffortUnavailable:
            .skipUnavailable
        case .generativeAI:
            .resolveRuntime
        case .streamingSpeech, .batchSpeech, .localDiarization:
            .rejectInvalidAssignment
        }
    }

    static func meetingNoteGenerationSaveFailure(
        for error: Error
    ) -> MeetingNoteGenerationFailure {
        guard let storeError = error as? CaptureSessionStoreError,
              case .meetingGeneratedNoteSourceChanged = storeError else {
            return .saveFailed
        }
        return .sourceChanged
    }

    static func noteGenerationExecutionOrder(
        for persistedAssignment: CaptureStageAssignment,
        runtimeAvailable: Bool,
        resolvedPrompt: String?
    ) -> [NoteGenerationExecutionStep] {
        guard noteGenerationRuntimeAssignment(from: persistedAssignment) != nil else {
            return [.assignmentSnapshot, .rawFallback]
        }
        guard runtimeAvailable,
              canExecutePersistedNoteGeneration(resolvedPrompt: resolvedPrompt) else {
            return [.assignmentSnapshot, .runtimeResolution, .stageFailureRecorded, .rawFallback]
        }
        return [.assignmentSnapshot, .runtimeResolution, .stageCall]
    }

    static func expectedMeetingFinalASRSequences(
        workItems: [MeetingChunkWorkItem]
    ) -> Set<Int> {
        Set(workItems.lazy.filter(shouldCreateMeetingTranscriptionInput(for:)).map(\.sequence))
    }

    static func missingMeetingFinalASRSequences(
        workItems: [MeetingChunkWorkItem],
        completedASRSequences: Set<Int>
    ) -> [Int] {
        expectedMeetingFinalASRSequences(workItems: workItems)
            .subtracting(completedASRSequences)
            .sorted()
    }

    static func meetingFinalizationNeedsFinalModelActivation(
        workItems: [MeetingChunkWorkItem],
        completedASRSequences: Set<Int>
    ) -> Bool {
        !missingMeetingFinalASRSequences(
            workItems: workItems,
            completedASRSequences: completedASRSequences
        ).isEmpty
    }

    static func finalHistoryModelIdentifier(
        from assignment: CaptureStageAssignment
    ) -> String? {
        guard case .finalTranscription = assignment.stage else { return nil }
        return assignment.modelIdentifier
    }

    static func meetingChunkWorkItems(
        sourceChunks: [PindropData.MeetingChunkCheckpoint],
        failedSequences: Set<Int>,
        handle: PindropCore.NoteCaptureHandle
    ) throws -> [MeetingChunkWorkItem] {
        func indexedChunks(
            sourceID: UUID
        ) throws -> [Int: PindropData.MeetingChunkCheckpoint] {
            try sourceChunks
                .filter { $0.sourceID == sourceID }
                .reduce(into: [Int: PindropData.MeetingChunkCheckpoint]()) { result, chunk in
                    guard result[chunk.sequence] == nil else {
                        throw MeetingChunkWorkItemError.duplicateSourceSequence(
                            sourceID: sourceID,
                            sequence: chunk.sequence
                        )
                    }
                    result[chunk.sequence] = chunk
                }
        }

        let microphoneChunks = try indexedChunks(sourceID: handle.microphoneSourceID)
        let systemAudioChunks = try handle.systemAudioSourceID
            .map { try indexedChunks(sourceID: $0) } ?? [:]
        let sequences = Set(microphoneChunks.keys)
            .union(systemAudioChunks.keys)
            .union(failedSequences)
            .sorted()

        return try sequences.map { sequence in
            let microphone = microphoneChunks[sequence]
            let systemAudio = systemAudioChunks[sequence]
            if let primary = microphone ?? systemAudio {
                if let microphone, let systemAudio,
                   abs(microphone.startOffset - systemAudio.startOffset) > (1.0 / Double(MeetingCaptureSpoolPlan.sampleRate)) {
                    throw MeetingChunkWorkItemError.mismatchedStartOffset(sequence: sequence)
                }
                return MeetingChunkWorkItem(
                    sequence: sequence,
                    chunkID: primary.chunkID,
                    startOffset: primary.startOffset,
                    duration: max(microphone?.duration ?? 0, systemAudio?.duration ?? 0),
                    microphone: microphone,
                    systemAudio: systemAudio
                )
            }

            return MeetingChunkWorkItem(
                sequence: sequence,
                chunkID: UUID(),
                startOffset: Double(sequence) * MeetingCaptureSpoolPlan.chunkDuration,
                duration: MeetingCaptureSpoolPlan.chunkDuration,
                microphone: nil,
                systemAudio: nil
            )
        }
    }

    static func shouldCreateMeetingTranscriptionInput(
        for workItem: MeetingChunkWorkItem
    ) -> Bool {
        workItem.microphone != nil || workItem.systemAudio != nil
    }

    static func meetingOutputPlaceholder(
        for workItem: MeetingChunkWorkItem
    ) -> TranscriptionChunkOutput {
        TranscriptionChunkOutput(
            chunkID: workItem.chunkID,
            sequence: workItem.sequence,
            startOffset: workItem.startOffset,
            duration: workItem.duration,
            plainText: ""
        )
    }

    static func meetingOutputPlaceholders(
        workItems: [MeetingChunkWorkItem],
        outputs: [TranscriptionChunkOutput]
    ) -> [TranscriptionChunkOutput] {
        let outputsBySequence = outputs.reduce(into: [Int: TranscriptionChunkOutput]()) { result, output in
            result[output.sequence] = result[output.sequence] ?? output
        }
        return workItems.map { item in
            outputsBySequence[item.sequence] ?? meetingOutputPlaceholder(for: item)
        }
    }

    static func meetingChunkProgress(completed: Int, total: Int) -> Double {
        guard total > 0 else { return 1 }
        return min(1, max(0, Double(completed) / Double(total)))
    }

    @MainActor
    static func completeMeetingAfterHistory(
        recordID: UUID,
        operationGuard: () throws -> Void,
        generateNote: () async throws -> Void,
        onGenerationFailure: (MeetingNoteGenerationFailure) -> Void,
        complete: (UUID) throws -> Void
    ) async throws {
        try operationGuard()
        do {
            try await generateNote()
        } catch is CancellationError {
            throw CancellationError()
        } catch let failure as MeetingNoteGenerationFailure {
            onGenerationFailure(failure)
            throw failure
        }
        try operationGuard()
        try complete(recordID)
    }

    static func isTaskCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        if let urlError = error as? URLError, urlError.code == .cancelled { return true }
        let nsError = error as NSError
        return nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled
    }

    static func normalizedText(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func isEffectivelyEmpty(_ text: String) -> Bool {
        let normalized = normalizedText(text)
        if normalized.isEmpty { return true }
        return normalized.caseInsensitiveCompare("[BLANK AUDIO]") == .orderedSame
    }

    static func encodeDiarizationSegmentsJSON(_ segments: [DiarizedTranscriptSegment]?) -> String? {
        guard let segments, !segments.isEmpty else { return nil }
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let encodedData = try encoder.encode(segments)
            return String(data: encodedData, encoding: .utf8)
        } catch {
            Log.app.warning("Failed to encode diarization segments for history: \(error.localizedDescription)")
            return nil
        }
    }
}
