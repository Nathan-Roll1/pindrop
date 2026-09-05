//
//  SpeakerEmbeddingSpace.swift
//  PindropCore
//
//  Created on 2026-07-22.
//

import Foundation

/// Identifies the embedding geometry used for speaker centroids and training evidence.
/// Offline Community-1 vectors are not comparable to legacy online wespeaker embeddings.
public enum SpeakerEmbeddingSpace {
    public static let current = "fluid-audio-offline-community1-256-v1"
}
