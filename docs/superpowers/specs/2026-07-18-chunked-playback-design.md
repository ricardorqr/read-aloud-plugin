# Read-Aloud — Chunked Playback Design

**Status:** Approved for implementation
**Date:** 2026-07-18
**Target version:** 1.1.0
**Scope:** Replace the single-process `say` playback with a sentence-chunked
player so `/pause` and `/resume` work reliably. Same commands, same UX.

---

## 1. Problem

Playback today launches one detached process: `say -f <last-response-file>`.
`/pause` and `/resume` send `SIGSTOP` / `SIGCONT` to it via `killall`.

Two defects:
1. **Resume produces no audio.** Freezing the `say` process with `SIGSTOP`
   stalls its CoreAudio client; macOS starves/drops it. On `SIGCONT` the
   *process* resumes (verified: state `T` → `S`) and reads its text to the end,
   but the **audio does not resume** — you hear a scrap of the buffer, then
   silence. Confirmed by process-state evidence + the observed symptom.
2. **`killall say` is global.** Pause/stop in one session affects every
   session's speech, because `say` processes aren't keyed to a session.

The fix is to stop relying on signal-freezing an audio process: speak in
**sentence-sized chunks**, track position, and control the current chunk's
`say` **by PID**.

---

## 2. Goals / Non-goals

**Goals**
- `/pause` stops **immediately**; `/resume` **replays the interrupted sentence**
  from its start (operator's chosen behavior).
- Per-session isolation for both content and playback control (retire global
  `killall`).
- No dependency on `SIGSTOP`/`SIGCONT` audio behavior.

**Non-goals**
- Voice / rate / volume configuration (keep `say` defaults).
- Word-level resume precision (sentence granularity is enough).
- Cross-platform (`say` is macOS-only, unchanged).

---

## 3. Architecture

Each Claude slash command is a separate short-lived process, so auto-advancing
through sentences needs a **detached background player loop**. Four small units:

| Unit | Responsibility | Depends on |
|---|---|---|
| `scripts/save-response.sh` | Stop hook: write the latest response into the per-session dir | `jq` |
| `scripts/split-sentences.sh` | **Pure**: stdin text → stdout one chunk per line | none |
| `scripts/player.sh` | Detached loop: speak chunk *i*, record `say.pid`, advance or hold | `say` |
| `bin/read-aloud` | Dispatch play/pause/resume/stop; build playlist; manage state; launch player | the above |

`split-sentences.sh` and `player.sh` are new; the other two are reworked.

---

## 4. State model

Per session: `~/.claude/read-aloud/<session_id>/`, **one file per field** so every
write is a single atomic value (`printf > tmp && mv tmp field`) with no
multi-field parse races:

```
response.txt    # raw last response (written by the Stop hook)
playlist.txt    # the split chunks, one per line (built at play time)
status          # playing | paused | stopped | done
index           # 0-based index of the current/next chunk
generation      # bumped by every play/resume; stale players self-exit
say.pid         # PID of the chunk currently being spoken
player.pid      # PID of the detached player loop
```

`<session_id>` comes from `CLAUDE_CODE_SESSION_ID` (CLI) / the hook payload's
`session_id`, matching the 1.0.1 isolation fix.

---

## 5. Behavior per verb (`bin/read-aloud`)

- **play / say**
  1. Require non-empty `response.txt`, else print `Nothing to speak yet.`
  2. `split-sentences.sh < response.txt > playlist.txt`.
  3. Kill any existing `say.pid`; `generation++`; `status=playing`; `index=0`.
  4. Launch `player.sh <dir> <generation> 0` detached (`nohup … & disown`);
     record `player.pid`.
  5. Print `🔊 Speaking…`.
- **pause** — if `status=playing`: `status=paused`, `kill $(say.pid)` (this
  session only) → immediate stop, `index` unchanged; print `⏸ Paused.`
  Else `Nothing is playing.`
- **resume / continue** — if `status=paused`: `generation++`, `status=playing`,
  launch `player.sh <dir> <generation> <index>` (replays the saved chunk);
  print `▶️ Resumed.` Else `Nothing to resume.`
- **stop / quiet** — if `status ∈ {playing,paused}`: `status=stopped`,
  kill `say.pid` and `player.pid`; print `⏹ Stopped.` Else `Nothing is playing.`

### Player loop (`player.sh <dir> <gen> <start>`)
```
i = start
loop:
  read status,generation
  if status != playing or generation != gen: exit          # newer player or paused/stopped
  if i >= total(playlist): status = done; exit
  index = i
  say -f <chunk i> &  ; say.pid = $! ; wait say.pid
  read status,generation
  if status == playing and generation == gen: i++          # finished naturally → advance
  else: exit                                                # killed by pause/stop → hold index
```
The generation check is what prevents two loops speaking at once after rapid
play/resume. Holding `index` on a killed chunk is what makes resume replay it.

---

## 6. Sentence splitting (`split-sentences.sh`)

Rules, applied to stdin:
1. Break after sentence-ending punctuation (`.`, `!`, `?`) followed by space.
2. Break on newlines (paragraph/line boundaries).
3. Collapse remaining internal whitespace so each chunk is a single line.
4. Drop empty lines.
5. **Hard-wrap** any chunk longer than ~250 chars at a word boundary, so pause
   stays responsive inside long, unpunctuated text (e.g. code blocks).

Imperfect splits (abbreviations, decimals) are acceptable — chunking is for
pause granularity, not prosody.

---

## 7. Edge cases

- Empty response → `Nothing to speak yet.`
- No punctuation → one (hard-wrapped) chunk sequence; pause still works at wraps.
- `/pause` after playback finished (`status=done`) → `Nothing is playing.`
- `/resume` while playing → `Nothing to resume.`
- Rapid `/play` ×2 → 2nd bumps generation and restarts; 1st player exits on
  generation mismatch (no double speech).
- Stale `say.pid` (process already gone) → guard with `kill -0` before killing;
  PID reuse risk is negligible and only acted on when `status` says active.
- A new turn completes mid-playback → the Stop hook rewrites `response.txt`
  only; the running player keeps its already-built `playlist.txt`. The next
  `/play` picks up the new content.

---

## 8. Testing (TDD)

- **split-sentences** — pure in/out fixtures: multi-sentence, embedded
  newlines, long unpunctuated run (asserts hard-wrap), punctuation edge cases.
- **playback** — sandbox (temp `HOME`, stub `say` that appends each spoken
  chunk to a log and sleeps briefly, stub nothing else needed since control is
  PID-based). Drive `play → pause → resume → stop`; assert:
  - chunks are spoken in order,
  - `pause` stops within one chunk (log stops growing),
  - `resume` **re-speaks the interrupted chunk** (same chunk appears twice),
  - `stop` ends playback and clears state.
- **session isolation** — the existing `tests/session-isolation.test.sh`
  continues to pass against the new per-session dir.

---

## 9. Migration & retirement

- Bump to **1.1.0** (new playback engine; commands and their output strings
  unchanged).
- Retires: `SIGSTOP`/`SIGCONT` control and global `killall say`.
- State moves from a flat `~/.claude/read-aloud-last-response-<sid>.txt` to the
  per-session dir `~/.claude/read-aloud/<sid>/`. No migration needed — the Stop
  hook repopulates on the next turn; a one-line note in the CHANGELOG suffices.
