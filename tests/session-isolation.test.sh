#!/bin/bash
# Two sessions must not clobber each other's saved response. Sandboxed HOME.
set -u
HOOK="$(cd "$(dirname "$0")/../plugins/read-aloud/scripts" && pwd)/save-response.sh"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
export HOME="$TMP/home"; mkdir -p "$HOME/.claude"

save_turn() { # <session_id> <message>
  printf '{"session_id":"%s","last_assistant_message":"%s"}' "$1" "$2" \
    | CLAUDE_CODE_SESSION_ID="$1" bash "$HOOK"
}
save_turn AAA "Response from session A"
save_turn BBB "Response from session B"

a="$(cat "$HOME/.claude/read-aloud/AAA/response.txt" 2>/dev/null || true)"
b="$(cat "$HOME/.claude/read-aloud/BBB/response.txt" 2>/dev/null || true)"
if [ "$a" = "Response from session A" ] && [ "$b" = "Response from session B" ]; then
  echo "PASS: each session kept its own response"
  exit 0
else
  echo "FAIL: A='$a' B='$b'"
  exit 1
fi
