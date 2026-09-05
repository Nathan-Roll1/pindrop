//
//  DiarizationSetupNotice.swift
//  Pindrop
//
//  Created on 2026-08-22.
//

import SwiftUI

/// Diarization setup warning / download banner. One copy for Dictate, Meeting,
/// and Library; the chrome comes from `InlineNotice`.
struct DiarizationSetupIssueBanner: View {
    @Environment(\.locale) private var locale

    let message: String
    let isDownloading: Bool
    let progress: Double
    let onDownload: (() -> Void)?

    var body: some View {
        if isDownloading {
            InlineNotice(
                kind: .info,
                message: message,
                systemImage: "arrow.down.circle",
                progress: progress
            )
        } else {
            InlineNotice(
                kind: .warning,
                message: message,
                actionTitle: onDownload == nil ? nil : localized("Download model", locale: locale),
                actionIdentifier: "diarizationSetupIssueDownloadButton",
                action: onDownload
            )
        }
    }
}

#Preview("DiarizationSetupIssueBanner") {
    VStack(spacing: 10) {
        DiarizationSetupIssueBanner(
            message: "Speaker labels need the diarization model.",
            isDownloading: false,
            progress: 0,
            onDownload: {}
        )
        DiarizationSetupIssueBanner(
            message: "Downloading the diarization model.",
            isDownloading: true,
            progress: 0.42,
            onDownload: nil
        )
    }
    .padding(16)
    .frame(width: 560)
    .background(AppColors.contentBackground)
    .themeRefresh()
}
