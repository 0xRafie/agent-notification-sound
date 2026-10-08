#!/bin/bash
# Notification hook for Claude Code, Factory Droid and Grok (OMP uses omp/index.ts).
# Hook command: notify.sh claude|droid|grok   (reads the hook event JSON on stdin)
# Title "<Tool> [<folder>]", message "<Tool> task completed" | "task failed" | "asks a question".

tool=${1:-}
case "$tool" in
  claude) name=Claude ask=AskUserQuestion ;;
  droid) name=Droid ask=AskUser ;;
  grok) name=Grok ask=ask_user_question ;;
  *) echo "usage: notify.sh claude|droid|grok" >&2; exit 0 ;;
esac

input=$(cat)
field() { printf '%s' "$input" | /usr/bin/jq -r "($1) // \"\"" 2>/dev/null; }

case "$(field .hook_event_name)" in
  Stop)
    # Grok also fires Stop when the session ends; only a finished turn counts.
    if [ "$tool" = grok ] && [ "$(field .reason)" != end_turn ]; then exit 0; fi
    message="$name task completed" ;;
  StopFailure) # Droid has no failure event
    message="$name task failed" ;;
  PreToolUse)
    # Only the tool that asks you a question; permission and idle prompts stay quiet.
    [ "$(field '.tool_name // .toolName')" = "$ask" ] || exit 0
    message="$name asks a question" ;;
  *) exit 0 ;;
esac

# Other harnesses can replay ~/.claude/settings.json hooks; only notify when
# Claude Code itself is an ancestor of this hook.
if [ "$tool" = claude ]; then
  pid=$PPID
  until [ "${pid:-1}" -le 1 ]; do
    case "$(ps -p "$pid" -o command= 2>/dev/null)" in claude | claude\ * | */claude | */claude\ *) break ;; esac
    pid=$(ps -p "$pid" -o ppid= 2>/dev/null | tr -d ' ')
  done
  [ "${pid:-1}" -gt 1 ] || exit 0
fi

cwd=$(field .cwd)
sound="$HOME/.factory/sounds/fx-ok01.wav"
[ -f "$sound" ] || sound=/System/Library/Sounds/Glass.aiff

# Title and message go in as argv, never into the AppleScript source: a stray
# quote or backslash would break the script and the notification would vanish.
/usr/bin/osascript - "$message" "$name [$(basename "${cwd:-$PWD}")]" >/dev/null 2>&1 <<'APPLESCRIPT'
on run argv
  display notification (item 1 of argv) with title (item 2 of argv)
end run
APPLESCRIPT
/usr/bin/afplay "$sound" >/dev/null 2>&1

[ "$tool" = claude ] && printf '{"suppressOutput":true}'
exit 0
