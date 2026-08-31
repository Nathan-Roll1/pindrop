//
//  SpeakerIdentityService.swift
//  PindropData
//
//  Created on 2026-07-22.
//

import Foundation
import Observation
import PindropCore
import SwiftData

/// Profile CRUD and training methods that refine the Core matching-only port.
@MainActor
public protocol SpeakerIdentityManaging: SpeakerIdentityMatching {
    func learnFromDictation(
        recordID: UUID,
        segments: [DiarizedTranscriptSegment]
    ) throws
    func learnFromProfileAssignments(
        recordID: UUID,
        segments: [DiarizedTranscriptSegment],
        profileIDsBySpeakerID: [String: UUID]
    ) throws
    func hasTrainingEvidence(for recordID: UUID) throws -> Bool
    func removeTrainingEvidence(for recordID: UUID) throws
    func removeTrainingEvidence(
        recordID: UUID,
        sourceSpeakerID: String,
        sourceType: String
    ) throws
    func createProfile(displayName: String, notes: String?) throws -> ParticipantProfile
    func fetchAllProfiles() throws -> [ParticipantProfile]
    func updateProfile(_ profile: ParticipantProfile, displayName: String, notes: String?) throws
    func renameProfile(_ profile: ParticipantProfile, to newName: String) throws
    func deleteProfile(_ profile: ParticipantProfile) throws
    func deleteAllProfiles() throws
}

@MainActor
@Observable
public final class SpeakerIdentityService: SpeakerIdentityManaging {
    public enum SpeakerIdentityError: Error, LocalizedError {
        case fetchFailed(String)
        case saveFailed(String)

        public var errorDescription: String? {
            switch self {
            case .fetchFailed(let message):
                return "Failed to fetch speaker identities: \(message)"
            case .saveFailed(let message):
                return "Failed to save speaker identities: \(message)"
            }
        }
    }

    public enum EvidenceSource: String, Sendable {
        case dictation
        case renameFeedback
    }

    private static let currentUserProfileID = UUID(uuidString: "9A80C8F2-DBA4-4F80-8D06-54F6151EC212")!

    private static let minimumDurationForLearning: TimeInterval = 1.0
    private static let minimumConfidenceForLearning: Float = 0.45
    private static let minimumSimilarityForAutoMatch: Float = 0.72
    private static let minimumSimilarityMarginForAutoMatch: Float = 0.08

    /// The same two gates for a name put on screen **while** a recording runs.
    ///
    /// Higher than the offline pair on purpose. Those two were tuned against
    /// embeddings of long, aggregated per-speaker audio from a whole recording.
    /// A live label is decided from a three to six second slice of conference
    /// codec audio, which scores differently, and a wrong name shown for forty
    /// minutes costs more than no name at all.
    ///
    /// Conservative placeholders. The calibration run in section 8.3 of the live
    /// attribution design measures the real distribution over held-out clips and
    /// replaces both numbers. Until then, staying at `Speaker 2` is the safe
    /// answer and this pair is chosen to give it often.
    public static let liveMinimumSimilarityForAutoMatch: Float = 0.80
    public static let liveMinimumSimilarityMarginForAutoMatch: Float = 0.12

    private let modelContext: ModelContext
    private var hasEnsuredCurrentEmbeddingSpace = false

    public init(modelContext: ModelContext) {
        self.modelContext = modelContext
    }

    public func bestMatch(for embedding: [Float]) throws -> SpeakerIdentityMatch? {
        try bestMatches(for: [embedding])[0]
    }

    public func bestMatches(for embeddings: [[Float]]) throws -> [SpeakerIdentityMatch?] {
        try ensureCurrentEmbeddingSpace()
        guard !embeddings.isEmpty else { return [] }

        // Empty / non-finite vectors never score; skip profile fetch/decode entirely
        // when the whole batch is invalid while preserving exact input cardinality.
        let hasScorableEmbedding = embeddings.contains { embedding in
            !embedding.isEmpty && embedding.allSatisfy(\.isFinite)
        }
        guard hasScorableEmbedding else {
            return Array(repeating: nil, count: embeddings.count)
        }

        do {
            let snapshot = try loadDecodedCurrentCentroids()
            return embeddings.map { embedding in
                match(embedding, against: snapshot)
            }
        } catch let error as SpeakerIdentityError {
            throw error
        } catch {
            throw SpeakerIdentityError.fetchFailed(error.localizedDescription)
        }
    }

    private struct DecodedCentroid {
        let profileID: UUID
        let displayName: String
        let centroid: [Float]
    }

    private func loadDecodedCurrentCentroids() throws -> [DecodedCentroid] {
        let profiles = try modelContext.fetch(FetchDescriptor<ParticipantProfile>())
        var snapshot: [DecodedCentroid] = []
        snapshot.reserveCapacity(profiles.count)

        for profile in profiles {
            guard profile.embeddingSpaceIdentifier == SpeakerEmbeddingSpace.current,
                  let centroid = decodeEmbedding(profile.centroidEmbeddingData),
                  !centroid.isEmpty else {
                continue
            }
            snapshot.append(
                DecodedCentroid(
                    profileID: profile.id,
                    displayName: profile.displayName,
                    centroid: centroid
                )
            )
        }
        return snapshot
    }

    /// The closest profiles to one embedding, best first, with no threshold
    /// applied.
    ///
    /// The thresholds belong to the caller because they differ by path: the
    /// offline pass uses the pair tuned for whole-recording embeddings, and the
    /// live path uses its own, higher, pair. Returning the ranking rather than a
    /// verdict is what lets both live in one place each.
    public func rankedMatches(for embedding: [Float], limit: Int = 2) throws -> [SpeakerIdentityMatch] {
        try ensureCurrentEmbeddingSpace()
        guard limit > 0, !embedding.isEmpty, embedding.allSatisfy(\.isFinite) else { return [] }
        do {
            return rankedMatches(
                for: embedding,
                against: try loadDecodedCurrentCentroids(),
                limit: limit
            )
        } catch let error as SpeakerIdentityError {
            throw error
        } catch {
            throw SpeakerIdentityError.fetchFailed(error.localizedDescription)
        }
    }

    private func match(
        _ embedding: [Float],
        against snapshot: [DecodedCentroid]
    ) -> SpeakerIdentityMatch? {
        let ranked = rankedMatches(for: embedding, against: snapshot, limit: 2)
        guard let bestMatch = ranked.first,
              bestMatch.similarity >= Self.minimumSimilarityForAutoMatch else {
            return nil
        }
        if ranked.count > 1,
           (bestMatch.similarity - ranked[1].similarity) < Self.minimumSimilarityMarginForAutoMatch {
            return nil
        }
        return bestMatch
    }

    /// Scores one embedding against every centroid of the current space, best
    /// first. Equal similarities keep the earlier profile, which is the order
    /// the profiles were fetched in.
    private func rankedMatches(
        for embedding: [Float],
        against snapshot: [DecodedCentroid],
        limit: Int
    ) -> [SpeakerIdentityMatch] {
        guard !embedding.isEmpty, embedding.allSatisfy(\.isFinite) else { return [] }

        var scored: [(order: Int, match: SpeakerIdentityMatch)] = []
        scored.reserveCapacity(snapshot.count)
        for (order, profile) in snapshot.enumerated() {
            guard profile.centroid.count == embedding.count else { continue }
            let similarity = cosineSimilarity(between: embedding, and: profile.centroid)
            guard similarity.isFinite else { continue }
            scored.append(
                (
                    order,
                    SpeakerIdentityMatch(
                        profileID: profile.profileID,
                        displayName: profile.displayName,
                        similarity: similarity
                    )
                )
            )
        }
        scored.sort { lhs, rhs in
            lhs.match.similarity == rhs.match.similarity
                ? lhs.order < rhs.order
                : lhs.match.similarity > rhs.match.similarity
        }
        return scored.prefix(limit).map(\.match)
    }

    public func learnFromProfileAssignments(
        recordID: UUID,
        segments: [DiarizedTranscriptSegment],
        profileIDsBySpeakerID: [String: UUID]
    ) throws {
        try ensureCurrentEmbeddingSpace()
        guard !profileIDsBySpeakerID.isEmpty else { return }

        do {
            var profilesByID: [UUID: ParticipantProfile] = [:]
            for profileID in Set(profileIDsBySpeakerID.values) {
                guard let profile = try fetchProfile(id: profileID) else { continue }
                profilesByID[profileID] = profile
            }

            try learn(
                recordID: recordID,
                segments: segments,
                source: .renameFeedback
            ) { segment in
                guard let profileID = profileIDsBySpeakerID[segment.speakerId] else { return nil }
                return profilesByID[profileID]
            }
        } catch let error as SpeakerIdentityError {
            throw error
        } catch {
            throw SpeakerIdentityError.saveFailed(error.localizedDescription)
        }
    }

    public func learnFromDictation(
        recordID: UUID,
        segments: [DiarizedTranscriptSegment]
    ) throws {
        try ensureCurrentEmbeddingSpace()
        guard segments.contains(where: isEligibleForLearning) else { return }

        do {
            let profile = try getOrCreateCurrentUserProfile()
            try learn(recordID: recordID, segments: segments, source: .dictation) { _ in profile }
        } catch let error as SpeakerIdentityError {
            throw error
        } catch {
            throw SpeakerIdentityError.saveFailed(error.localizedDescription)
        }
    }

    public func hasTrainingEvidence(for recordID: UUID) throws -> Bool {
        try ensureCurrentEmbeddingSpace()
        var descriptor = FetchDescriptor<ParticipantTrainingEvidence>(
            predicate: #Predicate { $0.recordID == recordID }
        )
        descriptor.fetchLimit = 1

        do {
            return try !modelContext.fetch(descriptor).isEmpty
        } catch {
            throw SpeakerIdentityError.fetchFailed(error.localizedDescription)
        }
    }

    public func removeTrainingEvidence(for recordID: UUID) throws {
        try removeTrainingEvidence(for: [recordID])
    }

    /// Removes training evidence for many records in one transaction: one evidence
    /// fetch, unique profile collection, evidence deletion, one rebuild per touched
    /// profile from the post-delete evidence set, and a single save.
    public func removeTrainingEvidence(for recordIDs: [UUID]) throws {
        try ensureCurrentEmbeddingSpace()
        let uniqueIDs = Array(Set(recordIDs))
        guard !uniqueIDs.isEmpty else { return }

        let descriptor = FetchDescriptor<ParticipantTrainingEvidence>(
            predicate: #Predicate<ParticipantTrainingEvidence> { evidence in
                if let recordID = evidence.recordID {
                    return uniqueIDs.contains(recordID)
                } else {
                    return false
                }
            }
        )

        do {
            let evidence = try modelContext.fetch(descriptor)
            guard !evidence.isEmpty else { return }

            let touchedProfiles = evidence.reduce(into: [PersistentIdentifier: ParticipantProfile]()) {
                result, item in
                guard let profile = item.profile else { return }
                result[profile.persistentModelID] = profile
            }

            for item in evidence {
                modelContext.delete(item)
            }

            for profile in touchedProfiles.values {
                rebuildProfile(profile)
            }
            try modelContext.save()
        } catch {
            throw SpeakerIdentityError.saveFailed(error.localizedDescription)
        }
    }

    public func removeTrainingEvidence(
        recordID: UUID,
        sourceSpeakerID: String,
        sourceType: String
    ) throws {
        try removeTrainingEvidence(
            recordID: recordID,
            sourceSpeakerID: sourceSpeakerID,
            sourceType: sourceType,
            saveChanges: true
        )
    }

    public func removeTrainingEvidence(
        recordID: UUID,
        sourceSpeakerID: String,
        sourceType: String,
        saveChanges: Bool
    ) throws {
        try ensureCurrentEmbeddingSpace()
        guard !sourceSpeakerID.isEmpty, !sourceType.isEmpty else { return }

        let descriptor = FetchDescriptor<ParticipantTrainingEvidence>(
            predicate: #Predicate<ParticipantTrainingEvidence> { evidence in
                evidence.recordID == recordID
                    && evidence.sourceSpeakerID == sourceSpeakerID
                    && evidence.sourceTypeRawValue == sourceType
            }
        )

        do {
            let evidence = try modelContext.fetch(descriptor)
            guard !evidence.isEmpty else { return }

            let touchedProfiles = evidence.reduce(into: [PersistentIdentifier: ParticipantProfile]()) {
                result, item in
                guard let profile = item.profile else { return }
                result[profile.persistentModelID] = profile
            }

            for item in evidence {
                modelContext.delete(item)
            }

            for profile in touchedProfiles.values {
                rebuildProfile(profile)
            }
            if saveChanges {
                try modelContext.save()
            }
        } catch {
            throw SpeakerIdentityError.saveFailed(error.localizedDescription)
        }
    }

    /// Deletes mismatched-space evidence and clears incompatible centroids once per service
    /// instance. Profiles, names, notes, current-user flags, and transcript assignments stay.
    public func ensureCurrentEmbeddingSpace() throws {
        guard !hasEnsuredCurrentEmbeddingSpace else { return }

        do {
            let currentSpace = SpeakerEmbeddingSpace.current
            let evidence = try modelContext.fetch(FetchDescriptor<ParticipantTrainingEvidence>())
            var touchedProfiles: [PersistentIdentifier: ParticipantProfile] = [:]
            var didMutate = false

            for item in evidence where item.embeddingSpaceIdentifier != currentSpace {
                if let profile = item.profile {
                    touchedProfiles[profile.persistentModelID] = profile
                }
                modelContext.delete(item)
                didMutate = true
            }

            // Profiles may still hold a legacy centroid with no remaining evidence rows.
            let profiles = try modelContext.fetch(FetchDescriptor<ParticipantProfile>())
            for profile in profiles where profile.embeddingSpaceIdentifier != currentSpace {
                let hasLegacyCentroidState =
                    profile.centroidEmbeddingData != nil
                    || profile.evidenceCount != 0
                    || profile.totalEvidenceDuration != 0
                    || profile.embeddingSpaceIdentifier != nil
                guard hasLegacyCentroidState else { continue }
                touchedProfiles[profile.persistentModelID] = profile
            }

            for profile in touchedProfiles.values {
                rebuildProfile(profile)
            }

            if didMutate || !touchedProfiles.isEmpty {
                try modelContext.save()
            }

            hasEnsuredCurrentEmbeddingSpace = true
        } catch let error as SpeakerIdentityError {
            throw error
        } catch {
            throw SpeakerIdentityError.saveFailed(error.localizedDescription)
        }
    }

    private func learn(
        recordID: UUID,
        segments: [DiarizedTranscriptSegment],
        source: EvidenceSource,
        profileForSegment: (DiarizedTranscriptSegment) -> ParticipantProfile?
    ) throws {
        var touchedProfiles: [PersistentIdentifier: ParticipantProfile] = [:]

        struct EligibleEvidence {
            let segment: DiarizedTranscriptSegment
            let embedding: [Float]
            let profile: ParticipantProfile
            let key: String
        }

        var eligible: [EligibleEvidence] = []
        eligible.reserveCapacity(segments.count)

        for segment in segments {
            guard isEligibleForLearning(segment),
                  let embedding = segment.speakerEmbedding,
                  let profile = profileForSegment(segment) else {
                continue
            }

            touchedProfiles[profile.persistentModelID] = profile
            eligible.append(
                EligibleEvidence(
                    segment: segment,
                    embedding: embedding,
                    profile: profile,
                    key: evidenceKey(for: recordID, segment: segment)
                )
            )
        }

        guard !eligible.isEmpty else { return }

        let keys = Array(Set(eligible.map(\.key)))
        var existingByKey = try fetchTrainingEvidence(withKeys: keys)

        for item in eligible {
            if let previousProfile = existingByKey[item.key]?.profile {
                touchedProfiles[previousProfile.persistentModelID] = previousProfile
            }

            // Encode once per segment; reuse for insert and assignment.
            let encodedEmbedding = encodeEmbedding(item.embedding)
            let existingEvidence = existingByKey[item.key]
            let evidence = existingEvidence ?? ParticipantTrainingEvidence(
                evidenceKey: item.key,
                sourceTypeRawValue: source.rawValue,
                recordID: recordID,
                sourceSpeakerID: item.segment.speakerId,
                segmentStartTime: item.segment.startTime,
                segmentEndTime: item.segment.endTime,
                segmentDuration: item.segment.endTime - item.segment.startTime,
                confidence: item.segment.confidence,
                embeddingData: encodedEmbedding,
                embeddingSpaceIdentifier: SpeakerEmbeddingSpace.current
            )

            evidence.sourceTypeRawValue = source.rawValue
            evidence.recordID = recordID
            evidence.sourceSpeakerID = item.segment.speakerId
            evidence.segmentStartTime = item.segment.startTime
            evidence.segmentEndTime = item.segment.endTime
            evidence.segmentDuration = item.segment.endTime - item.segment.startTime
            evidence.confidence = item.segment.confidence
            evidence.embeddingData = encodedEmbedding
            evidence.embeddingSpaceIdentifier = SpeakerEmbeddingSpace.current
            evidence.updatedAt = Date()
            evidence.profile = item.profile

            if existingEvidence == nil {
                modelContext.insert(evidence)
                // Later duplicate keys in this batch update the same inserted row.
                existingByKey[item.key] = evidence
            }
        }

        for profile in touchedProfiles.values {
            rebuildProfile(profile)
        }
        if !touchedProfiles.isEmpty {
            try modelContext.save()
        }
    }

    private func getOrCreateCurrentUserProfile() throws -> ParticipantProfile {
        var currentUserDescriptor = FetchDescriptor<ParticipantProfile>(
            predicate: #Predicate { $0.isCurrentUser }
        )
        currentUserDescriptor.fetchLimit = 1

        if let profile = try modelContext.fetch(currentUserDescriptor).first {
            return profile
        }

        let profileID = Self.currentUserProfileID
        if let profile = try fetchProfile(id: profileID) {
            profile.isCurrentUser = true
            return profile
        }

        if let profile = try fetchProfile(normalizedName: "me") {
            profile.isCurrentUser = true
            return profile
        }

        let profile = ParticipantProfile(
            id: profileID,
            normalizedName: "me",
            displayName: "Me",
            isCurrentUser: true
        )
        modelContext.insert(profile)
        return profile
    }

    private func getOrCreateProfile(named displayName: String) throws -> ParticipantProfile {
        let normalizedName = normalizedKey(for: displayName)

        if let existing = try fetchProfile(normalizedName: normalizedName) {
            existing.displayName = displayName
            existing.updatedAt = Date()
            return existing
        }

        let profile = ParticipantProfile(
            normalizedName: normalizedName,
            displayName: displayName
        )
        modelContext.insert(profile)
        return profile
    }

    private func fetchProfile(normalizedName: String) throws -> ParticipantProfile? {
        let descriptor = FetchDescriptor<ParticipantProfile>(
            predicate: #Predicate { $0.normalizedName == normalizedName }
        )

        do {
            return try modelContext.fetch(descriptor).first
        } catch {
            throw SpeakerIdentityError.fetchFailed(error.localizedDescription)
        }
    }

    private func fetchProfile(id: UUID) throws -> ParticipantProfile? {
        var descriptor = FetchDescriptor<ParticipantProfile>(
            predicate: #Predicate { $0.id == id }
        )
        descriptor.fetchLimit = 1

        do {
            return try modelContext.fetch(descriptor).first
        } catch {
            throw SpeakerIdentityError.fetchFailed(error.localizedDescription)
        }
    }

    /// Batch-fetch evidence rows for the given keys and index the first row per key
    /// (matches single-key `fetch(...).first` determinism when duplicates exist).
    private func fetchTrainingEvidence(withKeys keys: [String]) throws -> [String: ParticipantTrainingEvidence] {
        guard !keys.isEmpty else { return [:] }

        let descriptor = FetchDescriptor<ParticipantTrainingEvidence>(
            predicate: #Predicate<ParticipantTrainingEvidence> { evidence in
                keys.contains(evidence.evidenceKey)
            }
        )

        do {
            let rows = try modelContext.fetch(descriptor)
            var byKey: [String: ParticipantTrainingEvidence] = [:]
            byKey.reserveCapacity(rows.count)
            for row in rows {
                if byKey[row.evidenceKey] == nil {
                    byKey[row.evidenceKey] = row
                }
            }
            return byKey
        } catch {
            throw SpeakerIdentityError.fetchFailed(error.localizedDescription)
        }
    }

    private func fetchEvidence(for profileID: UUID) throws -> [ParticipantTrainingEvidence] {
        let descriptor = FetchDescriptor<ParticipantTrainingEvidence>(
            predicate: #Predicate { $0.profile?.id == profileID }
        )

        do {
            return try modelContext.fetch(descriptor)
        } catch {
            throw SpeakerIdentityError.fetchFailed(error.localizedDescription)
        }
    }

    private func rebuildProfile(_ profile: ParticipantProfile) {
        let evidence = (try? fetchEvidence(for: profile.id)) ?? []

        var usable: [(embedding: [Float], duration: TimeInterval, confidence: Float)] = []
        usable.reserveCapacity(evidence.count)
        var dimension: Int?
        var totalEvidenceDuration: TimeInterval = 0

        for item in evidence {
            guard item.embeddingSpaceIdentifier == SpeakerEmbeddingSpace.current,
                  let embedding = decodeEmbedding(item.embeddingData),
                  !embedding.isEmpty else {
                continue
            }

            // First valid vector establishes the dimension; mixed-dimension rows are dropped.
            if let dimension {
                guard embedding.count == dimension else { continue }
            } else {
                dimension = embedding.count
            }

            let duration = max(item.segmentDuration, 0)
            usable.append((
                embedding: embedding,
                duration: duration,
                confidence: max(item.confidence, 0)
            ))
            totalEvidenceDuration += duration
        }

        profile.evidenceCount = usable.count
        profile.totalEvidenceDuration = totalEvidenceDuration

        if usable.isEmpty {
            profile.centroidEmbeddingData = nil
            profile.needsVoiceRetraining = true
            profile.embeddingSpaceIdentifier = nil
        } else {
            profile.centroidEmbeddingData = encodeEmbedding(weightedAverageEmbedding(usable))
            profile.needsVoiceRetraining = false
            profile.embeddingSpaceIdentifier = SpeakerEmbeddingSpace.current
        }
        profile.updatedAt = Date()
    }

    private func weightedAverageEmbedding(
        _ samples: [(embedding: [Float], duration: TimeInterval, confidence: Float)]
    ) -> [Float] {
        guard let first = samples.first else { return [] }

        var totals = Array(repeating: Float.zero, count: first.embedding.count)

        var hasPositiveWeight = false
        for sample in samples {
            if Float(sample.duration) * sample.confidence > 0 {
                hasPositiveWeight = true
                break
            }
        }

        var weightSum: Float = 0
        for sample in samples {
            let weight = hasPositiveWeight
                ? Float(sample.duration) * sample.confidence
                : 1
            guard weight > 0 else { continue }
            for (index, value) in sample.embedding.enumerated() {
                totals[index] += value * weight
            }
            weightSum += weight
        }

        guard weightSum > 0 else { return [] }
        return totals.map { $0 / weightSum }
    }

    private func cosineSimilarity(between lhs: [Float], and rhs: [Float]) -> Float {
        guard lhs.count == rhs.count, !lhs.isEmpty else { return -.infinity }

        var dotProduct: Float = 0
        var lhsMagnitude: Float = 0
        var rhsMagnitude: Float = 0

        for index in lhs.indices {
            let lhsValue = lhs[index]
            let rhsValue = rhs[index]
            guard lhsValue.isFinite, rhsValue.isFinite else { return -.infinity }
            dotProduct += lhsValue * rhsValue
            lhsMagnitude += lhsValue * lhsValue
            rhsMagnitude += rhsValue * rhsValue
        }

        guard lhsMagnitude > 0, rhsMagnitude > 0 else { return -.infinity }
        return dotProduct / (sqrt(lhsMagnitude) * sqrt(rhsMagnitude))
    }

    private func isEligibleForLearning(_ segment: DiarizedTranscriptSegment) -> Bool {
        guard let embedding = segment.speakerEmbedding, !embedding.isEmpty else { return false }
        let duration = segment.endTime - segment.startTime
        return duration >= Self.minimumDurationForLearning && segment.confidence >= Self.minimumConfidenceForLearning
    }

    private func normalizedKey(for label: String) -> String {
        label
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
    }

    private func evidenceKey(for recordID: UUID, segment: DiarizedTranscriptSegment) -> String {
        [
            recordID.uuidString,
            segment.speakerId,
            String(format: "%.3f", segment.startTime),
            String(format: "%.3f", segment.endTime)
        ].joined(separator: "|")
    }

    private func encodeEmbedding(_ embedding: [Float]) -> Data {
        (try? JSONEncoder().encode(embedding)) ?? Data()
    }

    private func decodeEmbedding(_ data: Data?) -> [Float]? {
        guard let data, !data.isEmpty else { return nil }
        return try? JSONDecoder().decode([Float].self, from: data)
    }

    // MARK: - Profile Management

    /// Creates a named participant profile (without audio evidence). Useful for pre-registering
    /// known speakers so future diarization can match them by name.
    @discardableResult
    public func registerParticipant(displayName: String) throws -> ParticipantProfile {
        try ensureCurrentEmbeddingSpace()
        return try getOrCreateProfile(named: displayName)
    }

    public func createProfile(displayName: String, notes: String? = nil) throws -> ParticipantProfile {
        try ensureCurrentEmbeddingSpace()
        let trimmedName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            throw SpeakerIdentityError.saveFailed("Enter a name for the speaker profile.")
        }
        guard try fetchProfile(normalizedName: normalizedKey(for: trimmedName)) == nil else {
            throw SpeakerIdentityError.saveFailed("A speaker profile with that name already exists.")
        }

        let trimmedNotes = notes?.trimmingCharacters(in: .whitespacesAndNewlines)
        let profile = ParticipantProfile(
            normalizedName: normalizedKey(for: trimmedName),
            displayName: trimmedName,
            notes: trimmedNotes?.isEmpty == false ? trimmedNotes : nil
        )
        modelContext.insert(profile)

        do {
            try modelContext.save()
            return profile
        } catch {
            throw SpeakerIdentityError.saveFailed(error.localizedDescription)
        }
    }

    public func fetchAllProfiles() throws -> [ParticipantProfile] {
        try ensureCurrentEmbeddingSpace()
        do {
            let descriptor = FetchDescriptor<ParticipantProfile>(
                sortBy: [SortDescriptor(\.displayName, order: .forward)]
            )
            return try modelContext.fetch(descriptor)
        } catch {
            throw SpeakerIdentityError.fetchFailed(error.localizedDescription)
        }
    }

    public func updateProfile(_ profile: ParticipantProfile, displayName: String, notes: String?) throws {
        try ensureCurrentEmbeddingSpace()
        let trimmed = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let normalizedName = normalizedKey(for: trimmed)
        if let duplicate = try fetchProfile(normalizedName: normalizedName), duplicate.id != profile.id {
            throw SpeakerIdentityError.saveFailed("A speaker profile with that name already exists.")
        }

        profile.displayName = trimmed
        profile.normalizedName = normalizedName
        let trimmedNotes = notes?.trimmingCharacters(in: .whitespacesAndNewlines)
        profile.notes = trimmedNotes?.isEmpty == false ? trimmedNotes : nil
        profile.updatedAt = Date()

        do {
            try rewriteProfileAssignments(
                profileID: profile.id,
                updatedDisplayName: profile.displayName
            )
            try modelContext.save()
        } catch {
            throw SpeakerIdentityError.saveFailed(error.localizedDescription)
        }
    }

    public func renameProfile(_ profile: ParticipantProfile, to newName: String) throws {
        try updateProfile(profile, displayName: newName, notes: profile.notes)
    }

    public func deleteProfile(_ profile: ParticipantProfile) throws {
        try ensureCurrentEmbeddingSpace()
        do {
            let evidence = try fetchEvidence(for: profile.id)
            for item in evidence {
                modelContext.delete(item)
            }
            try rewriteProfileAssignments(profileID: profile.id, updatedDisplayName: nil)
            modelContext.delete(profile)
            try modelContext.save()
        } catch {
            throw SpeakerIdentityError.saveFailed(error.localizedDescription)
        }
    }

    public func deleteAllProfiles() throws {
        try ensureCurrentEmbeddingSpace()
        do {
            let profiles = try modelContext.fetch(FetchDescriptor<ParticipantProfile>())
            let evidence = try modelContext.fetch(FetchDescriptor<ParticipantTrainingEvidence>())
            for item in evidence {
                modelContext.delete(item)
            }
            for profile in profiles {
                try rewriteProfileAssignments(profileID: profile.id, updatedDisplayName: nil)
                modelContext.delete(profile)
            }
            try modelContext.save()
        } catch {
            throw SpeakerIdentityError.saveFailed(error.localizedDescription)
        }
    }

    private func rewriteProfileAssignments(
        profileID: UUID,
        updatedDisplayName: String?
    ) throws {
        let records = try modelContext.fetch(FetchDescriptor<TranscriptionRecord>())

        for record in records {
            let segments = record.diarizedSegments
            guard segments.contains(where: { $0.speakerProfileID == profileID }) else { continue }

            let genericLabels = Self.genericSpeakerLabelsByFirstAppearance(from: segments)
            let updatedSegments = segments.map { segment in
                guard segment.speakerProfileID == profileID else { return segment }
                return DiarizedTranscriptSegment(
                    speakerId: segment.speakerId,
                    speakerLabel: updatedDisplayName ?? genericLabels[segment.speakerId] ?? "Speaker 1",
                    speakerProfileID: updatedDisplayName == nil ? nil : profileID,
                    speakerEmbedding: segment.speakerEmbedding,
                    startTime: segment.startTime,
                    endTime: segment.endTime,
                    confidence: segment.confidence,
                    text: segment.text
                )
            }
            let data = try JSONEncoder().encode(updatedSegments)
            record.diarizationSegmentsJSON = String(data: data, encoding: .utf8)
        }
    }

    /// Stable "Speaker N" labels ordered by first segment appearance of each speaker ID.
    public static func genericSpeakerLabelsByFirstAppearance(
        from segments: [DiarizedTranscriptSegment]
    ) -> [String: String] {
        var labels: [String: String] = [:]
        var index = 1
        for segment in segments {
            guard labels[segment.speakerId] == nil else { continue }
            labels[segment.speakerId] = "Speaker \(index)"
            index += 1
        }
        return labels
    }
}
