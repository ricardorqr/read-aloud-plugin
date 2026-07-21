# Release CI + Lifecycle Test — Design

**Date:** 2026-07-20

**Status:** Source of truth. Supersedes and replaces the earlier standalone
lifecycle-test spec/plan (`2026-07-20-lifecycle-test-design.md` and its plan),
which have been deleted.

## Goal

Two connected deliverables:

1. **Release CI** — a GitHub Actions workflow that, fully automatically on every
   push to `master`, decides the next semantic version from conventional
   commits, stamps that version into every file that carries it, updates the
   changelog, tags the commit, and publishes a **GitHub Release** (the entry
   that populates the *Releases* box in the repo's right/left sidebar). The
   developer never sets a version number by hand.

2. **Lifecycle test** — a repeatable, fully-sandboxed local test
   (`tests/lifecycle.test.sh`) that drives the **real `claude plugin` CLI**
   against the **published GitHub marketplace**: install the newest published
   version → verify every command, hook, and script is present and the commands
   actually work → uninstall → verify every installed file is removed. It never
   touches the developer's real `~/.claude` install.

**How they connect:** CI publishes a new release automatically; afterwards the
developer runs `bash tests/lifecycle.test.sh` locally, which pulls that
freshly-published version from the marketplace and exercises the full
install → verify → uninstall → verify-gone cycle in a throwaway sandbox.

---

## Part 1 — Release CI

### Decisions (locked)

- **Trigger:** push to `master`. No tags to push by hand, no button to click.
- **Flavor:** `semantic-release` in *immediate* mode — a releasable commit
  publishes right away; there is no Release-PR gate.
- **No test gate:** the CI does release automation only. The bash test suite is
  run locally by the developer, not in CI.
- **Versioning is automatic:** the developer never edits a version number. It is
  computed from conventional-commit messages since the last tag (`v1.1.0`).

### Version bump rules (Conventional Commits)

| Commit type on `master`         | Bump    |
| ------------------------------- | ------- |
| `fix:`                          | patch   |
| `feat:`                         | minor   |
| `feat!:` / `BREAKING CHANGE:`   | major   |
| `docs:`, `chore:`, `test:`, …   | none (no release) |

`semantic-release` reads the latest existing tag (`v1.1.0`) and computes the
next version from the commits since it, preserving continuity with the two
hand-made releases (`v1.0.0`, `v1.1.0`).

### What a release does (in order)

1. Analyze commits → compute next version `X.Y.Z` (skip everything if no
   releasable commit is present).
2. Generate release notes from the commits (`conventionalcommits` preset).
3. **Stamp the version into every file that carries it:**
   - `plugins/read-aloud/.claude-plugin/plugin.json` → `version`
   - `CITATION.cff` → `version` **and** `date-released` (currently stale at
     `1.0.0`; this brings it current and keeps it current forever after).
4. Prepend the generated notes to `CHANGELOG.md` (existing hand-written entries
   are preserved untouched below).
5. Commit the changed files back to `master` as
   `chore(release): X.Y.Z [skip ci]`.
6. Create the git tag `vX.Y.Z`.
7. Create/attach the **GitHub Release** for that tag — this is what fills the
   sidebar *Releases* section.

### Files created

- **`.github/workflows/release.yml`** — triggers on `push` to `master`. Grants
  `contents: write` (and `issues: write`, `pull-requests: write` so
  `semantic-release` can comment on released issues/PRs). Checks out with
  `fetch-depth: 0` and `persist-credentials: true`, sets up Node, and runs
  `cycjimmy/semantic-release-action@v4` with `GITHUB_TOKEN` and the extra
  plugins declared via `extra_plugins`.
- **`.releaserc.json`** — the release configuration. Plugin chain:
  1. `@semantic-release/commit-analyzer` (`conventionalcommits` preset)
  2. `@semantic-release/release-notes-generator` (`conventionalcommits` preset)
  3. `@semantic-release/changelog` → `CHANGELOG.md`
  4. `@semantic-release/exec` → `prepareCmd` calls `scripts/set-version.sh`
  5. `@semantic-release/git` → commits `plugin.json`, `CITATION.cff`,
     `CHANGELOG.md` with message `chore(release): ${nextRelease.version}
     [skip ci]`
  6. `@semantic-release/github` → publishes the GitHub Release
- **`scripts/set-version.sh`** — a small, hand-runnable helper the CI calls
  (`scripts/set-version.sh "$VERSION"`). It writes the version into
  `plugin.json` (JSON-safe, via `node -e` or `jq`) and into `CITATION.cff`
  (`version:` + `date-released:` via `sed`), and nothing else. It lives at the
  **repo root `scripts/`** dir — deliberately distinct from the plugin's own
  `plugins/read-aloud/scripts/` (runtime code). It is the CI's "hands"; the
  developer never has to run it, but can, to bump versions manually if ever
  needed.

### Interfaces & isolation

- **Consumes:** `GITHUB_TOKEN` (provided by Actions); Node (installed in the
  workflow); the `cycjimmy/semantic-release-action` and its `extra_plugins`
  (`@semantic-release/changelog`, `@semantic-release/exec`,
  `@semantic-release/git`, `conventional-changelog-conventionalcommits`).
- **`set-version.sh` interface:** input = one arg, the version string
  (`X.Y.Z`, no leading `v`). Effect = edits exactly two files in place. It is
  pure/idempotent given the same version and does no network or git work —
  which is why it is independently testable.
- **Produces:** a git tag, a GitHub Release, and a `chore(release)` commit on
  `master`.

### Error handling & risks

- **Push-back permission:** `master` must allow the action to push the
  `chore(release)` commit — i.e. no branch protection that blocks it, or a
  bypass for `github-actions[bot]`. This is a repo-settings prerequisite, noted
  here and surfaced in the plan.
- **No CI loop:** the push-back uses `GITHUB_TOKEN` and a `[skip ci]` subject.
  Commits made with `GITHUB_TOKEN` do not re-trigger workflows, so the release
  job cannot recurse.
- **No releasable commit → no-op:** pushes that contain only `docs:`/`chore:`/
  `test:` commits produce no version, no tag, no release. Expected and correct.
- **Changelog styling:** `semantic-release`'s generated sections are styled
  slightly differently from the existing hand-written Keep-a-Changelog entries.
  They are coherent and the old entries are preserved; byte-for-byte identical
  formatting is a non-goal.
- **Immediate model:** a stray `feat:`/`fix:` merged to `master` ships a release
  instantly (the chosen flavor). Mitigation is commit discipline, not a gate.

---

## Part 2 — Lifecycle test

A single bash script, `tests/lifecycle.test.sh`, auto-discovered by the existing
`for t in tests/*.test.sh` runner loop — no runner change. It follows the
conventions of the existing tests (`set -u`, `mktemp -d` + `trap` cleanup, a
stub `say` on `PATH`, a `waitfor` polling helper with `perl` sub-second sleeps,
explicit `PASS:`/`FAIL:` lines, non-zero exit on failure).

### Why it exists

The existing `tests/*.test.sh` (split-sentences, player, session-isolation,
playback) exercise the dispatcher and scripts **directly** from the source tree.
They do not cover the **plugin-manager integration** — that a fresh
`claude plugin install` of the *published* artifact yields a working plugin with
all commands and hooks present, and that `claude plugin uninstall` cleanly
removes **every** installed file. That was only ever verified manually, and one
manual run silently downgraded the developer's live plugin. This test makes the
check repeatable and safe.

### Non-goals

- Not hermetic/offline: by decision it installs from GitHub, so it needs network
  + the `claude` binary. It is intentionally an integration/release test.
- Not version-pinned: it asserts that *whatever is currently published* installs
  and works, so it survives every release with no edits. It does **not** install
  a specific "old" version — the marketplace CLI installs latest-from-git, and
  the clean install → verify → uninstall → verify-gone cycle already covers the
  intent ("install the new version, check features; uninstall, check all files
  deleted").
- Does not test Anthropic's `claude plugin` CLI internals — only this plugin's
  installable shape and behavior through that CLI.

### Phase 1 — Isolation (safety core)

All state goes under a throwaway sandbox so the test can never touch the real
`~/.claude` plugins or the real per-session runtime dir:

```bash
SANDBOX="$(mktemp -d)"; trap 'rm -rf "$SANDBOX"' EXIT
export HOME="$SANDBOX/home"; mkdir -p "$HOME"
export CLAUDE_CONFIG_DIR="$HOME/.claude"
```

- Overriding `HOME` isolates both the dispatcher's runtime state
  (`$HOME/.claude/read-aloud/<sid>/`) and, as a fallback, `claude`'s default
  config dir.
- Setting `CLAUDE_CONFIG_DIR` explicitly pins `claude`'s plugin store into the
  sandbox regardless of how it derives its config path.
- A public GitHub marketplace is a git clone — no auth required — so a fresh,
  empty config dir is sufficient.

### Phase 2 — Preconditions (graceful skip)

The test **skips (exit 0), not fails**, when its external dependencies are
absent, so the default suite stays green offline:

- `command -v claude` missing → print `SKIP: claude CLI not on PATH`, exit 0.
- GitHub unreachable → print `SKIP: GitHub unreachable`, exit 0 (detected via a
  short `git ls-remote https://github.com/ricardorqr/read-aloud-plugin.git`, and
  by treating a network failure of the marketplace-add step as a skip).

Everything after preconditions is a genuine assertion → hard **FAIL** (non-zero
exit) on mismatch. All mutating `claude` calls read stdin from `/dev/null` to
avoid hanging on any confirmation prompt.

### Phase 3 — Install + presence assertions (the "new version" install)

```bash
claude plugin marketplace add ricardorqr/read-aloud-plugin </dev/null
claude plugin install read-aloud@read-aloud-marketplace </dev/null
```

Then assert the installed artifact is complete. Resolve the versioned cache dir
by globbing (never hard-code a version):

- `claude plugin list` shows `read-aloud@read-aloud-marketplace`.
- Under `$CLAUDE_CONFIG_DIR/plugins/cache/read-aloud-marketplace/read-aloud/<ver>/`:
  - **All 7 command files:** `commands/{say,play,pause,resume,continue,stop,quiet}.md`
  - **The hook:** `hooks/hooks.json` exists and registers the `Stop` hook
    (grep for `"Stop"` and `save-response.sh`).
  - **The dispatcher & scripts:** `bin/read-aloud` present and executable;
    `scripts/{save-response.sh,split-sentences.sh,player.sh}` present.

### Phase 4 — Features actually work (verify the new version)

Run the **installed** `bin/read-aloud` (from the cache dir) with a stubbed `say`
so no real audio is produced, and assert exact output strings:

- Stub: a tiny `say` script that appends its args to a log and lingers ~0.3s,
  placed in `$SANDBOX/bin` with that dir prepended to `PATH`.
- Fixed test session id (`export CLAUDE_CODE_SESSION_ID=LIFECYCLE`).
- **Empty states** (no `response.txt` yet):
  - `play` → `Nothing to speak yet.`
  - `resume` → `Nothing to resume.`
  - `pause` / `stop` → `Nothing is playing.`
- **Seeded response**, then drive the flow:
  - `play` → `🔊 Speaking…`  (then `waitfor` the stub log to prove speech began)
  - `pause` → `⏸ Paused.`
  - `resume` → `▶️ Resumed.`
  - `stop` → `⏹ Stopped.`

Timing is handled with the same `waitfor` polling pattern as
`tests/playback.test.sh`; the stub lingers 0.3s vs a 0.05s poll (6× margin). If
it ever flakes, increase the stub linger — never weaken the assertions.

### Phase 5 — Uninstall + removal assertions (check all files deleted)

```bash
claude plugin uninstall read-aloud@read-aloud-marketplace </dev/null
```

Assert the plugin and **all its files** are gone:

- `claude plugin list` no longer lists `read-aloud@read-aloud-marketplace`.
- `installed_plugins.json` no longer contains a `read-aloud` entry.
- The versioned cache dir captured in Phase 3 is **removed**, OR carries a
  soft-delete marker (`.orphaned_at`). In a fresh sandbox with no other running
  sessions holding an in-use ref, a hard delete is expected; the marker is
  tolerated to avoid a false failure.

### Error handling

- The sandbox is always removed via `trap 'rm -rf "$SANDBOX"' EXIT`.
- Missing `claude` / unreachable GitHub → SKIP (exit 0), never FAIL.
- Any post-precondition assertion mismatch → `FAIL: <what>`, exit 1.
- On success → `PASS:` summary lines, exit 0.

### Interfaces & dependencies

- **Consumes:** the `claude` CLI on PATH; network to GitHub; the published
  `ricardorqr/read-aloud-plugin` marketplace; `bash`, `grep`, `awk`, `sed`,
  `perl` (sub-second sleeps), `find` (version-agnostic cache resolution).
- **Produces:** `tests/lifecycle.test.sh` (executable), auto-discovered by the
  existing runner loop.
- **Isolated from:** the real `~/.claude` (via `HOME` + `CLAUDE_CONFIG_DIR`).

### Testing the test

1. On a machine with `claude` + network → expect the `PASS:` lines, exit 0.
2. With `PATH` scrubbed of `claude` → expect `SKIP: claude CLI not on PATH`,
   exit 0.
3. Confirm the real `~/.claude/plugins` is untouched afterward (the developer's
   installed `read-aloud` stays at its current version).
4. Run the full suite `for t in tests/*.test.sh; do bash "$t"; done` → all pass
   or skip, no `SUITE FAIL`.

---

## Overall risks

- **Network flakiness / GitHub outage** (Part 2): mitigated by the SKIP path so
  it never turns a code change red for an unrelated reason.
- **Publish lag** (Part 2): the test installs from GitHub `master`, so a local
  commit not yet pushed is not what gets tested — by design.
- **Branch-protection push-back** (Part 1): the release commit must be allowed
  on `master`; a repo-settings prerequisite.
