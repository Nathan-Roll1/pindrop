//
//  MediaTranscriptionTypes.swift
//  Pindrop
//
//  Created on 2026-03-07.
//
//  App-owned observable feature state and localized presentation helpers.
//  Shared value types live in PindropCore / PindropSpeech.
//

import Foundation
import Observation
import PindropCore
import PindropSpeech

// MARK: - Presentation

extension TranscribeOutputFormat {
    var displayName: String {
        switch self {
        case .plainText:  return "Plain Text (.txt)"
        case .subtitles:  return "Subtitles (.srt)"
        case .timestamps: return "Timestamps (.json)"
        }
    }
}

extension MediaLibrarySortMode {
    var title: String {
        switch self {
        case .newest:
            return "Newest"
        case .oldest:
            return "Oldest"
        case .nameAscending:
            return "Name A-Z"
        case .nameDescending:
            return "Name Z-A"
        }
    }

    func title(locale: Locale) -> String {
        localized(title, locale: locale)
    }
}

extension MediaTranscriptionStage {
    var title: String {
        switch self {
        case .preflight:
            return "Checking setup"
        case .preparingModel:
            return "Loading model"
        case .importing:
            return "Importing media"
        case .downloading:
            return "Downloading media"
        case .preparingAudio:
            return "Preparing audio"
        case .transcribing:
            return "Transcribing"
        case .saving:
            return "Saving"
        case .completed:
            return "Finished"
        case .failed:
            return "Failed"
        }
    }

    func title(locale: Locale) -> String {
        localized(title, locale: locale)
    }
}

extension MediaTranscriptionRequest {
    var displayName: String {
        switch self {
        case .file(let url):
            return url.lastPathComponent
        case .link(let string):
            return string
        case .manualCapture(let modeRawValue):
            if let mode = AudioRecordingMode(rawValue: modeRawValue) {
                return mode.libraryDisplayName
            }
            return modeRawValue
        }
    }
}

extension AudioRecordingMode {
    var title: String {
        switch self {
        case .microphone:
            return "Microphone"
        case .systemAudio:
            return "System Audio"
        case .microphoneAndSystemAudio:
            return "Both"
        }
    }

    var description: String {
        switch self {
        case .microphone:
            return "Capture your microphone only."
        case .systemAudio:
            return "Capture system audio from the active call or meeting."
        case .microphoneAndSystemAudio:
            return "Capture system audio and your microphone into one mixed recording."
        }
    }

    func title(locale: Locale) -> String {
        localized(title, locale: locale)
    }

    func description(locale: Locale) -> String {
        localized(description, locale: locale)
    }
}

// MARK: - Feature UI State

@MainActor
@Observable
final class MediaTranscriptionFeatureState {
    var route: MediaTranscriptionRoute = .library
    var selectedRecordID: UUID?
    var selectedFolderID: UUID?
    var currentJob: MediaTranscriptionJobState?
    var pendingJobs: [MediaTranscriptionJobState] = []
    var completedJobs: [MediaTranscriptionJobState] = []
    var draftLink: String = ""
    var hasUserEditedDraftLink = false
    var librarySearchText: String = ""
    var librarySortMode: MediaLibrarySortMode = .newest
    var setupIssue: String?
    var isDiarizationModelDownloading = false
    var diarizationModelDownloadProgress: Double = 0.0
    var libraryMessage: String?

    func beginJob(_ job: MediaTranscriptionJobState) {
        currentJob = job
        setupIssue = nil
        libraryMessage = nil
        route = .processing(job.id)
    }

    func updateJob(
        stage: MediaTranscriptionStage,
        progress: Double? = nil,
        detail: String? = nil,
        errorMessage: String? = nil
    ) {
        guard var job = currentJob else { return }
        job.stage = stage
        job.progress = progress
        if let detail {
            job.detail = detail
        }
        job.errorMessage = errorMessage
        currentJob = job
    }

    func exitProcessingView() {
        route = .library
    }

    func selectRecord(_ id: UUID) {
        selectedRecordID = id
        route = .detail(id)
        libraryMessage = nil
    }

    func showLibrary() {
        route = .library
    }

    func selectFolder(_ id: UUID) {
        selectedFolderID = id
        libraryMessage = nil
    }

    func clearSelectedFolder() {
        selectedFolderID = nil
    }

    func handleDeletedRecord(_ id: UUID, message: String = "Transcription deleted.") {
        if selectedRecordID == id {
            selectedRecordID = nil
        }

        if case .detail(let recordID) = route, recordID == id {
            route = .library
        }

        libraryMessage = message
    }

    func handleDeletedFolder(_ id: UUID, message: String = "Folder deleted.") {
        if selectedFolderID == id {
            selectedFolderID = nil
        }
        libraryMessage = message
    }

    func completeCurrentJob(with recordID: UUID, shouldNavigateToDetail: Bool) {
        guard var job = currentJob else { return }
        job.stage = .completed
        job.progress = 1.0
        job.detail = "Finished"
        job.resultRecordID = recordID
        completedJobs.append(job)
        currentJob = nil
        selectedRecordID = recordID
        if shouldNavigateToDetail {
            route = .detail(recordID)
        } else {
            route = .library
        }
    }

    func failCurrentJob(_ message: String, returnToLibrary: Bool) {
        guard var job = currentJob else { return }
        job.stage = .failed
        job.progress = nil
        job.errorMessage = message
        completedJobs.append(job)
        currentJob = nil
        if returnToLibrary {
            route = .library
        }
    }

    func clearCurrentJob() {
        currentJob = nil
    }

    // MARK: - Queue management

    func enqueue(_ job: MediaTranscriptionJobState) {
        pendingJobs.append(job)
    }

    func dequeueNextJob() -> MediaTranscriptionJobState? {
        guard !pendingJobs.isEmpty else { return nil }
        return pendingJobs.removeFirst()
    }

    func clearAllJobs() {
        currentJob = nil
        pendingJobs.removeAll()
        completedJobs.removeAll()
        route = .library
    }

    func setSetupIssue(_ message: String) {
        setupIssue = message
        route = .library
    }

    func updateDraftLinkFromClipboard(_ candidate: String) {
        guard !hasUserEditedDraftLink else { return }
        let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, draftLink != trimmed else { return }
        draftLink = trimmed
    }
}

@MainActor
@Observable
final class RecordingFeatureState {
    var selectedCaptureMode: AudioRecordingMode = .systemAudio
    var isRecording = false
    var recordingStartedAt: Date?
    var audioLevel: Float = 0.0
    var isDiarizationModelDownloading = false
    var diarizationModelDownloadProgress: Double = 0.0
    var currentJob: MediaTranscriptionJobState?
    var setupIssue: String?
    var message: String?
    var lastCompletedRecordID: UUID?

    func beginRecording(mode: AudioRecordingMode, startedAt: Date = Date()) {
        selectedCaptureMode = mode
        isRecording = true
        recordingStartedAt = startedAt
        lastCompletedRecordID = nil
        setupIssue = nil
        message = nil
    }

    func endRecording(message: String? = nil) {
        isRecording = false
        recordingStartedAt = nil
        if let message {
            self.message = message
        }
    }

    func beginJob(_ job: MediaTranscriptionJobState) {
        currentJob = job
        lastCompletedRecordID = nil
        setupIssue = nil
        message = nil
    }

    func updateJob(
        stage: MediaTranscriptionStage,
        progress: Double? = nil,
        detail: String? = nil,
        errorMessage: String? = nil
    ) {
        guard var job = currentJob else { return }
        job.stage = stage
        job.progress = progress
        if let detail {
            job.detail = detail
        }
        job.errorMessage = errorMessage
        currentJob = job
    }

    func clearCurrentJob() {
        currentJob = nil
    }

    func completeCurrentJob(with recordID: UUID, message: String) {
        lastCompletedRecordID = recordID
        currentJob = nil
        self.message = message
    }

    func failCurrentJob(_ message: String) {
        currentJob = nil
        self.message = message
    }

    func setSetupIssue(_ message: String) {
        setupIssue = message
    }
}
