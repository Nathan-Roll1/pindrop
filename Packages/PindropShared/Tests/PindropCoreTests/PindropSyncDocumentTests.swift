//
//  PindropSyncDocumentTests.swift
//  PindropCoreTests
//
//  Created on 2026-07-22.
//

import Foundation
import Testing
import PindropCore

@Suite("PindropSyncDocument")
struct PindropSyncDocumentTests {
    private var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    private var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return decoder
    }

    private func makeTranscriptionPayload() -> TranscriptionSyncPayload {
        TranscriptionSyncPayload(
            id: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
            text: "hello world",
            originalText: "hello  world",
            timestamp: Date(timeIntervalSince1970: 1_700_000_000),
            duration: 12.5,
            modelUsed: "base",
            enhancedWith: "gpt-4o-mini",
            diarizationSegments: [
                PortableDiarizationSegment(
                    speakerID: "S1",
                    speakerLabel: "Speaker 1",
                    startTime: 0,
                    endTime: 4,
                    text: "hello"
                )
            ],
            sourceKindRawValue: MediaSourceKind.voiceRecording.rawValue,
            sourceDisplayName: "Mic",
            generatedTitle: "Greeting",
            aiSummary: "A short greeting",
            sourceTitleOriginRawValue: "ai",
            folderID: UUID(uuidString: "22222222-2222-2222-2222-222222222222"),
            wordCount: 2,
            userEditedAt: Date(timeIntervalSince1970: 1_700_000_100)
        )
    }

    private func makeNotePayload() -> NoteSyncPayload {
        NoteSyncPayload(
            id: UUID(uuidString: "33333333-3333-3333-3333-333333333333")!,
            title: "Standup",
            content: "- [ ] Ship tests",
            tags: ["work", "sync"],
            sourceTranscriptionID: UUID(uuidString: "11111111-1111-1111-1111-111111111111"),
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            updatedAt: Date(timeIntervalSince1970: 1_700_000_200),
            isPinned: true
        )
    }

    @Test func initPayloadStampsCurrentSchemaVersion() {
        let document = PindropSyncDocument(payload: .note(makeNotePayload()))
        #expect(document.schemaVersion == PindropSyncDocument.currentSchemaVersion)
        #expect(PindropSyncDocument.currentSchemaVersion == 1)
    }

    @Test func documentRoundTripsEveryPayloadCase() throws {
        let payloads: [PindropSyncPayload] = [
            .transcription(makeTranscriptionPayload()),
            .mediaFolder(
                MediaFolderSyncPayload(
                    id: UUID(uuidString: "44444444-4444-4444-4444-444444444444")!,
                    name: "Meetings",
                    createdAt: Date(timeIntervalSince1970: 1_700_000_000),
                    updatedAt: Date(timeIntervalSince1970: 1_700_000_050)
                )
            ),
            .note(makeNotePayload()),
            .wordReplacement(
                WordReplacementSyncPayload(
                    id: UUID(uuidString: "55555555-5555-5555-5555-555555555555")!,
                    originals: ["teh", "Teh"],
                    replacement: "the",
                    createdAt: Date(timeIntervalSince1970: 1_700_000_000),
                    sortOrder: 3,
                    matchModeRawValue: ReplacementMatchMode.exact.rawValue
                )
            ),
            .vocabularyWord(
                VocabularyWordSyncPayload(
                    id: UUID(uuidString: "66666666-6666-6666-6666-666666666666")!,
                    word: "Pindrop",
                    createdAt: Date(timeIntervalSince1970: 1_700_000_000)
                )
            ),
            .customPromptPreset(
                PromptPresetSyncPayload(
                    id: UUID(uuidString: "77777777-7777-7777-7777-777777777777")!,
                    name: "Clean prose",
                    prompt: "Fix grammar only.",
                    sortOrder: 1,
                    createdAt: Date(timeIntervalSince1970: 1_700_000_000),
                    updatedAt: Date(timeIntervalSince1970: 1_700_000_300)
                )
            ),
        ]

        for payload in payloads {
            let document = PindropSyncDocument(payload: payload)
            let data = try encoder.encode(document)
            let decoded = try decoder.decode(PindropSyncDocument.self, from: data)
            #expect(decoded == document)
            #expect(decoded.schemaVersion == 1)
        }
    }

    @Test func mutationRoundTripsUpsertAndDelete() throws {
        let document = PindropSyncDocument(payload: .note(makeNotePayload()))
        let upsert = PindropSyncMutation.upsert(
            document,
            modifiedAt: Date(timeIntervalSince1970: 1_700_000_400)
        )
        let noteID = UUID(uuidString: "33333333-3333-3333-3333-333333333333")!
        let delete = PindropSyncMutation.delete(
            PindropSyncKey(entity: .note, id: noteID),
            deletedAt: Date(timeIntervalSince1970: 1_700_000_500)
        )

        for mutation in [upsert, delete] {
            let data = try encoder.encode(mutation)
            let decoded = try decoder.decode(PindropSyncMutation.self, from: data)
            #expect(decoded == mutation)
        }
    }

    @Test func decodingRejectsUnsupportedSchemaVersion() throws {
        let valid = PindropSyncDocument(payload: .vocabularyWord(
            VocabularyWordSyncPayload(
                id: UUID(uuidString: "88888888-8888-8888-8888-888888888888")!,
                word: "hello",
                createdAt: Date(timeIntervalSince1970: 1_700_000_000)
            )
        ))
        var object = try JSONSerialization.jsonObject(with: try encoder.encode(valid)) as! [String: Any]
        object["schemaVersion"] = 99
        let badData = try JSONSerialization.data(withJSONObject: object)

        do {
            _ = try decoder.decode(PindropSyncDocument.self, from: badData)
            Issue.record("Expected unsupported schema version to throw")
        } catch is DecodingError {
            // expected
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }
}
