#!/bin/bash
# End-to-end: play -> pause (immediate) -> resume (replays chunk) -> completion.
set -u
BIN="$(cd "$(dirname "$0")/../plugins/read-aloud/bin" && pwd)/read-aloud"
HOOK="$(cd "$(dirname "$0")/../plugins/read-aloud/scripts" && pwd)/save-response.sh"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
export HOME="$TMP/home"; mkdir -p "$TMP/bin"
export CLAUDE_CODE_SESSION_ID=SID
DIR="$HOME/.claude/read-aloud/SID"

# Stub `say`: log each chunk, linger so pause can interrupt mid-playback.
cat > "$TMP/bin/say" <<'EOF'
#!/bin/bash
[ "$1" = "--" ] && shift
echo "$*" >> "$HOME/.claude/read-aloud/SID/say.log"
perl -e 'select(undef,undef,undef,0.3)'
EOF
chmod +x "$TMP/bin/say"; export PATH="$TMP/bin:$PATH"
waitfor() { for _ in $(seq 1 200); do eval "$1" && return 0; perl -e 'select(undef,undef,undef,0.05)'; done; return 1; }

# Seed a 5-sentence response via the hook.
printf '{"session_id":"SID","last_assistant_message":"One. Two. Three. Four. Five."}' \
  | bash "$HOOK"

# play
out="$(bash "$BIN" play)"; [ "$out" = "🔊 Speaking…" ] || { echo "FAIL: play said '$out'"; exit 1; }
waitfor '[ -s "$DIR/say.log" ]' || { echo "FAIL: nothing spoken"; exit 1; }

# pause while a chunk is playing
spid_before="$(cat "$DIR/say.pid")"
out="$(bash "$BIN" pause)"; [ "$out" = "⏸ Paused." ] || { echo "FAIL: pause said '$out'"; exit 1; }
[ "$(cat "$DIR/status")" = "paused" ] || { echo "FAIL: status not paused"; exit 1; }
kill -0 "$spid_before" 2>/dev/null && { echo "FAIL: say pid $spid_before still alive after pause (not killed immediately)"; exit 1; }
paused_idx="$(cat "$DIR/index")"
lines_at_pause="$(grep -c '' "$DIR/say.log")"
# progress must stop: line count stable over a short window
perl -e 'select(undef,undef,undef,0.5)'
[ "$(grep -c '' "$DIR/say.log")" = "$lines_at_pause" ] || { echo "FAIL: kept speaking after pause"; exit 1; }

# resume -> must replay the paused chunk, then finish
out="$(bash "$BIN" resume)"; [ "$out" = "▶️ Resumed." ] || { echo "FAIL: resume said '$out'"; exit 1; }
waitfor '[ "$(cat "$DIR/status" 2>/dev/null)" = "done" ]' || { echo "FAIL: never finished"; exit 1; }

# the chunk at paused_idx (1-based line paused_idx+1) appears >= 2 times (replay)
chunk="$(sed -n "$((paused_idx+1))p" "$DIR/playlist.txt")"
count="$(grep -Fxc "$chunk" "$DIR/say.log")"
[ "$count" -ge 2 ] || { echo "FAIL: paused chunk '$chunk' not replayed (count=$count)"; exit 1; }
# all five spoken
grep -Fxq "One." "$DIR/say.log" && grep -Fxq "Five." "$DIR/say.log" || { echo "FAIL: missing chunks"; exit 1; }

# resume again when done -> Nothing to resume.
out="$(bash "$BIN" resume)"; [ "$out" = "Nothing to resume." ] || { echo "FAIL: resume-when-done said '$out'"; exit 1; }

echo "PASS: play/pause/resume replays paused sentence and completes"

# --- Bullet/dash chunk coverage: a chunk like "- bullet one." must be spoken
# via `say --`, not swallowed as unrecognized `say` options. Fresh session.
export CLAUDE_CODE_SESSION_ID=SID2
DIR2="$HOME/.claude/read-aloud/SID2"
: > "$DIR/say.log"
printf '{"session_id":"SID2","last_assistant_message":"- bullet one. - bullet two."}' \
  | bash "$HOOK"
out="$(bash "$BIN" play)"; [ "$out" = "🔊 Speaking…" ] || { echo "FAIL: play(SID2) said '$out'"; exit 1; }
waitfor '[ "$(cat "$DIR2/status" 2>/dev/null)" = "done" ]' || { echo "FAIL: SID2 never reached done"; exit 1; }
grep -Fxq -- "- bullet one." "$DIR/say.log" || { echo "FAIL: dash chunk 'bullet one' not spoken: $(cat "$DIR/say.log")"; exit 1; }
grep -Fxq -- "- bullet two." "$DIR/say.log" || { echo "FAIL: dash chunk 'bullet two' not spoken: $(cat "$DIR/say.log")"; exit 1; }

echo "PASS: dash/bullet chunks are spoken via say --"

# --- /stop coverage: stop ends playback immediately and reaps the player loop.
export CLAUDE_CODE_SESSION_ID=SID3
DIR3="$HOME/.claude/read-aloud/SID3"
: > "$DIR/say.log"
printf '{"session_id":"SID3","last_assistant_message":"One. Two. Three. Four. Five."}' \
  | bash "$HOOK"
out="$(bash "$BIN" play)"; [ "$out" = "🔊 Speaking…" ] || { echo "FAIL: play(SID3) said '$out'"; exit 1; }
waitfor '[ -s "$DIR/say.log" ]' || { echo "FAIL: SID3 nothing spoken before stop"; exit 1; }
out="$(bash "$BIN" stop)"; [ "$out" = "⏹ Stopped." ] || { echo "FAIL: stop said '$out'"; exit 1; }
[ "$(cat "$DIR3/status")" = "stopped" ] || { echo "FAIL: status not stopped after stop"; exit 1; }
player_pid="$(cat "$DIR3/player.pid" 2>/dev/null)"
waitfor '! kill -0 "$player_pid" 2>/dev/null' || { echo "FAIL: player loop (pid $player_pid) still alive after stop"; exit 1; }

echo "PASS: stop ends playback and reaps the player loop"
