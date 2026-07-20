# Plugin Lifecycle Test — Design

**Date:** 2026-07-20

**Goal:** Codify the ad-hoc plugin lifecycle verification (uninstall → confirm
gone → reinstall → confirm all commands work) into a repeatable, committed test
that drives the **real `claude plugin` CLI** against the **published GitHub
marketplace**, without ever touching the developer's real installed plugins.

**Scope:** One new test script, `tests/lifecycle.test.sh`, added to the repo so
the existing `for t in tests/*.test.sh` loop picks it up automatically. No
changes to the plugin's runtime code or the other tests.

## Why this exists

The existing `tests/*.test.sh` (split-sentences, player, session-isolation,
playback) exercise the dispatcher and scripts **directly** from the source tree.
They do not cover the **plugin-manager integration** — that a fresh
`claude plugin install` of the *published* artifact yields a working plugin with
all commands and hooks present, and that `claude plugin uninstall` cleanly
removes it. That integration was only ever verified manually (via a subagent),
and that manual run silently downgraded the developer's live plugin. This test
makes the check repeatable and safe.

## Non-goals

- Not a hermetic/offline test. By decision, it installs from GitHub, so it needs
  network + the `claude` binary. It is intentionally an integration/release test.
- Not a version-pinning test. It asserts that *whatever is published* installs
  and works; it does not assert a specific version number (so it survives
  releases without edits).
- Does not test Anthropic's `claude plugin` CLI internals — only this plugin's
  installable shape and behavior through that CLI.

## Architecture

A single bash script, `tests/lifecycle.test.sh`, structured in five ordered
phases. It follows the conventions of the existing tests (bash, `set -u`, a
`trap` for cleanup, explicit `FAIL:`/`PASS:` lines, non-zero exit on failure).

### Phase 1 — Isolation (safety core)

All state goes under a throwaway sandbox so the test can never touch the real
`~/.claude` plugins or the real per-session runtime dir:

```bash
SANDBOX="$(mktemp -d)"; trap 'rm -rf "$SANDBOX"' EXIT
export HOME="$SANDBOX/home"; mkdir -p "$HOME"
export CLAUDE_CONFIG_DIR="$HOME/.claude"
```

- Overriding `HOME` isolates **both** the dispatcher's runtime state
  (`$HOME/.claude/read-aloud/<sid>/`) **and** (as a fallback) `claude`'s default
  config dir.
- Setting `CLAUDE_CONFIG_DIR` explicitly pins `claude`'s plugin store into the
  sandbox regardless of how it derives its config path.
- Verified during design: `CLAUDE_CONFIG_DIR=<tmp> claude plugin marketplace
  list` returns a clean "No marketplaces configured", confirming isolation.
- A public GitHub marketplace is a git clone — no auth required — so a fresh,
  empty config dir is sufficient.

### Phase 2 — Preconditions (graceful skip)

The test **skips (exit 0), not fails**, when its external dependencies are
absent, so the default suite stays green offline:

- `command -v claude` missing → print `SKIP: claude CLI not on PATH`, exit 0.
- GitHub unreachable → print `SKIP: GitHub unreachable`, exit 0. Detected via a
  short-timeout `git ls-remote https://github.com/ricardorqr/read-aloud-plugin.git`
  before the marketplace add (and/or by treating a network failure of the
  marketplace-add step as a skip).

Everything after preconditions is a genuine assertion → hard **FAIL** (non-zero
exit) on mismatch.

### Phase 3 — Lifecycle (real CLI calls)

```bash
claude plugin marketplace add ricardorqr/read-aloud-plugin
claude plugin install read-aloud@read-aloud-marketplace
# ... Phase 4 install-assertions ...
claude plugin uninstall read-aloud@read-aloud-marketplace
# ... Phase 4 removal-assertions ...
```

If any CLI call requires a non-interactive/confirm flag in this environment, the
implementation plan resolves it (the manual subagent run executed these
non-interactively without issue, so none is expected).

### Phase 4 — Presence & removal assertions

**After install:**

- `claude plugin list` shows `read-aloud` as enabled.
- Locate the install cache dir under `$CLAUDE_CONFIG_DIR/plugins/cache/…`
  (resolve the versioned path rather than hard-coding a version). Assert it
  exists and contains:
  - **All 7 command files:**
    `commands/{say,play,pause,resume,continue,stop,quiet}.md`
  - **The hook:** `hooks/hooks.json` exists and registers the `Stop` hook
    (grep for `Stop` and `save-response.sh`).
  - **The dispatcher & scripts:** `bin/read-aloud` present and executable;
    `scripts/{save-response.sh,split-sentences.sh,player.sh}` present.

**After uninstall:**

- `claude plugin list` no longer lists `read-aloud`.
- The `installed_plugins.json` entry for `read-aloud@read-aloud-marketplace` is
  gone.
- Cache-dir removal: assert the version dir is removed **or** carries a
  soft-delete marker (`.orphaned_at`). In a fresh sandbox with no other running
  sessions holding `.in_use/<pid>` refs, a hard delete is expected; the marker
  is tolerated to avoid a false failure.

### Phase 5 — Commands actually work

Run the **installed** `bin/read-aloud` (from the cache dir) with a stubbed `say`
so no real audio is produced, and assert exact output strings.

- Stub: write a tiny `say` script that appends its args to a log file, into
  `$SANDBOX/bin`, and prepend that dir to `PATH`.
- Use a fixed test session id (e.g. `export CLAUDE_CODE_SESSION_ID=LIFECYCLE`).
- Seed `$HOME/.claude/read-aloud/LIFECYCLE/response.txt` with a few sentences.
- Assert:
  - `play` → `🔊 Speaking…`
  - `pause` → `⏸ Paused.`
  - `resume` → `▶️ Resumed.`
  - `stop` → `⏹ Stopped.`
  - Empty states: with no `response.txt`, `play` → `Nothing to speak yet.`;
    `resume` when idle → `Nothing to resume.`; `pause`/`stop` when idle →
    `Nothing is playing.`

The playback assertions are timing-sensitive by nature (async player loop). The
test uses the same polling helper pattern as `tests/playback.test.sh` and a
stub `say` that lingers briefly, giving a comfortable margin over the poll
interval. If timing ever flakes, increase the stub linger — do not weaken the
assertions.

## Error handling

- The sandbox is always removed via `trap 'rm -rf "$SANDBOX"' EXIT`.
- Missing `claude` / unreachable GitHub → SKIP (exit 0), never FAIL.
- Any post-precondition assertion mismatch → print `FAIL: <what>` and exit 1.
- On success → print a `PASS:` summary line and exit 0.

## Interfaces & dependencies

- **Consumes:** the `claude` CLI on PATH; network access to GitHub; the
  published `ricardorqr/read-aloud-plugin` marketplace; standard tools already
  used by the suite (`bash`, `jq` optional, `grep`, `awk`, `sed`, `perl` for the
  sub-second sleeps as in the existing tests).
- **Produces:** `tests/lifecycle.test.sh` (executable), auto-discovered by the
  existing `tests/*.test.sh` runner loop.
- **Isolated from:** the real `~/.claude` (via `HOME` + `CLAUDE_CONFIG_DIR`
  overrides).

## Testing

The script is itself the test. Verification during implementation:

1. Run `bash tests/lifecycle.test.sh` on a machine with `claude` + network →
   expect `PASS`.
2. Run with `PATH` scrubbed of `claude` → expect `SKIP: claude CLI not on PATH`,
   exit 0.
3. Confirm the real `~/.claude/plugins` is untouched afterward (the developer's
   installed `read-aloud` stays at its current version — this is the regression
   the manual run violated).
4. Run the full suite `for t in tests/*.test.sh; do bash "$t"; done` → all pass
   (or skip), no `SUITE FAIL`.

## Risks

- **Non-interactive install:** a trust/confirmation prompt could block. Expected
  fine (manual run worked); resolved in the plan if not.
- **Network flakiness / GitHub outage:** mitigated by the SKIP path, so it never
  turns a code change red for an unrelated reason.
- **Publishes lag:** because it installs from GitHub master, a change committed
  locally but not pushed is not what gets tested — by design (this test verifies
  the published artifact, not the working tree).
