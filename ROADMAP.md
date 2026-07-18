# Roadmap

**The goal:** GitPad should be productive, fast, accessible, scalable, usable, and
powerful — but never complicated. There is one obvious way to do everything, and
nothing that needs explaining. Every item below earns its place against that bar
or it doesn't ship.

## Now — quality

- [x] **Theming v2** — appearance-driven themes (each flips the whole window light/dark so every control adapts), live swatch picker.
- [x] **Navigation v2** — one NavBar on every screen; chevron.left always means back, xmark only on Capture, Esc mirrors the clicks.
- [ ] Conflict-resolution UX polish (inline diff when comparing copies).
- [ ] Keyboard-shortcut customization (⌥Space collides with some launchers).

## Next — power, still lazy

- [ ] Full-text search hotkey.
- [ ] `[[note linking]]` + backlinks.
- [ ] Note templates.
- [ ] `gitpad://new?text=` URL scheme + Shortcuts.app integration.
- [ ] Clipboard quick-capture.
- [ ] Pinned notes.

## Later — reach

- [ ] Optional end-to-end encryption of the repo (age / git-crypt).
- [ ] CLI companion (`gitpad new "…"`).
- [ ] Spotlight importer.
- [ ] Launch at login.
- [ ] Sparkle auto-updates.
- [ ] Homebrew cask.
- [ ] Localization.

## Non-goals

Accounts. Servers. Telemetry. Databases. Electron. Subscriptions. If a feature
needs any of these, it's not GitPad.
