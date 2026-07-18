# Security

## Threat model & posture

GitPad is a local-first app with no backend of its own. Its security story is
mostly about what it *doesn't* do.

- **Local plain files.** Notes are Markdown files in `~/Documents/GitPad/`. There is no proprietary store and no hidden state.
- **No telemetry.** No analytics, no crash reporting, no network calls of any kind except the git remote *you* configure.
- **Auth is delegated to the system.** Sync uses your existing SSH setup (`~/.ssh`). GitPad never sees, prompts for, or stores credentials. `GIT_TERMINAL_PROMPT=0` ensures it fails fast rather than hanging on an auth prompt — it can't silently capture one.
- **No arbitrary shell.** Every git call runs `/usr/bin/git` (and the optional `gh`) via `Process` with a **fixed argument array**. No user input — note titles, remote URLs — is ever interpolated into a shell string, so there is no command-injection surface. See the `exec` invariant comment in `GitSync.swift`.
- **No raw error leakage.** Subprocess stderr is never rendered verbatim in the UI; git failures are mapped to friendly messages (`GitSync.friendlyError`).
- **Release hardening.** `build.sh` codesigns with the Hardened Runtime (`--options runtime`). Signed distribution builds should additionally be notarized with a Developer ID.

## Privacy of your notes

Your notes are exactly as private as the git remote you point GitPad at. A
private repo on a host you trust keeps them private; a public repo makes them
public. GitPad adds no layer of its own — that's the point. Optional
repo-level encryption (age / git-crypt) is on the roadmap for those who want
zero trust in the host.

## Reporting a vulnerability

Please report security issues privately by opening a
[GitHub security advisory](../../security/advisories/new) rather than a public
issue. We'll acknowledge and work a fix before any disclosure.
