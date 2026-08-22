# Notes-that-record design spec

Last updated: 2026-08-22. Source of truth: Paper file "Pindrop — Scorched Earth Redesign", page "Notes that record", artboards 50-60. Values below are the authored values from those artboards. Map Paper tokens to the app theme as follows:

| Paper token | App theme role |
|---|---|
| `--color-page` #FCFBF7 | `contentBackground` |
| `--color-ground` #F6F4EE | `windowBackground` / surface fills |
| `--color-ink` / `-2` / `-3` | `textPrimary` / `textSecondary` / `textTertiary` |
| `--color-line` #E3DFD3 | `border` / `divider` |
| `--color-accent` #1F6D53, `--color-accent-soft` #E7EFE7 | `accent`, `accentBackground` |
| `--color-record` #B03A2E, `--color-record-soft` #F6E7E3 | `recording`, recording-soft background |

Dark mode: no separate mocks; every value below uses semantic roles, so the existing dark palette derivation applies unchanged.

Fonts: Newsreader (display/serif), Inter (UI), JetBrains Mono (timestamps, counts, kbd). Radius tokens: 6/8/10/999 as noted. All spacing in points.

## Sidebar (new IA)

- Groups with overline labels: CAPTURE (Dictate, Notes), WORKSPACE (Library, Stats), TOOLS (Dictionary, Models). Settings row stays at the bottom.
- Overline: Inter 11/600, letter-spacing +0.08em, textTertiary, padding 0 10 4 10. Groups separated by 16 top padding.
- Item row: padding 7/10, radius 8, gap 10; icon slot 18×18 (glyph 16, stroke 1.4); label Inter 13/500 textSecondary. Selected: contentBackground fill + 1px border, label Inter 13/600 textPrimary, icon stroke accent.
- Library keeps its mono count (JetBrains Mono 11/500 textTertiary). While a note capture is live, the Notes item's count slot shows an 8pt recording dot instead.
- Status card variants (bottom of sidebar): ready (existing accent-soft treatment, "Ready to dictate" + hotkey); recording (recording-soft bg, title "Recording · mm:ss" Inter 12/600, subtitle = note title in mono 11); finalizing (accent-soft, "Finalizing · mm:ss" + note title); dictating (recording-soft, "Dictating · m:ss" + "⌥ Space to stop"). The card is a button: click navigates to the capturing note (or Dictate).

## Notes list page (replaces Voice Note pillar, Meeting pillar, and workspace Notes page)

- Header: "Notes" Newsreader 34/38 −0.015em; meta beside it baseline-aligned (alignSelf bottom, pb 3): Newsreader Italic 16/22 textTertiary, humanized ("24 notes, three from today"; empty: "nothing here yet"). Right: search field (200pt) + split New note button.
- Split button: accent fill, radius 8, no gap between segments. Primary: padding 8/14→12, gap 7: plus glyph 12, "New note" Inter 13/600 white, "⌘N" mono 11 white at 72%. Divider 1px white at 28%. Menu segment: padding 8/10, chevron 10. Menu items: "New note with system audio", "New note without recording".
- Sections: PINNED, then date groups TODAY / YESTERDAY / weekday / date. Group header: Inter 11/600 +0.08em textTertiary + hairline.
- Row: padding 13/20, hairline bottom; lanes with fixed widths and 10 gaps: kind glyph slot 16 (doc / mic / mic+wave for meeting, stroke textTertiary) · title 220 Inter 13/500 textPrimary · preview flex Inter 13 textSecondary 1-line clamp · badge slot 74 right-aligned ("Enhanced" chip: accentBackground fill, accent Inter 11/600, radius 999, padding 2/8) · duration 44 mono 11/500 textTertiary right · time 64 Inter 12 textTertiary right.
- Live row: recording-soft fill, radius 8, dot 8 recording in the glyph slot, trailing lane 118 shows "REC mm:ss" mono 11/500 in recording color (replaces badge+duration+time).
- Empty state: centered, 40pt circle accentBackground with mic glyph accent; "No notes yet." Inter 13/600; "Click New note to start one. Pindrop records while you type." Inter 13 textSecondary.

## Note page (main window destination)

Content pane, padding 40 sides / 40 top / 32 bottom, vertical gap 24. Text column: left-aligned, max 720, with a 28pt marker gutter; the title and all body text share the axis at gutter+0 (i.e. 28 from column origin).

- Header rail: back chip ("‹ Notes", Inter 13/500 textSecondary); right cluster: Record button (secondary chrome: contentBackground + border, radius 8, padding 7/13, 8pt recording dot + "Record" Inter 12/600) shown only when no capture is attached; Export menu button (same chrome + chevron); 30×30 overflow icon button.
- Title: Newsreader 34/38 −0.015em, padding-left 28.
- Meta chip row (gap 8, padding-left 28): view toggle, then (Enhanced view only) template menu button, then chips: date, duration ("42:18 recording · 2 speakers" appears in the footer instead; the chips carry date, speakers, tags). Chip: radius 999, 1px border, padding 4/10, Inter 11/500 textSecondary; icon 11 textTertiary. "Speakers: Auto ▾" chip on meeting notes (menu sets expected speaker count; replaces the old options sheet). "Add tag" ghost chip in textTertiary.
- View toggle (SegmentedViewToggle): container windowBackground fill + border, radius 8, padding 2; segment padding 4/12, radius 6. Selected: contentBackground + border, Inter 12/600 textPrimary. Unselected: 12/500 textSecondary. Disabled (Enhanced during capture): 12/500 textTertiary + help text "Available when the recording is finished". Transcript segment carries a 6pt recording dot while live. Enhanced segment carries a 6pt accent dot when newly ready (cleared on first view). NEVER auto-switch views.
- Footer: hairline top, pt 12: "n words · edited …" Inter 11 textTertiary; right "⌘S to save" mono 11. Enhanced view: "Generated … · {template} template". Transcript view: "42:18 recording · 2 speakers".

### Markdown editor grammar (My notes view)

- Body: Inter 13/21 textPrimary. Block gap 8-10 between paragraphs/headings/quotes/code; headings get an extra 8 top.
- Lists group into a block with internal gap 3-4. Indent 20 per level; the marker sits at the text axis in a 20pt slot, item text at axis+20.
- Bullet markers are rendered glyphs, not raw markdown: level 1 "•", level 2 "◦", Inter 13/21 textTertiary. Ordered lists: "1." Inter 13/21 textTertiary. Checkboxes: 13×13, radius 3.5; checked = accent fill + white 1.6 check + line-through textTertiary label; unchecked = 1.3 stroke textTertiary.
- Headings keep visible hashes, styled: right-aligned in the 28pt gutter, padding-right 4-6, Newsreader at 60% opacity textTertiary; H2 heading Newsreader 20/26 500 with 15px hashes; H3 17/23 500 with 12px hashes (letter-spacing −0.02em so ### fits).
- Blockquote: 2px hairline bar (radius 999) + 14 left padding, Newsreader Italic 15/22 textSecondary.
- Inline code: chip in flow, mono 11/15 textSecondary, windowBackground fill, 1px border, radius 4, padding 1/5.
- Code block: windowBackground fill, 1px border, radius 8, padding 10/14, mono 11/17 textSecondary, pre whitespace.
- The editor is NEVER disabled while recording.

### Capture dock (bottom of note page while capture attached)

One connected block, full content width: transcript sheet (top half, radius 10/10/0/0) + capture bar (radius 0/0/10/10), windowBackground fill, 1px border, shared hairline between.

- Sheet collapsed (36): centered drag handle 36×4 line-color radius 999; row padding 6/16/10: mic glyph 13 + latest live line Newsreader 14/20 textSecondary one-line clamp + chevron up.
- Sheet expanded (snap points 0 / 40% / 70% of canvas; 300pt at default window, 260 at min): handle; header row "LIVE TRANSCRIPT" overline (Inter 11/600 +0.08em textTertiary) + search glyph + collapse chevron; lines column padding 6/40/16, gap 10, max 640: committed lines Newsreader 15/22 textSecondary, current line textPrimary with tentative tail textTertiary; "Jump to live" pill bottom-right (contentBackground + border, radius 999, accent Inter 11/600), shown when scrolled up. Esc collapses. Live transcript is microphone-only.
- Capture bar (page density): padding 10/16, gap 12: 8pt recording dot · elapsed mono 13/500 textPrimary · level bars (WaveformView, ~46×16) · spacer · source chips · Finish (accent fill, radius 8, padding 7/14, Inter 12/600 white). No pause in v1; Cancel lives in the overflow menu.
- Source chip on: accentBackground fill, 6pt accent dot, Inter 11/600 accent. Off: 1px border, 6pt ring dot, Inter 11/500 textTertiary. Disabled mid-capture with help text naming why (sources are fixed at start).

### Finalizing bar (replaces capture dock after Finish)

windowBackground fill, border, radius 10, padding 14/16, gap 8: spinner arc 14 accent + current stage Inter 12/600 textPrimary + completed stages Inter 12 textTertiary ("Transcription done") + elapsed mono 11 textTertiary right; 3px progress track (line color, accent fill, radius 999); caption Inter 11 textTertiary: "Writing your enhanced note comes next. Long recordings can take a few minutes. You can keep typing." Stage vocabulary mirrors MediaTranscriptionStage: Sealing audio → Transcribing → Identifying speakers → Writing note.

### Enhanced view (read-only, derived)

- Sections: heading Newsreader 20/26 500, gap 8 within, 10 extra top between sections. Bullets: 14pt slot "•" textTertiary, body Inter 13/21 textPrimary, trailing citation chip: min 16×16, radius 5, accentBackground fill, mono 10/600 accent, padding 0/4, top-margin 2. Clicking a citation switches to Transcript view, scrolls to and flashes the segment.
- End: "Sources (n)" disclosure (chevron 10 + Inter 12/500 textSecondary) with hint "Click a number to see it in the transcript" Inter 12 textTertiary.
- Template menu button (in meta row): secondary chrome (contentBackground + border, radius 8, padding 5/12): sparkle 12 accent + template name Inter 12/600 + chevron 10. Menu: contentBackground, border, radius 10, padding 6, width 224, shadow 0 8 24 rgba(ink,0.12): "TEMPLATES" overline; items padding 7/10 radius 6 Inter 13/500 textSecondary; selected item accentBackground fill + 13/600 textPrimary + accent check; separator; "Manage templates…" (opens existing preset sheet).
- Failed state: notice (recording-soft fill, border, radius 10, padding 12/14): alert glyph 14 recording + message Inter 12/17 ("Enhanced note failed. The AI provider did not respond within 20 seconds. Your notes and the transcript are safe.") + "Try again" secondary button. Below: "No enhanced note yet." Inter 13/600 + guidance 13 textSecondary.

### Transcript view (read-only, post-capture)

- Search field in meta row (200pt, secondary chrome): "Find in transcript" Inter 12 textTertiary; results filter + highlight, count "n results" in mono.
- Speaker turn: header row gap 8: 8pt speaker dot (You = accent; others from the existing participant color mapping shared with MediaTranscriptionDetailView) + name Inter 12/600 textPrimary + timestamp mono 11/500 textTertiary. Body: padding-left 16, Newsreader 15/22 textSecondary (the user's own key lines may read textPrimary), max 640. Consecutive paragraphs from one speaker collapse into one turn with 4 gap; 10 extra between turns.
- Playback bar above footer: windowBackground fill, border, radius 10, padding 10/16: 28pt circular play button (contentBackground + border) + 3px progress (accent played / line remaining) + "mm:ss / mm:ss" mono 11 textTertiary. Click a segment to seek.

## Global capture bar (every destination while a capture is active elsewhere)

Pinned to the bottom of the content pane, full pane width, reserves layout height (never overlays): padding 12/20, hairline top, contentBackground: 8pt recording dot + elapsed mono 12/500 + note title Inter 13/500 + "Recording continues while you work" Inter 12 textTertiary + spacer + "Open note" secondary button + "Finish" accent button. On the capturing note page it is replaced by the in-page capture dock.

## Dictate page

- CTA sits on the kicker baseline row (kicker left, CTA right at the 40 padding): accent fill, radius 8, padding 9/16, gap 8: 8pt WHITE dot + "Start dictating" Inter 13/600 white + "⌥ Space" mono 11 white 72%. Height 36.
- While dictating, the same frame swaps in place (no layout jump) to: recording-soft fill + border, radius 8, padding 8/14: 8pt recording dot + elapsed mono 13/500 + level bars + Stop (contentBackground + border, radius 6, padding 5/12, Inter 12/600). Delete the old busy-warning block.
- Stats: 3 tiles (Words today / Words per min / Streak); Sessions moves to the This-week chart header as trailing meta Inter 11/500 textTertiary ("12 sessions").
- Hero sub and recent previews: no em dashes; restructure with periods/colons.
- Empty state: "No dictations yet." / "Press ⌥ Space anywhere to start." (replaces the "Speak. It's written." slogan.)

## Copy rules

Verbs people say (Finish, Try again, View, Record, Open note, Start dictating). Errors name the cause and next action. Empty states name the situation and next action. No slogans. No em or en dashes as sentence dashes anywhere in UI copy.
