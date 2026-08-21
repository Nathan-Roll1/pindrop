//
//  NotesStore.swift
//  PindropData
//
//  Created on 2026-01-29.
//

import Foundation
import Observation
import PindropCore
import SwiftData

extension Notification.Name {
    public static let pindropNoteTagsDidChange = Notification.Name("PindropNoteTagsDidChange")
}

/// Durable result of a speak-to-append write.
public struct NoteAppendResult: Sendable, Equatable {
    public let noteID: UUID
    public let content: String
    public let sourceTranscriptionID: UUID

    public init(noteID: UUID, content: String, sourceTranscriptionID: UUID) {
        self.noteID = noteID
        self.content = content
        self.sourceTranscriptionID = sourceTranscriptionID
    }
}

@MainActor
@Observable
public final class NotesStore {

    public enum NotesStoreError: Error, Equatable, LocalizedError {
        case saveFailed(String)
        case fetchFailed(String)
        case deleteFailed(String)
        case searchFailed(String)
        case metadataGenerationFailed(String)
        case noteNotFound(UUID)
        public var errorDescription: String? {
            switch self {
            case .saveFailed(let message):
                return "Failed to save note: \(message)"
            case .fetchFailed(let message):
                return "Failed to fetch notes: \(message)"
            case .deleteFailed(let message):
                return "Failed to delete note: \(message)"
            case .searchFailed(let message):
                return "Failed to search notes: \(message)"
            case .metadataGenerationFailed(let message):
                return "Failed to generate metadata: \(message)"
            case .noteNotFound(let id):
                return "Note \(id.uuidString) was not found."
            }
        }
    }

    private let modelContext: ModelContext
    /// Optional host-supplied metadata generator. Returning `nil` means no
    /// assignment is configured and is not logged as an error. Thrown errors are
    /// logged and the note still saves with fallback title/tags.
    private let metadataGenerator: @MainActor @Sendable (String, [String]) async throws -> NoteMetadata?
    /// Background projection worker for tag aggregation (same container, separate context).
    private let tagsWorker: NotesTagsProjectionWorker
    /// Sorted unique tags cache; invalidated on tag-affecting note mutations.
    private var uniqueTagsCache: [String]?
    /// Changes whenever a tag-affecting write invalidates an in-flight projection.
    private var uniqueTagsCacheGeneration: UInt = 0
    /// Nonisolated resource ownership so `deinit` can remove the observer without
    /// touching MainActor-isolated stored properties.
    private let noteTagsChangeObserverRegistration = NotesTagsChangeObserverRegistration()

    public init(
        modelContext: ModelContext,
        metadataGenerator: @escaping @MainActor @Sendable (String, [String]) async throws -> NoteMetadata?
    ) {
        self.modelContext = modelContext
        self.metadataGenerator = metadataGenerator
        self.tagsWorker = NotesTagsProjectionWorker(modelContainer: modelContext.container)
        let token = NotificationCenter.default.addObserver(
            forName: .pindropNoteTagsDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.invalidateUniqueTagsCache()
            }
        }
        noteTagsChangeObserverRegistration.install(token)
    }

    deinit {
        // Nonisolated fallback: only the resource holder is touched.
        noteTagsChangeObserverRegistration.tearDown()
    }

    @discardableResult
    public func create(
        title: String? = nil,
        content: String,
        tags: [String]? = nil,
        sourceTranscriptionID: UUID? = nil,
        generateMetadata: Bool = false
    ) async throws -> Note {
        var finalTitle = title
        var finalTags = tags

        // Generate metadata if requested. `nil` means no assignment (not an error).
        // Generator failures are logged and fall back to default title/tags.
        if generateMetadata {
            do {
                let existingTags = (try? await getAllUniqueTagsAsync()) ?? []
                if let metadata = try await metadataGenerator(content, existingTags) {
                    if finalTitle == nil {
                        finalTitle = metadata.title
                    }
                    if finalTags == nil {
                        finalTags = metadata.tags
                    }
                }
            } catch {
                Log.aiEnhancement.warning(
                    "Failed to generate note metadata: \(error.localizedDescription)")
                // Fall back to default behavior on generator failure
            }
        }

        // Fall back to first 30 chars of content if no title
        if finalTitle == nil || finalTitle?.isEmpty == true {
            let trimmedContent = content.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmedContent.isEmpty {
                finalTitle = "Untitled Note"
            } else if trimmedContent.count <= 30 {
                finalTitle = trimmedContent
            } else {
                let index = trimmedContent.index(trimmedContent.startIndex, offsetBy: 30)
                finalTitle = String(trimmedContent[..<index]) + "..."
            }
        }

        // Use empty array if no tags
        if finalTags == nil {
            finalTags = []
        }

        let note = Note(
            title: finalTitle!,
            content: content,
            tags: finalTags!,
            sourceTranscriptionID: sourceTranscriptionID
        )
        let creationContext = ModelContext(modelContext.container)
        creationContext.insert(note)

        do {
            try creationContext.save()
        } catch {
            throw NotesStoreError.saveFailed(error.localizedDescription)
        }
        invalidateUniqueTagsCache()

        let noteID = note.id
        var descriptor = FetchDescriptor<Note>(
            predicate: #Predicate<Note> { $0.id == noteID }
        )
        descriptor.fetchLimit = 1
        do {
            guard let durableNote = try modelContext.fetch(descriptor).first else {
                throw NotesStoreError.noteNotFound(note.id)
            }
            return durableNote
        } catch let error as NotesStoreError {
            throw error
        } catch {
            throw NotesStoreError.fetchFailed(error.localizedDescription)
        }
    }

    /// Checks durable note existence from a context that cannot return a stale registered model.
    public func contains(id: UUID) throws -> Bool {
        let context = ModelContext(modelContext.container)
        var descriptor = FetchDescriptor<Note>(
            predicate: #Predicate<Note> { note in
                note.id == id
            }
        )
        descriptor.fetchLimit = 1

        do {
            return try context.fetch(descriptor).first != nil
        } catch {
            throw NotesStoreError.fetchFailed(error.localizedDescription)
        }
    }

    /// Appends a committed transcript to a durable note.
    ///
    /// The first originating transcription remains authoritative when a note
    /// receives multiple append operations.
    @discardableResult
    public func appendTranscript(
        to noteID: UUID,
        content: String,
        sourceTranscriptionID: UUID
    ) throws -> NoteAppendResult {
        let context = ModelContext(modelContext.container)
        var descriptor = FetchDescriptor<Note>(
            predicate: #Predicate<Note> { note in
                note.id == noteID
            }
        )
        descriptor.fetchLimit = 1

        let note: Note
        do {
            guard let fetchedNote = try context.fetch(descriptor).first else {
                throw NotesStoreError.noteNotFound(noteID)
            }
            note = fetchedNote
        } catch let error as NotesStoreError {
            throw error
        } catch {
            throw NotesStoreError.fetchFailed(error.localizedDescription)
        }

        note.content = NoteContentAppend.append(transcript: content, to: note.content)
        let effectiveSourceTranscriptionID = note.sourceTranscriptionID ?? sourceTranscriptionID
        if note.sourceTranscriptionID == nil {
            note.sourceTranscriptionID = effectiveSourceTranscriptionID
        }
        note.updatedAt = Date()

        do {
            try context.save()
        } catch {
            throw NotesStoreError.saveFailed(error.localizedDescription)
        }

        return NoteAppendResult(
            noteID: note.id,
            content: note.content,
            sourceTranscriptionID: effectiveSourceTranscriptionID
        )
    }

    public func fetchAll() throws -> [Note] {
        let descriptor = FetchDescriptor<Note>(
            sortBy: [SortDescriptor(\.updatedAt, order: .reverse)]
        )

        do {
            return try modelContext.fetch(descriptor)
        } catch {
            throw NotesStoreError.fetchFailed(error.localizedDescription)
        }
    }

    public func fetch(limit: Int) throws -> [Note] {
        var descriptor = FetchDescriptor<Note>(
            sortBy: [SortDescriptor(\.updatedAt, order: .reverse)]
        )
        descriptor.fetchLimit = limit

        do {
            return try modelContext.fetch(descriptor)
        } catch {
            throw NotesStoreError.fetchFailed(error.localizedDescription)
        }
    }

    public func update(_ note: Note) throws {
        note.updatedAt = Date()

        do {
            try modelContext.save()
            invalidateUniqueTagsCache()
        } catch {
            throw NotesStoreError.saveFailed(error.localizedDescription)
        }
    }

    public func delete(_ note: Note) throws {
        modelContext.delete(note)

        do {
            try modelContext.save()
            invalidateUniqueTagsCache()
        } catch {
            throw NotesStoreError.deleteFailed(error.localizedDescription)
        }
    }

    public func deleteAll() throws {
        do {
            try modelContext.delete(model: Note.self)
            try modelContext.save()
            invalidateUniqueTagsCache()
        } catch {
            throw NotesStoreError.deleteFailed(error.localizedDescription)
        }
    }

    public func search(query: String) throws -> [Note] {
        let predicate = #Predicate<Note> { note in
            note.title.localizedStandardContains(query) ||
            note.content.localizedStandardContains(query)
        }

        let descriptor = FetchDescriptor<Note>(
            predicate: predicate,
            sortBy: [SortDescriptor(\.updatedAt, order: .reverse)]
        )

        do {
            return try modelContext.fetch(descriptor)
        } catch {
            throw NotesStoreError.searchFailed(error.localizedDescription)
        }
    }

    public func togglePin(_ note: Note) throws {
        note.isPinned.toggle()
        note.updatedAt = Date()

        do {
            try modelContext.save()
            // Pin state does not affect tags; keep cache.
        } catch {
            throw NotesStoreError.saveFailed(error.localizedDescription)
        }
    }

    /// Unique note tags, alphabetically sorted.
    ///
    /// Uses a lightweight tags-only projection (no `updatedAt` sort / full-model
    /// materialization) and an in-memory cache invalidated on tag-affecting writes.
    public func getAllUniqueTags() throws -> [String] {
        if let uniqueTagsCache {
            return uniqueTagsCache
        }
        do {
            // A dedicated context avoids reusing registered models whose values
            // predate a background editor save in another context.
            let projectionContext = ModelContext(modelContext.container)
            let tags = try NotesTagsProjection.uniqueTags(from: projectionContext)
            uniqueTagsCache = tags
            return tags
        } catch NotesTagsProjectionError.fetchFailed(let message) {
            throw NotesStoreError.fetchFailed(message)
        }
    }

    /// Async path that projects tags on a background model actor when the cache is cold.
    public func getAllUniqueTagsAsync() async throws -> [String] {
        if let uniqueTagsCache {
            return uniqueTagsCache
        }
        let generation = uniqueTagsCacheGeneration
        do {
            let tags = try await tagsWorker.uniqueTags()
            guard generation == uniqueTagsCacheGeneration else {
                // A write landed while the background context was fetching. Do not
                // publish its pre-write projection over the invalidation.
                return try getAllUniqueTags()
            }
            uniqueTagsCache = tags
            return tags
        } catch {
            // Fall back to the lightweight synchronous projection.
            return try getAllUniqueTags()
        }
    }

    private func invalidateUniqueTagsCache() {
        uniqueTagsCacheGeneration &+= 1
        uniqueTagsCache = nil
    }
}

// MARK: - Tags change observer (nonisolated for deinit)

/// Owns the NotificationCenter observer token so teardown can run from
/// nonisolated `deinit` without reading MainActor-isolated stored properties
/// on `NotesStore`.
private final class NotesTagsChangeObserverRegistration: @unchecked Sendable {
    private let lock = NSLock()
    private var token: NSObjectProtocol?

    /// Installs a new observer token, removing any previous one.
    func install(_ token: NSObjectProtocol) {
        lock.lock()
        let previous = self.token
        self.token = token
        lock.unlock()
        if let previous {
            NotificationCenter.default.removeObserver(previous)
        }
    }

    /// Idempotent: removes the observer and clears the stored token.
    func tearDown() {
        lock.lock()
        let token = self.token
        self.token = nil
        lock.unlock()
        if let token {
            NotificationCenter.default.removeObserver(token)
        }
    }
}

private enum NotesTagsProjectionError: Error {
    case fetchFailed(String)
}

/// Tags-only projection shared by the main-context and background paths.
private enum NotesTagsProjection {
    static func uniqueTags(from context: ModelContext) throws -> [String] {
        var descriptor = FetchDescriptor<Note>()
        // No sort - tag aggregation does not care about updatedAt order.
        descriptor.propertiesToFetch = [\.tags]

        let notes: [Note]
        do {
            notes = try context.fetch(descriptor)
        } catch {
            throw NotesTagsProjectionError.fetchFailed(error.localizedDescription)
        }

        var tagSet = Set<String>()
        tagSet.reserveCapacity(notes.count)
        for note in notes {
            tagSet.formUnion(note.tags)
        }
        return tagSet.sorted()
    }
}

/// Background SwiftData projection for unique note tags.
/// Keeps full-library tag aggregation off the main context when callers can await.
@ModelActor
private actor NotesTagsProjectionWorker {
    func uniqueTags() throws -> [String] {
        try NotesTagsProjection.uniqueTags(from: modelContext)
    }
}
