#!/bin/bash
# App-level vault test: launches the real binary against a scratch notes dir + scratch bundle
# (GITPAD_DIR + GITPAD_VAULT) and checks the Swift glue that test_vault.sh can't reach —
# Keychain auto-unlock → NoteStore.open, detach on quit, and a locked launch that neither
# crashes nor writes plaintext. Pops the panel briefly; installed GitPad is untouched.
set -euo pipefail
cd "$(dirname "$0")"
BIN="$(pwd)/.build/release/GitPad"
[ -x "$BIN" ] || { echo "no binary at $BIN — run swift build -c release first"; exit 1; }

TMP=$(mktemp -d /tmp/gitpad-vault-app.XXXXXX)
# kill(1) skips applicationShouldTerminate; a real Quit Apple Event to the pid runs it.
cat > "$TMP/quitpid.swift" <<'EOF'
import AppKit
guard let pid = Int32(CommandLine.arguments[1]), let app = NSRunningApplication(processIdentifier: pid) else { exit(2) }
exit(app.terminate() ? 0 : 1)
EOF
swiftc -O "$TMP/quitpid.swift" -o "$TMP/quitpid" 2>/dev/null || { echo "swiftc failed"; exit 1; }
QUITPID="$TMP/quitpid"
NOTES="$TMP/notes"; BUNDLE="$TMP/Vault.sparsebundle"; STAGE="$TMP/stage"
PASS='correct horse battery staple'
SERVICE=com.stalinzbb.gitpad.vault
PID=""
cleanup() {
    [ -n "$PID" ] && kill -9 "$PID" 2>/dev/null || true
    hdiutil detach "$NOTES" -quiet 2>/dev/null || true
    security delete-generic-password -s "$SERVICE" -a vault >/dev/null 2>&1 || true
    chmod -R u+w "$TMP" 2>/dev/null; rm -rf "$TMP"
}
trap cleanup EXIT
fail() { echo "FAIL: $*"; echo "--- app log:"; cat "$TMP/app.log" 2>/dev/null | tail -20; exit 1; }
mounted() { [ "$(stat -f %d "$NOTES")" != "$(stat -f %d "$TMP")" ]; }
launch() {
    GITPAD_DIR="$NOTES" GITPAD_VAULT="$BUNDLE" "$BIN" >>"$TMP/app.log" 2>&1 &
    PID=$!
    sleep 3
    kill -0 "$PID" 2>/dev/null || fail "app exited early"
}
# Keychain read + encrypted APFS attach take a variable 5–15 s; poll rather than sleep.
wait_mounted() {
    for i in $(seq 1 180); do mounted && { echo "mounted after $((i / 2))s"; return 0; }; sleep 0.5; done
    return 1
}
quit() {
    "$QUITPID" "$PID" || fail "quit event refused"
    for _ in $(seq 1 40); do kill -0 "$PID" 2>/dev/null || { PID=""; return; }; sleep 0.5; done
    fail "app did not quit"
}

# Simulate Vault.create's end state: a bundle holding one note, nothing at the mountpoint.
mkdir -p "$NOTES" "$STAGE"
printf '%s' "$PASS" | hdiutil create -quiet -size 1g -type SPARSEBUNDLE -fs APFS -volname GitPad \
    -encryption AES-256 -stdinpass "$BUNDLE"
printf '%s' "$PASS" | hdiutil attach -quiet -stdinpass -nobrowse -mountpoint "$STAGE" "$BUNDLE"
echo "# Seeded note" > "$STAGE/seeded.md"
hdiutil detach "$STAGE" -quiet
chmod 500 "$NOTES"
security delete-generic-password -s "$SERVICE" -a vault >/dev/null 2>&1 || true
# -A: any app may read this test item without a prompt (an ad-hoc dev binary has no stable
# identity for -T). The item is deleted on exit; the real one is written by GitPad itself.
security add-generic-password -s "$SERVICE" -a vault -w "$PASS" -A -U

# 1. Keychain auto-unlock at launch → mounted, seeded note visible, today's daily note created inside
launch
wait_mounted || fail "not mounted within 90s of launch with Keychain passphrase"
sleep 2 # NoteStore.open runs on main after the mount
[ -f "$NOTES/seeded.md" ] || fail "seeded note missing after unlock"
ls "$NOTES/Daily"/*.md >/dev/null 2>&1 || fail "no daily note written inside the vault"

# 2. Quit → applicationShouldTerminate detaches; mountpoint empty and unwritable
quit
mounted && fail "still mounted after quit"
[ -z "$(ls -A "$NOTES")" ] || fail "mountpoint not empty after quit"
if (echo x > "$NOTES/leak.md") 2>/dev/null; then fail "locked mountpoint is writable"; fi

# 3. No Keychain item → launches locked, stays alive, writes nothing
security delete-generic-password -s "$SERVICE" -a vault >/dev/null
launch
sleep 10
mounted && fail "mounted without a passphrase"
[ -z "$(ls -A "$NOTES")" ] || fail "locked launch wrote into the mountpoint"
quit
[ -z "$(ls -A "$NOTES")" ] || fail "quit from locked state wrote into the mountpoint"

echo "PASS"
