# Changelog

All notable changes to GitPad. Dates are release dates; format loosely follows
[Keep a Changelog](https://keepachangelog.com/).

## [0.9.1] — unreleased

Cross-device sync, an icon that behaves, and setup that explains itself.

- **App icon.** A real Dock/Finder icon (`make-icon.swift` → `make-icns.sh`, regenerated
  by `build.sh`). The menu-bar glyph is now an explicit **template** image, so it adapts
  to light/dark menu bars and Increase Contrast; a sync failure switches it to a badged
  symbol instead of signalling with color alone.
- **True-conflict detection.** Conflict copies are written only for genuinely unmerged
  files (`--diff-filter=U`), not for every file that differed.
- **Device names.** Each Mac commits under its own name, and copies are named
  `<note> (conflict from <device> <date>).md`. Old-format copies still work.
- **New-device adoption.** A Mac whose notes are all still generated boilerplate adopts
  an existing remote instead of manufacturing conflict copies of your real notes. One
  typed character disables it.
- **Conflict screen.** An orange ⚠ in the header of every screen opens a dedicated
  review screen: both versions side by side, *Keep Mine* / *Use Theirs* / *Keep Both*.
  Shown once automatically the first time a conflict appears.
- **Sync doctor.** When sync fails, Settings names the cause — rejected SSH key (naming
  the key ssh actually offered), changed host key, missing repo, HTTPS login, no network
  — and offers the fix, including a one-click switch to HTTPS via the `gh` CLI.
- **Modify/delete no longer wedges the repo**; a note edited on one Mac and deleted on
  the other survives.
- **Push retry.** A push that loses a race is retried once instead of being reported as
  "offline".
- **Fetch on show.** Opening the panel syncs (debounced to 30s), so what you see is fresh.
- The menu bar's "Set Remote…" NSAlert is gone — it's now "Set Up Sync…", routing to the
  real setup screen. Onboarding's Test button reports the same friendly errors as
  everything else.
- Docs: `SYNCING.md` added; SECURITY.md documents the `StrictHostKeyChecking=accept-new`
  tradeoff. `test_gitsync.sh` grows to 8 scenarios.
- **Fixed: "Quit GitPad" was greyed out.** The status menu auto-enables its items, and
  every item's target was being set to the AppDelegate — which doesn't implement
  `terminate:`, so AppKit disabled it. Quit now targets `NSApp`. (The only way to quit
  was Activity Monitor or `pkill`.)

## [0.9] — unreleased

- Menu-driven shortcuts: ⌘N / ⌘L / ⌘S / ⌘⌫ / ⌘M / ⌘, now work from **every** screen
  (Library, Settings, onboarding), not just the capture editor. Replaces the old
  zero-opacity SwiftUI button hack with a real (hidden) main-menu "Note" submenu.
- Event-driven sync status — Settings updates the moment a sync finishes instead of
  guessing with a fixed 2-second delay; "Sync Now" shows a live "Syncing…" state.
- Faster search — file bodies are cached (mtime-validated, like titles) so typing in
  the Library no longer re-reads every note on each keystroke.
- Library: Esc clears an active search before leaving the screen.
- Docs: `CHANGELOG.md`, `CLAUDE.md`, and `GROWTH.md` added; README architecture,
  shortcuts, and screenshots sections refreshed.

### Readability, chrome & delete UX

- **Fixed: the panel was unreadable over light backgrounds.** It blended
  `.behindWindow` with only a 0.20-opacity tint — and *no* tint at all on the System
  theme — so text effectively rendered against the desktop while its color was picked
  from the window's appearance. Every theme now paints a real surface (~0.92 opaque,
  System follows the OS window color), so contrast holds over white, dark, or video.
  macOS **Reduce Transparency** makes it fully opaque.
- **One chrome icon system.** All nav controls are now a single `ChromeIcon` — identical
  28×28 container, one glyph size/weight, consistent hover background — so alignment
  comes from geometry instead of each SF Symbol's optical center. The two heavy glyphs
  were swapped for symmetric ones: new-note `square.and.pencil` → `plus`, and the busy
  four-arrow minimize → `minus`.
- **Roomier editor** — text inset 12×8 → 20×14, plus real leading (1.25 line height,
  6pt paragraph spacing). The style rides in the highlighter's base attributes, so it
  survives syntax highlighting instead of resetting as you type.
- Info-bearing metadata (dates, folders, group headers, sync counts) moved from tertiary
  to secondary — tertiary is the first thing to fail contrast over a translucent surface.
- **Undo delete.** Deleting a note shows a self-dismissing "Note deleted — Undo" banner,
  and there's an Undo Delete item in the Note menu. Restores the file and its pin. No
  confirmation dialog: delete already goes to the Trash, so undo beats taxing every
  intentional delete. The folder-delete confirmation stays — that one is destructive.

### Bug fixes (testing pass)

- Library now has a **New Note** button (next to Back); it creates the note where
  you're browsing — a folder → that folder, Daily → today's note, Recent/Inbox → Inbox.
- `newNote(in:)` is folder-aware; ⌘N still creates in Inbox, and the empty-scratch reuse
  is scoped to the same folder so a new note in folder B doesn't reuse an empty note in A.
- Folder ⋯ menu is now **vertical (⋮)** and uses the secondary chrome color instead of
  rendering accent-blue; sized to a nav-icon hit box so it lines up.
- Daily-note title carries the **full date incl. year** ("Friday, 18 July 2026").
- More breathing room between the Library chrome bar and the search field.
- Nav-bar glyphs use a square box + fixed weight so the left (library/new) and right
  (settings/minimize/close) icon clusters align exactly.
- Pill collapse/expand is **snappier** — ~0.2s strong ease-out instead of the mushy
  built-in ease-in-out (still instant under Reduce Motion). Also reachable via ⌘M and
  a double-click on the title bar.
- Themes refactored to hex-preset rows (base + 3 colors) so adding one is a one-liner;
  no behavior change to the five shipping themes.

## [0.8] — 2026-07-18

- Appearance-driven themes (each flips the whole window light/dark so every native
  control adapts), unified NavBar on every screen, pill mode, sync fixes, OSS docs.
- Follow-ups: fixed pill expand, persistent chrome + 2-column library, hardened git
  setup; folder edit/delete, pill tap+drag, drawn checkboxes, fixed daily title, Inbox;
  double-tap title bar to pill, full-width search, sync dot beside title, folder ⋯ menu.

## [0.7] — 2026-07-18

- Edit-menu shortcuts, header type scale, titled new notes, daily-note prefix,
  scalable folder picker.

## [0.6] — 2026-07-17

- Caret-anchored selection toolbar, themes, nav hierarchy, git-setup guide, ⌘S.

## [0.5] — 2026-07-17

- Sync settings with status/conflict tooling, inline folder creation.

## [0.4] — 2026-07-17

- Borderless refined panel, real header hiding, divider fix, font library,
  grouped settings.

## [0.3] — 2026-07-17

- Liquid glass, portrait panel, folders, rendered checkboxes, settings, polish.

## [0.2] — 2026-07-17

- Minimal UI overhaul — daily-note capture, library view, onboarding, smart editor.

## [0.1] — 2026-07-17

- First release: menu-bar markdown notes with git sync.
