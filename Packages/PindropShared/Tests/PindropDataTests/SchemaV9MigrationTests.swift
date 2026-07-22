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
    @Test func currentSchemaIsV10AndEmbeddingIdentifiersStartNil() throws {
        #expect(TranscriptionRecordSchemaV10.versionIdentifier == .init(1, 0, 9))

        let container = try PindropModelContainerFactory.makeInMemoryContainer()
        let context = ModelContext(container)
        let profile = ParticipantProfile(normalizedName: "alice", displayName: "Alice")
        context.insert(profile)
        try context.save()

        let fetched = try context.fetch(FetchDescriptor<ParticipantProfile>())
        #expect(fetched.first?.embeddingSpaceIdentifier == nil)
        #expect(TranscriptionRecordSchemaV12.models.contains { $0 == ParticipantProfile.self })
    }

    @Test func migrationPlanIncludesV9ToV10LightweightStage() {
        #expect(TranscriptionRecordMigrationPlan.schemas.contains { $0 == TranscriptionRecordSchemaV9.self })
        #expect(TranscriptionRecordMigrationPlan.schemas.contains { $0 == TranscriptionRecordSchemaV10.self })
        #expect(TranscriptionRecordMigrationPlan.schemas.count == 12)
        #expect(TranscriptionRecordMigrationPlan.stages.count == 11)
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
