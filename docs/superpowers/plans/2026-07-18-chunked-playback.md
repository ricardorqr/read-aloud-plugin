# Chunked Playback Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace single-process `say` playback with a per-session, sentence-chunked player so `/pause` stops instantly and `/resume` replays the interrupted sentence.

**Architecture:** A detached player loop speaks one sentence at a time and records its position in per-session single-value state files. `bin/read-aloud` builds the playlist (via a pure splitter), writes state, and launches/controls the player by PID. No `SIGSTOP`/`SIGCONT`, no global `killall`.

**Tech Stack:** Bash, macOS `say`, `jq` (hook only), `awk`/`sed` (splitter).

## Global Constraints

- Target plugin version: **1.1.0** (`plugins/read-aloud/.claude-plugin/plugin.json`).
- Commands and their exact output strings are unchanged: `🔊 Speaking…`, `⏸ Paused.`, `▶️ Resumed.`, `⏹ Stopped.`, `Nothing to speak yet.`, `Nothing is playing.`, `Nothing to resume.`
- Per-session id: `CLAUDE_CODE_SESSION_ID` (CLI) or the hook payload's `.session_id`; fall back to `default`.
- Session state root: `$HOME/.claude/read-aloud/<session_id>/`.
- State is one file per field (`status`, `index`, `generation`, `say.pid`, `player.pid`, `playlist.txt`, `response.txt`); writes are atomic (`printf > tmp && mv tmp field`).
- No secrets, no network. Bash only; do not add a Python runtime dependency.
- Every commit message ends with the trailer:
  `Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>`

---

### Task 1: Sentence splitter (pure function)

**Files:**
- Create: `plugins/read-aloud/scripts/split-sentences.sh`
- Test: `tests/split-sentences.test.sh`

**Interfaces:**
- Consumes: nothing.
- Produces: executable `split-sentences.sh` — reads text on **stdin**, writes **one chunk per line** to stdout. Splits on `.!?`+space and on newlines, collapses internal whitespace, drops blank lines, hard-wraps chunks longer than `${READ_ALOUD_MAXLEN:-250}` at word boundaries.

- [ ] **Step 1: Write the failing test**

Create `tests/split-sentences.test.sh`:
```bash
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

exit $fail
```
(`python3` is used only to *generate test input*, not by the plugin.)

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/split-sentences.test.sh`
Expected: FAIL — `split-sentences.sh` does not exist (bash: No such file), non-zero exit.

- [ ] **Step 3: Write minimal implementation**

Create `plugins/read-aloud/scripts/split-sentences.sh`:
```bash
#!/bin/bash
# split-sentences.sh — read text on stdin, emit one speakable chunk per line.
# Chunking is for pause/resume granularity, not prosody. Pure awk (portable on
# BSD/macOS and GNU; avoids sed's non-portable newline-in-replacement): each
# input line is a hard break; within a line, break after sentence-ending
# punctuation followed by whitespace; collapse internal whitespace; drop blank
# chunks; hard-wrap chunks longer than MAXLEN at a word boundary.
MAXLEN="${READ_ALOUD_MAXLEN:-250}"

awk -v max="$MAXLEN" '
function emit(s,   n, w, i, line) {
  gsub(/[[:space:]]+/, " ", s); sub(/^ /, "", s); sub(/ $/, "", s)
  if (s == "") return
  if (length(s) <= max) { print s; return }
  n = split(s, w, " "); line = ""
  for (i = 1; i <= n; i++) {
    if (line == "") line = w[i]
    else if (length(line) + 1 + length(w[i]) <= max) line = line " " w[i]
    else { print line; line = w[i] }
  }
  if (line != "") print line
}
{
  s = $0
  while (match(s, /[.!?][[:space:]]+/)) {
    emit(substr(s, 1, RSTART))          # chunk up to and incl. the punctuation
    s = substr(s, RSTART + RLENGTH)     # remainder after the whitespace
  }
  emit(s)
}
'
```

- [ ] **Step 4: Make it executable and run the test**

Run:
```bash
chmod +x plugins/read-aloud/scripts/split-sentences.sh
bash tests/split-sentences.test.sh
```
Expected: all `ok:` lines, exit 0.

- [ ] **Step 5: Commit**

```bash
chmod +x tests/split-sentences.test.sh
git add plugins/read-aloud/scripts/split-sentences.sh tests/split-sentences.test.sh
git commit -m "feat: add pure sentence splitter for chunked playback

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 2: Detached player loop

**Files:**
- Create: `plugins/read-aloud/scripts/player.sh`
- Test: `tests/player.test.sh`

**Interfaces:**
- Consumes: a session dir containing `playlist.txt`, `status`, `generation` (seeded by the caller); a `say` on PATH.
- Produces: executable `player.sh <dir> <generation> <start_index>`. Writes `player.pid` (its own `$$`), then for each chunk `i` from `start_index`: sets `index=i`, runs `say <chunk>` recording `say.pid`, waits; advances only if `status==playing` and `generation` still matches, else exits (holding `index`). Sets `status=done` when it runs past the last chunk.

- [ ] **Step 1: Write the failing test**

Create `tests/player.test.sh`:
```bash
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
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/player.test.sh`
Expected: FAIL — `player.sh` missing (`No such file`), non-zero exit.

- [ ] **Step 3: Write minimal implementation**

Create `plugins/read-aloud/scripts/player.sh`:
```bash
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
  say "$chunk" &
  spid=$!
  sset say.pid "$spid"
  wait "$spid" 2>/dev/null
  if [ "$(sget status)" = "playing" ] && [ "$(sget generation)" = "$GEN" ]; then
    i=$((i+1))
  else
    exit 0
  fi
done
```

- [ ] **Step 4: Make it executable and run the test**

Run:
```bash
chmod +x plugins/read-aloud/scripts/player.sh
bash tests/player.test.sh
```
Expected: `PASS: player advances, stops at done, honors generation`, exit 0.

- [ ] **Step 5: Commit**

```bash
chmod +x tests/player.test.sh
git add plugins/read-aloud/scripts/player.sh tests/player.test.sh
git commit -m "feat: add detached per-chunk player loop

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 3: Move saved response into the per-session dir

**Files:**
- Modify: `plugins/read-aloud/scripts/save-response.sh` (whole body)
- Modify: `tests/session-isolation.test.sh` (assert new per-session `response.txt`)

**Interfaces:**
- Consumes: hook JSON on stdin (`.last_assistant_message`, `.session_id`); `CLAUDE_CODE_SESSION_ID`.
- Produces: writes `$HOME/.claude/read-aloud/<session_id>/response.txt` (replaces the flat `read-aloud-last-response-<sid>.txt`).

- [ ] **Step 1: Update the isolation test to expect the new path (failing)**

Replace the body of `tests/session-isolation.test.sh` with:
```bash
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
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/session-isolation.test.sh`
Expected: FAIL — current hook writes `read-aloud-last-response-<sid>.txt`, so `read-aloud/AAA/response.txt` does not exist.

- [ ] **Step 3: Rewrite the hook**

Replace the body of `plugins/read-aloud/scripts/save-response.sh` (keep the header comment) so the value-producing part reads:
```bash
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
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash tests/session-isolation.test.sh`
Expected: `PASS: each session kept its own response`, exit 0.

- [ ] **Step 5: Commit**

```bash
git add plugins/read-aloud/scripts/save-response.sh tests/session-isolation.test.sh
git commit -m "refactor: store saved response under per-session dir

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 4: Rewrite the CLI dispatcher (play/pause/resume/stop)

**Files:**
- Modify: `plugins/read-aloud/bin/read-aloud` (whole body)
- Test: `tests/playback.test.sh`

**Interfaces:**
- Consumes: `split-sentences.sh`, `player.sh` (siblings via `$(dirname "$0")/../scripts`); per-session `response.txt` from the hook; `CLAUDE_CODE_SESSION_ID`.
- Produces: `read-aloud <say|play|pause|resume|continue|stop|quiet>` driving the per-session state + player.

- [ ] **Step 1: Write the failing integration test**

Create `tests/playback.test.sh`:
```bash
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
out="$(bash "$BIN" pause)"; [ "$out" = "⏸ Paused." ] || { echo "FAIL: pause said '$out'"; exit 1; }
[ "$(cat "$DIR/status")" = "paused" ] || { echo "FAIL: status not paused"; exit 1; }
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
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/playback.test.sh`
Expected: FAIL — current `read-aloud` uses the old flat file + `say -f`, so `status`/`playlist.txt` never appear and assertions fail.

- [ ] **Step 3: Rewrite the dispatcher**

Replace the whole body of `plugins/read-aloud/bin/read-aloud` with:
```bash
#!/bin/bash
# read-aloud — macOS text-to-speech voice control for Claude Code.
# Usage: read-aloud <say|play|stop|quiet|pause|resume|continue>
# Playback speaks the last response one sentence at a time via a detached
# player loop; control is per-session and by PID (no SIGSTOP, no global killall).

SID="${CLAUDE_CODE_SESSION_ID:-default}"
DIR="$HOME/.claude/read-aloud/$SID"
HERE="$(cd "$(dirname "$0")" && pwd)"
SPLIT="$HERE/../scripts/split-sentences.sh"
PLAYER="$HERE/../scripts/player.sh"

sget() { cat "$DIR/$1" 2>/dev/null; }
sset() { mkdir -p "$DIR"; printf '%s' "$2" > "$DIR/$1.tmp" && mv "$DIR/$1.tmp" "$DIR/$1"; }
killpid() { local p; p="$(sget "$1")"; [ -n "$p" ] && kill -0 "$p" 2>/dev/null && kill "$p" 2>/dev/null; }
next_gen() { echo $(( $(sget generation 2>/dev/null || echo 0) + 1 )); }

case "$1" in
  say|play)
    if [ ! -s "$DIR/response.txt" ]; then echo "Nothing to speak yet."; exit 0; fi
    "$SPLIT" < "$DIR/response.txt" > "$DIR/playlist.txt"
    killpid say.pid
    gen="$(next_gen)"; sset generation "$gen"; sset status playing; sset index 0
    nohup "$PLAYER" "$DIR" "$gen" 0 >/dev/null 2>&1 &
    disown
    echo "🔊 Speaking…"
    ;;
  pause)
    if [ "$(sget status)" = "playing" ]; then
      sset status paused
      killpid say.pid
      echo "⏸ Paused."
    else
      echo "Nothing is playing."
    fi
    ;;
  resume|continue)
    if [ "$(sget status)" = "paused" ]; then
      gen="$(next_gen)"; sset generation "$gen"; sset status playing
      nohup "$PLAYER" "$DIR" "$gen" "$(sget index 2>/dev/null || echo 0)" >/dev/null 2>&1 &
      disown
      echo "▶️ Resumed."
    else
      echo "Nothing to resume."
    fi
    ;;
  stop|quiet)
    st="$(sget status)"
    if [ "$st" = "playing" ] || [ "$st" = "paused" ]; then
      sset status stopped
      killpid say.pid
      killpid player.pid
      echo "⏹ Stopped."
    else
      echo "Nothing is playing."
    fi
    ;;
  *)
    echo "Usage: read-aloud <say|play|stop|quiet|pause|resume|continue>"
    ;;
esac
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash tests/playback.test.sh`
Expected: `PASS: play/pause/resume replays paused sentence and completes`, exit 0.
If it flakes on timing, re-run once; the `say` stub lingers 0.3s per chunk which comfortably covers the 0.05s poll.

- [ ] **Step 5: Commit**

```bash
chmod +x tests/playback.test.sh
git add plugins/read-aloud/bin/read-aloud tests/playback.test.sh
git commit -m "feat: chunked per-session playback with reliable pause/resume

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 5: Version bump, changelog, run full suite, patch cache

**Files:**
- Modify: `plugins/read-aloud/.claude-plugin/plugin.json` (`version` → `1.1.0`)
- Modify: `CHANGELOG.md`

**Interfaces:**
- Consumes: all prior tasks.
- Produces: released 1.1.0 source; the running cache patched for immediate use.

- [ ] **Step 1: Run the whole test suite (all must pass)**

Run:
```bash
for t in tests/*.test.sh; do echo "== $t =="; bash "$t" || { echo "SUITE FAIL: $t"; break; }; done
```
Expected: every test prints `PASS`/`ok` and the loop finishes without `SUITE FAIL`.

- [ ] **Step 2: Bump the version**

In `plugins/read-aloud/.claude-plugin/plugin.json` change:
```json
  "version": "1.0.1",
```
to:
```json
  "version": "1.1.0",
```

- [ ] **Step 3: Add the changelog entry**

Insert above the `## [1.0.1]` heading in `CHANGELOG.md`:
```markdown
## [1.1.0] - 2026-07-18

### Changed
- **Reliable `/pause` and `/resume`.** Playback now speaks the response one
  sentence at a time via a detached per-session player loop, controlled by PID,
  instead of one `say` process paused with `SIGSTOP`/`SIGCONT` (which macOS
  CoreAudio would not reliably resume). `/pause` stops immediately; `/resume`
  replays the interrupted sentence. Also retires the global `killall say`, so
  controlling one session no longer affects another.
- Saved state moved to `~/.claude/read-aloud/<session_id>/`.

```
And add the link reference near the bottom, above the `[1.0.1]:` line:
```markdown
[1.1.0]: https://github.com/ricardorqr/read-aloud-plugin/releases/tag/v1.1.0
```

- [ ] **Step 4: Patch the running cache and re-verify**

Run:
```bash
SRC=plugins/read-aloud
CACHE="$HOME/.claude/plugins/cache/read-aloud-marketplace/read-aloud/1.0.0"
cp "$SRC/bin/read-aloud" "$CACHE/bin/read-aloud"
cp "$SRC/scripts/save-response.sh" "$CACHE/scripts/save-response.sh"
cp "$SRC/scripts/split-sentences.sh" "$CACHE/scripts/"
cp "$SRC/scripts/player.sh" "$CACHE/scripts/"
diff "$SRC/bin/read-aloud" "$CACHE/bin/read-aloud" && echo "cache bin OK"
ls "$CACHE/scripts"
```
Expected: `cache bin OK`; `scripts` lists `save-response.sh`, `split-sentences.sh`, `player.sh`.

- [ ] **Step 5: Commit**

```bash
git add plugins/read-aloud/.claude-plugin/plugin.json CHANGELOG.md
git commit -m "release: chunked playback v1.1.0

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Notes for the implementer

- **Restart is required** for open sessions to pick up new hook/`bin` behavior; new sessions load it automatically. Cache patching (Task 5 Step 4) makes it available after a restart without a full marketplace reinstall.
- **Timing:** the playback test is mildly timing-sensitive by nature (async audio). The `say` stub lingers 0.3s/chunk vs a 0.05s poll, a 6× margin. If CI ever flakes, increase the stub linger, don't weaken the assertions.
- **Do not** add a Python dependency to any plugin script — `python3` appears only to generate test input.
