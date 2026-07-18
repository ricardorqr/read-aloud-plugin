#!/bin/bash
set -u
SPLIT="$(cd "$(dirname "$0")/../plugins/read-aloud/scripts" && pwd)/split-sentences.sh"
fail=0
check() { # <description> <expected> <actual>
  if [ "$2" = "$3" ]; then echo "ok: $1"; else echo "FAIL: $1"; echo "  expected: [$2]"; echo "  actual:   [$3]"; fail=1; fi
}

# 1) Three sentences -> three lines
out="$(printf 'Hello world. How are you? I am fine!' | bash "$SPLIT")"
check "3 sentences -> 3 lines" "3" "$(printf '%s\n' "$out" | grep -c '')"
check "first sentence" "Hello world." "$(printf '%s\n' "$out" | sed -n 1p)"
check "third sentence" "I am fine!" "$(printf '%s\n' "$out" | sed -n 3p)"

# 2) Newlines split; whitespace collapses; blank lines dropped
out="$(printf 'a    b.\n\n  c.' | bash "$SPLIT")"
check "collapse+drop-blanks -> 2 lines" "2" "$(printf '%s\n' "$out" | grep -c '')"
check "collapsed line" "a b." "$(printf '%s\n' "$out" | sed -n 1p)"

# 3) Long unpunctuated text hard-wraps at <= MAXLEN, no word split
long="$(python3 - <<'PY'
print("word " * 120, end="")
PY
)"
out="$(printf '%s' "$long" | READ_ALOUD_MAXLEN=50 bash "$SPLIT")"
maxlen="$(printf '%s\n' "$out" | awk '{ if (length($0) > m) m = length($0) } END { print m+0 }')"
check "hard-wrap <= 50" "1" "$([ "$maxlen" -le 50 ] && echo 1 || echo 0)"
check "no word split (all tokens are 'word')" "1" "$(printf '%s\n' "$out" | grep -vqE '^(word)( word)*$' && echo 0 || echo 1)"

# 4) Dash/bullet lines survive splitting unchanged (they must reach player.sh
# intact so `say -- "$chunk"` speaks them instead of them being dropped).
out="$(printf -- '- foo.\n- bar.' | bash "$SPLIT")"
check "bullets -> 2 lines" "2" "$(printf '%s\n' "$out" | grep -c '')"
check "first bullet" "- foo." "$(printf '%s\n' "$out" | sed -n 1p)"
check "second bullet" "- bar." "$(printf '%s\n' "$out" | sed -n 2p)"

exit $fail
