#!/bin/bash
# read-aloud — Stop-hook helper.
# Saves Claude's latest response to a file so the voice commands can replay it,
# BUT skips the plugin's own voice-control confirmations (🔊 / ⏸ / ▶️ / ⏹ and the
# "Nothing to ..." fallbacks) so they never overwrite the real answer.
#
# Reads the hook payload (JSON) on stdin. Requires `jq`; if jq is missing it
# exits quietly so it never breaks a session.

FILE="$HOME/.claude/read-aloud-last-response.txt"

command -v jq >/dev/null 2>&1 || exit 0

msg=$(jq -r '.last_assistant_message // empty')
[ -z "$msg" ] && exit 0

case "$msg" in
  🔊*|⏸*|▶️*|⏹*) exit 0 ;;
  "Nothing to speak"*|"Nothing is playing"*|"Nothing to resume"*) exit 0 ;;
esac

mkdir -p "$(dirname "$FILE")"
printf '%s' "$msg" > "$FILE"
