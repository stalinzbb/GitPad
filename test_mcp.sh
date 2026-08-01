#!/bin/bash
# Drives the real MCP server (`GitPad --mcp`) over stdio against a throwaway notes dir.
set -euo pipefail
cd "$(dirname "$0")"
BIN=$(cd "$(dirname .build/release/GitPad)" && pwd)/GitPad
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

NOTES="$TMP/notes"
mkdir -p "$NOTES/Daily" "$NOTES/Work" "$NOTES/Private"
TODAY=$(date +%Y-%m-%d)
printf '# Today\n- [x] shipped\n- [ ] write the tests\n' > "$NOTES/Daily/$TODAY.md"
printf '# Groceries\n- milk\n' > "$NOTES/list.md"
printf '# Café notes\nespresso machine\n' > "$NOTES/Work/cafe.md"
printf '# Secrets\n- [ ] never leaks\n' > "$NOTES/Private/secret.md"

git -C "$NOTES" init -q -b main
git -C "$NOTES" config user.name TestMac
git -C "$NOTES" config user.email test@x
git -C "$NOTES" add -A
git -C "$NOTES" commit -qm "seed notes"

# One server run per case: feed it JSON-RPC lines, keep stdout, drop the stderr log.
# $1 = extra server args, rest of stdin = requests.
mcp() {
    local args="$1"; shift
    printf '%s\n' \
        '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}' \
        '{"jsonrpc":"2.0","method":"notifications/initialized"}' \
        "$@" | GITPAD_DIR="$NOTES" $BIN --mcp $args 2>/dev/null
}
fail() { echo "FAIL: $1"; exit 1; }

# 1. handshake + tool discovery
OUT=$(mcp "" '{"jsonrpc":"2.0","id":2,"method":"tools/list"}' '{"jsonrpc":"2.0","id":3,"method":"ping"}')
grep -q '"serverInfo":{"name":"gitpad"' <<<"$OUT" || fail "no serverInfo in initialize: $OUT"
grep -q '"id":1' <<<"$OUT" || fail "initialize not answered"
[ "$(grep -c '"jsonrpc"' <<<"$OUT")" = 3 ] || fail "notification got a response (must be silent)"
for t in list_notes read_note search_notes create_note append_daily read_daily list_open_todos note_history; do
    grep -q "\"name\":\"$t\"" <<<"$OUT" || fail "tool $t missing from tools/list"
done
grep -q 'sync_notes' <<<"$OUT" && fail "sync_notes exposed without --allow-sync"
grep -q 'sync_notes' <<<"$(mcp --allow-sync '{"jsonrpc":"2.0","id":2,"method":"tools/list"}')" \
    || fail "--allow-sync did not expose sync_notes"
echo "PASS: handshake, notifications, tool list"

# 2. search folds diacritics end to end ("cafe" finds "Café notes")
call() { echo "{\"jsonrpc\":\"2.0\",\"id\":9,\"method\":\"tools/call\",\"params\":{\"name\":\"$1\",\"arguments\":$2}}"; }
OUT=$(mcp "" "$(call search_notes '{"query":"cafe"}')")
grep -q 'Work/cafe.md' <<<"$OUT" || fail "search didn't fold Café → cafe: $OUT"
echo "PASS: search_notes reuses the app's folding"

# 3. only unchecked to-dos, with line numbers
OUT=$(mcp "" "$(call list_open_todos '{"folder":"Daily"}')")
grep -q 'write the tests' <<<"$OUT" || fail "open todo not found: $OUT"
grep -q 'shipped' <<<"$OUT" && fail "checked item reported as open"
grep -q '\\"line\\":3' <<<"$OUT" || fail "wrong line number: $OUT"
echo "PASS: list_open_todos"

# 4. history names the committing device
OUT=$(mcp "" "$(call note_history '{"path":"list.md"}')")
grep -q 'TestMac' <<<"$OUT" || fail "note_history lost the device: $OUT"
grep -q 'seed notes' <<<"$OUT" || fail "note_history lost the subject: $OUT"
echo "PASS: note_history"

# 5. read_note round-trips; traversal is refused
OUT=$(mcp "" "$(call read_note '{"path":"Work/cafe.md"}')" "$(call read_note '{"path":"../../etc/hosts"}')")
grep -q 'espresso machine' <<<"$OUT" || fail "read_note returned no content: $OUT"
grep -q 'outside the notes folder' <<<"$OUT" || fail "path traversal not refused: $OUT"
echo "PASS: read_note + traversal guard"

# 6. create_note writes a note-*.md and never overwrites
mcp "" "$(call create_note '{"content":"body text","title":"From Claude","folder":"Work"}')" >/dev/null
mcp "" "$(call create_note '{"content":"second"}')" >/dev/null
ls "$NOTES"/Work/note-*.md >/dev/null 2>&1 || fail "create_note wrote nothing in Work/"
grep -q '# From Claude' "$NOTES"/Work/note-*.md || fail "title not written as a heading"
grep -qx 'second' "$NOTES"/note-*.md || fail "root note not created"
echo "PASS: create_note"

# 7. append_daily with no GUI running writes the file directly, after the heading
OUT=$(mcp "" "$(call append_daily '{"text":"remember the milk"}')")
grep -q '\\"method\\":\\"file\\"' <<<"$OUT" || fail "expected a direct file write: $OUT"
tail -1 "$NOTES/Daily/$TODAY.md" | grep -q 'remember the milk' || fail "append_daily didn't append"
head -1 "$NOTES/Daily/$TODAY.md" | grep -q '# Today' || fail "append_daily clobbered the heading"
grep -q -- '- \[ \] write the tests' "$NOTES/Daily/$TODAY.md" || fail "append_daily mangled the markdown checkboxes"
echo "PASS: append_daily (no GUI)"

# 8. --exclude hides a folder from listing, search and reads
OUT=$(mcp "--exclude Private" \
    "$(call list_notes '{}')" \
    "$(call search_notes '{"query":"never leaks"}')" \
    "$(call list_open_todos '{}')" \
    "$(call read_note '{"path":"Private/secret.md"}')")
grep -q 'Private/secret.md' <<<"$OUT" && fail "excluded folder leaked: $OUT"
grep -q 'never leaks' <<<"$OUT" && fail "excluded note content leaked: $OUT"
grep -q "is excluded" <<<"$OUT" || fail "read_note into an excluded folder should error: $OUT"
grep -q 'Work/cafe.md' <<<"$OUT" || fail "--exclude hid everything else too"
echo "PASS: --exclude"

# 9. read_daily: today by default, one date, or a range
printf '# Old day\nyesteryear entry\n' > "$NOTES/Daily/2020-01-02.md"
OUT=$(mcp "" "$(call read_daily '{}')")
grep -q "$TODAY" <<<"$OUT" || fail "read_daily didn't default to today: $OUT"
grep -q 'yesteryear' <<<"$OUT" && fail "read_daily returned a day outside today"
OUT=$(mcp "" "$(call read_daily '{"date":"2020-01-02"}')")
grep -q 'yesteryear entry' <<<"$OUT" || fail "read_daily by date failed: $OUT"
OUT=$(mcp "" "$(call read_daily '{"from":"2019-01-01","to":"2021-01-01"}')")
grep -q 'yesteryear entry' <<<"$OUT" || fail "read_daily range failed: $OUT"
grep -q "$TODAY" <<<"$OUT" && fail "read_daily range included a day outside it"
echo "PASS: read_daily"

echo "ALL MCP TESTS PASSED"
