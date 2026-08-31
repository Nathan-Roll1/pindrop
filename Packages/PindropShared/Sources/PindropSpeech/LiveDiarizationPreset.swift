//
//  LiveDiarizationPreset.swift
//  PindropSpeech
//
//  Created on 2026-08-31.
//
//  The one place the streaming speaker preset is chosen.
//

import FluidAudio
import Foundation

/// Streaming Sortformer preset the live speaker path runs, and everything derived
/// from it.
///
/// One source of truth on purpose. Readiness checks a bundle on disk and the live
/// engine loads that same bundle, so a preset change that only lands in one of
/// them makes readiness false after a good download, with no error to show and no
/// live labels ever. Nothing outside this type spells a Sortformer file name.
public enum LiveDiarizationPreset {

    /// Balanced v2.1: about 1.04 s of latency, 20.57 percent DER on AMI SDM.
    ///
    /// `fastV2_1` has the same latency with a much smaller FIFO, and
    /// `highContextV2*` costs about 30.4 s of latency, which is not live at all.
    /// FluidAudio reports v2.1 can degrade when many people talk at once, so
    /// `balancedV2` stays the fallback worth trying for crowded rooms.
    public static let variant: ModelNames.Sortformer.Variant = .balancedV2_1

    /// Kept reachable for crowded rooms. See `variant`.
    public static let crowdedRoomVariant: ModelNames.Sortformer.Variant = .balancedV2

    /// Chunking and cache settings that match how the chosen bundle was converted.
    /// Reading them off the variant keeps the two from drifting apart.
    public static let config: SortformerConfig = variant.defaultConfiguration

    /// On-disk bundle name inside `FeatureModelType.liveDiarization.repoFolderName`.
    /// `SortformerNvidiaLow_v2.1.mlmodelc` for the balanced preset;
    /// `Sortformer_v2.1.mlmodelc` is a different bundle, for the fast preset.
    public static let bundleFileName: String = variant.fileName
}
