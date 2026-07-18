# CLAUDE.md

Guidance for AI coding agents working in this repo. Human docs are the source of
truth — [README.md](README.md) (vision/features), [PROJECT.md](PROJECT.md)
(non-obvious decisions & gotchas), [ROADMAP.md](ROADMAP.md), [SECURITY.md](SECURITY.md),
[GROWTH.md](GROWTH.md). This file is the fast map.

## Build & test

- **Build:** `./build.sh` → `GitPad.app` (SwiftPM release build + ad-hoc codesign).
- **Test:** `./test_gitsync.sh` — drives the real binary (`GitPad --sync <dir>`) through a
  bare remote: same-line conflicts, README/unrelated-histories, offline. Run after any
  change near `GitSync.sync` or `NoteStore` save/refresh.
- **Quick compile:** `swift build -c release`.

## Source map (7 files, `Sources/GitPad/`)

| File | Role |
|------|------|
| `main.swift` | Entry point + `--sync <dir>` CLI mode for tests |
| `GitPadApp.swift` | AppDelegate: status item, main-menu "Note" shortcuts, global hotkey, sync scheduling, URL scheme |
| `PanelWindow.swift` | Floating borderless NSPanel + pill collapse/expand frames |
| `NoteStore.swift` | `ObservableObject`: file listing, load/save, debounced autosave, folders, search index, pinning |
| `GitSync.swift` | Every git op via `Process` on `/usr/bin/git` |
| `EditorView.swift` | All SwiftUI: theme tokens, NavBar chrome, screens, NSTextView markdown editor |
| `OnboardingView.swift` | First-run walkthrough + reusable git-setup guide |

## Invariants — do not break

- **Zero third-party dependencies.** Swift + SwiftUI/AppKit only. A new dependency is a
  last resort that needs its own justification (see the "ladder" in README Contributing).
- **Git only via fixed argument arrays**, never shell strings — user input (titles, remote
  URLs) goes straight to `execve` and can't inject. See `GitSync.exec` and its comment.
- **Notes stay plain Markdown** in `~/Documents/GitPad/`. The editor shows ☐/☑ glyphs;
  `NoteStore.to/fromMarkdown` converts to/from `- [ ]` on disk. No proprietary format,
  no frontmatter, no sidecar index files.
- **Sync never blocks writing** and never shows a merge UI — clean merge first, then
  conflict copies + `-X ours`. Keep it that way.
- **Keyboard shortcuts live in the main-menu "Note" submenu** (`GitPadApp.swift`), so they
  route from every screen. Don't reintroduce zero-opacity SwiftUI `.keyboardShortcut` buttons.
- **LSUIElement app** (`.accessory`): no Dock icon, no visible menu bar. The main menu
  exists only to route key equivalents; `autoenablesItems = false` on the Note submenu.
