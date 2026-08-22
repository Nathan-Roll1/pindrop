//
//  LongMeetingReliabilityTests.swift
//  PindropTests
//
//  Created on 2026-08-21.
//

import Foundation
import Testing

@testable import Pindrop
import PindropCore
import PindropData
import PindropSpeech

@MainActor
@Suite
struct LongMeetingReliabilityTests {
    private func makeHandle() -> NoteCaptureHandle {
        NoteCaptureHandle(
            sessionID: UUID(),
            microphoneSourceID: UUID(),
            systemAudioSourceID: UUID()
        )
    }

    private func checkpoint(
        for handle: NoteCaptureHandle,
        sourceID: UUID,
        sequence: Int,
        startOffset: TimeInterval? = nil,
        duration: TimeInterval = MeetingCaptureSpoolPlan.chunkDuration
    ) -> MeetingChunkCheckpoint {
        MeetingChunkCheckpoint(
            sourceID: sourceID,
            sequence: sequence,
            startOffset: startOffset ?? Double(sequence) * MeetingCaptureSpoolPlan.chunkDuration,
            duration: duration,
            managedMediaPath: CaptureSourceArtifactPath.relativePath(
                sessionID: handle.sessionID,
                sourceID: sourceID,
                chunkSequence: sequence
            ),
            byteCount: MeetingCaptureSpoolPlan.defaultChunkByteCount,
            sha256: String(format: "%064x", sequence + 1),
            sealedAt: Date(timeIntervalSinceReferenceDate: Double(sequence))
        )
    }

    @Test func pairsEighteenFiveMinuteSourceChunksInSequenceOrder() throws {
        let handle = makeHandle()
        let microphone = (0..<18).map {
            checkpoint(for: handle, sourceID: handle.microphoneSourceID, sequence: $0)
        }
        let systemAudio = (0..<18).map {
            checkpoint(for: handle, sourceID: handle.dualSourceSystemAudioID, sequence: $0)
        }

        let workItems = try AppCoordinator.meetingChunkWorkItems(
            sourceChunks: Array((microphone + systemAudio).reversed()),
            failedSequences: [],
            handle: handle
        )

        #expect(workItems.map(\.sequence) == Array(0..<18))
        for (sequence, item) in zip(0..<18, workItems) {
            #expect(item.startOffset == Double(sequence) * MeetingCaptureSpoolPlan.chunkDuration)
            #expect(item.duration == MeetingCaptureSpoolPlan.chunkDuration)
            #expect(item.microphone?.sourceID == handle.microphoneSourceID)
            #expect(item.systemAudio?.sourceID == handle.dualSourceSystemAudioID)
        }
    }

    @Test func pairsSoleSourceSequencesWithoutInventingTheOtherSource() throws {
        let handle = makeHandle()
        let microphoneOnly = checkpoint(
            for: handle,
            sourceID: handle.microphoneSourceID,
            sequence: 0
        )
        let systemOnly = checkpoint(
            for: handle,
            sourceID: handle.dualSourceSystemAudioID,
            sequence: 1
        )

        let workItems = try AppCoordinator.meetingChunkWorkItems(
            sourceChunks: [systemOnly, microphoneOnly],
            failedSequences: [],
            handle: handle
        )

        #expect(workItems.map(\.sequence) == [0, 1])
        #expect(workItems[0].microphone == microphoneOnly)
        #expect(workItems[0].systemAudio == nil)
        #expect(workItems[1].microphone == nil)
        #expect(workItems[1].systemAudio == systemOnly)
        #expect(AppCoordinator.shouldCreateMeetingTranscriptionInput(for: workItems[0]))
        #expect(AppCoordinator.shouldCreateMeetingTranscriptionInput(for: workItems[1]))
    }

    @Test func rejectsDuplicateAndMismatchedSourceChunks() {
        let handle = makeHandle()
        let microphone = checkpoint(
            for: handle,
            sourceID: handle.microphoneSourceID,
            sequence: 0
        )
        let duplicateMicrophone = checkpoint(
            for: handle,
            sourceID: handle.microphoneSourceID,
            sequence: 0
        )
        let systemWithMismatchedTiming = checkpoint(
            for: handle,
            sourceID: handle.dualSourceSystemAudioID,
            sequence: 0,
            startOffset: 0.25
        )

        #expect(throws: AppCoordinator.MeetingChunkWorkItemError.duplicateSourceSequence(
            sourceID: handle.microphoneSourceID,
            sequence: 0
        )) {
            try AppCoordinator.meetingChunkWorkItems(
                sourceChunks: [microphone, duplicateMicrophone],
                failedSequences: [],
                handle: handle
            )
        }
        #expect(throws: AppCoordinator.MeetingChunkWorkItemError.mismatchedStartOffset(sequence: 0)) {
            try AppCoordinator.meetingChunkWorkItems(
                sourceChunks: [microphone, systemWithMismatchedTiming],
                failedSequences: [],
                handle: handle
            )
        }
    }

    @Test func scopedFailedGapKeepsLaterValidChunksMergeContinuous() throws {
        let handle = makeHandle()
        let sourceChunks = [0, 2].flatMap { sequence in
            [
                checkpoint(for: handle, sourceID: handle.microphoneSourceID, sequence: sequence),
                checkpoint(for: handle, sourceID: handle.dualSourceSystemAudioID, sequence: sequence)
            ]
        }
        let workItems = try AppCoordinator.meetingChunkWorkItems(
            sourceChunks: Array(sourceChunks.reversed()),
            failedSequences: [1],
            handle: handle
        )
        let first = TranscriptionChunkOutput(
            chunkID: workItems[0].chunkID,
            sequence: 0,
            startOffset: 0,
            duration: MeetingCaptureSpoolPlan.chunkDuration,
            plainText: "first chunk"
        )
        let third = TranscriptionChunkOutput(
            chunkID: workItems[2].chunkID,
            sequence: 2,
            startOffset: 2 * MeetingCaptureSpoolPlan.chunkDuration,
            duration: MeetingCaptureSpoolPlan.chunkDuration,
            plainText: "third chunk"
        )

        let mergeInputs = AppCoordinator.meetingOutputPlaceholders(
            workItems: workItems,
            outputs: [third, first]
        )

        #expect(workItems.map(\.sequence) == [0, 1, 2])
        #expect(workItems[1].microphone == nil)
        #expect(workItems[1].systemAudio == nil)
        #expect(mergeInputs.map(\.sequence) == [0, 1, 2])
        #expect(mergeInputs[0] == first)
        #expect(mergeInputs[1].chunkID == workItems[1].chunkID)
        #expect(mergeInputs[1].startOffset == MeetingCaptureSpoolPlan.chunkDuration)
        #expect(mergeInputs[1].duration == MeetingCaptureSpoolPlan.chunkDuration)
        #expect(mergeInputs[1].plainText.isEmpty)
        #expect(mergeInputs[2] == third)
    }

    @Test func failedOnlyFirstAndLastSequencesUseCanonicalTimedPlaceholders() throws {
        let handle = makeHandle()
        let microphone = checkpoint(
            for: handle,
            sourceID: handle.microphoneSourceID,
            sequence: 1
        )

        let workItems = try AppCoordinator.meetingChunkWorkItems(
            sourceChunks: [microphone],
            failedSequences: [0, 2],
            handle: handle
        )

        #expect(workItems.map(\.sequence) == [0, 1, 2])
        #expect(workItems[0].startOffset == 0)
        #expect(workItems[0].duration == 300)
        #expect(workItems[0].microphone == nil)
        #expect(workItems[0].systemAudio == nil)
        #expect(workItems[1].microphone == microphone)
        #expect(workItems[2].startOffset == 600)
        #expect(workItems[2].duration == 300)
        #expect(workItems[2].microphone == nil)
        #expect(workItems[2].systemAudio == nil)
    }

    @Test func reconstructsChunkProgressFromCompletedCheckpoints() {
        #expect(AppCoordinator.meetingChunkProgress(completed: 0, total: 18) == 0)
        #expect(AppCoordinator.meetingChunkProgress(completed: 9, total: 18) == 0.5)
        #expect(AppCoordinator.meetingChunkProgress(completed: 18, total: 18) == 1)
        #expect(AppCoordinator.meetingChunkProgress(completed: 24, total: 18) == 1)
    }

    @Test func recoveryAndFinalizationCarryOneReservedHistoryIdentity() {
        let handle = makeHandle()
        let reservation = UUID()
        let differentHistoryRecordID = UUID()
        let finalizationPlan = MeetingFinalizationPlan(
            handle: handle,
            sourceChunks: [],
            failedSequences: [],
            completedASRCheckpoints: [],
            completedDiarizationSequences: [],
            reservedTranscriptionRecordID: reservation
        )
        let recoverySnapshot = NoteCaptureRecoverySnapshot(
            handle: handle,
            mode: .note,
            state: .finalizing,
            recoveryTarget: nil,
            sourceChunks: [],
            failedSequences: [],
            completedASRCheckpoints: [],
            completedDiarizationSequences: [],
            reservedTranscriptionRecordID: reservation
        )

        #expect(finalizationPlan.reservedTranscriptionRecordID == reservation)
        #expect(recoverySnapshot.reservedTranscriptionRecordID == reservation)
        #expect(finalizationPlan.reservedTranscriptionRecordID == recoverySnapshot.reservedTranscriptionRecordID)
        #expect(finalizationPlan.reservedTranscriptionRecordID != differentHistoryRecordID)
    }
    @Test func workItemUsesSourceOffsetAndLongestAvailableSourceDurationExactly() throws {
        let handle = makeHandle()
        let startOffset = 37.125
        let microphone = checkpoint(
            for: handle,
            sourceID: handle.microphoneSourceID,
            sequence: 0,
            startOffset: startOffset,
            duration: 4.5
        )
        let systemAudio = checkpoint(
            for: handle,
            sourceID: handle.dualSourceSystemAudioID,
            sequence: 0,
            startOffset: startOffset + (0.5 / Double(MeetingCaptureSpoolPlan.sampleRate)),
            duration: 4.75
        )

        let workItem = try #require(
            AppCoordinator.meetingChunkWorkItems(
                sourceChunks: [microphone, systemAudio],
                failedSequences: [],
                handle: handle
            ).first
        )

        #expect(workItem.startOffset == startOffset)
        #expect(workItem.duration == 4.75)
    }

    @Test func micOnlyCaptureBuildsWorkItemsWithoutASystemAudioSource() throws {
        let handle = NoteCaptureHandle(
            sessionID: UUID(),
            microphoneSourceID: UUID()
        )
        let microphone = (0..<3).map {
            checkpoint(for: handle, sourceID: handle.microphoneSourceID, sequence: $0)
        }

        let workItems = try AppCoordinator.meetingChunkWorkItems(
            sourceChunks: Array(microphone.reversed()),
            failedSequences: [],
            handle: handle
        )

        #expect(workItems.map(\.sequence) == [0, 1, 2])
        #expect(workItems.allSatisfy { $0.systemAudio == nil })
        #expect(workItems.map(\.microphone) == microphone)
        #expect(workItems.allSatisfy(AppCoordinator.shouldCreateMeetingTranscriptionInput))
    }
}

/// The system-audio identifier of a fixture that was started with system audio.
private extension NoteCaptureHandle {
    var dualSourceSystemAudioID: UUID {
        guard let systemAudioSourceID else {
            preconditionFailure("This capture fixture must own a system-audio source.")
        }
        return systemAudioSourceID
    }
}
