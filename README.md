# GitPad

**Notes at the speed of thought. Your files, your git, no cloud.**

GitPad is a menu-bar macOS notes app. Press ⌥Space from anywhere, type, and it
saves itself — as plain Markdown files in a folder you own. Point it at a private
git repo and your notes follow you to every Mac. No accounts, no server, no
subscription, no Electron.

---

## Features

- **Instant capture** — ⌥Space floats a Spotlight-style panel over any app. Esc dismisses.
- **Plain Markdown** — every note is a real `.md` file in `~/Documents/GitPad/`, readable and editable by any other tool.
- **Smart editor** — live markdown styling, slash commands (`/` at the caret), auto-continuing lists and checkboxes, clickable to-dos, a select-text mini toolbar.
- **Daily notes** — ⌥Space always lands on today's note; ⌘N for a fresh one.
- **Library** — search-as-you-type, Pinned / Today / This Week / Earlier, folders. Pin notes and reveal any in Finder from the ⋯ menu.
- **Quick capture from anywhere else** — the `gitpad://` URL scheme (`new?text=`, `daily`, `daily?append=`) drives GitPad from Raycast, Alfred, Shortcuts.app, or a shell script; "Append Clipboard to Daily" and your recent notes live in the status-bar menu.
- **Invisible git sync** — commits, merges and pushes on every save, every 5 minutes, and on wake. Real conflicts resolve automatically with nothing lost (the remote copy is kept alongside).
- **Pill mode** — collapse the whole UI to a draggable 240×40 lozenge that floats over your work; ⌥Space springs it back.
- **Themes** — System, Sepia, Nord, Dracula, Solarized Light. Each flips the whole window's appearance so every control adapts, not just a color wash.
- **Zero dependencies** — Swift + SwiftUI/AppKit, seven source files, built with SwiftPM.

## Screenshots

_Coming soon — the capture panel, the library, and the theme strip. (See [GROWTH.md](GROWTH.md) for the landing-page plan these feed into.)_

## Install

```bash
git clone <this repo> && cd GitPad
./build.sh                 # → GitPad.app
cp -r GitPad.app /Applications/
open /Applications/GitPad.app
```

Requires macOS 13+ and the Xcode command-line tools (`xcode-select --install`).
Homebrew cask is on the roadmap.

## Shortcuts

| Key | Action |
|-----|--------|
| ⌥Space | Toggle the panel (or expand the pill) |
| ⌘N | New note |
| ⌘L | Library ⇄ note |
| ⌘S | Save now (also commits + pushes) |
| ⌘⌫ | Delete current note |
| ⌘M | Minimize to pill |
| ⌘, | Settings |
| Esc | Back one level (clears search first in Library) / hide |

## Sync setup

1. Create a **private** repo (any host). GitPad → Settings → *Set up sync* opens a guide.
2. Paste its SSH URL and hit **Save & Sync** — GitPad checks reachability and syncs, reporting a friendly result inline.
3. That's it. Sync is automatic from then on.

Auth is your existing SSH setup (`~/.ssh`) — GitPad never sees or stores credentials.
If you have the `gh` CLI installed and authenticated, the setup screen offers a
one-click "Create a private repo for me".

## Architecture

Seven files, no third-party dependencies:

| File | Role |
|------|------|
| `main.swift` | Entry point; also a `--sync <dir>` CLI mode used by tests |
| `GitPadApp.swift` | AppDelegate: status item, main-menu shortcuts, global hotkey, sync scheduling |
| `PanelWindow.swift` | The floating NSPanel + pill frame logic |
| `NoteStore.swift` | File listing, load/save, debounced autosave, trash-delete, search index |
| `GitSync.swift` | All git operations via `Process` on `/usr/bin/git` |
| `EditorView.swift` | SwiftUI chrome + NSTextView editor with markdown styling |
| `OnboardingView.swift` | First-run walkthrough + the reusable git-setup guide |

Storage is the filesystem; the sync "backend" is whatever git remote you point it
at. See [SECURITY.md](SECURITY.md) for the threat model and [ROADMAP.md](ROADMAP.md)
for where it's going.

## FAQ

**Why git?** It's the most durable, portable sync anyone already has — versioned,
offline-first, and yours. No new account, no lock-in.

**Why no Electron?** A notes app shouldn't cost 300MB of RAM. Native AppKit is
fast, tiny, and lets the panel float over other apps the way a launcher does.

**Where are my notes?** `~/Documents/GitPad/`. Delete the app and they're still
plain Markdown files.

## Contributing

- **Build:** `./build.sh`. **Test:** `./test_gitsync.sh` (drives the real binary through a bare remote + conflict + unrelated-histories scenarios).
- **Code style — "the ladder":** reuse what's already here before reaching for the standard library; the standard library before new code; new code before a new dependency (there are none, keep it that way). Shortest change that actually works wins.
- Keep git operations shelled out to `/usr/bin/git` with **fixed argument arrays** — never string-interpolated commands.

## License

MIT — see [LICENSE](LICENSE).
