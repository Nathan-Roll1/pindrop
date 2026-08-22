//
//  SchemaV9MigrationTests.swift
//  PindropDataTests
//

import Foundation
import SwiftData
import Testing
import PindropCore
@testable import PindropData

@MainActor
@Suite(.serialized)
struct SchemaV9MigrationTests {
    @Test func schemaV10AddsEmbeddingIdentifiers() throws {
        #expect(TranscriptionRecordSchemaV10.versionIdentifier == .init(1, 0, 9))

        let container = try PindropModelContainerFactory.makeInMemoryContainer()
        let context = ModelContext(container)
        let profile = ParticipantProfile(normalizedName: "alice", displayName: "Alice")
        context.insert(profile)
        try context.save()

        let fetched = try context.fetch(FetchDescriptor<ParticipantProfile>())
        #expect(fetched.first?.embeddingSpaceIdentifier == nil)
        #expect(TranscriptionRecordSchemaV10.models.contains { $0 == TranscriptionRecordSchemaV10.ParticipantProfile.self })
    }

    @Test func migrationPlanOrdersV9BeforeV10() throws {
        let schemas = TranscriptionRecordMigrationPlan.schemas
        let v9Index = try #require(schemas.firstIndex { $0 == TranscriptionRecordSchemaV9.self })
        let v10Index = try #require(schemas.firstIndex { $0 == TranscriptionRecordSchemaV10.self })

        #expect(v10Index == v9Index + 1)
    }

    @Test func v9IdentityDataTypesRemainRepresentableInV10() throws {
        let profile = ParticipantProfile(
            normalizedName: "alice",
            displayName: "Alice",
            notes: "Host",
            isCurrentUser: true
        )
        profile.centroidEmbeddingData = try JSONEncoder().encode([0.1 as Float, 0.2])
        #expect(profile.displayName == "Alice")
        #expect(profile.notes == "Host")
        #expect(profile.isCurrentUser)
        #expect(profile.embeddingSpaceIdentifier == nil)
    }
}
