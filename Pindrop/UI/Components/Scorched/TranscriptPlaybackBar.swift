//
//  TranscriptPlaybackBar.swift
//  Pindrop
//
//  Created on 2026-08-22.
//
//  The playback bar under a note's transcript (WP5).
//
//  A recorded note keeps its audio, so the transcript is something you can also
//  listen to: play, a hairline of progress, and the clock. It is deliberately
//  quieter than the Library player (no waveform, no speed chip): here the words
//  are the subject and the audio is the reference.
//
//  The bar reads the playback clock inside its own body. The clock ticks four
//  times a second and the note page around it holds a text editor, so the
//  observation stops in this leaf.
//

import SwiftUI
import Foundation

struct TranscriptPlaybackBar: View {
    @Environment(\.locale) private var locale

    let controller: MediaPlaybackController
    /// The recorded length, used until the asset reports its own.
    var fallbackDuration: TimeInterval = 0

    private var duration: TimeInterval {
        max(controller.duration, fallbackDuration)
    }

    private var progress: Double {
        guard duration > 0 else { return 0 }
        return min(1, max(0, controller.currentTime / duration))
    }

    private var clockText: String {
        let elapsed = NoteRowPresentation.elapsedText(controller.currentTime)
        let total = NoteRowPresentation.elapsedText(duration)
        return "\(elapsed) / \(total)"
    }

    var body: some View {
        HStack(spacing: 14) {
            playButton

            progressTrack

            Text(clockText)
                .font(AppTypography.monoSmall)
                .foregroundStyle(AppColors.textTertiary)
                .monospacedDigit()
                .environment(\.layoutDirection, .leftToRight)
                .fixedSize()
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(AppColors.windowBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(AppColors.border, lineWidth: 1)
        )
        .accessibilityIdentifier("note.page.transcript.player")
    }

    private var playButton: some View {
        Button(action: controller.togglePlayback) {
            Circle()
                .fill(AppColors.contentBackground)
                .frame(width: 28, height: 28)
                .overlay(Circle().strokeBorder(AppColors.border, lineWidth: 1))
                .overlay {
                    Image(systemName: controller.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(AppColors.textPrimary)
                        .offset(x: controller.isPlaying ? 0 : 1)
                }
        }
        .buttonStyle(.plain)
        .focusRing(.circle)
        .accessibilityIdentifier("note.page.transcript.player.play")
        .accessibilityLabel(localized(controller.isPlaying ? "Pause" : "Play", locale: locale))
    }

    private var progressTrack: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule(style: .continuous)
                    .fill(AppColors.border)
                    .frame(height: 3)

                Capsule(style: .continuous)
                    .fill(AppColors.accent)
                    .frame(width: geometry.size.width * progress, height: 3)
            }
            .frame(height: geometry.size.height, alignment: .center)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        seek(fraction: value.location.x / max(1, geometry.size.width))
                    }
            )
        }
        .frame(height: 16)
        .frame(maxWidth: .infinity)
        .accessibilityIdentifier("note.page.transcript.player.progress")
        .accessibilityLabel(localized("Playback position", locale: locale))
        .accessibilityValue(clockText)
    }

    private func seek(fraction: Double) {
        guard duration > 0 else { return }
        controller.seek(to: min(1, max(0, fraction)) * duration)
    }
}
