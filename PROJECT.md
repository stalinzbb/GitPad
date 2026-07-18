# GitPad — internal working notes

_User-facing docs are the source of truth: see [README.md](README.md) (vision,
features, architecture, shortcuts), [ROADMAP.md](ROADMAP.md) (what's next), and
[SECURITY.md](SECURITY.md) (threat model). This file is scratch: decisions,
gotchas, and things that would surprise a contributor._

## Design decisions that aren't obvious from the code

- **Themes flip window appearance, not a color wash.** Each `Theme` sets `panel.appearance` (`.aqua` / `.darkAqua` / follow-system) via the `store.applyAppearance` callback wired in `AppDelegate` — same pattern as `onHide`. That's what makes native controls (text fields, lists, forms, popovers) render correctly per theme instead of all looking identical. `editorTint` is only a subtle (~0.2 opacity) layer over the material; the appearance switch does the real work.
- **One NavBar for every screen** (`NavBar(left:center:right:)` in `EditorView.swift`). `chevron.left` always means "back one level"; `xmark` only on Capture (home has nowhere to go back to). Esc mirrors the clicks — see `PanelWindow.cancelOperation`.
- **Pill mode replaced compact mode.** `store.pill` + `PanelWindow.applyPill(_:)` save/restore the expanded frame and animate the corner radius to height/2. Compact mode (and its 12pt font path and menu item) was deleted — one mode fewer.
- **Sync never blocks writing.** `GitSync.sync` does a clean merge first (with `--allow-unrelated-histories`, since a repo created with a README has history unrelated to our fresh `init`), then falls back to conflict copies + `-X ours`. See `GitSync.swift` comments.

## Gotchas / known issues

- **Fresh-app indexing**: until copied to `/Applications`, Spotlight/automation don't know the app exists.
- **Rebase vs merge**: `-X ours/theirs` swap meaning under rebase; sync uses plain merge deliberately to keep semantics predictable.
- **SwiftUI `TextEditor`** is too limited for highlighting → wrapped `NSTextView` (`MarkdownTextView`).
- **⌥Space** may collide with other launchers (Raycast/Alfred); hotkey is hardcoded for now (customization is on the roadmap).
- **Ad-hoc signing** with Hardened Runtime — fine locally; distribution needs Developer ID + notarization.

## Verify

- `swift build -c release && ./test_gitsync.sh` — the test drives the real binary through a bare remote: same-line conflict resolution and README/unrelated-histories scenarios.
- `./build.sh` → `GitPad.app`, then copy to `/Applications` and relaunch.
