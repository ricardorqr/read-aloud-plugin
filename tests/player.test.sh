#!/bin/bash
set -u
PLAYER="$(cd "$(dirname "$0")/../plugins/read-aloud/scripts" && pwd)/player.sh"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
export HOME="$TMP/home"; mkdir -p "$TMP/bin"
DIR="$HOME/.claude/read-aloud/SID"; mkdir -p "$DIR"

# Stub `say`: log each spoken chunk, then linger briefly.
cat > "$TMP/bin/say" <<'EOF'
#!/bin/bash
echo "$*" >> "$HOME/.claude/read-aloud/SID/say.log"
perl -e 'select(undef,undef,undef,0.15)'
EOF
chmod +x "$TMP/bin/say"; export PATH="$TMP/bin:$PATH"
sset() { printf '%s' "$2" > "$DIR/$1.tmp" && mv "$DIR/$1.tmp" "$DIR/$1"; }
waitfor() { for _ in $(seq 1 200); do eval "$1" && return 0; perl -e 'select(undef,undef,undef,0.05)'; done; return 1; }

printf 'One.\nTwo.\nThree.\n' > "$DIR/playlist.txt"
sset generation 1; sset status playing

# Full play-through from index 0.
bash "$PLAYER" "$DIR" 1 0 &
waitfor '[ "$(cat "$DIR/status" 2>/dev/null)" = "done" ]' || { echo "FAIL: never reached done"; exit 1; }
log="$(cat "$DIR/say.log")"
[ "$(printf '%s\n' "$log" | grep -c '')" = "3" ] || { echo "FAIL: expected 3 chunks, got: $log"; exit 1; }
[ "$(printf '%s\n' "$log" | sed -n 1p)" = "One." ] || { echo "FAIL: wrong order: $log"; exit 1; }

# Stale generation: player must not speak.
: > "$DIR/say.log"; sset status playing
bash "$PLAYER" "$DIR" 99 0   # generation arg 99 != current 1
[ ! -s "$DIR/say.log" ] || { echo "FAIL: stale-generation player spoke: $(cat "$DIR/say.log")"; exit 1; }

echo "PASS: player advances, stops at done, honors generation"
