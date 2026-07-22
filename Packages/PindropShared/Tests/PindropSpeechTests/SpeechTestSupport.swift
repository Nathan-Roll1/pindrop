// Created on 2026-07-22

import Foundation
import PindropCore
@testable import PindropSpeech

// MARK: - Shared test storage roots

enum SpeechTestSupport {
    /// Isolated temp roots so package tests never touch real Application Support.
    static func makeStorageLocations(
        label: String = "speech"
    ) throws -> (locations: ModelStorageLocations, root: URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("pindrop-\(label)-\(UUID().uuidString)", isDirectory: true)
        let pindropRoot = root.appendingPathComponent("Pindrop", isDirectory: true)
        let fluidRoot = root.appendingPathComponent("FluidAudio/Models", isDirectory: true)
        try FileManager.default.createDirectory(at: pindropRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: fluidRoot, withIntermediateDirectories: true)
        let locations = ModelStorageLocations(
            pindropApplicationSupportRoot: pindropRoot,
            fluidAudioModelsRoot: fluidRoot
        )
        return (locations, root)
    }

    static func applicationSupportPathFragment() -> String {
        "Application Support"
    }
}
