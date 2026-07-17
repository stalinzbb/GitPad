# GitPad — Project Document

_Last updated: 2026-07-17_

## Goal
A minimalist, lightweight macOS note-taking app: instant capture via a global hotkey (Spotlight-style panel), a tiny "compact mode" sticky window for glancing at notes while working, and invisible sync through a private Git repository — no accounts, no cloud service, no merge dialogs.

## What it does
- **⌥Space** toggles a floating, non-activating panel over any app (Esc dismisses). Menu-bar-only app — no Dock icon.
- Notes are **plain Markdown files** in `~/Documents/GitPad/` — readable/editable by any other tool.
- Editor with light regex-based markdown highlighting (headers, bold, italic, inline code, list markers). Autosave on a 1-second debounce.
- **Compact Mode** shrinks the panel to a 300×220 sticky pinned top-right, always floating.
- **Git sync**: the notes folder is a git repo. On every save, every 5 minutes, and on wake, the app commits, fetches, merges, and pushes. Menu-bar icon tints orange while out of sync.
- **Conflict resolution** (automatic, never shows a UI): clean merges happen silently; a true same-file conflict keeps the local version and writes the remote version alongside as `name (conflict <date>).md`, so nothing is ever lost.

## Architecture
Swift + SwiftUI/AppKit, built with SwiftPM (no Xcode project). Zero third-party dependencies.

| File | Role |
|---|---|
| `Sources/GitPad/main.swift` | Entry point; also a `--sync <dir>` CLI mode used by tests |
| `Sources/GitPad/GitPadApp.swift` | AppDelegate: status item, Carbon global hotkey, sync scheduling |
| `Sources/GitPad/PanelWindow.swift` | Spotlight-style NSPanel + compact-mode frame logic |
| `Sources/GitPad/NoteStore.swift` | File listing, load/save, debounced autosave, trash-delete |
| `Sources/GitPad/GitSync.swift` | All git operations via `Process` on `/usr/bin/git` |
| `Sources/GitPad/EditorView.swift` | SwiftUI sidebar + NSTextView editor with MD highlighting |

- **Build**: `./build.sh` → wraps the release binary into `GitPad.app` (Info.plist sets `LSUIElement` for menu-bar-only), ad-hoc codesigned.
- **Test**: `./test_gitsync.sh` → drives the real binary through a bare remote + two clones with a deliberate same-line conflict; asserts silent resolution and no data loss.

## Hosted / Database
- **No server, no database.** Storage is the filesystem; sync backend is any git remote the user points it at (GitHub private repo, self-hosted, etc.).
- Auth is the user's existing SSH setup (`~/.ssh`); the app stores nothing (`GIT_TERMINAL_PROMPT=0` prevents hangs when auth is missing).
- Remote URL lives in the notes repo's own git config — set once via menu bar → *Set Remote…*.

## Done
- [x] App shell: menu-bar item, global hotkey, floating panel
- [x] Notes: create / edit / autosave / trash-delete, first-line titles
- [x] Markdown syntax highlighting
- [x] Compact mode
- [x] Git sync loop with automatic conflict resolution (tested end-to-end)
- [x] Build script producing a signed .app; installed to /Applications

## Issues / Challenges
- **Fresh-app indexing**: until copied to /Applications, Spotlight/automation tools don't know the app exists.
- **Rebase vs merge semantics**: `-X ours/theirs` swap meaning during rebase; sync uses plain merge (clean-first, then `-X ours` with conflict copies) to keep semantics predictable.
- **SwiftUI TextEditor is too limited** for highlighting → wrapped NSTextView instead.
- **⌥Space** may collide with other launchers (e.g. Raycast/Alfred custom binds); hotkey is hardcoded for now.
- Ad-hoc signing only — fine locally, would need Developer ID for distribution.

## Roadmap (add when needed — YAGNI until then)
- Search across notes
- Configurable hotkey + notes folder location
- Rendered markdown preview
- Conflict-copy cleanup helper (merge a conflict copy back, delete it)
- Launch at login
- Images/attachments
- Developer ID signing + notarization for sharing

## Usage
1. `./build.sh`, app is in `/Applications/GitPad.app` (auto-launches nothing; open once).
2. **⌥Space** → panel. Type. It saves itself.
3. Menu bar → *Set Remote…* → paste a private repo SSH URL. Sync is automatic from then on.
