#!/bin/bash
# Notification hook for Claude Code, Factory Droid and Grok (OMP uses omp/index.ts).
# Hook command: notify.sh claude|droid|grok   (reads the hook event JSON on stdin)
# Title "<Tool> [<folder>]" on a glass banner tinted by class (green, orange,
# blue, red, grey). Each class has its own message and sound:
#   done      "<Tool> task completed"                     fx-ok01.wav
#   failed    "<Tool> task failed"                        Basso
#   question  "<Tool> asks a question"                    Submarine
#   progress  "Claude replied · 2 subagents still running" Tink   (Claude only)
#             "Claude subagent finished · 1 shell still running"
#   quiet     "Claude scheduled check" / "Claude monitor event"   no sound
# Every notification is logged to ~/Library/Logs/agent-notify.log.
# NOTIFY_DRY_RUN=1 prints "<class>|<title>|<message>|<sound>" instead of notifying.

tool=${1:-}
case "$tool" in
  claude) name=Claude ask=AskUserQuestion ;;
  droid) name=Droid ask=AskUser ;;
  grok) name=Grok ask=ask_user_question ;;
  *) echo "usage: notify.sh claude|droid|grok" >&2; exit 0 ;;
esac

input=$(cat)
field() { printf '%s' "$input" | /usr/bin/jq -r "($1) // \"\"" 2>/dev/null; }

done_sound="$HOME/.factory/sounds/fx-ok01.wav"
[ -f "$done_sound" ] || done_sound=/System/Library/Sounds/Glass.aiff
class=done sound=$done_sound

# Claude only: what started this turn, and which background work is still running.
# A turn can be started by you (human), by a finished background task
# (task_notification), or by a cron/loop job (scheduled); see "turnOrigin" in the
# transcript. Monitors are long-lived watchers, not work, so they don't count.
claude_stop() {
  local transcript origin_line origin summary running
  transcript=$(field .transcript_path)
  # Transcripts reach 150+ MB; the turn's first line is almost always in the last 8 MB.
  if [ -f "$transcript" ]; then
    origin_line=$(tail -c 8000000 "$transcript" | /usr/bin/grep -a '"turnOrigin"' | tail -n 1)
    [ -n "$origin_line" ] || origin_line=$(/usr/bin/grep -a '"turnOrigin"' "$transcript" | tail -n 1)
  fi
  origin=$(printf '%s' "$origin_line" | /usr/bin/jq -r '.turnOrigin // ""' 2>/dev/null)
  running=$(printf '%s' "$input" | /usr/bin/jq -r '
    [(.background_tasks // [])[]
      | select(.status == "running" or .status == "pending")
      | select(.type | IN("monitor", "dream", "auto-mode scan", "memory import", "memory save") | not)]
    | group_by(.type)
    | map("\(length) \(.[0].type)\(if length > 1 then "s" else "" end)")
    | join(", ")' 2>/dev/null)

  case "$origin" in
    scheduled) class=quiet message="$name scheduled check" ;;
    task_notification)
      summary=$(printf '%s' "$origin_line" | /usr/bin/jq -r '
        .message.content | if type == "array" then map(.text? // "") | join(" ") else . end
        | capture("<summary>(?<s>[^<]*)</summary>").s // ""' 2>/dev/null)
      case "$summary" in
        Monitor*) class=quiet message="$name monitor event" ;;
        *) local what=subagent verb=finished
           case "$summary" in
             "Background command"* | "Background shell"*) what="background command" ;;
             "Dynamic workflow"*) what=workflow ;;
           esac
           case "$summary" in *" failed"*) verb=failed ;; esac
           [ -n "$running" ] && class=progress message="$name $what $verb · $running still running" ;;
      esac ;;
    *) [ -n "$running" ] && class=progress message="$name replied · $running still running" ;;
  esac
}

message=
case "$(field .hook_event_name)" in
  Stop)
    # Grok also fires Stop when the session ends; only a finished turn counts.
    if [ "$tool" = grok ] && [ "$(field .reason)" != end_turn ]; then exit 0; fi
    [ "$tool" = claude ] && claude_stop
    # A task_notification turn with nothing left running is the real finish.
    [ -n "$message" ] || message="$name task completed" ;;
  StopFailure) # Droid has no failure event
    class=failed sound=/System/Library/Sounds/Basso.aiff message="$name task failed" ;;
  PreToolUse)
    # Only the tool that asks you a question; permission and idle prompts stay quiet.
    [ "$(field '.tool_name // .toolName')" = "$ask" ] || exit 0
    class=question sound=/System/Library/Sounds/Submarine.aiff message="$name asks a question" ;;
  *) exit 0 ;;
esac
case "$class" in
  progress) sound=/System/Library/Sounds/Tink.aiff ;;
  quiet) sound= ;;
esac

cwd=$(field .cwd)
title="$name [$(basename "${cwd:-$PWD}")]"

if [ -n "${NOTIFY_DRY_RUN:-}" ]; then
  printf '%s|%s|%s|%s\n' "$class" "$title" "$message" "${sound##*/}"
  exit 0
fi

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

log="$HOME/Library/Logs/agent-notify.log"
printf '%s\t%s\t%s\t%s\n' "$(date '+%F %T')" "$class" "$title" "$message" >>"$log" 2>/dev/null
[ "$(wc -l <"$log" 2>/dev/null)" -gt 2000 ] 2>/dev/null && { tail -n 1000 "$log" >"$log.tmp" && mv "$log.tmp" "$log"; }

# Glass banner tinted by class (bin/notify-overlay, built by install.sh); it stays
# up a few seconds, so it runs detached. Without it, the plain macOS banner.
# Title and message go in as argv, never into script source.
overlay="$(dirname "$0")/bin/notify-overlay"
if [ -x "$overlay" ]; then
  case "$tool" in
    droid) icon=/Applications/Factory.app ;;
    grok) icon="/Applications/Grok Bot.app" ;;
    *) icon=claude ;;
  esac
  slot=$(pgrep -x notify-overlay | wc -l | tr -d ' ')
  nohup "$overlay" "$class" "$title" "$message" "$icon" "$slot" >/dev/null 2>&1 &
else
  /usr/bin/osascript - "$message" "$title" >/dev/null 2>&1 <<'APPLESCRIPT'
on run argv
  display notification (item 1 of argv) with title (item 2 of argv)
end run
APPLESCRIPT
fi
[ -n "$sound" ] && /usr/bin/afplay "$sound" >/dev/null 2>&1

[ "$tool" = claude ] && printf '{"suppressOutput":true}'
exit 0
