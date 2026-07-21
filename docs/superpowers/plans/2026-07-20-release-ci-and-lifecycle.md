# Release CI + Lifecycle Test Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add (1) a GitHub Actions release pipeline that auto-versions, tags, and publishes a GitHub Release on every push to `master`, and (2) a sandboxed, real-CLI plugin lifecycle test.

**Architecture:** Part 1 is three files — a `semantic-release` config (`.releaserc.json`), the workflow (`.github/workflows/release.yml`), and a small `scripts/set-version.sh` helper the release calls to stamp the computed version into `plugin.json` + `CITATION.cff`. Part 2 is one append-built bash script, `tests/lifecycle.test.sh`, auto-discovered by the existing `for t in tests/*.test.sh` runner. The two parts are independent (no shared code); do them in order but either could ship alone.

**Tech Stack:** GitHub Actions, `semantic-release` (via `cycjimmy/semantic-release-action@v4`), Conventional Commits, Bash, `perl` (portable in-place edits + sub-second sleeps), the `claude` CLI + `git` (Part 2 only).

**Spec:** `docs/superpowers/specs/2026-07-20-release-ci-and-lifecycle-design.md` (source of truth).

## Global Constraints

- **New files only** for Part 1: `.releaserc.json`, `.github/workflows/release.yml`, `scripts/set-version.sh`, `tests/set-version.test.sh`. Part 2 adds only `tests/lifecycle.test.sh`. No changes to plugin runtime code.
- **Repo-root `scripts/`** is distinct from the plugin's `plugins/read-aloud/scripts/` (runtime). `set-version.sh` goes at the repo root.
- **Version lives in exactly two files:** `plugins/read-aloud/.claude-plugin/plugin.json` (`version`) and `CITATION.cff` (`version` + `date-released`). The developer never edits either by hand; the CI does.
- **Release trigger:** push to `master`, `semantic-release` *immediate* mode. `fix:`→patch, `feat:`→minor, `feat!:`/`BREAKING CHANGE:`→major; `docs:`/`chore:`/`test:`/`ci:` → no release.
- **Tag format:** `v${version}` (matches existing `v1.0.0`, `v1.1.0`).
- **Part 2 isolation is mandatory:** never touch the real `~/.claude`. Override both `HOME` and `CLAUDE_CONFIG_DIR` into a `mktemp -d` sandbox with a `trap … EXIT` cleanup.
- **Part 2 SKIPs** (`echo "SKIP: …"; exit 0`) when `claude` is not on PATH or GitHub is unreachable. Any post-precondition mismatch is a hard FAIL (`echo "FAIL: …"; exit 1`). All mutating `claude` calls read stdin from `/dev/null`.
- **Part 2 install target:** `ricardorqr/read-aloud-plugin` → plugin id `read-aloud@read-aloud-marketplace`. Resolve the cache dir by globbing; never hard-code a version.
- **Exact command output strings (verbatim):** `🔊 Speaking…`, `⏸ Paused.`, `▶️ Resumed.`, `⏹ Stopped.`, `Nothing to speak yet.`, `Nothing is playing.`, `Nothing to resume.`
- **Every commit message ends with the trailer:** `Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>`
- **Use conventional-commit prefixes for these implementation commits** (`ci:`, `test:`, `chore:`) — none of them trigger a release, which is intended.

---

## Part 1 — Release CI

### Task 1: `scripts/set-version.sh` version stamper (+ its test)

**Files:**
- Create: `scripts/set-version.sh`
- Test: `tests/set-version.test.sh`

**Interfaces:**
- Consumes: nothing from other tasks.
- Produces: `scripts/set-version.sh <X.Y.Z>` — edits exactly two files in place (`plugins/read-aloud/.claude-plugin/plugin.json` `version`; `CITATION.cff` `version` + `date-released`). Pure/idempotent given the same version; no network, no git. `.releaserc.json` (Task 2) calls it as `prepareCmd`.

- [ ] **Step 1: Write the failing test**

Create `tests/set-version.test.sh`:
```bash
#!/bin/bash
# set-version.test.sh — scripts/set-version.sh stamps the release version into
# plugin.json (version) and CITATION.cff (version + date-released), leaving both
# files valid. Backs up and restores both files so the repo is unchanged after.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$ROOT/scripts/set-version.sh"
PJ="$ROOT/plugins/read-aloud/.claude-plugin/plugin.json"
CFF="$ROOT/CITATION.cff"

# Exact-byte backup + guaranteed restore, even on failure.
PJ_BAK="$(mktemp)"; CFF_BAK="$(mktemp)"
cp "$PJ" "$PJ_BAK"; cp "$CFF" "$CFF_BAK"
restore() { cp "$PJ_BAK" "$PJ"; cp "$CFF_BAK" "$CFF"; rm -f "$PJ_BAK" "$CFF_BAK"; }
trap restore EXIT

bash "$SCRIPT" 9.9.9 || { echo "FAIL: set-version.sh exited non-zero"; exit 1; }

grep -q '"version": "9.9.9"' "$PJ" || { echo "FAIL: plugin.json version not stamped: $(grep -i version "$PJ")"; exit 1; }
grep -q 'version: "9.9.9"' "$CFF" || { echo "FAIL: CITATION.cff version not stamped"; exit 1; }
grep -qE 'date-released: "[0-9]{4}-[0-9]{2}-[0-9]{2}"' "$CFF" || { echo "FAIL: CITATION.cff date-released not stamped"; exit 1; }
# cff-version must be untouched (leading-anchored regex must not hit it).
grep -q 'cff-version: 1.2.0' "$CFF" || { echo "FAIL: cff-version was clobbered"; exit 1; }
# plugin.json must remain valid JSON (guarded: only if python3 is present).
if command -v python3 >/dev/null 2>&1; then
  python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$PJ" \
    || { echo "FAIL: plugin.json is not valid JSON after edit"; exit 1; }
fi

echo "PASS: set-version.sh stamps plugin.json + CITATION.cff, structure intact"
```

- [ ] **Step 2: Run the test to verify it fails**

Run:
```bash
bash tests/set-version.test.sh; echo "exit=$?"
```
Expected: FAIL (script does not exist yet) — the `bash "$SCRIPT" 9.9.9` line errors, prints `FAIL: set-version.sh exited non-zero`, `exit=1`. (The trap still restores the untouched files.)

- [ ] **Step 3: Write the minimal implementation**

Create `scripts/set-version.sh`:
```bash
#!/bin/bash
# set-version.sh — stamp a release version into every file that carries it.
# Usage: scripts/set-version.sh <X.Y.Z>   (no leading "v")
# Called automatically by semantic-release (@semantic-release/exec prepareCmd);
# also safe to run by hand. Edits exactly two files: the plugin manifest and
# CITATION.cff. Pure/idempotent; no network, no git.
set -eu

VERSION="${1:?usage: set-version.sh <X.Y.Z>}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PLUGIN_JSON="$ROOT/plugins/read-aloud/.claude-plugin/plugin.json"
CITATION="$ROOT/CITATION.cff"
TODAY="$(date -u +%F)"
export VERSION TODAY

# plugin.json: replace ONLY the value of the "version" key (structure preserved).
perl -i -pe 's/("version"\s*:\s*")[^"]*(")/${1}$ENV{VERSION}${2}/' "$PLUGIN_JSON"

# CITATION.cff: version + date-released. Leading-anchored so `cff-version:` is
# never matched.
perl -i -pe 's/^version:.*/version: "$ENV{VERSION}"/; s/^date-released:.*/date-released: "$ENV{TODAY}"/' "$CITATION"
```

- [ ] **Step 4: Make it executable and run the test to verify it passes**

Run:
```bash
chmod +x scripts/set-version.sh
bash tests/set-version.test.sh; echo "exit=$?"
```
Expected: `PASS: set-version.sh stamps plugin.json + CITATION.cff, structure intact`, `exit=0`. Then confirm the repo is unchanged:
```bash
git status --porcelain plugins/read-aloud/.claude-plugin/plugin.json CITATION.cff
```
Expected: no output (the test restored both files).

- [ ] **Step 5: Commit**

```bash
chmod +x tests/set-version.test.sh
git add scripts/set-version.sh tests/set-version.test.sh
git commit -m "ci: add set-version.sh version stamper with test

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 2: `semantic-release` config + release workflow

**Files:**
- Create: `.releaserc.json`
- Create: `.github/workflows/release.yml`

**Interfaces:**
- Consumes: `scripts/set-version.sh` from Task 1 (invoked as `prepareCmd`).
- Produces: on push to `master`, an automatic version/tag/GitHub-Release pipeline. No later task consumes this.

- [ ] **Step 1: Create the `semantic-release` config**

Create `.releaserc.json`:
```json
{
  "branches": ["master"],
  "tagFormat": "v${version}",
  "plugins": [
    ["@semantic-release/commit-analyzer", { "preset": "conventionalcommits" }],
    ["@semantic-release/release-notes-generator", { "preset": "conventionalcommits" }],
    ["@semantic-release/changelog", { "changelogFile": "CHANGELOG.md" }],
    ["@semantic-release/exec", { "prepareCmd": "scripts/set-version.sh ${nextRelease.version}" }],
    ["@semantic-release/git", {
      "assets": [
        "CHANGELOG.md",
        "CITATION.cff",
        "plugins/read-aloud/.claude-plugin/plugin.json"
      ],
      "message": "chore(release): ${nextRelease.version} [skip ci]\n\n${nextRelease.notes}"
    }],
    "@semantic-release/github"
  ]
}
```

- [ ] **Step 2: Validate the config is well-formed JSON**

Run:
```bash
python3 -m json.tool .releaserc.json >/dev/null && echo "OK: .releaserc.json is valid JSON"
```
Expected: `OK: .releaserc.json is valid JSON`. (If `python3` is absent, use `node -e 'JSON.parse(require("fs").readFileSync(".releaserc.json","utf8"))' && echo OK`.)

- [ ] **Step 3: Create the release workflow**

Create `.github/workflows/release.yml`:
```yaml
name: Release

on:
  push:
    branches: [master]

permissions:
  contents: write        # push the chore(release) commit + tag, create the Release
  issues: write          # semantic-release can comment on resolved issues
  pull-requests: write   # …and on merged PRs

jobs:
  release:
    runs-on: ubuntu-latest
    steps:
      - name: Checkout
        uses: actions/checkout@v4
        with:
          fetch-depth: 0          # full history so version is computed from all tags
          persist-credentials: true

      - name: Set up Node
        uses: actions/setup-node@v4
        with:
          node-version: 20

      - name: Semantic Release
        uses: cycjimmy/semantic-release-action@v4
        with:
          extra_plugins: |
            @semantic-release/changelog
            @semantic-release/exec
            @semantic-release/git
            conventional-changelog-conventionalcommits
        env:
          GITHUB_TOKEN: ${{ secrets.GITHUB_TOKEN }}
```

- [ ] **Step 4: Validate the workflow YAML parses**

Run:
```bash
python3 -c 'import yaml,sys; yaml.safe_load(open(".github/workflows/release.yml"))' && echo "OK: release.yml parses"
```
Expected: `OK: release.yml parses`. (If PyYAML is unavailable, skip — GitHub validates it on push; a visual check that indentation matches the block above is sufficient.)

- [ ] **Step 5: Commit**

```bash
git add .releaserc.json .github/workflows/release.yml
git commit -m "ci: automate versioning and GitHub Releases with semantic-release

Push to master computes the next version from Conventional Commits,
stamps plugin.json + CITATION.cff via scripts/set-version.sh, updates
CHANGELOG.md, tags vX.Y.Z, and publishes the GitHub Release.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

- [ ] **Step 6: Post-merge verification (manual, requires push access)**

After this lands on `master`, open the repo's **Actions** tab and confirm the **Release** workflow ran. Because every commit in this branch is `ci:`/`test:`/`chore:`/`docs:` (none `feat:`/`fix:`), `semantic-release` should log *"There are no relevant changes, so no new version is released"* — a clean no-op, **not** a failure. The first real release happens on the next `feat:`/`fix:` push.

**Repo-settings prerequisite (one-time):** `master` must allow the action to push the `chore(release)` commit. If `master` has branch protection, either exempt `github-actions[bot]` or allow the push; otherwise the `@semantic-release/git` step fails. The `[skip ci]` subject + `GITHUB_TOKEN` push does not re-trigger the workflow, so there is no release loop.

---

## Part 2 — Lifecycle test

### Task 3: Lifecycle skeleton — preconditions, isolation, helpers

**Files:**
- Create: `tests/lifecycle.test.sh`

**Interfaces:**
- Consumes: `claude` CLI + `git` on PATH; network to GitHub.
- Produces: an executable script that either SKIPs (missing dep) or stands up an isolated sandbox and defines `fail`/`waitfor`. Tasks 4–5 append their logic after the helpers.

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

Run (scrub PATH so `claude` is not found):
```bash
PATH=/usr/bin:/bin bash tests/lifecycle.test.sh; echo "exit=$?"
```
Expected: `SKIP: claude CLI not on PATH` and `exit=0`. (If `git`/`perl` are outside `/usr/bin` on this machine and a different SKIP line prints, that is still a valid pass — the requirement is a clean `exit=0`, never a FAIL.)

- [ ] **Step 4: Verify the happy path reaches the sandbox (deps present → silent exit 0)**

Run:
```bash
bash tests/lifecycle.test.sh; echo "exit=$?"
```
Expected: no output, `exit=0` — the script sets up the sandbox, defines helpers, and falls off the end (Tasks 4–5 add the assertions). Confirm the real store is untouched:
```bash
claude plugin list 2>/dev/null | grep -A1 "read-aloud@read-aloud-marketplace"
```
Expected: your real install still shows its current version (the test used a temp `HOME`).

- [ ] **Step 5: Commit**

```bash
git add tests/lifecycle.test.sh
git commit -m "test: add lifecycle test skeleton (preconditions + sandbox)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 4: Install, presence assertions, and feature-behavior

**Files:**
- Modify: `tests/lifecycle.test.sh` (append after the Task 3 helpers)

**Interfaces:**
- Consumes: `REPO_GH`, `PLUGIN_ID`, `CLAUDE_CONFIG_DIR`, `SANDBOX`, `fail`, `waitfor` from Task 3.
- Produces: `CACHE` (absolute path to the installed plugin's version dir), used by the behavior section and by Task 5's removal assertions; leaves the plugin installed in the sandbox for Task 5 to uninstall.

- [ ] **Step 1: Append the install + presence-assertion block**

Append to `tests/lifecycle.test.sh`:
```bash

# --- Install from the published GitHub marketplace (the "new version") -------
claude plugin marketplace add "$REPO_GH" </dev/null >/dev/null 2>&1 \
  || { echo "SKIP: marketplace add failed (network?)"; exit 0; }
claude plugin install "$PLUGIN_ID" </dev/null >/dev/null 2>&1 \
  || fail "plugin install failed"

# --- Presence assertions: all commands, the hook, the dispatcher + scripts ---
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

- [ ] **Step 2: Append the feature-behavior block (stubbed `say`, no audio)**

Append to `tests/lifecycle.test.sh`:
```bash

# --- Features actually work: run the INSTALLED dispatcher with a stubbed say -
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
Expected two lines then `exit=0`:
`PASS: install exposes all 7 commands, the Stop hook, and the dispatcher+scripts`
`PASS: installed commands produce the correct output strings`
If it FAILs on a `claude` confirmation prompt, confirm the `</dev/null` is present on both `marketplace add` and `install`. If the behavior block flakes on timing, increase the `0.3` linger in the stub `say` — never weaken the assertions.

- [ ] **Step 4: Verify the real store is still untouched**

Run:
```bash
claude plugin list 2>/dev/null | grep -A1 "read-aloud@read-aloud-marketplace"
```
Expected: your real install still shows its current version (the test ran entirely in the temp sandbox).

- [ ] **Step 5: Commit**

```bash
git add tests/lifecycle.test.sh
git commit -m "test: assert install exposes commands+hook and features work

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 5: Uninstall, removal assertions, and full-suite verification

**Files:**
- Modify: `tests/lifecycle.test.sh` (append after the Task 4 behavior block)

**Interfaces:**
- Consumes: `PLUGIN_ID`, `CLAUDE_CONFIG_DIR`, `CACHE`, `fail` from Tasks 3–4.
- Produces: the terminal removal assertions and final PASS lines; nothing downstream depends on it.

- [ ] **Step 1: Append the uninstall + removal-assertion block**

Append to `tests/lifecycle.test.sh`:
```bash

# --- Uninstall + removal assertions: every installed file must be gone -------
claude plugin uninstall "$PLUGIN_ID" </dev/null >/dev/null 2>&1 \
  || fail "plugin uninstall failed"

claude plugin list 2>/dev/null | grep -q "read-aloud@read-aloud-marketplace" \
  && fail "plugin still listed after uninstall"

IP="$CLAUDE_CONFIG_DIR/plugins/installed_plugins.json"
if [ -f "$IP" ]; then
  grep -q "read-aloud@read-aloud-marketplace" "$IP" \
    && fail "installed_plugins.json still has a read-aloud entry after uninstall"
fi

# Cache version dir removed, OR soft-deleted (.orphaned_at marker tolerated —
# happens only when another live session holds an in-use ref; not expected in
# this fresh sandbox, so a hard delete is the normal outcome).
if [ -d "$CACHE" ]; then
  [ -f "$CACHE/.orphaned_at" ] \
    || fail "cache dir still present without a soft-delete marker after uninstall"
fi

echo "PASS: uninstall removes the plugin (list + installed_plugins.json + all files)"
echo "PASS: full lifecycle (install -> verify -> run -> uninstall -> verify) complete"
```

- [ ] **Step 2: Run the full lifecycle test end to end**

Run:
```bash
bash tests/lifecycle.test.sh; echo "exit=$?"
```
Expected: four `PASS:` lines ending with
`PASS: full lifecycle (install -> verify -> run -> uninstall -> verify) complete` and `exit=0`.

- [ ] **Step 3: Run the whole suite (all pass or skip, none FAIL)**

Run:
```bash
for t in tests/*.test.sh; do echo "== $t =="; bash "$t" || { echo "SUITE FAIL: $t"; break; }; done
```
Expected: every test prints `PASS`/`ok`/`SKIP`; the loop finishes without `SUITE FAIL`. `tests/lifecycle.test.sh` and `tests/set-version.test.sh` are both picked up automatically by the glob.

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

- **Part 1 needs no real run to land.** A genuine release only happens after a `feat:`/`fix:` commit reaches `master`. Landing the CI itself is a safe no-op (all commits here are `ci:`/`test:`). Do not force a release to "test" it.
- **Part 2 needs `claude` + network for a real run.** Without them it SKIPs (exit 0) — correct behavior, not a failure. It installs from GitHub `master`, so it verifies the *published* artifact; an unpushed local commit is not what gets tested (by design).
- **Timing (Part 2):** the stubbed `say` lingers 0.3s per chunk vs the 0.05s `waitfor` poll (6× margin). If the behavior section flakes, increase the linger — never weaken assertions.
- **Never hard-code a plugin version** in Part 2; the `find`-based `CACHE` resolution is deliberate so releases don't break the test.
- **`master` push-back prerequisite (Part 1):** see Task 2 Step 6 — branch protection must allow the `chore(release)` commit.
