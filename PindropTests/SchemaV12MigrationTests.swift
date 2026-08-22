//
//  SchemaV12MigrationTests.swift
//  PindropTests
//
//  Created on 2026-07-14.
//
// App repair/path/factory integration cases. V12 is used only as a historical
// store fixture below; portable V12 schema/migration coverage lives in
// Packages/PindropShared/Tests/PindropDataTests.
//

import Foundation
import SwiftData
import Testing
import PindropCore
@testable import PindropData
@testable import Pindrop

@MainActor
@Suite(.serialized)
struct SchemaV12MigrationTests {
    @Test func productionConfigurationReopensHistoricalV12StoreForHistoryFetch() throws {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directoryURL) }
        let storeURL = directoryURL.appendingPathComponent("history.store")
        let schema = Schema(versionedSchema: TranscriptionRecordSchemaV12.self)

        // Seed a historical V12 store with the pre-fix URL-only configuration.
        // SwiftData creates persistent-history tables as records are saved.
        do {
            let v12FixtureContainer = try ModelContainer(
                for: schema,
                migrationPlan: TranscriptionRecordMigrationPlan.self,
                configurations: ModelConfiguration(url: storeURL)
            )
            let v12FixtureContext = ModelContext(v12FixtureContainer)
            v12FixtureContext.insert(
                TranscriptionRecord(
                    text: "Existing transcript",
                    duration: 1.0,
                    modelUsed: "test"
                )
            )
            try v12FixtureContext.save()
        }

        let reopenedContainer = try AppDelegate.makeModelContainer(at: storeURL)
        let historyStore = HistoryStore(modelContext: ModelContext(reopenedContainer))
        let records = try historyStore.fetch(limit: 5)

        #expect(records.count == 1)
        #expect(records.first?.text == "Existing transcript")
    }

    @Test func productionConfigurationSupportsSpeakerIdentityReadAndWrite() throws {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directoryURL) }
        let storeURL = directoryURL.appendingPathComponent("speaker-identities.store")

        let container = try AppDelegate.makeModelContainer(at: storeURL)
        let context = ModelContext(container)
        let identityService = SpeakerIdentityService(modelContext: context)

        let createdProfile = try identityService.createProfile(displayName: "Alice", notes: "Test profile")
        let profiles = try identityService.fetchAllProfiles()

        #expect(profiles.count == 1)
        #expect(profiles.first?.id == createdProfile.id)
        #expect(profiles.first?.displayName == "Alice")
        #expect(profiles.first?.notes == "Test profile")
    }
}
