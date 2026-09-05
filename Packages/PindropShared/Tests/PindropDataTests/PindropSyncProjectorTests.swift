//
//  PindropSyncProjectorTests.swift
//  PindropDataTests
//
//  Created on 2026-07-22.
//
//  Proves PindropSyncProjector preserves step-3 synchronized fields, Codable/
//  Equatable round trips, local-field exclusions, diarization nil/empty/valid/
//  malformed contracts, and built-in preset suppression.
//

import Foundation
import SwiftData
import Testing
import PindropCore
@testable import PindropData

@MainActor
@Suite("PindropSyncProjector", .serialized)
struct PindropSyncProjectorTests {

    // MARK: - Transcription

    @Test("transcription projects every synchronized field and round-trips")
    func transcriptionProjectsSynchronizedFieldsAndRoundTrips() throws {
        let (container, context) = try makeStore()
        defer { withExtendedLifetime(container) {} }
        let folderID = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
        let recordID = UUID(uuidString: "22222222-2222-4222-8222-222222222222")!
        let folder = MediaFolder(
            id: folderID,
            name: "Meetings",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            updatedAt: Date(timeIntervalSince1970: 1_700_000_100)
        )
        let editedAt = Date(timeIntervalSince1970: 1_700_000_200)
        let timestamp = Date(timeIntervalSince1970: 1_700_000_050)
        let record = TranscriptionRecord(
            id: recordID,
            text: "Enhanced hello world",
            originalText: "hello world",
            timestamp: timestamp,
            duration: 12.5,
            modelUsed: "parakeet-tdt-0.6b-v3",
            enhancedWith: "openai:gpt-4.1-mini",
            diarizationSegmentsJSON: nil,
            sourceKind: .voiceRecording,
            sourceDisplayName: "Microphone",
            generatedTitle: "Standup notes",
            aiSummary: "A short summary",
            sourceTitleOriginRawValue: TranscriptionTitleOrigin.fallback.rawValue,
            originalSourceURL: "file:///tmp/local-only.m4a",
            managedMediaPath: "MediaLibrary/DictationAudio/local.m4a",
            thumbnailPath: "MediaLibrary/Thumbnails/local.jpg",
            folder: folder,
            destinationAppName: "Notes",
            destinationAppBundleID: "com.apple.Notes",
            wordCount: 3,
            userEditedAt: editedAt,
            pipelineMetricsJSON: #"{"totalMs":42}"#
        )
        context.insert(folder)
        context.insert(record)
        try context.save()

        let document = try PindropSyncProjector.document(from: record)
        #expect(document.schemaVersion == PindropSyncDocument.currentSchemaVersion)

        guard case .transcription(let payload) = document.payload else {
            Issue.record("Expected transcription payload")
            return
        }

        #expect(payload.id == recordID)
        #expect(payload.text == "Enhanced hello world")
        #expect(payload.originalText == "hello world")
        #expect(payload.timestamp == timestamp)
        #expect(payload.duration == 12.5)
        #expect(payload.modelUsed == "parakeet-tdt-0.6b-v3")
        #expect(payload.enhancedWith == "openai:gpt-4.1-mini")
        #expect(payload.diarizationSegments == nil)
        #expect(payload.sourceKindRawValue == MediaSourceKind.voiceRecording.rawValue)
        #expect(payload.sourceDisplayName == "Microphone")
        #expect(payload.generatedTitle == "Standup notes")
        #expect(payload.aiSummary == "A short summary")
        #expect(payload.sourceTitleOriginRawValue == TranscriptionTitleOrigin.fallback.rawValue)
        #expect(payload.folderID == folderID)
        #expect(payload.wordCount == 3)
        #expect(payload.userEditedAt == editedAt)

        let expected = TranscriptionSyncPayload(
            id: recordID,
            text: "Enhanced hello world",
            originalText: "hello world",
            timestamp: timestamp,
            duration: 12.5,
            modelUsed: "parakeet-tdt-0.6b-v3",
            enhancedWith: "openai:gpt-4.1-mini",
            diarizationSegments: nil,
            sourceKindRawValue: MediaSourceKind.voiceRecording.rawValue,
            sourceDisplayName: "Microphone",
            generatedTitle: "Standup notes",
            aiSummary: "A short summary",
            sourceTitleOriginRawValue: TranscriptionTitleOrigin.fallback.rawValue,
            folderID: folderID,
            wordCount: 3,
            userEditedAt: editedAt
        )
        #expect(payload == expected)
        try assertDocumentRoundTrips(document)
    }

    @Test("transcription encoding excludes host-local storage and metrics fields")
    func transcriptionEncodingExcludesLocalFields() throws {
        let (container, context) = try makeStore()
        defer { withExtendedLifetime(container) {} }
        let record = TranscriptionRecord(
            id: UUID(uuidString: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa")!,
            text: "local fields stay local",
            timestamp: Date(timeIntervalSince1970: 1_700_100_000),
            duration: 1,
            modelUsed: "whisper-base",
            originalSourceURL: "file:///Users/fixture/secret.m4a",
            managedMediaPath: "MediaLibrary/Imports/secret.m4a",
            thumbnailPath: "MediaLibrary/Thumbnails/secret.jpg",
            destinationAppName: "Mail",
            destinationAppBundleID: "com.apple.mail",
            pipelineMetricsJSON: #"{"captureMs":9}"#
        )
        context.insert(record)
        try context.save()

        let document = try PindropSyncProjector.document(from: record)
        let payloadObject = try payloadObject(from: document)

        // Non-nil synchronized fields are present; nil optionals are omitted by
        // JSONEncoder and must never be replaced by host-local keys.
        let presentKeys: Set<String> = [
            "id",
            "text",
            "timestamp",
            "duration",
            "modelUsed",
            "sourceKindRawValue",
        ]
        #expect(Set(payloadObject.keys) == presentKeys)

        let synchronizedOptionalKeys = [
            "originalText",
            "enhancedWith",
            "diarizationSegments",
            "sourceDisplayName",
            "generatedTitle",
            "aiSummary",
            "sourceTitleOriginRawValue",
            "folderID",
            "wordCount",
            "userEditedAt",
        ]
        for key in synchronizedOptionalKeys {
            #expect(payloadObject[key] == nil, "Nil optional \(key) should be omitted from encoding")
        }

        let excludedKeys = [
            "managedMediaPath",
            "thumbnailPath",
            "originalSourceURL",
            "destinationAppName",
            "destinationAppBundleID",
            "pipelineMetricsJSON",
            "pipelineMetrics",
            "diarizationSegmentsJSON",
            "sourceKind",
            "wasEnhanced",
            "folder",
        ]
        for key in excludedKeys {
            #expect(payloadObject[key] == nil, "Unexpected local key \(key) in transcription payload")
        }
    }

    @Test("transcription nil diarization JSON projects nil segments")
    func transcriptionNilDiarizationProjectsNil() throws {
        let (container, context) = try makeStore()
        defer { withExtendedLifetime(container) {} }
        let record = TranscriptionRecord(
            id: UUID(uuidString: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb")!,
            text: "no diarization",
            timestamp: Date(timeIntervalSince1970: 1_700_200_000),
            duration: 2,
            modelUsed: "apple-speech",
            diarizationSegmentsJSON: nil
        )
        context.insert(record)
        try context.save()

        let document = try PindropSyncProjector.document(from: record)
        guard case .transcription(let payload) = document.payload else {
            Issue.record("Expected transcription payload")
            return
        }
        #expect(payload.diarizationSegments == nil)
        // Nil optional arrays are omitted by JSONEncoder rather than encoded as null.
        let payloadObject = try payloadObject(from: document)
        #expect(payloadObject["diarizationSegments"] == nil)
    }

    @Test("transcription empty diarization JSON projects empty non-optional array")
    func transcriptionEmptyDiarizationProjectsEmptyArray() throws {
        let (container, context) = try makeStore()
        defer { withExtendedLifetime(container) {} }
        let record = TranscriptionRecord(
            id: UUID(uuidString: "cccccccc-cccc-4ccc-8ccc-cccccccccccc")!,
            text: "empty diarization",
            timestamp: Date(timeIntervalSince1970: 1_700_300_000),
            duration: 3,
            modelUsed: "sensevoice",
            diarizationSegmentsJSON: "[]"
        )
        context.insert(record)
        try context.save()

        let document = try PindropSyncProjector.document(from: record)
        guard case .transcription(let payload) = document.payload else {
            Issue.record("Expected transcription payload")
            return
        }
        let segments = try #require(payload.diarizationSegments)
        #expect(segments.isEmpty)
        #expect(payload.diarizationSegments != nil)

        let payloadObject = try payloadObject(from: document)
        let encodedSegments = try #require(payloadObject["diarizationSegments"] as? [Any])
        #expect(encodedSegments.isEmpty)
    }

    @Test("transcription valid diarization strips profile, embedding, and confidence")
    func transcriptionValidDiarizationStripsLocalSpeakerState() throws {
        let (container, context) = try makeStore()
        defer { withExtendedLifetime(container) {} }
        let profileID = UUID(uuidString: "dddddddd-dddd-4ddd-8ddd-dddddddddddd")!
        let segments = [
            DiarizedTranscriptSegment(
                speakerId: "spk_0",
                speakerLabel: "Alice",
                speakerProfileID: profileID,
                speakerEmbedding: [0.1, 0.2, 0.3, 0.4],
                startTime: 0.0,
                endTime: 1.25,
                confidence: 0.97,
                text: "Hello there"
            ),
            DiarizedTranscriptSegment(
                speakerId: "spk_1",
                speakerLabel: "Bob",
                speakerProfileID: UUID(uuidString: "eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee")!,
                speakerEmbedding: [0.9, 0.8],
                startTime: 1.25,
                endTime: 3.5,
                confidence: 0.81,
                text: "Hi Alice"
            ),
        ]
        let jsonData = try JSONEncoder().encode(segments)
        let json = try #require(String(data: jsonData, encoding: .utf8))

        let record = TranscriptionRecord(
            id: UUID(uuidString: "ffffffff-ffff-4fff-8fff-ffffffffffff")!,
            text: "Hello there Hi Alice",
            timestamp: Date(timeIntervalSince1970: 1_700_400_000),
            duration: 3.5,
            modelUsed: "whisper-large",
            diarizationSegmentsJSON: json
        )
        context.insert(record)
        try context.save()

        let document = try PindropSyncProjector.document(from: record)
        guard case .transcription(let payload) = document.payload else {
            Issue.record("Expected transcription payload")
            return
        }

        let projected = try #require(payload.diarizationSegments)
        #expect(projected.count == 2)
        #expect(
            projected[0] == PortableDiarizationSegment(
                speakerID: "spk_0",
                speakerLabel: "Alice",
                startTime: 0.0,
                endTime: 1.25,
                text: "Hello there"
            )
        )
        #expect(
            projected[1] == PortableDiarizationSegment(
                speakerID: "spk_1",
                speakerLabel: "Bob",
                startTime: 1.25,
                endTime: 3.5,
                text: "Hi Alice"
            )
        )

        let payloadObject = try payloadObject(from: document)
        let encodedSegments = try #require(payloadObject["diarizationSegments"] as? [[String: Any]])
        #expect(encodedSegments.count == 2)

        let portableKeys: Set<String> = [
            "speakerID",
            "speakerLabel",
            "startTime",
            "endTime",
            "text",
        ]
        let excludedSegmentKeys = [
            "speakerProfileID",
            "speakerEmbedding",
            "confidence",
            "speakerId",
            "profileID",
            "embedding",
        ]
        for segmentObject in encodedSegments {
            #expect(Set(segmentObject.keys) == portableKeys)
            for key in excludedSegmentKeys {
                #expect(segmentObject[key] == nil, "Unexpected local diarization key \(key)")
            }
        }

        try assertDocumentRoundTrips(document)
    }

    @Test("transcription malformed diarization throws invalidDiarization with record id")
    func transcriptionMalformedDiarizationThrowsInvalidDiarization() throws {
        let (container, context) = try makeStore()
        defer { withExtendedLifetime(container) {} }
        let recordID = UUID(uuidString: "12121212-1212-4121-8121-121212121212")!
        let record = TranscriptionRecord(
            id: recordID,
            text: "broken diarization",
            timestamp: Date(timeIntervalSince1970: 1_700_500_000),
            duration: 4,
            modelUsed: "parakeet",
            diarizationSegmentsJSON: "{not-valid-json"
        )
        context.insert(record)
        try context.save()

        #expect {
            try PindropSyncProjector.document(from: record)
        } throws: { error in
            guard let projectionError = error as? PindropSyncProjectionError else {
                return false
            }
            return projectionError == .invalidDiarization(recordID: recordID)
        }
    }

    // MARK: - Media folder

    @Test("media folder projects synchronized fields and round-trips")
    func mediaFolderProjectsSynchronizedFieldsAndRoundTrips() throws {
        let (container, context) = try makeStore()
        defer { withExtendedLifetime(container) {} }
        let id = UUID(uuidString: "31313131-3131-4131-8131-313131313131")!
        let createdAt = Date(timeIntervalSince1970: 1_701_000_000)
        let updatedAt = Date(timeIntervalSince1970: 1_701_000_500)
        let folder = MediaFolder(
            id: id,
            name: "Podcasts",
            createdAt: createdAt,
            updatedAt: updatedAt
        )
        context.insert(folder)
        try context.save()

        let document = PindropSyncProjector.document(from: folder)
        #expect(document.schemaVersion == PindropSyncDocument.currentSchemaVersion)
        guard case .mediaFolder(let payload) = document.payload else {
            Issue.record("Expected mediaFolder payload")
            return
        }

        #expect(payload.id == id)
        #expect(payload.name == "Podcasts")
        #expect(payload.createdAt == createdAt)
        #expect(payload.updatedAt == updatedAt)
        #expect(
            payload == MediaFolderSyncPayload(
                id: id,
                name: "Podcasts",
                createdAt: createdAt,
                updatedAt: updatedAt
            )
        )

        let payloadObject = try payloadObject(from: document)
        #expect(Set(payloadObject.keys) == ["id", "name", "createdAt", "updatedAt"])
        #expect(payloadObject["records"] == nil)
        try assertDocumentRoundTrips(document)
    }

    // MARK: - Note

    @Test("note projects synchronized fields and round-trips")
    func noteProjectsSynchronizedFieldsAndRoundTrips() throws {
        let (container, context) = try makeStore()
        defer { withExtendedLifetime(container) {} }
        let id = UUID(uuidString: "41414141-4141-4141-8141-414141414141")!
        let sourceID = UUID(uuidString: "42424242-4242-4242-8242-424242424242")!
        let createdAt = Date(timeIntervalSince1970: 1_702_000_000)
        let updatedAt = Date(timeIntervalSince1970: 1_702_000_100)
        let note = Note(
            id: id,
            title: "Action items",
            content: "- Ship sync contracts",
            tags: ["work", "sync"],
            sourceTranscriptionID: sourceID,
            createdAt: createdAt,
            updatedAt: updatedAt,
            isPinned: true
        )
        context.insert(note)
        try context.save()

        let document = PindropSyncProjector.document(from: note)
        guard case .note(let payload) = document.payload else {
            Issue.record("Expected note payload")
            return
        }

        #expect(payload.id == id)
        #expect(payload.title == "Action items")
        #expect(payload.content == "- Ship sync contracts")
        #expect(payload.tags == ["work", "sync"])
        #expect(payload.sourceTranscriptionID == sourceID)
        #expect(payload.createdAt == createdAt)
        #expect(payload.updatedAt == updatedAt)
        #expect(payload.isPinned == true)
        #expect(
            payload == NoteSyncPayload(
                id: id,
                title: "Action items",
                content: "- Ship sync contracts",
                tags: ["work", "sync"],
                sourceTranscriptionID: sourceID,
                createdAt: createdAt,
                updatedAt: updatedAt,
                isPinned: true
            )
        )

        let payloadObject = try payloadObject(from: document)
        #expect(
            Set(payloadObject.keys) == [
                "id",
                "title",
                "content",
                "tags",
                "sourceTranscriptionID",
                "createdAt",
                "updatedAt",
                "isPinned",
            ]
        )
        try assertDocumentRoundTrips(document)
    }

    // MARK: - Word replacement

    @Test("word replacement projects synchronized fields, excludes usageCount, and round-trips")
    func wordReplacementProjectsFieldsExcludesUsageAndRoundTrips() throws {
        let (container, context) = try makeStore()
        defer { withExtendedLifetime(container) {} }
        let id = UUID(uuidString: "51515151-5151-4151-8151-515151515151")!
        let createdAt = Date(timeIntervalSince1970: 1_703_000_000)
        let replacement = WordReplacement(
            id: id,
            originals: ["pindrop", "pin drop"],
            replacement: "Pindrop",
            createdAt: createdAt,
            sortOrder: 7,
            matchModeRawValue: ReplacementMatchMode.exact.rawValue,
            usageCount: 42
        )
        context.insert(replacement)
        try context.save()

        let document = PindropSyncProjector.document(from: replacement)
        guard case .wordReplacement(let payload) = document.payload else {
            Issue.record("Expected wordReplacement payload")
            return
        }

        #expect(payload.id == id)
        #expect(payload.originals == ["pindrop", "pin drop"])
        #expect(payload.replacement == "Pindrop")
        #expect(payload.createdAt == createdAt)
        #expect(payload.sortOrder == 7)
        #expect(payload.matchModeRawValue == ReplacementMatchMode.exact.rawValue)
        #expect(
            payload == WordReplacementSyncPayload(
                id: id,
                originals: ["pindrop", "pin drop"],
                replacement: "Pindrop",
                createdAt: createdAt,
                sortOrder: 7,
                matchModeRawValue: ReplacementMatchMode.exact.rawValue
            )
        )

        let payloadObject = try payloadObject(from: document)
        #expect(
            Set(payloadObject.keys) == [
                "id",
                "originals",
                "replacement",
                "createdAt",
                "sortOrder",
                "matchModeRawValue",
            ]
        )
        #expect(payloadObject["usageCount"] == nil)
        try assertDocumentRoundTrips(document)
    }

    // MARK: - Vocabulary word

    @Test("vocabulary word projects synchronized fields, excludes usageCount, and round-trips")
    func vocabularyWordProjectsFieldsExcludesUsageAndRoundTrips() throws {
        let (container, context) = try makeStore()
        defer { withExtendedLifetime(container) {} }
        let id = UUID(uuidString: "61616161-6161-4161-8161-616161616161")!
        let createdAt = Date(timeIntervalSince1970: 1_704_000_000)
        let word = VocabularyWord(
            id: id,
            word: "SwiftData",
            createdAt: createdAt,
            usageCount: 19
        )
        context.insert(word)
        try context.save()

        let document = PindropSyncProjector.document(from: word)
        guard case .vocabularyWord(let payload) = document.payload else {
            Issue.record("Expected vocabularyWord payload")
            return
        }

        #expect(payload.id == id)
        #expect(payload.word == "SwiftData")
        #expect(payload.createdAt == createdAt)
        #expect(
            payload == VocabularyWordSyncPayload(
                id: id,
                word: "SwiftData",
                createdAt: createdAt
            )
        )

        let payloadObject = try payloadObject(from: document)
        #expect(Set(payloadObject.keys) == ["id", "word", "createdAt"])
        #expect(payloadObject["usageCount"] == nil)
        try assertDocumentRoundTrips(document)
    }

    // MARK: - Prompt presets

    @Test("custom prompt preset projects synchronized fields, excludes built-in markers, and round-trips")
    func customPromptPresetProjectsFieldsAndRoundTrips() throws {
        let (container, context) = try makeStore()
        defer { withExtendedLifetime(container) {} }
        let id = UUID(uuidString: "71717171-7171-4171-8171-717171717171")!
        let createdAt = Date(timeIntervalSince1970: 1_705_000_000)
        let updatedAt = Date(timeIntervalSince1970: 1_705_000_200)
        let preset = PromptPreset(
            id: id,
            name: "Concise bullets",
            prompt: "Rewrite as concise bullets.",
            isBuiltIn: false,
            sortOrder: 3,
            createdAt: createdAt,
            updatedAt: updatedAt,
            builtInIdentifier: nil
        )
        context.insert(preset)
        try context.save()

        let document = try #require(PindropSyncProjector.document(from: preset))
        guard case .customPromptPreset(let payload) = document.payload else {
            Issue.record("Expected customPromptPreset payload")
            return
        }

        #expect(payload.id == id)
        #expect(payload.name == "Concise bullets")
        #expect(payload.prompt == "Rewrite as concise bullets.")
        #expect(payload.sortOrder == 3)
        #expect(payload.createdAt == createdAt)
        #expect(payload.updatedAt == updatedAt)
        #expect(
            payload == PromptPresetSyncPayload(
                id: id,
                name: "Concise bullets",
                prompt: "Rewrite as concise bullets.",
                sortOrder: 3,
                createdAt: createdAt,
                updatedAt: updatedAt
            )
        )

        let payloadObject = try payloadObject(from: document)
        #expect(
            Set(payloadObject.keys) == [
                "id",
                "name",
                "prompt",
                "sortOrder",
                "createdAt",
                "updatedAt",
            ]
        )
        #expect(payloadObject["isBuiltIn"] == nil)
        #expect(payloadObject["builtInIdentifier"] == nil)
        try assertDocumentRoundTrips(document)
    }

    @Test("built-in prompt preset returns nil and never projects")
    func builtInPromptPresetReturnsNil() throws {
        let (container, context) = try makeStore()
        defer { withExtendedLifetime(container) {} }
        let preset = PromptPreset(
            id: UUID(uuidString: "81818181-8181-4181-8181-818181818181")!,
            name: "Meeting notes",
            prompt: "Summarize the meeting.",
            isBuiltIn: true,
            sortOrder: 0,
            createdAt: Date(timeIntervalSince1970: 1_706_000_000),
            updatedAt: Date(timeIntervalSince1970: 1_706_000_000),
            builtInIdentifier: "meeting-notes"
        )
        context.insert(preset)
        try context.save()

        let document = PindropSyncProjector.document(from: preset)
        #expect(document == nil)
    }

    // MARK: - Helpers

    /// Builds an in-memory store and returns both the container and its main
    /// context so the container stays alive for the full test lifetime.
    private func makeStore() throws -> (container: ModelContainer, context: ModelContext) {
        let container = try PindropModelContainerFactory.makeInMemoryContainer()
        return (container, container.mainContext)
    }

    private func assertDocumentRoundTrips(_ document: PindropSyncDocument) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970

        let data = try encoder.encode(document)
        let decoded = try decoder.decode(PindropSyncDocument.self, from: data)
        #expect(decoded == document)
        #expect(decoded.schemaVersion == PindropSyncDocument.currentSchemaVersion)
    }

    private func payloadObject(from document: PindropSyncDocument) throws -> [String: Any] {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(document)
        let root = try #require(
            try JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        #expect(root["schemaVersion"] as? Int == PindropSyncDocument.currentSchemaVersion)

        // Encoded shape: { "payload": { "<case>": { "_0": { ...fields } } } }
        let payload = try #require(root["payload"] as? [String: Any])
        #expect(payload.count == 1)
        let caseObject = try #require(payload.values.first as? [String: Any])
        let nested = try #require(caseObject["_0"] as? [String: Any])
        return nested
    }
}
