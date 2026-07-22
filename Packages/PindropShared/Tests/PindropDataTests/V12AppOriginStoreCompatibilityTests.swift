//
//  V12AppOriginStoreCompatibilityTests.swift
//  PindropDataTests
//
//  Created on 2026-07-22.
//
//  Opens the immutable app-origin V12 fixture through PindropModelContainerFactory
//  and proves package models preserve persistent identity. Hashes the committed
//  artifact set before and after so the test never mutates source fixtures.
//

import CryptoKit
import Foundation
import SwiftData
import Testing
@testable import PindropData

@MainActor
@Suite("V12 app-origin store compatibility", .serialized)
struct V12AppOriginStoreCompatibilityTests {
    private static let fixtureFileNames = [
        "v12-app-origin.store",
        "v12-app-origin.store-shm",
        "v12-app-origin.store-wal",
    ]

    private static let transcriptionID = UUID(uuidString: "22222222-2222-4222-8222-222222222222")!
    private static let folderID = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
    private static let profileID = UUID(uuidString: "33333333-3333-4333-8333-333333333333")!
    private static let evidenceID = UUID(uuidString: "44444444-4444-4444-8444-444444444444")!
    private static let wordReplacementID = UUID(uuidString: "55555555-5555-4555-8555-555555555555")!
    private static let vocabularyID = UUID(uuidString: "66666666-6666-4666-8666-666666666666")!
    private static let noteID = UUID(uuidString: "77777777-7777-4777-8777-777777777777")!
    private static let customPresetID = UUID(uuidString: "88888888-8888-4888-8888-888888888888")!
    private static let builtInPresetID = UUID(uuidString: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa")!
    private static let contributionID = UUID(uuidString: "99999999-9999-4999-8999-999999999999")!

    private static let managedMediaPath =
        "MediaLibrary/Imports/22222222-2222-4222-8222-222222222222.m4a"
    private static let thumbnailPath =
        "MediaLibrary/Thumbnails/22222222-2222-4222-8222-222222222222.jpg"
    private static let originalSourceURL =
        "file:///Users/fixture/Movies/fixture-meeting.m4a"
    /// Seeded by the app-origin fixture generator (timeIntervalSince1970).
    private static let fixtureTimestamp = Date(timeIntervalSince1970: 1_700_000_000)
    private static let fixtureUpdatedAt = Date(timeIntervalSince1970: 1_700_000_360)
    private static let fixtureUserEditedAt = Date(timeIntervalSince1970: 1_700_000_720)

    @Test("factory opens app-origin fixture and preserves nine-model identity")
    func factoryOpensAppOriginFixtureAndPreservesIdentity() throws {
        let fixtureDirectory = try Self.fixtureDirectoryURL()
        let beforeHashes = try Self.hashFixtureArtifacts(in: fixtureDirectory)
        #expect(beforeHashes.count == Self.fixtureFileNames.count)

        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("v12-app-origin-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)

        let storeURL = try Self.copyFixtureArtifacts(
            from: fixtureDirectory,
            to: temporaryDirectory
        )

        do {
            let container = try PindropModelContainerFactory.makeContainer(at: storeURL)
            let context = container.mainContext

            let transcriptions = try context.fetch(FetchDescriptor<TranscriptionRecord>())
            let folders = try context.fetch(FetchDescriptor<MediaFolder>())
            let profiles = try context.fetch(FetchDescriptor<ParticipantProfile>())
            let evidence = try context.fetch(FetchDescriptor<ParticipantTrainingEvidence>())
            let replacements = try context.fetch(FetchDescriptor<WordReplacement>())
            let vocabulary = try context.fetch(FetchDescriptor<VocabularyWord>())
            let notes = try context.fetch(FetchDescriptor<Note>())
            let presets = try context.fetch(FetchDescriptor<PromptPreset>())
            let contributions = try context.fetch(FetchDescriptor<TrainingContribution>())

            #expect(transcriptions.count == 1)
            #expect(folders.count == 1)
            #expect(profiles.count == 1)
            #expect(evidence.count == 1)
            #expect(replacements.count == 1)
            #expect(vocabulary.count == 1)
            #expect(notes.count == 1)
            #expect(presets.count == 2)
            #expect(contributions.count == 1)

            let record = try #require(transcriptions.first)
            #expect(record.id == Self.transcriptionID)
            #expect(record.text == "Hello from the V12 fixture. Persisted paths stay stable.")
            #expect(record.originalText == "hello from the v12 fixture persisted paths stay stable")
            #expect(record.timestamp == Self.fixtureTimestamp)
            #expect(record.duration == 3.0)
            #expect(record.modelUsed == "fixture-model")
            #expect(record.enhancedWith == "gpt-test")
            #expect(record.sourceKindRawValue == "importedFile")
            #expect(record.sourceDisplayName == "fixture-meeting.m4a")
            #expect(record.generatedTitle == "V12 Fixture Meeting")
            #expect(record.aiSummary == "Deterministic V12 app-origin fixture transcript.")
            #expect(record.sourceTitleOriginRawValue == "sourceMetadata")
            #expect(record.originalSourceURL == Self.originalSourceURL)
            #expect(record.managedMediaPath == Self.managedMediaPath)
            #expect(record.thumbnailPath == Self.thumbnailPath)
            #expect(record.destinationAppName == "Notes")
            #expect(record.destinationAppBundleID == "com.apple.Notes")
            #expect(record.wordCount == 9)
            #expect(record.userEditedAt == Self.fixtureUserEditedAt)
            #expect(record.folder?.id == Self.folderID)
            #expect(record.diarizationSegmentsJSON != nil)
            #expect(record.pipelineMetricsJSON != nil)
            #expect(record.managedMediaURL != nil)
            #expect(record.managedMediaURL?.path.hasSuffix(Self.managedMediaPath) == true)
            #expect(record.thumbnailURL != nil)
            #expect(record.thumbnailURL?.path.hasSuffix(Self.thumbnailPath) == true)

            let folder = try #require(folders.first)
            #expect(folder.id == Self.folderID)
            #expect(folder.name == "V12 Fixture Folder")
            #expect(folder.trimmedName == "V12 Fixture Folder")
            #expect(folder.createdAt == Self.fixtureTimestamp)
            #expect(folder.updatedAt == Self.fixtureUpdatedAt)

            let profile = try #require(profiles.first)
            #expect(profile.id == Self.profileID)
            #expect(profile.displayName == "Alice")
            #expect(profile.normalizedName == "alice")
            #expect(profile.notes == "Fixture speaker profile")
            #expect(profile.isCurrentUser == false)
            #expect(profile.evidenceCount == 1)
            #expect(profile.totalEvidenceDuration == 1.5)
            #expect(profile.embeddingSpaceIdentifier == "fixture-embedding-space")
            #expect(profile.needsVoiceRetraining == false)
            #expect(profile.createdAt == Self.fixtureTimestamp)
            #expect(profile.updatedAt == Self.fixtureUpdatedAt)

            let trainingEvidence = try #require(evidence.first)
            #expect(trainingEvidence.id == Self.evidenceID)
            #expect(trainingEvidence.evidenceKey == "fixture-evidence-key")
            #expect(trainingEvidence.sourceTypeRawValue == "dictation")
            #expect(trainingEvidence.recordID == Self.transcriptionID)
            #expect(trainingEvidence.sourceSpeakerID == "speaker-1")
            #expect(trainingEvidence.segmentStartTime == 0)
            #expect(trainingEvidence.segmentEndTime == 1.5)
            #expect(trainingEvidence.segmentDuration == 1.5)
            #expect(abs(Double(trainingEvidence.confidence) - 0.98) < 0.0001)
            #expect(trainingEvidence.embeddingSpaceIdentifier == "fixture-embedding-space")
            #expect(trainingEvidence.profile?.id == Self.profileID)
            #expect(trainingEvidence.createdAt == Self.fixtureTimestamp)
            #expect(trainingEvidence.updatedAt == Self.fixtureUpdatedAt)

            let replacement = try #require(replacements.first)
            #expect(replacement.id == Self.wordReplacementID)
            #expect(replacement.originals == ["pindropp", "pin drop"])
            #expect(replacement.replacement == "Pindrop")
            #expect(replacement.sortOrder == 0)
            #expect(replacement.matchModeRawValue == "caseInsensitive")
            #expect(replacement.usageCount == 3)
            #expect(replacement.createdAt == Self.fixtureTimestamp)

            let word = try #require(vocabulary.first)
            #expect(word.id == Self.vocabularyID)
            #expect(word.word == "Pindrop")
            #expect(word.usageCount == 5)
            #expect(word.createdAt == Self.fixtureTimestamp)

            let note = try #require(notes.first)
            #expect(note.id == Self.noteID)
            #expect(note.title == "V12 Fixture Note")
            #expect(note.content == "Note body linked to the fixture transcription.")
            #expect(note.tags == ["fixture", "v12"])
            #expect(note.sourceTranscriptionID == Self.transcriptionID)
            #expect(note.isPinned == true)
            #expect(note.createdAt == Self.fixtureTimestamp)
            #expect(note.updatedAt == Self.fixtureUpdatedAt)

            let presetsByID = Dictionary(uniqueKeysWithValues: presets.map { ($0.id, $0) })
            let customPreset = try #require(presetsByID[Self.customPresetID])
            #expect(customPreset.name == "Fixture Custom Preset")
            #expect(customPreset.prompt == "Rewrite the transcript with deterministic fixture wording.")
            #expect(customPreset.isBuiltIn == false)
            #expect(customPreset.sortOrder == 100)
            #expect(customPreset.builtInIdentifier == nil)
            #expect(customPreset.createdAt == Self.fixtureTimestamp)
            #expect(customPreset.updatedAt == Self.fixtureUpdatedAt)

            let builtInPreset = try #require(presetsByID[Self.builtInPresetID])
            #expect(builtInPreset.name == "Clean Transcript")
            #expect(builtInPreset.prompt == "Clean up the transcript without changing meaning.")
            #expect(builtInPreset.isBuiltIn == true)
            #expect(builtInPreset.sortOrder == 0)
            #expect(builtInPreset.builtInIdentifier == "clean-transcript")
            #expect(builtInPreset.createdAt == Self.fixtureTimestamp)
            #expect(builtInPreset.updatedAt == Self.fixtureUpdatedAt)

            let contribution = try #require(contributions.first)
            #expect(contribution.id == Self.contributionID)
            #expect(contribution.kindRawValue == "aiEnhancement")
            #expect(contribution.inputText == "hello from the v12 fixture persisted paths stay stable")
            #expect(contribution.targetText == "Hello from the V12 fixture. Persisted paths stay stable.")
            #expect(contribution.modelUsed == "fixture-model")
            #expect(contribution.enhancedWith == "gpt-test")
            #expect(contribution.language == "en")
            #expect(contribution.locale == "en_US")
            #expect(contribution.appVersion == "1.0.0-fixture")
            #expect(contribution.sourceRecordID == Self.transcriptionID)
            #expect(contribution.redactionVersion == 1)
            #expect(contribution.uploadStateRawValue == "pending")
            #expect(contribution.createdAt == Self.fixtureTimestamp)

        }

        try? FileManager.default.removeItem(at: temporaryDirectory)

        let afterHashes = try Self.hashFixtureArtifacts(in: fixtureDirectory)
        #expect(afterHashes == beforeHashes)
        #expect(afterHashes.count == Self.fixtureFileNames.count)
    }

    // MARK: - Fixture helpers

    private static func fixtureDirectoryURL() throws -> URL {
        if let nested = Bundle.module.resourceURL?.appendingPathComponent("Fixtures", isDirectory: true),
           FileManager.default.fileExists(atPath: nested.appendingPathComponent("v12-app-origin.store").path) {
            return nested
        }

        // `.copy("Fixtures")` may flatten contents next to the bundle resources root.
        if let root = Bundle.module.resourceURL,
           FileManager.default.fileExists(atPath: root.appendingPathComponent("v12-app-origin.store").path) {
            return root
        }

        if let storeURL = Bundle.module.url(
            forResource: "v12-app-origin",
            withExtension: "store",
            subdirectory: "Fixtures"
        ) {
            return storeURL.deletingLastPathComponent()
        }

        if let storeURL = Bundle.module.url(forResource: "v12-app-origin", withExtension: "store") {
            return storeURL.deletingLastPathComponent()
        }

        Issue.record("V12 app-origin fixtures missing from Bundle.module")
        throw CocoaError(.fileNoSuchFile)
    }

    private static func hashFixtureArtifacts(in directory: URL) throws -> [String: String] {
        var hashes: [String: String] = [:]
        for name in fixtureFileNames {
            let url = directory.appendingPathComponent(name)
            #expect(
                FileManager.default.fileExists(atPath: url.path),
                "Missing fixture artifact \(name) under \(directory.path)"
            )
            let data = try Data(contentsOf: url)
            hashes[name] = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        }
        return hashes
    }

    private static func copyFixtureArtifacts(
        from sourceDirectory: URL,
        to destinationDirectory: URL
    ) throws -> URL {
        var storeURL: URL?
        for name in fixtureFileNames {
            let source = sourceDirectory.appendingPathComponent(name)
            let destination = destinationDirectory.appendingPathComponent(name)
            try FileManager.default.copyItem(at: source, to: destination)
            if name == "v12-app-origin.store" {
                storeURL = destination
            }
        }
        return try #require(storeURL)
    }
}
