# agent-notification-sound

One sound and macOS notification setup for four coding-agent CLIs. Each one says the same three things:

| When | Title | Message |
|---|---|---|
| The agent finishes | `<Tool> [<folder>]` | `<Tool> task completed` |
| The turn dies on an API error | `<Tool> [<folder>]` | `<Tool> task failed` |
| The agent asks you a question | `<Tool> [<folder>]` | `<Tool> asks a question` |

Permission prompts, idle pings, other tool calls and turns you interrupt stay quiet.

| Tool | Wired as | Completed | Failed | Question |
|---|---|---|---|---|
| Claude Code | `notify.sh claude` in `~/.claude/settings.json` | `Stop` | `StopFailure` | `PreToolUse` on `AskUserQuestion` |
| Factory Droid | `notify.sh droid` in `~/.factory/hooks.json` | `Stop` | none (Droid has no failure event) | `PreToolUse` on `AskUser` |
| Grok | `notify.sh grok` in `~/.grok/hooks/agent-notification-sound.json` | `Stop` with `end_turn` | `StopFailure` | `PreToolUse` on `ask_user_question` |
| Oh My Pi | `omp/` extension at `~/.omp/agent/extensions/notification-sound` | `agent_end` | `agent_end` ending in `error` | the `ask` tool |

The sound is `~/.factory/sounds/fx-ok01.wav`, or macOS Glass when that file is missing.

## Install

```bash
git clone https://github.com/0xRafie/agent-notification-sound ~/agent-notification-sound
~/agent-notification-sound/install.sh
```

Needs macOS and `jq` (`/usr/bin/jq` ships with macOS). The hooks run the scripts in this folder, so keep it where you cloned it and re-run `install.sh` after moving it. Re-running is safe: it replaces older notification hooks and leaves your other hooks alone. Restart running agents afterwards; in Claude Code, opening `/hooks` once is enough.

OMP needs no config. To change its sound, messages or events, see the header of `omp/index.ts`.

This repo replaces `droid-notification-sound` and `omp-notification-sound`.
