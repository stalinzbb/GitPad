# Syncing GitPad across Macs

Your notes are plain Markdown files in `~/Documents/GitPad/`, kept in a git repo.
Sync is just git: commit, pull, push. Nothing proprietary, nothing to log into
beyond whatever your git host already uses.

## When GitPad syncs

- ~1 second after you stop typing (the autosave debounce)
- Every 5 minutes
- When your Mac wakes
- When you open the panel (skipped if a sync ran in the last 30 seconds)
- When you pick **Sync Now** from the menu-bar menu or Settings

Syncing never blocks typing — it runs on a background queue, and there is no merge
UI to get stuck in.

## Adding a second Mac

Install GitPad, then point it at the **same** repo (Settings → *Set up sync*, or the
menu bar → *Set Up Sync…*).

If the new Mac hasn't got any real notes yet — only the auto-created daily note and
empty scratch notes — GitPad adopts the remote wholesale: your existing notes appear
and nothing is duplicated. The moment you've typed even one character into a note on
the new Mac, adoption is off and GitPad merges the two sides normally instead.

## Conflicts

A conflict only happens when **both Macs edit the same note between syncs**. GitPad
never blocks and never asks you to resolve a merge mid-thought:

1. This Mac's version stays exactly as you left it.
2. The other Mac's version is saved beside it as
   `<note> (conflict from <device> 2026-07-23 1400).md`.
3. An orange ⚠ appears in the header on every screen until you deal with it.

Nothing is ever discarded automatically. Files that merged cleanly never get a copy —
only genuinely conflicting ones do.

### Resolving

Click the ⚠ (or Settings → Conflicts → *Review conflicts…*). You get both versions
side by side and three choices:

- **Keep Mine** — trash the other Mac's copy.
- **Use Theirs** — replace your note with theirs (the copy is then removed).
- **Keep Both** — rename the copy to `<note> (from <device>).md` so it lives on as a
  normal note.

If you deleted the note on this Mac while the other Mac edited it, the copy has no
counterpart — you get **Keep as Note** or **Discard**.

## Device names

Each Mac commits under its own name (`Host.current().localizedName`), so
`git log` in `~/Documents/GitPad` reads like a history of which Mac wrote what — and
conflict copies can say which Mac they came from.

## When sync stops working

The status dot goes orange and the menu-bar glyph gains a badge (the badge, not the
color, is the real signal). Settings → Sync then names the actual problem and offers
the fix — a rejected SSH key, a changed host key, a missing repo, an HTTPS URL that
needs a login, or just no network.

The most common one, an SSH key GitHub doesn't know, is one click: **Switch to HTTPS
via GitHub CLI** (shown when you're signed in to `gh`). The equivalent by hand:

```bash
cd ~/Documents/GitPad && git remote set-url origin https://github.com/you/notes.git && gh auth setup-git && git push -u origin main
```

Prefer SSH? Add the right key under `Host github.com` in `~/.ssh/config`:

```
Host github.com
  IdentityFile ~/.ssh/id_ed25519_gitpad
```

and register `~/.ssh/id_ed25519_gitpad.pub` at
[github.com/settings/ssh/new](https://github.com/settings/ssh/new).

If sync has been broken for over a day, GitPad shows a one-line banner above the
editor with a **Fix** link. Running deliberately local-only (no remote at all) never
nags.
