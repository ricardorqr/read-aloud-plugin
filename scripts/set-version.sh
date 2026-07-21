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
