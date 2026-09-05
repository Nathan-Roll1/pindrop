//
//  NoteEnhancementServiceTests.swift
//  PindropTests
//
//  Created on 2026-08-22.
//

import Foundation
import PindropAI
import PindropCore
import PindropData
import PindropSpeech
import SwiftData
import Testing

@testable import Pindrop

@MainActor
@Suite(.serialized)
struct NoteEnhancementServiceTests {

    // MARK: - Fixture

    private struct Fixture {
        let container: ModelContainer
        let settings: SettingsStore
        let captureSessionStore: CaptureSessionStore
        let notesStore: NotesStore
        let promptPresetStore: PromptPresetStore
        let session: StubEnhancementProviderSession
        let sut: NoteEnhancementService
        let handle: NoteCaptureHandle
        let noteID: UUID
        let typedContent: String
        let root: URL
        let cleanup: () -> Void
    }

    private func requestBody(from session: StubEnhancementProviderSession) throws -> [String: Any] {
        let body = try #require(session.lastRequest?.httpBody)
        return try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
    }

    private func chunk(
        _ sourceID: UUID,
        sessionID: UUID,
        sequence: Int,
        sealedAt: Date
    ) -> MeetingChunkCheckpoint {
        let byteCount = MeetingCaptureSpoolPlan.defaultChunkByteCount
        let duration = Double(byteCount) /
            Double(MeetingCaptureSpoolPlan.sampleRate * MeetingCaptureSpoolPlan.bytesPerSample)
        return MeetingChunkCheckpoint(
            sourceID: sourceID,
            sequence: sequence,
            startOffset: Double(sequence) * duration,
            duration: duration,
            managedMediaPath: CaptureSourceArtifactPath.relativePath(
                sessionID: sessionID,
                sourceID: sourceID,
                chunkSequence: sequence
            ),
            byteCount: byteCount,
            sha256: String(format: "%064x", sequence + 1),
            sealedAt: sealedAt
        )
    }

    private func makeFixture(
        typedContent: String = "Ship notes I typed myself.",
        recordTranscript: Bool = true,
        configureProvider: Bool = true
    ) throws -> Fixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("pindrop-note-enhancement-\(UUID().uuidString)", isDirectory: true)
        let applicationSupportRoot = root.appendingPathComponent("Pindrop", isDirectory: true)
        let modelsRoot = root.appendingPathComponent("FluidAudio/Models", isDirectory: true)
        try FileManager.default.createDirectory(at: applicationSupportRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: modelsRoot, withIntermediateDirectories: true)

        let container = try PindropModelContainerFactory.makeInMemoryContainer()
        let settings = SettingsStore()
        settings.resetAllSettings()
        if configureProvider {
            let provider = ProviderConfig(kind: .openai, displayName: "Test OpenAI")
            settings.upsertProvider(provider)
            try settings.saveProviderAPIKey("note-secret", forProviderID: provider.id)
            try settings.saveProviderEndpoint(
                "https://api.example.invalid/v1/chat/completions",
                forProviderID: provider.id
            )
            settings.setAssignment(
                ModelAssignment(
                    providerID: provider.id,
                    modelID: "gpt-4o-mini",
                    promptPresetID: BuiltInPresetID.noteFormatting
                ),
                for: .noteEnhancement
            )
        }

        let captureSessionStore = CaptureSessionStore(modelContext: ModelContext(container))
        let notesStore = NotesStore(
            modelContext: ModelContext(container),
            metadataGenerator: { _, _ in nil }
        )
        let promptPresetStore = PromptPresetStore(modelContext: ModelContext(container))
        let modelManager = ModelManager(storageLocations: ModelStorageLocations(
            pindropApplicationSupportRoot: applicationSupportRoot,
            fluidAudioModelsRoot: modelsRoot
        ))
        let session = StubEnhancementProviderSession()
        let sut = NoteEnhancementService(
            captureSessionStore: captureSessionStore,
            notesStore: notesStore,
            promptPresetStore: promptPresetStore,
            assignmentResolver: CaptureStageAssignmentResolver(
                settings: settings,
                modelManager: modelManager,
                promptPresetStore: promptPresetStore
            ),
            aiEnhancementService: AIEnhancementService(session: session),
            settingsStore: settings
        )

        let startedAt = Date(timeIntervalSinceReferenceDate: 90_000)
        let handle = try captureSessionStore.startNoteCapture(
            startedAt: startedAt,
            includeSystemAudio: false,
            intent: CaptureIntentRequest(destination: .newNote, origin: .mainWindow)
        )
        let anchor = try captureSessionStore.ensureMeetingHumanAnchor(
            handle,
            title: "Release review",
            at: startedAt
        )
        let note = try notesStore.fetch(id: anchor.noteID)
        note.content = typedContent
        try notesStore.update(note)

        if recordTranscript {
            try captureSessionStore.beginMeetingFinalization(handle, at: startedAt.addingTimeInterval(1))
            let checkpoint = chunk(
                handle.microphoneSourceID,
                sessionID: handle.sessionID,
                sequence: 0,
                sealedAt: startedAt.addingTimeInterval(2)
            )
            try captureSessionStore.recordSealedMeetingChunk(handle, checkpoint: checkpoint)
            _ = try captureSessionStore.resolveAssignment(
                sessionID: handle.sessionID,
                stage: .finalTranscription,
                attempt: 1,
                selecting: {
                    try CaptureStageAssignment(
                        stage: .finalTranscription,
                        providerKind: .batchSpeech,
                        providerIdentifier: "catalog-provider",
                        modelIdentifier: "catalog-model",
                        prompt: nil,
                        selectedAt: startedAt,
                        attempt: 1
                    )
                }
            )
            _ = try captureSessionStore.recordMeetingTranscriptionChunk(
                handle,
                sourceChunkSequence: 0,
                startOffset: checkpoint.startOffset,
                duration: checkpoint.duration,
                text: "The release candidate ships on Friday.",
                assignmentAttempt: 1
            )
        }

        return Fixture(
            container: container,
            settings: settings,
            captureSessionStore: captureSessionStore,
            notesStore: notesStore,
            promptPresetStore: promptPresetStore,
            session: session,
            sut: sut,
            handle: handle,
            noteID: anchor.noteID,
            typedContent: typedContent,
            root: root,
            cleanup: {
                settings.resetAllSettings()
                try? FileManager.default.removeItem(at: root)
            }
        )
    }

    // MARK: - Success

    @Test func generationSavesAPanelWithFrozenTemplateProvenanceAndAnchorSnapshot() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        fixture.session.responseContent = "Decisions: ship on Friday."

        let panel = try await fixture.sut.generatePanel(
            sessionID: fixture.handle.sessionID,
            noteID: fixture.noteID,
            templatePresetIdentifier: nil
        )

        #expect(panel.content == "Decisions: ship on Friday.")
        #expect(panel.noteID == fixture.noteID)
        #expect(panel.generation == 1)
        #expect(panel.isCurrent)
        #expect(!panel.isLegacy)
        #expect(panel.templatePresetIdentifier == BuiltInPresetID.noteFormatting)
        #expect(panel.providerSnapshotID != nil)
        #expect(panel.promptSnapshotID != nil)
        #expect(fixture.session.requestCount == 1)

        // The typed notes went in as untrusted evidence and came back untouched.
        let body = try requestBody(from: fixture.session)
        let messages = try #require(body["messages"] as? [[String: Any]])
        let userContent = try #require(messages[1]["content"] as? String)
        #expect(userContent.contains("<untrusted-human-notes>"))
        #expect(userContent.contains(fixture.typedContent))
        #expect(try fixture.notesStore.fetch(id: fixture.noteID).content == fixture.typedContent)

        // The panel is the only note-shaped output: no second Note row is filed.
        let notes = try fixture.notesStore.fetchAll()
        #expect(notes.count == 1)
        #expect(try fixture.captureSessionStore.currentPanels(noteID: fixture.noteID).count == 1)
    }

    @Test func regeneratingUnderAnotherTemplateSupersedesOnlyThatTemplate() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }

        let first = try await fixture.sut.generatePanel(
            sessionID: fixture.handle.sessionID,
            noteID: fixture.noteID,
            templatePresetIdentifier: nil
        )
        fixture.session.responseContent = "Standup: no blockers."
        let second = try await fixture.sut.generatePanel(
            sessionID: fixture.handle.sessionID,
            noteID: fixture.noteID,
            templatePresetIdentifier: BuiltInPresetID.cleanTranscript
        )
        fixture.session.responseContent = "Standup: still no blockers."
        let third = try await fixture.sut.generatePanel(
            sessionID: fixture.handle.sessionID,
            noteID: fixture.noteID,
            templatePresetIdentifier: BuiltInPresetID.cleanTranscript
        )

        #expect(second.templatePresetIdentifier == BuiltInPresetID.cleanTranscript)
        #expect(second.generation == 1)
        #expect(third.generation == 2)
        #expect(third.assignmentAttempt > second.assignmentAttempt)
        #expect(third.providerSnapshotID != second.providerSnapshotID)
        #expect(third.promptSnapshotID != second.promptSnapshotID)

        let current = try fixture.captureSessionStore.currentPanels(noteID: fixture.noteID)
        #expect(Set(current.map(\.id)) == [first.id, third.id])
        #expect(try fixture.captureSessionStore.enhancedPanel(id: second.id)?.isCurrent == false)
    }

    @Test func anOverriddenTemplateIsResolvedAndFrozenIntoThePanel() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }

        let panel = try await fixture.sut.generatePanel(
            sessionID: fixture.handle.sessionID,
            noteID: fixture.noteID,
            templatePresetIdentifier: BuiltInPresetID.cleanTranscript
        )

        #expect(panel.templatePresetIdentifier == BuiltInPresetID.cleanTranscript)
        let expectedName = try #require(
            BuiltInPresets.definition(for: BuiltInPresetID.cleanTranscript)?.name
        )
        #expect(panel.templateDisplayName == expectedName)

        // The chosen template's instructions, not the settings-assigned one, are
        // what the provider was asked to follow.
        let body = try requestBody(from: fixture.session)
        let messages = try #require(body["messages"] as? [[String: Any]])
        let systemContent = try #require(messages[0]["content"] as? String)
        let expectedPrompt = try #require(
            BuiltInPresets.englishPrompt(for: BuiltInPresetID.cleanTranscript)
        )
        #expect(systemContent.contains(expectedPrompt))
    }

    // MARK: - Failures

    @Test func emptyGeneratedContentIsRejectedAndWritesNoPanel() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        fixture.session.responseContent = "   "

        await #expect(throws: NoteEnhancementService.NoteEnhancementError.emptyOutput) {
            try await fixture.sut.generatePanel(
                sessionID: fixture.handle.sessionID,
                noteID: fixture.noteID,
                templatePresetIdentifier: nil
            )
        }

        #expect(try fixture.captureSessionStore.enhancedPanels(noteID: fixture.noteID).isEmpty)
        #expect(try fixture.notesStore.fetch(id: fixture.noteID).content == fixture.typedContent)
    }

    @Test func contentThatIsOnlyForgedCitationsIsRejected() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        // Sanitizing removes a forged citation appendix; nothing else remains.
        fixture.session.responseContent = "Citation Appendix:\\n[C1] invented source"

        await #expect(throws: NoteEnhancementService.NoteEnhancementError.emptyOutput) {
            try await fixture.sut.generatePanel(
                sessionID: fixture.handle.sessionID,
                noteID: fixture.noteID,
                templatePresetIdentifier: nil
            )
        }
        #expect(try fixture.captureSessionStore.enhancedPanels(noteID: fixture.noteID).isEmpty)
    }

    @Test func aProviderFailureBecomesATypedErrorAndLeavesTheNoteIntact() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        fixture.session.error = URLError(.timedOut)

        await #expect(throws: NoteEnhancementService.NoteEnhancementError.generationFailed) {
            try await fixture.sut.generatePanel(
                sessionID: fixture.handle.sessionID,
                noteID: fixture.noteID,
                templatePresetIdentifier: nil
            )
        }

        #expect(try fixture.captureSessionStore.enhancedPanels(noteID: fixture.noteID).isEmpty)
        #expect(try fixture.notesStore.fetch(id: fixture.noteID).content == fixture.typedContent)
    }

    @Test func aCaptureWithNoTranscriptReportsNothingToEnhance() async throws {
        let fixture = try makeFixture(recordTranscript: false)
        defer { fixture.cleanup() }

        await #expect(throws: NoteEnhancementService.NoteEnhancementError.nothingToEnhance) {
            try await fixture.sut.generatePanel(
                sessionID: fixture.handle.sessionID,
                noteID: fixture.noteID,
                templatePresetIdentifier: nil
            )
        }
        #expect(fixture.session.requestCount == 0)
    }

    @Test func anUnassignedNoteEnhancementModelReportsWhatToDoNext() async throws {
        let fixture = try makeFixture(configureProvider: false)
        defer { fixture.cleanup() }

        await #expect(throws: NoteEnhancementService.NoteEnhancementError.enhancementDisabled) {
            try await fixture.sut.generatePanel(
                sessionID: fixture.handle.sessionID,
                noteID: fixture.noteID,
                templatePresetIdentifier: nil
            )
        }
        #expect(fixture.session.requestCount == 0)
        #expect(
            NoteEnhancementService.NoteEnhancementError.enhancementDisabled.errorDescription
                == "Pick a model for note enhancement in Settings, then try again."
        )
    }

    @Test func aMissingNoteReportsThatTheNoteCouldNotBeOpened() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }

        await #expect(throws: NoteEnhancementService.NoteEnhancementError.noteUnavailable) {
            try await fixture.sut.generatePanel(
                sessionID: fixture.handle.sessionID,
                noteID: UUID(),
                templatePresetIdentifier: nil
            )
        }
        #expect(fixture.session.requestCount == 0)
    }

    // MARK: - Template naming

    @Test func templateNamesFallBackWhenNoPresetMatches() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }

        let builtInName = try #require(
            BuiltInPresets.definition(for: BuiltInPresetID.cleanTranscript)?.name
        )
        #expect(fixture.sut.templateDisplayName(for: BuiltInPresetID.cleanTranscript) == builtInName)
        #expect(fixture.sut.templateDisplayName(for: UUID().uuidString) == "Enhanced note")
        #expect(
            fixture.sut.templateDisplayName(for: NoteEnhancementService.defaultTemplateIdentifier)
                == "Enhanced note"
        )
    }
}
