#!/bin/bash
# read-aloud — Stop-hook helper.
# Saves Claude's latest response to a file so the voice commands can replay it,
# BUT skips the plugin's own voice-control confirmations (🔊 / ⏸ / ▶️ / ⏹ and the
# "Nothing to ..." fallbacks) so they never overwrite the real answer.
#
# Reads the hook payload (JSON) on stdin. Requires `jq`; if jq is missing it
# exits quietly so it never breaks a session.

BASE="$HOME/.claude/read-aloud"

command -v jq >/dev/null 2>&1 || exit 0

payload="$(cat)"
msg=$(printf '%s' "$payload" | jq -r '.last_assistant_message // empty')
[ -z "$msg" ] && exit 0

sid="${CLAUDE_CODE_SESSION_ID:-$(printf '%s' "$payload" | jq -r '.session_id // empty')}"
[ -z "$sid" ] && sid="default"

case "$msg" in
  🔊*|⏸*|▶️*|⏹*) exit 0 ;;
  "Nothing to speak"*|"Nothing is playing"*|"Nothing to resume"*) exit 0 ;;
esac

mkdir -p "$BASE/$sid"
printf '%s' "$msg" > "$BASE/$sid/response.txt"
