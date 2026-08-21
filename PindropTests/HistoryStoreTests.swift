//
//  HistoryStoreTests.swift
//  PindropTests
//
//  Created on 2026-01-25.
//
//  App repair/path/factory integration. Portable HistoryStore CRUD/export
//  coverage lives in Packages/PindropShared/Tests/PindropDataTests.
//

import Foundation
import SQLite3
import SwiftData
import Testing
import PindropCore
@testable import PindropData
@testable import Pindrop

@MainActor
@Suite(.serialized, .enabled(if: sqlite3_libversion_number() > 0, "SQLite is unavailable in this environment"))
struct HistoryStoreTests {
    private func requireSQLiteSupport() throws {
    }

    @Test func repairServiceRepairsStoreWithV3TablesAndV1Metadata() throws {
        try requireSQLiteSupport()
        let brokenStoreURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("broken.store")
        let referenceStoreURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("reference-v1.store")
        let repairService = SwiftDataStoreRepairService()

        try createV3Store(at: brokenStoreURL)
        try createV1Store(at: referenceStoreURL)
        try overwriteMetadataAndModelCache(at: brokenStoreURL, using: referenceStoreURL)

        do {
            _ = try makeCurrentContainer(at: brokenStoreURL)
            Issue.record("Expected legacy container creation to fail before repair")
        } catch {
            #expect(Bool(true))
        }

        let repairOutcome = try repairService.repairIfNeeded(storeURL: brokenStoreURL)
        #expect(repairOutcome.repaired)
        #expect(repairOutcome.backupDirectoryURL != nil)
        #expect(try metadataVersionIdentifier(at: brokenStoreURL) == PindropPersistentSchemaVersion.v3.rawValue)

        let repairedContainer = try makeCurrentContainer(at: brokenStoreURL)
        let repairedContext = ModelContext(repairedContainer)
        let records = try repairedContext.fetch(FetchDescriptor<TranscriptionRecord>())

        #expect(records.count == 1)
        #expect(records.first?.text == "Legacy transcription")
        #expect(records.first?.resolvedSourceKind == .voiceRecording)

        try? FileManager.default.removeItem(at: brokenStoreURL.deletingLastPathComponent())
        try? FileManager.default.removeItem(at: referenceStoreURL.deletingLastPathComponent())
    }

    @Test func repairServiceRecreatesMissingV14PromptSnapshotTableWithV14Metadata() throws {
        try requireSQLiteSupport()
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let storeURL = directoryURL.appendingPathComponent("missing-v14-prompt-snapshot-table.store")
        let repairService = SwiftDataStoreRepairService()

        let seedContainer = try makeCurrentContainer(at: storeURL)
        let seedContext = ModelContext(seedContainer)
        seedContext.insert(
            TranscriptionRecord(
                text: "Existing transcription",
                duration: 2.5,
                modelUsed: "base"
            )
        )
        try seedContext.save()
        try flushSQLiteStore(at: storeURL)
        #expect(try metadataVersionIdentifier(at: storeURL) == PindropPersistentSchemaVersion.v14.rawValue)
        #expect(try tableExists(named: "ZCAPTURESTAGEPROMPTSNAPSHOTMODEL", at: storeURL))

        try withDatabase(at: storeURL) { database in
            try execute("DROP TABLE ZCAPTURESTAGEPROMPTSNAPSHOTMODEL", on: database)
        }

        #expect(try tableExists(named: "ZCAPTURESTAGEPROMPTSNAPSHOTMODEL", at: storeURL) == false)

        let repairOutcome = try repairService.repairIfNeeded(storeURL: storeURL)
        #expect(repairOutcome.repaired)
        #expect(repairOutcome.backupDirectoryURL != nil)
        #expect(try metadataVersionIdentifier(at: storeURL) == PindropPersistentSchemaVersion.v14.rawValue)
        #expect(try tableExists(named: "ZCAPTURESTAGEPROMPTSNAPSHOTMODEL", at: storeURL))

        let repairedContainer = try makeCurrentContainer(at: storeURL)
        let repairedContext = ModelContext(repairedContainer)
        let records = try repairedContext.fetch(FetchDescriptor<TranscriptionRecord>())

        #expect(records.count == 1)
        #expect(records.first?.text == "Existing transcription")

        try? FileManager.default.removeItem(at: directoryURL)
    }

    @Test func prepareStoreLocationMigratesRecognizedLegacyStore() throws {
        try requireSQLiteSupport()
        let applicationSupportURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let legacyStoreURL = applicationSupportURL.appendingPathComponent("default.store")
        let repairService = SwiftDataStoreRepairService(
            fileManager: .default,
            applicationSupportRootURL: applicationSupportURL
        )

        try createV3Store(at: legacyStoreURL)

        try repairService.prepareStoreLocation()

        let migratedStoreURL = repairService.storeURL()
        #expect(FileManager.default.fileExists(atPath: migratedStoreURL.path))

        let migratedContainer = try makeCurrentContainer(at: migratedStoreURL)
        let migratedContext = ModelContext(migratedContainer)
        let records = try migratedContext.fetch(FetchDescriptor<TranscriptionRecord>())

        #expect(records.count == 1)
        #expect(records.first?.text == "Legacy transcription")

        try? FileManager.default.removeItem(at: applicationSupportURL)
    }

    @Test func prepareStoreLocationMigratesV4LegacyStoreToCurrentSchema() throws {
        try requireSQLiteSupport()
        let applicationSupportURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let legacyStoreURL = applicationSupportURL.appendingPathComponent("default.store")
        let repairService = SwiftDataStoreRepairService(
            fileManager: .default,
            applicationSupportRootURL: applicationSupportURL
        )

        try createV4Store(at: legacyStoreURL)

        try repairService.prepareStoreLocation()

        let migratedStoreURL = repairService.storeURL()
        #expect(FileManager.default.fileExists(atPath: migratedStoreURL.path))

        let migratedContainer = try makeCurrentContainer(at: migratedStoreURL)
        let migratedContext = ModelContext(migratedContainer)
        let records = try migratedContext.fetch(FetchDescriptor<TranscriptionRecord>())

        #expect(records.count == 1)
        #expect(records.first?.text == "Legacy transcription")
        #expect(records.first?.folder == nil)

        try? FileManager.default.removeItem(at: applicationSupportURL)
    }

    @Test func currentContainerMigratesLegacyStoreWithoutPromptPresetModel() throws {
        try requireSQLiteSupport()
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let storeURL = directoryURL.appendingPathComponent("legacy-no-prompt-preset.store")

        try createV4StoreWithoutPromptPreset(at: storeURL)

        do {
            try autoreleasepool {
                let container = try makeCurrentContainer(at: storeURL)
                let records = try ModelContext(container).fetch(FetchDescriptor<TranscriptionRecord>())
                #expect(records.map(\.text) == ["Legacy transcription"])
                #expect(try tableExists(named: "ZPROMPTPRESET", at: storeURL))
            }

            let reopenedContainer = try makeCurrentContainer(at: storeURL)
            let reopenedRecords = try ModelContext(reopenedContainer).fetch(FetchDescriptor<TranscriptionRecord>())
            #expect(reopenedRecords.map(\.text) == ["Legacy transcription"])
        } catch {
            Issue.record("Expected current container migration to succeed, got \(error)")
        }

        try? FileManager.default.removeItem(at: directoryURL)
    }

    @Test func prepareStoreLocationIgnoresUnrecognizedLegacyStore() throws {
        try requireSQLiteSupport()
        let applicationSupportURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let legacyStoreURL = applicationSupportURL.appendingPathComponent("default.store")
        let repairService = SwiftDataStoreRepairService(
            fileManager: .default,
            applicationSupportRootURL: applicationSupportURL
        )

        try createUnrecognizedStore(at: legacyStoreURL)

        try repairService.prepareStoreLocation()

        #expect(FileManager.default.fileExists(atPath: repairService.storeURL().path) == false)
        #expect(FileManager.default.fileExists(atPath: legacyStoreURL.path))

        try? FileManager.default.removeItem(at: applicationSupportURL)
    }

    @Test func prepareStoreLocationAllowsFreshStoreCreationWhenLegacyStoreIsUnrecognized() throws {
        try requireSQLiteSupport()
        let applicationSupportURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let legacyStoreURL = applicationSupportURL.appendingPathComponent("default.store")
        let repairService = SwiftDataStoreRepairService(
            fileManager: .default,
            applicationSupportRootURL: applicationSupportURL
        )

        try createUnrecognizedStore(at: legacyStoreURL)
        try repairService.prepareStoreLocation()

        let currentStoreURL = repairService.storeURL()
        let container = try makeCurrentContainer(at: currentStoreURL)
        let context = ModelContext(container)
        context.insert(
            TranscriptionRecord(
                text: "Fresh transcription",
                duration: 1.0,
                modelUsed: "base"
            )
        )
        try context.save()

        let records = try context.fetch(FetchDescriptor<TranscriptionRecord>())

        #expect(currentStoreURL.path.contains("/Pindrop/default.store"))
        #expect(FileManager.default.fileExists(atPath: currentStoreURL.path))
        #expect(FileManager.default.fileExists(atPath: legacyStoreURL.path))
        #expect(records.count == 1)
        #expect(records.first?.text == "Fresh transcription")

        try? FileManager.default.removeItem(at: applicationSupportURL)
    }

    @Test func prepareStoreLocationRestoresLegacyStoreWhenCurrentStoreIsUnrecognized() throws {
        try requireSQLiteSupport()
        let applicationSupportURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let legacyStoreURL = applicationSupportURL.appendingPathComponent("default.store")
        let repairService = SwiftDataStoreRepairService(
            fileManager: .default,
            applicationSupportRootURL: applicationSupportURL
        )

        try createV4Store(at: legacyStoreURL)
        try createUnrecognizedStore(at: repairService.storeURL())

        try repairService.prepareStoreLocation()

        let restoredContainer = try makeCurrentContainer(at: repairService.storeURL())
        let restoredContext = ModelContext(restoredContainer)
        let records = try restoredContext.fetch(FetchDescriptor<TranscriptionRecord>())

        #expect(records.count == 1)
        #expect(records.first?.text == "Legacy transcription")

        try? FileManager.default.removeItem(at: applicationSupportURL)
    }

    @Test func repairServiceLeavesHealthyV11StoreUntouched() throws {
        try requireSQLiteSupport()
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let storeURL = directoryURL.appendingPathComponent("healthy-v11.store")
        let repairService = SwiftDataStoreRepairService()

        try createV11Store(at: storeURL)

        let outcome = try repairService.repairIfNeeded(storeURL: storeURL)
        #expect(outcome.repaired == false)

        let container = try AppDelegate.makeModelContainer(at: storeURL)
        let records = try ModelContext(container).fetch(FetchDescriptor<TranscriptionRecord>())
        #expect(records.count == 1)
        #expect(records.first?.text == "Legacy transcription")

        try? FileManager.default.removeItem(at: directoryURL)
    }

    @Test func repairServiceLeavesHealthyV14StoreUntouched() throws {
        try requireSQLiteSupport()
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        let storeURL = directoryURL.appendingPathComponent("healthy-v14.store")
        let repairService = SwiftDataStoreRepairService()

        try autoreleasepool {
            let container = try AppDelegate.makeModelContainer(at: storeURL)
            let context = ModelContext(container)
            context.insert(
                TranscriptionRecord(
                    text: "Current transcription",
                    duration: 1.0,
                    modelUsed: "base"
                )
            )
            try context.save()
        }
        try flushSQLiteStore(at: storeURL)
        #expect(try metadataVersionIdentifier(at: storeURL) == PindropPersistentSchemaVersion.v14.rawValue)
        #expect(try tableExists(named: "ZCAPTURESTAGEPROMPTSNAPSHOTMODEL", at: storeURL))

        let outcome = try repairService.repairIfNeeded(storeURL: storeURL)
        #expect(outcome.repaired == false)
        #expect(outcome.backupDirectoryURL == nil)

        try? FileManager.default.removeItem(at: directoryURL)
    }

    @Test func repairServiceRepairsV12StoreWithoutCaptureTablesUsingV12Artifacts() throws {
        try requireSQLiteSupport()
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let storeURL = directoryURL.appendingPathComponent("bricked-v12.store")
        let v11ReferenceStoreURL = directoryURL.appendingPathComponent("v11-reference.store")
        defer { try? FileManager.default.removeItem(at: directoryURL) }
        let repairService = SwiftDataStoreRepairService()

        try createV12Store(at: storeURL)
        try createV11Store(at: v11ReferenceStoreURL)
        #expect(try tableExists(named: "ZCAPTURESESSIONMODEL", at: storeURL) == false)

        try overwriteMetadataAndModelCache(at: storeURL, using: v11ReferenceStoreURL)

        let outcome = try repairService.repairIfNeeded(storeURL: storeURL)
        #expect(outcome.repaired)
        #expect(try metadataVersionIdentifier(at: storeURL) == PindropPersistentSchemaVersion.v12.rawValue)
        #expect(try tableExists(named: "ZCAPTURESESSIONMODEL", at: storeURL) == false)
    }

    // Regression for https://github.com/watzon/pindrop/issues/78: a V13 store
    // can carry V13 metadata while still missing columns from earlier
    // lightweight migrations. Version metadata and object-name checks alone
    // must not cause the repair path to treat that store as healthy.
    @Test func repairServiceRestoresV13MetadataStoreWithMissingColumns() throws {
        try requireSQLiteSupport()
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let storeURL = directoryURL.appendingPathComponent("incomplete-v13.store")
        defer { try? FileManager.default.removeItem(at: directoryURL) }
        let repairService = SwiftDataStoreRepairService(
            fileManager: .default,
            applicationSupportRootURL: directoryURL
        )
        let missingColumns = [
            (table: "ZTRANSCRIPTIONRECORD", column: "ZDESTINATIONAPPNAME"),
            (table: "ZTRANSCRIPTIONRECORD", column: "ZDESTINATIONAPPBUNDLEID"),
            (table: "ZTRANSCRIPTIONRECORD", column: "ZWORDCOUNT"),
            (table: "ZPARTICIPANTPROFILE", column: "ZNOTES"),
            (table: "ZPARTICIPANTPROFILE", column: "ZISCURRENTUSER"),
            (table: "ZPARTICIPANTPROFILE", column: "ZEMBEDDINGSPACEIDENTIFIER"),
            (table: "ZPARTICIPANTPROFILE", column: "ZNEEDSVOICERETRAINING"),
            (table: "ZPARTICIPANTTRAININGEVIDENCE", column: "ZEMBEDDINGSPACEIDENTIFIER"),
            (table: "ZWORDREPLACEMENT", column: "ZMATCHMODERAWVALUE"),
            (table: "ZWORDREPLACEMENT", column: "ZUSAGECOUNT"),
            (table: "ZVOCABULARYWORD", column: "ZUSAGECOUNT")
        ]

        try autoreleasepool {
            let schema = Schema(versionedSchema: TranscriptionRecordSchemaV13.self)
            let configuration = ModelConfiguration(schema: schema, url: storeURL)
            let container = try ModelContainer(for: schema, configurations: configuration)
            let context = ModelContext(container)
            let profile = ParticipantProfile(
                normalizedName: "alice",
                displayName: "Alice",
                notes: "Seed notes",
                isCurrentUser: true,
                embeddingSpaceIdentifier: "seed-space",
                needsVoiceRetraining: true
            )

            context.insert(
                TranscriptionRecord(
                    text: "Current transcription",
                    duration: 1.0,
                    modelUsed: "base",
                    destinationAppName: "Notes",
                    destinationAppBundleID: "com.apple.Notes",
                    wordCount: 2,
                    pipelineMetricsJSON: "{}"
                )
            )
            context.insert(profile)
            context.insert(
                ParticipantTrainingEvidence(
                    evidenceKey: "seed-evidence",
                    sourceTypeRawValue: "dictation",
                    sourceSpeakerID: "speaker-0",
                    segmentStartTime: 0,
                    segmentEndTime: 1,
                    segmentDuration: 1,
                    confidence: 0.9,
                    embeddingData: Data([0x01]),
                    embeddingSpaceIdentifier: "seed-space",
                    profile: profile
                )
            )
            context.insert(
                WordReplacement(
                    originals: ["teh"],
                    replacement: "the",
                    matchModeRawValue: ReplacementMatchMode.exact.rawValue,
                    usageCount: 4
                )
            )
            context.insert(VocabularyWord(word: "Pindrop", usageCount: 3))
            try context.save()
        }
        try flushSQLiteStore(at: storeURL)
        #expect(try metadataVersionIdentifier(at: storeURL) == PindropPersistentSchemaVersion.v13.rawValue)
        #expect(try tableExists(named: "ZCAPTURESESSIONMODEL", at: storeURL))
        #expect(try tableExists(named: "ZCAPTURESTAGEPROMPTSNAPSHOTMODEL", at: storeURL) == false)

        try withDatabase(at: storeURL) { database in
            for missingColumn in missingColumns {
                let tableName = quotedSQLiteIdentifier(missingColumn.table)
                let columnName = quotedSQLiteIdentifier(missingColumn.column)
                try execute("ALTER TABLE \(tableName) DROP COLUMN \(columnName)", on: database)
            }
        }
        // ALTER TABLE damage must retain the V13 identity and table set; otherwise
        // this regression would accidentally exercise the V14 repair path.
        #expect(try metadataVersionIdentifier(at: storeURL) == PindropPersistentSchemaVersion.v13.rawValue)
        #expect(try tableExists(named: "ZCAPTURESESSIONMODEL", at: storeURL))
        #expect(try tableExists(named: "ZCAPTURESTAGEPROMPTSNAPSHOTMODEL", at: storeURL) == false)
        let metadataBeforeRepair = try fetchBlob(
            sql: "SELECT Z_PLIST FROM Z_METADATA LIMIT 1",
            at: storeURL
        )
        let modelCacheBeforeRepair = try fetchBlob(
            sql: "SELECT Z_CONTENT FROM Z_MODELCACHE LIMIT 1",
            at: storeURL
        )

        do {
            try autoreleasepool {
                let schema = Schema(versionedSchema: TranscriptionRecordSchemaV13.self)
                let configuration = ModelConfiguration(schema: schema, url: storeURL)
                let container = try ModelContainer(for: schema, configurations: configuration)
                let context = ModelContext(container)
                var healthCheck = FetchDescriptor<TranscriptionRecord>()
                healthCheck.fetchLimit = 1
                _ = try context.fetch(healthCheck)
            }
            Issue.record("Expected V13 container health check to reject the incomplete store")
        } catch {
            #expect(!error.localizedDescription.isEmpty)
        }
        #expect(try metadataVersionIdentifier(at: storeURL) == PindropPersistentSchemaVersion.v13.rawValue)
        #expect(try tableExists(named: "ZCAPTURESTAGEPROMPTSNAPSHOTMODEL", at: storeURL) == false)

        let outcome = try repairService.repairIfNeeded(storeURL: storeURL)
        #expect(outcome.repaired)
        #expect(outcome.backupDirectoryURL != nil)
        #expect(try metadataVersionIdentifier(at: storeURL) == PindropPersistentSchemaVersion.v13.rawValue)
        #expect(try tableExists(named: "ZCAPTURESTAGEPROMPTSNAPSHOTMODEL", at: storeURL) == false)
        #expect(
            try fetchBlob(sql: "SELECT Z_PLIST FROM Z_METADATA LIMIT 1", at: storeURL)
                == metadataBeforeRepair
        )
        #expect(
            try fetchBlob(sql: "SELECT Z_CONTENT FROM Z_MODELCACHE LIMIT 1", at: storeURL)
                == modelCacheBeforeRepair
        )

        let repairedContainer = try AppDelegate.makeModelContainer(at: storeURL)
        let repairedContext = ModelContext(repairedContainer)
        let records = try repairedContext.fetch(FetchDescriptor<TranscriptionRecord>())
        let profiles = try repairedContext.fetch(FetchDescriptor<ParticipantProfile>())
        let evidence = try repairedContext.fetch(FetchDescriptor<ParticipantTrainingEvidence>())
        let replacements = try repairedContext.fetch(FetchDescriptor<WordReplacement>())
        let vocabulary = try repairedContext.fetch(FetchDescriptor<VocabularyWord>())

        #expect(records.count == 1)
        #expect(records.first?.destinationAppName == nil)
        #expect(records.first?.destinationAppBundleID == nil)
        #expect(records.first?.wordCount == nil)
        #expect(profiles.count == 1)
        #expect(profiles.first?.notes == nil)
        #expect(profiles.first?.isCurrentUser == false)
        #expect(profiles.first?.embeddingSpaceIdentifier == nil)
        #expect(profiles.first?.needsVoiceRetraining == false)
        #expect(evidence.count == 1)
        #expect(evidence.first?.embeddingSpaceIdentifier == nil)
        #expect(replacements.count == 1)
        #expect(replacements.first?.matchModeRawValue == nil)
        #expect(replacements.first?.usageCount == 0)
        #expect(vocabulary.count == 1)
        #expect(vocabulary.first?.usageCount == 0)
    }

    @Test func productionHealthCheckRejectsMissingNonTranscriptionColumn() throws {
        try requireSQLiteSupport()
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let storeURL = directoryURL.appendingPathComponent("incomplete-dictionary.store")
        defer { try? FileManager.default.removeItem(at: directoryURL) }

        try autoreleasepool {
            let container = try AppDelegate.makeModelContainer(at: storeURL)
            let context = ModelContext(container)
            context.insert(VocabularyWord(word: "Pindrop", usageCount: 3))
            try context.save()
        }
        try flushSQLiteStore(at: storeURL)

        try withDatabase(at: storeURL) { database in
            try execute("ALTER TABLE ZVOCABULARYWORD DROP COLUMN ZUSAGECOUNT", on: database)
        }

        do {
            _ = try AppDelegate.makeModelContainer(at: storeURL)
            Issue.record("Expected production health check to reject the incomplete dictionary table")
        } catch {
            #expect(!error.localizedDescription.isEmpty)
        }
    }

    // Regression for https://github.com/watzon/pindrop/issues/76: the old
    // repair path stamped V7+ stores with metadata built from unversioned
    // current models (version identifier 1.0.0, stale entity set), after which
    // the staged-migration container could never open the store again.
    @Test func repairServiceRestoresStoreBrickedByLegacyRepairMetadata() throws {
        try requireSQLiteSupport()
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let storeURL = directoryURL.appendingPathComponent("bricked-v11.store")
        let referenceStoreURL = directoryURL.appendingPathComponent("legacy-repair-reference.store")
        let repairService = SwiftDataStoreRepairService()

        try createV11Store(at: storeURL)

        // Reproduce the poisoned metadata the pre-fix repair service wrote:
        // an unversioned container over the current model classes.
        try autoreleasepool {
            let configuration = ModelConfiguration(url: referenceStoreURL)
            let container = try ModelContainer(
                for: TranscriptionRecord.self,
                MediaFolder.self,
                ParticipantProfile.self,
                ParticipantTrainingEvidence.self,
                WordReplacement.self,
                VocabularyWord.self,
                Note.self,
                PromptPreset.self,
                configurations: configuration
            )
            try container.mainContext.save()
        }
        try flushSQLiteStore(at: referenceStoreURL)
        try overwriteMetadataAndModelCache(at: storeURL, using: referenceStoreURL)

        do {
            _ = try AppDelegate.makeModelContainer(at: storeURL)
            Issue.record("Expected staged-migration container creation to fail before repair")
        } catch {
            #expect((error as NSError).domain == "SwiftData.SwiftDataError")
        }

        let outcome = try repairService.repairIfNeeded(storeURL: storeURL)
        #expect(outcome.repaired)
        #expect(outcome.backupDirectoryURL != nil)

        let repairedContainer = try AppDelegate.makeModelContainer(at: storeURL)
        let records = try ModelContext(repairedContainer).fetch(FetchDescriptor<TranscriptionRecord>())
        #expect(records.count == 1)
        #expect(records.first?.text == "Legacy transcription")
        #expect(records.first?.pipelineMetricsJSON == nil)

        let identityService = SpeakerIdentityService(modelContext: ModelContext(repairedContainer))
        let profile = try identityService.createProfile(displayName: "Alice", notes: "Repaired store")
        let profiles = try identityService.fetchAllProfiles()
        #expect(profiles.contains { $0.id == profile.id })

        try? FileManager.default.removeItem(at: directoryURL)
    }

    // MARK: - Test Helpers

    private func createV1Store(at storeURL: URL) throws {
        try FileManager.default.createDirectory(at: storeURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try autoreleasepool {
            let configuration = ModelConfiguration(url: storeURL)
            let container = try ModelContainer(
                for: TranscriptionRecordSchemaV1.TranscriptionRecordV1.self,
                WordReplacement.self,
                VocabularyWord.self,
                Note.self,
                PromptPreset.self,
                configurations: configuration
            )

            let context = ModelContext(container)
            context.insert(
                TranscriptionRecordSchemaV1.TranscriptionRecordV1(
                    text: "Original transcription",
                    duration: 2.0,
                    modelUsed: "tiny"
                )
            )
            try context.save()
        }
        try flushSQLiteStore(at: storeURL)
    }

    private func createV3Store(at storeURL: URL) throws {
        try FileManager.default.createDirectory(at: storeURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try autoreleasepool {
            let configuration = ModelConfiguration(url: storeURL)
            let container = try ModelContainer(
                for: TranscriptionRecordSchemaV3.TranscriptionRecord.self,
                WordReplacement.self,
                VocabularyWord.self,
                Note.self,
                PromptPreset.self,
                configurations: configuration
            )

            let context = ModelContext(container)
            context.insert(
                TranscriptionRecordSchemaV3.TranscriptionRecord(
                    text: "Legacy transcription",
                    originalText: "Legacy transcription",
                    duration: 4.2,
                    modelUsed: "base",
                    enhancedWith: nil,
                    diarizationSegmentsJSON: nil
                )
            )
            try context.save()
        }
        try flushSQLiteStore(at: storeURL)
    }

    private func createV4Store(at storeURL: URL) throws {
        try FileManager.default.createDirectory(at: storeURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try autoreleasepool {
            let configuration = ModelConfiguration(url: storeURL)
            let container = try ModelContainer(
                for: TranscriptionRecordSchemaV4.TranscriptionRecord.self,
                WordReplacement.self,
                VocabularyWord.self,
                Note.self,
                PromptPreset.self,
                configurations: configuration
            )

            let context = ModelContext(container)
            context.insert(
                TranscriptionRecordSchemaV4.TranscriptionRecord(
                    text: "Legacy transcription",
                    originalText: "Legacy transcription",
                    duration: 4.2,
                    modelUsed: "base",
                    enhancedWith: nil,
                    diarizationSegmentsJSON: nil,
                    sourceKind: .voiceRecording,
                    sourceDisplayName: nil,
                    originalSourceURL: nil,
                    managedMediaPath: nil,
                    thumbnailPath: nil
                )
            )
            try context.save()
        }
        try flushSQLiteStore(at: storeURL)
    }

    private func createV4StoreWithoutPromptPreset(at storeURL: URL) throws {
        try FileManager.default.createDirectory(at: storeURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try autoreleasepool {
            let configuration = ModelConfiguration(url: storeURL)
            let container = try ModelContainer(
                for: TranscriptionRecordSchemaV4.TranscriptionRecord.self,
                WordReplacement.self,
                VocabularyWord.self,
                Note.self,
                configurations: configuration
            )

            let context = ModelContext(container)
            context.insert(
                TranscriptionRecordSchemaV4.TranscriptionRecord(
                    text: "Legacy transcription",
                    originalText: "Legacy transcription",
                    duration: 4.2,
                    modelUsed: "base",
                    enhancedWith: nil,
                    diarizationSegmentsJSON: nil,
                    sourceKind: .voiceRecording,
                    sourceDisplayName: nil,
                    originalSourceURL: nil,
                    managedMediaPath: nil,
                    thumbnailPath: nil
                )
            )
            try context.save()
        }
        try flushSQLiteStore(at: storeURL)
    }

    private func createV12Store(at storeURL: URL) throws {
        try FileManager.default.createDirectory(at: storeURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try autoreleasepool {
            let schema = Schema(versionedSchema: TranscriptionRecordSchemaV12.self)
            let configuration = ModelConfiguration(schema: schema, url: storeURL)
            let container = try ModelContainer(for: schema, configurations: configuration)
            try container.mainContext.save()
        }
        try flushSQLiteStore(at: storeURL)
    }

    private func createV11Store(at storeURL: URL) throws {
        try FileManager.default.createDirectory(at: storeURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try autoreleasepool {
            let schema = Schema(versionedSchema: TranscriptionRecordSchemaV11.self)
            let configuration = ModelConfiguration(schema: schema, url: storeURL)
            let container = try ModelContainer(for: schema, configurations: configuration)

            let context = ModelContext(container)
            context.insert(
                TranscriptionRecordSchemaV11.TranscriptionRecord(
                    text: "Legacy transcription",
                    duration: 2.0,
                    modelUsed: "base"
                )
            )
            try context.save()
        }
        try flushSQLiteStore(at: storeURL)
    }

    private func createUnrecognizedStore(at storeURL: URL) throws {
        try FileManager.default.createDirectory(at: storeURL.deletingLastPathComponent(), withIntermediateDirectories: true)

        var database: OpaquePointer?
        guard sqlite3_open_v2(storeURL.path, &database, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK else {
            let message = database.flatMap { sqlite3_errmsg($0) }.map { String(cString: $0) } ?? "Unknown SQLite error"
            sqlite3_close(database)
            throw NSError(domain: "HistoryStoreTests", code: 2, userInfo: [NSLocalizedDescriptionKey: message])
        }

        defer { sqlite3_close(database) }

        guard let database else {
            throw NSError(domain: "HistoryStoreTests", code: 3, userInfo: [NSLocalizedDescriptionKey: "Failed to create SQLite database"])
        }

        let sql = "CREATE TABLE IF NOT EXISTS unrelated_table (id INTEGER PRIMARY KEY)"
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
            throw sqliteError(on: database)
        }
    }

    private func makeCurrentContainer(at storeURL: URL) throws -> ModelContainer {
        try AppDelegate.makeModelContainer(at: storeURL)
    }

    private func overwriteMetadataAndModelCache(at targetStoreURL: URL, using referenceStoreURL: URL) throws {
        let referenceMetadata = try fetchBlob(
            sql: "SELECT Z_PLIST FROM Z_METADATA LIMIT 1",
            at: referenceStoreURL
        )
        let referenceModelCache = try fetchBlob(
            sql: "SELECT Z_CONTENT FROM Z_MODELCACHE LIMIT 1",
            at: referenceStoreURL
        )

        try withDatabase(at: targetStoreURL) { database in
            try execute("BEGIN IMMEDIATE TRANSACTION", on: database)
            do {
                try updateBlob(
                    sql: "UPDATE Z_METADATA SET Z_PLIST = ? WHERE Z_VERSION = 1",
                    blob: referenceMetadata,
                    on: database
                )
                try execute("DELETE FROM Z_MODELCACHE", on: database)
                try updateBlob(
                    sql: "INSERT INTO Z_MODELCACHE (Z_CONTENT) VALUES (?)",
                    blob: referenceModelCache,
                    on: database
                )
                try execute("COMMIT TRANSACTION", on: database)
            } catch {
                try? execute("ROLLBACK TRANSACTION", on: database)
                throw error
            }
        }
    }

    private func fetchBlob(sql: String, at storeURL: URL) throws -> Data {
        try withDatabase(at: storeURL) { database in
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
                throw sqliteError(on: database)
            }

            defer { sqlite3_finalize(statement) }

            guard sqlite3_step(statement) == SQLITE_ROW else {
                throw sqliteError(on: database)
            }

            guard let bytes = sqlite3_column_blob(statement, 0) else {
                return Data()
            }

            let count = Int(sqlite3_column_bytes(statement, 0))
            return Data(bytes: bytes, count: count)
        }
    }

    private func metadataVersionIdentifier(at storeURL: URL) throws -> String? {
        let metadataBlob = try fetchBlob(
            sql: "SELECT Z_PLIST FROM Z_METADATA LIMIT 1",
            at: storeURL
        )
        let plist = try PropertyListSerialization.propertyList(from: metadataBlob, format: nil)
        let dictionary = plist as? [String: Any]
        return (dictionary?["NSStoreModelVersionIdentifiers"] as? [String])?.first
    }

    private func updateBlob(sql: String, blob: Data, on database: OpaquePointer) throws {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            throw sqliteError(on: database)
        }

        defer { sqlite3_finalize(statement) }

        let bindResult = blob.withUnsafeBytes { rawBuffer in
            sqlite3_bind_blob(
                statement,
                1,
                rawBuffer.baseAddress,
                Int32(blob.count),
                unsafeBitCast(-1, to: sqlite3_destructor_type.self)
            )
        }
        guard bindResult == SQLITE_OK else {
            throw sqliteError(on: database)
        }

        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw sqliteError(on: database)
        }
    }

    private func tableExists(named table: String, at storeURL: URL) throws -> Bool {
        try withDatabase(at: storeURL) { database in
            var statement: OpaquePointer?
            let sql = "SELECT name FROM sqlite_master WHERE type = 'table' AND name = ? LIMIT 1"
            guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
                throw sqliteError(on: database)
            }

            defer { sqlite3_finalize(statement) }

            guard sqlite3_bind_text(
                statement,
                1,
                (table as NSString).utf8String,
                -1,
                unsafeBitCast(-1, to: sqlite3_destructor_type.self)
            ) == SQLITE_OK else {
                throw sqliteError(on: database)
            }

            return sqlite3_step(statement) == SQLITE_ROW
        }
    }

    private func execute(_ sql: String, on database: OpaquePointer) throws {
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
            throw sqliteError(on: database)
        }
    }

    private func quotedSQLiteIdentifier(_ identifier: String) -> String {
        "\"\(identifier.replacingOccurrences(of: "\"", with: "\"\""))\""
    }

    private func withDatabase<T>(at url: URL, _ work: (OpaquePointer) throws -> T) throws -> T {
        var database: OpaquePointer?
        guard sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK else {
            let error = sqliteError(on: database)
            sqlite3_close(database)
            throw error
        }

        defer { sqlite3_close(database) }

        guard let database else {
            throw sqliteError(on: nil)
        }

        sqlite3_busy_timeout(database, 5_000)

        return try work(database)
    }

    private func flushSQLiteStore(at storeURL: URL) throws {
        var lastError: Error?

        for _ in 0..<5 {
            do {
                try withDatabase(at: storeURL) { database in
                    try execute("PRAGMA wal_checkpoint(TRUNCATE)", on: database)
                }
                return
            } catch {
                lastError = error
                Thread.sleep(forTimeInterval: 0.05)
            }
        }

        if let lastError {
            throw lastError
        }
    }

    private func sqliteError(on database: OpaquePointer?) -> NSError {
        let message = database.flatMap { sqlite3_errmsg($0) }.map { String(cString: $0) } ?? "Unknown SQLite error"
        return NSError(domain: "HistoryStoreTests", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
