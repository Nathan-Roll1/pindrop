//
//  WaveformPeaks.swift
//  PindropCore
//
//  Created on 2026-07-09.
//
//  Foundation-only sidecar URL / JSON read-write / delete contract. AVFoundation
//  extraction and coalesced loading live in PindropMedia.
//

import Foundation

/// Waveform peak sidecar persistence for dictation audio.
/// Sidecar format: `<basename>.peaks` next to the audio file. JSON array of Float 0...1.
public enum WaveformPeaks {
    public static let defaultBucketCount = 200
    public static let sidecarExtension = "peaks"

    public static func sidecarURL(for audioURL: URL) -> URL {
        audioURL.deletingPathExtension().appendingPathExtension(sidecarExtension)
    }

    public static func writeSidecar(_ peaks: [Float], for audioURL: URL) throws {
        let sidecar = sidecarURL(for: audioURL)
        let data = try JSONEncoder().encode(peaks)
        try data.write(to: sidecar, options: .atomic)
    }

    public static func readSidecar(for audioURL: URL) throws -> [Float]? {
        let sidecar = sidecarURL(for: audioURL)
        guard FileManager.default.fileExists(atPath: sidecar.path) else { return nil }
        let data = try Data(contentsOf: sidecar)
        return try JSONDecoder().decode([Float].self, from: data)
    }

    public static func removeSidecar(for audioURL: URL, fileManager: FileManager = .default) {
        let sidecar = sidecarURL(for: audioURL)
        guard fileManager.fileExists(atPath: sidecar.path) else { return }
        try? fileManager.removeItem(at: sidecar)
    }
}
