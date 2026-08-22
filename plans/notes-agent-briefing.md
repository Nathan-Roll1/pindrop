# Agent briefing: notes-that-record build

Read this fully before touching code. It applies to every work package.

## Context documents (read these first)

1. `plans/notes-that-record-plan.md`: the approved plan. Find your work package (P0-P7 or WP0-WP9) and read its section plus the Decisions and Risks sections.
2. `docs/notes-redesign-design-spec.md`: exact visual values for all UI work.
3. Repo conventions: `CLAUDE.md` at the repo root.

## Ground rules

- Repo: `/Users/watzon/Projects/personal/pindrop`, branch `feature/notes-that-record` (already checked out). Do NOT run any git write command (no commit, stash, checkout, reset). The orchestrator commits.
- HARD RULE: never add, remove, or change a stored property on any existing `@Model` type. `Note.self` and friends are listed in all 15 schema versions; a field change alters the entity hash everywhere and bricks user stores. New persistent state goes into NEW `@Model` types only (schema V15).
- New files in the `Pindrop/` app target must be registered in `Pindrop.xcodeproj/project.pbxproj` (objectVersion 90, explicit references). Follow the existing pattern: one `PBXBuildFile` entry, one `PBXFileReference` entry, add to the right group's `children`, add to the target's Sources build phase. Same for new files in `PindropTests/`. Files under `Packages/PindropShared/Sources/**` and its `Tests/**` are SwiftPM and need no registration. Prefer extending existing files or package sources when it is natural.
- New user-facing strings: use the `localized("English key", ...)` API and add the key to the YAML source under `Localization/app/en.yml` following the existing structure. Do NOT run `just l10n-sync` and do NOT edit the `.xcstrings` catalogs or other locale files; a final localization sweep handles those.
- UI copy rules: verbs people say; errors name cause + next action; empty states name situation + next action; no slogans; NEVER em/en dashes as sentence dashes.
- Tests: Swift Testing (`@Suite`/`@Test`, `#expect`/`#require`) for unit tests; in-memory model containers for store tests; mirror the nearest existing test file's structure; `sut` naming; helpers in `PindropTests/TestSupport.swift` and mocks in `PindropTests/TestHelpers/`.

## Machine quirks

- Broken brew shims can crash `ls`/`cat`: use `/bin/ls` and `/bin/cat`, or the Read/Glob/Grep tools.
- Builds share DerivedData. If `xcodebuild` reports a locked build database because another agent is building, wait ~60s and retry.
- UI tests cannot run on this machine. Put decision logic in pure presentation types with unit tests instead.

## Definition of done (per package)

1. `just build` passes (Bash timeout 600000).
2. Your package's tests pass via focused runs, e.g. `xcodebuild test -project Pindrop.xcodeproj -scheme Pindrop -testPlan Unit -destination 'platform=macOS' -only-testing:PindropTests/<YourSuite>` (or `swift test --package-path Packages/PindropShared --filter <...>` for package-only logic if that target is test-runnable; otherwise run through xcodebuild).
3. New behavior has a test that fails without the change. Never weaken or delete existing tests to get green; if an existing test conflicts with intended new behavior, update it and say so explicitly in your report.
4. Report honestly: files changed, commands run, actual outcomes, anything left incomplete. Your final message is machine-read; keep it structured.
