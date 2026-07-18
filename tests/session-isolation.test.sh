#!/bin/bash
# Reproduces the multi-session bug: /read-aloud:play in one session must speak
# THAT session's last response, not whichever session most recently finished a
# turn. Runs fully sandboxed (temp HOME, stubbed `say`/`killall`) — no audio.
set -u

PLUGIN_DIR="$(cd "$(dirname "$0")/../plugins/read-aloud" && pwd)"
HOOK="$PLUGIN_DIR/scripts/save-response.sh"
BIN="$PLUGIN_DIR/bin/read-aloud"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
export HOME="$TMP/home"
mkdir -p "$HOME/.claude" "$TMP/bin"

# Stub `say`: record the text it was asked to speak (synchronously).
cat > "$TMP/bin/say" <<'EOF'
#!/bin/bash
while [ $# -gt 0 ]; do
  [ "$1" = "-f" ] && { shift; cat "$1" > "$HOME/.claude/say-spoke.txt"; }
  shift
done
EOF
# Stub `killall` so the test never touches a real `say` process.
printf '#!/bin/bash\nexit 0\n' > "$TMP/bin/killall"
chmod +x "$TMP/bin/say" "$TMP/bin/killall"
export PATH="$TMP/bin:$PATH"

save_turn() { # <session_id> <message>
  printf '{"session_id":"%s","last_assistant_message":"%s"}' "$1" "$2" \
    | CLAUDE_CODE_SESSION_ID="$1" bash "$HOOK"
}

# Session A finishes a turn, then session B finishes a turn (B is more recent).
save_turn AAA "Response from session A"
save_turn BBB "Response from session B"

# Session A now runs /read-aloud:play — it must speak A's response.
CLAUDE_CODE_SESSION_ID=AAA bash "$BIN" play >/dev/null 2>&1

# `play` backgrounds `say`; wait (bounded, no `sleep` binary) for the stub output.
for _ in $(seq 1 60); do
  [ -s "$HOME/.claude/say-spoke.txt" ] && break
  perl -e 'select(undef,undef,undef,0.05)'
done

spoke="$(cat "$HOME/.claude/say-spoke.txt" 2>/dev/null || true)"
if [ "$spoke" = "Response from session A" ]; then
  echo "PASS: session A spoke its own response"
  exit 0
else
  echo "FAIL: session A spoke: '${spoke:-<nothing>}' (expected 'Response from session A')"
  exit 1
fi
