# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.0.0] - 2026-07-17

### Added
- Initial release of the **read-aloud** plugin.
- Voice-control commands: `/say` and `/play` (speak the last response),
  `/pause`, `/resume` and `/continue`, `/stop` and `/quiet`.
- A `Stop` hook that saves each of Claude's responses so they can be replayed,
  skipping the plugin's own voice-control confirmations so they never overwrite
  the real answer.
- Marketplace manifest so the plugin is installable via Claude Code.

[1.0.0]: https://github.com/ricardorqr/read-aloud-plugin/releases/tag/v1.0.0
