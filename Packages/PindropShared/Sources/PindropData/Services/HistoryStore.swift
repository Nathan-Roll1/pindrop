//
//  HistoryStore.swift
//  PindropData
//
//  Created on 2026-01-25.
//

import Foundation
import SwiftData
import PindropCore

extension Notification.Name {
    public static let historyStoreDidChange = Notification.Name("tech.watzon.pindrop.historyStoreDidChange")
}

@MainActor
@Observable
public final class HistoryStore {

    public struct TranscriptionSnapshot {
        public let count: Int
        public let spokenDuration: TimeInterval
        private let searchedRecords: [TranscriptionRecord]?

        fileprivate init(
            count: Int,
            spokenDuration: TimeInterval,
            searchedRecords: [TranscriptionRecord]?
        ) {
            self.count = count
            self.spokenDuration = spokenDuration
            self.searchedRecords = searchedRecords
        }

        public func page(limit: Int, offset: Int) -> [TranscriptionRecord]? {
            guard let searchedRecords else { return nil }
            guard offset < searchedRecords.count else { return [] }
            let end = min(offset + limit, searchedRecords.count)
            return Array(searchedRecords[offset..<end])
        }
    }

    public struct TranscriptionAggregate: Sendable {
        public let count: Int
        public let spokenDuration: TimeInterval

        public init(count: Int, spokenDuration: TimeInterval) {
            self.count = count
            self.spokenDuration = spokenDuration
        }
    }
    
    public enum HistoryStoreError: Error, LocalizedError {
        case saveFailed(String)
        case fetchFailed(String)
        case deleteFailed(String)
        case searchFailed(String)
        case exportFailed(String)
        
        public var errorDescription: String? {
            switch self {
            case .saveFailed(let message):
                return "Failed to save transcription: \(message)"
            case .fetchFailed(let message):
                return "Failed to fetch transcriptions: \(message)"
            case .deleteFailed(let message):
                return "Failed to delete transcription: \(message)"
            case .searchFailed(let message):
                return "Failed to search transcriptions: \(message)"
            case .exportFailed(let message):
                return "Failed to export transcriptions: \(message)"
            }
        }
    }
    
    private let modelContext: ModelContext
    private let speakerIdentityService: (any SpeakerIdentityManaging)?
    private let contributionService: ContributionService?
    private let aggregationWorker: HistoryAggregationWorker

    public init(
        modelContext: ModelContext,
        speakerIdentityService: (any SpeakerIdentityManaging)? = nil,
        contributionService: ContributionService? = nil
    ) {
        self.modelContext = modelContext
        self.speakerIdentityService = speakerIdentityService
        self.contributionService = contributionService
        self.aggregationWorker = HistoryAggregationWorker(modelContainer: modelContext.container)
    }
    
    @discardableResult
    public func save(
        text: String,
        originalText: String? = nil,
        duration: TimeInterval,
        modelUsed: String,
        enhancedWith: String? = nil,
        diarizationSegmentsJSON: String? = nil,
        sourceKind: MediaSourceKind = .voiceRecording,
        sourceDisplayName: String? = nil,
        generatedTitle: String? = nil,
        aiSummary: String? = nil,
        sourceTitleOrigin: TranscriptionTitleOrigin? = nil,
        originalSourceURL: String? = nil,
        managedMediaPath: String? = nil,
        thumbnailPath: String? = nil,
        folderID: UUID? = nil,
        destinationAppName: String? = nil,
        destinationAppBundleID: String? = nil,
        wordCount: Int? = nil,
        speakerTrainingSegments: [DiarizedTranscriptSegment]? = nil,
        pipelineMetricsJSON: String? = nil
    ) throws -> TranscriptionRecord {
        // Always persist a word count for the final text; callers may pass an
        // explicit value (e.g. pre-computed) but we default to String.wordCount.
        let resolvedWordCount = wordCount ?? text.wordCount
        let record = TranscriptionRecord(
            text: text,
            originalText: originalText,
            duration: duration,
            modelUsed: modelUsed,
            enhancedWith: enhancedWith,
            diarizationSegmentsJSON: diarizationSegmentsJSON,
            sourceKind: sourceKind,
            sourceDisplayName: sourceDisplayName,
            generatedTitle: generatedTitle,
            aiSummary: aiSummary,
            sourceTitleOriginRawValue: sourceTitleOrigin?.rawValue,
            originalSourceURL: originalSourceURL,
            managedMediaPath: managedMediaPath,
            thumbnailPath: thumbnailPath,
            destinationAppName: destinationAppName,
            destinationAppBundleID: destinationAppBundleID,
            wordCount: resolvedWordCount,
            pipelineMetricsJSON: pipelineMetricsJSON
        )

        if let folderID,
           let folder = try fetchFolder(id: folderID) {
            record.folder = folder
        }
        
        modelContext.insert(record)

        do {
            try modelContext.save()
        } catch {
            throw HistoryStoreError.saveFailed(error.localizedDescription)
        }

        // The record is durable at this point. Notify consumers before attempting
        // optional speaker learning so a learning failure cannot report the save as
        // failed or leave history views stale.
        NotificationCenter.default.post(name: .historyStoreDidChange, object: nil)

        // Opt-in training-data capture: a genuine before/after pair exists only
        // when AI enhancement rewrote the text. Gated inside the service.
        if let originalText, originalText != text, enhancedWith != nil {
            contributionService?.recordAIEnhancementPair(
                input: originalText,
                target: text,
                modelUsed: modelUsed,
                enhancedWith: enhancedWith,
                sourceRecordID: record.id
            )
        }

        let dictationTrainingSegments = speakerTrainingSegments ?? record.diarizedSegments
        if sourceKind == .voiceRecording, !dictationTrainingSegments.isEmpty {
            learnFromDictationBestEffort(
                recordID: record.id,
                segments: dictationTrainingSegments
            )
        }

        return record
    }

    /// Applies a manual transcript edit from the library. `text` stays the single
    /// source of truth (copy/export/search all read it); the pre-edit value is
    /// captured transiently for the opt-in training contribution only.
    public func updateText(_ record: TranscriptionRecord, to newText: String) throws {
        let trimmedText = newText.trimmingCharacters(in: .whitespacesAndNewlines)
        let oldText = record.text
        guard !trimmedText.isEmpty, trimmedText != oldText else { return }

        record.text = trimmedText
        record.wordCount = trimmedText.wordCount
        record.userEditedAt = Date()

        do {
            try modelContext.save()
        } catch {
            throw HistoryStoreError.saveFailed(error.localizedDescription)
        }

        NotificationCenter.default.post(name: .historyStoreDidChange, object: nil)

        contributionService?.recordManualEdit(
            input: oldText,
            target: trimmedText,
            modelUsed: record.modelUsed,
            sourceRecordID: record.id
        )
    }

    public func fetchAll() throws -> [TranscriptionRecord] {
        let descriptor = FetchDescriptor<TranscriptionRecord>(
            sortBy: [SortDescriptor(\.timestamp, order: .reverse)]
        )
        
        do {
            return try modelContext.fetch(descriptor)
        } catch {
            throw HistoryStoreError.fetchFailed(error.localizedDescription)
        }
    }
    
    public func fetch(limit: Int) throws -> [TranscriptionRecord] {
        var descriptor = FetchDescriptor<TranscriptionRecord>(
            sortBy: [SortDescriptor(\.timestamp, order: .reverse)]
        )
        descriptor.fetchLimit = limit
        
        do {
            return try modelContext.fetch(descriptor)
        } catch {
            throw HistoryStoreError.fetchFailed(error.localizedDescription)
        }
    }

    public func fetchVoiceTranscriptions(
        limit: Int,
        offset: Int = 0,
        query: String = ""
    ) throws -> [TranscriptionRecord] {
        var descriptor = voiceTranscriptionsDescriptor(query: query)
        descriptor.fetchLimit = limit
        descriptor.fetchOffset = offset

        do {
            return try modelContext.fetch(descriptor)
        } catch {
            throw HistoryStoreError.fetchFailed(error.localizedDescription)
        }
    }

    public func fetchAllVoiceTranscriptions(query: String = "") throws -> [TranscriptionRecord] {
        let descriptor = voiceTranscriptionsDescriptor(query: query)

        do {
            return try modelContext.fetch(descriptor)
        } catch {
            throw HistoryStoreError.fetchFailed(error.localizedDescription)
        }
    }

    public func countVoiceTranscriptions(query: String = "") throws -> Int {
        let descriptor = voiceTranscriptionsDescriptor(query: query)

        do {
            return try modelContext.fetchCount(descriptor)
        } catch {
            throw HistoryStoreError.fetchFailed(error.localizedDescription)
        }
    }

    // MARK: - Unified fetch (all source kinds with optional filtering)

    public enum HistoryFilter: Equatable, Sendable {
        case all
        case voice
        case meetings
        case media
    }

    public func fetchTranscriptions(
        limit: Int,
        offset: Int = 0,
        query: String = "",
        filter: HistoryFilter = .all,
        sort: MediaLibrarySortMode = .newest
    ) throws -> [TranscriptionRecord] {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)

        // Empty search can paginate at the SQL layer. Non-empty search matches
        // title/summary/source in memory (Core Data cannot SQL-generate
        // optional-string CONTAINS via #Predicate coalescing).
        if trimmedQuery.isEmpty {
            var descriptor = transcriptionsDescriptor(query: "", filter: filter, sort: sort)
            descriptor.fetchLimit = limit
            descriptor.fetchOffset = offset
            do {
                return try modelContext.fetch(descriptor)
            } catch {
                throw HistoryStoreError.fetchFailed(error.localizedDescription)
            }
        }

        let allMatching = try fetchAllTranscriptions(query: trimmedQuery, filter: filter, sort: sort)
        guard offset < allMatching.count else { return [] }
        let end = min(offset + limit, allMatching.count)
        return Array(allMatching[offset..<end])
    }

    public func fetchAllTranscriptions(
        query: String = "",
        filter: HistoryFilter = .all,
        sort: MediaLibrarySortMode = .newest
    ) throws -> [TranscriptionRecord] {
        // Filter + sort in SQL; broaden search in memory for optional fields.
        let descriptor = transcriptionsDescriptor(query: "", filter: filter, sort: sort)

        do {
            var records = try modelContext.fetch(descriptor)
            let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmedQuery.isEmpty {
                // Parity with media-library search (title/summary/source + body).
                records = records.filter { $0.matchesMediaLibrarySearch(trimmedQuery) }
            }
            return records
        } catch {
            throw HistoryStoreError.fetchFailed(error.localizedDescription)
        }
    }

    public func countTranscriptions(
        query: String = "",
        filter: HistoryFilter = .all,
        sort: MediaLibrarySortMode = .newest
    ) throws -> Int {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedQuery.isEmpty {
            let descriptor = transcriptionsDescriptor(query: "", filter: filter, sort: sort)
            do {
                return try modelContext.fetchCount(descriptor)
            } catch {
                throw HistoryStoreError.fetchFailed(error.localizedDescription)
            }
        }
        return try fetchAllTranscriptions(query: trimmedQuery, filter: filter, sort: sort).count
    }

    /// Returns the count and total duration for a filter without loading transcript
    /// bodies. Searches intentionally use `transcriptionSnapshot` so their in-memory
    /// matching work is performed once and reused for pagination.
    public func transcriptionAggregate(filter: HistoryFilter = .all) async throws -> TranscriptionAggregate {
        do {
            return try await aggregationWorker.aggregate(filter: filter)
        } catch {
            throw HistoryStoreError.fetchFailed(error.localizedDescription)
        }
    }

    /// Produces one reload-scoped result. Empty searches use store-level count and
    /// duration projections; non-empty searches match off the main actor once so
    /// count, duration, and every page share the same result set.
    public func transcriptionSnapshot(
        query: String = "",
        filter: HistoryFilter = .all,
        sort: MediaLibrarySortMode = .newest
    ) async throws -> TranscriptionSnapshot {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuery.isEmpty else {
            let aggregate = try await transcriptionAggregate(filter: filter)
            return TranscriptionSnapshot(
                count: aggregate.count,
                spokenDuration: aggregate.spokenDuration,
                searchedRecords: nil
            )
        }

        let searchResult: HistorySearchResult
        do {
            searchResult = try await aggregationWorker.search(
                query: trimmedQuery,
                filter: filter,
                sort: sort
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw HistoryStoreError.searchFailed(error.localizedDescription)
        }

        try Task.checkCancellation()
        let records = try fetchTranscriptions(ids: searchResult.matchingIDs)
        return TranscriptionSnapshot(
            count: searchResult.matchingIDs.count,
            spokenDuration: searchResult.spokenDuration,
            searchedRecords: records
        )
    }

    /// Hydrates main-context records for an ordered ID list produced by a background search.
    public func fetchTranscriptions(ids: [UUID]) throws -> [TranscriptionRecord] {
        guard !ids.isEmpty else { return [] }

        let uniqueIDs = Array(Set(ids))
        let predicate = #Predicate<TranscriptionRecord> { record in
            uniqueIDs.contains(record.id)
        }
        let descriptor = FetchDescriptor<TranscriptionRecord>(predicate: predicate)

        do {
            let fetched = try modelContext.fetch(descriptor)
            let byID = Dictionary(uniqueKeysWithValues: fetched.map { ($0.id, $0) })
            return ids.compactMap { byID[$0] }
        } catch {
            throw HistoryStoreError.fetchFailed(error.localizedDescription)
        }
    }

    public func fetchRecord(with id: UUID) throws -> TranscriptionRecord? {
        var descriptor = FetchDescriptor<TranscriptionRecord>(
            predicate: #Predicate<TranscriptionRecord> { $0.id == id }
        )
        descriptor.fetchLimit = 1

        do {
            return try modelContext.fetch(descriptor).first
        } catch {
            throw HistoryStoreError.fetchFailed(error.localizedDescription)
        }
    }

    /// Attaches (or clears) the managed media path on an existing record after async encode.
    /// - Returns: `true` if the record was found and updated; `false` if no matching record exists
    ///   (caller should clean up any unlinked media files).
    @discardableResult
    public func updateManagedMediaPath(for recordID: UUID, path: String?) throws -> Bool {
        guard let record = try fetchRecord(with: recordID) else {
            Log.app.warning("updateManagedMediaPath: record \(recordID) not found")
            return false
        }
        record.managedMediaPath = path
        do {
            try modelContext.save()
            NotificationCenter.default.post(name: .historyStoreDidChange, object: nil)
            return true
        } catch {
            throw HistoryStoreError.saveFailed(error.localizedDescription)
        }
    }

    /// Lightweight projection used by dictation-audio retention maintenance.
    /// Avoids loading full transcript bodies for expiry sweeps.
    public struct ExpiredDictationMediaCandidate: Sendable, Equatable {
        public let recordID: UUID
        public let mediaPath: String

        public init(recordID: UUID, mediaPath: String) {
            self.recordID = recordID
            self.mediaPath = mediaPath
        }
    }

    /// Fetches a bounded page of voice-recording rows whose managed media is older than `cutoff`.
    /// Only `id` / path / timestamp fields are needed for deletion; transcript bodies stay unloaded.
    public func fetchExpiredDictationMediaCandidates(
        olderThan cutoff: Date,
        limit: Int
    ) throws -> [ExpiredDictationMediaCandidate] {
        let pageLimit = max(limit, 0)
        guard pageLimit > 0 else { return [] }

        let voiceRawValue = MediaSourceKind.voiceRecording.rawValue
        let predicate = #Predicate<TranscriptionRecord> { record in
            (record.sourceKindRawValue == nil || record.sourceKindRawValue == voiceRawValue)
                && record.timestamp < cutoff
                && record.managedMediaPath != nil
        }

        var descriptor = FetchDescriptor<TranscriptionRecord>(
            predicate: predicate,
            sortBy: [SortDescriptor(\.timestamp, order: .forward)]
        )
        descriptor.fetchLimit = pageLimit
        descriptor.propertiesToFetch = [\.id, \.managedMediaPath, \.timestamp, \.sourceKindRawValue]

        do {
            let records = try modelContext.fetch(descriptor)
            var candidates: [ExpiredDictationMediaCandidate] = []
            candidates.reserveCapacity(min(records.count, pageLimit))
            for record in records {
                // Preserve empty/whitespace paths so the sweep can still clear the field
                // and the page advances; only non-empty paths need filesystem deletion.
                let path = record.managedMediaPath?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                candidates.append(
                    ExpiredDictationMediaCandidate(recordID: record.id, mediaPath: path)
                )
            }
            return candidates
        } catch {
            throw HistoryStoreError.fetchFailed(error.localizedDescription)
        }
    }

    /// Clears `managedMediaPath` for the given record IDs in one save.
    /// Missing IDs are ignored. Returns the number of rows updated.
    @discardableResult
    public func clearManagedMediaPaths(for recordIDs: [UUID]) throws -> Int {
        guard !recordIDs.isEmpty else { return 0 }

        let uniqueIDs = Array(Set(recordIDs))
        let predicate = #Predicate<TranscriptionRecord> { record in
            uniqueIDs.contains(record.id)
        }
        let descriptor = FetchDescriptor<TranscriptionRecord>(predicate: predicate)

        do {
            let records = try modelContext.fetch(descriptor)
            var updated = 0
            for record in records where record.managedMediaPath != nil {
                record.managedMediaPath = nil
                updated += 1
            }
            guard updated > 0 else { return 0 }
            try modelContext.save()
            NotificationCenter.default.post(name: .historyStoreDidChange, object: nil)
            return updated
        } catch {
            throw HistoryStoreError.saveFailed(error.localizedDescription)
        }
    }

    /// Persists pending model changes without inserting a new record.
    public func saveContext() throws {
        do {
            try modelContext.save()
            NotificationCenter.default.post(name: .historyStoreDidChange, object: nil)
        } catch {
            throw HistoryStoreError.saveFailed(error.localizedDescription)
        }
    }

    public func fetchMediaRecords(limit: Int? = nil) throws -> [TranscriptionRecord] {
        // Preserve pre-optimization prefix(0)/empty semantics. SwiftData treats
        // fetchLimit == 0 as unlimited, so nonpositive limits must short-circuit
        // before any descriptor fetch. Negative values also return [].
        if let limit, limit <= 0 {
            return []
        }

        // Push media source-kind filter + newest timestamp sort into SQL so
        // voice/meeting rows are never materialized just to discard them.
        var descriptor = transcriptionsDescriptor(query: "", filter: .media, sort: .newest)
        if let limit {
            descriptor.fetchLimit = limit
        }

        do {
            return try modelContext.fetch(descriptor)
        } catch {
            throw HistoryStoreError.fetchFailed(error.localizedDescription)
        }
    }

    public func fetchFolders() throws -> [MediaFolder] {
        let descriptor = FetchDescriptor<MediaFolder>()

        do {
            return try modelContext.fetch(descriptor).sorted {
                $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
        } catch {
            throw HistoryStoreError.fetchFailed(error.localizedDescription)
        }
    }

    public func createFolder(named name: String) throws -> MediaFolder {
        let normalizedName = try normalizeFolderName(name)
        guard try !folderNameExists(normalizedName) else {
            throw HistoryStoreError.saveFailed("A folder named \"\(normalizedName)\" already exists.")
        }

        let folder = MediaFolder(name: normalizedName)
        modelContext.insert(folder)

        do {
            try modelContext.save()
            return folder
        } catch {
            throw HistoryStoreError.saveFailed(error.localizedDescription)
        }
    }

    public func renameFolder(_ folder: MediaFolder, to name: String) throws {
        let normalizedName = try normalizeFolderName(name)
        let existingFolders = try fetchFolders()
        let duplicate = existingFolders.contains {
            $0.id != folder.id && $0.trimmedName.compare(normalizedName, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
        }
        guard !duplicate else {
            throw HistoryStoreError.saveFailed("A folder named \"\(normalizedName)\" already exists.")
        }

        folder.name = normalizedName
        folder.updatedAt = Date()

        do {
            try modelContext.save()
        } catch {
            throw HistoryStoreError.saveFailed(error.localizedDescription)
        }
    }

    public func deleteFolder(_ folder: MediaFolder) throws {
        let records = try fetchMediaRecords().filter { $0.folder?.id == folder.id }
        records.forEach { $0.folder = nil }
        modelContext.delete(folder)

        do {
            try modelContext.save()
            NotificationCenter.default.post(name: .historyStoreDidChange, object: nil)
        } catch {
            throw HistoryStoreError.deleteFailed(error.localizedDescription)
        }
    }

    public func assign(record: TranscriptionRecord, to folder: MediaFolder) throws {
        record.folder = folder
        folder.updatedAt = Date()

        do {
            try modelContext.save()
        } catch {
            throw HistoryStoreError.saveFailed(error.localizedDescription)
        }
    }

    public func removeFromFolder(record: TranscriptionRecord) throws {
        record.folder?.updatedAt = Date()
        record.folder = nil

        do {
            try modelContext.save()
        } catch {
            throw HistoryStoreError.saveFailed(error.localizedDescription)
        }
    }

    public func assignSpeakerProfile(
        record: TranscriptionRecord,
        speakerID: String,
        profileID: UUID
    ) throws {
        let diarizedSegments = record.diarizedSegments
        guard !diarizedSegments.isEmpty, !speakerID.isEmpty else { return }

        var descriptor = FetchDescriptor<ParticipantProfile>(
            predicate: #Predicate { $0.id == profileID }
        )
        descriptor.fetchLimit = 1
        guard let profile = try modelContext.fetch(descriptor).first else {
            throw HistoryStoreError.saveFailed("The selected speaker profile no longer exists.")
        }

        let updatedSegments = diarizedSegments.map { segment in
            guard segment.speakerId == speakerID else {
                return segment
            }

            return DiarizedTranscriptSegment(
                speakerId: segment.speakerId,
                speakerLabel: profile.displayName,
                speakerProfileID: profile.id,
                speakerEmbedding: segment.speakerEmbedding,
                startTime: segment.startTime,
                endTime: segment.endTime,
                confidence: segment.confidence,
                text: segment.text
            )
        }

        do {
            let data = try JSONEncoder().encode(updatedSegments)
            record.diarizationSegmentsJSON = String(data: data, encoding: .utf8)
            try speakerIdentityService?.learnFromProfileAssignments(
                recordID: record.id,
                segments: updatedSegments,
                profileIDsBySpeakerID: [speakerID: profileID]
            )
            try modelContext.save()
            NotificationCenter.default.post(name: .historyStoreDidChange, object: nil)
        } catch {
            throw HistoryStoreError.saveFailed(error.localizedDescription)
        }
    }

    @discardableResult
    public func createAndAssignSpeakerProfile(
        record: TranscriptionRecord,
        speakerID: String,
        displayName: String,
        notes: String?
    ) throws -> ParticipantProfile {
        guard let speakerIdentityService else {
            throw HistoryStoreError.saveFailed("Speaker profiles are unavailable.")
        }

        do {
            let profile = try speakerIdentityService.createProfile(
                displayName: displayName,
                notes: notes
            )
            try assignSpeakerProfile(record: record, speakerID: speakerID, profileID: profile.id)
            return profile
        } catch {
            throw HistoryStoreError.saveFailed(error.localizedDescription)
        }
    }

    /// Clears a speaker's profile assignment on one record, restores generic labels by first
    /// appearance, deletes only rename-feedback evidence for that record/speaker, rebuilds
    /// affected profiles, and posts a single history notification.
    public func unassignSpeakerProfile(
        record: TranscriptionRecord,
        speakerID: String
    ) throws {
        let diarizedSegments = record.diarizedSegments
        guard !diarizedSegments.isEmpty, !speakerID.isEmpty else { return }
        guard diarizedSegments.contains(where: {
            $0.speakerId == speakerID && $0.speakerProfileID != nil
        }) else {
            return
        }

        let genericLabels = SpeakerIdentityService.genericSpeakerLabelsByFirstAppearance(
            from: diarizedSegments
        )
        let updatedSegments = diarizedSegments.map { segment in
            guard segment.speakerId == speakerID else { return segment }
            return DiarizedTranscriptSegment(
                speakerId: segment.speakerId,
                speakerLabel: genericLabels[segment.speakerId] ?? "Speaker 1",
                speakerProfileID: nil,
                speakerEmbedding: segment.speakerEmbedding,
                startTime: segment.startTime,
                endTime: segment.endTime,
                confidence: segment.confidence,
                text: segment.text
            )
        }

        do {
            let data = try JSONEncoder().encode(updatedSegments)
            record.diarizationSegmentsJSON = String(data: data, encoding: .utf8)
            if let identityService = speakerIdentityService as? SpeakerIdentityService {
                try identityService.removeTrainingEvidence(
                    recordID: record.id,
                    sourceSpeakerID: speakerID,
                    sourceType: SpeakerIdentityService.EvidenceSource.renameFeedback.rawValue,
                    saveChanges: false
                )
            } else {
                try speakerIdentityService?.removeTrainingEvidence(
                    recordID: record.id,
                    sourceSpeakerID: speakerID,
                    sourceType: SpeakerIdentityService.EvidenceSource.renameFeedback.rawValue
                )
            }
            try modelContext.save()
            NotificationCenter.default.post(name: .historyStoreDidChange, object: nil)
        } catch {
            throw HistoryStoreError.saveFailed(error.localizedDescription)
        }
    }

    public func hasSpeakerTrainingEvidence(for record: TranscriptionRecord) throws -> Bool {
        try speakerIdentityService?.hasTrainingEvidence(for: record.id) ?? false
    }

    public func removeFromSpeakerProfiles(_ record: TranscriptionRecord) throws {
        do {
            try speakerIdentityService?.removeTrainingEvidence(for: record.id)
            NotificationCenter.default.post(name: .historyStoreDidChange, object: nil)
        } catch {
            throw HistoryStoreError.saveFailed(error.localizedDescription)
        }
    }

    public func fetchMediaLibrary(
        folderID: UUID? = nil,
        query: String = "",
        sort: MediaLibrarySortMode = .newest
    ) throws -> [TranscriptionRecord] {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        // Media kind + timestamp sort live in the descriptor. Broadened
        // title/summary/source search, folder membership, and name sorts stay
        // in memory (optional strings / relationship id / localized compare).
        let descriptor = transcriptionsDescriptor(query: "", filter: .media, sort: sort)

        do {
            var records = try modelContext.fetch(descriptor)

            if folderID != nil || !trimmedQuery.isEmpty {
                records = records.filter { record in
                    if let folderID, record.folder?.id != folderID {
                        return false
                    }
                    if !trimmedQuery.isEmpty, !record.matchesMediaLibrarySearch(trimmedQuery) {
                        return false
                    }
                    return true
                }
            }

            switch sort {
            case .newest, .oldest:
                // Already ordered by SQL via transcriptionsDescriptor.
                return records
            case .nameAscending, .nameDescending:
                return sortMediaRecords(records, sort: sort)
            }
        } catch {
            throw HistoryStoreError.fetchFailed(error.localizedDescription)
        }
    }

    public func delete(_ record: TranscriptionRecord) throws {
        // Snapshot filesystem paths before mutating the store so cleanup can
        // run after a successful DB commit without rereading models.
        let mediaPaths = managedMediaPaths(for: record)
        try speakerIdentityService?.removeTrainingEvidence(for: record.id)
        modelContext.delete(record)

        do {
            try modelContext.save()
            // DB must commit before destructive filesystem work so a failed save
            // never leaves a live row pointing at already-removed files. Single-record
            // cleanup stays owned/synchronous after that commit: there is no durable
            // orphan-recovery job for these paths, and an unowned fire-and-forget task
            // can be lost at process termination, permanently orphaning managed media.
            Self.removeManagedMediaAssets(at: mediaPaths)
            NotificationCenter.default.post(name: .historyStoreDidChange, object: nil)
        } catch {
            throw HistoryStoreError.deleteFailed(error.localizedDescription)
        }
    }
    
    public func deleteAll() throws {
        do {
            let records = try fetchAll()
            // Snapshot filesystem paths before mutating the store so media cleanup
            // can run off-main after a successful DB commit without rereading models.
            let managedMediaPaths = records.flatMap(managedMediaPaths(for:))
            let recordIDs = records.map(\.id)

            if let speakerIdentityService = speakerIdentityService as? SpeakerIdentityService {
                try speakerIdentityService.removeTrainingEvidence(for: recordIDs)
            } else {
                // Protocol seam (tests / alternate services): preserve per-ID API.
                for recordID in recordIDs {
                    try speakerIdentityService?.removeTrainingEvidence(for: recordID)
                }
            }

            try modelContext.delete(model: TranscriptionRecord.self)
            try modelContext.save()

            // DB is durable first; filesystem cleanup is best-effort off-main so a
            // mid-delete crash cannot leave records pointing at already-removed files.
            Self.scheduleManagedMediaRemoval(paths: managedMediaPaths)

            NotificationCenter.default.post(name: .historyStoreDidChange, object: nil)
        } catch {
            throw HistoryStoreError.deleteFailed(error.localizedDescription)
        }
    }

    
    public func search(query: String) throws -> [TranscriptionRecord] {
        let predicate = #Predicate<TranscriptionRecord> { record in
            record.text.localizedStandardContains(query)
        }
        
        let descriptor = FetchDescriptor<TranscriptionRecord>(
            predicate: predicate,
            sortBy: [SortDescriptor(\.timestamp, order: .reverse)]
        )
        
        do {
            return try modelContext.fetch(descriptor)
        } catch {
            throw HistoryStoreError.searchFailed(error.localizedDescription)
        }
    }

    private func managedMediaPaths(for record: TranscriptionRecord) -> [String] {
        [record.managedMediaPath, record.thumbnailPath]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    // Single-record delete runs owned/synchronous filesystem cleanup after DB commit.
    // Bulk delete-all may still schedule best-effort off-main cleanup for throughput.

    /// Fire-and-forget filesystem cleanup after a durable bulk DB commit.
    private static func scheduleManagedMediaRemoval(paths: [String]) {
        guard !paths.isEmpty else { return }
        Task.detached(priority: .utility) {
            Self.removeManagedMediaAssets(at: paths)
        }
    }

    /// Shared path-based managed-media + peaks + empty-parent cleanup.
    /// `nonisolated` so delete-all can run it off the main actor after DB commit.
    nonisolated private static func removeManagedMediaAssets(at paths: [String]) {
        let fileManager = FileManager.default
        var parentDirectories = Set<String>()
        for path in paths {
            do {
                if fileManager.fileExists(atPath: path) {
                    try fileManager.removeItem(atPath: path)
                }
                // Remove waveform peaks sidecar next to managed audio when present.
                let audioURL = URL(fileURLWithPath: path)
                let peaksURL = WaveformPeaks.sidecarURL(for: audioURL)
                if fileManager.fileExists(atPath: peaksURL.path) {
                    try fileManager.removeItem(at: peaksURL)
                }
                parentDirectories.insert((path as NSString).deletingLastPathComponent)
            } catch {
                Log.app.warning("Failed to remove managed media asset at \(path): \(error.localizedDescription)")
            }
        }

        for directory in parentDirectories where !directory.isEmpty {
            do {
                let contents = try fileManager.contentsOfDirectory(atPath: directory)
                if contents.isEmpty {
                    try fileManager.removeItem(atPath: directory)
                }
            } catch {
                Log.app.debug("Skipping managed media directory cleanup for \(directory): \(error.localizedDescription)")
            }
        }
    }


    private func learnFromDictationBestEffort(
        recordID: UUID,
        segments: [DiarizedTranscriptSegment]
    ) {
        // Production learning gets a dedicated context so failed learning changes
        // are discarded with that context rather than remaining pending alongside
        // the saved transcription. Custom test/alternate services keep their
        // injected seam, with an explicit rollback of the shared context on error.
        let usesIsolatedContext = speakerIdentityService is SpeakerIdentityService

        do {
            if usesIsolatedContext {
                let learningContext = ModelContext(modelContext.container)
                let learningService = SpeakerIdentityService(modelContext: learningContext)
                try learningService.learnFromDictation(recordID: recordID, segments: segments)
            } else {
                try speakerIdentityService?.learnFromDictation(recordID: recordID, segments: segments)
            }
        } catch {
            if !usesIsolatedContext {
                modelContext.rollback()
            }
            Log.app.warning(
                "Saved transcription \(recordID) but speaker learning failed: \(error.localizedDescription)"
            )
        }
    }

    private func fetchFolder(id: UUID) throws -> MediaFolder? {
        let folders = try fetchFolders()
        return folders.first { $0.id == id }
    }

    private func folderNameExists(_ name: String) throws -> Bool {
        let folders = try fetchFolders()
        return folders.contains {
            $0.trimmedName.compare(name, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
        }
    }

    private func normalizeFolderName(_ name: String) throws -> String {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            throw HistoryStoreError.saveFailed("Folder name cannot be empty.")
        }
        return trimmedName
    }

    private func voiceTranscriptionsDescriptor(query: String) -> FetchDescriptor<TranscriptionRecord> {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let voiceRawValue = MediaSourceKind.voiceRecording.rawValue
        let sortDescriptors = [SortDescriptor<TranscriptionRecord>(\.timestamp, order: .reverse)]

        if trimmedQuery.isEmpty {
            let predicate = #Predicate<TranscriptionRecord> { record in
                record.sourceKindRawValue == nil || record.sourceKindRawValue == voiceRawValue
            }
            return FetchDescriptor(predicate: predicate, sortBy: sortDescriptors)
        }

        let predicate = #Predicate<TranscriptionRecord> { record in
            (record.sourceKindRawValue == nil || record.sourceKindRawValue == voiceRawValue)
                && record.text.localizedStandardContains(trimmedQuery)
        }
        return FetchDescriptor(predicate: predicate, sortBy: sortDescriptors)
    }

    private func transcriptionsSortDescriptors(
        for sort: MediaLibrarySortMode
    ) -> [SortDescriptor<TranscriptionRecord>] {
        // Library list currently exposes newest/oldest. Name sorts fall back to
        // newest-first at the SQL level (media library keeps its own in-memory sort).
        switch sort {
        case .oldest:
            return [SortDescriptor<TranscriptionRecord>(\.timestamp, order: .forward)]
        case .newest, .nameAscending, .nameDescending:
            return [SortDescriptor<TranscriptionRecord>(\.timestamp, order: .reverse)]
        }
    }

    private func transcriptionsDescriptor(
        query: String,
        filter: HistoryFilter,
        sort: MediaLibrarySortMode = .newest
    ) -> FetchDescriptor<TranscriptionRecord> {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let sortDescriptors = transcriptionsSortDescriptors(for: sort)

        let voiceRawValue = MediaSourceKind.voiceRecording.rawValue
        let manualCaptureRawValue = MediaSourceKind.manualCapture.rawValue
        let importedFileRawValue = MediaSourceKind.importedFile.rawValue
        let webLinkRawValue = MediaSourceKind.webLink.rawValue

        switch (filter, trimmedQuery.isEmpty) {
        case (.all, true):
            return FetchDescriptor(sortBy: sortDescriptors)

        case (.all, false):
            // Text-only SQL path kept for any callers that still pass a query
            // into the descriptor. `fetchTranscriptions` prefers in-memory
            // matching via `matchesLibrarySearch` for optional title/summary/source.
            let predicate = #Predicate<TranscriptionRecord> { record in
                record.text.localizedStandardContains(trimmedQuery)
            }
            return FetchDescriptor(predicate: predicate, sortBy: sortDescriptors)

        case (.voice, true):
            let predicate = #Predicate<TranscriptionRecord> { record in
                record.sourceKindRawValue == nil || record.sourceKindRawValue == voiceRawValue
            }
            return FetchDescriptor(predicate: predicate, sortBy: sortDescriptors)

        case (.voice, false):
            let predicate = #Predicate<TranscriptionRecord> { record in
                (record.sourceKindRawValue == nil || record.sourceKindRawValue == voiceRawValue)
                    && record.text.localizedStandardContains(trimmedQuery)
            }
            return FetchDescriptor(predicate: predicate, sortBy: sortDescriptors)

        case (.meetings, true):
            let predicate = #Predicate<TranscriptionRecord> { record in
                record.sourceKindRawValue == manualCaptureRawValue
            }
            return FetchDescriptor(predicate: predicate, sortBy: sortDescriptors)

        case (.meetings, false):
            let predicate = #Predicate<TranscriptionRecord> { record in
                record.sourceKindRawValue == manualCaptureRawValue
                    && record.text.localizedStandardContains(trimmedQuery)
            }
            return FetchDescriptor(predicate: predicate, sortBy: sortDescriptors)

        case (.media, true):
            let predicate = #Predicate<TranscriptionRecord> { record in
                record.sourceKindRawValue == importedFileRawValue
                    || record.sourceKindRawValue == webLinkRawValue
            }
            return FetchDescriptor(predicate: predicate, sortBy: sortDescriptors)

        case (.media, false):
            let predicate = #Predicate<TranscriptionRecord> { record in
                (record.sourceKindRawValue == importedFileRawValue
                    || record.sourceKindRawValue == webLinkRawValue)
                    && record.text.localizedStandardContains(trimmedQuery)
            }
            return FetchDescriptor(predicate: predicate, sortBy: sortDescriptors)
        }
    }

    private func sortMediaRecords(
        _ records: [TranscriptionRecord],
        sort: MediaLibrarySortMode
    ) -> [TranscriptionRecord] {
        switch sort {
        case .newest:
            return records.sorted { $0.timestamp > $1.timestamp }
        case .oldest:
            return records.sorted { $0.timestamp < $1.timestamp }
        case .nameAscending:
            return records.sorted {
                $0.mediaLibrarySortName.localizedStandardCompare($1.mediaLibrarySortName) == .orderedAscending
            }
        case .nameDescending:
            return records.sorted {
                $0.mediaLibrarySortName.localizedStandardCompare($1.mediaLibrarySortName) == .orderedDescending
            }
        }
    }
}

/// A dedicated SwiftData executor for history header aggregates and non-empty
/// library search. Keeps O(N) duration projection and text matching off the
/// main context/actor while empty-query SQL pagination stays on the store.
@ModelActor
private actor HistoryAggregationWorker {
    private static let searchBatchSize = 64

    func aggregate(
        filter: HistoryStore.HistoryFilter
    ) throws -> HistoryStore.TranscriptionAggregate {
        let descriptor = aggregateDescriptor(for: filter)
        let count = try modelContext.fetchCount(descriptor)
        var durationDescriptor = descriptor
        durationDescriptor.propertiesToFetch = [\.duration]
        let spokenDuration = try modelContext.fetch(durationDescriptor)
            .reduce(0) { $0 + max(0, $1.duration) }

        return HistoryStore.TranscriptionAggregate(
            count: count,
            spokenDuration: spokenDuration
        )
    }

    /// Filter-scoped fetch + broadened text match + duration reduce, with
    /// cooperative cancellation between batches.
    func search(
        query: String,
        filter: HistoryStore.HistoryFilter,
        sort: MediaLibrarySortMode
    ) async throws -> HistorySearchResult {
        try Task.checkCancellation()

        let descriptor = searchDescriptor(filter: filter, sort: sort)
        let candidates = try modelContext.fetch(descriptor)
        var matchingIDs: [UUID] = []
        matchingIDs.reserveCapacity(min(candidates.count, 256))
        var spokenDuration: TimeInterval = 0

        var index = 0
        while index < candidates.count {
            try Task.checkCancellation()
            let end = min(index + Self.searchBatchSize, candidates.count)
            for record in candidates[index..<end] {
                if Self.matchesMediaLibrarySearch(record, query: query) {
                    matchingIDs.append(record.id)
                    spokenDuration += max(0, record.duration)
                }
            }
            index = end
            // Yield so a superseded search generation can cancel between batches.
            await Task.yield()
        }

        return HistorySearchResult(
            matchingIDs: matchingIDs,
            spokenDuration: spokenDuration
        )
    }

    private func aggregateDescriptor(
        for filter: HistoryStore.HistoryFilter
    ) -> FetchDescriptor<TranscriptionRecord> {
        let voiceRawValue = MediaSourceKind.voiceRecording.rawValue
        let manualCaptureRawValue = MediaSourceKind.manualCapture.rawValue
        let importedFileRawValue = MediaSourceKind.importedFile.rawValue
        let webLinkRawValue = MediaSourceKind.webLink.rawValue

        switch filter {
        case .all:
            return FetchDescriptor<TranscriptionRecord>()
        case .voice:
            let predicate = #Predicate<TranscriptionRecord> { record in
                record.sourceKindRawValue == nil || record.sourceKindRawValue == voiceRawValue
            }
            return FetchDescriptor(predicate: predicate)
        case .meetings:
            let predicate = #Predicate<TranscriptionRecord> { record in
                record.sourceKindRawValue == manualCaptureRawValue
            }
            return FetchDescriptor(predicate: predicate)
        case .media:
            let predicate = #Predicate<TranscriptionRecord> { record in
                record.sourceKindRawValue == importedFileRawValue
                    || record.sourceKindRawValue == webLinkRawValue
            }
            return FetchDescriptor(predicate: predicate)
        }
    }

    private func searchDescriptor(
        filter: HistoryStore.HistoryFilter,
        sort: MediaLibrarySortMode
    ) -> FetchDescriptor<TranscriptionRecord> {
        // Mirror HistoryStore SQL filter + sort; broadened text match stays in memory.
        let sortDescriptors: [SortDescriptor<TranscriptionRecord>]
        switch sort {
        case .oldest:
            sortDescriptors = [SortDescriptor<TranscriptionRecord>(\.timestamp, order: .forward)]
        case .newest, .nameAscending, .nameDescending:
            sortDescriptors = [SortDescriptor<TranscriptionRecord>(\.timestamp, order: .reverse)]
        }

        var descriptor = aggregateDescriptor(for: filter)
        descriptor.sortBy = sortDescriptors
        // Prefer the fields used by matching/duration; SwiftData may still fault others.
        descriptor.propertiesToFetch = [
            \.id,
            \.duration,
            \.timestamp,
            \.text,
            \.originalText,
            \.sourceDisplayName,
            \.generatedTitle,
            \.aiSummary,
            \.originalSourceURL,
            \.sourceTitleOriginRawValue
        ]
        return descriptor
    }

    /// Parity with `TranscriptionRecord.matchesMediaLibrarySearch` / preferredTitle.
    private static func matchesMediaLibrarySearch(
        _ record: TranscriptionRecord,
        query: String
    ) -> Bool {
        let searchableFields = [
            preferredTitle(for: record),
            record.text,
            record.originalText,
            record.sourceDisplayName,
            record.generatedTitle,
            record.aiSummary,
            record.originalSourceURL
        ]

        return searchableFields.contains { value in
            guard let value, !value.isEmpty else { return false }
            return value.localizedStandardContains(query)
        }
    }

    private static func preferredTitle(for record: TranscriptionRecord) -> String? {
        let trimmedSourceDisplayName = record.sourceDisplayName?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedGeneratedTitle = record.generatedTitle?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let hasSourceMetadataTitle = record.sourceTitleOriginRawValue
            == TranscriptionTitleOrigin.sourceMetadata.rawValue

        if hasSourceMetadataTitle,
           let trimmedSourceDisplayName,
           !trimmedSourceDisplayName.isEmpty {
            return trimmedSourceDisplayName
        }
        if let trimmedGeneratedTitle, !trimmedGeneratedTitle.isEmpty {
            return trimmedGeneratedTitle
        }
        if let trimmedSourceDisplayName, !trimmedSourceDisplayName.isEmpty {
            return trimmedSourceDisplayName
        }

        let trimmedText = record.text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedText.isEmpty ? nil : trimmedText
    }
}

private struct HistorySearchResult: Sendable {
    let matchingIDs: [UUID]
    let spokenDuration: TimeInterval
}
