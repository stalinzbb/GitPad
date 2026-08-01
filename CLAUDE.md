# CLAUDE.md

Guidance for AI coding agents working in this repo. Human docs are the source of
truth — [README.md](README.md) (vision/features), [PROJECT.md](PROJECT.md)
(non-obvious decisions & gotchas), [ROADMAP.md](ROADMAP.md), [SECURITY.md](SECURITY.md),
[GROWTH.md](GROWTH.md). This file is the fast map.

## Build & test

- **Build:** `./build.sh` → `GitPad.app` (SwiftPM release build + ad-hoc codesign; also
  regenerates `Resources/AppIcon.icns` via `make-icns.sh` → `make-icon.swift` when stale).
- **Test (MCP):** `./test_mcp.sh` — pipes JSON-RPC into the real binary (`GitPad --mcp`)
  against a temp notes repo: handshake, tool list, search folding, todos, history,
  create/append, path traversal, `--exclude`. Run after any change in `MCPServer.swift`
  or to `NoteStore`'s search/daily/title behaviour.
- **Test:** `./test_gitsync.sh` — drives the real binary (`GitPad --sync <dir>`) through a
  bare remote: same-line conflicts, unrelated histories, true-conflict-only copies,
  modify/delete, push retry, new-device adoption (and its negative guard). Run after any
  change near `GitSync.sync` or `NoteStore` save/refresh. `GITPAD_DEVICE_NAME` overrides
  the commit author per invocation.
- **Quick compile:** `swift build -c release`.
- **Run a dev build safely:** every copy shares bundle id `com.stalinzbb.gitpad`, so `open
  GitPad.app` may just activate an installed one. Launch the binary directly, and point it
  at a scratch notes folder: `GITPAD_DIR=/tmp/gitpad-dev ./GitPad.app/Contents/MacOS/GitPad`.
  Without `GITPAD_DIR` a dev build edits `~/Documents/GitPad` and syncs to the real remote.

## Source map (8 files, `Sources/GitPad/`)

| File | Role |
|------|------|
| `main.swift` | Entry point + `--sync <dir>` / `--mcp` CLI modes (both before the AppKit spin-up) |
| `GitPadApp.swift` | AppDelegate: status item, main-menu "Note" shortcuts, global hotkey, sync scheduling, URL scheme |
| `PanelWindow.swift` | Floating borderless NSPanel + pill collapse/expand frames |
| `NoteStore.swift` | `ObservableObject`: file listing, load/save, debounced autosave, folders, search index, pinning |
| `GitSync.swift` | Every git op via `Process` on `/usr/bin/git` |
| `EditorView.swift` | All SwiftUI: theme tokens, NavBar chrome, screens, NSTextView markdown editor |
| `OnboardingView.swift` | First-run walkthrough + reusable git-setup guide |
| `MCPServer.swift` | `--mcp`: hand-rolled JSON-RPC over stdio; every tool goes through `NoteStore`/`GitSync` |

## Invariants — do not break

- **Zero third-party dependencies.** Swift + SwiftUI/AppKit only. A new dependency is a
  last resort that needs its own justification (see the "ladder" in README Contributing).
- **Git only via fixed argument arrays**, never shell strings — user input (titles, remote
  URLs) goes straight to `execve` and can't inject. See `GitSync.exec` and its comment.
- **Notes stay plain Markdown** in `~/Documents/GitPad/`. The editor shows ☐/☑ glyphs;
  `NoteStore.to/fromMarkdown` converts to/from `- [ ]` on disk. No proprietary format,
  no frontmatter, no sidecar index files.
- **`--mcp` is read-only on git** (`log`/`show`) and only ever creates notes or appends to
  today — a second process committing would race the GUI's sync. `--allow-sync` is the one
  opt-in exception. Writes to today's note hand off to the running app over `gitpad://`
  rather than fighting its debounced autosave.
- **Sync never blocks writing** and never shows a merge UI — clean merge first, then
  conflict copies + `-X ours`. Keep it that way.
- **Keyboard shortcuts live in the main-menu "Note" submenu** (`GitPadApp.swift`), so they
  route from every screen. Don't reintroduce zero-opacity SwiftUI `.keyboardShortcut` buttons.
- **LSUIElement app** (`.accessory`): no Dock icon, no visible menu bar. The main menu
  exists only to route key equivalents; `autoenablesItems = false` on the Note submenu.
