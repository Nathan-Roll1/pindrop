//
//  MediaTranscriptionTypes.swift
//  PindropCore
//
//  Created on 2026-07-22.
//

import Foundation

// MARK: - Output Format

public enum TranscribeOutputFormat: String, CaseIterable, Sendable, Equatable {
    case plainText
    case subtitles   // .srt
    case timestamps  // .json
}

// MARK: - Per-job Options

public struct TranscriptionJobOptions: Sendable, Equatable {
    public var modelName: String
    public var language: AppLanguage
    public var outputFormat: TranscribeOutputFormat
    public var diarizationEnabled: Bool
    /// Optional exact speaker-count hint for offline diarization (`1...20`).
    /// `nil` means automatic detection. Validated at the transcription service boundary.
    public var expectedSpeakerCount: Int?

    public init(
        modelName: String,
        language: AppLanguage = .automatic,
        outputFormat: TranscribeOutputFormat = .plainText,
        diarizationEnabled: Bool = true,
        expectedSpeakerCount: Int? = nil
    ) {
        self.modelName = modelName
        self.language = language
        self.outputFormat = outputFormat
        self.diarizationEnabled = diarizationEnabled
        self.expectedSpeakerCount = expectedSpeakerCount
    }
}

// MARK: -

public enum MediaLibrarySortMode: String, CaseIterable, Equatable, Sendable {
    case newest
    case oldest
    case nameAscending
    case nameDescending
}

public enum MediaTranscriptionStage: String, CaseIterable, Equatable, Sendable {
    case preflight
    case preparingModel
    case importing
    case downloading
    case preparingAudio
    case transcribing
    case saving
    case completed
    case failed
}

public enum MediaTranscriptionRoute: Equatable, Sendable {
    case library
    case processing(UUID)
    case detail(UUID)
}

public enum MediaTranscriptionRequest: Sendable, Equatable {
    case file(URL)
    case link(String)
    /// Manual capture mode as `AudioRecordingMode.rawValue`
    /// (`microphone` / `systemAudio` / `microphoneAndSystemAudio`).
    case manualCapture(String)

    public var sourceKind: MediaSourceKind {
        switch self {
        case .file:
            return .importedFile
        case .link:
            return .webLink
        case .manualCapture:
            return .manualCapture
        }
    }
}

public struct MediaTranscriptionJobState: Identifiable, Equatable, Sendable {
    public let id: UUID
    public var request: MediaTranscriptionRequest
    public var options: TranscriptionJobOptions
    public var destinationFolderID: UUID?
    public var stage: MediaTranscriptionStage
    public var progress: Double?
    public var detail: String
    public var errorMessage: String?
    public var startedAt: Date
    /// Set when the job completes successfully; contains the saved TranscriptionRecord's ID.
    public var resultRecordID: UUID?

    public init(
        id: UUID = UUID(),
        request: MediaTranscriptionRequest,
        options: TranscriptionJobOptions = TranscriptionJobOptions(modelName: ""),
        destinationFolderID: UUID? = nil,
        stage: MediaTranscriptionStage = .preflight,
        progress: Double? = nil,
        detail: String = "",
        errorMessage: String? = nil,
        startedAt: Date = Date(),
        resultRecordID: UUID? = nil
    ) {
        self.id = id
        self.request = request
        self.options = options
        self.destinationFolderID = destinationFolderID
        self.stage = stage
        self.progress = progress
        self.detail = detail
        self.errorMessage = errorMessage
        self.startedAt = startedAt
        self.resultRecordID = resultRecordID
    }
}
