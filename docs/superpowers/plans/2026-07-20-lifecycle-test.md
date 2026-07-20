# Plugin Lifecycle Test Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add `tests/lifecycle.test.sh` — a repeatable test that drives the real `claude plugin` install/uninstall lifecycle against the published GitHub marketplace, fully sandboxed, verifying all 7 commands + the Stop hook are present and the commands work.

**Architecture:** One append-only bash script built in three passes: (1) preconditions + isolation + helpers, (2) install + presence assertions + command-behavior via a stubbed `say`, (3) uninstall + removal assertions. It skips cleanly (exit 0) when `claude` or GitHub are unavailable, and hard-fails on any post-precondition assertion. It is named `tests/lifecycle.test.sh` so the existing `for t in tests/*.test.sh` loop auto-discovers it — no runner change.

**Tech Stack:** Bash, the `claude` CLI, `git` (reachability probe), `perl` (sub-second sleeps, matching the existing tests).

## Global Constraints

- New file only: `tests/lifecycle.test.sh`. No changes to plugin runtime code or other tests.
- Isolation is mandatory: never touch the real `~/.claude`. Override both `HOME` and `CLAUDE_CONFIG_DIR` into a `mktemp -d` sandbox with a `trap … EXIT` cleanup.
- SKIP (print `SKIP: …`, exit 0) when `claude` is not on PATH or GitHub is unreachable. Any post-precondition mismatch is a hard FAIL (`echo "FAIL: …"; exit 1`).
- Install source is the published GitHub marketplace: `ricardorqr/read-aloud-plugin` → plugin id `read-aloud@read-aloud-marketplace`.
- Version-agnostic: resolve the cache dir by globbing, never hard-code a version number.
- All `claude` mutating calls read stdin from `/dev/null` to avoid hanging on any confirmation prompt.
- Follow existing test conventions: `set -u`, `mktemp -d` + `trap`, stub `say` prepended to `PATH`, `waitfor` polling helper with `perl` sleeps, explicit `PASS:`/`FAIL:` lines.
- Exact command output strings (must match verbatim): `🔊 Speaking…`, `⏸ Paused.`, `▶️ Resumed.`, `⏹ Stopped.`, `Nothing to speak yet.`, `Nothing is playing.`, `Nothing to resume.`
- Every commit message ends with the trailer:
  `Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>`

---

### Task 1: Skeleton — preconditions, isolation, helpers

**Files:**
- Create: `tests/lifecycle.test.sh`

**Interfaces:**
- Consumes: `claude` CLI + `git` on PATH; network to GitHub.
- Produces: an executable script whose first responsibility is to *either* skip (missing dep) *or* stand up an isolated sandbox and define `fail`/`waitfor` helpers. Later tasks append their logic after the helpers.

- [ ] **Step 1: Create the script with preconditions, isolation, and helpers**

Create `tests/lifecycle.test.sh`:
```bash
#!/bin/bash
# lifecycle.test.sh — real `claude plugin` install/uninstall lifecycle against
# the published GitHub marketplace, fully sandboxed. Skips (exit 0) when the
# claude CLI or GitHub are unavailable; hard-fails on any post-precondition
# assertion. Isolation: HOME + CLAUDE_CONFIG_DIR are redirected into a temp
# sandbox so the real ~/.claude is never touched.
set -u

REPO_GH="ricardorqr/read-aloud-plugin"
GH_URL="https://github.com/${REPO_GH}.git"
PLUGIN_ID="read-aloud@read-aloud-marketplace"

# --- Preconditions: skip (do not fail) when external deps are unavailable ---
command -v claude >/dev/null 2>&1 || { echo "SKIP: claude CLI not on PATH"; exit 0; }
git ls-remote "$GH_URL" >/dev/null 2>&1 || { echo "SKIP: GitHub unreachable ($GH_URL)"; exit 0; }

# --- Isolation: sandbox HOME + claude config dir, always cleaned up ---------
SANDBOX="$(mktemp -d)"; trap 'rm -rf "$SANDBOX"' EXIT
export HOME="$SANDBOX/home"; mkdir -p "$HOME"
export CLAUDE_CONFIG_DIR="$HOME/.claude"

# --- Helpers ----------------------------------------------------------------
fail() { echo "FAIL: $*"; exit 1; }
waitfor() { for _ in $(seq 1 200); do eval "$1" && return 0; perl -e 'select(undef,undef,undef,0.05)'; done; return 1; }
```

- [ ] **Step 2: Make it executable**

Run:
```bash
chmod +x tests/lifecycle.test.sh
```

- [ ] **Step 3: Verify the SKIP path (dependency missing → exit 0)**

Run (simulate no `claude` by scrubbing PATH to a minimal set without it):
```bash
PATH=/usr/bin:/bin bash tests/lifecycle.test.sh; echo "exit=$?"
```
Expected: prints `SKIP: claude CLI not on PATH` and `exit=0`.
(If `git`/`perl` live outside `/usr/bin` on this machine and the skip line differs, that's still a valid SKIP — the point is a clean exit 0, never a FAIL.)

- [ ] **Step 4: Verify the happy path reaches the sandbox (deps present → silent exit 0)**

Run:
```bash
bash tests/lifecycle.test.sh; echo "exit=$?"
```
Expected: no output, `exit=0` (the script sets up the sandbox, defines helpers, and falls off the end). Confirm the real store is untouched:
```bash
ls "$HOME/.claude/plugins/cache/read-aloud-marketplace" 2>/dev/null && echo "REAL STORE (expected: your real plugin, unchanged)"
```
Expected: your real install is still there and unchanged (the test used a temp `HOME`, not this one).

- [ ] **Step 5: Commit**

```bash
git add tests/lifecycle.test.sh
git commit -m "test: add lifecycle test skeleton (preconditions + sandbox)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 2: Install, presence assertions, and command-behavior

**Files:**
- Modify: `tests/lifecycle.test.sh` (append after the helpers from Task 1)

**Interfaces:**
- Consumes: `REPO_GH`, `PLUGIN_ID`, `CLAUDE_CONFIG_DIR`, `SANDBOX`, `fail`, `waitfor` from Task 1.
- Produces: `CACHE` (absolute path to the installed plugin's version dir) used by the command-behavior section; leaves the plugin installed in the sandbox for Task 3 to uninstall.

- [ ] **Step 1: Append the install + presence-assertion block**

Append to `tests/lifecycle.test.sh`:
```bash

# --- Install from the published GitHub marketplace --------------------------
claude plugin marketplace add "$REPO_GH" </dev/null >/dev/null 2>&1 \
  || { echo "SKIP: marketplace add failed (network?)"; exit 0; }
claude plugin install "$PLUGIN_ID" </dev/null >/dev/null 2>&1 \
  || fail "plugin install failed"

# --- Presence assertions ----------------------------------------------------
claude plugin list 2>/dev/null | grep -q "read-aloud@read-aloud-marketplace" \
  || fail "plugin not listed after install"

CACHE="$(find "$CLAUDE_CONFIG_DIR/plugins/cache/read-aloud-marketplace/read-aloud" \
  -mindepth 1 -maxdepth 1 -type d 2>/dev/null | head -1)"
[ -n "$CACHE" ] && [ -d "$CACHE" ] || fail "cache dir not found after install"

for c in say play pause resume continue stop quiet; do
  [ -f "$CACHE/commands/$c.md" ] || fail "missing command file: commands/$c.md"
done

[ -f "$CACHE/hooks/hooks.json" ] || fail "missing hooks/hooks.json"
grep -q '"Stop"' "$CACHE/hooks/hooks.json" || fail "hooks.json does not register a Stop hook"
grep -q 'save-response.sh' "$CACHE/hooks/hooks.json" || fail "Stop hook does not call save-response.sh"

[ -x "$CACHE/bin/read-aloud" ] || fail "bin/read-aloud missing or not executable"
for s in save-response.sh split-sentences.sh player.sh; do
  [ -f "$CACHE/scripts/$s" ] || fail "missing script: scripts/$s"
done

echo "PASS: install exposes all 7 commands, the Stop hook, and the dispatcher+scripts"
```

- [ ] **Step 2: Append the command-behavior block (stubbed `say`, no audio)**

Append to `tests/lifecycle.test.sh`:
```bash

# --- Commands actually work: run the INSTALLED dispatcher with a stubbed say -
mkdir -p "$SANDBOX/bin"
cat > "$SANDBOX/bin/say" <<'EOF'
#!/bin/bash
[ "$1" = "--" ] && shift
echo "$*" >> "$HOME/.claude/read-aloud/LIFECYCLE/say.log"
perl -e 'select(undef,undef,undef,0.3)'
EOF
chmod +x "$SANDBOX/bin/say"; export PATH="$SANDBOX/bin:$PATH"
export CLAUDE_CODE_SESSION_ID=LIFECYCLE
BIN="$CACHE/bin/read-aloud"
DIR="$HOME/.claude/read-aloud/LIFECYCLE"

# Empty states first (no response.txt yet).
out="$(bash "$BIN" play)";   [ "$out" = "Nothing to speak yet." ] || fail "empty play said '$out'"
out="$(bash "$BIN" resume)"; [ "$out" = "Nothing to resume." ]    || fail "idle resume said '$out'"
out="$(bash "$BIN" pause)";  [ "$out" = "Nothing is playing." ]   || fail "idle pause said '$out'"
out="$(bash "$BIN" stop)";   [ "$out" = "Nothing is playing." ]   || fail "idle stop said '$out'"

# Seed a response, then drive play -> pause -> resume -> stop.
mkdir -p "$DIR"; printf 'One. Two. Three. Four. Five.' > "$DIR/response.txt"
out="$(bash "$BIN" play)";   [ "$out" = "🔊 Speaking…" ] || fail "play said '$out'"
waitfor '[ -s "$DIR/say.log" ]' || fail "nothing spoken after play"
out="$(bash "$BIN" pause)";  [ "$out" = "⏸ Paused." ]   || fail "pause said '$out'"
out="$(bash "$BIN" resume)"; [ "$out" = "▶️ Resumed." ] || fail "resume said '$out'"
out="$(bash "$BIN" stop)";   [ "$out" = "⏹ Stopped." ]  || fail "stop said '$out'"

echo "PASS: installed commands produce the correct output strings"
```

- [ ] **Step 3: Run the test to verify install + behavior pass**

Run (needs `claude` + network; installs from GitHub — may take a few seconds):
```bash
bash tests/lifecycle.test.sh; echo "exit=$?"
```
Expected: two lines —
`PASS: install exposes all 7 commands, the Stop hook, and the dispatcher+scripts`
`PASS: installed commands produce the correct output strings` — and `exit=0`.
If it FAILs on a `claude` confirmation prompt, confirm the `</dev/null` is present on both `marketplace add` and `install`.

- [ ] **Step 4: Verify the real store is still untouched**

Run:
```bash
claude plugin list 2>/dev/null | grep -A1 "read-aloud@read-aloud-marketplace"
```
Expected: your real install still shows its current version (the test ran entirely in the temp sandbox; this real list is unaffected).

- [ ] **Step 5: Commit**

```bash
git add tests/lifecycle.test.sh
git commit -m "test: assert install exposes commands+hook and commands work

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 3: Uninstall, removal assertions, and full-suite verification

**Files:**
- Modify: `tests/lifecycle.test.sh` (append after the command-behavior block)

**Interfaces:**
- Consumes: `PLUGIN_ID`, `CLAUDE_CONFIG_DIR`, `CACHE`, `fail` from Tasks 1–2.
- Produces: the terminal removal assertions and final PASS lines; nothing downstream depends on it.

- [ ] **Step 1: Append the uninstall + removal-assertion block**

Append to `tests/lifecycle.test.sh`:
```bash

# --- Uninstall + removal assertions -----------------------------------------
claude plugin uninstall "$PLUGIN_ID" </dev/null >/dev/null 2>&1 \
  || fail "plugin uninstall failed"

claude plugin list 2>/dev/null | grep -q "read-aloud@read-aloud-marketplace" \
  && fail "plugin still listed after uninstall"

IP="$CLAUDE_CONFIG_DIR/plugins/installed_plugins.json"
if [ -f "$IP" ]; then
  grep -q "read-aloud@read-aloud-marketplace" "$IP" \
    && fail "installed_plugins.json still has a read-aloud entry after uninstall"
fi

# Cache dir removed, OR soft-deleted (.orphaned_at marker tolerated — happens
# when another live session holds an in-use ref; not expected in this sandbox).
if [ -d "$CACHE" ]; then
  [ -f "$CACHE/.orphaned_at" ] \
    || fail "cache dir still present without a soft-delete marker after uninstall"
fi

echo "PASS: uninstall removes the plugin (list + installed_plugins.json + cache)"
echo "PASS: full lifecycle (install -> verify -> run -> uninstall -> verify) complete"
```

- [ ] **Step 2: Run the full lifecycle test end to end**

Run:
```bash
bash tests/lifecycle.test.sh; echo "exit=$?"
```
Expected: four `PASS:` lines ending with
`PASS: full lifecycle (install -> verify -> run -> uninstall -> verify) complete`
and `exit=0`.

- [ ] **Step 3: Run the whole suite (all pass or skip, none FAIL)**

Run:
```bash
for t in tests/*.test.sh; do echo "== $t =="; bash "$t" || { echo "SUITE FAIL: $t"; break; }; done
```
Expected: every test prints `PASS`/`ok`/`SKIP`; the loop finishes without `SUITE FAIL`. `tests/lifecycle.test.sh` is picked up automatically by the glob.

- [ ] **Step 4: Confirm the real environment is intact**

Run:
```bash
claude plugin list 2>/dev/null | grep -A1 "read-aloud@read-aloud-marketplace"
```
Expected: your real `read-aloud` install still present at its current version — the regression the original manual run violated is now guarded against.

- [ ] **Step 5: Commit**

```bash
git add tests/lifecycle.test.sh
git commit -m "test: assert uninstall fully removes the plugin

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Notes for the implementer

- **Network + `claude` required for a real run.** On a machine without them, the test SKIPs (exit 0) — that is correct behavior, not a failure. To see it actually exercise the lifecycle you need both.
- **It installs from GitHub master**, so it verifies the *published* artifact. A local commit that hasn't been pushed is not what gets tested — by design.
- **Timing:** the stubbed `say` lingers 0.3s per chunk vs the 0.05s `waitfor` poll (6× margin). If the behavior section ever flakes, increase the stub linger — never weaken the assertions.
- **Do not** hard-code a plugin version anywhere; the `find`-based `CACHE` resolution is deliberate so releases don't break the test.
