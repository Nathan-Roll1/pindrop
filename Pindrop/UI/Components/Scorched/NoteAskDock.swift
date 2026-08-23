//
//  NoteAskDock.swift
//  Pindrop
//
//  Created on 2026-08-23.
//
//  "Ask this note", in the band above the footer (Round B).
//
//  A dock, not a panel and not a window: the questions are about the note that
//  is on screen, so the answers stay on the same page, and following a source
//  link is a scroll rather than a trip somewhere else.
//
//  The dock draws a conversation it does not own. `NoteChatService` holds the
//  thread for the life of the app run and the note page runs the asking, so
//  closing and reopening the dock costs nothing and loses nothing.
//

import SwiftUI
import Foundation

struct NoteAskDock: View {
    @Environment(\.locale) private var locale
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    // MARK: Inputs

    /// Everything asked and answered about this note so far.
    let messages: [NoteChatMessage]
    /// What the dock is doing: waiting, thinking, or holding a failure.
    let phase: NoteAskPhase
    /// The question being typed. The page owns it so a retry can refill it.
    @Binding var draft: String
    /// The room the page has. The exchange list opens to a fraction of it.
    let canvasHeight: CGFloat
    /// Sends one question.
    var onSubmit: ((String) -> Void)?
    /// Forgets this note's conversation.
    var onClear: (() -> Void)?
    /// Puts the corner back to the floating control.
    var onClose: (() -> Void)?
    /// Follows one cited span into the transcript.
    var onFollowSource: ((NoteChatSource) -> Void)?

    @FocusState private var isFieldFocused: Bool

    /// Inter 13/20: one notch airier than the interface body, because an answer
    /// is read as prose and not as a label.
    private static let answerMetrics = TypographyRoleMetrics(
        family: .inter, size: 13, weight: .regular, lineHeight: 20
    )
    /// The anchor the list follows. The newest thing said is at the bottom, and
    /// that is where a reader expects to be.
    private static let bottomAnchor = "note.ask.bottom"

    private var hasThread: Bool { !messages.isEmpty }

    private var showsExchanges: Bool {
        hasThread || phase.isThinking || phase.failure != nil
    }

    // MARK: Body

    var body: some View {
        VStack(spacing: 8) {
            dock

            Text(NoteAskPresentation.caption(locale: locale))
                .font(AppTypography.caption)
                .foregroundStyle(AppColors.textTertiary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity, alignment: .center)
                .accessibilityIdentifier("note.ask.caption")
        }
        .padding(.bottom, 12)
        // Escape gets out of the dock. The floating control is not on screen
        // while this is, so nothing else is listening for it.
        .background {
            Button { onClose?() } label: { EmptyView() }
                .keyboardShortcut(.cancelAction)
                .opacity(0)
                .frame(width: 0, height: 0)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
        // The tick of delay is what lets the claim win: an assignment made
        // while the dock is still being inserted loses to the window's current
        // first responder, and the question lands in the title instead.
        .onAppear {
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(50))
                isFieldFocused = true
            }
        }
        // Thinking disables the field, and disabling drops focus. The reader's
        // next move after an answer is a follow-up, so the field takes focus
        // back the moment it can be typed into again.
        .onChange(of: phase) { _, newValue in
            guard NoteAskPresentation.isInputEnabled(phase: newValue) else { return }
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(50))
                isFieldFocused = true
            }
        }
        .accessibilityIdentifier("note.ask.dock")
    }

    private var dock: some View {
        VStack(spacing: 0) {
            header

            if showsExchanges {
                exchanges
            }

            inputRow
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppColors.windowBackground)
        .clipShape(
            RoundedRectangle(cornerRadius: NoteAskPresentation.cornerRadius, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: NoteAskPresentation.cornerRadius, style: .continuous)
                .strokeBorder(AppColors.border, lineWidth: 1)
        )
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "sparkles")
                .font(.system(size: 12))
                .foregroundStyle(AppColors.accent)
                .accessibilityHidden(true)

            Text(NoteAskPresentation.title(locale: locale))
                .font(AppTypography.overline)
                .tracking(AppTypography.overlineMetrics.tracking)
                .textCase(.uppercase)
                .foregroundStyle(AppColors.textTertiary)

            Spacer(minLength: 8)

            if hasThread {
                Button { onClear?() } label: {
                    Text(NoteAskPresentation.clearTitle(locale: locale))
                        .font(AppTypography.captionMedium)
                        .foregroundStyle(AppColors.textTertiary)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .focusRing(.rounded(.sm))
                .accessibilityIdentifier("note.ask.clear")
            }

            Button { onClose?() } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(AppColors.textSecondary)
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .focusRing(.circle)
            .accessibilityIdentifier("note.ask.close")
            .accessibilityLabel(NoteAskPresentation.closeLabel(locale: locale))
        }
        .padding(.top, 10)
        .padding(.horizontal, 16)
        .padding(.bottom, 6)
    }

    // MARK: Exchanges

    private var exchanges: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: NoteAskPresentation.exchangeSpacing) {
                    ForEach(messages) { message in
                        exchangeRow(message).id(message.id)
                    }

                    if phase.isThinking {
                        thinkingRow
                    }

                    if let failure = phase.failure {
                        InlineNotice(
                            kind: .error,
                            message: failure.message,
                            actionTitle: NoteAskPresentation.retryTitle(locale: locale),
                            actionIdentifier: "note.ask.error.retry",
                            action: { onSubmit?(failure.question) }
                        )
                        .accessibilityIdentifier("note.ask.error")
                    }

                    Color.clear
                        .frame(height: 1)
                        .id(Self.bottomAnchor)
                        .accessibilityHidden(true)
                }
                .padding(.horizontal, 16)
                .padding(.top, 4)
                .padding(.bottom, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: NoteAskPresentation.maxExchangeHeight(canvasHeight: canvasHeight))
            .onChange(of: messages.last?.id) { _, _ in scrollToNewest(proxy) }
            .onChange(of: phase) { _, _ in scrollToNewest(proxy) }
            .onAppear { scrollToNewest(proxy, animated: false) }
        }
        .accessibilityIdentifier("note.ask.exchanges")
    }

    @ViewBuilder
    private func exchangeRow(_ message: NoteChatMessage) -> some View {
        switch message.role {
        case .person:
            questionRow(message)
        case .assistant:
            answerRow(message)
        }
    }

    private func questionRow(_ message: NoteChatMessage) -> some View {
        HStack(spacing: 0) {
            Spacer(minLength: 48)

            Text(message.text)
                .font(AppTypography.body)
                .foregroundStyle(AppColors.textPrimary)
                .multilineTextAlignment(.leading)
                .padding(.vertical, 6)
                .padding(.horizontal, 12)
                .background(
                    RoundedRectangle(
                        cornerRadius: NoteAskPresentation.bubbleRadius,
                        style: .continuous
                    )
                    .fill(AppColors.contentBackground)
                )
                .overlay(
                    RoundedRectangle(
                        cornerRadius: NoteAskPresentation.bubbleRadius,
                        style: .continuous
                    )
                    .strokeBorder(AppColors.border, lineWidth: 1)
                )
                .frame(maxWidth: NoteAskPresentation.answerMaxWidth, alignment: .trailing)
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .accessibilityIdentifier("note.ask.question")
    }

    private func answerRow(_ message: NoteChatMessage) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "sparkles")
                .font(.system(size: 12))
                .foregroundStyle(AppColors.accent)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 8) {
                Text(message.text)
                    .font(Self.answerMetrics.font)
                    .lineSpacing(Self.answerMetrics.lineSpacing)
                    .foregroundStyle(AppColors.textPrimary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(
                        maxWidth: NoteAskPresentation.answerMaxWidth,
                        alignment: .leading
                    )

                if !message.sources.isEmpty {
                    HStack(spacing: 12) {
                        ForEach(message.sources) { source in
                            sourceLink(source)
                        }
                    }
                }
            }

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityIdentifier("note.ask.answer")
    }

    private func sourceLink(_ source: NoteChatSource) -> some View {
        Button { onFollowSource?(source) } label: {
            Text(NoteAskPresentation.sourceTitle(source, locale: locale))
                .font(AppTypography.labelSemibold)
                .foregroundStyle(AppColors.accent)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusRing(.rounded(.sm))
        .help(source.text)
        .accessibilityIdentifier("note.ask.source")
    }

    /// What the dock says while a question is with the provider. Quiet on
    /// purpose: it is the same row an answer will land in.
    private var thinkingRow: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "sparkles")
                .font(.system(size: 12))
                .foregroundStyle(AppColors.accent)
                .accessibilityHidden(true)

            Text(NoteAskPresentation.thinkingText(locale: locale))
                .font(Self.answerMetrics.font)
                .foregroundStyle(AppColors.textTertiary)

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityIdentifier("note.ask.thinking")
    }

    // MARK: Input

    private var inputRow: some View {
        VStack(spacing: 0) {
            Rectangle()
                .fill(AppColors.border)
                .frame(height: 1)

            HStack(spacing: 10) {
                Image(systemName: "sparkles")
                    .font(.system(size: 13))
                    .foregroundStyle(AppColors.textTertiary)
                    .accessibilityHidden(true)

                ZStack(alignment: .leading) {
                    if draft.isEmpty {
                        Text(placeholder)
                            .font(AppTypography.body)
                            .foregroundStyle(AppColors.textTertiary)
                            .allowsHitTesting(false)
                    }

                    TextField("", text: $draft)
                        .font(AppTypography.body)
                        .foregroundStyle(AppColors.textPrimary)
                        .textFieldStyle(.plain)
                        .focused($isFieldFocused)
                        .disabled(!NoteAskPresentation.isInputEnabled(phase: phase))
                        .onSubmit(submit)
                        .accessibilityIdentifier("note.ask.field")
                        .accessibilityLabel(placeholder)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                quickActionChip
            }
            .padding(.vertical, 10)
            .padding(.horizontal, 16)
        }
    }

    private var placeholder: String {
        NoteAskPresentation.placeholder(hasThread: hasThread, locale: locale)
    }

    private var quickActionChip: some View {
        Button {
            onSubmit?(NoteChatService.listActionItemsQuestion)
        } label: {
            Text(NoteAskPresentation.quickActionTitle(locale: locale))
                .font(AppTypography.captionMedium)
                .foregroundStyle(AppColors.textSecondary)
                .fixedSize()
                .padding(.vertical, 4)
                .padding(.horizontal, 8)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(AppColors.contentBackground)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(AppColors.border, lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
        .focusRing(.rounded(.sm))
        .disabled(!NoteAskPresentation.isInputEnabled(phase: phase))
        .opacity(NoteAskPresentation.isInputEnabled(phase: phase) ? 1 : 0.4)
        .accessibilityIdentifier("note.ask.quickAction")
    }

    // MARK: Actions

    private func submit() {
        guard NoteAskPresentation.canSend(question: draft, phase: phase) else { return }
        onSubmit?(draft)
    }

    private func scrollToNewest(_ proxy: ScrollViewProxy, animated: Bool = true) {
        withAnimation(animated && !reduceMotion ? AppTheme.Animation.normal : nil) {
            proxy.scrollTo(Self.bottomAnchor, anchor: .bottom)
        }
    }
}

// MARK: - Preview

#Preview("Ask dock") {
    NoteAskDock(
        messages: [
            NoteChatMessage(role: .person, text: "What did we decide about the launch date?"),
            NoteChatMessage(
                role: .assistant,
                text: "You moved the launch to the first week of October so the pricing page ships first.",
                sources: [
                    NoteChatSource(
                        segmentID: "seg-1",
                        revisionID: UUID(),
                        startOffset: 192,
                        timestampLabel: "03:12",
                        speakerLabel: "You",
                        text: "Let us move the launch to October."
                    )
                ]
            ),
        ],
        phase: .idle,
        draft: .constant(""),
        canvasHeight: 640
    )
    .padding(40)
    .frame(width: 820)
    .background(AppColors.contentBackground)
    .environment(\.locale, Locale(identifier: "en"))
    .themeRefresh()
}
