#!/bin/bash
# Encrypted-vault test: an AES-256 sparse bundle mounted at an arbitrary path behaves as a
# normal notes folder for `GitPad --sync`, and holds only ciphertext once detached.
# Mirrors what Vault.swift does with hdiutil; the Swift glue (Keychain, lock/unlock UI) is a
# manual pass — see PROJECT.md.
set -euo pipefail

cd "$(dirname "$0")"
BIN="$(pwd)/.build/release/GitPad"
[ -x "$BIN" ] || { echo "no binary at $BIN — run swift build -c release first"; exit 1; }

TMP=$(mktemp -d /tmp/gitpad-vault.XXXXXX)
MP="$TMP/notes"       # mountpoint, stands in for ~/Documents/GitPad
BUNDLE="$TMP/Vault.sparsebundle"
REMOTE="$TMP/remote.git"
PASS='correct horse battery staple'
trap 'hdiutil detach "$MP" -quiet 2>/dev/null || true; rm -rf "$TMP"' EXIT

fail() { echo "FAIL: $*"; exit 1; }

# 1. create — passphrase via stdin, byte-exact (no trailing newline)
printf '%s' "$PASS" | hdiutil create -quiet -size 1g -type SPARSEBUNDLE -fs APFS -volname GitPadTest \
    -encryption AES-256 -stdinpass "$BUNDLE" || fail "create"
mkdir -p "$MP"

# 2. a newline-suffixed passphrase must be rejected: proves encryption is on and the
#    passphrase is taken verbatim (the trap Vault.swift's exec(stdin:) avoids)
if printf '%s\n' "$PASS" | hdiutil attach -quiet -stdinpass -nobrowse -mountpoint "$MP" "$BUNDLE" 2>/dev/null; then
    fail "attach succeeded with a wrong (newline-suffixed) passphrase"
fi

# 3. attach onto a 500 dir (the locked state) after chmod 700, exactly like Vault.unlock
chmod 500 "$MP"; chmod 700 "$MP"
printf '%s' "$PASS" | hdiutil attach -quiet -stdinpass -nobrowse -mountpoint "$MP" "$BUNDLE" || fail "attach"
[ "$(stat -f %d "$MP")" != "$(stat -f %d "$TMP")" ] || fail "mountpoint is not a volume"

# 4. git works inside the volume
git init -q --bare "$REMOTE"
git -C "$MP" init -q -b main
git -C "$MP" remote add origin "$REMOTE"
echo "# secret inside the vault" > "$MP/secret.md"
GITPAD_DEVICE_NAME=vault "$BIN" --sync "$MP" || fail "sync inside vault"
git -C "$REMOTE" show main:secret.md | grep -q "inside" || fail "remote lacks secret.md"
[ -z "$(git -C "$MP" status --porcelain)" ] || fail "worktree dirty after sync"

# 5. detach = lock: mountpoint empty and, at 500, unwritable
hdiutil detach "$MP" -quiet || fail "detach"
[ -z "$(ls -A "$MP")" ] || fail "mountpoint not empty after detach"
chmod 500 "$MP"
if (echo x > "$MP/leak.md") 2>/dev/null; then fail "wrote plaintext into the locked mountpoint"; fi

# 6. only ciphertext on disk
if grep -rqa "secret inside the vault" "$BUNDLE"; then fail "plaintext found in the sparse bundle"; fi

# 7. unlock again: repo intact, edits sync, lock again
chmod 700 "$MP"
printf '%s' "$PASS" | hdiutil attach -quiet -stdinpass -nobrowse -mountpoint "$MP" "$BUNDLE" || fail "re-attach"
[ -f "$MP/secret.md" ] || fail "secret.md missing after re-attach"
[ -z "$(git -C "$MP" status --porcelain)" ] || fail "worktree dirty after re-attach"
echo "second line" >> "$MP/secret.md"
GITPAD_DEVICE_NAME=vault "$BIN" --sync "$MP" || fail "second sync"
git -C "$REMOTE" show main:secret.md | grep -q "second line" || fail "remote lacks the edit"
hdiutil detach "$MP" -quiet || fail "final detach"
[ -z "$(ls -A "$MP")" ] || fail "mountpoint not empty after final detach"

echo "PASS"
