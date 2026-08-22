# Pindrop: Granola-class notes and capture UX

## Context

The `feature/granola-capture-lifecycle` branch (merged 2026-08-21) built the durable backend for three capture pillars: Dictate, Voice Note, and Meeting. The CaptureSession V13 domain now owns source-separated audio streams, chunked long-meeting durability, committed live revisions, anchored meeting-note generation, and per-stage provider assignment. The UI got only a partial rework ("restore Dictate dashboard and rework capture pages and note editor") and is in a rough state.

Goal for this effort:
1. A Granola-quality note experience: a New Note action that starts recording in the background, lets the user type while it captures, keeps the full transcript alongside the note, and produces cleaned-up enhanced notes after the capture ends, with both views always available.
2. A general design cleanup of the Dictate / Voice Note / Meeting Capture surfaces, especially the capture-in-progress page and the Start Dictating button.

Out of scope (explicitly deferred by the user): Google/Apple calendar integration and upcoming-meeting display. Also still deferred from the lifecycle plan: cross-meeting chat, camera consent, voice-note recovery delivery, Dictate migration into the capture domain (unless the design work forces it).

## Research findings

### Pindrop UI today (survey)

- Navigation: `MainWindow.swift` with sidebar groups Capture (Dictate, Voice Note, Meeting), Workspace (Library, Notes), Tools (Stats, Dictionary, Models). Route state in `MainWindowRouteState`.
- Pillar pages all live in `Pindrop/UI/Main/CapturePillarViews.swift` (Dictate ~15, Voice Note ~352, Meeting ~497). Editorial hero + stats + recent rows reusing `LibraryRowChrome`. Functional but unpolished; Start buttons are generic `PrimaryButton` with `record.circle`.
- There is NO capture-in-progress surface in the main window. All live capture UI is in the floating Orb/Pill indicators (`OrbFloatingIndicator.swift`). During a meeting or voice note the main window shows nothing live.
- Note editor is a separate document-style window (`Pindrop/UI/NoteEditor/NoteEditorWindow.swift`, `NoteEditorView` ~201): plain markdown string, dimmed heading markers in margin, autosave, listening chip for speak-to-append, meeting notes get an immutable citation section (speaker turns, per-speaker dots, AI summary block).
- Design system: `Pindrop/UI/Theme/Theme.swift` semantic colors + presets; typography ramp Newsreader/Inter/JetBrains Mono; spacing/radius/shadow/animation tokens; Scorched components in `Pindrop/UI/Components/Scorched/`. Drift: `HomeLayoutMetrics` duplicates font sizing vs `AppTypography`; ad-hoc `.system(size:)` calls remain; inline `.keyboardFocusRing(...)` everywhere.
- Rough spots called out: generic start buttons, no in-window recording state, recent rows reuse library chrome, waveform scrubber component exists but unwired in detail view, no selection/keyboard model in Library/Notes, speak-to-append only works with editor open.

### Pindrop services and data model (survey)

- Schema is at V14 (prompt snapshots + backfill). Capture domain models in `Packages/PindropShared/Sources/PindropData/Models/CaptureSessionModels.swift`: CaptureSessionModel (modes: dictation, voiceNote, meeting, importedMedia; states created→…→completed/abandoned), CaptureSourceModel (mic/systemAudio, sequence), CaptureChunkModel (sealed audio chunks, sha256), CaptureTranscriptRevisionModel (immutable per-stage revisions with segmentsJSON), CaptureStageProviderSnapshotModel + CaptureStagePromptSnapshotModel (frozen provider/prompt per stage), CaptureNoteReferenceModel (roles humanWritten/generatedMeeting/generatedVoiceNote, provenanceJSON with citations + humanAnchorContentSnapshot), CaptureFailureRecordModel.
- Services: `AudioRecorder` (mic + system audio via ScreenCaptureKit, spooled chunks, mixPCMFiles), `TranscriptionService` (streaming Apple/Nemotron RNNT + batch Parakeet/Whisper, diarization), `StreamingSessionController` (finalize pipeline: drain → dictionary → offline re-transcribe → enhancement → format → output; artifact-capture mode for voice notes/meetings), `CaptureSessionStore`, `CaptureStageAssignmentResolver` (per-stage provider/prompt resolution), `AIEnhancementService` (BYOM Claude/GPT/Gemini/Ollama, context-aware prompts), `AppCoordinator` (9,336 lines, orchestrates everything; voice-note and meeting capture contexts).
- Flows: dictation is streaming → finalize → paste (legacy TranscriptionRecord path, not capture domain). Voice note: artifact capture, committed revisions persisted, no offline re-transcription. Meeting: dual-source chunked spool, live transcription revisions, post-stop diarized final transcript + anchored generated note with citations.
- wip commit 78ba0bf (voice isolation preprocessor) is actually feature-complete, tests included.
- Debt: AppCoordinator size; dictation still outside capture domain; voice-note recovery delivery deferred (no persisted capture intent).

### Granola teardown (v7.498.1, Electron 42)

How Granola actually works, from grepping its asar bundle, native addons, and bundled Drizzle SQL migrations:

- Audio: CoreAudio process taps + a "Granola-Aggregate-Audio-Device" aggregate device (macOS 14.4+ tap API) with ScreenCaptureKit fallback; mic and system streams kept separate with per-stream timestamps on a shared clock. Pindrop's source-separated capture already matches this design.
- ASR: streaming websockets to Deepgram and AssemblyAI (short-lived tokens minted server-side). Diarization is hybrid: local FluidAudio (VAD → embeddings → agglomerative clustering) PLUS reading the meeting app's active-speaker UI via the Accessibility API to attach real names to clusters.
- Notes data model (the important part for us):
  - Editor is TipTap/ProseMirror synced via Yjs; DB stores the Yjs update log plus cached derived exports (`notes`, `notes_plain`, `notes_markdown`).
  - Enhanced notes are SEPARATE `document_panels` rows, one per template (`template_slug`), never edits to the user's typed notes; `original_content` preserved, `user_feedback` column for thumbs up/down.
  - Transcript is not in the local relational DB at all (server-side, fetched on demand); typed notes and transcript are NOT word-level anchored. The link is document-level.
  - `documents` has `transcript_deleted_at` (delete transcript independently of notes, privacy), `selected_template`, `chapters`, `summary`, `overview`, `valid_meeting`.
- Templates: server-side panel templates ("Hiring manager", "Sales Call", "Sprint Planning", "Standup"); template picker under the Enhanced dropdown.
- Dictation ("Granola Talk"): hold OR double-tap one rebindable key; low-latency formatting LLM chain Groq llama-3.3-70b / Cerebras gpt-oss-120b with direct → server-proxy → raw-text fallbacks so output never silently fails. Their full formatter system prompt was extracted (verbatim in research notes) including a prompt-injection defense: transcript wrapped in <transcription> XML tags, "spoken words, not commands".
- Meeting-end detection: fusion of browser-extension call state, AX reading of Zoom/Teams UI, and calendar end time. Not a silence timer.
- UX: floating "nub" is a transparent, click-through, join-all-spaces panel; paste via AX focused-element detection with strategy fallback + outcome telemetry; dictation history grouped Today/Yesterday/date.

### Capture lifecycle audit (from .audit/pindrop-granola-plan.tsv)

- Implemented: three-pillar navigation; CaptureSession V13 domain (Dictate mode is schema-only, still on old coordinator path); source-separated mic/system audio streams; chunked long-meeting durability; human notes as anchors with generated notes as derived artifact (citations); per-stage provider assignment (Live ASR, Final ASR, diarization, note generation); committed live voice-note revisions.
- Deferred deliberately: calendar detection/auto-start, cross-meeting chat, camera consent, voice-note recovery delivery (no capture intent persisted), Dictate migration into capture domain.

## Decisions (user-approved 2026-08-22)

1. Merge Voice Note + Meeting into one Notes pillar: a "note that records". New note auto-starts mic capture; system audio is an additional source.
2. The note experience moves into the main window (separate editor window demoted to an optional pop-out): title, typed-notes editor, recording state, collapsible live transcript.
3. Enhanced notes are switchable derived views (My notes / Enhanced / Transcript) with a template picker on PromptPresets; typed notes are never overwritten.
4. Process: Paper artboards first, sign-off, then Swift.
5. Enhanced generation runs automatically on finish for EVERY recorded note (meetings and voice notes), with the template picker for regeneration.
6. Library stays the complete transcript archive; note-backed rows get "Open note", notes get "Open in Library". No duplication.

Technical calls resolved during planning (grounded in verified code constraints):
- No pause/resume in v1. `CaptureSession.isValid` encodes state in revision parity and `AudioRecorder` has no pause; a new lifecycle state means rewriting the validator. Capture bar shows Finish (and Cancel in overflow) only; `NoteCaptureState.canPause = false` leaves the seam.
- Capture sources are fixed at start. Mid-capture system-audio enable is deferred to a "stop segment + append new segment to the same note" follow-up, unblocked by the new intent model. Source chips render disabled mid-capture with a help string naming why.
- New domain types keep note-specific names (`NoteCaptureHandle`, `NoteCaptureController`); Dictate's future migration reuses the CaptureSession domain, not this controller.
- V15 adds ONLY new @Model types, zero field changes to existing models. `Note.self` is listed in all 15 schema versions, so any field addition changes its entity hash everywhere and re-bricks stores (the b356cea failure mode).

## Plan

Three phases. Phase A is design sign-off in Paper; Phases B (domain) and C (UI) interleave — the dependency map is at the end.

### Phase A — Paper artboards (before any Swift)

Mock in the existing Paper design file, review in 4 gates, then extract exact values via Paper MCP `get_jsx`/`get_computed_styles` into `docs/notes-redesign-design-spec.md` (same discipline as `docs/scorched-earth-design-spec.md`). Sizes 1160×760, with 980×640 tight-proofs.

- Gate 1, structure: `50 Shell sidebar IA` (Capture: Dictate, Notes · Workspace: Library, Stats · Tools: Dictionary, Models), `51 Notes list` (+ empty variant), `52 Note idle`.
- Gate 2, capture + views: `53 Note recording` (+ transcript sheet expanded, + 980×640 proof), `54 Note finalizing`, `55 Enhanced ready` (+ failed), `56 Transcript view`, `57 Meeting variant` (two source chips, speakers menu).
- Gate 3, dictate + global: `58 Dictate idle redesigned`, `59 Dictate dictating in-place`, `60 Global capture bar over Library/Stats`.
- Gate 4, system: `61 Component sheet` (toggle, template menu, source chips, capture bar states, stage row, bubbles, notices — light + dark), `62/63 dark variants`, `64 pop-out` (only if WP8 ships this cycle).

### Phase B — Domain and services (work packages P0–P7)

**P0 — Schema V15 foundation (M).** Three new models in `Packages/PindropShared/Sources/PindropData/Models/CaptureNotePanelModels.swift`:
- `CaptureEnhancedPanelModel` (the Granola `document_panels` analog): sessionID, noteID, templatePresetIdentifier, frozen templateDisplayName, content, generation + supersededAt, providerSnapshotID + promptSnapshotID + assignmentAttempt, provenanceJSON, humanAnchorContentSnapshot, userFeedbackRawValue.
- `NoteViewStateModel`: noteID (unique), selectedPanelKey, transcriptDeletedAt (Granola's independent transcript deletion), updatedAt.
- `CaptureIntentModel`: sessionID (unique), destination (newNote/existingNote/transcriptOnly) + destinationNoteID, requestedSourceKindsJSON, requestedTemplatePresetIdentifier, origin, createdAt.
Wire V15 as `.lightweight` in `TranscriptionRecordSchema.swift` (Schema.Version(1,0,14)); extend `PindropPersistentSchemaVersion`; both container factories + `validateStoreAccess`; and the three `Pindrop/PindropApp.swift` repair-service edits: `inferredStoreVersion` newest-first table probe for `ZCAPTUREENHANCEDPANELMODEL`, `referenceVersion`, and generalizing the hard-coded `ZCAPTURESTAGEPROMPTSNAPSHOTMODEL` filters in `makeReferenceArtifacts` into a per-version exclusion set.
Tests: `SchemaV15MigrationTests` mirroring V14's (counts, order, disk-backed V14→V15 migration), plus a repair-service test that a damaged V15 store repairs to V15, not V14.

**P1 — Unified capture handle + variable source set (L).** Add `case note` to `CaptureSessionMode` (`PindropCore/Capture/CaptureSession.swift:11`) with `isNoteCapture` helper; do NOT migrate existing session rows (mode is invariant-checked). New `NoteCaptureHandle { sessionID, microphoneSourceID, systemAudioSourceID? }`. Refactor `CaptureSessionStore`'s `OwnedMeeting` → `OwnedNoteCapture { session, sources: [CaptureSourceModel] }`; a mic-only note must create NO system-audio source row (`finishMeetingSources` throws on chunkless sources). Make `MeetingCaptureSpoolPlan.systemAudioSourceID` optional through `MediaIngestionService`/`MediaLibrary` (`makeMixedMeetingChunk` already accepts optional sides). Unify `voiceNoteRecoveryCandidates`/`meetingRecoveryCandidates` into `noteCaptureRecoveryCandidates()`; widen the `generatedMeetingNote` mode assert. Delete `MeetingCaptureHandle`, let the compiler find call sites.
Tests: extend `CaptureSessionStoreTests` (mic-only round trip, no spurious source rows, one-source finish accepted, dual-source parity); `LongMeetingReliabilityTests` stays green as the durability gate.

**P2 — Capture intent (S/M).** Write `CaptureIntentModel` in the same transaction as capture start; `noteCaptureRecoveryCandidates()` returns intent + latest checkpoint. Recovery *delivery* (startup consumer) stays deferred to P7.

**P3 — Live transcript during durable capture (S).** `SourceSeparatedCaptureBackend.startCapture` (`Pindrop/Services/AudioRecorder.swift:3026`) currently discards buffers (`_ = onBuffer`); forward microphone-child buffers only (system audio must not reach the streaming pump). Generalize `StreamingSessionController`'s artifact API from `VoiceNoteCaptureHandle` to `NoteCaptureHandle`; checkpoint persistence is unchanged (keyed on microphoneSourceID). Keep the `artifactPersistenceDisabled` degradation and add a duration threshold: long captures may drop live transcription rather than risk the durable spool.
Tests: `AudioRecorderTests` with `MockAudioCaptureBackend` (mic buffers forwarded, system buffers not); `StreamingSessionControllerTests` for two-source artifact capture.

**P4 — `NoteCaptureController` + `NoteCaptureState` + `CaptureArbiter` (L, riskiest).** New `@MainActor @Observable NoteCaptureState` in `Pindrop/Models/` (phase: idle/starting/capturing/finalizing(stage)/enhancing/completed/failed; sources, elapsed, levels, liveTranscript mirroring `LiveTranscriptState`, panels, degraded flag). New `Pindrop/Services/NoteCaptureController.swift` with initializer DI, typed `NoteCaptureError: LocalizedError`, `Log` categories. Narrow `CaptureArbiter` protocol (claim/release/busy + lifecycle notifications) that `AppCoordinator` conforms to, so the controller never reaches into the coordinator. Move (not duplicate) the meeting/voice-note lifecycle out of `AppCoordinator` — contexts, start/stop/finalize, `generateMeetingNoteIfNeeded`, AND the termination/interruption checkpointing paths in the same package (partial extraction makes quit-mid-capture unrecoverable). Two bisectable commits: forwarders first, then deletion (~1,200–1,500 lines out of the 9,300-line coordinator). Leave `NoteAppendListeningCoordinator` alone; it dies with the editor window.
Tests: `NoteCaptureControllerTests` with mocks + in-memory store: start-while-busy, cancel-during-start, stop-during-finalize, termination-mid-capture checkpointing (port the coordinator's existing assertions).

**P5 — Enhanced panels + auto-generation + regeneration (M/L).** Panel CRUD + `nextNoteGenerationAttempt(sessionID:)` allocator in `CaptureSessionStore+NotePanels.swift`. New `NoteEnhancementService.generatePanel(sessionID:noteID:templatePresetIdentifier:)`: allocate attempt → `resolveAssignment` with new `promptPresetOverride` parameter on `CaptureStageAssignmentResolver.select` → reuse `MeetingNoteDerivation.make` evidence building verbatim (its `<untrusted-*>` envelope already subsumes Granola's injection defense; `wholeChunkCitation` fallback covers mic-only notes) → `aiEnhancementService.generateMeetingNote` → sanitize → save panel, superseding the prior generation of the same template. Auto-generation: `NoteCaptureController` calls it on finish for every recorded note (decision 5). Legacy `.generated` meeting notes surface as a read-only "Meeting note" panel; legacy voice notes resolve to typed-notes + transcript with panels empty. Include a small "Save as note" action that copies a panel's content into a real `Note` (explicit, never automatic).
Tests: regeneration creates a second row with distinct snapshots and supersedes the first; typed-notes byte-identical before/after; legacy shapes render; resolver override covered in `SettingsStoreCaptureAssignmentResolverTests`.

**P6 — Three-view read APIs (M).** `noteCaptureViews(noteID:)` in `CaptureSessionStore+NotePanels.swift` returning typed-notes / panels / transcript / captureState; transcript assembled from `.finalTranscription` revisions (live-checkpoint fallback while capturing), diarization decoded via a helper factored out of `MeetingNoteDerivation.diarizedSegments`; respects `transcriptDeletedAt`; view-state persistence. One test suite per legacy shape (legacy meeting, legacy voice note, plain note, V15 note).

**P7 — Optional follow-ups.** Voice-note recovery delivery (startup consumer using persisted intent); "append segment to note" (the mid-capture system-audio answer); pop-out window parity.

### Phase C — UI (work packages WP0–WP9)

**WP0 — Design-system cleanup (S, no dependencies).** Move `HomeLayoutMetrics` typography (hero 46/52, stat numbers, overline tracking) into `AppTypography` roles (`heroDisplayMetrics`, `statNumberMetrics`, `overlineMetrics`, add `trackingEm` to `TypographyRoleMetrics`; exhaustive metrics test picks them up); strip `HomeLayoutMetrics` to pure layout. `.focusRing(.rounded(.sm))`/`.focusRing(.capsule)` conveniences off `AppTheme.Radius`, baked into PrimaryButton/SecondaryButton/FilterChip/SidebarItem. `AppIcon.font(...)` + `IconSlot` for the hardcoded 11–14pt icon sizes. Dedupe `DiarizationSetupIssueBanner` (exists twice: `CapturePillarViews.swift:923`, `HistoryView.swift:322`) into new `InlineNotice` + `StageProgressRow` components.

**WP1 — IA + routing (M, no dependencies).** In `MainWindow.swift`: prune `MainNavItem` to Dictate/Notes/Library/Stats/Dictionary/Models (Stats moves to Workspace); legacy alias map so persisted `"voice-note"`/`"meeting"` raw values resolve to `.notes`; `NotesRoute { list | note(UUID) }` sub-route on `MainWindowRouteState` with `openNote(id:)`/`closeNote()`; replace `onStartVoiceNote`/`onStartMeeting` with `onStartNoteCapture(NoteCaptureRequest)`. The six `NoteEditorWindowControllerRegistry`/`presentEditor` call sites (`AppCoordinator.swift:5925,8368,9148`; `CapturePillarViews.swift:487`; `NotesView.swift:403`) become `routeState.openNote`. Update `MainShellNavigationTests` in the same commit; View-menu ⌘1–6 renumbers derive automatically.

**WP2 — Notes page merge (M, after WP1).** One Notes page replaces the Voice Note pillar, Meeting pillar, and Workspace Notes page: `PageHeader` + search + split "New note" button (primary = mic note; menu = "New note with system audio", "New note without recording"; ⌘N = primary), Pinned section, date-grouped list (`NotesGrouping` + `SectionHeader`), rows with kind glyph / title / preview / Enhanced badge / mono duration; live rows show record dot + elapsed. Delete `MeetingCaptureOptionsSheet`; speaker count becomes a "Speakers: Auto ▾" meta chip on the note page. Extract `NotesView`'s keyboard-selection monitor into a `listKeyboardSelection` modifier (behavior already tested via `ListSelectionNavigationTests`). Menu-bar status item gains "New note" / "New note with system audio".

**WP3 — Note page in the main window (L, after WP1; binds P4/P6, can start against stubs once P0–P2 land).** `NotePageView`: header rail, Newsreader 34 title (left inset = heading-gutter width), meta chip row (SegmentedViewToggle, template menu, date/duration/speakers chips, tags), canvas capped at 720pt on the shared left axis, footer. Reuse `MarkdownEditor`/`MarkdownTextView` and the `NoteEditorPersistenceController` stack verbatim — do not rewrite persistence arbitration. States per the matrix: idle (no capture chrome), recording (editor NEVER disabled; Enhanced segment disabled with help text), finalizing (named stages via `StageProgressRow`, honest copy: "Long recordings can take a few minutes."), enhanced-ready (accent dot on segment + dismissible inline notice — NEVER auto-switch views), failed (`InlineNotice` + "Try again"). `NoteEditorWindowController` survives only as pop-out (WP8).

**WP4 — Capture bar, page + global (M, after WP3 + P4).** `CaptureBar` component, two densities: in-page (record dot, mono elapsed, `WaveformView` level bars — finally wired, source chips, Finish) and global (44pt strip pinned to content-pane bottom on every destination while capture is active elsewhere: dot, elapsed, note title, "Open note", "Finish"; reserves height, never overlays). Sidebar: `StatusCardPhase.finalizing`, status card becomes a navigate button, `SidebarItem` accessory record-dot on Notes while live. Pure `CaptureBarPresentation` value type for tests.

**WP5 — Transcript sheet + view (M, after WP3 + P3).** `TranscriptSegmentList`/`TranscriptSegmentBubble`: speaker dot + name + `monoTime` header, `transcriptBody` (Newsreader 17/26) body, same-speaker runs collapse. Static view: search + highlight + count, click-to-seek via `MediaPlaybackController`, speaker colors shared with `MediaTranscriptionDetailView` (later converge that view onto the same components). Live sheet during recording: bottom sheet with drag handle, snaps 0/40%/70%, autoscroll + "Jump to live" pill, tentative text in `textTertiary`, bound to `LiveTranscriptState.displayText` (not the 360-char orb tail). Esc collapses.

**WP6 — Enhanced view (L, after P5/P6).** Read-only rendered markdown (Newsreader headings, Inter 13/20 body); `TemplateMenuButton` (extract shared `MenuButtonChrome` — `ExportMenuButton` already duplicates SecondaryButton) listing PromptPresets + "Manage templates…"; selecting regenerates in place with the finalizing affordance; panels cached per (noteID, templateID, transcriptRevisionID) so switching back is instant. Citations: inline markers that jump to the Transcript view + flash the segment, plus a collapsed "Sources (n)" disclosure; reuse `MeetingNoteDerivation` citation guards. "Save as note" in overflow.

**WP7 — Dictate polish (M, after WP0/WP4).** `CaptureStartButton` on the header baseline row at the 40pt right padding, shortcut hint INSIDE via PrimaryButton's `keyboardHint`, 8pt `AppColors.recording` dot instead of `record.circle`, 36pt height. While dictating, the same frame swaps to the in-page `CaptureBar` variant (no layout jump); delete the ragged busy-warning block. Stats: 3 tiles (Words today / WPM / Streak), Sessions moves into the This-week chart header. Empty state replaces the "Speak. It's written." slogan with "No dictations yet." + "Press ⌥Space anywhere to start." Recent rows get keyboard selection.

**WP8 — Pop-out parity (S).** `NotePageView(chrome: .window)` through the surviving window controller; pinned floats keep working.

**WP9 — Localization + a11y sweep (S, last).** ~55 new keys through `Localization/app/*.yml` + `just l10n-sync` (capture bar/stages, enhanced states, template menu, transcript, note chrome, notes list, dictate empty state). Copy rules: verbs people say; errors name cause + next action; no slogans; no em/en sentence dashes. RTL mirroring for capture bar/bubbles/chips with timestamps pinned LTR. VoiceOver labels, reduce-motion, focus order. Stable a11y identifiers (`note.page.*`, `capture.bar.*`, `notes.list.*`) + `AppUITestSurface.notePage` fixture in `AppTestMode.swift` so CI UI tests can run even though local UI tests cannot.

### Dependency map and suggested order

```
Phase A (Paper, gates 1-4)  ──sign-off──▶ implementation
P0 ─▶ P1 ─▶ P2 ─▶ P3 ─▶ P4 ─▶ P5 ─▶ P6 ─▶ P7(optional)
WP0, WP1 (parallel with P0-P2) ─▶ WP2 ─▶ WP3 (needs P4+P6, stubs earlier) ─▶ WP4/WP5/WP6 ─▶ WP7 ─▶ WP8/WP9
```
Suggested session order: A gates → {WP0, WP1, P0} → {P1, WP2} → {P2, P3} → P4 → {P5, P6} → WP3 → {WP4, WP5, WP6} → WP7 → WP9 (→ WP8, P7 as time allows).

### Verification

- Every package: `just build` + `just test` green before moving on; new logic lands with Swift Testing suites named above (in-memory model containers, TestHelpers mocks). `LongMeetingReliabilityTests` is the standing durability gate for P1/P3/P4.
- Schema safety: disk-backed V14→V15 migration test + repair-service V15 test before anything else merges (P0). Review checklist item: no field additions to existing @Model types anywhere in the diff.
- End-to-end smoke after WP3+P4: `just build`, run the app, create a note (mic-only), type while speaking, finish, confirm transcript + auto-enhanced views; repeat with system audio playing media; confirm a legacy meeting note still renders (read-only panel) and Library cross-links work.
- UI tests are not runnable locally; decision logic lives in pure presentation types (`CaptureBarPresentation`, `NotePagePresentation`, `TranscriptSegmentPresentation`, `EnhancedViewPresentation`) with unit coverage, plus the `AppUITestSurface.notePage` fixture for CI.

### Risks

1. Store brick via shared-model hash change — highest; mitigated by the append-only rule + migration tests + review checklist.
2. Repair-service drift: `inferredStoreVersion` probe order and `makeReferenceArtifacts` filters must gain V15 entries or healthy stores get "repaired" down to V14.
3. Long-capture durability regression from concurrent streaming ASR + durable spool — degradation threshold + reliability tests.
4. AppCoordinator extraction: termination/interruption checkpointing must move with the contexts in one package.
5. `finishMeetingSources` strictness: mic-only sessions must omit the system-audio source row entirely.

