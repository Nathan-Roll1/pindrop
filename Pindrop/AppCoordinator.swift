//
//  AppCoordinator.swift
//  Pindrop
//
//  Created on 2026-01-25.
//

import Foundation
import SwiftUI
import SwiftData
import Combine
import AVFoundation
import AppKit
import os.log
import PindropCore
import PindropAI
import PindropData
import PindropSpeech
import PindropMedia

private final class EventTapRunLoopThread: Thread {

    private let readinessSemaphore = DispatchSemaphore(value: 0)
    private let stateLock = NSLock()
    private var runLoop: CFRunLoop?
    private let threadExitGroup = DispatchGroup()
    private var hasStarted = false
    private var hasExited = false
    private var stopRequested = false
    private let keepAlivePort = Port()

    init(name: String) {
        super.init()
        self.name = name
        self.qualityOfService = .userInteractive
        threadExitGroup.enter()
    }

    override func main() {
        let currentRunLoop = CFRunLoopGetCurrent()

        stateLock.lock()
        runLoop = currentRunLoop
        stateLock.unlock()

        RunLoop.current.add(keepAlivePort, forMode: .default)
        readinessSemaphore.signal()

        while !isCancelled {
            autoreleasepool {
                _ = RunLoop.current.run(mode: .default, before: .distantFuture)
            }
        }

        stateLock.lock()
        runLoop = nil
        hasExited = true
        stateLock.unlock()
        threadExitGroup.leave()
    }

    func performAndWait(_ block: @escaping (CFRunLoop) -> Void) {
        startIfNeeded()

        guard let runLoop = currentRunLoop else { return }
        guard let defaultMode = CFRunLoopMode.defaultMode else { return }

        let completionSemaphore = DispatchSemaphore(value: 0)
        CFRunLoopPerformBlock(runLoop, defaultMode.rawValue as CFTypeRef) {
            block(runLoop)
            completionSemaphore.signal()
        }
        CFRunLoopWakeUp(runLoop)
        completionSemaphore.wait()
    }

    func stopIfNeeded() {
        var shouldCompleteWithoutStarting = false

        stateLock.lock()
        if !stopRequested {
            stopRequested = true
            cancel()
        }
        let runLoop = runLoop
        if !hasStarted && !hasExited {
            hasExited = true
            shouldCompleteWithoutStarting = true
        }
        stateLock.unlock()

        if shouldCompleteWithoutStarting {
            threadExitGroup.leave()
        }

        // Cancellation is set while holding the same lock used to publish the
        // run loop. A starting thread therefore either observes cancellation
        // before its first iteration, or publishes a loop that we stop here.
        if let runLoop {
            // Cover the narrow window after the loop condition is evaluated but
            // before `run` begins: if that activation starts, this block stops it.
            if let defaultMode = CFRunLoopMode.defaultMode {
                CFRunLoopPerformBlock(runLoop, defaultMode.rawValue as CFTypeRef) {
                    CFRunLoopStop(CFRunLoopGetCurrent())
                }
            }
            CFRunLoopStop(runLoop)
            CFRunLoopWakeUp(runLoop)
        }

        // Waiting for thread exit, rather than for a queued run-loop block,
        // remains safe after the run loop has stopped processing blocks.
        guard Thread.current !== self else { return }
        threadExitGroup.wait()
    }

    private func startIfNeeded() {
        stateLock.lock()
        guard !stopRequested, !hasStarted else {
            stateLock.unlock()
            return
        }
        hasStarted = true
        stateLock.unlock()

        start()
        readinessSemaphore.wait()
    }

    private var currentRunLoop: CFRunLoop? {
        stateLock.lock()
        defer { stateLock.unlock() }
        return runLoop
    }
}

extension Notification.Name {
    static let switchModel = Notification.Name("tech.watzon.pindrop.switchModel")
    static let modelActiveChanged = Notification.Name("tech.watzon.pindrop.modelActiveChanged")
    static let requestActiveModel = Notification.Name("tech.watzon.pindrop.requestActiveModel")
    static let showWhatsNew = Notification.Name("tech.watzon.pindrop.showWhatsNew")
    /// UI posts this with `userInfo["text"]` (String) to copy with clipboard-undo toast.
    static let copyTextWithUndo = Notification.Name("tech.watzon.pindrop.copyTextWithUndo")
}

struct HotkeyConflict: Equatable {
    let existingIdentifier: String
    let incomingIdentifier: String
    let combination: HotkeyRegistrationState.Combination

    var conflictKey: String {
        [existingIdentifier, incomingIdentifier]
            .sorted()
            .joined(separator: "|") + "|\(combination.keyCode)|\(combination.modifiers)"
    }
}

struct HotkeyRegistrationState {
    struct Combination: Hashable {
        let keyCode: UInt32
        let modifiers: UInt32
    }

    private(set) var registeredIdentifiersByCombination: [Combination: String] = [:]

    static func shouldRegisterHotkeys(hasCompletedOnboarding: Bool) -> Bool {
        hasCompletedOnboarding
    }

    mutating func register(
        identifier: String,
        keyCode: UInt32,
        modifiers: UInt32
    ) -> HotkeyConflict? {
        let combination = Combination(keyCode: keyCode, modifiers: modifiers)

        if let existingIdentifier = registeredIdentifiersByCombination[combination] {
            return HotkeyConflict(
                existingIdentifier: existingIdentifier,
                incomingIdentifier: identifier,
                combination: combination
            )
        }

        registeredIdentifiersByCombination[combination] = identifier
        return nil
    }
}

struct HotkeyBindingSnapshot: Equatable {
    let hotkey: String
    let keyCode: Int
    let modifiers: Int
}

struct HotkeySettingsSnapshot: Equatable {
    let hasCompletedOnboarding: Bool
    let pushToTalk: HotkeyBindingSnapshot
    let toggle: HotkeyBindingSnapshot
    let copyLastTranscript: HotkeyBindingSnapshot
    let quickCapturePTT: HotkeyBindingSnapshot
    let quickCaptureToggle: HotkeyBindingSnapshot
    let openLibrary: HotkeyBindingSnapshot
    let cancelOperation: HotkeyBindingSnapshot
}

struct SettingsObservationSnapshot: Equatable {
    let outputMode: String
    let automaticDictionaryLearningEnabled: Bool
    let selectedInputDeviceUID: String
    let selectedAppLocale: AppLocale
    let selectedAppLanguage: AppLanguage
    let floatingIndicatorEnabled: Bool
    let floatingIndicatorType: FloatingIndicatorType
    let aiEnhancementEnabled: Bool
    let enableUIContext: Bool
    let vibeLiveSessionEnabled: Bool
    let streamingFeatureEnabled: Bool
    let hotkeys: HotkeySettingsSnapshot
    let mcpServerEnabled: Bool
    let mcpServerPort: Int
    let dictationAudioRetention: DictationAudioRetention
}

enum RecordingStopRoute: Equatable {
    case dictation
    case quickCapture
    case noteAppend(UUID)
    case manualTranscription

    static func resolve(
        isQuickCapture: Bool,
        noteAppendEditorID: UUID?,
        isManualTranscription: Bool
    ) -> RecordingStopRoute {
        if let noteAppendEditorID { return .noteAppend(noteAppendEditorID) }
        if isQuickCapture { return .quickCapture }
        if isManualTranscription { return .manualTranscription }
        return .dictation
    }
}
/// IDs that cross persistence boundaries during voice-note linkage.
///
/// History owns the transcription record ID used by notes and editor notifications;
/// capture owns the final revision ID used only to complete the capture session.
struct VoiceNoteLinkageIDs: Equatable, Sendable {
    let historyRecordID: UUID
    let finalTranscriptRevisionID: UUID
}


enum CoordinatorTranscriptionRoute: Equatable {
    case dictation
    case noteAppend
    case quickCapture
    case manualCapture(AudioRecordingMode)
    case importedMedia

    var appliesVoiceIsolation: Bool {
        switch self {
        case .dictation, .noteAppend, .quickCapture:
            return true
        case .manualCapture, .importedMedia:
            return false
        }
    }
}


/// A synchronous, coordinator-owned admission gate shared by every stop source.
/// It lets only the first user/limit event own a recording's finalization route.
/// Claims are lease/generation-owned: cancel can free the gate immediately, and a
/// stale deferred release cannot clear a newer claim.
struct RecordingStopClaim: Equatable, Sendable {
    let id: UInt64
    let route: RecordingStopRoute
}

final class RecordingStopAdmission {
    private let lock = NSLock()
    private var isClaimed = false
    private var currentClaimID: UInt64 = 0
    private var nextClaimID: UInt64 = 0

    func claim(_ route: RecordingStopRoute) -> RecordingStopClaim? {
        lock.lock()
        defer { lock.unlock() }
        guard !isClaimed else { return nil }
        nextClaimID &+= 1
        currentClaimID = nextClaimID
        isClaimed = true
        return RecordingStopClaim(id: currentClaimID, route: route)
    }

    /// Releases only if `claim` is still the active lease.
    func release(_ claim: RecordingStopClaim) {
        lock.lock()
        defer { lock.unlock() }
        guard isClaimed, currentClaimID == claim.id else { return }
        isClaimed = false
    }

    /// Immediately frees the gate (e.g. cancel-operation). Any outstanding claim
    /// token becomes stale and its deferred `release` is a no-op.
    func invalidateCurrentClaim() {
        lock.lock()
        defer { lock.unlock() }
        guard isClaimed else { return }
        isClaimed = false
        currentClaimID &+= 1
    }
}

/// A synchronous admission gate for a pending meeting-capture start.
/// A claim is acquired before the start task is created, so a second trigger
/// cannot enter while the first one is suspended in recorder preparation.
struct MeetingCaptureStartClaim: Equatable, Sendable {
    let id: UInt64
}

final class MeetingCaptureStartAdmission {
    private let lock = NSLock()
    private var isClaimed = false
    private var currentClaimID: UInt64 = 0
    private var nextClaimID: UInt64 = 0

    func claim() -> MeetingCaptureStartClaim? {
        lock.lock()
        defer { lock.unlock() }
        guard !isClaimed else { return nil }
        nextClaimID &+= 1
        currentClaimID = nextClaimID
        isClaimed = true
        return MeetingCaptureStartClaim(id: currentClaimID)
    }

    func isCurrent(_ claim: MeetingCaptureStartClaim) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return isClaimed && currentClaimID == claim.id
    }

    /// Releases only the exact pending start that owns the admission.
    func release(_ claim: MeetingCaptureStartClaim) {
        lock.lock()
        defer { lock.unlock() }
        guard isClaimed, currentClaimID == claim.id else { return }
        isClaimed = false
    }
}

/// Generation-token ownership for a single in-flight dictation/processing pipeline.
/// Cancel advances the generation so post-await stages can discard stale results.
final class DictationOperationController: @unchecked Sendable {
    private let lock = NSLock()
    private var generation: UInt64 = 0

    func begin() -> DictationOperationToken {
        lock.lock()
        defer { lock.unlock() }
        generation &+= 1
        return DictationOperationToken(generation: generation)
    }

    func cancel() {
        lock.lock()
        defer { lock.unlock() }
        generation &+= 1
    }

    func isCurrent(_ token: DictationOperationToken) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return token.generation == generation
    }
}

struct DictationOperationToken: Equatable, Sendable {
    let generation: UInt64
}

private final class LiveContextKeyRefreshGate: @unchecked Sendable {
    private let lock = NSLock()
    private var isEnabled = false
    private var nextEligibleUptime: TimeInterval = 0

    func setEnabled(_ enabled: Bool) {
        lock.lock()
        defer { lock.unlock() }
        guard isEnabled != enabled else { return }
        isEnabled = enabled
        nextEligibleUptime = 0
    }

    func claim(now: TimeInterval, minimumInterval: TimeInterval) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard isEnabled, now >= nextEligibleUptime else { return false }
        nextEligibleUptime = now + minimumInterval
        return true
    }
}

private final class EscapeEventState: @unchecked Sendable {
    private let lock = NSLock()
    private var shouldSuppress = false

    func setShouldSuppress(_ shouldSuppress: Bool) {
        lock.lock()
        self.shouldSuppress = shouldSuppress
        lock.unlock()
    }

    func currentShouldSuppress() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return shouldSuppress
    }
}

private final class CoordinatorNotificationResources: @unchecked Sendable {
    private let lock = NSLock()
    private let notificationCenter: NotificationCenter
    private var tokens: [NSObjectProtocol] = []
    private var isTornDown = false

    init(notificationCenter: NotificationCenter = .default) {
        self.notificationCenter = notificationCenter
    }

    func install(_ token: NSObjectProtocol) {
        lock.lock()
        if isTornDown {
            lock.unlock()
            notificationCenter.removeObserver(token)
            return
        }
        tokens.append(token)
        lock.unlock()
    }

    func tearDown() {
        lock.lock()
        guard !isTornDown else {
            lock.unlock()
            return
        }
        isTornDown = true
        let installedTokens = tokens
        tokens.removeAll()
        lock.unlock()

        for token in installedTokens {
            notificationCenter.removeObserver(token)
        }
    }

    deinit {
        tearDown()
    }
}

@MainActor
@Observable
final class AppCoordinator {

    private static var isRunningTests: Bool {
        ProcessInfo.processInfo.environment["PINDROP_TEST_MODE"] == "1"
            || ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }

    private enum RecordingTriggerSource: String {
        case statusBarMenu = "status-bar-menu"
        case hotkeyToggle = "hotkey-toggle"
        case hotkeyPushToTalk = "hotkey-push-to-talk"
        case hotkeyQuickCapturePTT = "hotkey-quick-capture-ptt"
        case hotkeyQuickCaptureToggle = "hotkey-quick-capture-toggle"
        case floatingIndicatorStart = "floating-indicator-start"
        case floatingIndicatorStop = "floating-indicator-stop"
        case pillIndicatorStop = "pill-indicator-stop"
        case pillIndicatorStart = "pill-indicator-start"
        case orbIndicatorStart = "orb-indicator-start"
        case orbIndicatorStop = "orb-indicator-stop"
        case bubbleIndicatorStart = "bubble-indicator-start"
        case bubbleIndicatorStop = "bubble-indicator-stop"
        case noteAppend = "note-append"
    }

    private struct VoiceNoteCaptureContext {
        let handle: PindropData.VoiceNoteCaptureHandle
        let noteID: UUID?
        let liveAssignment: CaptureStageAssignment
    }

    private struct VoiceNoteCaptureResult {
        let context: VoiceNoteCaptureContext
        let rawText: String
        let finalText: String
        let duration: TimeInterval
        let languageCode: String
        let finalModelIdentifier: String
        let enhancedWithModel: String?
        let title: String?
        let tags: [String]
    }
    private struct MeetingCaptureContext {
        let handle: PindropData.MeetingCaptureHandle
        let humanAnchorNoteID: UUID
        let spoolPlan: MeetingCaptureSpoolPlan
        let generation: UInt64
    }

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

    private enum MeetingCaptureAdmissionError: LocalizedError {
        case captureAlreadyActive
        case recorderDidNotStart
        case noRetainedSources
        case missingMixedAudio

        var errorDescription: String? {
            switch self {
            case .captureAlreadyActive:
                "A meeting capture is already active."
            case .recorderDidNotStart:
                "The recorder did not begin meeting capture."
            case .noRetainedSources:
                "Neither meeting audio source could be retained."
            case .missingMixedAudio:
                "Meeting audio could not be prepared for transcription."
            }
        }
    }


    private enum MeetingCaptureTerminalPersistenceError: Error {
        case cancellation(Error)
    }

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
        var errorDescription: String? {
            message
        }

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


    private struct PendingNoteAppendStart: Equatable {
        let generation: UInt64
        let editorID: UUID
        let noteID: UUID
    }

    private struct PendingNoteAppendCapture {
        let request: PendingNoteAppendStart
        let context: VoiceNoteCaptureContext
    }

    private enum VoiceNoteCaptureAdmissionError: LocalizedError {
        case captureAlreadyActive
        case recorderDidNotStart

        var errorDescription: String? {
            switch self {
            case .captureAlreadyActive:
                "A voice-note capture is already active."
            case .recorderDidNotStart:
                "The recorder did not begin recording."
            }
        }
    }

    enum EventTapRecoveryAction: Equatable {
        case reenable
        case recreate
    }

    struct EventTapRecoveryDecision: Equatable {
        let consecutiveDisableCount: Int
        let action: EventTapRecoveryAction
    }

    static func determineEventTapRecovery(
        now: Date,
        lastDisableAt: Date?,
        consecutiveDisableCount: Int,
        disableLoopWindow: TimeInterval,
        maxReenableAttemptsBeforeRecreate: Int
    ) -> EventTapRecoveryDecision {
        let nextCount: Int
        if let lastDisableAt,
           now.timeIntervalSince(lastDisableAt) <= disableLoopWindow {
            nextCount = consecutiveDisableCount + 1
        } else {
            nextCount = 1
        }

        let recreateThreshold = max(1, maxReenableAttemptsBeforeRecreate)
        let action: EventTapRecoveryAction = nextCount >= recreateThreshold ? .recreate : .reenable

        return EventTapRecoveryDecision(
            consecutiveDisableCount: nextCount,
            action: action
        )
    }

    static func floatingIndicatorFocusTrackingMode(
        floatingIndicatorEnabled: Bool,
        isTemporarilyHidden: Bool,
        selectedType: FloatingIndicatorType,
        isRecording: Bool,
        isProcessing: Bool
    ) -> FloatingIndicatorTrackingMode? {
        guard floatingIndicatorEnabled, !isTemporarilyHidden else { return nil }

        if isRecording || isProcessing {
            // Bubble manages its own caret-anchor refresh; other active styles use focus tracking.
            switch selectedType {
            case .pill, .orb, .notch:
                return .activeSession
            case .bubble:
                return nil
            }
        }

        // Always-on styles need idle placement tracking; transient styles leave no idle footprint.
        return selectedType.isAlwaysOn ? .idlePill : nil
    }

    private enum EventTapKind {
        case escape
        case modifier
    }

    private struct EventTapDisableState {
        var lastDisableAt: Date?
        var consecutiveDisableCount = 0
        var lastDisabledTypeRawValue: UInt32?
    }

    // MARK: - Services
    
    let permissionManager: PermissionManager
    let audioRecorder: AudioRecorder
    let transcriptionService: PindropSpeech.TranscriptionService
    let modelManager: PindropSpeech.ModelManager
    let aiEnhancementService: PindropAI.AIEnhancementService
    let hotkeyManager: HotkeyManager
    let launchAtLoginManager: LaunchAtLoginManager
    let updateService: UpdateService
    let outputManager: OutputManager
    let historyStore: PindropData.HistoryStore
    let speakerIdentityService: PindropData.SpeakerIdentityService
    let dictionaryStore: PindropData.DictionaryStore
    let settingsStore: SettingsStore
    let notesStore: PindropData.NotesStore
    let captureSessionStore: PindropData.CaptureSessionStore
    let captureAssignmentResolver: CaptureStageAssignmentResolver
    let contextCaptureService: ContextCaptureService
    let contextEngineService: ContextEngineService
    let toastService: ToastService
    let automaticDictionaryLearningService: AutomaticDictionaryLearningService
    let promptPresetStore: PindropData.PromptPresetStore
    let mentionRewriteService: MentionRewriteService
    let mediaPauseService: MediaPauseService
    let mediaIngestionService: MediaIngestionService
    let mediaPreparationService: PindropMedia.MediaPreparationService
    let announcementService: AnnouncementService
    let telemetryService: TelemetryService
    let telemetryConsentService: TelemetryConsentService
    let contributionService: PindropData.ContributionService
    let dictationAudioRetentionService: PindropMedia.DictationAudioRetentionService
    let recordingState: RecordingFeatureState
    let mediaTranscriptionState: MediaTranscriptionFeatureState
    private(set) var mcpServer: MCPServer?

    // MARK: - UI Controllers
    
    let statusBarController: StatusBarController
    let floatingIndicatorState: FloatingIndicatorState
    /// Live-transcript model for overlay streaming. Shared by all indicator presenters
    /// (switching indicator type mid-session keeps the transcript) and fed by the
    /// streaming session's overlay sink.
    let liveTranscriptState: LiveTranscriptState
    /// Owns the streaming session lifecycle: engine callbacks, audio forwarding,
    /// refinement coordinator + overlay sink, and the post-stop finalize pipeline.
    let streamingSession: StreamingSessionController
    private var activeStreamingSessionToken: StreamingSessionController.SessionToken?
    let floatingIndicatorController: FloatingIndicatorController
    let pillFloatingIndicatorController: PillFloatingIndicatorController
    let caretBubbleFloatingIndicatorController: CaretBubbleFloatingIndicatorController
    let orbFloatingIndicatorController: OrbFloatingIndicatorController
    let floatingIndicatorPresenters: [FloatingIndicatorType: any FloatingIndicatorPresenting]
    let floatingIndicatorFocusTracker: FloatingIndicatorFocusTracker
    let onboardingController: OnboardingWindowController
    let announcementController: AnnouncementWindowController
    let telemetryConsentController: TelemetryConsentWindowController
    let splashController: SplashWindowController
    let settingsWindowController: SettingsWindowController
    let mainWindowController: MainWindowController
    private var mainWindowCaptureStartTask: Task<Void, Never>?
    let noteEditorWindowController: NoteEditorWindowController
    let toastWindowController: ToastWindowController
    private var meetingCaptureContext: MeetingCaptureContext?
    private var meetingCaptureGeneration: UInt64 = 0
    private let meetingCaptureStartAdmission = MeetingCaptureStartAdmission()
    private var pendingMeetingCaptureStart: MeetingCaptureStartClaim?
    private var pendingMeetingCaptureStartTask: Task<Void, Never>?
    private var pendingMeetingCaptureStartHandle: PindropData.MeetingCaptureHandle?
    private var pendingMeetingCaptureCancellationHandle: PindropData.MeetingCaptureHandle?
    private var meetingCancellationTasks: [UUID: Task<Void, Never>] = [:]
    private var meetingRecoveryTask: Task<Void, Never>?
    private var meetingRecoveryGeneration: UInt64 = 0
    private var meetingRecoveryHandle: PindropData.MeetingCaptureHandle?
    
    // MARK: - Quick Capture State
    
    private var isQuickCaptureMode = false
    private var isNoteAppendMode = false
    private let recordingStopAdmission = RecordingStopAdmission()
    private var isRecordingFeatureCaptureActive = false
    private var manualExpectedSpeakerCount: Int?
    private var quickCaptureTranscription: String?
    private var noteAppendEditorID: UUID?
    private var voiceNoteCaptureContext: VoiceNoteCaptureContext?
    /// The exact capture allocated for a pending editor request. Stop must only
    /// cancel this handle, never whichever capture happens to be active later.
    private var pendingNoteAppendStartCapture: PendingNoteAppendCapture?
    /// Retained until the cancelled start task unwinds so its stale catch can
    /// clean recorder startup without clobbering a newer start.
    private var pendingNoteAppendAudioStartupRequest: PendingNoteAppendStart?
    /// A start request is installed before its task can run so Stop/teardown can
    /// synchronously invalidate it while the editor is still closing.
    private var pendingNoteAppendStartTask: Task<Void, Never>?
    private var pendingNoteAppendStart: PendingNoteAppendStart?
    private var nextNoteAppendStartGeneration: UInt64 = 0
    private var mediaTranscriptionTask: Task<Void, Never>? {
        didSet {
            refreshEscapeSuppression()
        }
    }
    private var mediaTranscriptionGeneration: UInt64 = 0
    private var mediaTranscriptionTaskGeneration: UInt64?
    private var mediaQueueRestoreRequested = false
    private var mediaQueueNeedsProcessingReset = false
    /// Set when a dequeued media job had to yield to an active dictation session.
    /// The job goes back to the head of the queue and the queue stays paused until
    /// recording/processing clears, instead of silently dropping the job.
    private var mediaQueueDeferredUntilIdle = false
    /// Owned processing task for stop/transcribe/enhance pipelines. Cancelled by cancel-operation.
    private var activeOperationTask: Task<Void, Error>?
    private var operationController = DictationOperationController()
    private var queueOriginalModelName: String?

    // MARK: - State
    
    private let escapeEventState = EscapeEventState()
    private(set) var activeModelName: String?
    private(set) var isRecording = false {
        didSet {
            refreshEscapeSuppression()
            resumeDeferredMediaQueueIfIdle()
            recordingState.setCaptureActivity(
                isRecording: isRecording,
                isProcessing: isProcessing
            )
        }
    }
    private(set) var isProcessing = false {
        didSet {
            refreshEscapeSuppression()
            resumeDeferredMediaQueueIfIdle()
            recordingState.setCaptureActivity(
                isRecording: isRecording,
                isProcessing: isProcessing
            )
        }
    }

    /// True when the only active work is a background media transcription job.
    /// Those jobs were explicitly queued by the user and have their own cancel UI,
    /// so Escape neither cancels them nor gets swallowed while they run.
    private var isMediaTranscriptionOnlyWork: Bool {
        mediaTranscriptionTask != nil && !isRecording && activeOperationTask == nil
    }

    /// Escape is only suppressed when pressing it would actually cancel something;
    /// the predicate must stay in lockstep with `cancelCurrentOperation`'s media guard.
    private func refreshEscapeSuppression() {
        escapeEventState.setShouldSuppress(
            Self.shouldSuppressEscapeEvent(
                isRecording: isRecording,
                isProcessing: isProcessing,
                isMediaTranscriptionOnly: isMediaTranscriptionOnlyWork
            )
        )
    }
    private(set) var error: Error?
    
    private var recordingStartTime: Date?
    private var cancellables = Set<AnyCancellable>()
    private let notificationResources = CoordinatorNotificationResources()
    private var capturedContext: CapturedContext?
    private var capturedSnapshot: ContextSnapshot?
    private var capturedAdapterCapabilities: AppAdapterCapabilities?
    private var capturedRoutingSignal: PromptRoutingSignal?
    private var contextSessionState: ContextSessionState?
    private var contextSessionPollTimer: Timer?
    private var contextSessionAppActivationObserver: NSObjectProtocol?
    private var lastFocusOrWindowUpdateAt: Date?
    /// Single owner for live-context refresh work. New triggers coalesce while a
    /// refresh is suspended; only the generation that owns the active task may
    /// apply results, and stop/reset cancels the pending task.
    private var contextSessionRefreshTask: Task<Void, Never>?
    private var contextSessionRefreshGeneration: UInt64 = 0
    private var contextSessionPendingRefresh: (trigger: ContextSessionUpdateTrigger, snapshotOverride: ContextSnapshot?)?
    private let liveContextKeyRefreshGate = LiveContextKeyRefreshGate()
    private let contextSessionPollInterval: TimeInterval = 1.25
    private let contextSessionFocusUpdateThrottle: TimeInterval = 0.75
    private var recordingStartAttemptCounter: UInt64 = 0

    private let appContextAdapterRegistry = AppContextAdapterRegistry()
    private let promptRoutingResolver: any PromptRoutingResolver = NoOpPromptRoutingResolver()
    private let enableSystemHooks: Bool
    private var isShutdown = false
    private var isPreparingForTermination = false
    private var lastObservedSettingsSnapshot: SettingsObservationSnapshot?
    private var hasRequestedAccessibilityPermissionThisLaunch = false
    private var hasShownAccessibilityFallbackAlertThisLaunch = false
    private var floatingIndicatorHiddenUntil: Date?
    private var floatingIndicatorHiddenTask: Task<Void, Never>?
    private var activeFloatingIndicatorType: FloatingIndicatorType?

    // MARK: - Dictionary Replacements
    
    /// Stores the last applied dictionary replacements for use in AI enhancement prompts
    var lastAppliedReplacements: [(original: String, replacement: String)] = []
    
    // MARK: - Escape Key Cancellation
    
    private var escapeEventTap: CFMachPort?
    private var escapeRunLoopSource: CFRunLoopSource?
    private var escapeGlobalMonitor: Any?
    private var modifierEventTap: CFMachPort?
    private var modifierRunLoopSource: CFRunLoopSource?
    private var modifierGlobalMonitor: Any?
    private let eventTapRunLoopThread = EventTapRunLoopThread(name: "tech.watzon.pindrop.event-tap-runloop")
    private var escapeEventTapDisableState = EventTapDisableState()
    private var modifierEventTapDisableState = EventTapDisableState()
    private var escapeEventTapRecoveryTask: Task<Void, Never>?
    private var modifierEventTapRecoveryTask: Task<Void, Never>?
    private var inputDeviceListMonitor: AudioDeviceListMonitor?
    private var inputMuteMonitor: InputMuteMonitor?
    private var lastEscapeSignalTime: Date?
    private let duplicateEscapeSignalThreshold: TimeInterval = 0.08
    /// First press of a double-Escape cancel sequence; cleared on cancel/finish.
    private var escapeCancelArmedAt: Date?
    static let doubleEscapeCancelWindow: TimeInterval = 0.6
    private let eventTapRecoveryDelay: Duration = .milliseconds(250)
    private let eventTapDisableLoopWindow: TimeInterval = 1.0
    private let maxEventTapReenableAttemptsBeforeRecreate = 3
    
    // MARK: - Initialization
    
    init(
        modelContext: ModelContext,
        modelContainer: ModelContainer,
        enableSystemHooks: Bool? = nil
    ) {
        self.enableSystemHooks = enableSystemHooks ?? !Self.isRunningTests
        self.permissionManager = PermissionManager()
        do {
            self.audioRecorder = try AudioRecorder(permissionManager: permissionManager)
        } catch {
            Log.app.error("Failed to initialize AudioRecorder: \(error)")
            fatalError("Failed to initialize AudioRecorder: \(error)")
        }
        let applicationSupportRoot = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let modelStorageLocations = ModelStorageLocations(
            pindropApplicationSupportRoot: applicationSupportRoot
                .appendingPathComponent("Pindrop", isDirectory: true),
            fluidAudioModelsRoot: applicationSupportRoot
                .appendingPathComponent("FluidAudio", isDirectory: true)
                .appendingPathComponent("Models", isDirectory: true)
        )
        let mediaLibraryBaseURL = applicationSupportRoot
            .appendingPathComponent("Pindrop", isDirectory: true)
            .appendingPathComponent("MediaLibrary", isDirectory: true)
        let dictationAudioDirectoryURL = mediaLibraryBaseURL
            .appendingPathComponent("DictationAudio", isDirectory: true)

        self.speakerIdentityService = PindropData.SpeakerIdentityService(modelContext: modelContext)
        self.settingsStore = SettingsStore()
        self.telemetryService = TelemetryService(settingsStore: settingsStore)
        self.modelManager = PindropSpeech.ModelManager(
            storageLocations: modelStorageLocations,
            modelDownloadEventReporter: telemetryService
        )
        self.aiEnhancementService = PindropAI.AIEnhancementService()
        self.hotkeyManager = HotkeyManager()
        self.launchAtLoginManager = LaunchAtLoginManager()
        self.updateService = UpdateService()
        // TranscriptionService is built after SettingsStore so the streaming chunk
        // profile and backend providers can read the user's toggles when the engine
        // is (re)loaded.
        let settingsRef = self.settingsStore
        self.transcriptionService = PindropSpeech.TranscriptionService(
            storageLocations: modelStorageLocations,
            openAIAPIKeyProvider: { [weak settingsRef] in
                guard let key = settingsRef?.loadTranscriptionAPIKey(for: .openAI) else {
                    throw PindropSpeech.OpenAITranscriptionEngine.EngineError.apiKeyMissing
                }
                return key
            },
            streamingChunkProfileProvider: { [weak settingsRef] in
                settingsRef?.streamingChunkProfile ?? .standard
            },
            streamingBackendProvider: { [weak settingsRef] in
                settingsRef?.resolvedTranscriptionBackend ?? .parakeet
            },
            speakerIdentityService: speakerIdentityService
        )
        do {
            try self.audioRecorder.setPreferredInputDeviceUID(settingsStore.selectedInputDeviceUID)
        } catch {
            Log.audio.error("Failed to apply initial preferred input device: \(error.localizedDescription)")
        }
        
        let initialOutputMode: OutputMode = settingsStore.outputMode == "directInsert" ? .directInsert : .clipboard
        self.outputManager = OutputManager(outputMode: initialOutputMode)
        self.contributionService = PindropData.ContributionService(
            modelContext: modelContext,
            metadataProvider: { [weak settingsRef] in
                ContributionCaptureMetadata(
                    isEnabled: settingsRef?.trainingDataContributionEnabled ?? false,
                    languageRawValue: settingsRef?.selectedAppLanguage.rawValue ?? AppLanguage.automatic.rawValue,
                    localeIdentifier: settingsRef?.selectedAppLocale.locale.identifier
                        ?? Locale.current.identifier,
                    appVersion: Bundle.main.appShortVersionString
                )
            }
        )
        self.historyStore = PindropData.HistoryStore(
            modelContext: modelContext,
            speakerIdentityService: speakerIdentityService,
            contributionService: contributionService
        )
        self.dictionaryStore = PindropData.DictionaryStore(modelContext: modelContext)
        let aiEnhancementServiceRef = self.aiEnhancementService
        self.notesStore = PindropData.NotesStore(
            modelContext: modelContext,
            metadataGenerator: { [weak settingsRef, weak aiEnhancementServiceRef] content, existingTags in
                guard let settingsRef, let aiEnhancementServiceRef else { return nil }
                guard let assignment = settingsRef.resolveAssignment(for: .noteMetadata) else {
                    return nil
                }
                let metadata = try await aiEnhancementServiceRef.generateNoteMetadata(
                    content: content,
                    apiEndpoint: assignment.endpoint ?? "",
                    apiKey: assignment.apiKey,
                    model: assignment.modelID,
                    existingTags: existingTags,
                    provider: assignment.kind
                )
                return NoteMetadata(title: metadata.title, tags: metadata.tags)
            }
        )
        self.captureSessionStore = PindropData.CaptureSessionStore(modelContext: modelContext)
        self.contextCaptureService = ContextCaptureService()
        self.contextEngineService = ContextEngineService()
        self.floatingIndicatorFocusTracker = FloatingIndicatorFocusTracker(
            contextEngineService: contextEngineService
        )
        self.toastWindowController = ToastWindowController()
        self.toastService = ToastService(presenter: toastWindowController)
        self.automaticDictionaryLearningService = AutomaticDictionaryLearningService(
            snapshotProvider: contextEngineService,
            dictionaryStore: dictionaryStore,
            toastService: toastService
        )
        self.promptPresetStore = PindropData.PromptPresetStore(modelContext: modelContext)
        self.captureAssignmentResolver = CaptureStageAssignmentResolver(
            settings: settingsStore,
            modelManager: modelManager,
            promptPresetStore: promptPresetStore
        )
        self.mentionRewriteService = MentionRewriteService()
        self.mediaPauseService = MediaPauseService()
        self.mediaIngestionService = MediaIngestionService()
        self.mediaPreparationService = PindropMedia.MediaPreparationService(
            fallbackTranscoder: MacFFmpegFallbackTranscoder()
        )
        self.dictationAudioRetentionService = PindropMedia.DictationAudioRetentionService(
            historyStore: historyStore,
            directoryURL: dictationAudioDirectoryURL,
            retentionPolicyProvider: { [weak settingsRef] in
                settingsRef?.dictationAudioRetention ?? .days7
            }
        )
        self.recordingState = RecordingFeatureState()
        self.mediaTranscriptionState = MediaTranscriptionFeatureState()

        self.statusBarController = StatusBarController(
            audioRecorder: audioRecorder,
            settingsStore: settingsStore
        )
        self.floatingIndicatorState = FloatingIndicatorState()
        self.liveTranscriptState = LiveTranscriptState()
        self.streamingSession = StreamingSessionController(
            transcriptionService: transcriptionService,
            settingsStore: settingsStore,
            dictionaryStore: dictionaryStore,
            outputManager: outputManager,
            toastService: toastService,
            liveTranscriptState: liveTranscriptState,
            audioRecorder: audioRecorder,
            captureSessionStore: captureSessionStore,
            normalizeText: { AppCoordinator.normalizedTranscriptionText($0) },
            isEffectivelyEmptyText: { AppCoordinator.isTranscriptionEffectivelyEmpty($0) }
        )
        self.floatingIndicatorController = FloatingIndicatorController(
            state: floatingIndicatorState,
            liveTranscript: liveTranscriptState
        )
        self.pillFloatingIndicatorController = PillFloatingIndicatorController(
            state: floatingIndicatorState,
            settingsStore: settingsStore,
            liveTranscript: liveTranscriptState
        )
        self.caretBubbleFloatingIndicatorController = CaretBubbleFloatingIndicatorController(
            state: floatingIndicatorState,
            liveTranscript: liveTranscriptState
        )
        self.orbFloatingIndicatorController = OrbFloatingIndicatorController(
            state: floatingIndicatorState,
            settingsStore: settingsStore,
            liveTranscript: liveTranscriptState
        )
        self.floatingIndicatorPresenters = [
            .notch: floatingIndicatorController,
            .pill: pillFloatingIndicatorController,
            .bubble: caretBubbleFloatingIndicatorController,
            .orb: orbFloatingIndicatorController
        ]
        self.onboardingController = OnboardingWindowController()
        self.announcementController = AnnouncementWindowController()
        self.announcementService = AnnouncementService(
            settingsStore: settingsStore,
            presenter: announcementController
        )
        self.telemetryConsentController = TelemetryConsentWindowController()
        self.telemetryConsentService = TelemetryConsentService(
            settingsStore: settingsStore,
            presenter: telemetryConsentController
        )
        let splashState = SplashScreenState()
        self.splashController = SplashWindowController(state: splashState)
        self.settingsWindowController = SettingsWindowController(
            settings: settingsStore,
            modelContainer: modelContainer,
            launchAtLoginManager: launchAtLoginManager,
            updateService: updateService
        )
        self.mainWindowController = MainWindowController()
        self.mainWindowController.setModelContainer(modelContainer)
        self.noteEditorWindowController = NoteEditorWindowController()
        self.noteEditorWindowController.setModelContainer(modelContainer)
        self.mainWindowController.configureCapture(
            floatingIndicatorState: floatingIndicatorState,
            recordingState: recordingState,
            onStartDictation: { [weak self] in
                self?.handleMainWindowDictationStart()
            },
            onStartVoiceNote: { [weak self] in
                self?.handleMainWindowVoiceNoteStart()
            },
            onStartMeeting: { [weak self] expectedSpeakerCount in
                self?.handleStartMeetingCapture(expectedSpeakerCount: expectedSpeakerCount) ?? false
            }
        )
        self.mainWindowController.configureTranscribeFeature(
            state: mediaTranscriptionState,
            modelManager: modelManager,
            settingsStore: settingsStore,
            onImportMediaFiles: { [weak self] urls, options in
                self?.handleImportMediaFiles(urls, options: options)
            },
            onSubmitMediaLink: { [weak self] link, options in
                self?.handleSubmitMediaLink(link, options: options)
            },
            onDownloadDiarizationModel: { [weak self] in
                self?.handleDownloadDiarizationModel()
            }
        )

        self.statusBarController.onToggleRecording = { [weak self] in
            await self?.handleToggleRecording(source: .statusBarMenu)
        }

        self.statusBarController.onCopyLastTranscript = { [weak self] in
            await self?.handleCopyLastTranscript()
        }

        self.statusBarController.onPasteLastTranscript = { [weak self] in
            await self?.handlePasteLastTranscript()
        }

        self.statusBarController.onExportLastTranscript = { [weak self] in
            await self?.handleExportLastTranscript()
        }

        self.statusBarController.onClearAudioBuffer = { [weak self] in
            await self?.handleClearAudioBuffer()
        }

        self.statusBarController.onCancelOperation = { [weak self] in
            await self?.handleCancelOperation()
        }

        self.statusBarController.onSelectPromptPreset = { [weak self] option in
            self?.handleSelectPromptPreset(option)
        }

        self.statusBarController.onOpenLibrary = { [weak self] in
            self?.handleOpenLibrary()
        }

        self.statusBarController.onShowApp = { [weak self] in
            self?.handleShowApp()
        }

        self.statusBarController.onMenuWillOpen = { [weak self] in
            self?.refreshStatusBarPresets()
        }

        self.statusBarController.onOpenSettings = { [weak self] tab in
            self?.settingsWindowController.show(tab: tab)
        }
        self.mainWindowController.onOpenSettings = { [weak self] tab in
            self?.settingsWindowController.show(tab: tab)
        }
        
        self.audioRecorder.onAudioLevel = { [weak self] level in
            self?.floatingIndicatorState.updateAudioLevel(level)
            if self?.isRecordingFeatureCaptureActive == true {
                self?.recordingState.audioLevel = level
            }
        }
        self.audioRecorder.onAudioBandLevels = { [weak self] bands in
            self?.floatingIndicatorState.updateBandLevels(bands)
        }
        self.streamingSession.configure(postStopEnhance: { [weak self] text, vocabularyWords in
            await self?.runBasicPostStopEnhance(text: text, vocabularyWords: vocabularyWords)
        })

        self.audioRecorder.onCaptureError = { [weak self] error in
            self?.handleAudioCaptureFailure(error)
        }

        let floatingIndicatorActions = FloatingIndicatorActions(
            onStartRecording: { [weak self] type in
                Task { @MainActor in
                    await self?.handleToggleRecording(source: self?.recordingTriggerSourceForIndicatorStart(type) ?? .floatingIndicatorStart)
                }
            },
            onStopRecording: { [weak self] type in
                Task { @MainActor in
                    await self?.handleToggleRecording(source: self?.recordingTriggerSourceForIndicatorStop(type) ?? .floatingIndicatorStop)
                }
            },
            onCancelRecording: { [weak self] in
                Task { @MainActor in
                    await self?.handleCancelOperation()
                }
            },
            onHideForOneHour: { [weak self] in
                self?.handleHideFloatingIndicatorForOneHour()
            },
            onReportIssue: { [weak self] in
                self?.handleReportIssue()
            },
            onGoToSettings: { [weak self] in
                self?.statusBarController.showSettings(tab: .general)
            },
            onOpenLibrary: { [weak self] in
                self?.handleOpenLibrary()
            },
            onPasteLastTranscript: { [weak self] in
                await self?.handlePasteLastTranscript()
            },
            onSelectInputDeviceUID: { [weak self] uid in
                self?.handleSelectInputDeviceUID(uid)
            },
            onSelectLanguage: { [weak self] language in
                self?.handleSelectLanguage(language)
            },
            onToastAnchorChanged: { [weak self] in
                self?.toastWindowController.repositionActiveToast()
            },
            availableInputDevicesProvider: {
                AudioDeviceManager.inputDevices().map { (uid: $0.uid, displayName: $0.displayName) }
            },
            selectedInputDeviceUIDProvider: { [weak self] in
                self?.settingsStore.selectedInputDeviceUID ?? ""
            },
            selectedLanguageProvider: { [weak self] in
                self?.settingsStore.selectedAppLanguage ?? .automatic
            },
            anchorProvider: { [weak self] in
                self?.contextEngineService.captureFocusedElementAnchorRect()
            },
            preferredScreenProvider: { [weak self] in
                self?.floatingIndicatorFocusTracker.preferredScreen()
            }
        )

        for presenter in self.floatingIndicatorPresenters.values {
            presenter.configure(actions: floatingIndicatorActions)
        }
        self.toastWindowController.configureIndicatorAnchorProvider { [weak self] in
            guard let self else { return nil }
            let type = self.settingsStore.selectedFloatingIndicatorType
            guard type.anchorsToastsToIndicator else { return nil }
            return self.floatingIndicatorPresenters[type]?.toastAnchor()
        }
        self.floatingIndicatorState.updateHotkeys(
            toggleHotkey: settingsStore.toggleHotkey,
            pushToTalkHotkey: settingsStore.pushToTalkHotkey
        )

        self.lastObservedSettingsSnapshot = currentSettingsObservationSnapshot()
        if self.enableSystemHooks {
            setupHotkeys()
            setupEscapeKeyMonitor()
            setupModifierKeyMonitor()
            setupInputDeviceMonitoring()
        } else {
            Log.app.debug("Skipping global hotkey and key monitor setup in test environment")
        }
        observeSettings()
        setupNotifications()
        Log.boot.info("AppCoordinator init finished enableSystemHooks=\(self.enableSystemHooks)")
    }
    
    private func setupNotifications() {
        notificationResources.install(
            NotificationCenter.default.addObserver(
                forName: .switchModel,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                guard let modelName = notification.userInfo?["modelName"] as? String else {
                    return
                }
                Task { @MainActor [weak self] in
                    guard let self, !self.isShutdown else { return }
                    await self.switchToModel(named: modelName)
                }
            }
        )

        notificationResources.install(
            NotificationCenter.default.addObserver(
                forName: .requestActiveModel,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self, !self.isShutdown,
                          let activeModel = self.activeModelName else { return }
                    NotificationCenter.default.post(
                        name: .modelActiveChanged,
                        object: nil,
                        userInfo: ["modelName": activeModel]
                    )
                }
            }
        )

        notificationResources.install(
            NotificationCenter.default.addObserver(
                forName: .showWhatsNew,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self, !self.isShutdown else { return }
                    self.handleShowWhatsNew()
                }
            }
        )

        notificationResources.install(
            NotificationCenter.default.addObserver(
                forName: .copyTextWithUndo,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                Task { @MainActor [weak self] in
                    guard let self, !self.isShutdown else { return }
                    self.handleCopyTextWithUndoNotification(notification)
                }
            }
        )

        notificationResources.install(
            NotificationCenter.default.addObserver(
                forName: .noteSpeakToAppendRequest,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                // `queue: .main` delivers on MainActor. Install/cancel the task
                // before returning so a Stop cannot race a deferred Start task.
                MainActor.assumeIsolated {
                    self?.handleNoteAppendRequestNotification(notification)
                }
            }
        )
    }
    
    // MARK: - Lifecycle
    
    func start(launchSemantics: StartupLaunchSemantics = .normal) async {
        Log.boot.info("AppCoordinator.start() entered hasCompletedOnboarding=\(settingsStore.hasCompletedOnboarding) selectedModel=\(settingsStore.selectedModel)")
        telemetryService.send(
            .appLaunched,
            parameters: [
                TelemetryParameter.backend: settingsStore.resolvedTranscriptionBackend.rawValue,
                TelemetryParameter.model: settingsStore.selectedModel,
                TelemetryParameter.locale: settingsStore.selectedAppLocale.locale.identifier
            ]
        )
        if !settingsStore.hasCompletedOnboarding {
            Log.boot.info("Taking onboarding path (skipping splash and normal operation until complete)")
            showOnboarding()
            return
        }

        Log.boot.info("Taking normal startup path: seed presets, splash, startNormalOperation")
        seedBuiltInPresetsIfNeeded()
        refreshStatusBarPresets()

        let shouldOrderMainWindowFront = StartupWindowPresentationPolicy.shouldOrderMainWindowFront(
            for: .init(
                launchWithoutShowingWindow: settingsStore.launchWithoutShowingWindow,
                launchSemantics: launchSemantics,
                hasCompletedOnboarding: settingsStore.hasCompletedOnboarding
            )
        )
        Log.boot.info(
            "Startup window presentation orderFront=\(shouldOrderMainWindowFront) preference=\(settingsStore.launchWithoutShowingWindow) hideFlag=\(launchSemantics.launchServicesRequestedHide)"
        )

        // Skip splash / main window / auto What's New so silent launches never
        // flash non-onboarding chrome. Manual menu-bar access still opens later.
        if shouldOrderMainWindowFront {
            splashController.show()
        }

        await startNormalOperation()

        if shouldOrderMainWindowFront {
            splashController.dismiss { [weak self] in
                self?.mainWindowController.show()
                self?.presentAnnouncementAfterStartup()
            }
        } else {
            // Keep the main window out of AppKit restoration/frontmost state.
            mainWindowController.hide()
            Log.boot.info("Silent startup: suppressed main window and auto announcement presentation")
        }
        Log.boot.info("AppCoordinator.start() finished normal path")
    }

    private func showOnboarding() {
        Log.boot.info("showOnboarding: presenting onboarding window")
        onboardingController.showOnboarding(
            settings: settingsStore,
            modelManager: modelManager,
            transcriptionService: transcriptionService,
            permissionManager: permissionManager,
            onComplete: { [weak self] in
                Task { @MainActor in
                    self?.announcementService.markCurrentAnnouncementSeen()
                    await self?.finishPostOnboardingSetup()
                    self?.mainWindowController.show()
                    self?.showWelcomePopoverAfterDelay()
                    // Consent was answered via the onboarding permissions step;
                    // this sends only if the user opted in there.
                    self?.telemetryService.send(
                        .onboardingCompleted,
                        parameters: [
                            TelemetryParameter.model: self?.settingsStore.selectedModel ?? ""
                        ]
                    )
                }
            }
        )
    }

    private func presentAnnouncementAfterStartup() {
        guard !AppTestMode.isRunningAnyTests else {
            Log.app.debug("Skipping announcement presentation in test mode")
            return
        }

        // Telemetry consent takes priority; when it presents, defer What's New to
        // the next launch so the two windows never stack.
        if telemetryConsentService.presentConsentIfNeeded(
            hasCompletedOnboarding: settingsStore.hasCompletedOnboarding
        ) {
            return
        }

        announcementService.presentCurrentAnnouncementIfNeeded(
            hasCompletedOnboarding: settingsStore.hasCompletedOnboarding
        )
    }


    private func handleShowWhatsNew() {
        guard !AppTestMode.isRunningAnyTests else {
            Log.app.debug("Skipping manual announcement presentation in test mode")
            return
        }

        announcementService.showCurrentAnnouncement()
    }
    
    private func showWelcomePopoverAfterDelay() {
        Task {
            try? await Task.sleep(for: .milliseconds(400))
            statusBarController.showWelcomePopover()
        }
    }
    
    private func finishPostOnboardingSetup() async {
        Log.boot.info("finishPostOnboardingSetup begin")
        seedBuiltInPresetsIfNeeded()
        refreshStatusBarPresets()
        registerHotkeysFromSettings()

        ensureAccessibilityPermissionForDirectInsert(trigger: "post-onboarding", showFallbackAlert: false)
        updateVibeRuntimeStateFromSettings()
        Log.boot.info("finishPostOnboardingSetup complete")
    }
    
    private func seedBuiltInPresetsIfNeeded() {
        do {
            try promptPresetStore.seedBuiltInPresets()
            Log.app.debug("Synced built-in prompt presets")
        } catch {
            Log.app.error("Failed to seed built-in presets: \(error)")
        }

        applyDefaultPromptPresetIfNeeded()
    }

    private func refreshStatusBarPresets() {
        do {
            let presets = try promptPresetStore.fetchAll()
            let options = presets.map {
                StatusBarController.PromptPresetOption(
                    id: $0.id.uuidString,
                    assignmentID: $0.builtInIdentifier ?? $0.id.uuidString,
                    name: $0.name
                )
            }
            statusBarController.updatePromptPresets(options)
        } catch {
            statusBarController.updatePromptPresets([])
            Log.app.error("Failed to refresh status bar presets: \(error)")
        }
    }

    /// One-shot migration: select the "Clean Transcript" built-in preset as the
    /// default for users who never explicitly chose a preset and never
    /// customized the generic fallback prompt.
    private func applyDefaultPromptPresetIfNeeded() {
        guard !settingsStore.didMigrateToCleanTranscriptDefault else { return }
        guard settingsStore.selectedPresetId == nil else {
            settingsStore.didMigrateToCleanTranscriptDefault = true
            return
        }
        // The v2 AI config migrator already seeds transcriptionEnhancement with a
        // promptPresetID (defaulting to "clean"), so this legacy default-prompt migration
        // is a no-op once v2 migration has completed.
        guard !settingsStore.aiConfigV2Migrated else {
            settingsStore.didMigrateToCleanTranscriptDefault = true
            return
        }
        guard settingsStore.aiEnhancementPrompt == SettingsStore.Defaults.aiEnhancementPrompt else {
            settingsStore.didMigrateToCleanTranscriptDefault = true
            return
        }

        do {
            let builtIns = try promptPresetStore.fetchBuiltIn()
            let target = BuiltInPresets.defaultPreset.identifier
            if let preset = builtIns.first(where: { $0.builtInIdentifier == target }) {
                settingsStore.selectedPresetId = preset.id.uuidString
                Log.app.info("Applied default prompt preset '\(preset.name)' for new user")
            } else {
                Log.app.error("Default prompt preset '\(target)' not found after seeding")
            }
        } catch {
            Log.app.error("Failed to apply default prompt preset: \(error)")
        }

        settingsStore.didMigrateToCleanTranscriptDefault = true
    }

    private func setActiveModel(_ modelName: String) {
        activeModelName = modelName
        NotificationCenter.default.post(
            name: .modelActiveChanged,
            object: nil,
            userInfo: ["modelName": modelName]
        )
    }

    static func shouldAttemptWhisperModelRepair(after error: Error) -> Bool {
        !isNetworkConnectivityError(error)
    }

    static func isNetworkConnectivityError(_ error: Error) -> Bool {
        if containsNetworkURLError(error) {
            return true
        }

        let descriptions = [
            (error as? LocalizedError)?.errorDescription,
            error.localizedDescription
        ].compactMap { $0?.lowercased() }

        let networkFragments = [
            "internet connection appears to be offline",
            "not connected to the internet",
            "network connection was lost",
            "cannot find host",
            "could not find host",
            "could not connect to the server",
            "a server with the specified hostname could not be found",
            "request timed out",
            "connection timed out",
            "dns lookup failed"
        ]

        return descriptions.contains { description in
            networkFragments.contains { description.contains($0) }
        }
    }

    private static func containsNetworkURLError(_ error: Error, depth: Int = 0) -> Bool {
        guard depth < 4 else { return false }

        let nsError = error as NSError
        let networkCodes: Set<URLError.Code> = [
            .notConnectedToInternet,
            .networkConnectionLost,
            .cannotFindHost,
            .cannotConnectToHost,
            .dnsLookupFailed,
            .timedOut,
            .internationalRoamingOff,
            .callIsActive,
            .dataNotAllowed,
            .secureConnectionFailed
        ]

        if nsError.domain == NSURLErrorDomain,
           networkCodes.contains(URLError.Code(rawValue: nsError.code)) {
            return true
        }

        if let underlyingError = nsError.userInfo[NSUnderlyingErrorKey] as? Error,
           containsNetworkURLError(underlyingError, depth: depth + 1) {
            return true
        }

        if let underlyingErrors = nsError.userInfo[NSMultipleUnderlyingErrorsKey] as? [Error] {
            return underlyingErrors.contains {
                containsNetworkURLError($0, depth: depth + 1)
            }
        }

        return false
    }

    private func loadAndActivateModel(
        named modelName: String,
        provider: PindropSpeech.ModelManager.ModelProvider
    ) async throws {
        do {
            if provider == .whisperKit,
               let localModelPath = modelManager.existingLocalModelPath(for: modelName) {
                Log.model.info("Loading WhisperKit model \(modelName) from local folder: \(localModelPath.path)")
                try await transcriptionService.loadModel(modelPath: localModelPath.path)
            } else {
                try await transcriptionService.loadModel(modelName: modelName, provider: provider)
            }
        } catch {
            telemetryService.send(
                .modelLoadFailed,
                parameters: [
                    TelemetryParameter.model: modelName,
                    TelemetryParameter.errorCase: TelemetryService.errorCaseName(error)
                ]
            )
            throw error
        }
        setActiveModel(modelName)
    }

    private func updateSplashDownloadState(
        with snapshot: PindropSpeech.ModelManager.DownloadSnapshot,
        displayName: String
    ) {
        let loadingText: String

        switch snapshot.phase {
        case .idle, .listing, .downloading:
            loadingText = "Downloading \(displayName)..."
        case .compiling, .preparing:
            loadingText = "Preparing \(displayName)..."
        case .completed:
            splashController.updateProgress(snapshot.progress)
            return
        }

        splashController.updateDownload(text: loadingText, progress: snapshot.progress)
    }

    private func attemptWhisperModelRepairAndReload(
        modelName: String,
        displayName: String,
        loadError: Error
    ) async throws {
        Log.boot.info("attemptWhisperModelRepairAndReload begin model=\(modelName)")

        guard Self.shouldAttemptWhisperModelRepair(after: loadError) else {
            Log.model.warning("Skipping Whisper model repair for \(modelName) after network/offline load failure; local model folder will not be deleted. Error: \(loadError.localizedDescription)")
            Log.boot.warning("attemptWhisperModelRepairAndReload skipped network/offline error model=\(modelName)")
            throw loadError
        }

        Log.model.warning("Selected Whisper model failed to load, attempting repair for \(modelName)")

        do {
            try await modelManager.deleteModel(named: modelName)
        } catch PindropSpeech.ModelManager.ModelError.modelNotFound {
            Log.model.debug("Model \(modelName) was not present when starting repair")
        }

        splashController.setDownloading("Repairing \(displayName)...")
        try await modelManager.downloadModel(named: modelName) { [weak self] snapshot in
            Task { @MainActor in
                self?.updateSplashDownloadState(with: snapshot, displayName: displayName)
            }
        }

        splashController.setLoading("Loading \(displayName)...")
        try await loadAndActivateModel(named: modelName, provider: .whisperKit)
        Log.boot.info("attemptWhisperModelRepairAndReload finished OK model=\(modelName)")
    }

    private func handleModelLoadError(_ error: Error, context: String) {
        self.error = error
        Log.app.error("\(context): \(error)")

    }
    
    private func startNormalOperation() async {
        Log.boot.info("startNormalOperation begin")
        // Sync launch at login state on startup
        let actualLaunchAtLoginState = launchAtLoginManager.isEnabled
        if settingsStore.launchAtLogin != actualLaunchAtLoginState {
            settingsStore.launchAtLogin = actualLaunchAtLoginState
            Log.app.info("Synced launch at login state: \(actualLaunchAtLoginState)")
        }

        // Sweep expired dictation audio at launch and every 24h thereafter.
        dictationAudioRetentionService.startPeriodicSweep()

        let micStatus = permissionManager.checkPermissionStatus()
        if micStatus == .denied || micStatus == .restricted {
            Log.app.warning("Microphone permission denied - recording will not work")
            AlertManager.shared.showMicrophonePermissionAlert()
        } else if micStatus == .notDetermined {
            Log.app.info("Microphone permission not determined at launch; request deferred until recording starts")
        }

        ensureAccessibilityPermissionForDirectInsert(trigger: "startup", showFallbackAlert: false)

        var modelName = settingsStore.selectedModel

        if !modelManager.availableModels.contains(where: { $0.name == modelName }) {
            Log.model.warning("Selected model \(modelName) is not recognized, resetting to default")
            modelName = SettingsStore.Defaults.selectedModel
            settingsStore.selectedModel = modelName
        }

        let selectedModel = modelManager.availableModels.first(where: { $0.name == modelName })
        let selectedProvider = selectedModel?.provider ?? .whisperKit
        let selectedDisplayName = selectedModel?.displayName ?? modelName
        
        await modelManager.refreshDownloadedModels()
        let modelExists = modelManager.isModelDownloaded(modelName)
        
        if modelExists {
            splashController.setLoading("Loading model...")
            Log.model.info("Model \(modelName) found, loading...")
            do {
                try await loadAndActivateModel(named: modelName, provider: selectedProvider)
                Log.model.info("Model loaded successfully")
            } catch {
                if selectedProvider == .whisperKit {
                    do {
                        try await attemptWhisperModelRepairAndReload(
                            modelName: modelName,
                            displayName: selectedDisplayName,
                            loadError: error
                        )
                        Log.model.info("Model repaired and loaded successfully")
                    } catch {
                        handleModelLoadError(error, context: "Failed to repair transcription model")
                    }
                } else {
                    handleModelLoadError(error, context: "Failed to load transcription model")
                }
            }
        } else {
            // Model missing - check if any model is available for fallback
            let downloadedModels = await modelManager.getDownloadedModels()
            
            if let fallbackModel = downloadedModels.first {
                Log.model.info("Selected model \(modelName) not found, falling back to \(fallbackModel.name)")
                splashController.setLoading("Using \(fallbackModel.displayName)...")
                settingsStore.selectedModel = fallbackModel.name
                do {
                    try await loadAndActivateModel(named: fallbackModel.name, provider: fallbackModel.provider)
                    Log.model.info("Fallback model loaded successfully")
                } catch {
                    handleModelLoadError(error, context: "Failed to load fallback model")
                }
            } else {
                // No models available - download the selected one
                splashController.setDownloading("Downloading \(selectedDisplayName)...")
                Log.model.info("Model \(modelName) not found, downloading...")
                
                do {
                    try await modelManager.downloadModel(named: modelName) { [weak self] snapshot in
                        Task { @MainActor in
                            self?.updateSplashDownloadState(with: snapshot, displayName: selectedDisplayName)
                        }
                    }
                    splashController.setLoading("Loading model...")
                    Log.model.info("Model downloaded, loading...")
                    try await loadAndActivateModel(named: modelName, provider: selectedProvider)
                    Log.model.info("Model loaded successfully")
                } catch {
                    handleModelLoadError(error, context: "Failed to download/load model")
                }
            }
        }

        // Load recent transcripts for the menu
        updateRecentTranscriptsMenu()

        updateFloatingIndicatorVisibility()

        updateVibeRuntimeStateFromSettings()
        applyMCPServerSettings()
        prewarmStreamingEngineIfEnabled()
        scheduleMeetingRecovery()
        Log.boot.info("startNormalOperation complete")
    }
    private func scheduleMeetingRecovery() {
        guard Self.canBeginMeetingRecovery(
            activeHandle: meetingCaptureContext?.handle,
            recoveryTaskActive: meetingRecoveryTask != nil,
            isShutdown: isShutdown || isPreparingForTermination
        ) else { return }

        meetingRecoveryGeneration &+= 1
        let generation = meetingRecoveryGeneration
        meetingRecoveryTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if self.meetingRecoveryGeneration == generation {
                    self.meetingRecoveryHandle = nil
                    self.meetingRecoveryTask = nil
                }
            }

            let cancelledSessionIDs: [UUID]
            do {
                cancelledSessionIDs = try self.captureSessionStore.cancelledMeetingCaptureSessionIDs()
            } catch {
                cancelledSessionIDs = []
                Log.app.warning("Cancelled meeting cleanup candidates unavailable: \(error.localizedDescription)")
            }

            for sessionID in cancelledSessionIDs {
                do {
                    try Task.checkCancellation()
                    guard
                        !self.isShutdown,
                        !self.isPreparingForTermination,
                        self.meetingRecoveryGeneration == generation
                    else {
                        throw CancellationError()
                    }
                    try await self.mediaIngestionService.removeMeetingCaptureArtifacts(for: sessionID)
                } catch is CancellationError {
                    return
                } catch {
                    Log.app.warning(
                        "Cancelled meeting cleanup deferred for \(sessionID.uuidString): \(error.localizedDescription)"
                    )
                }
            }

            let candidates: [PindropData.MeetingRecoverySnapshot]
            do {
                candidates = try self.captureSessionStore.meetingRecoveryCandidates()
            } catch {
                Log.app.warning("Meeting recovery candidates unavailable: \(error.localizedDescription)")
                return
            }

            for candidate in candidates {
                do {
                    try Task.checkCancellation()
                    guard
                        !self.isShutdown,
                        !self.isPreparingForTermination,
                        self.meetingRecoveryGeneration == generation
                    else {
                        throw CancellationError()
                    }
                    self.meetingRecoveryHandle = candidate.handle

                    try self.ensureMeetingRecoveryCurrent(
                        generation: generation,
                        handle: candidate.handle
                    )
                    _ = try self.captureSessionStore.ensureMeetingHumanAnchor(
                        candidate.handle,
                        title: localized(
                            "Untitled Note",
                            locale: self.settingsStore.selectedAppLocale.locale
                        ),
                        at: .now
                    )
                    try self.ensureMeetingRecoveryCurrent(
                        generation: generation,
                        handle: candidate.handle
                    )
                    try self.captureSessionStore.interruptMeetingCapture(
                        candidate.handle,
                        errorDomain: "Pindrop",
                        errorCode: "startup-recovery",
                        message: "Recovered after application interruption.",
                        at: .now
                    )

                    try self.ensureMeetingRecoveryCurrent(
                        generation: generation,
                        handle: candidate.handle
                    )
                    try self.captureSessionStore.recoverMeetingForFinalization(candidate.handle, at: .now)

                    let spoolPlan = try await self.mediaIngestionService.makeMeetingCaptureSpoolPlan(
                        sessionID: candidate.handle.sessionID,
                        microphoneSourceID: candidate.handle.microphoneSourceID,
                        systemAudioSourceID: candidate.handle.systemAudioSourceID
                    )
                    try self.ensureMeetingRecoveryCurrent(
                        generation: generation,
                        handle: candidate.handle
                    )

                    let recovery = try await self.reconcileMeetingArtifacts(
                        handle: candidate.handle,
                        spoolPlan: spoolPlan,
                        operationGuard: {
                            try self.ensureMeetingRecoveryCurrent(
                                generation: generation,
                                handle: candidate.handle
                            )
                        }
                    )

                    try self.ensureMeetingRecoveryCurrent(
                        generation: generation,
                        handle: candidate.handle
                    )
                    try self.finishMeetingSources(
                        handle: candidate.handle,
                        artifacts: recovery.sealedChunks,
                        recoveryFailures: recovery.failures,
                        stopResult: nil
                    )

                    try self.ensureMeetingRecoveryCurrent(
                        generation: generation,
                        handle: candidate.handle
                    )
                    try await self.finalizeMeetingCapture(
                        candidate.handle,
                        spoolPlan: spoolPlan,
                        operationGuard: {
                            try self.ensureMeetingRecoveryCurrent(
                                generation: generation,
                                handle: candidate.handle
                            )
                        }
                    )
                } catch let failure as MeetingNoteGenerationFailure {
                    guard Self.shouldContinueMeetingRecovery(after: failure) else {
                        return
                    }
                    guard self.isMeetingRecoveryCurrent(
                        generation: generation,
                        handle: candidate.handle
                    ) else {
                        return
                    }
                    Log.app.warning(
                        "Meeting recovery deferred note generation for \(candidate.handle.sessionID.uuidString): \(failure.message)"
                    )
                } catch {
                    guard Self.shouldContinueMeetingRecovery(after: error) else {
                        return
                    }
                    guard self.isMeetingRecoveryCurrent(
                        generation: generation,
                        handle: candidate.handle
                    ) else {
                        return
                    }
                    let nsError = error as NSError
                    try? self.captureSessionStore.recordMeetingFinalizationFailure(
                        candidate.handle,
                        stage: .finalTranscription,
                        domain: nsError.domain,
                        code: String(nsError.code),
                        message: error.localizedDescription,
                        retryable: true,
                        at: .now
                    )
                    Log.app.warning(
                        "Meeting recovery deferred for \(candidate.handle.sessionID.uuidString): \(error.localizedDescription)"
                    )
                }
            }
        }
    }

    /// Seals and inventories an active meeting before AppKit is allowed to terminate.
    ///
    /// This is deliberately awaited by the AppKit terminate-later bridge. `shutdown()`
    /// remains synchronous and only provides a best-effort persistence fallback for
    /// callers that cannot await this preparation.
    func prepareForTermination() async {
        guard !isShutdown, !isPreparingForTermination else { return }
        isPreparingForTermination = true
        defer { isPreparingForTermination = false }

        let noteAppendStartTask = pendingNoteAppendStartTask
        let meetingStartTask = pendingMeetingCaptureStartTask
        let windowStartTask = mainWindowCaptureStartTask
        let cancellationTasks = Array(meetingCancellationTasks.values)
        cancelPendingNoteAppendStart()
        cancelPendingMeetingCaptureStart()
        recordingState.invalidateCaptureStart()
        windowStartTask?.cancel()
        if let noteAppendStartTask {
            await noteAppendStartTask.value
        }
        if let meetingStartTask {
            await meetingStartTask.value
        }
        if let windowStartTask {
            await windowStartTask.value
        }
        for cancellationTask in cancellationTasks {
            await cancellationTask.value
        }
        meetingCancellationTasks.removeAll()
        mainWindowCaptureStartTask = nil
        do {
            try await cancelPendingMeetingCaptureStartHandle()
        } catch {
            reportMeetingCaptureTerminalPersistenceFailure(error)
        }

        meetingRecoveryGeneration &+= 1
        meetingRecoveryTask?.cancel()
        if let meetingRecoveryTask {
            await meetingRecoveryTask.value
        }
        meetingRecoveryTask = nil
        meetingRecoveryHandle = nil

        guard let context = meetingCaptureContext else { return }
        await checkpointMeetingInterruptionForTermination(context)
        clearMeetingCaptureContext(ifCurrent: context)
    }

    private func checkpointMeetingInterruptionForTermination(_ context: MeetingCaptureContext) async {
        do {
            try ensureMeetingCaptureCurrent(context)
            try captureSessionStore.beginMeetingFinalization(context.handle, at: .now)

            let stopResult = try await audioRecorder.stopMeetingRecording()
            try ensureMeetingCaptureCurrent(context)
            for chunk in stopResult.sealedChunks {
                try ensureMeetingCaptureCurrent(context)
                try captureSessionStore.recordSealedMeetingChunk(context.handle, chunk: chunk, at: .now)
            }
            let recovery = try await reconcileMeetingArtifacts(
                handle: context.handle,
                spoolPlan: context.spoolPlan,
                operationGuard: { try self.ensureMeetingCaptureCurrent(context) }
            )
            try ensureMeetingCaptureCurrent(context)
            try finishMeetingSources(
                handle: context.handle,
                artifacts: recovery.sealedChunks,
                recoveryFailures: recovery.failures,
                stopResult: stopResult
            )
            try ensureMeetingCaptureCurrent(context)
            try captureSessionStore.interruptMeetingCapture(
                context.handle,
                errorDomain: "Pindrop",
                errorCode: "lifecycle-shutdown",
                message: "Meeting capture was interrupted by application shutdown and can be resumed.",
                at: .now
            )
        } catch {
            let nsError = error as NSError
            if isMeetingCaptureContextCurrent(context) {
                try? captureSessionStore.interruptMeetingCapture(
                    context.handle,
                    errorDomain: nsError.domain,
                    errorCode: String(nsError.code),
                    message: "Meeting capture was interrupted during shutdown: \(error.localizedDescription)",
                    at: .now
                )
            }
        }
    }

    /// Loads the streaming (Nemotron) engine and runs its CoreML warm-up inference
    /// in the background so the first dictation session doesn't pay that cost while
    /// the recording indicator is animating in. `prepareStreamingEngine` coalesces
    /// concurrent callers, so a session that starts mid-prewarm awaits this same
    /// load rather than failing over to batch.
    private func prewarmStreamingEngineIfEnabled() {
        guard settingsStore.streamingFeatureEnabled else { return }
        Task(priority: .utility) { [weak self] in
            guard let self else { return }
            do {
                try await self.transcriptionService.prepareStreamingEngine()
                Log.boot.info("Streaming engine prewarmed")
            } catch {
                // Model not downloaded yet, etc. — the session path handles
                // fallback; the next session simply pays the load as before.
                Log.transcription.info("Streaming engine prewarm skipped: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - MCP Server

    private func applyMCPServerSettings() {
        if settingsStore.mcpServerEnabled {
            startMCPServerIfNeeded()
        } else {
            stopMCPServerIfRunning()
        }
    }

    private func startMCPServerIfNeeded() {
        let port = UInt16(clamping: settingsStore.mcpServerPort)

        // Reuse existing server if port hasn't changed
        if let existing = mcpServer, existing.port == port {
            if !existing.isRunning { existing.start() }
            return
        }

        // Stop old server (port changed)
        mcpServer?.stop()

        let token = resolvedMCPToken()
        let server = MCPServer(port: port, token: token)
        server.coordinator = self
        mcpServer = server
        server.start()
    }

    private func stopMCPServerIfRunning() {
        mcpServer?.stop()
        mcpServer = nil
    }

    private func resolvedMCPToken() -> String {
        if let existing = settingsStore.loadMCPToken(), !existing.isEmpty {
            return existing
        }
        let token = MCPTokenGenerator.generate()
        try? settingsStore.saveMCPToken(token)
        return token
    }

    /// Submits a transcription job from the MCP server (bypasses UI source validation).
    func submitMCPTranscriptionJob(_ job: MediaTranscriptionJobState) {
        enqueueOrStart(job)
    }

    /// Cancels the MCP-submitted job with the given internal state ID.
    func cancelMCPJob(stateID: UUID) {
        if mediaTranscriptionState.currentJob?.id == stateID {
            mediaTranscriptionGeneration &+= 1
            mediaQueueNeedsProcessingReset = mediaQueueNeedsProcessingReset || isProcessing
            mediaTranscriptionTask?.cancel()
            mediaTranscriptionState.clearCurrentJob()
            if mediaTranscriptionTask == nil {
                startMediaQueueContinuationIfNeeded()
            }
            Log.mcp.info("Cancelled active MCP job \(stateID)")
        } else {
            mediaTranscriptionState.pendingJobs.removeAll { $0.id == stateID }
            Log.mcp.info("Removed pending MCP job \(stateID)")
        }
    }

    /// Loads and activates a transcription model by name for MCP callers.
    func loadAndActivateModelForMCP(named modelName: String) async throws {
        guard let model = modelManager.availableModels.first(where: { $0.name == modelName }) else {
            throw PindropSpeech.ModelManager.ModelError.modelNotFound(modelName)
        }
        if !modelManager.isModelDownloaded(modelName),
           modelManager.existingLocalModelPath(for: modelName) == nil {
            try await modelManager.downloadModel(named: modelName) { _ in }
        }
        try await loadAndActivateModel(named: modelName, provider: model.provider)
        settingsStore.selectedModel = modelName
    }

    // MARK: - Hotkey Setup
    
    private func setupHotkeys() {
        registerHotkeysFromSettings()
    }
    
    private func registerHotkeysFromSettings() {
        guard enableSystemHooks else { return }

        hotkeyManager.unregisterAll()
        guard HotkeyRegistrationState.shouldRegisterHotkeys(hasCompletedOnboarding: settingsStore.hasCompletedOnboarding) else {
            Log.hotkey.info("Skipping hotkey registration until onboarding is complete")
            return
        }

        var registrationState = HotkeyRegistrationState()

        if !settingsStore.pushToTalkHotkey.isEmpty,
           let binding = validatedHotkeyBinding(
               displayName: "Push-to-Talk",
               hotkeyString: settingsStore.pushToTalkHotkey,
               keyCodeValue: settingsStore.pushToTalkHotkeyCode,
               modifiersValue: settingsStore.pushToTalkHotkeyModifiers
           ) {
            if canRegisterHotkey(
                identifier: "push-to-talk",
                displayName: "Push-to-Talk",
                hotkeyString: settingsStore.pushToTalkHotkey,
                keyCode: binding.keyCode,
                modifiers: binding.modifiers,
                registrationState: &registrationState
            ) {
                let didRegister = hotkeyManager.registerHotkey(
                    keyCode: binding.keyCode,
                    modifiers: binding.modifiers,
                    identifier: "push-to-talk",
                    mode: .pushToTalk,
                    onKeyDown: { [weak self] in
                        Task { @MainActor in
                            await self?.handlePushToTalkStart()
                        }
                    },
                    onKeyUp: { [weak self] in
                        Task { @MainActor in
                            await self?.handlePushToTalkEnd()
                        }
                    }
                )

                if !didRegister {
                    handleHotkeyRegistrationFailure(displayName: "Push-to-Talk", hotkeyString: settingsStore.pushToTalkHotkey)
                }
            }
        }

        if !settingsStore.toggleHotkey.isEmpty,
           let binding = validatedHotkeyBinding(
               displayName: "Toggle Recording",
               hotkeyString: settingsStore.toggleHotkey,
               keyCodeValue: settingsStore.toggleHotkeyCode,
               modifiersValue: settingsStore.toggleHotkeyModifiers
           ) {
            if canRegisterHotkey(
                identifier: "toggle-recording",
                displayName: "Toggle Recording",
                hotkeyString: settingsStore.toggleHotkey,
                keyCode: binding.keyCode,
                modifiers: binding.modifiers,
                registrationState: &registrationState
            ) {
                let didRegister = hotkeyManager.registerHotkey(
                    keyCode: binding.keyCode,
                    modifiers: binding.modifiers,
                    identifier: "toggle-recording",
                    mode: .toggle,
                    onKeyDown: { [weak self] in
                        Task { @MainActor in
                            await self?.handleToggleRecording(source: .hotkeyToggle)
                        }
                    },
                    onKeyUp: nil
                )

                if !didRegister {
                    handleHotkeyRegistrationFailure(displayName: "Toggle Recording", hotkeyString: settingsStore.toggleHotkey)
                }
            }
        }

        if !settingsStore.copyLastTranscriptHotkey.isEmpty,
           let binding = validatedHotkeyBinding(
               displayName: "Copy Last Transcript",
               hotkeyString: settingsStore.copyLastTranscriptHotkey,
               keyCodeValue: settingsStore.copyLastTranscriptHotkeyCode,
               modifiersValue: settingsStore.copyLastTranscriptHotkeyModifiers
           ) {
            Log.hotkey.info("Registering copy-last-transcript: keyCode=\(binding.keyCode), modifiers=0x\(String(binding.modifiers.rawValue, radix: 16)), string=\(self.settingsStore.copyLastTranscriptHotkey)")

            if canRegisterHotkey(
                identifier: "copy-last-transcript",
                displayName: "Copy Last Transcript",
                hotkeyString: settingsStore.copyLastTranscriptHotkey,
                keyCode: binding.keyCode,
                modifiers: binding.modifiers,
                registrationState: &registrationState
            ) {
                let didRegister = hotkeyManager.registerHotkey(
                    keyCode: binding.keyCode,
                    modifiers: binding.modifiers,
                    identifier: "copy-last-transcript",
                    mode: .toggle,
                    onKeyDown: { [weak self] in
                        Task { @MainActor in
                            await self?.handleCopyLastTranscript()
                        }
                    },
                    onKeyUp: nil
                )

                if !didRegister {
                    handleHotkeyRegistrationFailure(displayName: "Copy Last Transcript", hotkeyString: settingsStore.copyLastTranscriptHotkey)
                }
            }
        }

        if !settingsStore.quickCapturePTTHotkey.isEmpty,
           let binding = validatedHotkeyBinding(
               displayName: "Voice Note — Hold",
               hotkeyString: settingsStore.quickCapturePTTHotkey,
               keyCodeValue: settingsStore.quickCapturePTTHotkeyCode,
               modifiersValue: settingsStore.quickCapturePTTHotkeyModifiers
           ) {
            Log.hotkey.info("Registering quick-capture-ptt: keyCode=\(binding.keyCode), modifiers=0x\(String(binding.modifiers.rawValue, radix: 16)), string=\(self.settingsStore.quickCapturePTTHotkey)")

            if canRegisterHotkey(
                identifier: "quick-capture-ptt",
                displayName: "Voice Note — Hold",
                hotkeyString: settingsStore.quickCapturePTTHotkey,
                keyCode: binding.keyCode,
                modifiers: binding.modifiers,
                registrationState: &registrationState
            ) {
                let didRegister = hotkeyManager.registerHotkey(
                    keyCode: binding.keyCode,
                    modifiers: binding.modifiers,
                    identifier: "quick-capture-ptt",
                    mode: .pushToTalk,
                    onKeyDown: { [weak self] in
                        Task { @MainActor in
                            await self?.handleQuickCapturePTTStart()
                        }
                    },
                    onKeyUp: { [weak self] in
                        Task { @MainActor in
                            await self?.handleQuickCapturePTTEnd()
                        }
                    }
                )

                if !didRegister {
                    handleHotkeyRegistrationFailure(displayName: "Voice Note — Hold", hotkeyString: settingsStore.quickCapturePTTHotkey)
                }
            }
        }

        if !settingsStore.quickCaptureToggleHotkey.isEmpty,
           let binding = validatedHotkeyBinding(
               displayName: "Voice Note — Toggle",
               hotkeyString: settingsStore.quickCaptureToggleHotkey,
               keyCodeValue: settingsStore.quickCaptureToggleHotkeyCode,
               modifiersValue: settingsStore.quickCaptureToggleHotkeyModifiers
           ) {
            Log.hotkey.info("Registering quick-capture-toggle: keyCode=\(binding.keyCode), modifiers=0x\(String(binding.modifiers.rawValue, radix: 16)), string=\(self.settingsStore.quickCaptureToggleHotkey)")
            if canRegisterHotkey(
                identifier: "quick-capture-toggle",
                displayName: "Voice Note — Toggle",
                hotkeyString: settingsStore.quickCaptureToggleHotkey,
                keyCode: binding.keyCode,
                modifiers: binding.modifiers,
                registrationState: &registrationState
            ) {
                let didRegister = hotkeyManager.registerHotkey(
                    keyCode: binding.keyCode,
                    modifiers: binding.modifiers,
                    identifier: "quick-capture-toggle",
                    mode: .toggle,
                    onKeyDown: { [weak self] in
                        Task { @MainActor in
                            await self?.handleQuickCaptureToggle()
                        }
                    },
                    onKeyUp: nil
                )
                if !didRegister {
                    handleHotkeyRegistrationFailure(displayName: "Voice Note — Toggle", hotkeyString: settingsStore.quickCaptureToggleHotkey)
                }
            }
        }

        if !settingsStore.openLibraryHotkey.isEmpty,
           let binding = validatedHotkeyBinding(
               displayName: "Open Library",
               hotkeyString: settingsStore.openLibraryHotkey,
               keyCodeValue: settingsStore.openLibraryHotkeyCode,
               modifiersValue: settingsStore.openLibraryHotkeyModifiers
           ) {
            Log.hotkey.info("Registering open-library: keyCode=\(binding.keyCode), modifiers=0x\(String(binding.modifiers.rawValue, radix: 16)), string=\(self.settingsStore.openLibraryHotkey)")
            if canRegisterHotkey(
                identifier: "open-library",
                displayName: "Open Library",
                hotkeyString: settingsStore.openLibraryHotkey,
                keyCode: binding.keyCode,
                modifiers: binding.modifiers,
                registrationState: &registrationState
            ) {
                let didRegister = hotkeyManager.registerHotkey(
                    keyCode: binding.keyCode,
                    modifiers: binding.modifiers,
                    identifier: "open-library",
                    mode: .toggle,
                    onKeyDown: { [weak self] in
                        Task { @MainActor in
                            self?.handleOpenLibrary()
                        }
                    },
                    onKeyUp: nil
                )
                if !didRegister {
                    handleHotkeyRegistrationFailure(displayName: "Open Library", hotkeyString: settingsStore.openLibraryHotkey)
                }
            }
        }

        if !settingsStore.cancelOperationHotkey.isEmpty,
           let binding = validatedHotkeyBinding(
               displayName: "Cancel Operation",
               hotkeyString: settingsStore.cancelOperationHotkey,
               keyCodeValue: settingsStore.cancelOperationHotkeyCode,
               modifiersValue: settingsStore.cancelOperationHotkeyModifiers
           ) {
            Log.hotkey.info("Registering cancel-operation: keyCode=\(binding.keyCode), modifiers=0x\(String(binding.modifiers.rawValue, radix: 16)), string=\(self.settingsStore.cancelOperationHotkey)")
            if canRegisterHotkey(
                identifier: "cancel-operation",
                displayName: "Cancel Operation",
                hotkeyString: settingsStore.cancelOperationHotkey,
                keyCode: binding.keyCode,
                modifiers: binding.modifiers,
                registrationState: &registrationState
            ) {
                let didRegister = hotkeyManager.registerHotkey(
                    keyCode: binding.keyCode,
                    modifiers: binding.modifiers,
                    identifier: "cancel-operation",
                    mode: .toggle,
                    onKeyDown: { [weak self] in
                        Task { @MainActor in
                            await self?.handleCancelOperation()
                        }
                    },
                    onKeyUp: nil
                )
                if !didRegister {
                    handleHotkeyRegistrationFailure(displayName: "Cancel Operation", hotkeyString: settingsStore.cancelOperationHotkey)
                }
            }
        }
    }

    private func validatedHotkeyBinding(
        displayName: String,
        hotkeyString: String,
        keyCodeValue: Int,
        modifiersValue: Int
    ) -> (keyCode: UInt32, modifiers: HotkeyManager.ModifierFlags)? {
        let localizedDisplayName = localized(displayName, locale: settingsStore.selectedAppLocale.locale)
        guard let keyCode = UInt32(exactly: keyCodeValue),
              let modifiersRawValue = UInt32(exactly: modifiersValue) else {
            Log.hotkey.error("Invalid hotkey values for \(displayName): string=\(hotkeyString), keyCode=\(keyCodeValue), modifiers=\(modifiersValue)")
            AlertManager.shared.showGenericErrorAlert(
                title: "Invalid Hotkey Configuration",
                message: "The saved hotkey for \(localizedDisplayName) is invalid. Re-record this hotkey in Settings."
            )
            return nil
        }
        return (keyCode: keyCode, modifiers: HotkeyManager.ModifierFlags(rawValue: modifiersRawValue))
    }
    private func handleHotkeyRegistrationFailure(displayName: String, hotkeyString: String) {
        let localizedDisplayName = localized(displayName, locale: settingsStore.selectedAppLocale.locale)
        Log.hotkey.error("Failed to register hotkey for \(displayName): \(hotkeyString)")
        AlertManager.shared.showGenericErrorAlert(
            title: "Hotkey Registration Failed",
            message: "Could not register '\(hotkeyString)' for \(localizedDisplayName). Choose a different shortcut in Settings."
        )
    }

    private func canRegisterHotkey(
        identifier: String,
        displayName: String,
        hotkeyString: String,
        keyCode: UInt32,
        modifiers: HotkeyManager.ModifierFlags,
        registrationState: inout HotkeyRegistrationState
    ) -> Bool {
        if let conflict = registrationState.register(
            identifier: identifier,
            keyCode: keyCode,
            modifiers: modifiers.rawValue
        ) {
            let existingDisplayName = hotkeyDisplayName(for: conflict.existingIdentifier)

            // Pre-save inline feedback in HotkeysSettingsView covers Pindrop-internal
            // conflicts; skip the blocking NSAlert for those. Still refuse to register
            // the duplicate and keep Carbon registration-failure alerts as fallback.
            Log.hotkey.error(
                "Hotkey conflict detected for \(hotkeyString): \(existingDisplayName) conflicts with \(displayName). Ignoring \(displayName)"
            )
            return false
        }

        return true
    }

    private func hotkeyDisplayName(for identifier: String) -> String {
        switch identifier {
        case "toggle-recording":
            return "Toggle Recording"
        case "push-to-talk":
            return "Push-to-Talk"
        case "copy-last-transcript":
            return "Copy Last Transcript"
        case "quick-capture-ptt":
            return "Voice Note — Hold"
        case "quick-capture-toggle":
            return "Voice Note — Toggle"
        case "open-library":
            return "Open Library"
        case "cancel-operation":
            return "Cancel Operation"
        default:
            return identifier
        }
    }
    
    // MARK: - Settings Observation
    
    private func currentSettingsObservationSnapshot() -> SettingsObservationSnapshot {
        SettingsObservationSnapshot(
            outputMode: settingsStore.outputMode,
            automaticDictionaryLearningEnabled: settingsStore.automaticDictionaryLearningEnabled,
            selectedInputDeviceUID: settingsStore.selectedInputDeviceUID,
            selectedAppLocale: settingsStore.selectedAppLocale,
            selectedAppLanguage: settingsStore.selectedAppLanguage,
            floatingIndicatorEnabled: settingsStore.floatingIndicatorEnabled,
            floatingIndicatorType: settingsStore.selectedFloatingIndicatorType,
            aiEnhancementEnabled: settingsStore.assignment(for: .transcriptionEnhancement) != nil,
            enableUIContext: settingsStore.enableUIContext,
            vibeLiveSessionEnabled: settingsStore.vibeLiveSessionEnabled,
            streamingFeatureEnabled: settingsStore.streamingFeatureEnabled,
            hotkeys: HotkeySettingsSnapshot(
                hasCompletedOnboarding: settingsStore.hasCompletedOnboarding,
                pushToTalk: HotkeyBindingSnapshot(
                    hotkey: settingsStore.pushToTalkHotkey,
                    keyCode: settingsStore.pushToTalkHotkeyCode,
                    modifiers: settingsStore.pushToTalkHotkeyModifiers
                ),
                toggle: HotkeyBindingSnapshot(
                    hotkey: settingsStore.toggleHotkey,
                    keyCode: settingsStore.toggleHotkeyCode,
                    modifiers: settingsStore.toggleHotkeyModifiers
                ),
                copyLastTranscript: HotkeyBindingSnapshot(
                    hotkey: settingsStore.copyLastTranscriptHotkey,
                    keyCode: settingsStore.copyLastTranscriptHotkeyCode,
                    modifiers: settingsStore.copyLastTranscriptHotkeyModifiers
                ),
                quickCapturePTT: HotkeyBindingSnapshot(
                    hotkey: settingsStore.quickCapturePTTHotkey,
                    keyCode: settingsStore.quickCapturePTTHotkeyCode,
                    modifiers: settingsStore.quickCapturePTTHotkeyModifiers
                ),
                quickCaptureToggle: HotkeyBindingSnapshot(
                    hotkey: settingsStore.quickCaptureToggleHotkey,
                    keyCode: settingsStore.quickCaptureToggleHotkeyCode,
                    modifiers: settingsStore.quickCaptureToggleHotkeyModifiers
                ),
                openLibrary: HotkeyBindingSnapshot(
                    hotkey: settingsStore.openLibraryHotkey,
                    keyCode: settingsStore.openLibraryHotkeyCode,
                    modifiers: settingsStore.openLibraryHotkeyModifiers
                ),
                cancelOperation: HotkeyBindingSnapshot(
                    hotkey: settingsStore.cancelOperationHotkey,
                    keyCode: settingsStore.cancelOperationHotkeyCode,
                    modifiers: settingsStore.cancelOperationHotkeyModifiers
                )
            ),
            mcpServerEnabled: settingsStore.mcpServerEnabled,
            mcpServerPort: settingsStore.mcpServerPort,
            dictationAudioRetention: settingsStore.dictationAudioRetention
        )
    }
    private func observeSettings() {
        settingsStore.objectWillChange
            .sink { [weak self] _ in
                Task { @MainActor in
                    guard let self = self else { return }
                    guard !self.settingsStore.isApplyingHotkeyUpdate else { return }

                    let snapshot = self.currentSettingsObservationSnapshot()
                    let previousSnapshot = self.lastObservedSettingsSnapshot ?? snapshot
                    self.lastObservedSettingsSnapshot = snapshot

                    if previousSnapshot.outputMode != snapshot.outputMode {
                        let mode: OutputMode = snapshot.outputMode == "clipboard" ? .clipboard : .directInsert
                        self.outputManager.setOutputMode(mode)
                        if mode == .directInsert {
                            self.ensureAccessibilityPermissionForDirectInsert(trigger: "settings-change", showFallbackAlert: true)
                        }
                    }

                    if previousSnapshot.selectedInputDeviceUID != snapshot.selectedInputDeviceUID {
                        self.applyPreferredInputDeviceUID(snapshot.selectedInputDeviceUID)
                        self.inputMuteMonitor?.setPreferredDeviceUID(snapshot.selectedInputDeviceUID)
                    }

                    if previousSnapshot.floatingIndicatorEnabled != snapshot.floatingIndicatorEnabled
                        || previousSnapshot.floatingIndicatorType != snapshot.floatingIndicatorType {
                        // Re-enabling or switching styles clears "hide for 1 hour";
                        // disabling leaves it alone (irrelevant while off).
                        if (!previousSnapshot.floatingIndicatorEnabled && snapshot.floatingIndicatorEnabled)
                            || previousSnapshot.floatingIndicatorType != snapshot.floatingIndicatorType {
                            self.clearFloatingIndicatorTemporaryHiddenState()
                        }
                        self.updateFloatingIndicatorVisibility(previousType: previousSnapshot.floatingIndicatorType)
                    }

                    if !previousSnapshot.streamingFeatureEnabled && snapshot.streamingFeatureEnabled {
                        self.prewarmStreamingEngineIfEnabled()
                    }

                    if previousSnapshot.hotkeys != snapshot.hotkeys {
                        self.registerHotkeysFromSettings()
                        self.floatingIndicatorState.updateHotkeys(
                            toggleHotkey: self.settingsStore.toggleHotkey,
                            pushToTalkHotkey: self.settingsStore.pushToTalkHotkey
                        )
                    }

                    if previousSnapshot.automaticDictionaryLearningEnabled
                        && !snapshot.automaticDictionaryLearningEnabled {
                        self.automaticDictionaryLearningService.cancelObservation()
                    }

                    if previousSnapshot.selectedAppLocale != snapshot.selectedAppLocale
                        || previousSnapshot.selectedAppLanguage != snapshot.selectedAppLanguage {
                        if previousSnapshot.selectedAppLocale != snapshot.selectedAppLocale {
                            Log.app.infoVisible(
                                "Interface locale changed \(previousSnapshot.selectedAppLocale.rawValue) -> \(snapshot.selectedAppLocale.rawValue)"
                            )
                        }
                        if previousSnapshot.selectedAppLanguage != snapshot.selectedAppLanguage {
                            Log.app.infoVisible(
                                "Dictation language changed \(previousSnapshot.selectedAppLanguage.rawValue) -> \(snapshot.selectedAppLanguage.rawValue)"
                            )
                        }
                        Log.app.infoVisible("Reloading localized strings after settings change")
                        self.statusBarController.reloadLocalizedStrings()
                        self.pillFloatingIndicatorController.reloadLocalizedStrings()
                        self.orbFloatingIndicatorController.reloadLocalizedStrings()
                    }

                    if previousSnapshot.mcpServerEnabled != snapshot.mcpServerEnabled
                        || previousSnapshot.mcpServerPort != snapshot.mcpServerPort {
                        self.applyMCPServerSettings()
                    }

                    if previousSnapshot.dictationAudioRetention != snapshot.dictationAudioRetention {
                        self.dictationAudioRetentionService.applyRetentionPolicyChange()
                    }

                    self.statusBarController.updateDynamicItems()
                    if self.isRecording {
                        if self.shouldRunLiveContextSession() {
                            self.startLiveContextSessionIfNeeded(initialSnapshot: self.capturedSnapshot)
                        } else {
                            self.stopLiveContextSession()
                        }
                    } else if previousSnapshot.aiEnhancementEnabled != snapshot.aiEnhancementEnabled
                        || previousSnapshot.enableUIContext != snapshot.enableUIContext
                        || previousSnapshot.vibeLiveSessionEnabled != snapshot.vibeLiveSessionEnabled {
                        self.updateVibeRuntimeStateFromSettings()
                    }
                }
            }
            .store(in: &cancellables)
    }
    
    private func updateFloatingIndicatorVisibility(previousType: FloatingIndicatorType? = nil) {
        guard settingsStore.floatingIndicatorEnabled, !isFloatingIndicatorTemporarilyHidden() else {
            hideAllFloatingIndicators()
            syncFloatingIndicatorFocusTracking()
            return
        }

        let selectedType = configuredFloatingIndicatorType()
        syncFloatingIndicatorFocusTracking()
        
        if isRecording || isProcessing {
            if previousType != selectedType {
                let oldType = activeFloatingIndicatorType ?? previousType ?? selectedType
                if oldType != selectedType {
                    floatingIndicatorPresenters[oldType]?.hide()
                    activeFloatingIndicatorType = selectedType
                    floatingIndicatorPresenters[selectedType]?.showForCurrentState()
                }
            }
            return
        }

        hideAllFloatingIndicators(except: selectedType)
        floatingIndicatorPresenters[selectedType]?.showIdleIndicator()
    }

    private func configuredFloatingIndicatorType() -> FloatingIndicatorType {
        settingsStore.selectedFloatingIndicatorType
    }

    private func recordingTriggerSourceForIndicatorStart(_ type: FloatingIndicatorType) -> RecordingTriggerSource {
        switch type {
        case .pill:
            .pillIndicatorStart
        case .orb:
            .orbIndicatorStart
        case .notch:
            .floatingIndicatorStart
        case .bubble:
            .bubbleIndicatorStart
        }
    }

    private func recordingTriggerSourceForIndicatorStop(_ type: FloatingIndicatorType) -> RecordingTriggerSource {
        switch type {
        case .pill:
            .pillIndicatorStop
        case .orb:
            .orbIndicatorStop
        case .notch:
            .floatingIndicatorStop
        case .bubble:
            .bubbleIndicatorStop
        }
    }

    private func hideAllFloatingIndicators(except selectedType: FloatingIndicatorType? = nil) {
        for (type, presenter) in floatingIndicatorPresenters where type != selectedType {
            presenter.hide()
        }
    }

    private func syncFloatingIndicatorFocusTracking() {
        let trackingMode = Self.floatingIndicatorFocusTrackingMode(
            floatingIndicatorEnabled: settingsStore.floatingIndicatorEnabled,
            isTemporarilyHidden: isFloatingIndicatorTemporarilyHidden(),
            selectedType: configuredFloatingIndicatorType(),
            isRecording: isRecording,
            isProcessing: isProcessing
        )

        if let trackingMode {
            floatingIndicatorFocusTracker.start(mode: trackingMode)
        } else {
            floatingIndicatorFocusTracker.stop()
        }
    }

    private func startRecordingIndicatorSession() {
        guard settingsStore.floatingIndicatorEnabled, !isFloatingIndicatorTemporarilyHidden() else { return }

        let selectedType = configuredFloatingIndicatorType()
        activeFloatingIndicatorType = selectedType
        syncFloatingIndicatorFocusTracking()
        hideAllFloatingIndicators(except: selectedType)
        floatingIndicatorPresenters[selectedType]?.startRecording()
    }

    private func transitionRecordingIndicatorToProcessing() {
        guard settingsStore.floatingIndicatorEnabled else {
            finishIndicatorSession()
            return
        }

        let activeType = activeFloatingIndicatorType ?? configuredFloatingIndicatorType()
        syncFloatingIndicatorFocusTracking()
        floatingIndicatorPresenters[activeType]?.transitionToProcessing()
    }

    private func startProcessingIndicatorSession() {
        guard settingsStore.floatingIndicatorEnabled else { return }
        startRecordingIndicatorSession()
        transitionRecordingIndicatorToProcessing()
    }

    private func finishIndicatorSession() {
        for presenter in floatingIndicatorPresenters.values {
            presenter.finishProcessing()
        }
        activeFloatingIndicatorType = nil


        updateFloatingIndicatorVisibility()
    }


    private func isFloatingIndicatorTemporarilyHidden() -> Bool {
        guard let hiddenUntil = floatingIndicatorHiddenUntil else { return false }
        if Date() >= hiddenUntil {
            floatingIndicatorHiddenUntil = nil
            return false
        }
        return true
    }

    private func clearFloatingIndicatorTemporaryHiddenState() {
        floatingIndicatorHiddenUntil = nil
        floatingIndicatorHiddenTask?.cancel()
        floatingIndicatorHiddenTask = nil
    }

    // MARK: - Live Session Context

    private func shouldRunLiveContextSession() -> Bool {
        settingsStore.assignment(for: .transcriptionEnhancement) != nil &&
            settingsStore.enableUIContext &&
            settingsStore.vibeLiveSessionEnabled
    }

    private func updateVibeRuntimeStateFromSettings() {
        guard settingsStore.assignment(for: .transcriptionEnhancement) != nil else {
            settingsStore.updateVibeRuntimeState(.degraded, detail: "AI enhancement is disabled.")
            return
        }

        guard settingsStore.enableUIContext else {
            settingsStore.updateVibeRuntimeState(.degraded, detail: "Vibe mode is disabled.")
            return
        }

        guard settingsStore.vibeLiveSessionEnabled else {
            settingsStore.updateVibeRuntimeState(.limited, detail: "Live session updates are disabled.")
            return
        }

        if let contextSessionState {
            let detail = contextEngineService.deriveRuntimeDetail(
                for: contextSessionState.latestSnapshot,
                runtimeState: contextSessionState.runtimeState
            )
            settingsStore.updateVibeRuntimeState(contextSessionState.runtimeState, detail: detail)
            return
        }

        if permissionManager.checkAccessibilityPermission() {
            settingsStore.updateVibeRuntimeState(.ready, detail: "Ready for live session context.")
        } else {
            settingsStore.updateVibeRuntimeState(.limited, detail: "Accessibility permission not granted. Using limited context.")
        }
    }

    private func deriveWorkspaceRoots(
        routingSignal: PromptRoutingSignal?,
        snapshot: ContextSnapshot?
    ) -> [String] {
        var roots: [String] = []

        if let workspacePath = routingSignal?.workspacePath,
           !workspacePath.isEmpty {
            roots.append(workspacePath)
        } else if let documentPath = snapshot?.appContext?.documentPath,
                  !documentPath.isEmpty {
            let parent = (documentPath as NSString).deletingLastPathComponent
            if !parent.isEmpty {
                roots.append(parent)
            }
        }

        return mergeUniqueContextSignals(roots)
    }

    private func mentionRewriteWorkspaceDebugSummary(
        adapterName: String,
        routingSignal: PromptRoutingSignal?,
        snapshot: ContextSnapshot?,
        derivedWorkspaceRoots: [String]
    ) -> String {
        let appContext = snapshot?.appContext
        return """
        adapter=\(adapterName) bundle=\(routingSignal?.appBundleIdentifier ?? "nil") app=\(appContext?.appName ?? "nil") signalWorkspacePresent=\(hasUsableContextValue(routingSignal?.workspacePath)) documentPathPresent=\(hasUsableContextValue(appContext?.documentPath)) windowTitlePresent=\(hasUsableContextValue(appContext?.windowTitle)) focusedValuePresent=\(hasUsableContextValue(appContext?.focusedElementValue)) terminalProvider=\(routingSignal?.terminalProviderIdentifier ?? "nil") isCodeEditorContext=\(routingSignal?.isCodeEditorContext ?? false) derivedWorkspaceRootCount=\(derivedWorkspaceRoots.count)
        """
    }

    private func hasUsableContextValue(_ value: String?) -> Bool {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines) else {
            return false
        }
        return !value.isEmpty
    }

    private func mergeUniqueContextSignals(_ groups: [String]..., limit: Int = 8) -> [String] {
        var seen = Set<String>()
        var merged: [String] = []

        for group in groups {
            for value in group {
                let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !normalized.isEmpty else { continue }
                if seen.insert(normalized).inserted {
                    merged.append(normalized)
                }
                if merged.count >= limit {
                    return merged
                }
            }
        }

        return merged
    }

    private func buildSessionTransitionSignature(
        snapshot: ContextSnapshot,
        activeFilePath: String?,
        workspacePath: String?
    ) -> String {
        let signature = snapshot.transitionSignature
        return [
            signature.bundleIdentifier,
            signature.windowTitle,
            signature.focusedElementRole,
            signature.documentPath,
            signature.selectedText,
            activeFilePath,
            workspacePath
        ]
        .map { $0?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "" }
        .joined(separator: "|")
    }

    private func shouldAppendTransition(
        signature: String,
        trigger: ContextSessionUpdateTrigger,
        in session: ContextSessionState
    ) -> Bool {
        guard trigger != .recordingStart else { return true }
        guard let lastSignature = session.transitions.last?.transitionSignature else { return true }
        return lastSignature != signature
    }

    private func currentLiveSessionContext() -> PindropAI.AIEnhancementService.LiveSessionContext? {
        guard let contextSessionState else { return nil }

        let enrichment = contextSessionState.latestAdapterEnrichment
        let latestTransition = contextSessionState.transitions.last

        let fileTagCandidates = mergeUniqueContextSignals(
            enrichment?.fileTagCandidates ?? [],
            contextSessionState.transitions.compactMap { $0.activeFilePath },
            contextSessionState.transitions.flatMap { $0.contextTags }
        )

        return PindropAI.AIEnhancementService.LiveSessionContext(
            runtimeState: contextSessionState.runtimeState,
            latestAppName: contextSessionState.latestSnapshot.appContext?.appName,
            latestWindowTitle: contextSessionState.latestSnapshot.appContext?.windowTitle,
            activeFilePath: latestTransition?.activeFilePath ?? enrichment?.activeFilePath ?? contextSessionState.latestSnapshot.appContext?.documentPath,
            activeFileConfidence: latestTransition?.activeFileConfidence ?? enrichment?.activeFileConfidence ?? 0,
            workspacePath: latestTransition?.workspacePath ?? contextSessionState.latestRoutingSignal.workspacePath ?? enrichment?.workspacePath,
            workspaceConfidence: latestTransition?.workspaceConfidence ?? enrichment?.workspaceConfidence ?? 0,
            fileTagCandidates: fileTagCandidates,
            styleSignals: enrichment?.styleSignals ?? [],
            codingSignals: enrichment?.codingSignals ?? [],
            transitions: contextSessionState.transitions
        ).bounded()
    }

    private func startLiveContextSessionIfNeeded(initialSnapshot: ContextSnapshot?) {
        guard isRecording else { return }
        guard shouldRunLiveContextSession() else {
            stopLiveContextSession()
            updateVibeRuntimeStateFromSettings()
            return
        }

        liveContextKeyRefreshGate.setEnabled(true)
        installContextSessionObserversIfNeeded()

        if contextSessionPollTimer == nil {
            let timer = Timer.scheduledTimer(withTimeInterval: contextSessionPollInterval, repeats: true) { [weak self] _ in
                guard let self else { return }
                MainActor.assumeIsolated {
                    guard self.isRecording, self.shouldRunLiveContextSession() else { return }
                    self.requestContextSessionRefresh(trigger: .poll)
                }
            }
            timer.tolerance = 0.2
            RunLoop.main.add(timer, forMode: .common)
            contextSessionPollTimer = timer
        }

        if contextSessionState == nil {
            requestContextSessionRefresh(trigger: .recordingStart, snapshotOverride: initialSnapshot)
        }
    }

    private func stopLiveContextSession() {
        liveContextKeyRefreshGate.setEnabled(false)
        contextSessionPollTimer?.invalidate()
        contextSessionPollTimer = nil
        removeContextSessionObserversIfNeeded()
        cancelPendingContextSessionRefresh()
        contextSessionState = nil
        lastFocusOrWindowUpdateAt = nil
    }

    private func suspendLiveContextSessionUpdates() {
        liveContextKeyRefreshGate.setEnabled(false)
        contextSessionPollTimer?.invalidate()
        contextSessionPollTimer = nil
        removeContextSessionObserversIfNeeded()
        cancelPendingContextSessionRefresh()
    }

    private func installContextSessionObserversIfNeeded() {
        guard contextSessionAppActivationObserver == nil else { return }

        contextSessionAppActivationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            MainActor.assumeIsolated {
                guard self.isRecording, self.shouldRunLiveContextSession() else { return }
                self.requestContextSessionRefresh(trigger: .frontmostAppChange)
            }
        }
    }

    private func removeContextSessionObserversIfNeeded() {
        if let contextSessionAppActivationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(contextSessionAppActivationObserver)
            self.contextSessionAppActivationObserver = nil
        }
    }

    private func scheduleFocusOrWindowContextRefreshIfNeeded() {
        guard isRecording, shouldRunLiveContextSession() else { return }

        let now = Date()
        if let lastFocusOrWindowUpdateAt,
           now.timeIntervalSince(lastFocusOrWindowUpdateAt) < contextSessionFocusUpdateThrottle {
            return
        }

        lastFocusOrWindowUpdateAt = now
        requestContextSessionRefresh(trigger: .focusOrWindowChange)
    }

    private func cancelPendingContextSessionRefresh() {
        contextSessionRefreshGeneration &+= 1
        contextSessionPendingRefresh = nil
        contextSessionRefreshTask?.cancel()
        contextSessionRefreshTask = nil
    }

    /// Coalesces concurrent live-context triggers into one owner task. While a
    /// refresh is suspended, later triggers replace the pending request so only
    /// the latest work runs after the active refresh finishes.
    private func requestContextSessionRefresh(
        trigger: ContextSessionUpdateTrigger,
        snapshotOverride: ContextSnapshot? = nil
    ) {
        guard isRecording, shouldRunLiveContextSession() else { return }

        if contextSessionRefreshTask != nil {
            contextSessionPendingRefresh = (trigger, snapshotOverride)
            return
        }

        contextSessionRefreshGeneration &+= 1
        let generation = contextSessionRefreshGeneration
        contextSessionPendingRefresh = nil
        contextSessionRefreshTask = Task { @MainActor [weak self] in
            await self?.runContextSessionRefreshOwner(
                initialTrigger: trigger,
                initialSnapshotOverride: snapshotOverride,
                generation: generation
            )
        }
    }

    private func runContextSessionRefreshOwner(
        initialTrigger: ContextSessionUpdateTrigger,
        initialSnapshotOverride: ContextSnapshot?,
        generation: UInt64
    ) async {
        defer {
            if contextSessionRefreshGeneration == generation {
                contextSessionRefreshTask = nil
            }
        }

        var nextTrigger = initialTrigger
        var nextSnapshotOverride = initialSnapshotOverride

        while !Task.isCancelled {
            guard contextSessionRefreshGeneration == generation else { return }
            guard isRecording, shouldRunLiveContextSession() else { return }

            await updateContextSession(
                trigger: nextTrigger,
                snapshotOverride: nextSnapshotOverride,
                generation: generation
            )

            guard contextSessionRefreshGeneration == generation else { return }
            guard !Task.isCancelled else { return }

            guard let pending = contextSessionPendingRefresh else { return }
            contextSessionPendingRefresh = nil
            nextTrigger = pending.trigger
            nextSnapshotOverride = pending.snapshotOverride
        }
    }

    private func updateContextSession(
        trigger: ContextSessionUpdateTrigger,
        snapshotOverride: ContextSnapshot? = nil,
        generation: UInt64
    ) async {
        guard isRecording else { return }
        guard settingsStore.enableUIContext else { return }
        guard contextSessionRefreshGeneration == generation else { return }

        let clipboardText = settingsStore.enableClipboardContext ? capturedContext?.clipboardText : nil
        let snapshot = snapshotOverride ?? contextEngineService.captureSnapshot(clipboardText: clipboardText)

        let routingSignal = PromptRoutingSignal.from(
            snapshot: snapshot,
            adapterRegistry: appContextAdapterRegistry
        )

        var adapterCapabilities: AppAdapterCapabilities?
        var adapterEnrichment: AppRuntimeEnrichment?

        if let bundleIdentifier = snapshot.appContext?.bundleIdentifier {
            let adapter = appContextAdapterRegistry.adapter(for: bundleIdentifier)
            adapterCapabilities = adapter.capabilities
            adapterEnrichment = appContextAdapterRegistry.enrichment(for: snapshot, routingSignal: routingSignal)
        }

        let workspaceRoots = deriveWorkspaceRoots(routingSignal: routingSignal, snapshot: snapshot)
        let workspaceInsights = await mentionRewriteService.deriveWorkspaceInsights(
            workspaceRoots: workspaceRoots,
            activeDocumentPath: snapshot.appContext?.documentPath
        )

        // Drop any intermediate work that finished after stop/reset or a newer
        // owner generation took over. Nothing above mutates session state.
        guard contextSessionRefreshGeneration == generation, !Task.isCancelled else { return }
        guard isRecording, settingsStore.enableUIContext else { return }

        capturedSnapshot = snapshot
        capturedRoutingSignal = routingSignal
        _ = promptRoutingResolver.resolve(signal: routingSignal)
        capturedAdapterCapabilities = adapterCapabilities

        let activeFilePath = workspaceInsights.activeDocumentRelativePath
            ?? adapterEnrichment?.activeFilePath
            ?? snapshot.appContext?.documentPath

        let activeFileConfidence = max(
            workspaceInsights.activeDocumentConfidence,
            adapterEnrichment?.activeFileConfidence ?? 0
        )

        let workspacePath = routingSignal.workspacePath
            ?? workspaceInsights.normalizedWorkspaceRoots.first
            ?? adapterEnrichment?.workspacePath

        let workspaceConfidence = max(
            workspaceInsights.workspaceConfidence,
            adapterEnrichment?.workspaceConfidence ?? 0
        )

        let contextTags = mergeUniqueContextSignals(
            workspaceInsights.fileTagCandidates,
            adapterEnrichment?.fileTagCandidates ?? [],
            adapterEnrichment?.styleSignals ?? [],
            adapterEnrichment?.codingSignals ?? []
        )

        let transitionSignature = buildSessionTransitionSignature(
            snapshot: snapshot,
            activeFilePath: activeFilePath,
            workspacePath: workspacePath
        )

        let runtimeState = contextEngineService.deriveRuntimeState(
            for: snapshot,
            adapterCapabilities: adapterCapabilities
        )

        let transition = ContextSessionTransition(
            timestamp: snapshot.timestamp,
            trigger: trigger,
            snapshot: snapshot,
            activeFilePath: activeFilePath,
            activeFileConfidence: activeFileConfidence,
            workspacePath: workspacePath,
            workspaceConfidence: workspaceConfidence,
            outputMode: settingsStore.outputMode,
            contextTags: contextTags,
            transitionSignature: transitionSignature
        )

        if var contextSessionState {
            contextSessionState.latestSnapshot = snapshot
            contextSessionState.latestRoutingSignal = routingSignal
            contextSessionState.latestAdapterCapabilities = adapterCapabilities
            contextSessionState.latestAdapterEnrichment = adapterEnrichment
            contextSessionState.runtimeState = runtimeState

            if shouldAppendTransition(
                signature: transitionSignature,
                trigger: trigger,
                in: contextSessionState
            ) {
                contextSessionState.appendTransition(transition)
            }

            self.contextSessionState = contextSessionState
        } else {
            self.contextSessionState = ContextSessionState(
                startedAt: recordingStartTime ?? Date(),
                latestSnapshot: snapshot,
                latestRoutingSignal: routingSignal,
                latestAdapterCapabilities: adapterCapabilities,
                latestAdapterEnrichment: adapterEnrichment,
                runtimeState: runtimeState,
                transitions: [transition]
            )
        }

        let runtimeDetail = contextEngineService.deriveRuntimeDetail(
            for: snapshot,
            runtimeState: runtimeState
        )
        settingsStore.updateVibeRuntimeState(runtimeState, detail: runtimeDetail)
    }

    
    // MARK: - Recording Flow

    /// Single mode-aware stop entry for user actions and controlled capture-limit
    /// finalization. Claiming occurs synchronously before the first suspension so
    /// simultaneous events cannot stop or transcribe the same recording twice.
    private func dispatchRecordingStop() async throws {
        guard isRecording else { return }
        let route = RecordingStopRoute.resolve(
            isQuickCapture: isQuickCaptureMode,
            noteAppendEditorID: isNoteAppendMode ? noteAppendEditorID : nil,
            isManualTranscription: isRecordingFeatureCaptureActive
        )
        guard let claim = recordingStopAdmission.claim(route) else {
            Log.app.debug("Ignoring duplicate recording stop request")
            return
        }

        let token = operationController.begin()
        let operationTask = Task { @MainActor [weak self] in
            guard let self else { throw CancellationError() }
            try await self.performRecordingStop(route: claim.route, token: token)
        }
        activeOperationTask = operationTask

        defer {
            if activeOperationTask == operationTask {
                activeOperationTask = nil
            }
            // Only frees the gate if this claim is still current. Cancel may have
            // already invalidated it so a newer stop can proceed.
            recordingStopAdmission.release(claim)
        }

        do {
            try await operationTask.value
        } catch {
            if Self.isTaskCancellation(error) {
                Log.app.info("Recording stop cancelled")
                return
            }
            // A superseded generation was already cancelled; do not surface its failure.
            guard operationController.isCurrent(token) else { return }
            throw error
        }
    }

    private func performRecordingStop(
        route: RecordingStopRoute,
        token: DictationOperationToken
    ) async throws {
        switch route {
        case .dictation:
            try await stopRecordingAndTranscribe(token: token)
        case .quickCapture:
            if let result = try await stopRecordingAndTranscribeForQuickCapture(token: token) {
                let note = try await persistQuickCapture(result, token: token)
                try ensureOperationCurrent(token)
                openNoteEditor(note)
            }
            isQuickCaptureMode = false
        case .noteAppend(let editorID):
            if let result = try await stopRecordingAndTranscribeForNoteAppend(token: token) {
                try await persistNoteAppend(result, editorID: editorID, token: token)
            }
            clearNoteAppendMode()
        case .manualTranscription:
            try await stopManualTranscriptionRecording(token: token)
        }
    }
    
    private func handlePushToTalkStart() async {
        guard !isRecording,
              !isProcessing,
              !recordingState.isCaptureStartPending else { return }
        guard NoteAppendGate.canStartGlobalDictation(
            isNoteAppendListening: isNoteAppendMode || pendingNoteAppendStart != nil
        ) else {
            Log.app.info("Refuse global dictation: note-append listening is active")
            return
        }

        do {
            try await startRecording(source: .hotkeyPushToTalk)
        } catch {
            guard !Self.isTaskCancellation(error) else { return }
            self.error = error
            audioRecorder.resetAudioEngine()
            Log.app.error("Failed to start recording: \(error)")
            handleRecordingStartFailure(error, source: .hotkeyPushToTalk)
        }
    }
    
    private func handlePushToTalkEnd() async {
        // Note-append is not started by global PTT, so a PTT keyup must not
        // cancel an in-editor speak-to-append session.
        if isNoteAppendMode {
            Log.app.debug("Ignore global PTT end during note-append listening")
            return
        }
        guard isRecording else { return }

        do {
            try await dispatchRecordingStop()
        } catch {
            self.error = error
            audioRecorder.resetAudioEngine()
            Log.app.error("Failed to stop recording: \(error)")
        }
    }

    // MARK: - Quick Capture Handlers (Push-to-Talk)

    private func handleQuickCapturePTTStart() async {
        guard !isRecording,
              !isProcessing,
              !recordingState.isCaptureStartPending else { return }
        guard NoteAppendGate.canStartGlobalDictation(
            isNoteAppendListening: isNoteAppendMode || pendingNoteAppendStart != nil
        ) else {
            Log.app.info("Refuse quick-capture: note-append listening is active")
            return
        }

        isQuickCaptureMode = true
        quickCaptureTranscription = nil

        var context: VoiceNoteCaptureContext?
        do {
            try beginVoiceNoteCapture(noteID: nil)
            guard let activeContext = voiceNoteCaptureContext else {
                throw VoiceNoteCaptureAdmissionError.captureAlreadyActive
            }
            context = activeContext
            try await startRecording(
                source: .hotkeyQuickCapturePTT,
                voiceNoteContext: activeContext
            )
            guard isVoiceNoteCaptureContextCurrent(activeContext) else {
                throw CancellationError()
            }
        } catch {
            if Self.isTaskCancellation(error) {
                isQuickCaptureMode = false
                if let context, isVoiceNoteCaptureContextCurrent(context) {
                    cancelActiveVoiceNoteCapture()
                }
                return
            }
            guard let context, isVoiceNoteCaptureContextCurrent(context) else {
                guard voiceNoteCaptureContext == nil else { return }
                isQuickCaptureMode = false
                return
            }
            self.error = error
            failVoiceNoteCapture(context, stage: "recording-start", error: error)
            isQuickCaptureMode = false
            audioRecorder.resetAudioEngine()
            Log.app.error("Failed to start quick capture recording: \(error)")
            handleRecordingStartFailure(error, source: .hotkeyQuickCapturePTT)
        }
    }

    private func handleQuickCapturePTTEnd() async {
        guard isRecording && isQuickCaptureMode else { return }

        do {
            try await dispatchRecordingStop()
        } catch {
            self.error = error
            audioRecorder.resetAudioEngine()
            Log.app.error("Failed to stop quick capture recording: \(error)")
        }

        isQuickCaptureMode = false
    }

    // MARK: - Quick Capture Handlers (Toggle)

    private func handleQuickCaptureToggle(
        captureStartClaim: CaptureStartClaim? = nil
    ) async {
        if isRecording && isQuickCaptureMode {
            do {
                try await dispatchRecordingStop()
            } catch {
                self.error = error
                audioRecorder.resetAudioEngine()
                Log.app.error("Failed to stop quick capture recording: \(error)")
            }
            isQuickCaptureMode = false
        } else if !isRecording,
                  !isProcessing,
                  captureStartClaim != nil || !recordingState.isCaptureStartPending {
            guard NoteAppendGate.canStartGlobalDictation(
                isNoteAppendListening: isNoteAppendMode || pendingNoteAppendStart != nil
            ) else {
                Log.app.info("Refuse quick-capture toggle: note-append listening is active")
                return
            }
            isQuickCaptureMode = true
            quickCaptureTranscription = nil

            var context: VoiceNoteCaptureContext?
            do {
                try beginVoiceNoteCapture(noteID: nil)
                guard let activeContext = voiceNoteCaptureContext else {
                    throw VoiceNoteCaptureAdmissionError.captureAlreadyActive
                }
                context = activeContext
                try await startRecording(
                    source: .hotkeyQuickCaptureToggle,
                    voiceNoteContext: activeContext,
                    captureStartClaim: captureStartClaim
                )
                guard isVoiceNoteCaptureContextCurrent(activeContext) else {
                    throw CancellationError()
                }
            } catch {
                if Self.isTaskCancellation(error) {
                    isQuickCaptureMode = false
                    if let context, isVoiceNoteCaptureContextCurrent(context) {
                        cancelActiveVoiceNoteCapture()
                    }
                    return
                }
                guard let context, isVoiceNoteCaptureContextCurrent(context) else {
                    guard voiceNoteCaptureContext == nil else { return }
                    isQuickCaptureMode = false
                    return
                }
                self.error = error
                failVoiceNoteCapture(context, stage: "recording-start", error: error)
                isQuickCaptureMode = false
                audioRecorder.resetAudioEngine()
                Log.app.error("Failed to start quick capture recording: \(error)")
                handleRecordingStartFailure(error, source: .hotkeyQuickCaptureToggle)
            }
        }
    }

    // MARK: - Speak-to-Append (open note editor)

    private func handleNoteAppendRequestNotification(_ notification: Notification) {
        guard !isShutdown,
              let editorID = notification.userInfo?["editorID"] as? UUID,
              let noteID = notification.userInfo?["noteID"] as? UUID,
              let action = notification.userInfo?["action"] as? String else {
            return
        }

        switch action {
        case "start":
            installPendingNoteAppendStart(editorID: editorID, noteID: noteID)
        case "stop":
            // This happens before creating the stop task. A closed editor can
            // therefore cancel an installed Start before its async body runs.
            cancelPendingNoteAppendStart(editorID: editorID, noteID: noteID)
            Task { @MainActor [weak self] in
                await self?.handleNoteAppendStop(editorID: editorID, noteID: noteID)
            }
        default:
            return
        }
    }

    private func installPendingNoteAppendStart(editorID: UUID, noteID: UUID) {
        guard Self.canBeginVoiceNoteCapture(activeHandle: voiceNoteCaptureContext?.handle),
              pendingNoteAppendStart == nil else {
            Log.app.info("Refuse note-append listening: a voice-note capture start is already active")
            postNoteAppendStartRejected(editorID: editorID, noteID: noteID)
            return
        }

        nextNoteAppendStartGeneration &+= 1
        let request = PendingNoteAppendStart(
            generation: nextNoteAppendStartGeneration,
            editorID: editorID,
            noteID: noteID
        )
        pendingNoteAppendStart = request
        pendingNoteAppendStartTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.handleNoteAppendStart(request)
        }
    }

    private func postNoteAppendStartRejected(editorID: UUID, noteID: UUID) {
        NotificationCenter.default.post(
            name: .noteSpeakToAppendRejected,
            object: nil,
            userInfo: [
                "editorID": editorID,
                "noteID": noteID
            ]
        )
    }

    private func cancelPendingNoteAppendStart(editorID: UUID, noteID: UUID) {
        guard let request = pendingNoteAppendStart,
              request.editorID == editorID,
              request.noteID == noteID else {
            return
        }

        let capture = pendingNoteAppendStartCapture
        pendingNoteAppendStartTask?.cancel()
        pendingNoteAppendStartTask = nil
        pendingNoteAppendStart = nil
        clearPendingNoteAppendStartCapture(ifCurrent: capture, request: request)
        nextNoteAppendStartGeneration &+= 1

        if let capture {
            cancelPendingNoteAppendCapture(
                capture.context,
                request: request,
                preservingAudioStartupOwnership: true
            )
        }
    }

    private func isPendingNoteAppendStartCurrent(_ request: PendingNoteAppendStart) -> Bool {
        pendingNoteAppendStart == request && !Task.isCancelled
    }

    private func cancelPendingNoteAppendStart() {
        guard let request = pendingNoteAppendStart else { return }
        let capture = pendingNoteAppendStartCapture
        pendingNoteAppendStartTask?.cancel()
        pendingNoteAppendStartTask = nil
        if let capture, capture.request == request {
            cancelPendingNoteAppendCapture(capture.context, request: request)
        }
        pendingNoteAppendStart = nil
        clearPendingNoteAppendStartCapture(ifCurrent: capture, request: request)
        if pendingNoteAppendAudioStartupRequest == request {
            pendingNoteAppendAudioStartupRequest = nil
        }
        nextNoteAppendStartGeneration &+= 1
    }

    private func clearPendingNoteAppendStart(ifCurrent request: PendingNoteAppendStart) {
        guard pendingNoteAppendStart == request else { return }
        pendingNoteAppendStartTask = nil
        pendingNoteAppendStart = nil
        clearPendingNoteAppendStartCapture(
            ifCurrent: pendingNoteAppendStartCapture,
            request: request
        )
        if pendingNoteAppendAudioStartupRequest == request {
            pendingNoteAppendAudioStartupRequest = nil
        }
    }

    private func trackPendingNoteAppendStartCapture(
        _ context: VoiceNoteCaptureContext,
        for request: PendingNoteAppendStart
    ) throws {
        try ensurePendingNoteAppendStartCurrent(request, context: context)
        pendingNoteAppendStartCapture = PendingNoteAppendCapture(
            request: request,
            context: context
        )
        pendingNoteAppendAudioStartupRequest = request
    }

    private func clearPendingNoteAppendStartCapture(
        ifCurrent capture: PendingNoteAppendCapture?,
        request: PendingNoteAppendStart
    ) {
        guard let capture,
              capture.request == request,
              Self.isPendingNoteAppendCaptureCurrent(
                pendingEditorID: pendingNoteAppendStartCapture?.request.editorID,
                pendingNoteID: pendingNoteAppendStartCapture?.request.noteID,
                pendingHandle: pendingNoteAppendStartCapture?.context.handle,
                candidateEditorID: request.editorID,
                candidateNoteID: request.noteID,
                candidateHandle: capture.context.handle
              ) else {
            return
        }
        pendingNoteAppendStartCapture = nil
    }

    @discardableResult
    private func resetPendingNoteAppendAudioStartup(
        ifOwnedBy request: PendingNoteAppendStart,
        preservingOwnership: Bool = false
    ) -> Bool {
        let capture = pendingNoteAppendStartCapture
        guard pendingNoteAppendAudioStartupRequest == request else { return false }
        audioRecorder.cancelRecording()
        audioRecorder.resetAudioEngine()
        if let capture, capture.request == request {
            streamingSession.cancelArtifactCaptureDetached(for: capture.context.handle)
        }
        if !preservingOwnership {
            pendingNoteAppendAudioStartupRequest = nil
        }
        return true
    }

    private func cancelPendingNoteAppendCapture(
        _ context: VoiceNoteCaptureContext,
        request: PendingNoteAppendStart,
        preservingAudioStartupOwnership: Bool = false
    ) {
        do {
            try captureSessionStore.cancel(context.handle, at: .now)
        } catch {
            Log.app.error("Failed to cancel pending voice-note capture: \(error)")
        }

        let ownsActiveCapture = isVoiceNoteCaptureContextCurrent(context)
        _ = resetPendingNoteAppendAudioStartup(
            ifOwnedBy: request,
            preservingOwnership: preservingAudioStartupOwnership
        )
        guard ownsActiveCapture else { return }

        clearNoteAppendMode(
            ifCurrent: context,
            editorID: request.editorID,
            noteID: request.noteID
        )
        clearVoiceNoteCaptureContext(ifCurrent: context)
        mediaPauseService.endRecordingSession()
        recordingState.endRecording(
            message: localized("Recording canceled.", locale: settingsStore.selectedAppLocale.locale)
        )
        recordingState.clearCurrentJob()
        isRecording = false
        isProcessing = false
        recordingStartTime = nil
        statusBarController.setIdleState()
        statusBarController.updateMenuState()
    }

    private func ensurePendingNoteAppendStartCurrent(
        _ request: PendingNoteAppendStart,
        context: VoiceNoteCaptureContext? = nil
    ) throws {
        guard isPendingNoteAppendStartCurrent(request) else {
            throw CancellationError()
        }
        if let context {
            guard isVoiceNoteCaptureContextCurrent(context) else {
                throw CancellationError()
            }
        }
    }
    private func handleNoteAppendStart(_ request: PendingNoteAppendStart) async {
        guard isPendingNoteAppendStartCurrent(request) else { return }
        guard !recordingState.isCaptureStartPending,
              NoteAppendGate.canStartNoteAppend(
                  isRecording: isRecording,
                  isProcessing: isProcessing
              ) else {
            clearPendingNoteAppendStart(ifCurrent: request)
            postNoteAppendStartRejected(editorID: request.editorID, noteID: request.noteID)
            return
        }

        var context: VoiceNoteCaptureContext?
        do {
            let noteExists = try notesStore.contains(id: request.noteID)
            try ensurePendingNoteAppendStartCurrent(request)
            guard noteExists else {
                Log.app.info("Refuse note-append listening: note is no longer durable")
                clearPendingNoteAppendStart(ifCurrent: request)
                postNoteAppendStartRejected(editorID: request.editorID, noteID: request.noteID)
                return
            }

            isNoteAppendMode = true
            noteAppendEditorID = request.editorID
            NoteAppendListeningCoordinator.shared.state.startListening(
                editorID: request.editorID,
                noteID: request.noteID
            )

            try beginVoiceNoteCapture(noteID: request.noteID)
            guard let activeContext = voiceNoteCaptureContext else {
                throw VoiceNoteCaptureAdmissionError.captureAlreadyActive
            }
            context = activeContext
            try trackPendingNoteAppendStartCapture(activeContext, for: request)
            try await startRecording(
                source: .noteAppend,
                voiceNoteContext: activeContext,
                pendingNoteAppendStart: request
            )
            try ensurePendingNoteAppendStartCurrent(request, context: activeContext)
            guard isRecording else {
                throw VoiceNoteCaptureAdmissionError.recorderDidNotStart
            }
            clearPendingNoteAppendStart(ifCurrent: request)
        } catch {
            if Self.isTaskCancellation(error) {
                if let context {
                    cancelPendingNoteAppendCapture(context, request: request)
                }
                clearPendingNoteAppendStart(ifCurrent: request)
                return
            }
            guard isPendingNoteAppendStartCurrent(request) else {
                if let context {
                    cancelPendingNoteAppendCapture(context, request: request)
                }
                return
            }

            self.error = error
            _ = resetPendingNoteAppendAudioStartup(ifOwnedBy: request)
            if let context, isVoiceNoteCaptureContextCurrent(context) {
                clearNoteAppendMode(
                    ifCurrent: context,
                    editorID: request.editorID,
                    noteID: request.noteID
                )
                failVoiceNoteCapture(context, stage: "recording-start", error: error)
            } else if noteAppendEditorID == request.editorID {
                clearNoteAppendMode()
            }
            clearPendingNoteAppendStart(ifCurrent: request)
            Log.app.error("Failed to start note-append recording: \(error)")
            handleRecordingStartFailure(error, source: .noteAppend)
            postNoteAppendStartRejected(editorID: request.editorID, noteID: request.noteID)
        }
    }

    private func handleNoteAppendStop(editorID: UUID, noteID: UUID) async {
        guard isNoteAppendRequestCurrent(editorID: editorID, noteID: noteID) else {
            Log.app.info("Ignore note-append stop for non-active editor or note")
            return
        }

        do {
            try await dispatchRecordingStop()
        } catch {
            self.error = error
            audioRecorder.resetAudioEngine()
            Log.app.error("Failed to stop note-append recording: \(error)")
        }

        if !isRecording { clearNoteAppendMode() }
    }

    private func isNoteAppendRequestCurrent(editorID: UUID, noteID: UUID) -> Bool {
        noteAppendEditorID == editorID && voiceNoteCaptureContext?.noteID == noteID
    }

    private func clearNoteAppendMode(
        ifCurrent context: VoiceNoteCaptureContext,
        editorID: UUID,
        noteID: UUID
    ) {
        guard isVoiceNoteCaptureContextCurrent(context),
              isNoteAppendRequestCurrent(editorID: editorID, noteID: noteID) else {
            return
        }
        clearNoteAppendMode()
    }

    private func clearNoteAppendMode() {

        isNoteAppendMode = false
        noteAppendEditorID = nil
        NoteAppendListeningCoordinator.shared.state.finishSession()
    }

    static let meetingStartAssignmentStages: [CapturePipelineStage] = [
        .liveTranscription,
        .finalTranscription,
        .diarization,
        .noteGeneration
    ]

    static func captureAssignmentAttempt(for stage: CapturePipelineStage) -> Int {
        // Capture retries are represented by new attempts. Initial execution, recovery,
        // and every meeting chunk share the durable first attempt.
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
        return !normalizedTranscriptionText(resolvedPrompt).isEmpty
    }

    static func shouldGenerateMeetingNote(existingGeneratedNote: Bool) -> Bool {
        !existingGeneratedNote
    }

    static func generatedMeetingNoteTitle(_ title: String, fallback: String) -> String {
        let sanitizedTitle = MeetingNoteDerivation.sanitizingGeneratedContent(
            normalizedTranscriptionText(title)
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

    static func canBeginVoiceNoteCapture(
        activeHandle: PindropData.VoiceNoteCaptureHandle?
    ) -> Bool {
        activeHandle == nil
    }

    static func isVoiceNoteCaptureCurrent(
        activeHandle: PindropData.VoiceNoteCaptureHandle?,
        candidateHandle: PindropData.VoiceNoteCaptureHandle
    ) -> Bool {
        activeHandle == candidateHandle
    }

    static func canBeginMeetingCapture(
        activeHandle: PindropData.MeetingCaptureHandle?,
        recoveryTaskActive: Bool = false,
        isShutdown: Bool = false
    ) -> Bool {
        activeHandle == nil && !recoveryTaskActive && !isShutdown
    }

    static func canCancelCurrentOperation(
        isRecording: Bool,
        isProcessing: Bool,
        hasActiveOperationTask: Bool,
        hasMeetingCaptureContext: Bool,
        hasPendingMeetingCaptureStart: Bool
    ) -> Bool {
        isRecording
            || isProcessing
            || hasActiveOperationTask
            || hasMeetingCaptureContext
            || hasPendingMeetingCaptureStart
    }

    static func isMeetingCaptureCurrent(
        activeHandle: PindropData.MeetingCaptureHandle?,
        candidateHandle: PindropData.MeetingCaptureHandle
    ) -> Bool {
        activeHandle == candidateHandle
    }

    static func canBeginMeetingRecovery(
        activeHandle: PindropData.MeetingCaptureHandle?,
        recoveryTaskActive: Bool,
        isShutdown: Bool
    ) -> Bool {
        activeHandle == nil && !recoveryTaskActive && !isShutdown
    }

    static func isMeetingRecoveryCurrent(
        activeGeneration: UInt64,
        candidateGeneration: UInt64,
        activeHandle: PindropData.MeetingCaptureHandle?,
        candidateHandle: PindropData.MeetingCaptureHandle
    ) -> Bool {
        activeGeneration == candidateGeneration && activeHandle == candidateHandle
    }

    static func shouldApplyMeetingRecoveryMutation(
        isCancelled: Bool,
        isShutdown: Bool,
        isPreparingForTermination: Bool,
        activeGeneration: UInt64,
        candidateGeneration: UInt64,
        activeHandle: PindropData.MeetingCaptureHandle?,
        candidateHandle: PindropData.MeetingCaptureHandle
    ) -> Bool {
        !isCancelled
            && !isShutdown
            && !isPreparingForTermination
            && isMeetingRecoveryCurrent(
                activeGeneration: activeGeneration,
                candidateGeneration: candidateGeneration,
                activeHandle: activeHandle,
                candidateHandle: candidateHandle
            )
    }

    static func shouldContinueMeetingRecovery(after error: Error) -> Bool {
        !isTaskCancellation(error)
    }

    private func isMeetingRecoveryCurrent(
        generation: UInt64,
        handle: PindropData.MeetingCaptureHandle
    ) -> Bool {
        Self.shouldApplyMeetingRecoveryMutation(
            isCancelled: Task.isCancelled,
            isShutdown: isShutdown,
            isPreparingForTermination: isPreparingForTermination,
            activeGeneration: meetingRecoveryGeneration,
            candidateGeneration: generation,
            activeHandle: meetingRecoveryHandle,
            candidateHandle: handle
        )
    }

    private func ensureMeetingRecoveryCurrent(
        generation: UInt64,
        handle: PindropData.MeetingCaptureHandle
    ) throws {
        try Task.checkCancellation()
        guard isMeetingRecoveryCurrent(generation: generation, handle: handle) else {
            throw CancellationError()
        }
    }

    static func meetingChunkWorkItems(
        sourceChunks: [PindropData.MeetingChunkCheckpoint],
        failedSequences: Set<Int>,
        handle: PindropData.MeetingCaptureHandle
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
        let systemAudioChunks = try indexedChunks(sourceID: handle.systemAudioSourceID)
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

    static func isPendingNoteAppendCaptureCurrent(
        pendingEditorID: UUID?,
        pendingNoteID: UUID?,
        pendingHandle: PindropData.VoiceNoteCaptureHandle?,
        candidateEditorID: UUID,
        candidateNoteID: UUID,
        candidateHandle: PindropData.VoiceNoteCaptureHandle
    ) -> Bool {
        pendingEditorID == candidateEditorID
            && pendingNoteID == candidateNoteID
            && pendingHandle == candidateHandle
    }

    static func noteAppendNotificationSourceTranscriptionID(
        _ append: PindropData.NoteAppendResult
    ) -> UUID {
        append.sourceTranscriptionID
    }

    private func isVoiceNoteCaptureContextCurrent(_ context: VoiceNoteCaptureContext) -> Bool {
        Self.isVoiceNoteCaptureCurrent(
            activeHandle: voiceNoteCaptureContext?.handle,
            candidateHandle: context.handle
        )
    }

    static func revalidateVoiceCaptureAfterArtifactAdmission(
        ensureCurrent: @MainActor () throws -> Void,
        tearDownStreaming: @MainActor () async -> Void
    ) async throws {
        do {
            try ensureCurrent()
        } catch {
            await tearDownStreaming()
            throw error
        }
    }

    private func ensureVoiceNoteCaptureCurrentAfterArtifactAdmission(
        _ context: VoiceNoteCaptureContext,
        pendingNoteAppendStart: PendingNoteAppendStart?
    ) async throws {
        try await Self.revalidateVoiceCaptureAfterArtifactAdmission(
            ensureCurrent: { [self] in
                if let pendingNoteAppendStart {
                    try ensurePendingNoteAppendStartCurrent(
                        pendingNoteAppendStart,
                        context: context
                    )
                } else {
                    guard isVoiceNoteCaptureContextCurrent(context) else {
                        throw CancellationError()
                    }
                }
            },
            tearDownStreaming: { [streamingSession] in
                await streamingSession.cancelArtifactCapture(for: context.handle)
            }
        )
    }

    private func ensureVoiceNoteCaptureCurrent(
        _ context: VoiceNoteCaptureContext,
        token: DictationOperationToken
    ) throws {
        try ensureOperationCurrent(token)
        guard isVoiceNoteCaptureContextCurrent(context) else {
            throw CancellationError()
        }
    }

    static func finishArtifactCaptureThenBeginFinalization(
        finishArtifactCapture: @MainActor () async -> Void,
        ensureCurrent: @MainActor () throws -> Void,
        beginFinalization: @MainActor () throws -> Void
    ) async throws {
        try ensureCurrent()
        await finishArtifactCapture()
        try ensureCurrent()
        try beginFinalization()
    }

    private func clearVoiceNoteCaptureContext(ifCurrent context: VoiceNoteCaptureContext) {
        guard isVoiceNoteCaptureContextCurrent(context) else { return }
        voiceNoteCaptureContext = nil
    }

    private func isPendingMeetingCaptureStartCurrent(_ claim: MeetingCaptureStartClaim) -> Bool {
        pendingMeetingCaptureStart == claim
            && meetingCaptureStartAdmission.isCurrent(claim)
            && !isShutdown
            && !isPreparingForTermination
            && !Task.isCancelled
    }

    private func ensurePendingMeetingCaptureStartCurrent(
        _ claim: MeetingCaptureStartClaim
    ) throws {
        try Task.checkCancellation()
        guard isPendingMeetingCaptureStartCurrent(claim) else {
            throw CancellationError()
        }
    }

    private func clearPendingMeetingCaptureStart(
        ifCurrent claim: MeetingCaptureStartClaim
    ) {
        guard pendingMeetingCaptureStart == claim else { return }
        pendingMeetingCaptureStartTask = nil
        pendingMeetingCaptureStart = nil
        pendingMeetingCaptureStartHandle = nil
        meetingCaptureStartAdmission.release(claim)
    }

    private func cancelPendingMeetingCaptureStart() {
        guard let claim = pendingMeetingCaptureStart else { return }
        pendingMeetingCaptureStartTask?.cancel()
        pendingMeetingCaptureStartTask = nil
        pendingMeetingCaptureStart = nil
        meetingCaptureStartAdmission.release(claim)
    }

    private func cancelPendingMeetingCaptureStartHandle() async throws {
        guard let handle = pendingMeetingCaptureCancellationHandle
            ?? pendingMeetingCaptureStartHandle else {
            return
        }
        try await cancelMeetingCaptureStartHandle(handle)
    }

    private func cancelMeetingCaptureStartHandle(
        _ handle: PindropData.MeetingCaptureHandle
    ) async throws {
        guard !Self.isMeetingCaptureCurrent(
            activeHandle: meetingCaptureContext?.handle,
            candidateHandle: handle
        ) else { return }
        try await cancelMeetingCapture(handle, activeContext: nil)
    }

    private func isMeetingCaptureContextCurrent(_ context: MeetingCaptureContext) -> Bool {
        meetingCaptureGeneration == context.generation
            && Self.isMeetingCaptureCurrent(
                activeHandle: meetingCaptureContext?.handle,
                candidateHandle: context.handle
            )
    }

    private func ensureMeetingCaptureCurrent(_ context: MeetingCaptureContext) throws {
        try Task.checkCancellation()
        guard !isShutdown, isMeetingCaptureContextCurrent(context) else {
            throw CancellationError()
        }
    }

    private func ensureMeetingCaptureCurrent(
        _ context: MeetingCaptureContext,
        token: DictationOperationToken
    ) throws {
        try ensureOperationCurrent(token)
        try ensureMeetingCaptureCurrent(context)
    }

    private func clearMeetingCaptureContext(ifCurrent context: MeetingCaptureContext) {
        guard isMeetingCaptureContextCurrent(context) else { return }
        meetingCaptureContext = nil
    }

    private func cancelActiveMeetingCapture() async throws {
        guard let context = meetingCaptureContext else { return }
        try await cancelMeetingCapture(context.handle, activeContext: context)
    }

    /// Terminal cancellation is exact-handle scoped: a delayed duplicate must not
    /// clear or delete a successor.
    /// Active-capture callers must tear down the recorder first.
    private func cancelMeetingCapture(
        _ handle: PindropData.MeetingCaptureHandle,
        activeContext: MeetingCaptureContext?
    ) async throws {
        do {
            try captureSessionStore.cancelMeetingCapture(handle, at: .now)
        } catch {
            if pendingMeetingCaptureCancellationHandle == nil
                || pendingMeetingCaptureCancellationHandle == handle {
                pendingMeetingCaptureCancellationHandle = handle
            }
            throw MeetingCaptureTerminalPersistenceError.cancellation(error)
        }

        if let activeContext {
            clearMeetingCaptureContext(ifCurrent: activeContext)
        }
        if pendingMeetingCaptureStartHandle == handle {
            pendingMeetingCaptureStartHandle = nil
        }

        do {
            try await mediaIngestionService.removeMeetingCaptureArtifacts(for: handle.sessionID)
        } catch {
            if pendingMeetingCaptureCancellationHandle == nil
                || pendingMeetingCaptureCancellationHandle == handle {
                pendingMeetingCaptureCancellationHandle = handle
            }
            throw MeetingCaptureTerminalPersistenceError.cancellation(error)
        }

        if pendingMeetingCaptureCancellationHandle == handle {
            pendingMeetingCaptureCancellationHandle = nil
        }
    }

    private func reportMeetingCaptureTerminalPersistenceFailure(_ error: Error) {
        self.error = error
        Log.app.error("Meeting capture terminal cancellation cleanup deferred: \(error)")
    }

    private func resetStoppedMeetingCaptureState() {
        isRecording = false
        isRecordingFeatureCaptureActive = false
        manualExpectedSpeakerCount = nil
        resetProcessingState()
    }

    private func recordSealedMeetingChunk(
        _ chunk: SealedAudioSourceChunk,
        for context: MeetingCaptureContext
    ) {
        guard isMeetingCaptureContextCurrent(context), !isShutdown else { return }
        do {
            try captureSessionStore.recordSealedMeetingChunk(context.handle, chunk: chunk, at: .now)
        } catch {
            // The writer has already durably sealed the artifact. Stop/recovery inventory
            // reconciles this advisory callback if its database checkpoint was interrupted.
            Log.app.warning("Deferred meeting chunk checkpoint \(chunk.sequence): \(error.localizedDescription)")
        }
    }

    private func meetingSourceFailure(
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

    private func reconcileMeetingArtifacts(
        handle: PindropData.MeetingCaptureHandle,
        spoolPlan: MeetingCaptureSpoolPlan,
        operationGuard: () throws -> Void
    ) async throws -> MeetingArtifactRecoveryResult {
        let recovery = try await mediaIngestionService.recoverMeetingArtifacts(for: spoolPlan)
        try operationGuard()
        let failures = recovery.failures.map(meetingChunkFailure(from:))
        try operationGuard()
        try captureSessionStore.reconcileMeetingInventory(
            handle,
            sealedChunks: recovery.sealedChunks,
            failures: failures,
            at: .now
        )
        return recovery
    }

    private func meetingChunkFailure(
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

    private func finishMeetingSources(
        handle: PindropData.MeetingCaptureHandle,
        artifacts: [SealedAudioSourceChunk],
        recoveryFailures: [MeetingArtifactRecoveryFailure] = [],
        stopResult: MeetingRecordingStopResult?
    ) throws {
        let microphoneHasChunks = artifacts.contains { $0.sourceID == handle.microphoneSourceID }
        let systemAudioHasChunks = artifacts.contains { $0.sourceID == handle.systemAudioSourceID }
        func sourceUnavailable(for sourceID: UUID) -> MeetingArtifactRecoveryFailure? {
            recoveryFailures.first {
                $0.sourceID == sourceID && $0.kind == .sourceUnavailable
            }
        }
        var failures: [PindropData.FailedMeetingSource] = []
        if !microphoneHasChunks {
            failures.append(meetingSourceFailure(
                sourceID: handle.microphoneSourceID,
                recoveryFailure: sourceUnavailable(for: handle.microphoneSourceID),
                failure: stopResult?.microphoneFailure
            ))
        }
        if !systemAudioHasChunks {
            failures.append(meetingSourceFailure(
                sourceID: handle.systemAudioSourceID,
                recoveryFailure: sourceUnavailable(for: handle.systemAudioSourceID),
                failure: stopResult?.systemAudioFailure
            ))
        }
        try captureSessionStore.finishMeetingSources(handle, sourceFailures: failures, at: .now)
    }
    private func resolvedMeetingArtifacts(
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

    private func finalizeMeetingCapture(
        _ handle: PindropData.MeetingCaptureHandle,
        spoolPlan: MeetingCaptureSpoolPlan,
        operationGuard: () throws -> Void
    ) async throws {
        try operationGuard()
        let meetingStartAssignments = try captureMeetingStartAssignments(sessionID: handle.sessionID)
        guard let finalAssignment = meetingStartAssignments.first(where: {
            $0.stage == .finalTranscription
        }) else {
            throw CaptureStageAssignmentError.missingModelIdentifier(providerKind: .disabled)
        }
        guard let diarizationAssignment = meetingStartAssignments.first(where: {
            $0.stage == .diarization
        }) else {
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
            throw CaptureStageAssignmentError.missingModelIdentifier(
                providerKind: finalAssignment.providerKind
            )
        }
        if needsFinalModelActivation {
            try await activateAssignedFinalModel(finalAssignment)
            try operationGuard()
        }

        let diarizationDecision = Self.captureAssignmentExecutionDecision(
            for: diarizationAssignment
        )
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
        let artifacts = try await resolvedMeetingArtifacts(
            recovery.sealedChunks,
            operationGuard: operationGuard
        )
        try operationGuard()
        let artifactsBySourceAndSequence = Dictionary(
            uniqueKeysWithValues: artifacts.map {
                (MeetingSourceSequence(sourceID: $0.sourceID, sequence: $0.sequence), $0)
            }
        )
        var outputs: [TranscriptionChunkOutput] = plan.completedASRCheckpoints.compactMap { checkpoint -> TranscriptionChunkOutput? in
            guard let workItem = workItems.first(where: { $0.sequence == checkpoint.sequence }) else {
                return nil
            }
            return transcriptionOutput(checkpoint: checkpoint, workItem: workItem)
        }
        var warningCount = 0

        for workItem in workItems where !plan.completedASRSequences.contains(workItem.sequence) {
            try operationGuard()
            guard Self.shouldCreateMeetingTranscriptionInput(for: workItem) else {
                // `failedSequences` retains the persisted scoped failure as an empty timed window.
                warningCount += 1
                outputs.append(Self.meetingOutputPlaceholder(for: workItem))
                recordingState.updateJob(
                    stage: .transcribing,
                    progress: Self.meetingChunkProgress(completed: outputs.count, total: workItems.count),
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
                    message: "No deterministic source artifact was found for this meeting chunk.",
                    retryable: true,
                    at: .now
                )
                warningCount += 1
                outputs.append(Self.meetingOutputPlaceholder(for: workItem))
                recordingState.updateJob(
                    stage: .transcribing,
                    progress: Self.meetingChunkProgress(completed: outputs.count, total: workItems.count),
                    detail: "Chunk \(workItem.sequence + 1) failed; preserving its timed gap.",
                    errorMessage: nil
                )
                continue
            }

            try await transcribeMeetingWorkItem(
                workItem,
                microphone: microphone,
                systemAudio: systemAudio,
                handle: handle,
                spoolPlan: spoolPlan,
                finalAssignmentAttempt: finalAssignment.attempt,
                diarizationEnabled: diarizationDecision == .execute,
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
        let refreshedOutputs: [TranscriptionChunkOutput] = refreshedPlan.completedASRCheckpoints.compactMap { checkpoint -> TranscriptionChunkOutput? in
            guard let workItem = workItems.first(where: { $0.sequence == checkpoint.sequence }) else {
                return nil
            }
            return transcriptionOutput(checkpoint: checkpoint, workItem: workItem)
        }
        let merged = try transcriptionService.mergeMeetingChunks(
            Self.meetingOutputPlaceholders(workItems: workItems, outputs: refreshedOutputs)
        )
        let finalText = normalizedTranscriptionText(merged.text)
        guard !isTranscriptionEffectivelyEmpty(finalText) else {
            let failure = MeetingCaptureAdmissionError.noRetainedSources
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
        if let reservedRecordID = refreshedPlan.reservedTranscriptionRecordID {
            recordID = reservedRecordID
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
                diarizationSegmentsJSON: encodeDiarizationSegmentsJSON(merged.diarizedSegments),
                sourceKind: .manualCapture,
                sourceDisplayName: "Meeting recording",
                id: recordID
            )
            try await Self.completeMeetingAfterHistory(
                recordID: record.id,
                operationGuard: operationGuard,
                generateNote: {
                    try await self.generateMeetingNoteIfNeeded(
                        handle,
                        operationGuard: operationGuard
                    )
                },
                onGenerationFailure: { failure in
                    self.recordMeetingNoteGenerationFailure(
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
            updateRecentTranscriptsMenu()

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

    private func transcribeMeetingWorkItem(
        _ workItem: MeetingChunkWorkItem,
        microphone: SealedAudioSourceChunk?,
        systemAudio: SealedAudioSourceChunk?,
        handle: PindropData.MeetingCaptureHandle,
        spoolPlan: MeetingCaptureSpoolPlan,
        finalAssignmentAttempt: Int,
        diarizationEnabled: Bool,
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
            await removeMixedMeetingChunk(
                mixed,
                handle: handle,
                sequence: workItem.sequence,
                operationGuard: operationGuard
            )
            throw MeetingCaptureAdmissionError.missingMixedAudio
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
            let output = try await transcriptionService.transcribeMeetingChunk(
                input,
                options: makeTranscriptionOptions(route: .manualCapture(.microphoneAndSystemAudio)),
                diarizationOptions: .init(expectedSpeakerCount: manualExpectedSpeakerCount),
                diarizationEnabled: diarizationEnabled
            )
            try operationGuard()
            let segmentsJSON = encodeDiarizationSegmentsJSON(output.diarizedSegments)
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
            await removeMixedMeetingChunk(
                mixed,
                handle: handle,
                sequence: workItem.sequence,
                operationGuard: operationGuard
            )
            recordingState.updateJob(
                stage: .transcribing,
                progress: Self.meetingChunkProgress(completed: outputs.count, total: totalChunks),
                detail: "Transcribed \(outputs.count) chunk\(outputs.count == 1 ? "" : "s")\(warningCount == 0 ? "" : "; \(warningCount) warning\(warningCount == 1 ? "" : "s")")",
                errorMessage: nil
            )
        } catch is CancellationError {
            await removeMixedMeetingChunk(
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
            await removeMixedMeetingChunk(
                mixed,
                handle: handle,
                sequence: workItem.sequence,
                operationGuard: operationGuard
            )
            outputs.append(Self.meetingOutputPlaceholder(for: workItem))
            recordingState.updateJob(
                stage: .transcribing,
                progress: Self.meetingChunkProgress(completed: outputs.count, total: totalChunks),
                detail: "Chunk \(workItem.sequence + 1) failed; continuing with durable siblings.",
                errorMessage: error.localizedDescription
            )
        }
    }
    private func removeMixedMeetingChunk(
        _ mixed: ManagedMixedMeetingChunkArtifact,
        handle: PindropData.MeetingCaptureHandle,
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
                message: "Could not remove derived meeting chunk: \(error.localizedDescription)",
                retryable: true,
                at: .now
            )
        }
    }

    private func captureMeetingStartAssignments(
        sessionID: UUID
    ) throws -> [CaptureStageAssignment] {
        try Self.meetingStartAssignmentStages.map { stage in
            try captureAssignment(
                sessionID: sessionID,
                stage: stage,
                attempt: Self.captureAssignmentAttempt(for: stage)
            )
        }
    }

    private func recordMeetingNoteGenerationFailure(
        _ failure: MeetingNoteGenerationFailure,
        handle: PindropData.MeetingCaptureHandle,
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
                "Meeting note generation failure persistence failed code=\(failure.rawValue) category=\(failure.category.rawValue)"
            )
        }
        Log.app.warning(
            "Meeting note generation failure code=\(failure.rawValue) category=\(failure.category.rawValue) message=\(failure.message)"
        )
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

    private func generateMeetingNoteIfNeeded(
        _ handle: PindropData.MeetingCaptureHandle,
        operationGuard: () throws -> Void
    ) async throws {
        let attempt = Self.captureAssignmentAttempt(for: .noteGeneration)

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
            recordMeetingNoteGenerationFailure(
                .disabled,
                handle: handle,
                attempt: attempt,
            )
            return
        case .skipUnavailable:
            try operationGuard()
            recordMeetingNoteGenerationFailure(
                .unavailable,
                handle: handle,
                attempt: attempt,
            )
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
            runtime = try captureAssignmentResolver.resolveNoteGenerationRuntime(
                for: persistedAssignment
            )
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
            normalizedTranscriptionText(enhancedNote.content)
        )
        guard !content.isEmpty else {
            try operationGuard()
            throw MeetingNoteGenerationFailure.emptyOutput
        }

        do {
            let title = Self.generatedMeetingNoteTitle(
                enhancedNote.title,
                fallback: localized(
                    "Untitled Note",
                    locale: settingsStore.selectedAppLocale.locale
                )
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

    private func recordUnavailablePersistedNoteGenerationRuntime(
        sessionID: UUID,
        assignment: CaptureStageAssignment,
        error: CaptureStageAssignmentResolverError
    ) throws {
        let failureCode: String
        switch error {
        case .persistedNoteProviderUnavailable:
            failureCode = "persisted-provider-unavailable"
        case .persistedNotePromptUnavailable:
            failureCode = "persisted-prompt-unavailable"
        case .missingPersistedNoteProviderCredential:
            failureCode = "persisted-provider-credential-unavailable"
        default:
            throw error
        }

        let warning = "Warning: Note enhancement could not use the provider assigned when capture started: \(error.localizedDescription). Saving the raw transcription instead."
        try captureSessionStore.recordStageFailure(
            sessionID: sessionID,
            stage: .noteGeneration,
            attempt: assignment.attempt,
            domain: "PindropAssignment",
            code: failureCode,
            message: warning,
            retryable: false,
            at: .now
        )
        Log.app.warning("\(warning)")
        toastService.show(ToastPayload(message: warning, style: .standard))
    }

    private func captureAssignment(
        sessionID: UUID,
        stage: CapturePipelineStage,
        attempt: Int
    ) throws -> CaptureStageAssignment {
        let activeBatchModelName = activeModelName
        return try captureSessionStore.resolveAssignment(
            sessionID: sessionID,
            stage: stage,
            attempt: attempt
        ) { [captureAssignmentResolver] in
            try captureAssignmentResolver.select(
                stage: stage,
                attempt: attempt,
                activeBatchModelName: activeBatchModelName
            )
        }
    }

    private func activateAssignedFinalModel(
        _ assignment: CaptureStageAssignment
    ) async throws {
        guard Self.assignedFinalModelNeedsActivation(
            assignment,
            activeModelName: activeModelName
        ) else {
            return
        }
        guard let modelName = assignment.modelIdentifier,
              let model = modelManager.availableModels.first(where: {
                  $0.name == modelName && $0.provider.rawValue == assignment.providerIdentifier
              })
        else {
            throw CaptureStageAssignmentResolverError.unknownBatchModel(
                assignment.modelIdentifier ?? "missing-final-model"
            )
        }
        try await loadAndActivateModel(named: model.name, provider: model.provider)
    }

    private func beginVoiceNoteCapture(noteID: UUID?) throws {
        guard Self.canBeginVoiceNoteCapture(activeHandle: voiceNoteCaptureContext?.handle) else {
            throw VoiceNoteCaptureAdmissionError.captureAlreadyActive
        }
        let preferredInputUID = audioRecorder.currentPreferredInputDeviceUID
            ?? settingsStore.selectedInputDeviceUID
        let microphoneDisplayName = AudioDeviceManager.inputDevices()
            .first(where: { $0.uid == preferredInputUID })?
            .displayName ?? "Microphone"
        let handle = try captureSessionStore.startVoiceNoteCapture(
            startedAt: .now,
            microphoneDisplayName: microphoneDisplayName
        )
        do {
            let liveAssignment = try captureAssignment(
                sessionID: handle.sessionID,
                stage: .liveTranscription,
                attempt: Self.captureAssignmentAttempt(for: .liveTranscription)
            )
            voiceNoteCaptureContext = VoiceNoteCaptureContext(
                handle: handle,
                noteID: noteID,
                liveAssignment: liveAssignment
            )
        } catch {
            failVoiceNoteCapture(handle, stage: "recording-start", error: error)
            throw error
        }
    }

    private func failVoiceNoteCapture(
        _ context: VoiceNoteCaptureContext,
        stage: String,
        error: Error
    ) {
        guard isVoiceNoteCaptureContextCurrent(context) else { return }
        failVoiceNoteCapture(context.handle, stage: stage, error: error)
        clearVoiceNoteCaptureContext(ifCurrent: context)
    }

    private func failVoiceNoteCapture(
        _ handle: PindropData.VoiceNoteCaptureHandle,
        stage: String,
        error: Error
    ) {
        let nsError = error as NSError
        let captureStage: CapturePipelineStage? = switch stage {
        case "transcribe", "no-speech":
            .finalTranscription
        case "persist":
            .noteGeneration
        default:
            nil
        }
        do {
            try captureSessionStore.fail(
                handle,
                stage: captureStage,
                errorDomain: nsError.domain,
                errorCode: String(nsError.code),
                message: error.localizedDescription,
                at: .now
            )
        } catch {
            Log.app.error("Failed to mark voice-note capture as failed: \(error)")
        }
    }

    private func failActiveVoiceNoteCapture(stage: String, error: Error) {
        guard let context = voiceNoteCaptureContext else { return }
        failVoiceNoteCapture(context, stage: stage, error: error)
    }

    private func cancelActiveVoiceNoteCapture() {
        guard let context = voiceNoteCaptureContext else { return }
        do {
            try captureSessionStore.cancel(context.handle, at: .now)
        } catch {
            Log.app.error("Failed to cancel voice-note capture: \(error)")
        }
        clearVoiceNoteCaptureContext(ifCurrent: context)
    }

    private func stopRecordingAndTranscribeForNoteAppend(token: DictationOperationToken) async throws -> VoiceNoteCaptureResult? {
        guard let recordingStartTime, let context = voiceNoteCaptureContext, context.noteID != nil else {
            Log.app.warning("stopRecordingAndTranscribeForNoteAppend called without an active voice-note capture")
            return nil
        }

        isRecording = false
        mediaPauseService.endRecordingSession()
        suspendLiveContextSessionUpdates()
        isProcessing = true
        var didResetProcessingState = false

        statusBarController.setProcessingState()
        NoteAppendListeningCoordinator.shared.state.transitionToProcessing()

        defer {
            if Self.shouldResetProcessingStateOnExit(
                didResetProcessingState: didResetProcessingState,
                isOperationCurrent: operationController.isCurrent(token)
            ) {
                resetProcessingState()
            }
        }

        let audioData: Data
        do {
            audioData = try await audioRecorder.stopRecording()
            try await Self.finishArtifactCaptureThenBeginFinalization(
                finishArtifactCapture: { [streamingSession] in
                    await streamingSession.finishArtifactCapture(for: context.handle)
                },
                ensureCurrent: { [self] in
                    try ensureVoiceNoteCaptureCurrent(context, token: token)
                },
                beginFinalization: { [captureSessionStore] in
                    try captureSessionStore.beginFinalization(context.handle, at: .now)
                }
            )
        } catch {
            await streamingSession.cancelArtifactCapture(for: context.handle)
            if Self.isTaskCancellation(error) { throw CancellationError() }
            try ensureVoiceNoteCaptureCurrent(context, token: token)
            failVoiceNoteCapture(context, stage: "recording-stop", error: error)
            Log.app.error("Failed to stop note-append recording: \(error)")
            throw error
        }

        guard !audioData.isEmpty else {
            let noSpeechError = NSError(
                domain: "tech.watzon.pindrop.capture",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "No audio data recorded"]
            )
            failVoiceNoteCapture(context, stage: "no-speech", error: noSpeechError)
            Log.app.warning("No audio data recorded for note-append")
            handleNoSpeechDetected(context: "note-append")
            return nil
        }
        let duration = Date.now.timeIntervalSince(recordingStartTime)

        let transcriptionOutput: TranscriptionOutput
        let finalModelIdentifier: String
        do {
            let finalAssignment = try captureAssignment(
                sessionID: context.handle.sessionID,
                stage: .finalTranscription,
                attempt: Self.captureAssignmentAttempt(for: .finalTranscription)
            )
            guard let modelIdentifier = Self.finalHistoryModelIdentifier(from: finalAssignment) else {
                throw CaptureStageAssignmentError.missingModelIdentifier(
                    providerKind: finalAssignment.providerKind
                )
            }
            finalModelIdentifier = modelIdentifier
            try await activateAssignedFinalModel(finalAssignment)
            transcriptionOutput = try await transcriptionService.transcribe(
                audioData: audioData,
                diarizationEnabled: Self.dictationUsesSpeakerDiarization,
                options: makeTranscriptionOptions(route: .noteAppend),
                diarizationOptions: .init(),
                diarizationFailurePolicy: .bestEffort
            )
            try ensureVoiceNoteCaptureCurrent(context, token: token)
        } catch let error as PindropSpeech.TranscriptionService.TranscriptionError {
            guard operationController.isCurrent(token),
                  isVoiceNoteCaptureContextCurrent(context),
                  !Self.isTaskCancellation(error) else {
                throw CancellationError()
            }
            failVoiceNoteCapture(context, stage: "transcribe", error: error)
            Log.app.error("Note-append transcription failed: \(error)")
            reportTranscriptionFailureSignal(error, stage: "transcribe")
            resetProcessingState()
            didResetProcessingState = true
            let message = if case .modelNotLoaded = error {
                "No model loaded. Please download a model in Settings."
            } else {
                "Transcription failed: \(error.localizedDescription)"
            }
            toastService.show(ToastPayload(message: message, style: .error))
            throw error
        } catch {
            guard operationController.isCurrent(token),
                  isVoiceNoteCaptureContextCurrent(context),
                  !Self.isTaskCancellation(error) else {
                throw CancellationError()
            }
            failVoiceNoteCapture(context, stage: "transcribe", error: error)
            Log.app.error("Note-append transcription failed: \(error)")
            reportTranscriptionFailureSignal(error, stage: "transcribe")
            resetProcessingState()
            didResetProcessingState = true
            let locale = settingsStore.selectedAppLocale.locale
            toastService.show(
                ToastPayload(
                    message: String(format: localized("Transcription failed: %@", locale: locale), locale: locale, error.localizedDescription),
                    style: .error
                )
            )
            throw error
        }

        do {
            let rawText = transcriptionOutput.text
            var (finalText, appliedReplacements) = try dictionaryStore.applyReplacements(to: rawText)
            finalText = normalizedTranscriptionText(finalText)

            guard !isTranscriptionEffectivelyEmpty(finalText) else {
                let noSpeechError = NSError(
                    domain: "tech.watzon.pindrop.capture",
                    code: 2,
                    userInfo: [NSLocalizedDescriptionKey: "No speech detected"]
                )
                failVoiceNoteCapture(context, stage: "no-speech", error: noSpeechError)
                handleNoSpeechDetected(context: "note-append")
                return nil
            }
            try ensureVoiceNoteCaptureCurrent(context, token: token)
            self.lastAppliedReplacements = appliedReplacements
            try dictionaryStore.recordVocabularyHits(in: finalText)

            if !appliedReplacements.isEmpty {
                Log.app.info("Applied \(appliedReplacements.count) dictionary replacements (note-append)")
            }

            return VoiceNoteCaptureResult(
                context: context,
                rawText: rawText,
                finalText: finalText,
                duration: duration,
                languageCode: settingsStore.selectedAppLanguage.rawValue,
                finalModelIdentifier: finalModelIdentifier,
                enhancedWithModel: nil,
                title: nil,
                tags: []
            )
        } catch {
            guard Self.shouldEmitOperationFailureSideEffects(
                isOperationCurrent: operationController.isCurrent(token),
                error: error
            ), isVoiceNoteCaptureContextCurrent(context) else {
                throw CancellationError()
            }
            failVoiceNoteCapture(context, stage: "transcribe", error: error)
            throw error
        }
    }

    private func stopRecordingAndTranscribeForQuickCapture(token: DictationOperationToken) async throws -> VoiceNoteCaptureResult? {
        guard let recordingStartTime, let context = voiceNoteCaptureContext, context.noteID == nil else {
            Log.app.warning("stopRecordingAndTranscribeForQuickCapture called without an active quick-capture session")
            return nil
        }

        isRecording = false
        mediaPauseService.endRecordingSession()
        suspendLiveContextSessionUpdates()
        isProcessing = true
        var didResetProcessingState = false

        statusBarController.setProcessingState()
        transitionRecordingIndicatorToProcessing()

        defer {
            if Self.shouldResetProcessingStateOnExit(
                didResetProcessingState: didResetProcessingState,
                isOperationCurrent: operationController.isCurrent(token)
            ) {
                resetProcessingState()
            }
        }

        let audioData: Data
        do {
            audioData = try await audioRecorder.stopRecording()
            try await Self.finishArtifactCaptureThenBeginFinalization(
                finishArtifactCapture: { [streamingSession] in
                    await streamingSession.finishArtifactCapture(for: context.handle)
                },
                ensureCurrent: { [self] in
                    try ensureVoiceNoteCaptureCurrent(context, token: token)
                },
                beginFinalization: { [captureSessionStore] in
                    try captureSessionStore.beginFinalization(context.handle, at: .now)
                }
            )
        } catch {
            await streamingSession.cancelArtifactCapture(for: context.handle)
            if Self.isTaskCancellation(error) { throw CancellationError() }
            try ensureVoiceNoteCaptureCurrent(context, token: token)
            failVoiceNoteCapture(context, stage: "recording-stop", error: error)
            Log.app.error("Failed to stop quick-capture recording: \(error)")
            throw error
        }

        guard !audioData.isEmpty else {
            let noSpeechError = NSError(
                domain: "tech.watzon.pindrop.capture",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "No audio data recorded"]
            )
            failVoiceNoteCapture(context, stage: "no-speech", error: noSpeechError)
            Log.app.warning("No audio data recorded")
            handleNoSpeechDetected(context: "quick-capture")
            return nil
        }
        let duration = Date.now.timeIntervalSince(recordingStartTime)

        let transcriptionOutput: TranscriptionOutput
        let finalModelIdentifier: String
        do {
            let finalAssignment = try captureAssignment(
                sessionID: context.handle.sessionID,
                stage: .finalTranscription,
                attempt: Self.captureAssignmentAttempt(for: .finalTranscription)
            )
            guard let modelIdentifier = Self.finalHistoryModelIdentifier(from: finalAssignment) else {
                throw CaptureStageAssignmentError.missingModelIdentifier(
                    providerKind: finalAssignment.providerKind
                )
            }
            finalModelIdentifier = modelIdentifier
            try await activateAssignedFinalModel(finalAssignment)
            transcriptionOutput = try await transcriptionService.transcribe(
                audioData: audioData,
                diarizationEnabled: Self.dictationUsesSpeakerDiarization,
                options: makeTranscriptionOptions(route: .quickCapture),
                diarizationOptions: .init(),
                diarizationFailurePolicy: .bestEffort
            )
            try ensureVoiceNoteCaptureCurrent(context, token: token)
        } catch let error as PindropSpeech.TranscriptionService.TranscriptionError {
            guard operationController.isCurrent(token),
                  isVoiceNoteCaptureContextCurrent(context),
                  !Self.isTaskCancellation(error) else {
                throw CancellationError()
            }
            failVoiceNoteCapture(context, stage: "transcribe", error: error)
            Log.app.error("Quick-capture transcription failed: \(error)")
            reportTranscriptionFailureSignal(error, stage: "transcribe")
            resetProcessingState()
            didResetProcessingState = true
            let locale = settingsStore.selectedAppLocale.locale
            let message = if case .modelNotLoaded = error {
                localized("No model loaded. Please download a model in Settings.", locale: locale)
            } else {
                String(format: localized("Transcription failed: %@", locale: locale), locale: locale, error.localizedDescription)
            }
            toastService.show(ToastPayload(message: message, style: .error))
            throw error
        } catch {
            guard operationController.isCurrent(token),
                  isVoiceNoteCaptureContextCurrent(context),
                  !Self.isTaskCancellation(error) else {
                throw CancellationError()
            }
            failVoiceNoteCapture(context, stage: "transcribe", error: error)
            Log.app.error("Quick-capture transcription failed: \(error)")
            reportTranscriptionFailureSignal(error, stage: "transcribe")
            resetProcessingState()
            didResetProcessingState = true
            let locale = settingsStore.selectedAppLocale.locale
            toastService.show(
                ToastPayload(
                    message: String(format: localized("Transcription failed: %@", locale: locale), locale: locale, error.localizedDescription),
                    style: .error
                )
            )
            throw error
        }

        do {
            let rawText = transcriptionOutput.text
            var (fallbackText, appliedReplacements) = try dictionaryStore.applyReplacements(to: rawText)
            fallbackText = normalizedTranscriptionText(fallbackText)

            guard !isTranscriptionEffectivelyEmpty(fallbackText) else {
                let noSpeechError = NSError(
                    domain: "tech.watzon.pindrop.capture",
                    code: 2,
                    userInfo: [NSLocalizedDescriptionKey: "No speech detected"]
                )
                failVoiceNoteCapture(context, stage: "no-speech", error: noSpeechError)
                handleNoSpeechDetected(context: "quick-capture")
                return nil
            }
            try ensureVoiceNoteCaptureCurrent(context, token: token)
            self.lastAppliedReplacements = appliedReplacements
            try dictionaryStore.recordVocabularyHits(in: fallbackText)

            if !appliedReplacements.isEmpty {
                Log.app.info("Applied \(appliedReplacements.count) dictionary replacements")
            }

            let noteGenerationAssignment = try captureAssignment(
                sessionID: context.handle.sessionID,
                stage: .noteGeneration,
                attempt: Self.captureAssignmentAttempt(for: .noteGeneration)
            )
            if let persistedNoteGenerationAssignment = Self.noteGenerationRuntimeAssignment(
                from: noteGenerationAssignment
            ) {
                let noteRuntime: ResolvedAssignment?
                do {
                    noteRuntime = try captureAssignmentResolver.resolveNoteGenerationRuntime(
                        for: persistedNoteGenerationAssignment
                    )
                } catch let error as CaptureStageAssignmentResolverError {
                    try recordUnavailablePersistedNoteGenerationRuntime(
                        sessionID: context.handle.sessionID,
                        assignment: persistedNoteGenerationAssignment,
                        error: error
                    )
                    noteRuntime = nil
                }


                if let noteRuntime,
                   Self.canExecutePersistedNoteGeneration(resolvedPrompt: noteRuntime.prompt),
                   let notePrompt = noteRuntime.prompt {
                    let vocabularyWords = try dictionaryStore.fetchAllVocabularyWords().map(\.word)
                    do {
                        let replacementCorrections = appliedReplacements.map {
                            PindropAI.AIEnhancementService.ContextMetadata.ReplacementCorrection(
                                original: $0.original,
                                replacement: $0.replacement
                            )
                        }
                        let enhancementContext = PindropAI.AIEnhancementService.ContextMetadata(
                            hasClipboardText: false,
                            clipboardText: nil,
                            hasClipboardImage: false,
                            appContext: nil,
                            vocabularyWords: vocabularyWords,
                            replacementCorrections: replacementCorrections
                        )

                        let existingTags = (try? notesStore.getAllUniqueTags()) ?? []
                        let enhancedNote = try await aiEnhancementService.enhanceNote(
                            content: fallbackText,
                            apiEndpoint: noteRuntime.endpoint ?? "",
                            apiKey: noteRuntime.apiKey,
                            model: noteRuntime.modelID,
                            contentPrompt: notePrompt,
                            generateMetadata: true,
                            existingTags: existingTags,
                            context: enhancementContext,
                            provider: noteRuntime.kind
                        )
                        try ensureVoiceNoteCaptureCurrent(context, token: token)
                        let finalText = normalizedTranscriptionText(enhancedNote.content)
                        if !isTranscriptionEffectivelyEmpty(finalText) {
                            Log.app.info("Note enhancement completed: title='\(enhancedNote.title)', tags=\(enhancedNote.tags.count)")
                            return VoiceNoteCaptureResult(
                                context: context,
                                rawText: rawText,
                                finalText: finalText,
                                duration: duration,
                                languageCode: settingsStore.selectedAppLanguage.rawValue,
                                finalModelIdentifier: finalModelIdentifier,
                                enhancedWithModel: noteRuntime.modelID,
                                title: enhancedNote.title,
                                tags: enhancedNote.tags
                            )
                        }
                        Log.app.error("Note enhancement returned empty content; using raw transcription")
                    } catch {
                        if Self.isTaskCancellation(error)
                            || !operationController.isCurrent(token)
                            || !isVoiceNoteCaptureContextCurrent(context) {
                            throw CancellationError()
                        }
                        Log.app.error("Note enhancement failed: \(error)")
                    }
                } else if let noteRuntime {
                    try recordUnavailablePersistedNoteGenerationRuntime(
                        sessionID: context.handle.sessionID,
                        assignment: persistedNoteGenerationAssignment,
                        error: .persistedNotePromptUnavailable(
                            noteRuntime.promptPresetID ?? "missing-persisted-prompt"
                        )
                    )
                }
            }

            try ensureVoiceNoteCaptureCurrent(context, token: token)
            return VoiceNoteCaptureResult(
                context: context,
                rawText: rawText,
                finalText: fallbackText,
                duration: duration,
                languageCode: settingsStore.selectedAppLanguage.rawValue,
                finalModelIdentifier: finalModelIdentifier,
                enhancedWithModel: nil,
                title: aiEnhancementService.generateFallbackTitle(from: fallbackText),
                tags: []
            )
        } catch {
            guard Self.shouldEmitOperationFailureSideEffects(
                isOperationCurrent: operationController.isCurrent(token),
                error: error
            ), isVoiceNoteCaptureContextCurrent(context) else {
                throw CancellationError()
            }
            failVoiceNoteCapture(context, stage: "transcribe", error: error)
            throw error
        }
    }

    private func persistQuickCapture(
        _ result: VoiceNoteCaptureResult,
        token: DictationOperationToken
    ) async throws -> PindropData.NoteSchema.Note {
        do {
            try ensureVoiceNoteCaptureCurrent(result.context, token: token)
            let revisions = try captureSessionStore.saveTranscriptRevisions(
                for: result.context.handle,
                rawText: result.rawText,
                finalText: result.finalText,
                duration: result.duration,
                languageCode: result.languageCode,
                createdAt: .now
            )
            try ensureVoiceNoteCaptureCurrent(result.context, token: token)
            let record = try historyStore.save(
                text: result.finalText,
                originalText: result.rawText,
                duration: result.duration,
                modelUsed: result.finalModelIdentifier,
                enhancedWith: result.enhancedWithModel,
                sourceKind: .voiceRecording
            )
            let linkageIDs = VoiceNoteLinkageIDs(
                historyRecordID: record.id,
                finalTranscriptRevisionID: revisions.finalRevisionID
            )
            try ensureVoiceNoteCaptureCurrent(result.context, token: token)
            try captureSessionStore.linkTranscriptionRecord(
                linkageIDs.historyRecordID,
                to: result.context.handle,
                at: .now
            )
            try ensureVoiceNoteCaptureCurrent(result.context, token: token)
            let note = try await notesStore.create(
                title: result.title,
                content: result.finalText,
                tags: result.tags,
                sourceTranscriptionID: linkageIDs.historyRecordID
            )
            try ensureVoiceNoteCaptureCurrent(result.context, token: token)
            try captureSessionStore.complete(
                result.context.handle,
                noteID: note.id,
                finalTranscriptRevisionID: linkageIDs.finalTranscriptRevisionID,
                at: .now
            )
            clearVoiceNoteCaptureContext(ifCurrent: result.context)
            return note
        } catch {
            guard operationController.isCurrent(token),
                  isVoiceNoteCaptureContextCurrent(result.context) else {
                throw CancellationError()
            }
            failVoiceNoteCapture(result.context, stage: "persist", error: error)
            throw error
        }
    }

    private func persistNoteAppend(
        _ result: VoiceNoteCaptureResult,
        editorID: UUID,
        token: DictationOperationToken
    ) async throws {
        guard let noteID = result.context.noteID else {
            throw CancellationError()
        }

        do {
            try ensureVoiceNoteCaptureCurrent(result.context, token: token)
            let revisions = try captureSessionStore.saveTranscriptRevisions(
                for: result.context.handle,
                rawText: result.rawText,
                finalText: result.finalText,
                duration: result.duration,
                languageCode: result.languageCode,
                createdAt: .now
            )
            try ensureVoiceNoteCaptureCurrent(result.context, token: token)
            let record = try historyStore.save(
                text: result.finalText,
                originalText: result.rawText,
                duration: result.duration,
                modelUsed: result.finalModelIdentifier,
                enhancedWith: nil,
                sourceKind: .voiceRecording
            )
            let linkageIDs = VoiceNoteLinkageIDs(
                historyRecordID: record.id,
                finalTranscriptRevisionID: revisions.finalRevisionID
            )
            try ensureVoiceNoteCaptureCurrent(result.context, token: token)
            try captureSessionStore.linkTranscriptionRecord(
                linkageIDs.historyRecordID,
                to: result.context.handle,
                at: .now
            )
            try ensureVoiceNoteCaptureCurrent(result.context, token: token)
            let append = try notesStore.appendTranscript(
                to: noteID,
                content: result.finalText,
                sourceTranscriptionID: linkageIDs.historyRecordID
            )
            try ensureVoiceNoteCaptureCurrent(result.context, token: token)
            try captureSessionStore.complete(
                result.context.handle,
                noteID: append.noteID,
                finalTranscriptRevisionID: linkageIDs.finalTranscriptRevisionID,
                at: .now
            )
            clearVoiceNoteCaptureContext(ifCurrent: result.context)
            NotificationCenter.default.post(
                name: .noteSpeakToAppendTranscript,
                object: nil,
                userInfo: [
                    "editorID": editorID,
                    "noteID": append.noteID,
                    "content": append.content,
                    "sourceTranscriptionID": Self.noteAppendNotificationSourceTranscriptionID(append)
                ]
            )
        } catch {
            guard operationController.isCurrent(token),
                  isVoiceNoteCaptureContextCurrent(result.context) else {
                throw CancellationError()
            }
            failVoiceNoteCapture(result.context, stage: "persist", error: error)
            throw error
        }
    }

    private func openNoteEditor(_ note: PindropData.NoteSchema.Note) {
        noteEditorWindowController.show(note: note, isNewNote: true)
        Log.app.info("Opened note editor with durable quick-capture note")
    }

    private func handleMainWindowDictationStart() {
        guard !isRecording,
              !isProcessing,
              let claim = recordingState.claimCaptureStart() else { return }

        mainWindowCaptureStartTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                self.recordingState.releaseCaptureStart(claim)
                self.mainWindowCaptureStartTask = nil
            }
            await self.handleToggleRecording(
                source: .statusBarMenu,
                captureStartClaim: claim
            )
        }
    }

    private func handleMainWindowVoiceNoteStart() {
        guard !isRecording,
              !isProcessing,
              let claim = recordingState.claimCaptureStart() else { return }

        mainWindowCaptureStartTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                self.recordingState.releaseCaptureStart(claim)
                self.mainWindowCaptureStartTask = nil
            }
            await self.handleQuickCaptureToggle(captureStartClaim: claim)
        }
    }

    private func handleToggleRecording(
        source: RecordingTriggerSource,
        captureStartClaim: CaptureStartClaim? = nil
    ) async {
        if isRecording {
            do {
                if isNoteAppendMode {
                    guard noteAppendEditorID != nil else { return }
                    try await dispatchRecordingStop()
                } else {
                    try await dispatchRecordingStop()
                }
            } catch {
                self.error = error
                audioRecorder.resetAudioEngine()
                Log.app.error("Failed to stop recording: \(error)")
            }
        } else if !isProcessing,
                  captureStartClaim != nil || !recordingState.isCaptureStartPending {
            guard NoteAppendGate.canStartGlobalDictation(
                isNoteAppendListening: isNoteAppendMode || pendingNoteAppendStart != nil
            ) else {
                Log.app.info("Refuse global dictation toggle: note-append listening is active")
                return
            }
            do {
                try await startRecording(
                    source: source,
                    captureStartClaim: captureStartClaim
                )
            } catch {
                guard !Self.isTaskCancellation(error) else { return }
                self.error = error
                audioRecorder.resetAudioEngine()
                Log.app.error("Failed to start recording: \(error)")
                handleRecordingStartFailure(error, source: source)
            }
        }
    }
    
    private func startRecording(
        source: RecordingTriggerSource,
        voiceNoteContext: VoiceNoteCaptureContext? = nil,
        pendingNoteAppendStart: PendingNoteAppendStart? = nil,
        captureStartClaim: CaptureStartClaim? = nil
    ) async throws {
        let claim: CaptureStartClaim
        if let captureStartClaim {
            claim = captureStartClaim
        } else {
            guard let claimedStart = recordingState.claimCaptureStart() else {
                throw CancellationError()
            }
            claim = claimedStart
        }
        defer { recordingState.releaseCaptureStart(claim) }
        try ensureCaptureStartCurrent(claim)
        automaticDictionaryLearningService.cancelObservation()
        logRecordingStartAttempt(source: source)

        // If permissions were granted after launch, recreate global event taps
        // so escape-to-cancel and modifier tracking become available mid-session.
        ensureGlobalKeyMonitorsIfPossible()

        if let voiceNoteContext {
            if let pendingNoteAppendStart {
                try ensurePendingNoteAppendStartCurrent(
                    pendingNoteAppendStart,
                    context: voiceNoteContext
                )
            } else {
                guard isVoiceNoteCaptureContextCurrent(voiceNoteContext) else {
                    throw CancellationError()
                }
            }
        }
        let startedStreamingSession = await beginStreamingSessionIfAvailable(for: voiceNoteContext)
        do {
            try ensureCaptureStartCurrent(claim)
            if let voiceNoteContext {
                try await ensureVoiceNoteCaptureCurrentAfterArtifactAdmission(
                    voiceNoteContext,
                    pendingNoteAppendStart: pendingNoteAppendStart
                )
                try ensureCaptureStartCurrent(claim)
            }
        } catch {
            await cancelCaptureStartStreaming(
                voiceNoteContext: voiceNoteContext,
                session: startedStreamingSession
            )
            throw error
        }

        // Retention encodes a native-rate copy so kept audio isn't the 16 kHz ASR feed.
        audioRecorder.retainNativeAudioForSession =
            settingsStore.dictationAudioRetention != .off

        var recorderStarted = false
        let didStartRecording: Bool
        do {
            didStartRecording = try await audioRecorder.startRecording()
            recorderStarted = didStartRecording
            try ensureCaptureStartCurrent(claim)
            if let voiceNoteContext, let pendingNoteAppendStart {
                try ensurePendingNoteAppendStartCurrent(
                    pendingNoteAppendStart,
                    context: voiceNoteContext
                )
                try ensureCaptureStartCurrent(claim)
            }
        } catch {
            if recorderStarted || Self.isTaskCancellation(error) {
                audioRecorder.resetAudioEngine()
            }
            await cancelCaptureStartStreaming(
                voiceNoteContext: voiceNoteContext,
                session: startedStreamingSession
            )
            if !Self.isTaskCancellation(error) {
                Log.app.error("Audio engine failed to start: \(error)")
                throw error
            }
            throw CancellationError()
        }

        if didStartRecording {
            switch source {
            case .noteAppend:
                break
            default:
                // A newer capture owns the recorder now, so a cancelled
                // note-append start must not reset it when its task unwinds.
                pendingNoteAppendAudioStartupRequest = nil
            }
        }

        guard didStartRecording else {
            await cancelCaptureStartStreaming(
                voiceNoteContext: voiceNoteContext,
                session: startedStreamingSession
            )
            throw VoiceNoteCaptureAdmissionError.recorderDidNotStart
        }

        if settingsStore.pauseMediaOnRecording || settingsStore.muteAudioDuringRecording {
            mediaPauseService.beginRecordingSession(
                pauseMedia: settingsStore.pauseMediaOnRecording,
                muteSystemAudio: settingsStore.muteAudioDuringRecording
            )
        }
        
        isRecording = true
        recordingStartTime = Date()
        capturedAdapterCapabilities = nil
        capturedRoutingSignal = nil
        cancelPendingContextSessionRefresh()
        contextSessionState = nil
        lastFocusOrWindowUpdateAt = nil

        if settingsStore.enableClipboardContext || settingsStore.enableUIContext {
            let clipboardText = settingsStore.enableClipboardContext ? contextCaptureService.captureClipboardText() : nil
            capturedContext = CapturedContext(clipboardText: clipboardText)

            // Capture AX-based UI context when enabled (non-blocking)
            var appContext: AppContextInfo? = nil
            var captureWarnings: [ContextCaptureWarning] = []
            if settingsStore.enableUIContext {
                let result = contextEngineService.captureAppContext()
                appContext = result.appContext
                captureWarnings = result.warnings
                if !captureWarnings.isEmpty {
                    Log.app.debug("UI context capture warnings: \(captureWarnings.map(\.localizedDescription).joined(separator: ", "))")
                }
                if let ctx = appContext {
                    Log.app.info("Captured UI context: hasAppName=\(!ctx.appName.isEmpty), hasWindowTitle=\(ctx.windowTitle != nil)")
                }
            }

            capturedSnapshot = ContextSnapshot(
                timestamp: Date(),
                appContext: appContext,
                clipboardText: clipboardText,
                warnings: captureWarnings
            )

            if let snapshot = capturedSnapshot {
                let routingSignal = PromptRoutingSignal.from(
                    snapshot: snapshot,
                    adapterRegistry: appContextAdapterRegistry
                )
                capturedRoutingSignal = routingSignal
                _ = promptRoutingResolver.resolve(signal: routingSignal)

                if let bundleIdentifier = snapshot.appContext?.bundleIdentifier {
                    let adapter = appContextAdapterRegistry.adapter(for: bundleIdentifier)
                    capturedAdapterCapabilities = adapter.capabilities
                    let caps = adapter.capabilities
                    Log.context.info("Adapter context: app=\(caps.displayName) prefix=\(caps.mentionPrefix) fileMentions=\(caps.supportsFileMentions) codeContext=\(caps.supportsCodeContext) docsMentions=\(caps.supportsDocsMentions) diffContext=\(caps.supportsDiffContext) webContext=\(caps.supportsWebContext) chatHistory=\(caps.supportsChatHistory)")
                }
            }
        }

        if shouldRunLiveContextSession() {
            startLiveContextSessionIfNeeded(initialSnapshot: capturedSnapshot)
        } else {
            updateVibeRuntimeStateFromSettings()
        }

        statusBarController.setRecordingState()

        // Speak-to-append uses the in-editor listening chip only — no global orb/pill.
        if source != .noteAppend {
            startRecordingIndicatorSession()
        }
    }

    private func ensureCaptureStartCurrent(_ claim: CaptureStartClaim) throws {
        try Task.checkCancellation()
        guard !isShutdown,
              !isPreparingForTermination,
              recordingState.isCaptureStartClaimCurrent(claim) else {
            throw CancellationError()
        }
    }

    private func cancelCaptureStartStreaming(
        voiceNoteContext: VoiceNoteCaptureContext?,
        session: StreamingSessionController.SessionToken?
    ) async {
        if let voiceNoteContext {
            await streamingSession.cancelArtifactCapture(for: voiceNoteContext.handle)
        } else if let session {
            await streamingSession.cancel(session: session)
            if activeStreamingSessionToken == session {
                activeStreamingSessionToken = nil
            }
        }
    }

    private func logRecordingStartAttempt(source: RecordingTriggerSource) {
        recordingStartAttemptCounter += 1
        let snapshot = permissionManager.microphoneAuthorizationSnapshot()
        let shortVersion = Bundle.main.appShortVersionString
        let buildVersion = Bundle.main.appBuildVersionString
        let bundleIdentifier = Bundle.main.bundleIdentifier ?? "unknown"
        let bundlePath = Bundle.main.bundleURL.path
        let executablePath = Bundle.main.executableURL?.path ?? "unknown"
        let cachedDecision = snapshot.cachedDecision.map { $0 ? "granted" : "denied" } ?? "none"

        Log.app.info(
            "recording_start_attempt id=\(self.recordingStartAttemptCounter) source=\(source.rawValue) resolved=\(String(describing: snapshot.resolvedStatus)) avaudio=\(snapshot.audioApplicationStatus) avcapture=\(snapshot.captureDeviceStatus) requestedThisLaunch=\(snapshot.hasRequestedThisLaunch) cachedDecision=\(cachedDecision) bundleId=\(bundleIdentifier) shortVersion=\(shortVersion) buildVersion=\(buildVersion) pid=\(ProcessInfo.processInfo.processIdentifier) onboardingCompleted=\(self.settingsStore.hasCompletedOnboarding) bundlePath=\(bundlePath) executablePath=\(executablePath)"
        )
    }

    /// Builds transcription options including WhisperKit vocabulary bias words.
    private func makeTranscriptionOptions(
        language: AppLanguage? = nil,
        route: CoordinatorTranscriptionRoute
    ) -> TranscriptionOptions {
        let bias = (try? dictionaryStore.vocabularyBiasWords()) ?? []
        return TranscriptionOptions(
            language: language ?? settingsStore.selectedAppLanguage,
            vocabularyBiasWords: bias,
            audioPreprocessingMode: Self.audioPreprocessingMode(
                for: route,
                voiceIsolationEnabled: settingsStore.voiceIsolationEnabled
            )
        )
    }

    static func audioPreprocessingMode(
        for route: CoordinatorTranscriptionRoute,
        voiceIsolationEnabled: Bool
    ) -> AudioPreprocessingMode {
        voiceIsolationEnabled && route.appliesVoiceIsolation ? .voiceIsolation : .none
    }

    private func normalizedTranscriptionText(_ text: String) -> String {
        Self.normalizedTranscriptionText(text)
    }

    static func normalizedTranscriptionText(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    private func isTranscriptionEffectivelyEmpty(_ text: String) -> Bool {
        Self.isTranscriptionEffectivelyEmpty(text)
    }

    static func isTranscriptionEffectivelyEmpty(_ text: String) -> Bool {
        let normalizedText = normalizedTranscriptionText(text)
        if normalizedText.isEmpty {
            return true
        }
        return normalizedText.caseInsensitiveCompare("[BLANK AUDIO]") == .orderedSame
    }

    static func shouldPersistHistory(outputSucceeded: Bool, text: String) -> Bool {
        outputSucceeded && !isTranscriptionEffectivelyEmpty(text)
    }

    /// Dictation transcriptions never diarize: the output is a single-speaker paste
    /// into the target app, and speaker attribution both pollutes it with
    /// "Speaker N:" prefixes and can drop tail words when segment stitching
    /// disagrees with the final transcript. Speaker diarization belongs to meeting
    /// and media transcription jobs, which gate it via `TranscriptionJobOptions`.
    static let dictationUsesSpeakerDiarization = false

    /// The v3 (overlay) streaming gate. Streaming transcription runs whenever the user's
    /// streaming preference says so, independent of any AI-enhancement assignment. Live
    /// text renders in the floating-indicator overlay; the target app receives the final
    /// text once, via a single paste at stop (after dictionary replacements and the
    /// optional post-stop enhancement rewrite).
    ///
    /// Gates that matter: feature flag, quick-capture mode, and floating-indicator
    /// availability. With overlay streaming the live transcript renders in Pindrop's own
    /// indicator overlay and the target app receives one paste at the end, so:
    ///   - `outputMode` no longer gates — clipboard-mode users get the live overlay too;
    ///     the final landing routes through `output(_:)` per mode.
    ///   - The indicator must be available: without an overlay there is nowhere to show
    ///     live text, and streaming has no user-visible benefit over batch. We never
    ///     force-show UI the user disabled or temporarily hid.
    static func shouldUseStreamingTranscription(
        streamingFeatureEnabled: Bool,
        isQuickCaptureMode: Bool,
        floatingIndicatorAvailable: Bool,
        isNoteAppendMode: Bool = false
    ) -> Bool {
        streamingFeatureEnabled
            && !isQuickCaptureMode
            && !isNoteAppendMode
            && floatingIndicatorAvailable
    }

    private func encodeDiarizationSegmentsJSON(_ segments: [DiarizedTranscriptSegment]?) -> String? {
        guard let segments, !segments.isEmpty else {
            return nil
        }

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

    private func speakerTrainingSegments(
        audioData: Data,
        existingSegments: [DiarizedTranscriptSegment]?
    ) async -> [DiarizedTranscriptSegment] {
        if let existingSegments, !existingSegments.isEmpty {
            return existingSegments
        }

        do {
            return try await transcriptionService.extractSpeakerProfileSegments(audioData: audioData)
        } catch {
            Log.transcription.warning(
                "Speaker profile training skipped for this dictation: \(error.localizedDescription)"
            )
            return []
        }
    }

    private func shouldUseStreamingTranscriptionForCurrentSession() -> Bool {
        Self.shouldUseStreamingTranscription(
            streamingFeatureEnabled: settingsStore.streamingFeatureEnabled,
            isQuickCaptureMode: isQuickCaptureMode,
            floatingIndicatorAvailable: isFloatingIndicatorAvailable(),
            isNoteAppendMode: isNoteAppendMode
        )
    }

    /// Whether any floating indicator can currently present — the master enable
    /// switch and the temporary "hide for 1 hour" state both suppress it.
    private func isFloatingIndicatorAvailable() -> Bool {
        settingsStore.floatingIndicatorEnabled && !isFloatingIndicatorTemporarilyHidden()
    }

    private func handleNoSpeechDetected(context: String) {
        Log.app.info("No speech detected for \(context); skipping output")
        telemetryService.send(
            .transcriptionEmptyResult,
            parameters: [
                TelemetryParameter.stage: context,
                TelemetryParameter.backend: settingsStore.resolvedTranscriptionBackend.rawValue
            ]
        )
        toastService.show(
            ToastPayload(
                message: localized(
                    "No speech detected. Try speaking closer to your microphone.",
                    locale: settingsStore.selectedAppLocale.locale
                )
            )
        )
    }

    /// Reports a transcription failure as a telemetry signal. Only the bare error
    /// case label and pipeline stage are sent — never messages or paths.
    private func reportTranscriptionFailureSignal(_ error: Error, stage: String) {
        telemetryService.send(
            .transcriptionFailed,
            parameters: [
                TelemetryParameter.errorCase: TelemetryService.errorCaseName(error),
                TelemetryParameter.stage: stage,
                TelemetryParameter.backend: settingsStore.resolvedTranscriptionBackend.rawValue,
                TelemetryParameter.model: settingsStore.selectedModel
            ]
        )
    }

    /// Success toast after a paste landed in the target app. Not shown for clipboard-only
    /// fallback (that path gets a separate Copied+Undo toast in B7).
    private func showInsertionSuccessToast(appName: String?, wordCount: Int) {
        let locale = settingsStore.selectedAppLocale.locale
        let trimmedName = appName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let displayName = trimmedName.isEmpty
            ? localized("Unknown App", locale: locale)
            : trimmedName
        let format = localized("Inserted into %@", locale: locale)
        let message = String(format: format, locale: locale, displayName)
        toastService.show(
            ToastPayload(
                message: message,
                style: .standard,
                variant: .inserted(wordCount: wordCount)
            )
        )
    }

    private func handleRecordingStartFailure(_ error: Error, source: RecordingTriggerSource) {
        let isHotkeySource: Bool
        switch source {
        case .hotkeyToggle, .hotkeyPushToTalk, .hotkeyQuickCapturePTT, .hotkeyQuickCaptureToggle:
            isHotkeySource = true
        default:
            isHotkeySource = false
        }

        let isNoteAppendSource = source == .noteAppend
        guard isHotkeySource || isNoteAppendSource,
              let audioError = error as? AudioRecorderError,
              case .permissionDenied = audioError else {
            return
        }

        let locale = settingsStore.selectedAppLocale.locale
        toastService.show(
            ToastPayload(
                message: localized("Microphone unavailable", locale: locale),
                // Permission denial is only fixable in System Settings' mic privacy pane —
                // the app's Dictation tab has no permission controls.
                actions: [
                    ToastAction(
                        title: localized("Settings", locale: locale),
                        role: .primary
                    ) {
                        AlertManager.shared.openMicrophoneSettings()
                    }
                ],
                duration: 8.0,
                style: .error,
                variant: .microphoneUnavailable
            )
        )
    }

    private func beginStreamingSessionIfAvailable(
        for voiceNoteContext: VoiceNoteCaptureContext? = nil
    ) async -> StreamingSessionController.SessionToken? {
        if let voiceNoteContext {
            switch Self.liveArtifactCaptureAdmission(for: voiceNoteContext.liveAssignment) {
            case .capture:
                _ = await streamingSession.beginArtifactCapture(
                    for: voiceNoteContext.handle,
                    assignment: voiceNoteContext.liveAssignment
                )
            case .deactivate:
                streamingSession.deactivate()
            }
            return nil
        }

        guard shouldUseStreamingTranscriptionForCurrentSession() else {
            streamingSession.deactivate()
            return nil
        }
        let session = await streamingSession.begin()
        // A canceled older begin can resume after its successor has installed a token.
        // Its nil admission result must not erase that successor's global reference.
        if let session {
            activeStreamingSessionToken = session
        }
        return session
    }
    private func cancelActiveStreamingSession() async {
        guard let session = activeStreamingSessionToken else { return }
        activeStreamingSessionToken = nil
        await streamingSession.cancel(session: session)
    }


    /// Resolves prompt overrides, stable built-in identifiers, and persisted preset
    /// UUIDs through one path so every enhancement entry point sends the same text.
    func resolvedPrompt(
        for assignment: ResolvedAssignment,
        fallback: String
    ) -> String {
        if let prompt = assignment.prompt {
            return prompt
        }

        do {
            if let prompt = try promptPresetStore.resolvePrompt(for: assignment.promptPresetID) {
                return prompt
            }
        } catch {
            Log.aiEnhancement.error(
                "Failed to resolve prompt preset \(assignment.promptPresetID ?? "nil"): \(error)"
            )
        }
        return fallback
    }

    /// Runs the post-stop transcriptionEnhancement assignment on `text` with the user's
    /// vocabulary available as spelling/casing context. Used exclusively by the streaming
    /// finalize path — the non-streaming path constructs its own richer context-aware call
    /// with clipboard, app snapshot, mentions, and routing signals.
    ///
    /// Returns nil when no assignment resolves, the text is empty, or the call fails.
    private func runBasicPostStopEnhance(
        text: String,
        vocabularyWords: [String]
    ) async -> StreamingSessionController.PostStopEnhanceOutcome? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard let assignment = settingsStore.resolveAssignment(for: .transcriptionEnhancement)
        else { return nil }

        let basePrompt = resolvedPrompt(
            for: assignment,
            fallback: SettingsStore.Defaults.aiEnhancementPrompt
        )

        let context = PindropAI.AIEnhancementService.ContextMetadata(
            hasClipboardText: false,
            hasClipboardImage: false,
            appContext: nil,
            vocabularyWords: vocabularyWords
        )

        do {
            // Route through the context-aware overload so streaming finalization gets
            // the same vocabulary spelling/casing guidance and output contract as batch
            // dictation, without injecting clipboard or UI snapshots.
            let result = try await aiEnhancementService.enhanceWithMetrics(
                text: text,
                apiEndpoint: assignment.endpoint ?? "",
                apiKey: assignment.apiKey,
                model: assignment.modelID,
                customPrompt: basePrompt,
                imageBase64: nil,
                context: context,
                provider: assignment.kind
            )
            let sanitized = PindropAI.AIEnhancementService.stripResponsePreamble(result.text)
            return StreamingSessionController.PostStopEnhanceOutcome(
                enhancedText: sanitized,
                modelID: assignment.modelID,
                providerKind: assignment.kind.rawValue,
                usage: result.usage,
                requestSeconds: result.requestSeconds
            )
        } catch {
            if Self.isTaskCancellation(error) {
                Log.aiEnhancement.info("Streaming post-stop enhance cancelled")
                return nil
            }
            Log.aiEnhancement.warning(
                "Streaming post-stop enhance failed provider=\(assignment.kind.rawValue)")
            toastService.show(
                ToastPayload(
                    message: localized(
                        "AI enhancement failed. Streamed text kept as-is.",
                        locale: settingsStore.selectedAppLocale.locale
                    ),
                    style: .error
                )
            )
            return nil
        }
    }

    private func stopRecordingAndFinalizeStreaming(
        token: DictationOperationToken,
        session: StreamingSessionController.SessionToken
    ) async throws {
        guard let startTime = recordingStartTime else {
            Log.app.warning("stopRecordingAndFinalizeStreaming called but recordingStartTime is nil")
            return
        }

        isRecording = false
        mediaPauseService.endRecordingSession()
        suspendLiveContextSessionUpdates()
        isProcessing = true
        let didResetProcessingState = false

        statusBarController.setProcessingState()

        transitionRecordingIndicatorToProcessing()

        defer {
            if Self.shouldResetProcessingStateOnExit(
                didResetProcessingState: didResetProcessingState,
                isOperationCurrent: operationController.isCurrent(token)
            ) {
                resetProcessingState()
            }
        }

        // Keep the recorded audio: the finalize path re-transcribes it offline so the
        // pasted text gets full-context (pause-aware) punctuation.
        let pipelineClock = ContinuousClock()
        let pipelineStart = pipelineClock.now
        let recordedAudioData: Data
        let audioStopSeconds: Double
        do {
            let audioStopStart = pipelineClock.now
            recordedAudioData = try await audioRecorder.stopRecording()
            audioStopSeconds = audioStopStart.duration(to: pipelineClock.now).pipelineSeconds
            try ensureOperationCurrent(token)
        } catch {
            if Self.shouldCancelStreamingAfterStopFailure(
                isOperationCurrent: operationController.isCurrent(token)
            ) {
                await streamingSession.cancel(session: session)
                if activeStreamingSessionToken == session {
                    activeStreamingSessionToken = nil
                }
            }
            if Self.isTaskCancellation(error) { throw CancellationError() }
            Log.app.error("Failed to stop recording for streaming session: \(error)")
            throw error
        }

        var outcome = try await streamingSession.finalize(
            recordedAudioData: recordedAudioData,
            recordingDuration: Date().timeIntervalSince(startTime),
            session: session
        )
        if activeStreamingSessionToken == session {
            activeStreamingSessionToken = nil
        }
        outcome.pipelineMetrics.audioStopSeconds = audioStopSeconds
        outcome.pipelineMetrics.totalSeconds = pipelineStart.duration(to: pipelineClock.now).pipelineSeconds
        Log.app.info("Pipeline timing: \(outcome.pipelineMetrics.logSummary)")
        // Once the final paste landed, the session is committed: a cancel arriving
        // after that point must not drop the transcription from history. Only the
        // not-yet-output path may abort here.
        if !outcome.outputSucceeded {
            try ensureOperationCurrent(token)
        }
        lastAppliedReplacements = outcome.appliedReplacements

        guard !outcome.isEffectivelyEmpty else {
            handleNoSpeechDetected(context: "streaming recording")
            return
        }

        guard Self.shouldPersistHistory(outputSucceeded: outcome.outputSucceeded, text: outcome.finalText) else {
            return
        }

        let duration = Date().timeIntervalSince(startTime)
        let speakerTrainingSegments = await speakerTrainingSegments(
            audioData: recordedAudioData,
            existingSegments: nil
        )
        do {
            let record = try historyStore.save(
                text: outcome.finalText,
                originalText: outcome.originalStreamedText,
                duration: duration,
                modelUsed: settingsStore.selectedModel,
                enhancedWith: outcome.enhancedWithModel,
                diarizationSegmentsJSON: nil,
                destinationAppName: outcome.destinationAppName,
                destinationAppBundleID: outcome.destinationAppBundleID,
                speakerTrainingSegments: speakerTrainingSegments,
                pipelineMetricsJSON: outcome.pipelineMetrics.hasAnyStage
                    ? outcome.pipelineMetrics.jsonString()
                    : nil
            )
            if let nativeAudio = audioRecorder.takeLastNativeAudio(),
               let nativePCMURL = nativeAudio.takeFileURL() {
                dictationAudioRetentionService.schedulePersist(
                    pcmFloatFileURL: nativePCMURL,
                    sampleRate: nativeAudio.sampleRate,
                    recordID: record.id
                )
            } else {
                dictationAudioRetentionService.schedulePersist(
                    pcmFloatData: recordedAudioData,
                    recordID: record.id
                )
            }
            updateRecentTranscriptsMenu()
            if outcome.didPaste {
                showInsertionSuccessToast(
                    appName: outcome.destinationAppName,
                    wordCount: outcome.finalText.wordCount
                )
            }
        } catch {
            Log.app.error("Failed to save streamed transcription to history: \(error)")
        }
    }
    
    private func stopRecordingAndTranscribe(token: DictationOperationToken) async throws {
        guard let startTime = recordingStartTime else {
            Log.app.warning("stopRecordingAndTranscribe called but recordingStartTime is nil")
            return
        }

        if let session = activeStreamingSessionToken {
            try await stopRecordingAndFinalizeStreaming(token: token, session: session)
            return
        }

        let pipelineClock = ContinuousClock()
        let pipelineStart = pipelineClock.now
        var pipelineMetrics = PipelineMetrics(kind: .batch)

        isRecording = false
        mediaPauseService.endRecordingSession()
        suspendLiveContextSessionUpdates()
        isProcessing = true
        var didResetProcessingState = false

        statusBarController.setProcessingState()
        
        transitionRecordingIndicatorToProcessing()
        
        defer {
            if Self.shouldResetProcessingStateOnExit(
                didResetProcessingState: didResetProcessingState,
                isOperationCurrent: operationController.isCurrent(token)
            ) {
                resetProcessingState()
            }
        }

        let audioData: Data
        do {
            let audioStopStart = pipelineClock.now
            audioData = try await audioRecorder.stopRecording()
            pipelineMetrics.audioStopSeconds = audioStopStart.duration(to: pipelineClock.now).pipelineSeconds
            try ensureOperationCurrent(token)
        } catch {
            if Self.isTaskCancellation(error) { throw CancellationError() }
            Log.app.error("Failed to stop recording: \(error)")
            throw error
        }

        guard !audioData.isEmpty else {
            Log.app.warning("No audio data recorded")
            handleNoSpeechDetected(context: "recording")
            return
        }
        
        let duration = Date().timeIntervalSince(startTime)
        
        let diarizationEnabled = Self.dictationUsesSpeakerDiarization

        let transcriptionOutput: TranscriptionOutput
        do {
            let transcriptionStart = pipelineClock.now
            transcriptionOutput = try await transcriptionService.transcribe(
                audioData: audioData,
                diarizationEnabled: diarizationEnabled,
                options: makeTranscriptionOptions(route: .dictation),
                diarizationOptions: .init(),
                diarizationFailurePolicy: .bestEffort
            )
            pipelineMetrics.transcriptionSeconds = transcriptionStart.duration(to: pipelineClock.now).pipelineSeconds
            try ensureOperationCurrent(token)
        } catch let error as PindropSpeech.TranscriptionService.TranscriptionError {
            guard operationController.isCurrent(token), !Self.isTaskCancellation(error) else {
                throw CancellationError()
            }
            Log.app.error("Transcription failed: \(error)")
            reportTranscriptionFailureSignal(error, stage: "transcribe")
            resetProcessingState()
            didResetProcessingState = true
            let locale = settingsStore.selectedAppLocale.locale
            let message = if case .modelNotLoaded = error {
                localized("No model loaded. Please download a model in Settings.", locale: locale)
            } else {
                String(format: localized("Transcription failed: %@", locale: locale), locale: locale, error.localizedDescription)
            }
            toastService.show(
                ToastPayload(message: message, style: .error)
            )
            throw error
        } catch {
            guard operationController.isCurrent(token), !Self.isTaskCancellation(error) else {
                throw CancellationError()
            }
            Log.app.error("Transcription failed: \(error)")
            reportTranscriptionFailureSignal(error, stage: "transcribe")
            resetProcessingState()
            didResetProcessingState = true
            let locale = settingsStore.selectedAppLocale.locale
            toastService.show(
                ToastPayload(
                    message: String(format: localized("Transcription failed: %@", locale: locale), locale: locale, error.localizedDescription),
                    style: .error
                )
            )
            throw error
        }

        if diarizationEnabled {
            let segmentCount = transcriptionOutput.diarizedSegments?.count ?? 0
            if segmentCount > 0 {
                Log.app.info("Batch diarization produced \(segmentCount) segments")
            } else {
                Log.app.info("Batch diarization produced no attributed segments")
            }
        }

        let diarizationSegmentsJSON = encodeDiarizationSegmentsJSON(transcriptionOutput.diarizedSegments)
        let transcribedText = transcriptionOutput.text

        let textProcessingStart = pipelineClock.now
        var (textAfterReplacements, appliedReplacements) = try dictionaryStore.applyReplacements(to: transcribedText)
        textAfterReplacements = normalizedTranscriptionText(textAfterReplacements)

        guard !isTranscriptionEffectivelyEmpty(textAfterReplacements) else {
            handleNoSpeechDetected(context: "recording")
            return
        }
        self.lastAppliedReplacements = appliedReplacements
        try? dictionaryStore.recordVocabularyHits(in: textAfterReplacements)
        
        if !appliedReplacements.isEmpty {
            Log.app.info("Applied \(appliedReplacements.count) dictionary replacements")
        }
        
        // Mention rewrite: resolve spoken file mentions to app-specific syntax
        // Runs whenever adapter supports file mentions AND workspace roots are derivable
        // (not gated by isCodeEditorContext — enables Antigravity and other non-IDE adapters)
        var textAfterMentions = textAfterReplacements
        var mentionFormattingCapabilities = capturedAdapterCapabilities
        let derivedWorkspaceRoots = deriveWorkspaceRoots(
            routingSignal: capturedRoutingSignal,
            snapshot: capturedSnapshot
        )
        let shouldUsePlaceholderMentions =
            settingsStore.resolveAssignment(for: .transcriptionEnhancement) != nil
        if let capabilities = capturedAdapterCapabilities,
           capabilities.supportsFileMentions {
            let resolvedMentionFormatting = settingsStore.resolveMentionFormatting(
                editorBundleIdentifier: capturedRoutingSignal?.appBundleIdentifier,
                terminalProviderIdentifier: capturedRoutingSignal?.terminalProviderIdentifier,
                adapterDefaultTemplate: capabilities.mentionTemplate,
                adapterDefaultPrefix: capabilities.mentionPrefix
            )
            let effectiveCapabilities = capabilities.withMentionFormatting(
                prefix: resolvedMentionFormatting.mentionPrefix,
                template: resolvedMentionFormatting.mentionTemplate
            )
            mentionFormattingCapabilities = effectiveCapabilities
            if !derivedWorkspaceRoots.isEmpty {
                let rewriteResult: MentionRewriteResult
                if shouldUsePlaceholderMentions {
                    rewriteResult = await mentionRewriteService.rewriteToCanonicalPlaceholders(
                        text: textAfterReplacements,
                        capabilities: effectiveCapabilities,
                        workspaceRoots: derivedWorkspaceRoots,
                        activeDocumentPath: capturedSnapshot?.appContext?.documentPath
                    )
                } else {
                    rewriteResult = await mentionRewriteService.rewrite(
                        text: textAfterReplacements,
                        capabilities: effectiveCapabilities,
                        workspaceRoots: derivedWorkspaceRoots,
                        activeDocumentPath: capturedSnapshot?.appContext?.documentPath
                    )
                }
                textAfterMentions = rewriteResult.text
                if rewriteResult.didRewrite {
                    Log.app.info("Mention rewrite: \(rewriteResult.rewrittenCount) mention(s) rewritten, \(rewriteResult.preservedCount) preserved")
                }
            } else {
                let adapterName = capturedAdapterCapabilities?.displayName ?? "unknown"
                let hasDocPath = capturedSnapshot?.appContext?.documentPath != nil
                let debugSummary = mentionRewriteWorkspaceDebugSummary(
                    adapterName: adapterName,
                    routingSignal: capturedRoutingSignal,
                    snapshot: capturedSnapshot,
                    derivedWorkspaceRoots: derivedWorkspaceRoots
                )
                Log.app.warning("Adapter '\(adapterName)' supports file mentions but no workspace roots derived (documentPath available: \(hasDocPath)); skipping mention rewrite. \(debugSummary)")
            }
        }
        
        pipelineMetrics.textProcessingSeconds = textProcessingStart.duration(to: pipelineClock.now).pipelineSeconds

        var finalText = normalizedTranscriptionText(textAfterMentions)
        var originalText: String? = nil
        var enhancedWithModel: String? = nil

        if let transcriptionAssignment = settingsStore.resolveAssignment(
            for: .transcriptionEnhancement)
        {
            let enhancementStart = pipelineClock.now
            do {
                originalText = textAfterMentions
                Log.app.info("AI enhancement enabled, saving original text before enhancement")

                var basePrompt = resolvedPrompt(
                    for: transcriptionAssignment,
                    fallback: SettingsStore.Defaults.aiEnhancementPrompt
                )

                let vocabularyWords = try dictionaryStore.fetchAllVocabularyWords().map(\.word)
                let replacementCorrections = lastAppliedReplacements.map {
                    PindropAI.AIEnhancementService.ContextMetadata.ReplacementCorrection(
                        original: $0.original,
                        replacement: $0.replacement
                    )
                }

                if mentionFormattingCapabilities?.supportsFileMentions == true {
                    basePrompt += "\n\nIf the input contains file placeholders formatted as [[:relative/path.ext:]], preserve each placeholder token exactly. Do not change brackets, colons, slashes, file names, or extensions inside those tokens."
                }
                
                var contextMetadata = PindropAI.AIEnhancementService.ContextMetadata.none
                var clipboardText: String? = nil

                var workspaceTreeSummary: String? = nil
                if !derivedWorkspaceRoots.isEmpty {
                    workspaceTreeSummary = await mentionRewriteService.generateWorkspaceTreeSummary(
                        workspaceRoots: derivedWorkspaceRoots,
                        activeDocumentPath: capturedSnapshot?.appContext?.documentPath
                    )
                }

                let liveSessionContext = currentLiveSessionContext()
                
                if let context = capturedContext {
                    let hasClipboardText = context.clipboardText != nil && !context.clipboardText!.isEmpty
                    clipboardText = hasClipboardText ? context.clipboardText : nil
                    
                    contextMetadata = PindropAI.AIEnhancementService.ContextMetadata(
                        hasClipboardText: hasClipboardText,
                        clipboardText: clipboardText,
                        hasClipboardImage: false,
                        appContext: capturedSnapshot?.appContext,
                        adapterCapabilities: mentionFormattingCapabilities,
                        routingSignal: capturedRoutingSignal,
                        workspaceFileTree: workspaceTreeSummary,
                        liveSessionContext: liveSessionContext,
                        vocabularyWords: vocabularyWords,
                        replacementCorrections: replacementCorrections
                    )
                } else if let appContext = capturedSnapshot?.appContext {
                    contextMetadata = PindropAI.AIEnhancementService.ContextMetadata(
                        hasClipboardText: false,
                        clipboardText: nil,
                        hasClipboardImage: false,
                        appContext: appContext,
                        adapterCapabilities: mentionFormattingCapabilities,
                        routingSignal: capturedRoutingSignal,
                        workspaceFileTree: workspaceTreeSummary,
                        liveSessionContext: liveSessionContext,
                        vocabularyWords: vocabularyWords,
                        replacementCorrections: replacementCorrections
                    )
                } else if let liveSessionContext {
                    contextMetadata = PindropAI.AIEnhancementService.ContextMetadata(
                        hasClipboardText: false,
                        clipboardText: nil,
                        hasClipboardImage: false,
                        appContext: nil,
                        adapterCapabilities: mentionFormattingCapabilities,
                        routingSignal: capturedRoutingSignal,
                        workspaceFileTree: workspaceTreeSummary,
                        liveSessionContext: liveSessionContext,
                        vocabularyWords: vocabularyWords,
                        replacementCorrections: replacementCorrections
                    )
                } else if !vocabularyWords.isEmpty || !replacementCorrections.isEmpty {
                    contextMetadata = PindropAI.AIEnhancementService.ContextMetadata(
                        hasClipboardText: false,
                        clipboardText: nil,
                        hasClipboardImage: false,
                        appContext: nil,
                        adapterCapabilities: mentionFormattingCapabilities,
                        routingSignal: capturedRoutingSignal,
                        workspaceFileTree: workspaceTreeSummary,
                        liveSessionContext: nil,
                        vocabularyWords: vocabularyWords,
                        replacementCorrections: replacementCorrections
                    )
                }

                let enhancementResult = try await aiEnhancementService.enhanceWithMetrics(
                    text: textAfterMentions,
                    apiEndpoint: transcriptionAssignment.endpoint ?? "",
                    apiKey: transcriptionAssignment.apiKey,
                    model: transcriptionAssignment.modelID,
                    customPrompt: basePrompt,
                    imageBase64: nil,
                    context: contextMetadata,
                    provider: transcriptionAssignment.kind
                )
                finalText = enhancementResult.text
                pipelineMetrics.enhancementRequestSeconds = enhancementResult.requestSeconds
                pipelineMetrics.enhancementProvider = transcriptionAssignment.kind.rawValue
                pipelineMetrics.enhancementModel = transcriptionAssignment.modelID
                if let usage = enhancementResult.usage {
                    pipelineMetrics.enhancementPromptTokens = usage.promptTokens
                    pipelineMetrics.enhancementCompletionTokens = usage.completionTokens
                    pipelineMetrics.enhancementReasoningTokens = usage.reasoningTokens
                    pipelineMetrics.enhancementTotalTokens = usage.totalTokens
                }
                try ensureOperationCurrent(token)
                if let capabilities = mentionFormattingCapabilities,
                   capabilities.supportsFileMentions,
                   !derivedWorkspaceRoots.isEmpty {
                    let renderedPlaceholders = mentionRewriteService.renderCanonicalPlaceholders(
                        in: finalText,
                        capabilities: capabilities
                    )
                    finalText = renderedPlaceholders.text

                    if renderedPlaceholders.didRewrite {
                        Log.app.info("Post-enhancement placeholder render: \(renderedPlaceholders.rewrittenCount) placeholder(s) rendered, \(renderedPlaceholders.preservedCount) preserved")
                    } else {
                        let postEnhancementRewriteResult = await mentionRewriteService.rewrite(
                            text: finalText,
                            capabilities: capabilities,
                            workspaceRoots: derivedWorkspaceRoots,
                            activeDocumentPath: capturedSnapshot?.appContext?.documentPath
                        )
                        finalText = postEnhancementRewriteResult.text
                        if postEnhancementRewriteResult.didRewrite {
                            Log.app.info("Post-enhancement mention rewrite: \(postEnhancementRewriteResult.rewrittenCount) mention(s) rewritten, \(postEnhancementRewriteResult.preservedCount) preserved")
                        }
                    }
                }
                capturedContext = nil
                capturedSnapshot = nil
                capturedAdapterCapabilities = nil
                capturedRoutingSignal = nil
                stopLiveContextSession()
                enhancedWithModel = transcriptionAssignment.modelID
                pipelineMetrics.enhancementSeconds = enhancementStart.duration(to: pipelineClock.now).pipelineSeconds
                Log.app.info("AI enhancement completed, original: \(textAfterMentions.count) chars, enhanced: \(finalText.count) chars")
            } catch {
                // Cancelled/stale generation must not toast; abort the operation entirely.
                if Self.isTaskCancellation(error) || !operationController.isCurrent(token) {
                    throw CancellationError()
                }
                Log.app.error("AI enhancement failed: \(error)")
                telemetryService.send(
                    .enhancementFailed,
                    parameters: [
                        TelemetryParameter.providerKind: transcriptionAssignment.kind.rawValue,
                        TelemetryParameter.errorCase: TelemetryService.errorCaseName(error)
                    ]
                )
                toastService.show(
                    ToastPayload(
                        message: localized(
                            "AI enhancement failed. Transcription inserted without enhancement.",
                            locale: settingsStore.selectedAppLocale.locale
                        ),
                        style: .error
                    )
                )
                // Keep originalText so the unenhanced transcription is saved to history
            }
        } else {
            Log.app.debug("AI enhancement skipped: no transcriptionEnhancement assignment resolves")
        }
        finalText = ProgrammaticTranscriptFormatter.formatIfEnabled(
            finalText,
            enabled: settingsStore.programmaticFormattingEnabled
        )

        try ensureOperationCurrent(token)
        finalText = normalizedTranscriptionText(finalText)
        guard !isTranscriptionEffectivelyEmpty(finalText) else {
            handleNoSpeechDetected(context: "recording")
            return
        }

        let directInsertSnapshot = outputManager.outputMode == .directInsert
            && settingsStore.automaticDictionaryLearningEnabled
            ? contextEngineService.captureFocusedTextSnapshot()
            : nil
        var outputSucceeded = false
        var outputResult: OutputManager.OutputResult?
        do {
            if outputManager.outputMode == .directInsert {
                ensureAccessibilityPermissionForDirectInsert(trigger: "output", showFallbackAlert: true)
            }
            let outputText = settingsStore.addTrailingSpace ? finalText + " " : finalText
            let outputStart = pipelineClock.now
            outputResult = try await outputManager.output(outputText)
            pipelineMetrics.outputSeconds = outputStart.duration(to: pipelineClock.now).pipelineSeconds
            outputSucceeded = true
            if outputManager.outputMode == .directInsert,
               settingsStore.automaticDictionaryLearningEnabled {
                automaticDictionaryLearningService.beginObservation(
                    preInsertSnapshot: directInsertSnapshot,
                    insertedText: outputText
                )
            } else if outputManager.outputMode == .directInsert {
                Log.app.info("Automatic dictionary learning disabled in settings; skipping observation")
            }
        } catch {
            if Self.isTaskCancellation(error) { throw CancellationError() }
            Log.app.error("Output failed: \(error)")
        }

        pipelineMetrics.totalSeconds = pipelineStart.duration(to: pipelineClock.now).pipelineSeconds
        Log.app.info("Pipeline timing: \(pipelineMetrics.logSummary)")

        // Once the output landed in the target app the operation is committed: a
        // cancel arriving after that point must not drop the transcription from
        // history. Only the not-yet-output path may abort here.
        if !outputSucceeded {
            try ensureOperationCurrent(token)
        }
        guard Self.shouldPersistHistory(outputSucceeded: outputSucceeded, text: finalText) else { return }

        let speakerTrainingSegments = await speakerTrainingSegments(
            audioData: audioData,
            existingSegments: transcriptionOutput.diarizedSegments
        )
        do {
            let record = try historyStore.save(
                text: finalText,
                originalText: originalText,
                duration: duration,
                modelUsed: settingsStore.selectedModel,
                enhancedWith: enhancedWithModel,
                diarizationSegmentsJSON: diarizationSegmentsJSON,
                destinationAppName: outputResult?.destinationAppName,
                destinationAppBundleID: outputResult?.destinationAppBundleID,
                speakerTrainingSegments: speakerTrainingSegments,
                pipelineMetricsJSON: pipelineMetrics.hasAnyStage ? pipelineMetrics.jsonString() : nil
            )
            var successParameters: [String: String] = [
                TelemetryParameter.backend: settingsStore.resolvedTranscriptionBackend.rawValue,
                TelemetryParameter.model: settingsStore.selectedModel,
                TelemetryParameter.durationBucket: TelemetryService.durationBucket(duration),
                TelemetryParameter.wordCountBucket: TelemetryService.wordCountBucket(finalText.wordCount),
                TelemetryParameter.enhanced: String(enhancedWithModel != nil),
                TelemetryParameter.diarized: String(diarizationSegmentsJSON != nil)
            ]
            if let seconds = pipelineMetrics.transcriptionSeconds {
                successParameters[TelemetryParameter.transcribeLatencyBucket] = TelemetryService.latencyBucket(seconds)
            }
            if let seconds = pipelineMetrics.enhancementSeconds {
                successParameters[TelemetryParameter.enhanceLatencyBucket] = TelemetryService.latencyBucket(seconds)
            }
            if let seconds = pipelineMetrics.totalSeconds {
                successParameters[TelemetryParameter.totalLatencyBucket] = TelemetryService.latencyBucket(seconds)
            }
            telemetryService.send(
                .transcriptionSucceeded,
                parameters: successParameters,
                sampleRate: TelemetryService.successSampleRate
            )
            if let nativeAudio = audioRecorder.takeLastNativeAudio(),
               let nativePCMURL = nativeAudio.takeFileURL() {
                dictationAudioRetentionService.schedulePersist(
                    pcmFloatFileURL: nativePCMURL,
                    sampleRate: nativeAudio.sampleRate,
                    recordID: record.id
                )
            } else {
                dictationAudioRetentionService.schedulePersist(
                    pcmFloatData: audioData,
                    recordID: record.id
                )
            }
            updateRecentTranscriptsMenu()
            if let outputResult {
                showOutputResultToast(outputResult, wordCount: finalText.wordCount)
            }
        } catch {
            Log.app.error("Failed to save to history: \(error)")
        }
    }

    /// Post-output feedback for the batch path. A landed paste gets the insertion
    /// toast; the intentional no-Accessibility copy fallback gets "Copied" with Undo
    /// (previously it was silent, making dictation look like a no-op); a real paste
    /// failure that fell back to the clipboard gets an error toast.
    private func showOutputResultToast(_ result: OutputManager.OutputResult, wordCount: Int) {
        let locale = settingsStore.selectedAppLocale.locale
        if result.didPaste {
            showInsertionSuccessToast(
                appName: result.destinationAppName,
                wordCount: wordCount
            )
            return
        }

        switch result.clipboardFallbackReason {
        case .copyOnlyMode, .accessibilityUnavailable:
            var actions: [ToastAction] = []
            if let snapshot = result.previousClipboardSnapshot {
                actions.append(
                    ToastAction(title: localized("Undo", locale: locale), role: .primary) { [weak self] in
                        let restored = self?.outputManager.restoreClipboardSnapshot(snapshot) ?? false
                        if restored {
                            Log.output.info("Restored clipboard after copy undo")
                        } else {
                            Log.output.error("Failed to restore clipboard after copy undo")
                        }
                    }
                )
            }
            toastService.show(
                ToastPayload(
                    message: localized("Copied to clipboard", locale: locale),
                    actions: actions,
                    variant: .copied
                )
            )
        case .pasteFailed, nil:
            toastService.show(
                ToastPayload(
                    message: localized("Paste failed. Transcript copied to clipboard.", locale: locale),
                    style: .error
                )
            )
        }
    }

    // MARK: - Escape Key Cancellation
    
    private func setupEscapeKeyMonitor() {
        if escapeEventTap != nil, escapeRunLoopSource != nil {
            installEscapeGlobalMonitorFallbackIfNeeded()
            return
        }

        if escapeEventTap != nil, escapeRunLoopSource == nil {
            Log.app.warning("Escape event tap missing run loop source; recreating monitor")
            teardownEscapeKeyMonitor()
        }

        let eventMask = (1 << CGEventType.keyDown.rawValue)
        
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        
        guard let eventTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(eventMask),
            callback: { (proxy, type, event, refcon) -> Unmanaged<CGEvent>? in
                guard let refcon = refcon else { return Unmanaged.passUnretained(event) }
                
                let coordinator = Unmanaged<AppCoordinator>.fromOpaque(refcon).takeUnretainedValue()
                return coordinator.handleKeyEvent(proxy: proxy, type: type, event: event)
            },
            userInfo: refcon
        ) else {
            Log.app.error("Failed to create CGEventTap - Accessibility or Input Monitoring permission may be required")
            resetEventTapRecoveryState(for: .escape)
            installEscapeGlobalMonitorFallbackIfNeeded()
            return
        }

        installEscapeGlobalMonitorFallbackIfNeeded()
        
        escapeEventTap = eventTap

        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, eventTap, 0) else {
            Log.app.error("Failed to create run loop source for escape CGEventTap")
            escapeEventTap = nil
            resetEventTapRecoveryState(for: .escape)
            return
        }

        escapeRunLoopSource = source
        eventTapRunLoopThread.performAndWait { runLoop in
            CFRunLoopAddSource(runLoop, source, .commonModes)
            CGEvent.tapEnable(tap: eventTap, enable: true)
        }
        resetEventTapRecoveryState(for: .escape)
        Log.app.info("Escape key monitor installed")
    }

    private func setupModifierKeyMonitor() {
        if modifierEventTap != nil, modifierRunLoopSource != nil {
            removeModifierGlobalMonitorFallbackIfNeeded()
            return
        }

        if modifierEventTap != nil, modifierRunLoopSource == nil {
            Log.hotkey.warning("Modifier event tap missing run loop source; recreating monitor")
            teardownModifierKeyMonitor()
        }

        let eventMask = (1 << CGEventType.flagsChanged.rawValue)

        let refcon = Unmanaged.passUnretained(self).toOpaque()

        guard let eventTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(eventMask),
            callback: { (proxy, type, event, refcon) -> Unmanaged<CGEvent>? in
                guard let refcon = refcon else { return Unmanaged.passUnretained(event) }

                let coordinator = Unmanaged<AppCoordinator>.fromOpaque(refcon).takeUnretainedValue()
                return coordinator.handleModifierKeyEvent(proxy: proxy, type: type, event: event)
            },
            userInfo: refcon
        ) else {
            Log.hotkey.error("Failed to create modifier CGEventTap - Accessibility or Input Monitoring permission may be required")
            resetEventTapRecoveryState(for: .modifier)
            installModifierGlobalMonitorFallbackIfNeeded()
            return
        }

        removeModifierGlobalMonitorFallbackIfNeeded()

        modifierEventTap = eventTap

        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, eventTap, 0) else {
            Log.hotkey.error("Failed to create run loop source for modifier CGEventTap")
            modifierEventTap = nil
            resetEventTapRecoveryState(for: .modifier)
            return
        }

        modifierRunLoopSource = source
        eventTapRunLoopThread.performAndWait { runLoop in
            CFRunLoopAddSource(runLoop, source, .commonModes)
            CGEvent.tapEnable(tap: eventTap, enable: true)
        }
        resetEventTapRecoveryState(for: .modifier)
        Log.hotkey.info("Modifier key monitor installed")
    }

    private func teardownEscapeKeyMonitor() {
        escapeEventTapRecoveryTask?.cancel()
        escapeEventTapRecoveryTask = nil

        if let source = escapeRunLoopSource {
            let eventTap = escapeEventTap
            eventTapRunLoopThread.performAndWait { runLoop in
                if let eventTap {
                    CGEvent.tapEnable(tap: eventTap, enable: false)
                }
                CFRunLoopRemoveSource(runLoop, source, .commonModes)
            }
        } else if let eventTap = escapeEventTap {
            eventTapRunLoopThread.performAndWait { _ in
                CGEvent.tapEnable(tap: eventTap, enable: false)
            }
        }

        escapeEventTap = nil
        escapeRunLoopSource = nil
        resetEventTapRecoveryState(for: .escape)
    }

    private func teardownModifierKeyMonitor() {
        modifierEventTapRecoveryTask?.cancel()
        modifierEventTapRecoveryTask = nil

        if let source = modifierRunLoopSource {
            let eventTap = modifierEventTap
            eventTapRunLoopThread.performAndWait { runLoop in
                if let eventTap {
                    CGEvent.tapEnable(tap: eventTap, enable: false)
                }
                CFRunLoopRemoveSource(runLoop, source, .commonModes)
            }
        } else if let eventTap = modifierEventTap {
            eventTapRunLoopThread.performAndWait { _ in
                CGEvent.tapEnable(tap: eventTap, enable: false)
            }
        }

        modifierEventTap = nil
        modifierRunLoopSource = nil
        resetEventTapRecoveryState(for: .modifier)
    }

    private func scheduleEventTapRecovery(for kind: EventTapKind, disabledType: CGEventType) {
        let now = Date()

        switch kind {
        case .escape:
            let decision = Self.determineEventTapRecovery(
                now: now,
                lastDisableAt: escapeEventTapDisableState.lastDisableAt,
                consecutiveDisableCount: escapeEventTapDisableState.consecutiveDisableCount,
                disableLoopWindow: eventTapDisableLoopWindow,
                maxReenableAttemptsBeforeRecreate: maxEventTapReenableAttemptsBeforeRecreate
            )
            escapeEventTapDisableState.lastDisableAt = now
            escapeEventTapDisableState.consecutiveDisableCount = decision.consecutiveDisableCount
            escapeEventTapDisableState.lastDisabledTypeRawValue = disabledType.rawValue

            guard escapeEventTapRecoveryTask == nil else { return }
            let recoveryDelay = eventTapRecoveryDelay
            escapeEventTapRecoveryTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: recoveryDelay)
                guard let self, !Task.isCancelled else { return }
                self.escapeEventTapRecoveryTask = nil
                self.performEventTapRecovery(for: .escape)
            }
        case .modifier:
            let decision = Self.determineEventTapRecovery(
                now: now,
                lastDisableAt: modifierEventTapDisableState.lastDisableAt,
                consecutiveDisableCount: modifierEventTapDisableState.consecutiveDisableCount,
                disableLoopWindow: eventTapDisableLoopWindow,
                maxReenableAttemptsBeforeRecreate: maxEventTapReenableAttemptsBeforeRecreate
            )
            modifierEventTapDisableState.lastDisableAt = now
            modifierEventTapDisableState.consecutiveDisableCount = decision.consecutiveDisableCount
            modifierEventTapDisableState.lastDisabledTypeRawValue = disabledType.rawValue

            guard modifierEventTapRecoveryTask == nil else { return }
            let recoveryDelay = eventTapRecoveryDelay
            modifierEventTapRecoveryTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: recoveryDelay)
                guard let self, !Task.isCancelled else { return }
                self.modifierEventTapRecoveryTask = nil
                self.performEventTapRecovery(for: .modifier)
            }
        }
    }

    private func performEventTapRecovery(for kind: EventTapKind) {
        switch kind {
        case .escape:
            let state = escapeEventTapDisableState
            resetEventTapRecoveryState(for: .escape)

            guard state.consecutiveDisableCount > 0 else { return }

            if state.consecutiveDisableCount >= maxEventTapReenableAttemptsBeforeRecreate {
                Log.app.error(
                    "Escape key monitor kept disabling (count=\(state.consecutiveDisableCount), lastType=\(state.lastDisabledTypeRawValue ?? 0)); recreating monitor"
                )
                teardownEscapeKeyMonitor()
                setupEscapeKeyMonitor()
                return
            }

            guard let tap = escapeEventTap else { return }

            eventTapRunLoopThread.performAndWait { _ in
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            Log.app.warning("Escape key monitor was disabled (type=\(state.lastDisabledTypeRawValue ?? 0)); re-enabled after backoff")
        case .modifier:
            let state = modifierEventTapDisableState
            resetEventTapRecoveryState(for: .modifier)

            guard state.consecutiveDisableCount > 0 else { return }

            if state.consecutiveDisableCount >= maxEventTapReenableAttemptsBeforeRecreate {
                Log.hotkey.error(
                    "Modifier key monitor kept disabling (count=\(state.consecutiveDisableCount), lastType=\(state.lastDisabledTypeRawValue ?? 0)); recreating monitor"
                )
                teardownModifierKeyMonitor()
                setupModifierKeyMonitor()
                return
            }

            guard let tap = modifierEventTap else { return }

            eventTapRunLoopThread.performAndWait { _ in
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            Log.hotkey.warning("Modifier key monitor was disabled (type=\(state.lastDisabledTypeRawValue ?? 0)); re-enabled after backoff")
        }
    }

    private func resetEventTapRecoveryState(for kind: EventTapKind) {
        switch kind {
        case .escape:
            escapeEventTapDisableState = EventTapDisableState()
        case .modifier:
            modifierEventTapDisableState = EventTapDisableState()
        }
    }

    private func installEscapeGlobalMonitorFallbackIfNeeded() {
        guard escapeGlobalMonitor == nil else { return }

        escapeGlobalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            guard event.keyCode == 53 else { return }
            Task { @MainActor [weak self] in
                guard let self, !self.isShutdown else { return }
                self.handleEscapeSignal(source: "nsevent-global")
            }
        }

        if escapeGlobalMonitor != nil {
            Log.app.warning("Using NSEvent global monitor fallback for escape key (observation only; suppression unavailable)")
        }
    }

    private func removeEscapeGlobalMonitorFallbackIfNeeded() {
        guard let monitor = escapeGlobalMonitor else { return }
        NSEvent.removeMonitor(monitor)
        escapeGlobalMonitor = nil
        Log.app.debug("Removed NSEvent global monitor fallback for escape key")
    }

    private func installModifierGlobalMonitorFallbackIfNeeded() {
        guard modifierGlobalMonitor == nil else { return }

        modifierGlobalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.flagsChanged]) { [weak self] event in
            guard let cgEvent = event.cgEvent else { return }
            Task { @MainActor [weak self] in
                guard let self, !self.isShutdown else { return }
                self.hotkeyManager.handleModifierFlagsChanged(event: cgEvent)
            }
        }

        if modifierGlobalMonitor != nil {
            Log.hotkey.warning("Using NSEvent global monitor fallback for modifier changes")
        }
    }

    private func removeModifierGlobalMonitorFallbackIfNeeded() {
        guard let monitor = modifierGlobalMonitor else { return }
        NSEvent.removeMonitor(monitor)
        modifierGlobalMonitor = nil
        Log.hotkey.debug("Removed NSEvent global monitor fallback for modifier changes")
    }
    
    static func shouldSuppressEscapeEvent(
        isRecording: Bool,
        isProcessing: Bool,
        isMediaTranscriptionOnly: Bool = false
    ) -> Bool {
        (isRecording || isProcessing) && !isMediaTranscriptionOnly
    }

    /// Single Escape cancels while a recording/processing session is active.
    /// Same predicate as suppression so the key is only swallowed when we act on it.
    /// Media-only work is excluded from both: cancel intentionally ignores queued
    /// media jobs, so Escape must not be stolen from the focused app while they run.
    static func shouldCancelOperationOnEscape(
        isRecording: Bool,
        isProcessing: Bool,
        isMediaTranscriptionOnly: Bool = false
    ) -> Bool {
        shouldSuppressEscapeEvent(
            isRecording: isRecording,
            isProcessing: isProcessing,
            isMediaTranscriptionOnly: isMediaTranscriptionOnly
        )
    }

    static func isTaskCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        if let urlError = error as? URLError, urlError.code == .cancelled { return true }
        let nsError = error as NSError
        return nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled
    }

    private func ensureOperationCurrent(_ token: DictationOperationToken) throws {
        try Task.checkCancellation()
        guard operationController.isCurrent(token) else {
            throw CancellationError()
        }
    }

    /// Deferred stop/transcribe cleanup must only run for the still-current operation.
    /// After cancel frees admission and a new recording starts, a stale cancelled task
    /// must not wipe the new session's processing/recording state.
    static func shouldResetProcessingStateOnExit(
        didResetProcessingState: Bool,
        isOperationCurrent: Bool
    ) -> Bool {
        !didResetProcessingState && isOperationCurrent
    }

    /// Whether a stop-path catch may toast or mutate shared UI/RecordingState.
    /// Stale generations (cancelled then superseded) and cooperative cancellation
    /// must produce no user-visible side effects.
    static func shouldEmitOperationFailureSideEffects(
        isOperationCurrent: Bool,
        error: Error
    ) -> Bool {
        isOperationCurrent && !isTaskCancellation(error)
    }

    /// A failed generic stop may cancel the shared streaming engine only while its
    /// operation still owns the coordinator; a stale stop must leave its successor alone.
    static func shouldCancelStreamingAfterStopFailure(isOperationCurrent: Bool) -> Bool {
        isOperationCurrent
    }

    private func resetProcessingStateIfCurrent(_ token: DictationOperationToken) {
        guard Self.shouldResetProcessingStateOnExit(
            didResetProcessingState: false,
            isOperationCurrent: operationController.isCurrent(token)
        ) else {
            return
        }
        resetProcessingState()
    }

    private nonisolated func handleKeyEvent(
        proxy: CGEventTapProxy,
        type: CGEventType,
        event: CGEvent
    ) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            Task { @MainActor [weak self] in
                guard let self, !self.isShutdown else { return }
                self.scheduleEventTapRecovery(for: .escape, disabledType: type)
            }
            return Unmanaged.passUnretained(event)
        }

        guard type == .keyDown else { return Unmanaged.passUnretained(event) }

        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        guard keyCode == 53 else {
            guard liveContextKeyRefreshGate.claim(
                now: ProcessInfo.processInfo.systemUptime,
                minimumInterval: 0.75
            ) else {
                return Unmanaged.passUnretained(event)
            }
            Task { @MainActor [weak self] in
                guard let self, !self.isShutdown else { return }
                self.scheduleFocusOrWindowContextRefreshIfNeeded()
            }
            return Unmanaged.passUnretained(event)
        }
        
        let shouldSuppress = escapeEventState.currentShouldSuppress()
        guard shouldSuppress else {
            return Unmanaged.passUnretained(event)
        }

        Task { @MainActor [weak self] in
            guard let self, !self.isShutdown else { return }
            self.handleEscapeSignal(source: "cg-event-tap")
            Log.app.info("Escape intercepted+suppressing (recordingOrProcessing=true)")
        }
        return nil
    }

    private func handleEscapeSignal(source: String) {
        let now = Date()
        if let lastSignal = lastEscapeSignalTime,
           now.timeIntervalSince(lastSignal) <= duplicateEscapeSignalThreshold {
            Log.app.debug("Ignoring duplicate escape signal from \(source)")
            return
        }

        lastEscapeSignalTime = now
        Log.app.info("Escape signal received (source=\(source))")
        handleEscapeKeyPress()
    }

    private nonisolated func handleModifierKeyEvent(
        proxy: CGEventTapProxy,
        type: CGEventType,
        event: CGEvent
    ) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            Task { @MainActor [weak self] in
                guard let self, !self.isShutdown else { return }
                self.scheduleEventTapRecovery(for: .modifier, disabledType: type)
            }
            return Unmanaged.passUnretained(event)
        }

        guard type == .flagsChanged else { return Unmanaged.passUnretained(event) }

        Task { @MainActor [weak self] in
            guard let self, !self.isShutdown else { return }
            self.hotkeyManager.handleModifierFlagsChanged(event: event)
        }
        return Unmanaged.passUnretained(event)
    }
    
    private func handleEscapeKeyPress() {
        // Escape cancels while Pindrop owns an active recording/processing session.
        // Idle Escape is intentionally a no-op so other apps keep the key, and
        // media-only work is skipped so an Escape that cannot cancel anything
        // neither arms the double-press sequence nor pretends to act.
        guard isRecording || isProcessing || activeOperationTask != nil else { return }
        guard !isMediaTranscriptionOnlyWork else { return }

        let now = Date()
        if Self.escapeShouldCancel(
            requiresDoublePress: settingsStore.cancelRequiresDoubleEscape,
            armedAt: escapeCancelArmedAt,
            now: now,
            window: Self.doubleEscapeCancelWindow
        ) {
            escapeCancelArmedAt = nil
            cancelCurrentOperation(source: "escape")
        } else {
            escapeCancelArmedAt = now
            Log.app.info("Escape armed for cancel — press again within \(Self.doubleEscapeCancelWindow)s")
        }
    }

    /// Whether an Escape press should cancel the active session, or merely arm the
    /// double-press sequence. Single-press mode always cancels; double-press mode
    /// cancels only when a prior press armed the sequence within `window`.
    static func escapeShouldCancel(
        requiresDoublePress: Bool,
        armedAt: Date?,
        now: Date,
        window: TimeInterval
    ) -> Bool {
        guard requiresDoublePress else { return true }
        guard let armedAt else { return false }
        return now.timeIntervalSince(armedAt) <= window
    }

    private func cancelCurrentOperation(source: String = "cancel") {
        guard !isShutdown, !isPreparingForTermination else { return }
        guard Self.canCancelCurrentOperation(
            isRecording: isRecording,
            isProcessing: isProcessing,
            hasActiveOperationTask: activeOperationTask != nil,
            hasMeetingCaptureContext: meetingCaptureContext != nil,
            hasPendingMeetingCaptureStart: pendingMeetingCaptureStart != nil
                || pendingMeetingCaptureStartHandle != nil
                || pendingMeetingCaptureCancellationHandle != nil
        ) else {
            Log.app.debug("Cancel requested (\(source)) but no operation in progress")
            return
        }

        // Background media transcription jobs are long-running and were explicitly
        // queued by the user — don't cancel them via keyboard shortcut. Only bail
        // when the media job is the sole active work: a concurrent dictation
        // session must stay cancellable.
        guard !isMediaTranscriptionOnlyWork else {
            Log.app.debug("Cancel requested (\(source)) during background media transcription — ignoring")
            return
        }

        Log.app.info("Cancelling current operation via \(source)")
        let capturedStreamingSessionToken = activeStreamingSessionToken
        let capturedVoiceNoteHandle = voiceNoteCaptureContext?.handle
        let capturedMeetingContext = meetingCaptureContext
        let capturedPendingMeetingHandle = pendingMeetingCaptureCancellationHandle
            ?? pendingMeetingCaptureStartHandle
        let capturedPendingMeetingStartTask = pendingMeetingCaptureStartTask
        let capturedActiveOperationTask = activeOperationTask

        escapeCancelArmedAt = nil
        // Invalidate any in-flight stop/transcribe/enhance pipeline first so post-await
        // stages discard results even if cooperative cancellation is delayed.
        operationController.cancel()
        cancelPendingNoteAppendStart()
        cancelPendingMeetingCaptureStart()
        activeOperationTask?.cancel()
        activeOperationTask = nil
        // Free stop admission immediately so a new recording can stop even while the
        // cancelled finalize task is still unwinding its defer.
        recordingStopAdmission.invalidateCurrentClaim()
        cancelActiveVoiceNoteCapture()
        audioRecorder.resetAudioEngine()
        let meetingCancellationTaskID = UUID()
        meetingCancellationTasks[meetingCancellationTaskID] = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.meetingCancellationTasks[meetingCancellationTaskID] = nil }
            if let capturedPendingMeetingStartTask {
                await capturedPendingMeetingStartTask.value
            }
            if let capturedActiveOperationTask {
                _ = await capturedActiveOperationTask.result
            }
            if let capturedPendingMeetingHandle {
                do {
                    try await self.cancelMeetingCaptureStartHandle(capturedPendingMeetingHandle)
                } catch {
                    self.reportMeetingCaptureTerminalPersistenceFailure(error)
                }
            }
            if let capturedMeetingContext {
                do {
                    try await self.cancelMeetingCapture(
                        capturedMeetingContext.handle,
                        activeContext: capturedMeetingContext
                    )
                } catch {
                    self.reportMeetingCaptureTerminalPersistenceFailure(error)
                }
            }
        }

        if let capturedStreamingSessionToken {
            if activeStreamingSessionToken == capturedStreamingSessionToken {
                activeStreamingSessionToken = nil
            }
            streamingSession.cancelDetached(session: capturedStreamingSessionToken)
        }
        if let capturedVoiceNoteHandle {
            streamingSession.cancelArtifactCaptureDetached(for: capturedVoiceNoteHandle)
        }
        if capturedStreamingSessionToken == nil, capturedVoiceNoteHandle == nil {
            streamingSession.deactivate()
        }
        recordingState.endRecording(message: localized("Recording canceled.", locale: settingsStore.selectedAppLocale.locale))
        recordingState.clearCurrentJob()

        mediaPauseService.endRecordingSession()
        isRecording = false
        isProcessing = false
        isRecordingFeatureCaptureActive = false
        isQuickCaptureMode = false
        clearNoteAppendMode()
        recordingStartTime = nil
        manualExpectedSpeakerCount = nil
        capturedContext = nil
        capturedSnapshot = nil
        capturedAdapterCapabilities = nil
        capturedRoutingSignal = nil
        stopLiveContextSession()
        updateVibeRuntimeStateFromSettings()

        statusBarController.setIdleState()
        statusBarController.updateMenuState()

        finishIndicatorSession()
    }

    private func handleAudioCaptureFailure(_ failure: Error) {
        if case .recordingLimitReached = failure as? AudioRecorderError {
            handleRecordingLimitReached(failure)
            return
        }
        let capturedStreamingSessionToken = activeStreamingSessionToken
        let capturedVoiceNoteHandle = voiceNoteCaptureContext?.handle
        error = failure
        Log.app.error("Audio capture failed: \(failure.localizedDescription)")
        if let capturedStreamingSessionToken,
           activeStreamingSessionToken == capturedStreamingSessionToken {
            activeStreamingSessionToken = nil
        }
        let hadCapturedStreamingOwner =
            capturedStreamingSessionToken != nil || capturedVoiceNoteHandle != nil
        if let capturedStreamingSessionToken {
            streamingSession.cancelDetached(session: capturedStreamingSessionToken)
        }
        if let capturedVoiceNoteHandle {
            streamingSession.cancelArtifactCaptureDetached(for: capturedVoiceNoteHandle)
        }
        let captureFailureLocale = settingsStore.selectedAppLocale.locale
        let captureFailureMessage = String(
            format: localized("Recording stopped: %@", locale: captureFailureLocale),
            locale: captureFailureLocale,
            failure.localizedDescription
        )
        recordingState.endRecording(message: captureFailureMessage)
        if let context = voiceNoteCaptureContext {
            failVoiceNoteCapture(context, stage: "audio-capture", error: failure)
        }
        if let context = meetingCaptureContext {
            let nsError = failure as NSError
            do {
                try captureSessionStore.interruptMeetingCapture(
                    context.handle,
                    errorDomain: nsError.domain,
                    errorCode: String(nsError.code),
                    message: failure.localizedDescription,
                    at: .now
                )
                clearMeetingCaptureContext(ifCurrent: context)
            } catch {
                reportMeetingCaptureTerminalPersistenceFailure(error)
            }
        }
        recordingState.clearCurrentJob()
        if hadCapturedStreamingOwner {
            Log.transcription.info("Cancelled streaming transcription after audio capture failure")
        }

        mediaPauseService.endRecordingSession()
        isRecording = false
        isProcessing = false
        isRecordingFeatureCaptureActive = false
        isQuickCaptureMode = false
        clearNoteAppendMode()
        manualExpectedSpeakerCount = nil
        capturedContext = nil
        capturedSnapshot = nil
        capturedAdapterCapabilities = nil
        capturedRoutingSignal = nil
        stopLiveContextSession()
        updateVibeRuntimeStateFromSettings()

        statusBarController.setIdleState()
        statusBarController.updateMenuState()
        finishIndicatorSession()

        toastService.show(
            ToastPayload(message: captureFailureMessage, style: .error)
        )
    }

    /// The recorder has stopped accepting new PCM, but its valid spool remains
    /// intact. Route this through the normal stop path so captured speech is
    /// transcribed instead of treating the limit as a cancellation.
    private func handleRecordingLimitReached(_ signal: Error) {
        guard isRecording, recordingStartTime != nil else { return }
        Log.app.info("Recording duration limit reached; finalizing captured audio")
        toastService.show(
            ToastPayload(message: signal.localizedDescription, style: .standard)
        )
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await self.dispatchRecordingStop()
            } catch {
                self.handleAudioCaptureFailure(error)
            }
        }
    }

    private func resetProcessingState() {
        mediaPauseService.endRecordingSession()
        isProcessing = false
        isRecordingFeatureCaptureActive = false
        // Note-append mode is cleared by the stop path after processing; only clear if not mid-append.
        if !isNoteAppendMode {
            NoteAppendListeningCoordinator.shared.state.finishSession()
        }
        recordingState.endRecording()
        recordingStartTime = nil
        manualExpectedSpeakerCount = nil
        capturedContext = nil
        capturedSnapshot = nil
        capturedAdapterCapabilities = nil
        capturedRoutingSignal = nil
        stopLiveContextSession()
        updateVibeRuntimeStateFromSettings()
        statusBarController.setIdleState()
        statusBarController.updateMenuState()

        finishIndicatorSession()
    }

    // MARK: - Floating Indicator Actions

    private func handleHideFloatingIndicatorForOneHour() {
        let hideDuration: TimeInterval = 60 * 60
        floatingIndicatorHiddenUntil = Date().addingTimeInterval(hideDuration)

        hideAllFloatingIndicators()
        syncFloatingIndicatorFocusTracking()

        floatingIndicatorHiddenTask?.cancel()
        floatingIndicatorHiddenTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: UInt64(hideDuration * 1_000_000_000))
            } catch {
                return
            }

            await MainActor.run {
                guard let self = self else { return }
                self.floatingIndicatorHiddenUntil = nil
                self.updateFloatingIndicatorVisibility()
            }
        }

        Log.ui.info("Floating indicator hidden for one hour")
    }

    private func handleReportIssue() {
        guard let supportURL = URL(string: "https://github.com/watzon/pindrop/issues") else { return }
        NSWorkspace.shared.open(supportURL)
    }

    @discardableResult
    private func applyPreferredInputDeviceUID(_ uid: String) -> Bool {
        do {
            try audioRecorder.setPreferredInputDeviceUID(uid)
            return true
        } catch {
            self.error = error
            Log.audio.error("Failed to switch input device: \(error.localizedDescription)")
            let locale = settingsStore.selectedAppLocale.locale
            toastService.show(
                ToastPayload(
                    message: String(format: localized("Could not switch microphone: %@", locale: locale), locale: locale, error.localizedDescription),
                    style: .error
                )
            )
            // The recorder reverted to the device actually capturing; snap the
            // stored selection back so Settings doesn't show a mic that isn't
            // recording (silent wrong-device recordings otherwise).
            let actualUID = audioRecorder.currentPreferredInputDeviceUID ?? ""
            if settingsStore.selectedInputDeviceUID != actualUID {
                settingsStore.selectedInputDeviceUID = actualUID
                inputMuteMonitor?.setPreferredDeviceUID(actualUID)
            }
            return false
        }
    }

    private func handleSelectInputDeviceUID(_ uid: String) {
        settingsStore.selectedInputDeviceUID = uid
        guard applyPreferredInputDeviceUID(uid) else { return }
        inputMuteMonitor?.setPreferredDeviceUID(uid)

        if uid.isEmpty {
            Log.audio.info("Selected input device: system default")
        } else {
            Log.audio.info("Selected input device UID: \(uid)")
        }
    }

    private func setupInputDeviceMonitoring() {
        let monitor = AudioDeviceListMonitor()
        monitor.onChange = { [weak self] in
            self?.validateSelectedInputDeviceAvailability()
        }
        monitor.start()
        inputDeviceListMonitor = monitor
        validateSelectedInputDeviceAvailability()
        setupInputMuteMonitoring()
    }

    private func setupInputMuteMonitoring() {
        let muteMonitor = InputMuteMonitor(
            preferredDeviceUID: settingsStore.selectedInputDeviceUID
        )
        muteMonitor.onMuteStateChange = { [weak self] muted in
            self?.floatingIndicatorState.isInputMuted = muted
        }
        muteMonitor.start()
        floatingIndicatorState.isInputMuted = muteMonitor.isMuted
        inputMuteMonitor = muteMonitor
    }

    /// If the explicitly selected input device is no longer attached, fall back to the
    /// system default so capture and the device pickers don't stay pinned to a device
    /// that isn't there anymore.
    private func validateSelectedInputDeviceAvailability() {
        let uid = settingsStore.selectedInputDeviceUID
        guard !uid.isEmpty else { return }
        guard !AudioDeviceManager.inputDevices().contains(where: { $0.uid == uid }) else { return }

        Log.audio.info(
            "Selected input device is no longer available (uid=\(uid)); falling back to system default"
        )
        handleSelectInputDeviceUID("")
    }

    private func handleSelectLanguage(_ language: AppLanguage) {
        settingsStore.selectedAppLanguage = language
        Log.ui.info("Selected app language: \(language.rawValue)")
    }

    // MARK: - Copy Last Transcript

    private func handleCopyLastTranscript() async {
        do {
            let records = try historyStore.fetch(limit: 1)
            guard let lastRecord = records.first else {
                Log.app.warning("No transcripts to copy")
                return
            }

            copyTextWithUndo(lastRecord.text)
            Log.app.info("Copied last transcript to clipboard")
        } catch {
            Log.app.error("Failed to copy last transcript: \(error)")
        }
    }

    /// Snapshots the pasteboard, writes text, and shows a "Copied — Undo" toast.
    func copyTextWithUndo(_ text: String) {
        guard !text.isEmpty else { return }
        do {
            let snapshot = try outputManager.copyReplacingClipboard(text)
            let locale = settingsStore.selectedAppLocale.locale
            toastService.show(
                ToastPayload(
                    message: localized("Copied to clipboard", locale: locale),
                    actions: [
                        ToastAction(title: localized("Undo", locale: locale), role: .primary) { [weak self] in
                            let restored = self?.outputManager.restoreClipboardSnapshot(snapshot) ?? false
                            if restored {
                                Log.output.info("Restored clipboard after copy undo")
                            } else {
                                Log.output.error("Failed to restore clipboard after copy undo")
                            }
                        }
                    ],
                    variant: .copied
                )
            )
        } catch {
            Log.output.error("Failed to copy text with undo: \(error)")
        }
    }

    @objc private func handleCopyTextWithUndoNotification(_ notification: Notification) {
        guard let text = notification.userInfo?["text"] as? String else { return }
        copyTextWithUndo(text)
    }

    private func handlePasteLastTranscript() async {
        do {
            let records = try historyStore.fetch(limit: 1)
            guard let lastRecord = records.first else {
                Log.app.warning("No transcripts to paste")
                return
            }

            if permissionManager.checkAccessibilityPermission() {
                do {
                    try await outputManager.pasteText(lastRecord.text)
                    Log.output.info("Pasted last transcript into active app")
                    return
                } catch {
                    Log.output.error("Failed to paste last transcript directly: \(error)")
                }
            }

            try outputManager.copyToClipboard(lastRecord.text)
            Log.output.info("Copied last transcript to clipboard (paste fallback)")
        } catch {
            Log.output.error("Failed to prepare last transcript for paste: \(error)")
        }
    }

    // MARK: - Export Last Transcript

    private func handleExportLastTranscript() async {
        do {
            let records = try historyStore.fetch(limit: 1)
            guard let lastRecord = records.first else {
                Log.app.warning("No transcripts to export")
                return
            }

            await MainActor.run {
                let savePanel = NSSavePanel()
                savePanel.allowedContentTypes = [.plainText]
                savePanel.nameFieldStringValue = "transcript.txt"
                savePanel.title = "Export Transcript"

                guard savePanel.runModal() == .OK, let url = savePanel.url else { return }

                do {
                    try lastRecord.text.write(to: url, atomically: true, encoding: .utf8)
                    Log.app.info("Exported transcript to \(url.lastPathComponent)")
                } catch {
                    Log.app.error("Failed to export transcript: \(error)")
                }
            }
        } catch {
            Log.app.error("Failed to fetch transcript for export: \(error)")
        }
    }

    // MARK: - Media Transcription
    static func mediaTranscriptionProvider(
        named modelName: String,
        availableModels: [PindropSpeech.ModelManager.WhisperModel]
    ) -> PindropSpeech.ModelManager.ModelProvider {
        availableModels.first(where: { $0.name == modelName })?.provider ?? .whisperKit
    }

    private func handleImportMediaFiles(_ urls: [URL], options: TranscriptionJobOptions) {
        for url in urls {
            let job = MediaTranscriptionJobState(request: .file(url), options: options)
            enqueueOrStart(job)
        }
    }

    private func handleSubmitMediaLink(_ link: String, options: TranscriptionJobOptions) {
        let job = MediaTranscriptionJobState(request: .link(link), options: options)
        enqueueOrStart(job)
    }

    private func enqueueOrStart(_ job: MediaTranscriptionJobState) {
        if mediaTranscriptionTask == nil {
            startMediaTranscriptionTask(for: job)
        } else {
            mediaTranscriptionState.enqueue(job)
        }
    }

    private func clearTranscriptionQueue() {
        mediaTranscriptionGeneration &+= 1
        mediaQueueRestoreRequested =
            mediaQueueRestoreRequested || queueOriginalModelName != nil
        mediaQueueNeedsProcessingReset = mediaQueueNeedsProcessingReset || isProcessing
        mediaQueueDeferredUntilIdle = false
        mediaTranscriptionTask?.cancel()
        mediaTranscriptionState.clearAllJobs()
        if mediaTranscriptionTask == nil {
            startMediaQueueContinuationIfNeeded()
        }
    }

    private func handleDownloadDiarizationModel() {
        guard !mediaTranscriptionState.isDiarizationModelDownloading,
              !recordingState.isDiarizationModelDownloading else {
            return
        }

        mediaTranscriptionState.isDiarizationModelDownloading = true
        mediaTranscriptionState.diarizationModelDownloadProgress = 0.0
        recordingState.isDiarizationModelDownloading = true
        recordingState.diarizationModelDownloadProgress = 0.0

        Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                self.mediaTranscriptionState.isDiarizationModelDownloading = false
                self.recordingState.isDiarizationModelDownloading = false
            }

            do {
                try await self.modelManager.downloadFeatureModel(.diarization) { [weak self] progress in
                    guard let self else { return }
                    self.mediaTranscriptionState.diarizationModelDownloadProgress = progress
                    self.recordingState.diarizationModelDownloadProgress = progress
                }
                await self.modelManager.refreshDownloadedFeatureModels()
                self.settingsStore.diarizationFeatureEnabled = true
                self.mediaTranscriptionState.setupIssue = nil
                self.toastService.show(ToastPayload(message: localized("Speaker diarization is ready.", locale: self.settingsStore.selectedAppLocale.locale)))
                self.recordingState.setupIssue = nil
                self.recordingState.message = localized("Speaker diarization is ready.", locale: self.settingsStore.selectedAppLocale.locale)
            } catch {
                self.mediaTranscriptionState.diarizationModelDownloadProgress = 0.0
                self.recordingState.diarizationModelDownloadProgress = 0.0
                self.mediaTranscriptionState.setSetupIssue(error.localizedDescription)
                self.recordingState.setSetupIssue(error.localizedDescription)
            }
        }
    }

    private func handleStartMeetingCapture(expectedSpeakerCount: Int?) -> Bool {
        guard !isRecording,
              !isProcessing,
              Self.canBeginMeetingCapture(
                  activeHandle: meetingCaptureContext?.handle,
                  recoveryTaskActive: meetingRecoveryTask != nil,
                  isShutdown: isShutdown || isPreparingForTermination
              ),
              let captureStartClaim = recordingState.claimCaptureStart() else {
            recordingState.message = "Finish the active transcription before starting another one."
            return false
        }
        guard let meetingClaim = meetingCaptureStartAdmission.claim() else {
            recordingState.releaseCaptureStart(captureStartClaim)
            recordingState.message = "Finish the active transcription before starting another one."
            return false
        }

        pendingMeetingCaptureStart = meetingClaim
        pendingMeetingCaptureStartTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                self.recordingState.releaseCaptureStart(captureStartClaim)
                self.clearPendingMeetingCaptureStart(ifCurrent: meetingClaim)
            }

            do {
                try await self.startManualTranscriptionRecording(
                    mode: .microphoneAndSystemAudio,
                    expectedSpeakerCount: expectedSpeakerCount,
                    pendingStart: meetingClaim
                )
            } catch {
                guard !self.isShutdown,
                      !self.isPreparingForTermination,
                      self.isPendingMeetingCaptureStartCurrent(meetingClaim) else { return }
                self.error = error
                self.audioRecorder.resetAudioEngine()
                self.isRecordingFeatureCaptureActive = false
                self.recordingState.endRecording(message: error.localizedDescription)
                Log.app.error("Failed to start meeting capture: \(error)")
            }
        }
        return true
    }

    private func startManualTranscriptionRecording(
        mode: AudioRecordingMode,
        expectedSpeakerCount: Int? = nil,
        pendingStart: MeetingCaptureStartClaim
    ) async throws {
        try ensurePendingMeetingCaptureStartCurrent(pendingStart)
        guard !isRecording && !isProcessing else {
            recordingState.message = "Finish the active transcription before starting another one."
            return
        }
        guard Self.canBeginMeetingCapture(
            activeHandle: meetingCaptureContext?.handle,
            recoveryTaskActive: meetingRecoveryTask != nil,
            isShutdown: isShutdown || isPreparingForTermination
        ) else {
            throw MeetingCaptureAdmissionError.captureAlreadyActive
        }

        try ensurePendingMeetingCaptureStartCurrent(pendingStart)
        let startedAt = Date.now
        let preferredInputUID = audioRecorder.currentPreferredInputDeviceUID
            ?? settingsStore.selectedInputDeviceUID
        let microphoneDisplayName = AudioDeviceManager.inputDevices()
            .first(where: { $0.uid == preferredInputUID })?
            .displayName ?? "Microphone"
        let handle = try captureSessionStore.startMeetingCapture(
            startedAt: startedAt,
            microphoneDisplayName: microphoneDisplayName,
            systemAudioDisplayName: "System Audio"
        )
        pendingMeetingCaptureStartHandle = handle

        do {
            try ensurePendingMeetingCaptureStartCurrent(pendingStart)
            let humanAnchor = try captureSessionStore.ensureMeetingHumanAnchor(
                handle,
                title: localized(
                    "Untitled Note",
                    locale: settingsStore.selectedAppLocale.locale
                ),
                at: startedAt
            )
            _ = try captureMeetingStartAssignments(sessionID: handle.sessionID)
            try ensurePendingMeetingCaptureStartCurrent(pendingStart)
            let spoolPlan = try await mediaIngestionService.makeMeetingCaptureSpoolPlan(
                sessionID: handle.sessionID,
                microphoneSourceID: handle.microphoneSourceID,
                systemAudioSourceID: handle.systemAudioSourceID
            )
            try ensurePendingMeetingCaptureStartCurrent(pendingStart)

            meetingCaptureGeneration &+= 1
            let context = MeetingCaptureContext(
                handle: handle,
                humanAnchorNoteID: humanAnchor.noteID,
                spoolPlan: spoolPlan,
                generation: meetingCaptureGeneration
            )
            try ensurePendingMeetingCaptureStartCurrent(pendingStart)
            meetingCaptureContext = context

            try ensurePendingMeetingCaptureStartCurrent(pendingStart)
            let didStartRecording = try await audioRecorder.startMeetingRecording(
                spoolPlan: spoolPlan,
                onChunkSealed: { [weak self] chunk in
                    Task { @MainActor [weak self] in
                        self?.recordSealedMeetingChunk(chunk, for: context)
                    }
                }
            )
            try ensurePendingMeetingCaptureStartCurrent(pendingStart)
            guard didStartRecording else {
                throw MeetingCaptureAdmissionError.recorderDidNotStart
            }
            try ensureMeetingCaptureCurrent(context)

            try ensurePendingMeetingCaptureStartCurrent(pendingStart)
            manualExpectedSpeakerCount = expectedSpeakerCount
            isRecording = true
            isRecordingFeatureCaptureActive = true
            recordingStartTime = startedAt
            recordingState.beginRecording(mode: mode, startedAt: startedAt)
            statusBarController.setRecordingState()
            statusBarController.updateMenuState()
            startRecordingIndicatorSession()

            try ensurePendingMeetingCaptureStartCurrent(pendingStart)
            do {
                let note = try notesStore.fetch(id: context.humanAnchorNoteID)
                noteEditorWindowController.show(note: note, isNewNote: false)
            } catch {
                Log.app.warning(
                    "Meeting capture started, but its human anchor could not be opened: \(error.localizedDescription)"
                )
            }
        } catch {
            guard isPendingMeetingCaptureStartCurrent(pendingStart) else {
                if meetingCaptureContext?.handle == handle {
                    audioRecorder.resetAudioEngine()
                }
                do {
                    try await cancelMeetingCaptureStartHandle(handle)
                } catch {
                    reportMeetingCaptureTerminalPersistenceFailure(error)
                }
                throw CancellationError()
            }

            let nsError = error as NSError
            if let context = meetingCaptureContext, context.handle == handle {
                if Self.isTaskCancellation(error) {
                    try await cancelMeetingCapture(handle, activeContext: context)
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
                clearMeetingCaptureContext(ifCurrent: context)
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
            throw error
        }
    }

    private func stopManualTranscriptionRecording(token: DictationOperationToken) async throws {
        guard isRecordingFeatureCaptureActive, let context = meetingCaptureContext else {
            throw AudioRecorderError.notRecording
        }
        let mode = recordingState.selectedCaptureMode

        do {
            try captureSessionStore.beginMeetingFinalization(context.handle, at: .now)
            let stopResult = try await audioRecorder.stopMeetingRecording()
            try ensureMeetingCaptureCurrent(context, token: token)
            for chunk in stopResult.sealedChunks {
                recordSealedMeetingChunk(chunk, for: context)
            }
            let recovery = try await reconcileMeetingArtifacts(
                handle: context.handle,
                spoolPlan: context.spoolPlan,
                operationGuard: { try self.ensureMeetingCaptureCurrent(context, token: token) }
            )
            try ensureMeetingCaptureCurrent(context, token: token)
            try finishMeetingSources(
                handle: context.handle,
                artifacts: recovery.sealedChunks,
                recoveryFailures: recovery.failures,
                stopResult: stopResult
            )

            isRecording = false
            isRecordingFeatureCaptureActive = false
            recordingState.endRecording()
            statusBarController.setProcessingState()
            statusBarController.updateMenuState()
            transitionRecordingIndicatorToProcessing()
            isProcessing = true
            let job = MediaTranscriptionJobState(
                request: .manualCapture(mode.rawValue),
                options: TranscriptionJobOptions(
                    modelName: settingsStore.selectedModel,
                    language: settingsStore.selectedAppLanguage,
                    outputFormat: .plainText,
                    diarizationEnabled: settingsStore.diarizationFeatureEnabled,
                    expectedSpeakerCount: manualExpectedSpeakerCount
                ),
                destinationFolderID: nil,
                stage: .transcribing,
                progress: 0,
                detail: "Preparing durable meeting chunks"
            )
            recordingState.beginJob(job)
            let recordID = try captureSessionStore.reserveMeetingTranscriptionRecordID(context.handle)
            try await finalizeMeetingCapture(
                context.handle,
                spoolPlan: context.spoolPlan,
                operationGuard: { [weak self] in
                    guard let self else { throw CancellationError() }
                    try self.ensureMeetingCaptureCurrent(context, token: token)
                }
            )
            guard isMeetingCaptureContextCurrent(context), operationController.isCurrent(token) else {
                throw CancellationError()
            }
            clearMeetingCaptureContext(ifCurrent: context)
            manualExpectedSpeakerCount = nil
            resetProcessingState()
            recordingState.completeCurrentJob(
                with: recordID,
                message: "Meeting recording transcribed successfully."
            )
            mainWindowController.openLibrary(recordID: recordID)
        } catch is CancellationError {
            // Explicit cancellation already terminally cancelled the durable session.
            // Lifecycle interruption retains it for startup recovery instead.
            if isMeetingCaptureContextCurrent(context), operationController.isCurrent(token) {
                do {
                    try await cancelActiveMeetingCapture()
                } catch {
                    reportMeetingCaptureTerminalPersistenceFailure(error)
                    throw error
                }
                resetStoppedMeetingCaptureState()
                recordingState.clearCurrentJob()
                recordingState.message = localized("Recording canceled.", locale: settingsStore.selectedAppLocale.locale)
            }
            throw CancellationError()
        } catch {
            // Chunk and History failures are durable/retryable. Retain the exact
            // capture context so cancel can retry terminal persistence.
            resetStoppedMeetingCaptureState()
            recordingState.failCurrentJob(error.localizedDescription)
            throw error
        }
    }

    private func startMediaTranscriptionTask(for job: MediaTranscriptionJobState) {
        guard mediaTranscriptionTask == nil, !isShutdown else {
            if !isShutdown {
                mediaTranscriptionState.enqueue(job)
            }
            return
        }

        mediaTranscriptionGeneration &+= 1
        let generation = mediaTranscriptionGeneration
        mediaTranscriptionTaskGeneration = generation
        mediaTranscriptionTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.performMediaTranscription(job, generation: generation)
            await self.finishMediaTranscriptionTask(generation: generation)
        }
    }

    private func restoreOriginalModelAfterQueueIfNeeded(generation: UInt64) async {
        guard isMediaTranscriptionOwnerCurrent(generation),
              let original = queueOriginalModelName else {
            return
        }

        do {
            try await loadAndActivateModel(
                named: original,
                provider: Self.mediaTranscriptionProvider(
                    named: original,
                    availableModels: modelManager.availableModels
                )
            )
            guard isMediaTranscriptionOwnerCurrent(generation) else { return }
            queueOriginalModelName = nil
            let restoredName = modelManager.availableModels.first(where: { $0.name == original })?.displayName ?? original
            let locale = settingsStore.selectedAppLocale.locale
            toastService.show(
                ToastPayload(
                    message: String(format: localized("Queue complete — restored %@", locale: locale), locale: locale, restoredName),
                    style: .standard
                )
            )
        } catch {
            guard isMediaTranscriptionOwnerCurrent(generation) else { return }
            queueOriginalModelName = nil
            Log.model.error("Failed to restore original model after queue: \(error)")
        }
    }
    
    private func finishMediaTranscriptionTask(generation: UInt64) async {
        guard mediaTranscriptionTaskGeneration == generation else { return }
        guard isMediaTranscriptionOwnerCurrent(generation) else {
            releaseMediaTranscriptionTaskOwnership(generation: generation)
            startMediaQueueContinuationIfNeeded()
            return
        }

        await continueMediaQueueAsOwner(generation: generation)
    }

    private func startMediaQueueContinuationIfNeeded() {
        guard !isShutdown, mediaTranscriptionTask == nil else { return }
        guard !mediaQueueDeferredUntilIdle else { return }
        guard mediaQueueRestoreRequested
                || mediaQueueNeedsProcessingReset
                || queueOriginalModelName != nil
                || !mediaTranscriptionState.pendingJobs.isEmpty else {
            return
        }

        let generation = mediaTranscriptionGeneration
        mediaTranscriptionTaskGeneration = generation
        mediaTranscriptionTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.continueMediaQueueAsOwner(generation: generation)
        }
    }

    private func continueMediaQueueAsOwner(generation: UInt64) async {
        guard isMediaTranscriptionOwnerCurrent(generation) else {
            releaseMediaTranscriptionTaskOwnership(generation: generation)
            startMediaQueueContinuationIfNeeded()
            return
        }

        // A job just yielded to an active dictation session; park the queue until
        // the session ends (resumeDeferredMediaQueueIfIdle restarts it).
        if mediaQueueDeferredUntilIdle {
            releaseMediaTranscriptionTaskOwnership(generation: generation)
            return
        }

        if mediaQueueNeedsProcessingReset {
            resetProcessingState()
            mediaQueueNeedsProcessingReset = false
        }

        if mediaQueueRestoreRequested {
            await restoreOriginalModelAfterQueueIfNeeded(generation: generation)
            guard isMediaTranscriptionOwnerCurrent(generation) else {
                releaseMediaTranscriptionTaskOwnership(generation: generation)
                startMediaQueueContinuationIfNeeded()
                return
            }
            mediaQueueRestoreRequested = false
        }

        if let next = mediaTranscriptionState.dequeueNextJob() {
            releaseMediaTranscriptionTaskOwnership(generation: generation)
            startMediaTranscriptionTask(for: next)
            return
        }

        await restoreOriginalModelAfterQueueIfNeeded(generation: generation)
        guard isMediaTranscriptionOwnerCurrent(generation) else {
            releaseMediaTranscriptionTaskOwnership(generation: generation)
            startMediaQueueContinuationIfNeeded()
            return
        }
        releaseMediaTranscriptionTaskOwnership(generation: generation)
    }

    private func releaseMediaTranscriptionTaskOwnership(generation: UInt64) {
        guard mediaTranscriptionTaskGeneration == generation else { return }
        mediaTranscriptionTask = nil
        mediaTranscriptionTaskGeneration = nil
    }

    /// Restarts a queue that was paused because a job yielded to a dictation
    /// session. Driven from the isRecording/isProcessing didSets so every path
    /// that returns the pipeline to idle resumes the queue.
    private func resumeDeferredMediaQueueIfIdle() {
        guard mediaQueueDeferredUntilIdle, !isRecording, !isProcessing else { return }
        mediaQueueDeferredUntilIdle = false
        startMediaQueueContinuationIfNeeded()
    }

    private func isMediaTranscriptionOwnerCurrent(_ generation: UInt64) -> Bool {
        !isShutdown
            && mediaTranscriptionGeneration == generation
            && mediaTranscriptionTaskGeneration == generation
    }

    private func ensureMediaTranscriptionOwnerCurrent(_ generation: UInt64) throws {
        try Task.checkCancellation()
        guard isMediaTranscriptionOwnerCurrent(generation) else {
            throw CancellationError()
        }
    }

    private func performMediaTranscription(
        _ jobIn: MediaTranscriptionJobState,
        generation: UInt64
    ) async {
        guard isMediaTranscriptionOwnerCurrent(generation) else { return }
        guard !isRecording && !isProcessing else {
            // A dictation session owns the pipeline right now. Put the job back at
            // the head of the queue and pause the queue until the session ends —
            // a bare return here silently lost the dequeued job.
            mediaTranscriptionState.pendingJobs.insert(jobIn, at: 0)
            mediaQueueDeferredUntilIdle = true
            toastService.show(
                ToastPayload(
                    message: localized(
                        "Recording in progress — transcription will start when it finishes.",
                        locale: settingsStore.selectedAppLocale.locale
                    ),
                    style: .standard
                )
            )
            return
        }

        let request = jobIn.request
        let options = jobIn.options

        await modelManager.refreshDownloadedFeatureModels()
        guard isMediaTranscriptionOwnerCurrent(generation), !Task.isCancelled else { return }
        guard !options.diarizationEnabled || modelManager.isFeatureModelDownloaded(.diarization) else {
            let message = localized("Download the speaker diarization model before starting media transcription.", locale: settingsStore.selectedAppLocale.locale)
            // Record the job as failed so it doesn't just vanish from the queue,
            // then surface the setup guidance banner.
            mediaTranscriptionState.beginJob(jobIn)
            mediaTranscriptionState.failCurrentJob(message, returnToLibrary: true)
            mediaTranscriptionState.setSetupIssue(message)
            return
        }

        let job = MediaTranscriptionJobState(
            id: jobIn.id,
            request: request,
            options: options,
            destinationFolderID: mediaTranscriptionState.selectedFolderID ?? jobIn.destinationFolderID,
            stage: request.sourceKind == .webLink ? .preflight : .importing,
            progress: nil,
            detail: request.sourceKind == .webLink ? "Checking yt-dlp and ffmpeg" : "Importing local media"
        )

        mediaTranscriptionState.beginJob(job)
        mainWindowController.navigate(to: .library)

        isProcessing = true
        statusBarController.setProcessingState()
        statusBarController.updateMenuState()
        startProcessingIndicatorSession()

        var didResetProcessingState = false

        defer {
            if !didResetProcessingState,
               isMediaTranscriptionOwnerCurrent(generation) {
                resetProcessingState()
            }
        }

        do {
            // --- Model preparation ---
            let requestedModel = options.modelName.isEmpty ? settingsStore.selectedModel : options.modelName
            if requestedModel != activeModelName {
                if queueOriginalModelName == nil {
                    queueOriginalModelName = activeModelName
                    let displayName = modelManager.availableModels.first(where: { $0.name == requestedModel })?.displayName ?? requestedModel
                    let locale = settingsStore.selectedAppLocale.locale
                    toastService.show(
                        ToastPayload(
                            message: String(format: localized("Switching to %@ for this queue", locale: locale), locale: locale, displayName),
                            style: .standard
                        )
                    )
                }
                mediaTranscriptionState.updateJob(
                    stage: .preparingModel,
                    progress: nil,
                    detail: "Loading \(requestedModel)…",
                    errorMessage: nil
                )
                try await loadAndActivateModel(
                    named: requestedModel,
                    provider: Self.mediaTranscriptionProvider(
                        named: requestedModel,
                        availableModels: modelManager.availableModels
                    )
                )
            }

            try ensureMediaTranscriptionOwnerCurrent(generation)

            let managedAsset = try await mediaIngestionService.ingest(
                request: request,
                jobID: job.id,
                progressHandler: { [weak self] progress, detail in
                    guard let self,
                          self.isMediaTranscriptionOwnerCurrent(generation) else {
                        return
                    }
                    let stage: MediaTranscriptionStage = request.sourceKind == .webLink ? .downloading : .importing
                    self.mediaTranscriptionState.updateJob(
                        stage: stage,
                        progress: progress,
                        detail: detail,
                        errorMessage: nil
                    )
                }
            )

            try ensureMediaTranscriptionOwnerCurrent(generation)

            mediaTranscriptionState.updateJob(
                stage: .preparingAudio,
                progress: nil,
                detail: "Preparing audio for transcription",
                errorMessage: nil
            )
            let preparedAudio = try await mediaPreparationService.prepareAudio(
                from: managedAsset.mediaURL
            )

            try ensureMediaTranscriptionOwnerCurrent(generation)

            mediaTranscriptionState.updateJob(
                stage: .transcribing,
                progress: nil,
                detail: options.diarizationEnabled ? "Running diarization and transcription" : "Running transcription",
                errorMessage: nil
            )

            let transcriptionOutput = try await transcriptionService.transcribe(
                audioData: preparedAudio.audioData,
                diarizationEnabled: options.diarizationEnabled,
                options: makeTranscriptionOptions(
                    language: options.language,
                    route: .importedMedia
                ),
                diarizationOptions: .init(expectedSpeakerCount: options.expectedSpeakerCount),
                diarizationFailurePolicy: options.diarizationEnabled ? .required : .bestEffort
            )
            try ensureMediaTranscriptionOwnerCurrent(generation)
            let diarizationSegmentsJSON = encodeDiarizationSegmentsJSON(transcriptionOutput.diarizedSegments)

            mediaTranscriptionState.updateJob(
                stage: .saving,
                progress: nil,
                detail: "Saving transcript to history",
                errorMessage: nil
            )

            let renderedText = renderTranscriptionOutput(transcriptionOutput, format: options.outputFormat)
            let finalText = normalizedTranscriptionText(renderedText)
            guard !isTranscriptionEffectivelyEmpty(finalText) else {
                throw PindropMedia.MediaPreparationError.readFailed("No speech could be transcribed from this media.")
            }

            let transcriptionMetadata = await generateTranscriptionMetadataIfNeeded(
                from: finalText,
                managedAsset: managedAsset
            )
            try ensureMediaTranscriptionOwnerCurrent(generation)

            let record = try historyStore.save(
                text: finalText,
                originalText: nil,
                duration: preparedAudio.duration,
                modelUsed: activeModelName ?? settingsStore.selectedModel,
                enhancedWith: nil,
                diarizationSegmentsJSON: diarizationSegmentsJSON,
                sourceKind: managedAsset.sourceKind,
                sourceDisplayName: managedAsset.displayName,
                generatedTitle: transcriptionMetadata.generatedTitle,
                aiSummary: transcriptionMetadata.summary,
                sourceTitleOrigin: managedAsset.hasSourceMetadataTitle ? .sourceMetadata : .fallback,
                originalSourceURL: managedAsset.originalSourceURL,
                managedMediaPath: managedAsset.mediaURL.path,
                thumbnailPath: managedAsset.thumbnailURL?.path,
                folderID: job.destinationFolderID
            )
            updateRecentTranscriptsMenu()

            let shouldNavigateToDetail = mediaTranscriptionState.route == .processing(job.id)
            resetProcessingState()
            didResetProcessingState = true
            let completionLocale = settingsStore.selectedAppLocale.locale
            toastService.show(
                ToastPayload(
                    message: String(format: localized("Transcribed: %@", locale: completionLocale), locale: completionLocale, managedAsset.displayName)
                )
            )
            mediaTranscriptionState.completeCurrentJob(with: record.id, shouldNavigateToDetail: shouldNavigateToDetail)
        } catch is CancellationError {
            guard isMediaTranscriptionOwnerCurrent(generation) else { return }
            resetProcessingState()
            didResetProcessingState = true
            mediaTranscriptionState.showLibrary()
            mediaTranscriptionState.clearCurrentJob()
        } catch let error as MediaIngestionError {
            guard isMediaTranscriptionOwnerCurrent(generation) else { return }
            Log.app.error("Media ingestion failed: \(error.localizedDescription)")
            resetProcessingState()
            didResetProcessingState = true
            mediaTranscriptionState.clearCurrentJob()
            if case .toolingUnavailable(let message) = error {
                mediaTranscriptionState.setSetupIssue(message)
            } else {
                toastService.show(ToastPayload(message: error.localizedDescription, style: .error))
            }
        } catch {
            guard isMediaTranscriptionOwnerCurrent(generation) else { return }
            Log.app.error("Media transcription failed: \(error)")
            resetProcessingState()
            didResetProcessingState = true
            let shouldReturnToLibrary = mediaTranscriptionState.route != .processing(job.id)
            mediaTranscriptionState.failCurrentJob(error.localizedDescription, returnToLibrary: shouldReturnToLibrary)
        }
    }

    // MARK: - Output format rendering

    private func renderTranscriptionOutput(_ output: TranscriptionOutput, format: TranscribeOutputFormat) -> String {
        switch format {
        case .plainText:
            return output.text
        case .subtitles:
            guard let segments = output.diarizedSegments, !segments.isEmpty else {
                return output.text
            }
            return TranscriptExportService.formatAsSRT(segments)
        case .timestamps:
            guard let segments = output.diarizedSegments, !segments.isEmpty else {
                return output.text
            }
            return TranscriptExportService.formatAsTimestampedJSON(segments, plainText: output.text)
        }
    }

    private func generateTranscriptionMetadataIfNeeded(
        from transcription: String,
        managedAsset: ManagedMediaAsset
    ) async -> (generatedTitle: String?, summary: String?) {
        guard let assignment = settingsStore.resolveAssignment(for: .transcriptionMetadata) else {
            return (nil, nil)
        }

        do {
            let metadata = try await aiEnhancementService.generateTranscriptionMetadata(
                transcription: transcription,
                assignment: assignment,
                includeTitle: !managedAsset.hasSourceMetadataTitle
            )
            let trimmedSummary = metadata.summary.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
            return (
                managedAsset.hasSourceMetadataTitle ? nil : metadata.title,
                trimmedSummary.isEmpty ? nil : trimmedSummary
            )
        } catch {
            Log.aiEnhancement.warning(
                "Transcription metadata generation failed provider=\(assignment.kind.rawValue)")
            return (nil, nil)
        }
    }

    // MARK: - Clear Audio Buffer

    private func handleClearAudioBuffer() async {
        guard isRecording else {
            finishIndicatorSession()
            return
        }
        let capturedStreamingSessionToken = activeStreamingSessionToken
        let capturedVoiceNoteHandle = voiceNoteCaptureContext?.handle

        cancelPendingNoteAppendStart()
        Log.app.info("Clearing audio buffer")
        // Mirror cancel's teardown: invalidate any in-flight operation and stop
        // admission so a half-dispatched stop can't run against the cleared audio.
        operationController.cancel()
        activeOperationTask?.cancel()
        activeOperationTask = nil
        recordingStopAdmission.invalidateCurrentClaim()
        cancelActiveVoiceNoteCapture()
        audioRecorder.cancelRecording()
        do {
            try await cancelActiveMeetingCapture()
        } catch {
            reportMeetingCaptureTerminalPersistenceFailure(error)
        }

        if let capturedStreamingSessionToken {
            if activeStreamingSessionToken == capturedStreamingSessionToken {
                activeStreamingSessionToken = nil
            }
            streamingSession.cancelDetached(session: capturedStreamingSessionToken)
        }
        if let capturedVoiceNoteHandle {
            streamingSession.cancelArtifactCaptureDetached(for: capturedVoiceNoteHandle)
        }
        if capturedStreamingSessionToken == nil, capturedVoiceNoteHandle == nil {
            streamingSession.deactivate()
        }
        recordingState.endRecording(message: localized("Recording canceled.", locale: settingsStore.selectedAppLocale.locale))
        recordingState.clearCurrentJob()
        mediaPauseService.endRecordingSession()
        isRecording = false
        isProcessing = false
        // Capture modes must not survive a cleared buffer: a lingering note-append
        // mode blocks global dictation (NoteAppendGate) and leaves sticky listening UI.
        isRecordingFeatureCaptureActive = false
        isQuickCaptureMode = false
        clearNoteAppendMode()
        recordingStartTime = nil
        manualExpectedSpeakerCount = nil
        capturedContext = nil
        capturedSnapshot = nil
        capturedAdapterCapabilities = nil
        capturedRoutingSignal = nil
        stopLiveContextSession()
        updateVibeRuntimeStateFromSettings()
        error = nil

        statusBarController.setIdleState()
        statusBarController.updateMenuState()

        finishIndicatorSession()
    }

    // MARK: - Cancel Operation

    private func handleCancelOperation() async {
        cancelCurrentOperation(source: "hotkey-or-menu")
    }

    // MARK: - Toggle Output Mode

    private func handleToggleOutputMode() {
        let newMode = settingsStore.outputMode == "clipboard" ? "directInsert" : "clipboard"
        settingsStore.outputMode = newMode
        Log.app.info("Output mode changed to: \(newMode)")
    }

    private func ensureAccessibilityPermissionForDirectInsert(trigger: String, showFallbackAlert: Bool) {
        guard outputManager.outputMode == .directInsert else { return }

        let hasPermission = permissionManager.checkAccessibilityPermission()
        if hasPermission {
            hasShownAccessibilityFallbackAlertThisLaunch = false
            ensureGlobalKeyMonitorsIfPossible()
            return
        }

        if !hasRequestedAccessibilityPermissionThisLaunch {
            hasRequestedAccessibilityPermissionThisLaunch = true

            let grantedImmediately = permissionManager.requestAccessibilityPermission(showPrompt: true)
            Log.app.info("Requested Accessibility permission (trigger=\(trigger), grantedImmediately=\(grantedImmediately))")

            permissionManager.refreshAccessibilityPermissionStatus()
        }

        let hasPermissionAfterRequest = permissionManager.checkAccessibilityPermission()
        if hasPermissionAfterRequest {
            hasShownAccessibilityFallbackAlertThisLaunch = false
            ensureGlobalKeyMonitorsIfPossible()
            return
        }

        Log.app.info("Accessibility permission not granted - direct insert will use clipboard fallback")

        if showFallbackAlert && !hasShownAccessibilityFallbackAlertThisLaunch {
            hasShownAccessibilityFallbackAlertThisLaunch = true
            AlertManager.shared.showAccessibilityPermissionAlert()
        }

    }

    private func ensureGlobalKeyMonitorsIfPossible() {
        guard permissionManager.checkAccessibilityPermission() else { return }

        setupEscapeKeyMonitor()
        setupModifierKeyMonitor()
    }

    // MARK: - Toggle AI Enhancement

    /// Stashed assignment from the last "disable" toggle. Lives in-memory only so that the
    /// hotkey and menu toggle keep a friendly on/off semantic under v2 — removing the
    /// transcriptionEnhancement assignment effectively disables enhancement, but we hold on
    /// to the configuration so the user can flip it back without re-entering everything.
    /// Not persisted: a fresh launch re-reads whatever assignment exists in settings.
    private var transcriptionEnhancementStash: ModelAssignment?

    private func handleToggleAIEnhancement() {
        if let current = settingsStore.assignment(for: .transcriptionEnhancement) {
            transcriptionEnhancementStash = current
            settingsStore.setAssignment(nil, for: .transcriptionEnhancement)
            Log.app.info("AI enhancement disabled (transcriptionEnhancement assignment removed)")
            stopLiveContextSession()
        } else if let stashed = transcriptionEnhancementStash {
            settingsStore.setAssignment(stashed, for: .transcriptionEnhancement)
            Log.app.info("AI enhancement re-enabled from stashed assignment")
            if isRecording, shouldRunLiveContextSession() {
                startLiveContextSessionIfNeeded(initialSnapshot: capturedSnapshot)
            }
        } else {
            toastService.show(
                ToastPayload(
                    message:
                        "No AI provider configured for transcription enhancement. Open Pindrop Settings → AI Enhancement.",
                    style: .error
                )
            )
        }
        updateVibeRuntimeStateFromSettings()
    }

    // MARK: - Select Prompt Preset

    static func applyPromptPresetSelection(
        _ option: StatusBarController.PromptPresetOption,
        to settingsStore: SettingsStore
    ) -> Bool {
        guard settingsStore.assignment(for: .transcriptionEnhancement) != nil else {
            return false
        }

        // The legacy pointer stores the SwiftData row UUID, while v2 assignments use
        // stable built-in identifiers when available.
        settingsStore.enhanceTranscriptsPresetID = option.assignmentID
        settingsStore.selectedPresetId = option.id
        return true
    }

    private func handleSelectPromptPreset(_ option: StatusBarController.PromptPresetOption) {
        guard Self.applyPromptPresetSelection(option, to: settingsStore) else {
            Log.app.warning("Ignored prompt preset selection while AI enhancement is disabled")
            return
        }

        Log.app.info("Prompt preset changed to: \(option.name)")
        statusBarController.updateDynamicItems()
    }

    // MARK: - Toggle Launch at Login

    private func handleToggleLaunchAtLogin() {
        let newValue = !settingsStore.launchAtLogin
        do {
            try launchAtLoginManager.setEnabled(newValue)
            settingsStore.launchAtLogin = newValue
            let status = newValue ? "enabled" : "disabled"
            Log.app.info("Launch at login \(status)")
        } catch {
            Log.app.error("Failed to toggle launch at login: \(error)")
        }
    }

    private func handleCheckForUpdates() {
        if updateService.shouldDeferUpdate(isRecording: isRecording || isProcessing) {
            AlertManager.shared.showGenericErrorAlert(
                title: "Update Deferred",
                message: "Finish recording or processing before checking for updates."
            )
            return
        }

        updateService.checkForUpdates()
    }

    // MARK: - Open Library

    private func handleOpenLibrary() {
        mainWindowController.navigate(to: .library)
    }

    // MARK: - Show App

    private func handleShowApp() {
        mainWindowController.show()
    }

    // MARK: - Main Menu Actions

    func openNewNoteFromMenu() {
        noteEditorWindowController.show(note: nil, isNewNote: true)
    }

    func exportLastTranscriptFromMenu() async {
        await handleExportLastTranscript()
    }

    func switchToModel(named modelName: String) async {
        guard modelName != activeModelName else {
            Log.app.info("Model \(modelName) is already active")
            return
        }
        
        guard !isRecording && !isProcessing else {
            Log.app.warning("Cannot switch model while recording or processing")
            return
        }
        
        Log.app.info("Switching to model: \(modelName)")
        
        await modelManager.refreshDownloadedModels()
        guard let model = modelManager.availableModels.first(where: { $0.name == modelName }) else {
            Log.app.error("Cannot switch to model \(modelName): not found")
            return
        }
        
        if !modelManager.isModelDownloaded(modelName) {
            Log.app.error("Cannot switch to model \(modelName): not downloaded")
            return
        }
        
        splashController.setLoading("Switching to \(model.displayName)...")
        
        do {
            try await loadAndActivateModel(named: modelName, provider: model.provider)
            settingsStore.selectedModel = modelName
            statusBarController.updateDynamicItems()
            Log.model.info("Switched to model \(modelName) successfully")
        } catch {
            if model.provider == .whisperKit {
                do {
                    try await attemptWhisperModelRepairAndReload(
                        modelName: modelName,
                        displayName: model.displayName,
                        loadError: error
                    )
                    settingsStore.selectedModel = modelName
                    statusBarController.updateDynamicItems()
                    Log.model.info("Model repaired and switched successfully: \(modelName)")
                    return
                } catch {
                    handleModelLoadError(error, context: "Failed to repair switched model")
                    AlertManager.shared.showModelLoadErrorAlert(error: error)
                    return
                }
            }

            handleModelLoadError(error, context: "Failed to switch model")
            AlertManager.shared.showModelLoadErrorAlert(error: error)
        }
    }
    
    // MARK: - Update Recent Transcripts

    private func updateRecentTranscriptsMenu() {
        Task {
            do {
                let records = try historyStore.fetch(limit: 5)
                let transcripts = records.map { (id: $0.id, text: $0.text, timestamp: $0.timestamp) }
                await MainActor.run {
                    statusBarController.updateRecentTranscripts(transcripts)
                }
            } catch {
                Log.app.error("Failed to update recent transcripts: \(error)")
            }
        }
    }

    func shutdown() {
        guard !isShutdown else { return }
        let shutdownStreamingSessionToken = activeStreamingSessionToken
        let shutdownVoiceNoteHandle = voiceNoteCaptureContext?.handle
        if let shutdownStreamingSessionToken,
           activeStreamingSessionToken == shutdownStreamingSessionToken {
            activeStreamingSessionToken = nil
        }
        isShutdown = true
        recordingState.invalidateCaptureStart()
        mainWindowCaptureStartTask?.cancel()
        mainWindowCaptureStartTask = nil

        // Stop Carbon callbacks first. The sources must be disabled and detached on
        // their owning run loop before the pass-unretained coordinator refcon can die.
        liveContextKeyRefreshGate.setEnabled(false)
        escapeEventState.setShouldSuppress(false)
        teardownEscapeKeyMonitor()
        teardownModifierKeyMonitor()
        removeEscapeGlobalMonitorFallbackIfNeeded()
        removeModifierGlobalMonitorFallbackIfNeeded()
        eventTapRunLoopThread.stopIfNeeded()

        notificationResources.tearDown()
        cancellables.removeAll()
        cancelPendingNoteAppendStart()
        cancelPendingMeetingCaptureStart()
        if let handle = pendingMeetingCaptureStartHandle {
            do {
                try captureSessionStore.interruptMeetingCapture(
                    handle,
                    errorDomain: "Pindrop",
                    errorCode: "lifecycle-sync-shutdown",
                    message: "Meeting capture was interrupted before startup completed.",
                    at: .now
                )
            } catch {
                reportMeetingCaptureTerminalPersistenceFailure(error)
            }
        }
        cancelActiveVoiceNoteCapture()
        meetingRecoveryGeneration &+= 1
        meetingRecoveryTask?.cancel()
        meetingRecoveryTask = nil
        meetingRecoveryHandle = nil
        let interruptedMeeting = meetingCaptureContext
        if let interruptedMeeting {
            // `prepareForTermination()` normally owns and awaits tail sealing. This
            // synchronous fallback must not launch background work during teardown;
            // it can only persist an interruption against the exact active handle.
            do {
                try captureSessionStore.beginMeetingFinalization(interruptedMeeting.handle, at: .now)
                try captureSessionStore.interruptMeetingCapture(
                    interruptedMeeting.handle,
                    errorDomain: "Pindrop",
                    errorCode: "lifecycle-sync-shutdown",
                    message: "Meeting capture was interrupted before its tail could be sealed.",
                    at: .now
                )
            } catch {
                Log.app.warning("Could not persist synchronous meeting interruption: \(error.localizedDescription)")
            }
            meetingCaptureContext = nil
        }
        escapeEventTapRecoveryTask = nil
        modifierEventTapRecoveryTask?.cancel()
        modifierEventTapRecoveryTask = nil

        stopLiveContextSession()
        operationController.cancel()
        recordingStopAdmission.invalidateCurrentClaim()
        activeOperationTask?.cancel()
        activeOperationTask = nil

        mediaTranscriptionGeneration &+= 1
        mediaTranscriptionTask?.cancel()
        mediaQueueRestoreRequested = false
        mediaQueueNeedsProcessingReset = false
        mediaQueueDeferredUntilIdle = false
        mediaTranscriptionState.clearAllJobs()

        if let shutdownStreamingSessionToken {
            streamingSession.cancelDetached(session: shutdownStreamingSessionToken)
        }
        if let shutdownVoiceNoteHandle {
            streamingSession.cancelArtifactCaptureDetached(for: shutdownVoiceNoteHandle)
        } else {
            // Application shutdown has no successor, so terminal cleanup may safely
            // abort any unowned artifact lifecycle left by a failed admission.
            streamingSession.cancelDetached()
        }
        if interruptedMeeting == nil {
            audioRecorder.resetAudioEngine()
        }
        mediaPauseService.endRecordingSession()
        isRecording = false
        isProcessing = false
        isRecordingFeatureCaptureActive = false
        automaticDictionaryLearningService.cancelObservation()

        inputMuteMonitor?.stop()
        inputMuteMonitor = nil
        inputDeviceListMonitor?.stop()
        inputDeviceListMonitor = nil
        floatingIndicatorFocusTracker.stop()

        hotkeyManager.unregisterAll()
        stopMCPServerIfRunning()
        dictationAudioRetentionService.stopPeriodicSweep()
    }
}
