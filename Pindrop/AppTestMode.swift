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
    /// The note page with all three views populated: typed notes, one enhanced
    /// panel with citations, and a finished transcript.
    case notePage
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
        case .notePage:
            NotePageFixtureRootView()
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
        let schema = Schema(versionedSchema: TranscriptionRecordSchemaV15.self)
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
        let schema = Schema(versionedSchema: TranscriptionRecordSchemaV15.self)
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
            onStopDictation: {
                callbackMarker = "dictate-stop"
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

/// One recorded capture, seeded into a fresh in-memory V15 store.
///
/// Both note fixtures need the same thing behind the note they draw: a finished
/// meeting capture, a human anchor note with typed content, a sealed chunk, and
/// one diarized transcript revision. Seeding it once means the citation fixture
/// and the note-page fixture cannot drift apart, and neither one touches the
/// person's real notes or capture history.
@MainActor
enum RecordedNoteFixture {
    static let transcriptText =
        "We will publish the final report on Friday. The launch checklist needs legal approval."
    static let typedContent = "Confirm the release timeline before publishing."

    struct Seeded {
        let container: ModelContainer
        let store: CaptureSessionStore
        let handle: NoteCaptureHandle
        let noteID: UUID
        let createdAt: Date
        /// The evidence a generated note cites, built from the seeded transcript.
        let source: MeetingNoteSourceBundle
    }

    static func seed(title: String, label: String) throws -> Seeded {
        let schema = Schema(versionedSchema: TranscriptionRecordSchemaV15.self)
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let createdAt = Date(timeIntervalSinceReferenceDate: 0)

        let container = try ModelContainer(for: schema, configurations: [configuration])
        let store = CaptureSessionStore(modelContext: ModelContext(container))
        let handle = try store.startMeetingCapture(startedAt: createdAt)
        let anchor = try store.ensureMeetingHumanAnchor(handle, title: title, at: createdAt)

        let anchorContext = ModelContext(container)
        guard let anchorNote = try anchorContext.fetch(FetchDescriptor<NoteSchema.Note>())
            .first(where: { $0.id == anchor.noteID })
        else {
            throw NoteFixtureError.anchorNoteMissing
        }
        anchorNote.content = typedContent
        try anchorContext.save()
        guard let populatedAnchor = try store.meetingHumanAnchor(handle) else {
            throw NoteFixtureError.anchorNoteMissing
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
                    providerIdentifier: label,
                    modelIdentifier: label,
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
            text: transcriptText,
            segmentsJSON: segmentsJSON,
            assignmentAttempt: 1
        )
        let historyID = try store.reserveMeetingTranscriptionRecordID(handle)
        let context = ModelContext(container)
        context.insert(TranscriptionRecord(
            id: historyID,
            text: transcriptText,
            duration: checkpoint.duration,
            modelUsed: label
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
                    providerIdentifier: label,
                    modelIdentifier: label,
                    prompt: CapturePromptSnapshot(
                        presetIdentifier: label,
                        resolvedPrompt: label
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
                    text: transcriptText,
                    segmentsJSON: segmentsJSON,
                    languageCode: nil
                )
            ]
        )

        return Seeded(
            container: container,
            store: store,
            handle: handle,
            noteID: anchor.noteID,
            createdAt: createdAt,
            source: source
        )
    }

    /// The note-page fixture: a recorded note with typed content, one enhanced
    /// panel that cites the transcript, and the transcript itself.
    ///
    /// Written as a throwing function rather than inline in the view so a unit
    /// test can seed it too. The view turns a failure into `fatalError`, which
    /// would otherwise only surface as a crashed CI UI test.
    static func seedNotePage() throws -> (container: ModelContainer, noteID: UUID) {
        let seeded = try seed(title: notePageTitle, label: notePageTemplateDisplayName)
        let provenance = MeetingGeneratedNoteProvenance(
            humanAnchorNoteID: seeded.noteID,
            evidenceInput: seeded.source.evidenceInput,
            citations: seeded.source.citations,
            sourceTranscriptRevisionIDs: seeded.source.sourceTranscriptRevisionIDs
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let provenanceJSON = String(decoding: try encoder.encode(provenance), as: UTF8.self)

        _ = try seeded.store.saveEnhancedPanel(
            sessionID: seeded.handle.sessionID,
            noteID: seeded.noteID,
            templatePresetIdentifier: notePageTemplateIdentifier,
            templateDisplayName: notePageTemplateDisplayName,
            content: notePagePanelContent,
            assignmentAttempt: 1,
            provenanceJSON: provenanceJSON,
            humanAnchorContentSnapshot: typedContent,
            at: seeded.createdAt
        )
        return (seeded.container, seeded.noteID)
    }

    static let notePageTitle = "Weekly planning"
    static let notePageTemplateIdentifier = "meeting-summary"
    static let notePageTemplateDisplayName = "Meeting summary"
    static let notePagePanelContent =
        "## Decisions\n\nPublish the final report on Friday. [1]\n\nComplete legal review before launch. [2]"

    enum NoteFixtureError: Error {
        case anchorNoteMissing
    }
}

private struct NoteEditorCitationsFixtureRootView: View {

    /// A seeded V15 store makes the real citation panel stable without accessing
    /// the user's persistent notes or capture history.
    private static let fixture: (modelContainer: ModelContainer, noteID: UUID) = {
        do {
            let seeded = try RecordedNoteFixture.seed(
                title: "Generated meeting note",
                label: "Generated meeting note"
            )
            let generated = try seeded.store.saveGeneratedMeetingNote(
                seeded.handle,
                title: "Generated meeting note",
                content: "## Decisions\n\nPublish the final report on Friday.\n\nComplete legal review before launch.",
                source: seeded.source,
                at: seeded.createdAt
            )
            return (seeded.container, generated.noteID)
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

/// The note page with typed notes, one enhanced panel, and a transcript.
///
/// Everything the page draws comes from the same seeded capture the citation
/// fixture uses, so the three view segments, the template menu, and the citation
/// chips all resolve against real store reads rather than stubs.
private struct NotePageFixtureRootView: View {
    private static let fixture: (container: ModelContainer, noteID: UUID) = {
        do {
            return try RecordedNoteFixture.seedNotePage()
        } catch {
            fatalError("Failed to create and seed note-page UI-test fixture: \(error)")
        }
    }()

    var body: some View {
        NotePageView(noteID: Self.fixture.noteID, onBack: {})
            .frame(width: 900, height: 680)
            .modelContainer(Self.fixture.container)
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
