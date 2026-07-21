## [1.1.1](https://github.com/ricardorqr/read-aloud-plugin/compare/v1.1.0...v1.1.1) (2026-07-21)

### Bug Fixes

* guard lifecycle test sandbox against mktemp failure ([1fc5e1c](https://github.com/ricardorqr/read-aloud-plugin/commit/1fc5e1cb989a8b553f1b5425f158e49673d681eb))

# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.1.0] - 2026-07-18

### Changed
- **Reliable `/pause` and `/resume`.** Playback now speaks the response one
  sentence at a time via a detached per-session player loop, controlled by PID,
  instead of one `say` process paused with `SIGSTOP`/`SIGCONT` (which macOS
  CoreAudio would not reliably resume). `/pause` stops immediately; `/resume`
  replays the interrupted sentence. Also retires the global `killall say`, so
  controlling one session no longer affects another.
- Saved state moved to `~/.claude/read-aloud/<session_id>/`.

## [1.0.1] - 2026-07-18

### Fixed
- **Multi-session isolation.** `/say` and `/play` could speak a *different*
  open session's response, because the last response was saved to a single
  shared file that every session's `Stop` hook overwrote. The saved response is
  now keyed per session (`read-aloud-last-response-<session_id>.txt`), so each
  session speaks its own last response. Added `tests/session-isolation.test.sh`
  covering the regression.

## [1.0.0] - 2026-07-17

### Added
- Initial release of the **read-aloud** plugin.
- Voice-control commands: `/say` and `/play` (speak the last response),
  `/pause`, `/resume` and `/continue`, `/stop` and `/quiet`.
- A `Stop` hook that saves each of Claude's responses so they can be replayed,
  skipping the plugin's own voice-control confirmations so they never overwrite
  the real answer.
- Marketplace manifest so the plugin is installable via Claude Code.

[1.1.0]: https://github.com/ricardorqr/read-aloud-plugin/releases/tag/v1.1.0
[1.0.1]: https://github.com/ricardorqr/read-aloud-plugin/releases/tag/v1.0.1
[1.0.0]: https://github.com/ricardorqr/read-aloud-plugin/releases/tag/v1.0.0
