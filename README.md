# agent-notification-sound

One sound and macOS notification setup for four coding-agent CLIs. Each one says the same three things:

| When | Title | Message | Sound |
|---|---|---|---|
| The agent finishes | `<Tool> [<folder>]` | `<Tool> task completed` | `fx-ok01.wav` |
| The turn dies on an API error | `<Tool> [<folder>]` | `<Tool> task failed` | Basso |
| The agent asks you a question | `<Tool> [<folder>]` | `<Tool> asks a question` | Submarine |

Claude Code adds classes so a ping from background work doesn't sound like the main agent finishing. The hook reads `turnOrigin` from the transcript (what started the turn) and `background_tasks` from the `Stop` input:

| Claude turn | Message | Sound |
|---|---|---|
| Ends while subagents, shells or workflows still run | `Claude replied · 2 subagents still running` | Tink |
| A background task finished, others still run | `Claude subagent finished · 1 shell still running` | Tink |
| A background task finished, nothing left running | `Claude task completed` | `fx-ok01.wav` |
| A cron/loop job ran | `Claude scheduled check` | none (banner only) |
| A Monitor event arrived | `Claude monitor event` | none (banner only) |

Monitors don't count as running work. Every notification is logged to `~/Library/Logs/agent-notify.log`, so you can check what an earlier ping was. `./test.sh` runs every class in dry-run mode (`NOTIFY_DRY_RUN=1`).

| Tool | Wired as | Completed | Failed | Question |
|---|---|---|---|---|
| Claude Code | `notify.sh claude` in `~/.claude/settings.json` | `Stop` | `StopFailure` | `PreToolUse` on `AskUserQuestion` |
| Factory Droid | `notify.sh droid` in `~/.factory/hooks.json` | `Stop` | none (Droid has no failure event) | `PreToolUse` on `AskUser` |
| Grok | `notify.sh grok` in `~/.grok/hooks/agent-notification-sound.json` | `Stop` with `end_turn` | `StopFailure` | `PreToolUse` on `ask_user_question` |
| Oh My Pi | `omp/` extension at `~/.omp/agent/extensions/notification-sound` | `agent_end` | `agent_end` ending in `error` | the `ask` tool |

`fx-ok01.wav` lives in `~/.factory/sounds/`; macOS Glass plays when it is missing. OMP still plays `fx-ok01.wav` for all three of its events.

## Install

```bash
git clone https://github.com/0xRafie/agent-notification-sound ~/agent-notification-sound
~/agent-notification-sound/install.sh
```

Needs macOS and `jq` (`/usr/bin/jq` ships with macOS). The hooks run the scripts in this folder, so keep it where you cloned it and re-run `install.sh` after moving it. Re-running is safe: it replaces older notification hooks and leaves your other hooks alone. Restart running agents afterwards; in Claude Code, opening `/hooks` once is enough.

OMP needs no config. To change its sound, messages or events, see the header of `omp/index.ts`.

This repo replaces `droid-notification-sound` and `omp-notification-sound`.
