#!/bin/bash
# Two-clone conflict scenario driving the real GitSync code via `GitPad --sync`.
set -euo pipefail
cd "$(dirname "$0")"
BIN=.build/release/GitPad
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

git init --bare -q -b main "$TMP/remote.git"
A="$TMP/a"; B="$TMP/b"
mkdir "$A" "$B"

# machine A creates a note and syncs
echo "# Groceries
- milk" > "$A/list.md"
git -C "$A" init -q -b main
git -C "$A" -c user.name=A -c user.email=a@x config user.name A
git -C "$A" config user.email a@x
git -C "$A" remote add origin "$TMP/remote.git"
"$BIN" --sync "$A"

# machine B clones, both edit the SAME line of the same file
git clone -q "$TMP/remote.git" "$B"
git -C "$B" config user.name B; git -C "$B" config user.email b@x
echo "# Groceries
- milk
- eggs" > "$A/list.md"
echo "# Groceries
- milk
- bread" > "$B/list.md"
"$BIN" --sync "$A"
"$BIN" --sync "$B"   # must resolve the conflict silently

# assertions
[ -z "$(git -C "$B" status --porcelain)" ] || { echo "FAIL: B repo dirty"; exit 1; }
[ ! -d "$B/.git/rebase-merge" ] && [ ! -f "$B/.git/MERGE_HEAD" ] || { echo "FAIL: merge in progress"; exit 1; }
grep -q bread "$B/list.md" || { echo "FAIL: B's edit lost"; exit 1; }
ls "$B"/*conflict*.md >/dev/null 2>&1 || { echo "FAIL: no conflict copy for A's edit"; exit 1; }
grep -q eggs "$B"/*conflict*.md || { echo "FAIL: A's edit not preserved in copy"; exit 1; }

# A syncs again and sees both files, no conflict left
"$BIN" --sync "$A"
grep -q eggs "$A"/*conflict*.md || { echo "FAIL: conflict copy not propagated to A"; exit 1; }
echo "PASS: conflict resolved silently, both edits preserved"
