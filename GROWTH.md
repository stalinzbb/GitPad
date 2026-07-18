# GROWTH.md — distribution, marketing, analytics, signups

Strategy, not shipped code. Everything here is a decision record + a plan the
maintainer can execute later. The bar is the same as the app itself: no accounts,
no servers you have to run, nothing the user can't inspect or opt out of.

The guiding constraint: **GitPad's pitch is "your files, your git, no cloud."**
Any growth mechanism that quietly adds a cloud dependency contradicts the product.
So each item below is designed to be either static (a page, a DMG) or strictly
opt-in and inspectable.

---

## 1. Distribution pipeline

Goal: a stranger runs one command (or drags one icon) and has a signed, notarized
app that Gatekeeper opens without a scary dialog. No Mac App Store — the sandbox
would break the whole design (git subprocess, `~/.ssh` access, a floating
non-activating panel).

### 1.1 Signing & notarization

Prerequisite: an Apple Developer account ($99/yr) and a **Developer ID Application**
certificate (not "Mac App Store"). This is the only paid dependency of the whole plan.

Replace the ad-hoc `codesign --sign -` in [build.sh](build.sh) with a real identity,
then notarize. Sketch of the added steps:

```bash
# 1. Sign with Developer ID + hardened runtime (already have the runtime flag)
codesign --force --options runtime --timestamp \
  --sign "Developer ID Application: Your Name (TEAMID)" GitPad.app

# 2. Zip and submit to Apple's notary service (blocks until a verdict)
ditto -c -k --keepParent GitPad.app GitPad.zip
xcrun notarytool submit GitPad.zip \
  --keychain-profile "gitpad-notary" --wait     # store creds once with `notarytool store-credentials`

# 3. Staple the ticket so it verifies offline
xcrun stapler staple GitPad.app
```

Keep this behind a flag (`./build.sh --release`) so the everyday dev build stays
ad-hoc and instant. Store the notary credentials with `notarytool store-credentials`
in the keychain — never in the repo, never in an env var committed to CI.

### 1.2 DMG — no third-party tool

`create-dmg` would be the first-ever dependency. Skip it; `hdiutil` ships with macOS:

```bash
# Stage the app + an /Applications symlink, then build a compressed DMG
mkdir -p dmg-stage && cp -R GitPad.app dmg-stage/ && ln -s /Applications dmg-stage/Applications
hdiutil create -volname GitPad -srcfolder dmg-stage -ov -format UDZO GitPad.dmg
codesign --sign "Developer ID Application: …" GitPad.dmg    # sign the DMG too
xcrun stapler staple GitPad.dmg                              # staple after notarizing the app inside
```

A background image + icon layout is polish, not a blocker — a plain DMG with the
app and an Applications alias is enough to ship v1.

### 1.3 GitHub Releases → Homebrew cask

- Tag a release (`v0.9`), attach `GitPad.dmg`, write release notes from
  [CHANGELOG.md](CHANGELOG.md).
- A Homebrew cask is ~15 lines pointing at the release asset URL + its sha256:

  ```ruby
  cask "gitpad" do
    version "0.9"
    sha256 "…"                                   # shasum -a 256 GitPad.dmg
    url "https://github.com/USER/GitPad/releases/download/v#{version}/GitPad.dmg"
    name "GitPad"
    desc "Menu-bar quick-capture notes backed by your own git repo"
    homepage "https://github.com/USER/GitPad"
    app "GitPad.app"
    zap trash: ["~/Documents/GitPad", "~/Library/Preferences/com.stalinzbb.gitpad.plist"]
  end
  ```

- Start it in a personal tap (`USER/homebrew-tap`) → `brew install --cask USER/tap/gitpad`.
  Submit to `homebrew-cask` proper only once there's a stable release cadence; they
  require notarization (which §1.1 gives) and some download history.

### 1.4 Updates — decide, don't drift

**Recommendation: ship a zero-dependency "Check for Updates" first.** ~30 lines:
`URLSession` GETs the GitHub Releases API (`/repos/USER/GitPad/releases/latest`),
compares `tag_name` against `CFBundleShortVersionString`, and if newer opens the
release page in the browser. No auto-download, no privileged installer, no new
dependency. A status-menu item and/or a Settings button.

**Sparkle only if manual updates measurably lose users.** Sparkle is excellent, but
it would be the *first third-party dependency in the project* and it runs a signed
auto-update feed you have to maintain. That's a real cost against the "zero deps"
identity — pay it only with evidence (e.g. telemetry showing most installs stuck on
old versions), not preemptively. If adopted, it needs its own EdDSA signing key and
an appcast XML feed published alongside releases.

---

## 2. Landing page

One page, one offer, on GitHub Pages (free, static, no server). When you build it,
load the `landing-page` skill. Structure:

- **Hero** — the tagline ("Notes at the speed of thought. Your files, your git, no
  cloud.") + a short screen recording: press the hotkey, panel drops, type, it's a
  file. Show, don't describe.
- **Three feature blocks** — *Capture* (hotkey → panel → done), *Plain Markdown*
  (it's just `.md` files you own), *Your git* (sync is a repo you point at, not our
  cloud).
- **Theme strip** — a row of screenshots across System / Sepia / Nord / Dracula /
  Solarized. (These are the screenshots the README `## Screenshots` section also wants.)
- **Install** — the DMG download button + `brew install --cask gitpad`, side by side.
- **FAQ** — reuse the README's: why git, why not Electron, where are my notes, is it
  really no-account (yes).
- **GitHub link** — it's open source; make the repo one click away.

**No trackers → no cookie banner.** A static page with no analytics script needs no
consent gate, which is itself on-brand. If you later want page analytics, use a
server-log or privacy-first counter that sets no cookies (see §3's ethos) rather
than a script that forces a banner.

---

## 3. Opt-in analytics design (off by default, fully inspectable)

Decided with the maintainer: **off by default, anonymous, opt-in only, and the user
can read the exact payload before enabling.** This section is the design; it is not
implemented yet, and the [ROADMAP.md](ROADMAP.md) non-goal is amended to say so out loud.

### What it may collect — the whole list, nothing more

At most ~4 events, no free text, no note content, no filenames, no paths:

| Event | Fields | Why |
|-------|--------|-----|
| `launch` | app version, macOS major version | version adoption; which OSes to support |
| `sync_configured` | bool | do people actually use git sync, or just local? |
| `theme` | theme id (e.g. "Nord") | which themes earn their keep |
| `hotkey_customized` | bool | is ⌥Space colliding often enough to matter? |

- **Install id:** a random UUID generated locally, regenerable, stored in prefs.
  Not derived from hardware, not stable across a reinstall, not tied to any identity.
- **No content, ever.** No note text, no titles, no file names, no remote URLs, no IP
  logging beyond what any HTTP request incurs (use an endpoint that doesn't log IPs).

### How it stays honest

- A single Settings toggle, **unchecked by default.** Next to it: a
  **"See exactly what's sent"** button that shows the literal JSON that would be
  posted — the same struct that gets serialized, not a hand-written approximation.
- Onboarding mentions it in **one plain sentence, no pre-checked box.** Declining
  changes nothing about how the app works.
- The payload builder is one small pure function so the "see what's sent" view and
  the actual sender call the *same* code — they can't drift.

### Endpoint

Anything that accepts a POST and doesn't log IPs: a self-hosted Plausible/Umami
event, a tiny serverless function writing to a table, or even a static counter.
Keep it dumb. This is the one place the app would touch a server you run — which is
exactly why it's opt-in and inspectable, and why it's not in the app yet.

---

## 4. Optional release-updates email

**A single Settings field, not an account.** Copy: "Email me when a new version ships
— nothing else, unsubscribe anytime." One text field + a Subscribe button.

- Posts the email to a minimal list endpoint (Buttondown, Listmonk, a serverless
  function — maintainer's call). Not stored in the app, not tied to notes, not a login.
- **Never a modal, never a gate.** It sits in Settings for people who want it and is
  invisible to everyone else. No "sign up to continue," no nag.
- Confirm-opt-in (double opt-in) so a typo'd address doesn't get mailed. Unsubscribe
  link in every send. That's the whole feature.

This is deliberately the weakest possible "signup": no password, no profile, no
server-side state the app depends on. Delete the field tomorrow and nothing breaks.

---

## Summary — what actually gets built, and when

| Now (this repo) | Later (has a plan above) |
|-----------------|--------------------------|
| Code polish, hotkey, motion, URL scheme, pinning (done) | Developer ID + notarization in build.sh |
| This doc + amended ROADMAP non-goals | DMG via hdiutil, GitHub release, Homebrew cask |
| README `## Screenshots` placeholder | Landing page (GitHub Pages) |
| — | "Check for Updates" (zero-dep); Sparkle only if evidence demands |
| — | Opt-in analytics (off by default, inspectable) |
| — | Optional release-updates email field |

Nothing in the "Later" column ships without keeping the core promise: no required
account, no required server, nothing sent without an explicit yes you can inspect first.
