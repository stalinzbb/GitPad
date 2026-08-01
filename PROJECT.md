# GitPad — internal working notes

_User-facing docs are the source of truth: see [README.md](README.md) (vision,
features, architecture, shortcuts), [ROADMAP.md](ROADMAP.md) (what's next), and
[SECURITY.md](SECURITY.md) (threat model). This file is scratch: decisions,
gotchas, and things that would surprise a contributor._

## Design decisions that aren't obvious from the code

- **Themes flip window appearance, not a color wash.** Each `Theme` sets `panel.appearance` (`.aqua` / `.darkAqua` / follow-system) via the `store.applyAppearance` callback wired in `AppDelegate` — same pattern as `onHide`. That's what makes native controls (text fields, lists, forms, popovers) render correctly per theme instead of all looking identical. `editorTint` is only a subtle (~0.2 opacity) layer over the material; the appearance switch does the real work.
- **One NavBar for every screen** (`NavBar(left:center:right:)` in `EditorView.swift`). `chevron.left` always means "back one level"; `xmark` only on Capture (home has nowhere to go back to). Esc mirrors the clicks — see `PanelWindow.cancelOperation`.
- **Pill mode replaced compact mode.** `store.pill` + `PanelWindow.applyPill(_:)` save/restore the expanded frame and animate the corner radius to height/2. Compact mode (and its 12pt font path and menu item) was deleted — one mode fewer.
- **The panel needs a real surface, not just a tint.** The window blends `.behindWindow`
  with a clear background, and `labelColor` resolves from the window's *appearance*, not
  from what's actually behind it. A low-opacity tint therefore can't guarantee contrast —
  over a white backdrop the material washes out while the text color stays put. `Theme.surface`
  + `PanelSurface.opacity` (~0.92, 1.0 under Reduce Transparency) paint a real background so
  text always sits on a known color. Don't reintroduce a low-opacity wash. Note System's
  surface must stay `windowBackgroundColor` (dynamic) — it has no hex of its own.
- **Chrome alignment comes from containers, not glyphs.** SF Symbols have different optical
  centers, so framing each one identically is not enough — `square.and.pencil` next to
  `xmark` reads as misaligned no matter the box. `ChromeIcon` gives every control the same
  28×28 container/weight/hover, and `ChromeGlyph` keeps the set symmetric. Adding a chrome
  button means adding a `ChromeGlyph` entry, not a bare `Image(systemName:)`.
- **Editor leading lives in the highlighter's `base` attributes.** `highlight()` calls
  `storage.setAttributes(base:range:)`, which *replaces* every attribute on the range. A
  paragraph style set only via `defaultParagraphStyle` gets wiped on the first keystroke,
  so `Coordinator.paragraphStyle` is included in `base` too.
- **Delete = Trash + Undo, deliberately no confirmation.** `delete()` trashes the file
  (already recoverable) and records the restore URL, so `undoDelete()` can put it back with
  its pin. A modal on every delete taxes the intentional case and trains click-through; the
  actual risk is an accidental ⌘⌫ (which shadows delete-to-line-start in the editor), and
  undo covers exactly that. There is deliberately **no Archive folder** — folders + "Move to"
  already do that job. The folder-delete alert stays: it touches many notes at once.
- **Sync never blocks writing.** `GitSync.sync` does a clean merge first (with `--allow-unrelated-histories`, since a repo created with a README has history unrelated to our fresh `init`), then falls back to conflict copies + `-X ours`. See `GitSync.swift` comments.
- **List rendering is a display pipeline over untouched CommonMark.** Disk keeps `- ` bullets
  and `1. 2. 3.` ordinals at every depth. The editor clears the source marker's color and tags
  it with `markerKey`; `DividerLayoutManager` draws the display marker (• ◦ ▪ / `1.` `a.` `i.`
  by depth) right-aligned to the source marker's trailing edge, so caret/content positions
  never move even though `iii.` is wider than `3.`. Hanging indents come from per-paragraph
  styles built in `applyListLayout` (cached per depth+prefix width). Ordered lists renumber in
  a deferred pass (`renumberListBlock`, pure logic in `ListLogic.renumber`) that runs from
  `didProcessEditing` — so Enter/Tab/Backspace/paste/undo all renumber without per-command code.
- **`typingAttributes` are set explicitly** (from paragraph context, in `refreshTypingAttributes`).
  NSTextView otherwise derives them from the character before the caret — right after a hidden
  `# ` marker that's `clear` + 0.1pt, which made the first typed character invisible for a frame.

## Gotchas / known issues

- **Fresh-app indexing**: until copied to `/Applications`, Spotlight/automation don't know the app exists.
- **Rebase vs merge**: `-X ours/theirs` swap meaning under rebase; sync uses plain merge deliberately to keep semantics predictable.
- **SwiftUI `TextEditor`** is too limited for highlighting → wrapped `NSTextView` (`MarkdownTextView`).
- **⌥Space** may collide with other launchers (Raycast/Alfred); it's now rebindable in Settings → Global Hotkey. The binding is swapped via Carbon `Unregister`/`Register` (see `Hotkey.apply`); the shared event handler is installed once so re-registering never double-fires. On collision (`eventHotKeyExistsErr`) the old binding is restored and the recorder shows "already in use".
- **Ad-hoc signing** with Hardened Runtime — fine locally; distribution needs Developer ID + notarization.
- **`unzip` silently breaks a signed bundle.** It drops the extended attributes the signature seals over, so a perfectly good release then fails `codesign --verify` with "a sealed resource is missing or invalid" — a message that reads like tampering. `Updater` expands with `/usr/bin/ditto -x -k`, which preserves them. Same trap applies to any by-hand check of a release zip: extract with `ditto` or you'll be debugging a signature that was never broken.
- **`GET /releases/latest` 404s for this repo.** Every GitPad release so far is marked *pre-release*, and that endpoint only ever returns a full release. `Updater` lists `?per_page=5` and takes the first non-draft entry, which works either way. Tags are v-prefixed (`v0.9.3`), assets are not (`GitPad-0.9.3.zip`) — the updater strips the `v` before matching.
- **Replacing the running app** uses move-aside (rename the live bundle out of the way, move the new one in), not `replaceItemAt`. Renaming a running bundle is safe — the executable keeps running from the renamed inode — and both renames are same-volume, hence atomic. `Hotkey.stop()` must run before the replacement launches, or the new instance can't register ⌥Space while this one still holds it.
- **The staged-update directory is user-writable**, so `Updater.verifiedStagedApp()` re-runs the *full* signature chain at the moment of use rather than trusting the check done at download time.

## Verify

- `swift build -c release && ./test_gitsync.sh` — the test drives the real binary through a bare remote: same-line conflict resolution and README/unrelated-histories scenarios.
- `./build.sh` → `GitPad.app`, then copy to `/Applications` and relaunch.
