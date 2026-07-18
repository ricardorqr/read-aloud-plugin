# read-aloud — Claude Code Plugin

A Claude Code plugin that reads Claude's responses **aloud** using macOS
text-to-speech, with full playback control — **play, pause, resume, and stop** —
right from the `/` menu.

Type a command and listen instead of read. Each of Claude's answers is kept
ready, so you can replay the last one any time.

---

## Requirements

- **macOS** — uses the built-in [`say`](https://ss64.com/mac/say.html) command.
- **[`jq`](https://jqlang.github.io/jq/)** — used by the Stop hook to read each
  response. Install with `brew install jq`. If `jq` is missing, the plugin
  simply won't capture new responses (it won't error).

---

## Install

Add the marketplace once, then install the plugin:

```
/plugin marketplace add ricardorqr/read-aloud-plugin
/plugin install read-aloud@read-aloud-marketplace
```

Restart Claude Code (or start a new session) and confirm the voice commands
(`/say`, `/play`, `/pause`, `/resume`, `/continue`, `/stop`, `/quiet`) appear in
the `/` menu.

## Update

```
/plugin marketplace update read-aloud-marketplace
/plugin install read-aloud@read-aloud-marketplace
```

## Uninstall

```
/plugin uninstall read-aloud@read-aloud-marketplace
```

- **Disable instead of remove:** use the `/plugin` menu to toggle it off while
  keeping it installed.

---

## Using it

| Command | What it does |
|---|---|
| `/say`, `/play` | Read Claude's most recent response aloud (restarts cleanly if already playing) |
| `/pause` | Pause playback where it is |
| `/resume`, `/continue` | Resume from where you paused |
| `/stop`, `/quiet` | Stop playback completely |

That's it — ask Claude something, then type `/say` to hear the answer.

---

## How it works

- A **Stop hook** (`scripts/save-response.sh`) runs each time Claude finishes a
  response and saves the text to `~/.claude/read-aloud-last-response.txt`. It
  deliberately **skips the plugin's own voice-control confirmations** (🔊 / ⏸ /
  ▶️ / ⏹) so they never overwrite the real answer you want to hear.
- The voice commands call **`bin/read-aloud`** (added to your `PATH` by Claude
  Code), which drives macOS `say`:
  - `say`/`play` → speak the saved file in the background,
  - `pause` → `SIGSTOP` the `say` process,
  - `resume`/`continue` → `SIGCONT`,
  - `stop`/`quiet` → terminate it.

Because the commands only ever invoke the bundled `read-aloud` script (declared
in each command's `allowed-tools`), they run without touching your other
permissions. If your setup still prompts the first time, choose **"don't ask
again for `read-aloud`"** and it stays quiet after that.

---

## Security & updates

This plugin runs a small bundled shell script on your machine (like any plugin).
It makes **no network connections** — it only reads a local file and runs
`say` / `killall say` (the `killall` is hardcoded to target only `say`).

For the safest posture, keep **auto-update disabled** and pin to a reviewed
commit, so new code only ever arrives when you deliberately update. See
[`CHANGELOG.md`](CHANGELOG.md) for what changed in each version.

---

## Repo layout

```
read-aloud-plugin/
├── .claude-plugin/
│   └── marketplace.json                 # marketplace manifest (lists the plugin)
└── plugins/
    └── read-aloud/
        ├── .claude-plugin/
        │   └── plugin.json              # plugin manifest (name, version, keywords)
        ├── bin/
        │   └── read-aloud               # voice-control dispatcher (on PATH)
        ├── scripts/
        │   └── save-response.sh         # Stop-hook helper (saves last response)
        ├── hooks/
        │   └── hooks.json               # registers the Stop hook
        └── commands/
            ├── say.md   play.md         # speak the last response
            ├── pause.md                 # pause
            ├── resume.md continue.md    # resume
            └── stop.md  quiet.md        # stop
```

## Maintaining

- Edit the voice logic in `plugins/read-aloud/bin/read-aloud` and the save logic
  in `plugins/read-aloud/scripts/save-response.sh`.
- Add or rename commands under `plugins/read-aloud/commands/`.
- Bump `version` in `plugins/read-aloud/.claude-plugin/plugin.json` and add a
  `CHANGELOG.md` entry on each change so installs can pull updates.
- Push to GitHub, then run the **Update** commands above.
