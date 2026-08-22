//
//  AppTestMode.swift
//  Pindrop
//
//  Created on 2026-03-21.
//

import AppKit
import Foundation
import PindropCore
import PindropData
import SwiftData
import SwiftUI

enum AppTestMode {
    static let unitTestModeKey = "PINDROP_TEST_MODE"
    static let uiTestModeKey = "PINDROP_UI_TEST_MODE"
    static let uiTestSurfaceKey = "PINDROP_UI_TEST_SURFACE"
    static let uiTestSettingsTabKey = "PINDROP_UI_TEST_SETTINGS_TAB"
    static let testUserDefaultsSuiteKey = "PINDROP_TEST_USER_DEFAULTS_SUITE"
    static let uiTestCaptureStartPendingKey = "PINDROP_UI_TEST_CAPTURE_START_PENDING"

    static var environment: [String: String] {
        ProcessInfo.processInfo.environment
    }

    static var isRunningUITests: Bool {
        environment[uiTestModeKey] == "1"
    }

    static var isRunningUnitTests: Bool {
        !isRunningUITests && (
            environment[unitTestModeKey] == "1"
                || environment["XCTestConfigurationFilePath"] != nil
        )
    }

    static var isRunningAnyTests: Bool {
        isRunningUITests || isRunningUnitTests
    }
}

enum AppUITestSurface: String {
    case settings
    case noteEditorCitations
    case mainShell
}

enum AppUITestFixture {
    static var isEnabled: Bool {
        surface != nil
    }

    static var surface: AppUITestSurface? {
        guard AppTestMode.isRunningUITests else { return nil }
        let rawValue = AppTestMode.environment[AppTestMode.uiTestSurfaceKey] ?? AppUITestSurface.settings.rawValue
        return AppUITestSurface(rawValue: rawValue)
    }

    static var settingsInitialTab: SettingsTab {
        let rawValue = AppTestMode.environment[AppTestMode.uiTestSettingsTabKey]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return SettingsTab(rawValue: rawValue ?? "") ?? .general
    }

    @MainActor
    @ViewBuilder
    static func rootView() -> some View {
        switch surface {
        case .settings:
            SettingsFixtureRootView(initialTab: settingsInitialTab)
        case .noteEditorCitations:
            NoteEditorCitationsFixtureRootView()
        case .mainShell:
            MainShellFixtureRootView()
        case nil:
            EmptyView()
        }
    }

    @MainActor
    static func configureApplication() {
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }
}

private struct SettingsFixtureRootView: View {
    @StateObject private var settings = SettingsStore()

    let initialTab: SettingsTab

    /// Deterministic in-memory store so panes using @Query (e.g. Privacy) render
    /// in the fixture without touching the real persistent store.
    private static let modelContainer: ModelContainer = {
        let schema = Schema(versionedSchema: TranscriptionRecordSchemaV14.self)
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        do {
            return try ModelContainer(for: schema, configurations: [configuration])
        } catch {
            fatalError("Failed to create UI-test fixture model container: \(error)")
        }
    }()

    var body: some View {
        SettingsPaneContent(settings: settings, tab: initialTab)
            .frame(minWidth: 620, minHeight: 420)
            .environment(\.locale, settings.selectedAppLocale.locale)
            .environment(\.layoutDirection, settings.selectedAppLocale.layoutDirection)
            .modelContainer(Self.modelContainer)
    }
}

@MainActor
private struct MainShellFixtureRootView: View {
    @StateObject private var settings: SettingsStore
    @StateObject private var floatingIndicatorState: FloatingIndicatorState
    @State private var routeState: MainWindowRouteState
    @State private var mediaTranscriptionState: MediaTranscriptionFeatureState
    @State private var recordingState: RecordingFeatureState
    @State private var callbackMarker = "ready"

    private static let modelContainer: ModelContainer = {
        let schema = Schema(versionedSchema: TranscriptionRecordSchemaV14.self)
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        do {
            return try ModelContainer(for: schema, configurations: [configuration])
        } catch {
            fatalError("Failed to create main-shell UI-test fixture model container: \(error)")
        }
    }()

    init() {
        let settings = SettingsStore()
        settings.sidebarExpanded = true
        settings.selectedSidebarPosition = .leading

        let recordingState = RecordingFeatureState()
        if AppTestMode.environment[AppTestMode.uiTestCaptureStartPendingKey] == "1" {
            _ = recordingState.claimCaptureStart()
        }

        _settings = StateObject(wrappedValue: settings)
        _floatingIndicatorState = StateObject(wrappedValue: FloatingIndicatorState())
        _routeState = State(initialValue: MainWindowRouteState())
        _mediaTranscriptionState = State(initialValue: MediaTranscriptionFeatureState())
        _recordingState = State(initialValue: recordingState)
    }

    var body: some View {
        MainWindow(
            settingsStore: settings,
            routeState: routeState,
            floatingIndicatorState: floatingIndicatorState,
            mediaTranscriptionState: mediaTranscriptionState,
            recordingState: recordingState,
            modelManager: nil,
            onImportMediaFiles: nil,
            onSubmitMediaLink: nil,
            onDownloadDiarizationModel: nil,
            onStartDictation: {
                callbackMarker = "dictate"
            },
            onStartNoteCapture: { request in
                let sources = request.includeSystemAudio ? "mic+system" : "mic"
                let speakers = request.expectedSpeakerCount.map(String.init) ?? "auto"
                callbackMarker = "note-capture:\(sources):\(speakers)"
                return true
            },
            onOpenSettings: { tab in
                callbackMarker = "settings:\(tab.rawValue)"
            }
        )
        .frame(width: 980, height: 640)
        .overlay(alignment: .bottomTrailing) {
            Text(callbackMarker)
                .padding(8)
                .accessibilityLabel(callbackMarker)
                .accessibilityIdentifier("mainShell.callback.\(callbackMarker)")
        }
        .modelContainer(Self.modelContainer)
    }
}

private struct NoteEditorCitationsFixtureRootView: View {

    /// A seeded V14 store makes the real citation panel stable without accessing
    /// the user's persistent notes or capture history.
    private static let fixture: (modelContainer: ModelContainer, noteID: UUID) = {
        let schema = Schema(versionedSchema: TranscriptionRecordSchemaV14.self)
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let createdAt = Date(timeIntervalSinceReferenceDate: 0)

        do {
            let container = try ModelContainer(for: schema, configurations: [configuration])
            let store = CaptureSessionStore(modelContext: ModelContext(container))
            let handle = try store.startMeetingCapture(startedAt: createdAt)
            let anchor = try store.ensureMeetingHumanAnchor(
                handle,
                title: "Generated meeting note",
                at: createdAt
            )
            let humanAnchorContent = "Confirm the release timeline before publishing."
            let anchorContext = ModelContext(container)
            guard let anchorNote = try anchorContext.fetch(FetchDescriptor<NoteSchema.Note>())
                .first(where: { $0.id == anchor.noteID })
            else {
                fatalError("Failed to find the seeded human anchor note.")
            }
            anchorNote.content = humanAnchorContent
            try anchorContext.save()
            guard let populatedAnchor = try store.meetingHumanAnchor(handle) else {
                fatalError("Failed to reload the seeded human anchor note.")
            }
            try store.beginMeetingFinalization(handle, at: createdAt)
            let checkpoint = MeetingChunkCheckpoint(
                sourceID: handle.microphoneSourceID,
                sequence: 0,
                startOffset: 0,
                duration: MeetingCaptureSpoolPlan.chunkDuration,
                managedMediaPath: CaptureSourceArtifactPath.relativePath(
                    sessionID: handle.sessionID,
                    sourceID: handle.microphoneSourceID,
                    chunkSequence: 0
                ),
                byteCount: MeetingCaptureSpoolPlan.defaultChunkByteCount,
                sha256: String(repeating: "a", count: 64),
                sealedAt: createdAt
            )
            try store.recordSealedMeetingChunk(handle, checkpoint: checkpoint)
            _ = try store.resolveAssignment(
                sessionID: handle.sessionID,
                stage: .finalTranscription,
                attempt: 1,
                selecting: {
                    try CaptureStageAssignment(
                        stage: .finalTranscription,
                        providerKind: .batchSpeech,
                        providerIdentifier: "Generated meeting note",
                        modelIdentifier: "Generated meeting note",
                        prompt: nil,
                        selectedAt: createdAt,
                        attempt: 1
                    )
                }
            )
            let segmentsJSON = String(
                decoding: try JSONEncoder().encode([
                    DiarizedTranscriptSegment(
                        speakerId: "Alex",
                        speakerLabel: "Alex",
                        startTime: 5,
                        endTime: 18,
                        confidence: 1,
                        text: "We will publish the final report on Friday."
                    ),
                    DiarizedTranscriptSegment(
                        speakerId: "Jordan",
                        speakerLabel: "Jordan",
                        startTime: 22,
                        endTime: 34,
                        confidence: 1,
                        text: "The launch checklist needs legal approval."
                    )
                ]),
                as: UTF8.self
            )
            let revisionID = try store.recordMeetingTranscriptionChunk(
                handle,
                sourceChunkSequence: checkpoint.sequence,
                startOffset: checkpoint.startOffset,
                duration: checkpoint.duration,
                text: "We will publish the final report on Friday. The launch checklist needs legal approval.",
                segmentsJSON: segmentsJSON,
                assignmentAttempt: 1
            )
            let historyID = try store.reserveMeetingTranscriptionRecordID(handle)
            let context = ModelContext(container)
            context.insert(TranscriptionRecord(
                id: historyID,
                text: "We will publish the final report on Friday. The launch checklist needs legal approval.",
                duration: checkpoint.duration,
                modelUsed: "Generated meeting note"
            ))
            try context.save()
            _ = try store.resolveAssignment(
                sessionID: handle.sessionID,
                stage: .noteGeneration,
                attempt: 1,
                selecting: {
                    try CaptureStageAssignment(
                        stage: .noteGeneration,
                        providerKind: .generativeAI,
                        providerIdentifier: "Generated meeting note",
                        modelIdentifier: "Generated meeting note",
                        prompt: CapturePromptSnapshot(
                            presetIdentifier: "Generated meeting note",
                            resolvedPrompt: "Generated meeting note"
                        ),
                        selectedAt: createdAt,
                        attempt: 1
                    )
                }
            )
            let source = try MeetingNoteDerivation.make(
                humanNoteContent: populatedAnchor.content,
                checkpoints: [
                    MeetingTranscriptionCheckpoint(
                        revisionID: revisionID,
                        providerSnapshotID: nil,
                        sequence: checkpoint.sequence,
                        startOffset: checkpoint.startOffset,
                        duration: checkpoint.duration,
                        text: "We will publish the final report on Friday. The launch checklist needs legal approval.",
                        segmentsJSON: segmentsJSON,
                        languageCode: nil
                    )
                ]
            )
            let generated = try store.saveGeneratedMeetingNote(
                handle,
                title: "Generated meeting note",
                content: "## Decisions\n\nPublish the final report on Friday.\n\nComplete legal review before launch.",
                source: source,
                at: createdAt
            )
            return (container, generated.noteID)
        } catch {
            fatalError("Failed to create and seed note-editor citation UI-test fixture: \(error)")
        }
    }()

    var body: some View {
        NoteEditorCitationsFixtureContentView(noteID: Self.fixture.noteID)
            .frame(width: 480, height: 560)
            .modelContainer(Self.fixture.modelContainer)
    }
}

private struct NoteEditorCitationsFixtureContentView: View {
    @Query private var notes: [NoteSchema.Note]

    init(noteID: UUID) {
        _notes = Query(
            filter: #Predicate<NoteSchema.Note> { $0.id == noteID }
        )
    }

    var body: some View {
        if let note = notes.first {
            NoteEditorView(
                note: note,
                isNewNote: false,
                onClose: {},
                onSave: { _ in }
            )
        } else {
            ProgressView()
        }
    }
}
