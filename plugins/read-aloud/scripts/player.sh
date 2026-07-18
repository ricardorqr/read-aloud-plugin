#!/bin/bash
# player.sh <dir> <generation> <start_index>
# Detached loop: speak one playlist chunk at a time, honoring status/generation.
DIR="$1"; GEN="$2"; i="$3"

sget() { cat "$DIR/$1" 2>/dev/null; }
sset() { printf '%s' "$2" > "$DIR/$1.tmp" && mv "$DIR/$1.tmp" "$DIR/$1"; }

sset player.pid "$$"
total="$(awk 'END{print NR+0}' "$DIR/playlist.txt" 2>/dev/null)"
[ -z "$total" ] && total=0

while :; do
  [ "$(sget status)" = "playing" ] || exit 0
  [ "$(sget generation)" = "$GEN" ] || exit 0
  if [ "$i" -ge "$total" ]; then sset status done; exit 0; fi
  sset index "$i"
  chunk="$(sed -n "$((i+1))p" "$DIR/playlist.txt")"
  say -- "$chunk" &
  spid=$!
  sset say.pid "$spid"
  wait "$spid" 2>/dev/null
  if [ "$(sget status)" = "playing" ] && [ "$(sget generation)" = "$GEN" ]; then
    i=$((i+1))
  else
    exit 0
  fi
done
