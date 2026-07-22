//
//  PindropModelContainerFactory.swift
//  PindropData
//
//  Created on 2026-07-22.
//

import CoreData
import Foundation
import SwiftData

@MainActor
public enum PindropModelContainerFactory {
    /// Opens a durable store at `storeURL` with the complete V12 schema and migration plan.
    /// Performs a health fetch for every current model so store damage surfaces immediately.
    public static func makeContainer(at storeURL: URL) throws -> ModelContainer {
        let schema = Schema(versionedSchema: TranscriptionRecordSchemaV12.self)
        let configuration = ModelConfiguration(schema: schema, url: storeURL)
        let container: ModelContainer

        do {
            container = try ModelContainer(
                for: schema,
                migrationPlan: TranscriptionRecordMigrationPlan.self,
                configurations: configuration
            )
        } catch let stagedMigrationError {
            // Releases before PromptPreset was added used an unversioned model
            // container. Staged migration cannot identify that otherwise-compatible
            // model hash, so preserve the original inferred lightweight-migration
            // path only for that known Pindrop model. Other unknown versions remain
            // rejected by the staged migration error.
            guard isLegacyStoreWithoutPromptPreset(at: storeURL) else {
                throw stagedMigrationError
            }

            do {
                container = try makeLegacyCompatibleContainer(at: storeURL)
            } catch {
                throw stagedMigrationError
            }
        }

        try validateStoreAccess(on: container)
        return container
    }

    /// In-memory container using the complete current V12 schema for store tests and previews.
    public static func makeInMemoryContainer() throws -> ModelContainer {
        let schema = Schema(versionedSchema: TranscriptionRecordSchemaV12.self)
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(
            for: schema,
            migrationPlan: TranscriptionRecordMigrationPlan.self,
            configurations: configuration
        )
        try validateStoreAccess(on: container)
        return container
    }

    private static func isLegacyStoreWithoutPromptPreset(at storeURL: URL) -> Bool {
        guard let metadata = try? NSPersistentStoreCoordinator.metadataForPersistentStore(
            ofType: NSSQLiteStoreType,
            at: storeURL
        ),
            let versionHashes = metadata[NSStoreModelVersionHashesKey] as? [String: Data]
        else {
            return false
        }

        let entityNames = Set(versionHashes.keys)
        let legacyEntityNames: Set<String> = [
            "TranscriptionRecord",
            "WordReplacement",
            "VocabularyWord",
            "Note"
        ]
        return entityNames == legacyEntityNames
    }

    private static func makeLegacyCompatibleContainer(at storeURL: URL) throws -> ModelContainer {
        try ModelContainer(
            for: TranscriptionRecord.self,
            MediaFolder.self,
            ParticipantProfile.self,
            ParticipantTrainingEvidence.self,
            WordReplacement.self,
            VocabularyWord.self,
            Note.self,
            PromptPreset.self,
            TrainingContribution.self,
            configurations: ModelConfiguration(url: storeURL)
        )
    }

    private static func validateStoreAccess(on container: ModelContainer) throws {
        func validateStoreAccess<Model: PersistentModel>(_: Model.Type) throws {
            var healthCheck = FetchDescriptor<Model>()
            healthCheck.fetchLimit = 1
            _ = try container.mainContext.fetch(healthCheck)
        }

        try validateStoreAccess(TranscriptionRecord.self)
        try validateStoreAccess(MediaFolder.self)
        try validateStoreAccess(ParticipantProfile.self)
        try validateStoreAccess(ParticipantTrainingEvidence.self)
        try validateStoreAccess(WordReplacement.self)
        try validateStoreAccess(VocabularyWord.self)
        try validateStoreAccess(Note.self)
        try validateStoreAccess(PromptPreset.self)
        try validateStoreAccess(TrainingContribution.self)
    }
}
