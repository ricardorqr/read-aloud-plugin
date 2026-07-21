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
