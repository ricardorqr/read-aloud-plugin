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
