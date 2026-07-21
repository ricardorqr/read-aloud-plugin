#!/bin/bash
# set-version.test.sh — scripts/set-version.sh stamps the release version into
# plugin.json (version) and CITATION.cff (version + date-released), leaving both
# files valid. Backs up and restores both files so the repo is unchanged after.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$ROOT/scripts/set-version.sh"
PJ="$ROOT/plugins/read-aloud/.claude-plugin/plugin.json"
CFF="$ROOT/CITATION.cff"

# Exact-byte backup + guaranteed restore, even on failure.
PJ_BAK="$(mktemp)"; CFF_BAK="$(mktemp)"
cp "$PJ" "$PJ_BAK"; cp "$CFF" "$CFF_BAK"
restore() { cp "$PJ_BAK" "$PJ"; cp "$CFF_BAK" "$CFF"; rm -f "$PJ_BAK" "$CFF_BAK"; }
trap restore EXIT

bash "$SCRIPT" 9.9.9 || { echo "FAIL: set-version.sh exited non-zero"; exit 1; }

grep -q '"version": "9.9.9"' "$PJ" || { echo "FAIL: plugin.json version not stamped: $(grep -i version "$PJ")"; exit 1; }
grep -q 'version: "9.9.9"' "$CFF" || { echo "FAIL: CITATION.cff version not stamped"; exit 1; }
grep -qE 'date-released: "[0-9]{4}-[0-9]{2}-[0-9]{2}"' "$CFF" || { echo "FAIL: CITATION.cff date-released not stamped"; exit 1; }
# cff-version must be untouched (leading-anchored regex must not hit it).
grep -q 'cff-version: 1.2.0' "$CFF" || { echo "FAIL: cff-version was clobbered"; exit 1; }
# plugin.json must remain valid JSON (guarded: only if python3 is present).
if command -v python3 >/dev/null 2>&1; then
  python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$PJ" \
    || { echo "FAIL: plugin.json is not valid JSON after edit"; exit 1; }
fi

echo "PASS: set-version.sh stamps plugin.json + CITATION.cff, structure intact"
