//
//  ConferenceAudioProcessProbe.swift
//  Pindrop
//
//  Created on 2026-09-03.
//
//  Reads which processes currently hold the microphone and the speakers.
//

import AudioToolbox
import CoreAudio
import Foundation
import PindropCore

// MARK: - Values

/// One audio process as the HAL currently reports it.
struct ConferenceAudioProcessState: Equatable, Sendable {
    let bundleIdentifier: String
    /// True while the process has at least one active input stream.
    let isRunningInput: Bool
    /// True while the process has at least one active output stream.
    let isRunningOutput: Bool
}

/// A HAL property read that came back with a non-zero `OSStatus`.
///
/// macOS 14.2 and 14.3 return an error for the process object list. That is
/// "no call detected", never a crash and never a second availability axis:
/// system audio capture already answers whether the meeting feature exists.
struct ConferenceAudioProcessReadError: Error, Equatable {
    let status: OSStatus
}

// MARK: - Seam

/// The one call the conference monitor makes into Core Audio.
///
/// A protocol so the monitor's rules can be tested without a HAL, which is the
/// only way those tests can be deterministic: the real list depends on whatever
/// the machine happens to be running.
protocol ConferenceAudioProcessProbe: Sendable {
    /// Current state of every audio process, or the failing `OSStatus`.
    ///
    /// Always resolves off the main actor. `AudioObjectGetPropertyData` can
    /// block on `coreaudiod`, and a blocked main actor is a frozen menu bar.
    func readProcessStates() async throws -> [ConferenceAudioProcessState]
}

// MARK: - Core Audio conformer

/// Reads `kAudioHardwarePropertyProcessObjectList` and the per-process flags.
///
/// This works because Pindrop is not sandboxed (`Pindrop.entitlements` has no
/// `com.apple.security.app-sandbox` key). A sandboxed build would see only
/// itself. It needs no new entitlement and asks for no new permission: the app
/// already creates process taps through the same framework generation.
final class CoreAudioConferenceProcessProbe: ConferenceAudioProcessProbe {
    /// Every HAL read runs here, never on the main actor.
    private let queue = DispatchQueue(label: "tech.watzon.pindrop.conference-process-probe")

    func readProcessStates() async throws -> [ConferenceAudioProcessState] {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                continuation.resume(with: Result { try Self.readStates() })
            }
        }
    }

    /// Synchronous HAL read. Callers must keep it off the main actor.
    private static func readStates() throws -> [ConferenceAudioProcessState] {
        try processObjectIDs().compactMap(state(for:))
    }

    private static func processObjectIDs() throws -> [AudioObjectID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let systemObject = AudioObjectID(kAudioObjectSystemObject)

        var dataSize: UInt32 = 0
        let sizeStatus = AudioObjectGetPropertyDataSize(systemObject, &address, 0, nil, &dataSize)
        guard sizeStatus == noErr else {
            throw ConferenceAudioProcessReadError(status: sizeStatus)
        }

        let capacity = Int(dataSize) / MemoryLayout<AudioObjectID>.size
        guard capacity > 0 else { return [] }

        var objectIDs = [AudioObjectID](repeating: 0, count: capacity)
        let status = objectIDs.withUnsafeMutableBufferPointer { buffer in
            AudioObjectGetPropertyData(
                systemObject,
                &address,
                0,
                nil,
                &dataSize,
                buffer.baseAddress!
            )
        }
        guard status == noErr else {
            throw ConferenceAudioProcessReadError(status: status)
        }

        // The second read can return fewer objects than the size read promised.
        let returned = Int(dataSize) / MemoryLayout<AudioObjectID>.size
        return Array(objectIDs.prefix(returned))
    }

    /// A process with no bundle identifier cannot match the catalog, so it is
    /// dropped rather than carried as an empty string.
    private static func state(for processID: AudioObjectID) -> ConferenceAudioProcessState? {
        guard let bundleIdentifier = bundleIdentifier(for: processID) else { return nil }
        return ConferenceAudioProcessState(
            bundleIdentifier: bundleIdentifier,
            isRunningInput: flag(kAudioProcessPropertyIsRunningInput, for: processID),
            isRunningOutput: flag(kAudioProcessPropertyIsRunningOutput, for: processID)
        )
    }

    private static func bundleIdentifier(for processID: AudioObjectID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyBundleID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var unmanaged: Unmanaged<CFString>?
        var dataSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = AudioObjectGetPropertyData(processID, &address, 0, nil, &dataSize, &unmanaged)
        guard status == noErr, let unmanaged else { return nil }
        // The property is documented as +1: the caller owns the returned CFString.
        let bundleIdentifier = unmanaged.takeRetainedValue() as String
        return bundleIdentifier.isEmpty ? nil : bundleIdentifier
    }

    private static func flag(
        _ selector: AudioObjectPropertySelector,
        for processID: AudioObjectID
    ) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: UInt32 = 0
        var dataSize = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(processID, &address, 0, nil, &dataSize, &value)
        // A process that cannot answer is reported as not running that stream,
        // which keeps a partial read on the safe side of the detection rule.
        return status == noErr && value != 0
    }
}
