# Changelog

All notable changes to GitPad. Dates are release dates; format loosely follows
[Keep a Changelog](https://keepachangelog.com/).

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
