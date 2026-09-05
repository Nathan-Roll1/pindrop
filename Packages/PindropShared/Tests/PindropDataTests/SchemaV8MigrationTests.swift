//
//  SchemaV8MigrationTests.swift
//  PindropDataTests
//
//  Created on 2026-07-09.
//

import Foundation
import SQLite3
import SwiftData
import Testing
import PindropCore
@testable import PindropData

@MainActor
@Suite(.serialized, .enabled(if: sqlite3_libversion_number() > 0, "SQLite is unavailable in this environment"))
struct SchemaV8MigrationTests {
    @Test func migrationFromV7PreservesRecordsAndLeavesNewFieldsNil() throws {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directoryURL) }

        let storeURL = directoryURL.appendingPathComponent("migration-v7-to-v8.store")

        try autoreleasepool {
            let legacySchema = Schema(versionedSchema: TranscriptionRecordSchemaV7.self)
            let legacyContainer = try ModelContainer(
                for: legacySchema,
                configurations: [ModelConfiguration(schema: legacySchema, url: storeURL)]
            )
            let legacyContext = ModelContext(legacyContainer)
            legacyContext.insert(
                TranscriptionRecordSchemaV7.TranscriptionRecord(
                    text: "Hello schema migration",
                    duration: 3.5,
                    modelUsed: "base",
                    sourceKind: .voiceRecording
                )
            )
            legacyContext.insert(
                TranscriptionRecordSchemaV7.TranscriptionRecord(
                    text: "Second legacy record",
                    duration: 1.0,
                    modelUsed: "tiny",
                    sourceKind: .voiceRecording
                )
            )
            try legacyContext.save()
        }

        let migratedContainer = try PindropModelContainerFactory.makeContainer(at: storeURL)
        let migratedContext = ModelContext(migratedContainer)
        let records = try migratedContext.fetch(
            FetchDescriptor<TranscriptionRecord>(sortBy: [SortDescriptor(\.timestamp)])
        )

        #expect(records.count == 2)
        #expect(records.map(\.text).sorted() == ["Hello schema migration", "Second legacy record"].sorted())
        for record in records {
            #expect(record.destinationAppName == nil)
            #expect(record.destinationAppBundleID == nil)
            #expect(record.wordCount == nil)
        }
    }

    @Test func migrationFromV8AddsProfileMetadataDefaults() throws {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directoryURL) }

        let storeURL = directoryURL.appendingPathComponent("migration-v8-to-v9.store")

        try autoreleasepool {
            let legacySchema = Schema(versionedSchema: TranscriptionRecordSchemaV8.self)
            let legacyContainer = try ModelContainer(
                for: legacySchema,
                configurations: [ModelConfiguration(schema: legacySchema, url: storeURL)]
            )
            let legacyContext = ModelContext(legacyContainer)
            legacyContext.insert(
                TranscriptionRecordSchemaV8.ParticipantProfile(
                    normalizedName: "alice",
                    displayName: "Alice"
                )
            )
            try legacyContext.save()
        }

        let migratedContainer = try PindropModelContainerFactory.makeContainer(at: storeURL)
        let profiles = try ModelContext(migratedContainer).fetch(FetchDescriptor<ParticipantProfile>())
        let profile = try #require(profiles.first)

        #expect(profiles.count == 1)
        #expect(profile.displayName == "Alice")
        #expect(profile.notes == nil)
        #expect(profile.isCurrentUser == false)
    }
}
