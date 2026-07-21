#!/bin/bash
# lifecycle.test.sh — real `claude plugin` install/uninstall lifecycle against
# the published GitHub marketplace, fully sandboxed. Skips (exit 0) when the
# claude CLI or GitHub are unavailable; hard-fails on any post-precondition
# assertion. Isolation: HOME + CLAUDE_CONFIG_DIR are redirected into a temp
# sandbox so the real ~/.claude is never touched.
set -u

REPO_GH="ricardorqr/read-aloud-plugin"
GH_URL="https://github.com/${REPO_GH}.git"
PLUGIN_ID="read-aloud@read-aloud-marketplace"

# --- Preconditions: skip (do not fail) when external deps are unavailable ---
command -v claude >/dev/null 2>&1 || { echo "SKIP: claude CLI not on PATH"; exit 0; }
git ls-remote "$GH_URL" >/dev/null 2>&1 || { echo "SKIP: GitHub unreachable ($GH_URL)"; exit 0; }

# --- Isolation: sandbox HOME + claude config dir, always cleaned up ---------
SANDBOX="$(mktemp -d)"; trap 'rm -rf "$SANDBOX"' EXIT
export HOME="$SANDBOX/home"; mkdir -p "$HOME"
export CLAUDE_CONFIG_DIR="$HOME/.claude"

# --- Helpers ----------------------------------------------------------------
fail() { echo "FAIL: $*"; exit 1; }
waitfor() { for _ in $(seq 1 200); do eval "$1" && return 0; perl -e 'select(undef,undef,undef,0.05)'; done; return 1; }

# --- Install from the published GitHub marketplace (the "new version") -------
claude plugin marketplace add "$REPO_GH" </dev/null >/dev/null 2>&1 \
  || { echo "SKIP: marketplace add failed (network?)"; exit 0; }
claude plugin install "$PLUGIN_ID" </dev/null >/dev/null 2>&1 \
  || fail "plugin install failed"

# --- Presence assertions: all commands, the hook, the dispatcher + scripts ---
claude plugin list 2>/dev/null | grep -q "read-aloud@read-aloud-marketplace" \
  || fail "plugin not listed after install"

CACHE="$(find "$CLAUDE_CONFIG_DIR/plugins/cache/read-aloud-marketplace/read-aloud" \
  -mindepth 1 -maxdepth 1 -type d 2>/dev/null | head -1)"
[ -n "$CACHE" ] && [ -d "$CACHE" ] || fail "cache dir not found after install"

for c in say play pause resume continue stop quiet; do
  [ -f "$CACHE/commands/$c.md" ] || fail "missing command file: commands/$c.md"
done

[ -f "$CACHE/hooks/hooks.json" ] || fail "missing hooks/hooks.json"
grep -q '"Stop"' "$CACHE/hooks/hooks.json" || fail "hooks.json does not register a Stop hook"
grep -q 'save-response.sh' "$CACHE/hooks/hooks.json" || fail "Stop hook does not call save-response.sh"

[ -x "$CACHE/bin/read-aloud" ] || fail "bin/read-aloud missing or not executable"
for s in save-response.sh split-sentences.sh player.sh; do
  [ -f "$CACHE/scripts/$s" ] || fail "missing script: scripts/$s"
done

echo "PASS: install exposes all 7 commands, the Stop hook, and the dispatcher+scripts"

# --- Features actually work: run the INSTALLED dispatcher with a stubbed say -
mkdir -p "$SANDBOX/bin"
cat > "$SANDBOX/bin/say" <<'EOF'
#!/bin/bash
[ "$1" = "--" ] && shift
echo "$*" >> "$HOME/.claude/read-aloud/LIFECYCLE/say.log"
perl -e 'select(undef,undef,undef,0.3)'
EOF
chmod +x "$SANDBOX/bin/say"; export PATH="$SANDBOX/bin:$PATH"
export CLAUDE_CODE_SESSION_ID=LIFECYCLE
BIN="$CACHE/bin/read-aloud"
DIR="$HOME/.claude/read-aloud/LIFECYCLE"

# Empty states first (no response.txt yet).
out="$(bash "$BIN" play)";   [ "$out" = "Nothing to speak yet." ] || fail "empty play said '$out'"
out="$(bash "$BIN" resume)"; [ "$out" = "Nothing to resume." ]    || fail "idle resume said '$out'"
out="$(bash "$BIN" pause)";  [ "$out" = "Nothing is playing." ]   || fail "idle pause said '$out'"
out="$(bash "$BIN" stop)";   [ "$out" = "Nothing is playing." ]   || fail "idle stop said '$out'"

# Seed a response, then drive play -> pause -> resume -> stop.
mkdir -p "$DIR"; printf 'One. Two. Three. Four. Five.' > "$DIR/response.txt"
out="$(bash "$BIN" play)";   [ "$out" = "🔊 Speaking…" ] || fail "play said '$out'"
waitfor '[ -s "$DIR/say.log" ]' || fail "nothing spoken after play"
out="$(bash "$BIN" pause)";  [ "$out" = "⏸ Paused." ]   || fail "pause said '$out'"
out="$(bash "$BIN" resume)"; [ "$out" = "▶️ Resumed." ] || fail "resume said '$out'"
out="$(bash "$BIN" stop)";   [ "$out" = "⏹ Stopped." ]  || fail "stop said '$out'"

echo "PASS: installed commands produce the correct output strings"
