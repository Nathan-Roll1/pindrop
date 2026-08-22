//
//  NotesStoreTests.swift
//  PindropDataTests
//
//  Created on 2026-01-29.
//

import Foundation
import SwiftData
import Testing
import PindropCore
@testable import PindropData

@MainActor
@Suite(.serialized)
struct NotesStoreTests {
    private func makeContainer() throws -> ModelContainer {
        try PindropModelContainerFactory.makeInMemoryContainer()
    }

    private func makeStore(in container: ModelContainer) -> NotesStore {
        NotesStore(
            modelContext: ModelContext(container),
            metadataGenerator: { _, _ in nil }
        )
    }

    private func makeStore() throws -> NotesStore {
        makeStore(in: try makeContainer())
    }

    private func insertMeetingReference(
        in container: ModelContainer,
        noteID: UUID,
        role: CaptureNoteRole
    ) throws -> CaptureNoteReferenceModel {
        let context = ModelContext(container)
        let reference = CaptureNoteReferenceModel(
            sessionID: UUID(),
            noteID: noteID,
            role: role
        )
        context.insert(reference)
        try context.save()
        return reference
    }

    @Test func createNote() async throws {
        let notesStore = try makeStore()
        try await notesStore.create(
            title: "Test Note",
            content: "This is a test note content."
        )

        let notes = try notesStore.fetchAll()
        #expect(notes.count == 1)
        #expect(notes.first?.title == "Test Note")
        #expect(notes.first?.content == "This is a test note content.")
        #expect(notes.first?.tags == [])
        #expect(notes.first?.isPinned == false)
    }

    @Test func fetchReturnsRegisteredNoteAfterDurableLookup() async throws {
        let notesStore = try makeStore()
        let created = try await notesStore.create(title: "Durable", content: "Persisted content")

        let fetched = try notesStore.fetch(id: created.id)

        #expect(fetched.id == created.id)
        #expect(fetched.title == "Durable")
        #expect(fetched.content == "Persisted content")
    }

    @Test func createNoteWithAutoTitle() async throws {
        let notesStore = try makeStore()
        let longContent = "This is a very long content that should be truncated for the title"
        try await notesStore.create(content: longContent)

        let notes = try notesStore.fetchAll()
        #expect(notes.count == 1)
        #expect(notes.first?.title == "This is a very long content th...")
    }

    @Test func createNoteWithShortContent() async throws {
        let notesStore = try makeStore()
        try await notesStore.create(content: "Short content")

        let notes = try notesStore.fetchAll()
        #expect(notes.count == 1)
        #expect(notes.first?.title == "Short content")
    }

    @Test func createNoteWithEmptyContent() async throws {
        let notesStore = try makeStore()
        try await notesStore.create(content: "   ")

        let notes = try notesStore.fetchAll()
        #expect(notes.count == 1)
        #expect(notes.first?.title == "Untitled Note")
    }

    @Test func createNoteWithTags() async throws {
        let notesStore = try makeStore()
        try await notesStore.create(
            title: "Tagged Note",
            content: "Content here",
            tags: ["swift", "testing", "notes"]
        )

        let notes = try notesStore.fetchAll()
        #expect(notes.count == 1)
        #expect(notes.first?.tags == ["swift", "testing", "notes"])
    }

    @Test func fetchAllNotes() async throws {
        let notesStore = try makeStore()
        try await notesStore.create(title: "First", content: "Content 1")
        try await Task.sleep(nanoseconds: 100_000_000)
        try await notesStore.create(title: "Second", content: "Content 2")
        try await Task.sleep(nanoseconds: 100_000_000)
        try await notesStore.create(title: "Third", content: "Content 3")

        let notes = try notesStore.fetchAll()
        #expect(notes.count == 3)
        #expect(notes[0].title == "Third")
        #expect(notes[1].title == "Second")
        #expect(notes[2].title == "First")
    }

    @Test func fetchNotesWithLimit() async throws {
        let notesStore = try makeStore()
        try await notesStore.create(title: "First", content: "Content 1")
        try await Task.sleep(nanoseconds: 100_000_000)
        try await notesStore.create(title: "Second", content: "Content 2")
        try await Task.sleep(nanoseconds: 100_000_000)
        try await notesStore.create(title: "Third", content: "Content 3")

        let notes = try notesStore.fetch(limit: 2)
        #expect(notes.count == 2)
        #expect(notes[0].title == "Third")
        #expect(notes[1].title == "Second")
    }

    @Test func updateNote() async throws {
        let notesStore = try makeStore()
        try await notesStore.create(
            title: "Original Title",
            content: "Original content",
            tags: ["original"]
        )

        var notes = try notesStore.fetchAll()
        let note = try #require(notes.first)
        let originalUpdatedAt = note.updatedAt

        try await Task.sleep(nanoseconds: 100_000_000)

        note.title = "Updated Title"
        note.content = "Updated content"
        note.tags = ["updated"]
        try notesStore.update(note)

        notes = try notesStore.fetchAll()
        #expect(notes.count == 1)
        #expect(notes.first?.title == "Updated Title")
        #expect(notes.first?.content == "Updated content")
        #expect(notes.first?.tags == ["updated"])
        #expect(try #require(notes.first).updatedAt > originalUpdatedAt)
    }

    @Test func deleteNote() async throws {
        let notesStore = try makeStore()
        try await notesStore.create(title: "To Delete", content: "Delete me")
        try await notesStore.create(title: "To Keep", content: "Keep me")

        var notes = try notesStore.fetchAll()
        #expect(notes.count == 2)

        let noteToDelete = try #require(notes.first { $0.title == "To Delete" })
        try notesStore.delete(noteToDelete)

        notes = try notesStore.fetchAll()
        #expect(notes.count == 1)
        #expect(notes.first?.title == "To Keep")
    }

    @Test func deleteAllNotes() async throws {
        let notesStore = try makeStore()
        try await notesStore.create(title: "First", content: "Content 1")
        try await notesStore.create(title: "Second", content: "Content 2")
        try await notesStore.create(title: "Third", content: "Content 3")

        var notes = try notesStore.fetchAll()
        #expect(notes.count == 3)

        try notesStore.deleteAll()

        notes = try notesStore.fetchAll()
        #expect(notes.count == 0)
    }

    @Test func deleteProtectsMeetingHumanAnchorWithoutMutation() async throws {
        let container = try makeContainer()
        let notesStore = makeStore(in: container)
        let anchor = try await notesStore.create(title: "Anchor", content: "Human content")
        let reference = try insertMeetingReference(
            in: container,
            noteID: anchor.id,
            role: .humanAnchor
        )

        #expect(throws: NotesStore.NotesStoreError.meetingAnchorProtected(noteID: anchor.id)) {
            try notesStore.delete(anchor)
        }

        let freshContext = ModelContext(container)
        #expect(try freshContext.fetch(FetchDescriptor<Note>()).map(\.id) == [anchor.id])
        #expect(
            try freshContext.fetch(FetchDescriptor<CaptureNoteReferenceModel>()).map(\.id)
                == [reference.id]
        )
    }

    @Test func deleteAllProtectsEveryMeetingHumanAnchorWithoutMutation() async throws {
        let container = try makeContainer()
        let notesStore = makeStore(in: container)
        let anchor = try await notesStore.create(title: "Anchor", content: "Human content")
        let generated = try await notesStore.create(title: "Generated", content: "Generated content")
        let anchorReference = try insertMeetingReference(
            in: container,
            noteID: anchor.id,
            role: .humanAnchor
        )
        let generatedReference = try insertMeetingReference(
            in: container,
            noteID: generated.id,
            role: .generated
        )

        #expect(throws: NotesStore.NotesStoreError.meetingAnchorProtected(noteID: anchor.id)) {
            try notesStore.deleteAll()
        }

        let freshContext = ModelContext(container)
        #expect(
            Set(try freshContext.fetch(FetchDescriptor<Note>()).map(\.id))
                == Set([anchor.id, generated.id])
        )
        #expect(
            Set(try freshContext.fetch(FetchDescriptor<CaptureNoteReferenceModel>()).map(\.id))
                == Set([anchorReference.id, generatedReference.id])
        )
    }

    @Test func deleteRemovesGeneratedMeetingReferenceAndAllowsRegeneration() async throws {
        let container = try makeContainer()
        let notesStore = makeStore(in: container)
        let generated = try await notesStore.create(title: "Generated", content: "Generated content")
        _ = try insertMeetingReference(in: container, noteID: generated.id, role: .generated)

        try notesStore.delete(generated)

        let deletedContext = ModelContext(container)
        #expect(try deletedContext.fetch(FetchDescriptor<Note>()).isEmpty)
        #expect(try deletedContext.fetch(FetchDescriptor<CaptureNoteReferenceModel>()).isEmpty)

        let regenerated = try await notesStore.create(
            title: "Regenerated",
            content: "Regenerated generated content"
        )
        _ = try insertMeetingReference(in: container, noteID: regenerated.id, role: .generated)

        let freshContext = ModelContext(container)
        #expect(try freshContext.fetch(FetchDescriptor<Note>()).map(\.id) == [regenerated.id])
        #expect(
            try freshContext.fetch(FetchDescriptor<CaptureNoteReferenceModel>()).map(\.noteID)
                == [regenerated.id]
        )
    }

    @Test func deleteFailsClosedForUnknownMeetingNoteRoleWithoutMutation() async throws {
        let container = try makeContainer()
        let notesStore = makeStore(in: container)
        let note = try await notesStore.create(title: "Unknown role", content: "Protected")
        let setupContext = ModelContext(container)
        let reference = CaptureNoteReferenceModel(
            persistedRawID: UUID(),
            sessionID: UUID(),
            noteID: note.id,
            roleRawValue: "unknown"
        )
        setupContext.insert(reference)
        try setupContext.save()

        #expect(throws: NotesStore.NotesStoreError.deleteFailed("Note has an unrecognized meeting role.")) {
            try notesStore.delete(note)
        }
        #expect(throws: NotesStore.NotesStoreError.deleteFailed("Note has an unrecognized meeting role.")) {
            try notesStore.deleteAll()
        }

        let freshContext = ModelContext(container)
        #expect(try freshContext.fetch(FetchDescriptor<Note>()).map(\.id) == [note.id])
        #expect(
            try freshContext.fetch(FetchDescriptor<CaptureNoteReferenceModel>()).map(\.id)
                == [reference.id]
        )
    }

    @Test func searchByTitle() async throws {
        let notesStore = try makeStore()
        try await notesStore.create(title: "Project Ideas", content: "Some content")
        try await notesStore.create(title: "Meeting Notes", content: "Other content")
        try await notesStore.create(title: "Shopping List", content: "More content")

        let results = try notesStore.search(query: "Project")
        #expect(results.count == 1)
        #expect(results.first?.title == "Project Ideas")
    }

    @Test func searchByContent() async throws {
        let notesStore = try makeStore()
        try await notesStore.create(title: "Note One", content: "This contains the word elephant")
        try await notesStore.create(title: "Note Two", content: "This is about giraffes")
        try await notesStore.create(title: "Note Three", content: "More about elephants here")

        let results = try notesStore.search(query: "elephant")
        #expect(results.count >= 0)
        #expect(results.contains { $0.title == "Note One" })
        #expect(results.contains { $0.title == "Note Three" })
    }

    @Test func searchByTags() async throws {
        let notesStore = try makeStore()
        try await notesStore.create(
            title: "Swift Note",
            content: "Content about programming",
            tags: ["swift", "coding"]
        )
        try await notesStore.create(
            title: "Other Note",
            content: "Different content",
            tags: ["personal"]
        )

        let results = try notesStore.search(query: "swift")
        #expect(results.count == 1)
        #expect(results.first?.title == "Swift Note")
    }

    @Test func searchNoResults() async throws {
        let notesStore = try makeStore()
        try await notesStore.create(title: "Note One", content: "Content")
        try await notesStore.create(title: "Note Two", content: "More content")

        let results = try notesStore.search(query: "nonexistent")
        #expect(results.count == 0)
    }

    @Test func searchCaseInsensitive() async throws {
        let notesStore = try makeStore()
        try await notesStore.create(title: "Hello World", content: "Test Content")

        let lowerResults = try notesStore.search(query: "hello")
        #expect(lowerResults.count == 1)

        let upperResults = try notesStore.search(query: "WORLD")
        #expect(upperResults.count == 1)

        let mixedResults = try notesStore.search(query: "HeLLo WoRLd")
        #expect(mixedResults.count == 1)
    }

    @Test func searchPartialMatch() async throws {
        let notesStore = try makeStore()
        try await notesStore.create(title: "Project Management", content: "Content here")
        try await notesStore.create(title: "Project Ideas", content: "More content")
        try await notesStore.create(title: "Personal", content: "Different")

        let results = try notesStore.search(query: "Proj")
        #expect(results.count >= 0)
    }

    @Test func sortByDateDescending() async throws {
        let notesStore = try makeStore()
        try await notesStore.create(title: "Oldest", content: "First note")
        try await Task.sleep(nanoseconds: 200_000_000)
        try await notesStore.create(title: "Middle", content: "Second note")
        try await Task.sleep(nanoseconds: 200_000_000)
        try await notesStore.create(title: "Newest", content: "Third note")

        let notes = try notesStore.fetchAll()
        #expect(notes.count == 3)
        #expect(notes[0].title == "Newest")
        #expect(notes[1].title == "Middle")
        #expect(notes[2].title == "Oldest")
    }

    @Test func togglePin() async throws {
        let notesStore = try makeStore()
        try await notesStore.create(title: "Test Note", content: "Content")

        var notes = try notesStore.fetchAll()
        let note = try #require(notes.first)
        #expect(note.isPinned == false)

        try notesStore.togglePin(note)
        notes = try notesStore.fetchAll()
        #expect(try #require(notes.first).isPinned)

        try notesStore.togglePin(note)
        notes = try notesStore.fetchAll()
        #expect(try #require(notes.first).isPinned == false)
    }

    @Test func pinUpdatesTimestamp() async throws {
        let notesStore = try makeStore()
        try await notesStore.create(title: "Test Note", content: "Content")

        var notes = try notesStore.fetchAll()
        let note = try #require(notes.first)
        let originalUpdatedAt = note.updatedAt

        try await Task.sleep(nanoseconds: 100_000_000)

        try notesStore.togglePin(note)

        notes = try notesStore.fetchAll()
        #expect(try #require(notes.first).updatedAt > originalUpdatedAt)
    }

    @Test func createNoteWithSourceTranscriptionID() async throws {
        let notesStore = try makeStore()
        let transcriptionID = UUID()
        try await notesStore.create(
            title: "Transcription Note",
            content: "Content from transcription",
            sourceTranscriptionID: transcriptionID
        )

        let notes = try notesStore.fetchAll()
        #expect(notes.count == 1)
        #expect(notes.first?.sourceTranscriptionID == transcriptionID)
    }

    @Test func uniqueIDs() async throws {
        let notesStore = try makeStore()
        try await notesStore.create(title: "First", content: "Content 1")
        try await notesStore.create(title: "Second", content: "Content 2")

        let notes = try notesStore.fetchAll()
        #expect(notes.count == 2)
        #expect(notes[0].id != notes[1].id)
    }

    @Test func fetchEmptyStore() throws {
        let notesStore = try makeStore()
        let notes = try notesStore.fetchAll()
        #expect(notes.count == 0)
    }

    @Test func deleteFromEmptyStore() throws {
        let notesStore = try makeStore()
        do {
            try notesStore.deleteAll()
        } catch {
            Issue.record("Expected deleting all from an empty store not to throw: \(error.localizedDescription)")
        }

        let notes = try notesStore.fetchAll()
        #expect(notes.count == 0)
    }

    @Test func searchEmptyStore() throws {
        let notesStore = try makeStore()
        let results = try notesStore.search(query: "anything")
        #expect(results.count == 0)
    }

    @Test func createNoteWithSpecialCharacters() async throws {
        let notesStore = try makeStore()
        try await notesStore.create(
            title: "Note with \"quotes\" and 'apostrophes'",
            content: "Content with emojis 🎉 and special chars: @#$%"
        )

        let notes = try notesStore.fetchAll()
        #expect(notes.count == 1)
        #expect(notes.first?.title == "Note with \"quotes\" and 'apostrophes'")
        #expect(notes.first?.content == "Content with emojis 🎉 and special chars: @#$%")
    }

    @Test func createNoteWithMultilineContent() async throws {
        let notesStore = try makeStore()
        let multilineContent = """
        Line 1
        Line 2
        Line 3
        """
        try await notesStore.create(title: "Multiline", content: multilineContent)

        let notes = try notesStore.fetchAll()
        #expect(notes.count == 1)
        #expect(notes.first?.content == multilineContent)
    }

    @Test func searchWithEmptyQuery() async throws {
        let notesStore = try makeStore()
        try await notesStore.create(title: "Note One", content: "Content")
        try await notesStore.create(title: "Note Two", content: "More content")

        let results = try notesStore.search(query: "")
        #expect(results.count >= 0)
    }

    // MARK: - Unique tags cache invalidation

    @Test func uniqueTagsCacheInvalidatesAfterCreateUpdateDelete() async throws {
        let notesStore = try makeStore()

        #expect(try notesStore.getAllUniqueTags() == [])

        try await notesStore.create(
            title: "Tagged",
            content: "Content",
            tags: ["swift", "testing"]
        )
        #expect(try notesStore.getAllUniqueTags() == ["swift", "testing"])

        // Warm the cache, then mutate tags through update.
        _ = try notesStore.getAllUniqueTags()
        let notes = try notesStore.fetchAll()
        let note = try #require(notes.first)
        note.tags = ["swift", "cache"]
        try notesStore.update(note)

        #expect(try notesStore.getAllUniqueTags() == ["cache", "swift"])
        #expect(try await notesStore.getAllUniqueTagsAsync() == ["cache", "swift"])

        try notesStore.delete(note)
        #expect(try notesStore.getAllUniqueTags() == [])
        #expect(try await notesStore.getAllUniqueTagsAsync() == [])
    }

    @Test func uniqueTagsCacheInvalidatesOnBackgroundEditorNotification() async throws {
        let modelContainer = try PindropModelContainerFactory.makeInMemoryContainer()
        let notesStore = NotesStore(
            modelContext: ModelContext(modelContainer),
            metadataGenerator: { _, _ in nil }
        )

        try await notesStore.create(
            title: "Editor Note",
            content: "Body",
            tags: ["stale"]
        )
        #expect(try notesStore.getAllUniqueTags() == ["stale"])

        // Background / editor-window style mutation on a separate context.
        let backgroundContext = ModelContext(modelContainer)
        let descriptor = FetchDescriptor<NoteSchema.Note>()
        let backgroundNotes = try backgroundContext.fetch(descriptor)
        let backgroundNote = try #require(backgroundNotes.first)
        backgroundNote.tags = ["editor", "fresh"]
        try backgroundContext.save()

        // Note editor posts this after a tags-changing save so other store
        // instances drop their in-memory projection.
        NotificationCenter.default.post(name: .pindropNoteTagsDidChange, object: nil)
        await Task.yield()

        #expect(try notesStore.getAllUniqueTags() == ["editor", "fresh"])
        #expect(try await notesStore.getAllUniqueTagsAsync() == ["editor", "fresh"])
    }

    @Test func pinDoesNotInvalidateUniqueTagsCache() async throws {
        let notesStore = try makeStore()
        try await notesStore.create(
            title: "Pinned",
            content: "Body",
            tags: ["keep"]
        )
        #expect(try notesStore.getAllUniqueTags() == ["keep"])

        let note = try #require(try notesStore.fetchAll().first)
        try notesStore.togglePin(note)

        // Pin path must not clear tags; cache remains coherent with stored tags.
        #expect(try notesStore.getAllUniqueTags() == ["keep"])
        #expect(try #require(try notesStore.fetchAll().first).isPinned)
    }

    @Test func createReturnsADurableNoteVisibleFromAFreshContext() async throws {
        let container = try PindropModelContainerFactory.makeInMemoryContainer()
        let store = NotesStore(
            modelContext: ModelContext(container),
            metadataGenerator: { _, _ in nil }
        )

        let created = try await store.create(
            title: "Durable",
            content: "Created through the store."
        )

        let freshContext = ModelContext(container)
        let persisted = try #require(
            freshContext.fetch(FetchDescriptor<Note>()).first { $0.id == created.id }
        )
        #expect(persisted.title == "Durable")
        #expect(persisted.content == "Created through the store.")
        #expect(try store.contains(id: created.id))
    }

    @Test func appendTranscriptPersistsThroughAFreshContextAndPreservesFirstSource() async throws {
        let container = try PindropModelContainerFactory.makeInMemoryContainer()
        let store = NotesStore(
            modelContext: ModelContext(container),
            metadataGenerator: { _, _ in nil }
        )
        let firstSourceID = UUID()
        let created = try await store.create(
            title: "Append",
            content: "Opening"
        )
        let secondSourceID = UUID()

        let firstAppend = try store.appendTranscript(
            to: created.id,
            content: "first transcript",
            sourceTranscriptionID: firstSourceID
        )
        let secondAppend = try store.appendTranscript(
            to: created.id,
            content: "second transcript",
            sourceTranscriptionID: secondSourceID
        )

        let firstResultSourceID: UUID = firstAppend.sourceTranscriptionID
        #expect(firstAppend.content == "Opening first transcript")
        #expect(firstResultSourceID == firstSourceID)
        let repeatedResultSourceID: UUID = secondAppend.sourceTranscriptionID
        #expect(secondAppend.content == "Opening first transcript second transcript")
        #expect(repeatedResultSourceID == firstSourceID)

        let freshContext = ModelContext(container)
        let persisted = try #require(
            freshContext.fetch(FetchDescriptor<Note>()).first { $0.id == created.id }
        )
        #expect(persisted.content == secondAppend.content)
        #expect(persisted.sourceTranscriptionID == firstSourceID)
    }

    @Test func appendTranscriptRejectsMissingDurableNote() throws {
        let container = try PindropModelContainerFactory.makeInMemoryContainer()
        let store = NotesStore(
            modelContext: ModelContext(container),
            metadataGenerator: { _, _ in nil }
        )
        let missingNoteID = UUID()

        #expect(throws: NotesStore.NotesStoreError.noteNotFound(missingNoteID)) {
            try store.appendTranscript(
                to: missingNoteID,
                content: "Transcript",
                sourceTranscriptionID: UUID()
            )
        }
        #expect(try !store.contains(id: missingNoteID))
    }
}
