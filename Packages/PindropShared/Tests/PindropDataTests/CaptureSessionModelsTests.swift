//
//  CaptureSessionModelsTests.swift
//  PindropDataTests
//
//  Created on 2026-08-20.
//

import Foundation
import SwiftData
import Testing
import PindropCore
@testable import PindropData

@MainActor
@Suite(.serialized)
struct CaptureSessionModelsTests {
    @Test func flatCaptureRecordsRoundTripThroughAFreshModelContext() throws {
        let container = try PindropModelContainerFactory.makeInMemoryContainer()
        let context = ModelContext(container)
        let timestamp = Date(timeIntervalSinceReferenceDate: 3_000)
        let sessionID = UUID()
        let sourceID = UUID()
        let chunkID = UUID()
        let transcriptRevisionID = UUID()
        let sessionWideTranscriptRevisionID = UUID()
        let providerSnapshotID = UUID()
        let humanAnchorReferenceID = UUID()
        let generatedReferenceID = UUID()
        let failureID = UUID()
        let transcriptionRecordID = UUID()
        let noteID = UUID()
        let humanAnchorContentSnapshot = "Human anchor snapshot."
        let generatedProvenance = MeetingGeneratedNoteProvenance(
            humanAnchorNoteID: noteID,
            evidenceInput: "<untrusted-human-notes>\n\(humanAnchorContentSnapshot)\n</untrusted-human-notes>",
            citations: [
                MeetingNoteCitation(
                    identifier: "C1",
                    transcriptRevisionID: sessionWideTranscriptRevisionID,
                    startTime: 0,
                    endTime: 15,
                    speakerLabel: nil,
                    text: "A session-wide final transcript."
                )
            ],
            sourceTranscriptRevisionIDs: [sessionWideTranscriptRevisionID]
        )
        let provenanceEncoder = JSONEncoder()
        provenanceEncoder.outputFormatting = [.sortedKeys]
        let generatedProvenanceJSON = String(
            decoding: try provenanceEncoder.encode(generatedProvenance),
            as: UTF8.self
        )
        #expect(!generatedProvenanceJSON.contains("\"humanAnchorContent\""))

        var captureSession = try CaptureSession(
            id: sessionID,
            mode: .meeting,
            createdAt: timestamp
        )
        try captureSession.start(at: timestamp)
        try captureSession.interrupt(
            with: CaptureFailure(
                id: failureID,
                sessionID: sessionID,
                disposition: .recoverable,
                occurredAt: timestamp,
                code: "retryable",
                message: "Retry after reconnecting.",
                stage: .finalTranscription,
                sourceID: sourceID
            ),
            at: timestamp
        )

        context.insert(
            CaptureSessionModel(
                session: captureSession,
                lastActivityAt: timestamp,
                transcriptionRecordID: transcriptionRecordID
            )
        )
        context.insert(
            CaptureSourceModel(
                id: sourceID,
                sessionID: sessionID,
                kind: .systemAudio,
                sequence: 2,
                stateRawValue: "capturing",
                displayName: "System Audio",
                sampleRate: 48_000,
                channelCount: 2,
                codecRawValue: "aac",
                startedAt: timestamp,
                createdAt: timestamp,
                updatedAt: timestamp
            )
        )
        context.insert(
            CaptureChunkModel(
                id: chunkID,
                sessionID: sessionID,
                sourceID: sourceID,
                sequence: 4,
                startOffset: 12.5,
                duration: 2.5,
                stateRawValue: "sealed",
                managedMediaPath: "Capture/Chunks/chunk-4.m4a",
                byteCount: 1_024,
                sha256: "f00d",
                createdAt: timestamp,
                sealedAt: timestamp
            )
        )
        context.insert(
            CaptureTranscriptRevisionModel(
                id: transcriptRevisionID,
                sessionID: sessionID,
                sourceID: sourceID,
                sequence: 5,
                stage: .finalTranscription,
                statusRawValue: "completed",
                startOffset: 0,
                duration: 15,
                text: "A final transcript.",
                segmentsJSON: "[]",
                languageCode: "en",
                providerSnapshotID: providerSnapshotID,
                createdAt: timestamp
            )
        )
        context.insert(
            CaptureTranscriptRevisionModel(
                id: sessionWideTranscriptRevisionID,
                sessionID: sessionID,
                sequence: 6,
                stage: .finalTranscription,
                statusRawValue: "completed",
                startOffset: 0,
                duration: 15,
                text: "A session-wide final transcript.",
                providerSnapshotID: providerSnapshotID,
                createdAt: timestamp
            )
        )
        context.insert(
            CaptureStageProviderSnapshotModel(
                id: providerSnapshotID,
                sessionID: sessionID,
                stage: .finalTranscription,
                attempt: 1,
                providerKindRawValue: "offline",
                providerIdentifier: "whisperkit",
                modelIdentifier: "large-v3",
                selectedAt: timestamp
            )
        )
        context.insert(
            CaptureNoteReferenceModel(
                id: humanAnchorReferenceID,
                sessionID: sessionID,
                noteID: noteID,
                role: .humanAnchor,
                createdAt: timestamp
            )
        )
        context.insert(
            CaptureNoteReferenceModel(
                id: generatedReferenceID,
                sessionID: sessionID,
                noteID: UUID(),
                role: .generated,
                provenanceJSON: generatedProvenanceJSON,
                humanAnchorContentSnapshot: humanAnchorContentSnapshot,
                createdAt: timestamp
            )
        )
        context.insert(
            CaptureFailureRecordModel(
                id: failureID,
                sessionID: sessionID,
                sourceID: sourceID,
                chunkID: chunkID,
                transcriptRevisionID: transcriptRevisionID,
                providerSnapshotID: providerSnapshotID,
                stage: .finalTranscription,
                attempt: 1,
                errorDomain: "Capture",
                errorCode: "retryable",
                message: "Retry after reconnecting.",
                isRetryable: true,
                detailsJSON: "{\"reason\":\"network\"}",
                occurredAt: timestamp,
                recoveryDisposition: .recoverable
            )
        )
        try context.save()

        let freshContext = ModelContext(container)
        let session = try #require(
            freshContext.fetch(FetchDescriptor<CaptureSessionModel>()).first { $0.id == sessionID }
        )
        let restoredSession = try session.restoreSession()
        #expect(restoredSession == captureSession)
        #expect(session.lastActivityAt == timestamp)
        #expect(session.transcriptionRecordID == transcriptionRecordID)

        let source = try #require(
            freshContext.fetch(FetchDescriptor<CaptureSourceModel>()).first { $0.id == sourceID }
        )
        #expect(source.sessionID == sessionID)
        #expect(source.kindRawValue == CaptureSourceKind.systemAudio.rawValue)

        let chunk = try #require(
            freshContext.fetch(FetchDescriptor<CaptureChunkModel>()).first { $0.id == chunkID }
        )
        #expect(chunk.sessionID == sessionID)
        #expect(chunk.sourceID == sourceID)
        #expect(chunk.managedMediaPath == "Capture/Chunks/chunk-4.m4a")
        #expect(chunk.byteCount == 1_024)
        #expect(chunk.sha256 == "f00d")
        #expect(chunk.sealedAt == timestamp)

        let transcriptRevision = try #require(
            freshContext.fetch(FetchDescriptor<CaptureTranscriptRevisionModel>()).first { $0.id == transcriptRevisionID }
        )
        #expect(transcriptRevision.sessionID == sessionID)
        #expect(transcriptRevision.sourceID == sourceID)
        #expect(transcriptRevision.stageRawValue == CapturePipelineStage.finalTranscription.rawValue)
        #expect(transcriptRevision.providerSnapshotID == providerSnapshotID)
        let sessionWideTranscriptRevision = try #require(
            freshContext.fetch(FetchDescriptor<CaptureTranscriptRevisionModel>()).first {
                $0.id == sessionWideTranscriptRevisionID
            }
        )
        #expect(sessionWideTranscriptRevision.sessionID == sessionID)
        #expect(sessionWideTranscriptRevision.sourceID == nil)

        let providerSnapshot = try #require(
            freshContext.fetch(FetchDescriptor<CaptureStageProviderSnapshotModel>()).first {
                $0.id == providerSnapshotID
            }
        )
        #expect(providerSnapshot.sessionID == sessionID)
        #expect(providerSnapshot.stageRawValue == CapturePipelineStage.finalTranscription.rawValue)
        #expect(providerSnapshot.providerIdentifier == "whisperkit")

        let humanAnchorReference = try #require(
            freshContext.fetch(FetchDescriptor<CaptureNoteReferenceModel>()).first {
                $0.id == humanAnchorReferenceID
            }
        )
        #expect(humanAnchorReference.sessionID == sessionID)
        #expect(humanAnchorReference.noteID == noteID)
        #expect(humanAnchorReference.roleRawValue == CaptureNoteRole.humanAnchor.rawValue)
        #expect(try humanAnchorReference.resolvedRole() == .humanAnchor)
        #expect(humanAnchorReference.provenanceJSON == nil)
        #expect(humanAnchorReference.humanAnchorContentSnapshot == nil)
        let generatedReference = try #require(
            freshContext.fetch(FetchDescriptor<CaptureNoteReferenceModel>()).first {
                $0.id == generatedReferenceID
            }
        )
        #expect(generatedReference.roleRawValue == CaptureNoteRole.generated.rawValue)
        #expect(try generatedReference.resolvedRole() == .generated)
        #expect(
            try JSONDecoder().decode(
                MeetingGeneratedNoteProvenance.self,
                from: try #require(generatedReference.provenanceJSON).data(using: .utf8)!
            ) == generatedProvenance
        )
        #expect(generatedReference.humanAnchorContentSnapshot == humanAnchorContentSnapshot)

        let failure = try #require(
            freshContext.fetch(FetchDescriptor<CaptureFailureRecordModel>()).first { $0.id == failureID }
        )
        #expect(failure.sessionID == sessionID)
        #expect(failure.sourceID == sourceID)
        #expect(failure.chunkID == chunkID)
        #expect(failure.transcriptRevisionID == transcriptRevisionID)
        #expect(failure.providerSnapshotID == providerSnapshotID)
        #expect(failure.stageRawValue == CapturePipelineStage.finalTranscription.rawValue)
        #expect(failure.recoveryDispositionRawValue == CaptureFailureDisposition.recoverable.rawValue)

        let projectionSnapshot = try session.restoreSession()
        let otherSession = try CaptureSession(id: UUID(), mode: .meeting, createdAt: timestamp)
        #expect(throws: CaptureSessionProjectionError.sessionIDMismatch(
            expected: sessionID,
            actual: otherSession.id
        )) {
            try session.update(from: otherSession)
        }
        #expect(try session.restoreSession() == projectionSnapshot)

        let differentMode = try CaptureSession(id: sessionID, mode: .dictate, createdAt: timestamp)
        #expect(throws: CaptureSessionProjectionError.modeMismatch(expected: .meeting, actual: .dictate)) {
            try session.update(from: differentMode)
        }
        #expect(try session.restoreSession() == projectionSnapshot)

        let earlierRevision = try CaptureSession(id: sessionID, mode: .meeting, createdAt: timestamp)
        #expect(throws: CaptureSessionProjectionError.revisionRegression(current: 2, attempted: 0)) {
            try session.update(from: earlierRevision)
        }
        #expect(try session.restoreSession() == projectionSnapshot)
    }

    @Test func invalidPersistedNoteRoleRawValueIsRejectedAfterFetchingThroughAFreshContext() throws {
        let container = try PindropModelContainerFactory.makeInMemoryContainer()
        let context = ModelContext(container)
        let referenceID = UUID()
        let sessionID = UUID()

        context.insert(
            CaptureNoteReferenceModel(
                persistedRawID: referenceID,
                sessionID: sessionID,
                noteID: UUID(),
                roleRawValue: "unrecognized"
            )
        )
        try context.save()

        let freshContext = ModelContext(container)
        let reference = try #require(
            freshContext.fetch(FetchDescriptor<CaptureNoteReferenceModel>()).first { $0.id == referenceID }
        )
        #expect(throws: CaptureSessionProjectionError.invalidNoteRoleRawValue("unrecognized")) {
            try reference.resolvedRole()
        }
    }

    @Test func invalidPersistedLifecycleRawValueIsRejectedAfterFetchingThroughAFreshContext() throws {
        let container = try PindropModelContainerFactory.makeInMemoryContainer()
        let context = ModelContext(container)
        let timestamp = Date(timeIntervalSinceReferenceDate: 3_000)
        let sessionID = UUID()

        context.insert(
            CaptureSessionModel(
                persistedRawID: sessionID,
                modeRawValue: "unrecognized",
                stateRawValue: CaptureSessionState.created.rawValue,
                stateRevision: 0,
                stateChangedAt: timestamp,
                createdAt: timestamp,
                updatedAt: timestamp,
                startedAt: nil,
                endedAt: nil,
                lastActivityAt: nil,
                recoveryTargetRawValue: nil,
                latestFailureID: nil,
                transcriptionRecordID: nil
            )
        )
        try context.save()

        let freshContext = ModelContext(container)
        let session = try #require(
            freshContext.fetch(FetchDescriptor<CaptureSessionModel>()).first { $0.id == sessionID }
        )
        #expect(throws: CaptureSessionProjectionError.invalidModeRawValue("unrecognized")) {
            try session.restoreSession()
        }
    }
}
