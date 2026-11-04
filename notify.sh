#!/bin/bash
# Notification hook for Claude Code, Factory Droid, Grok and Codex (OMP uses omp/index.ts).
# Hook command: notify.sh claude|droid|grok|codex   (reads the hook event JSON on stdin)
# Title "<Tool> [<folder>]" on a glass banner tinted by class (green, orange,
# blue, red, grey). Each class has its own message and sound:
#   done      "<Tool> task completed"                     fx-ok01.wav
#   failed    "<Tool> task failed"                        Basso
#   question  "<Tool> asks a question"                    Submarine
#   progress  "Claude replied · 2 subagents still running" Tink   (all but OMP's own copy in omp/)
#             "Droid subagent finished · 1 shell still running"
#   quiet     "Claude scheduled check" / "Claude monitor event" / "Codex goal step"   no sound
#             (Grok has all three)
# Every notification is logged to ~/Library/Logs/agent-notify.log.
# NOTIFY_DRY_RUN=1 prints "<class>|<title>|<message>|<sound>" instead of notifying.

# Banner mode: auto (fades out) or sticky (stays until you swipe or close it).
mode_file="${XDG_CONFIG_HOME:-$HOME/.config}/agent-notification-sound/mode"
if [ "${1:-}" = mode ]; then
  case "${2:-}" in
    auto | sticky) mkdir -p "$(dirname "$mode_file")" && echo "$2" >"$mode_file" ;;
    "") ;;
    *) echo "usage: notify.sh mode [auto|sticky]" >&2; exit 2 ;;
  esac
  cat "$mode_file" 2>/dev/null || echo auto
  exit 0
fi

tool=${1:-}
case "$tool" in
  claude) name=Claude ask=AskUserQuestion ;;
  droid) name=Droid ask=AskUser ;;
  grok) name=Grok ask=ask_user_question ;;
  codex) name=Codex ask=request_user_input ;;
  *) echo "usage: notify.sh claude|droid|grok|codex   or   notify.sh mode [auto|sticky]" >&2; exit 0 ;;
esac

input=$(cat)
field() { printf '%s' "$input" | /usr/bin/jq -r "($1) // \"\"" 2>/dev/null; }

if [ "$tool" = codex ]; then
  # Only the terminal app: `codex exec` runs scripted (Claude uses it as a
  # reviewer) and the ChatGPT/Codex desktop app shows its own notifications.
  transcript=$(field .transcript_path)
  if [ -f "$transcript" ]; then
    case "$(head -n 1 "$transcript" | /usr/bin/jq -r '.payload.originator // ""' 2>/dev/null)" in
      "" | codex-tui | codex_cli_rs) ;;
      *) exit 0 ;;
    esac
  fi
  # Codex hooks don't list running subagents, so keep one file per running
  # subagent (SubagentStart adds it, SubagentStop removes it). Silent events.
  agents_dir="${CODEX_AGENTS_DIR:-$HOME/Library/Caches/agent-notify/codex}/$(field .session_id)"
  case "$(field .hook_event_name)" in
    SubagentStart) mkdir -p "$agents_dir" && touch "$agents_dir/$(field .agent_id | tr '/' '_')"; exit 0 ;;
    SubagentStop) rm -f "$agents_dir/$(field .agent_id | tr '/' '_')"; exit 0 ;;
  esac
fi

done_sound="$HOME/.factory/sounds/fx-ok01.wav"
[ -f "$done_sound" ] || done_sound=/System/Library/Sounds/Glass.aiff
class=done sound=$done_sound

# What started this turn and which background work is still running. Each
# reader sets: origin = human | scheduled | monitor | finished (a background
# task ended), what/verb for a finished task, and running ("2 subagents, 1 shell").

# Claude: "turnOrigin" in the transcript (human, task_notification, scheduled)
# and background_tasks in the Stop input. Monitors are long-lived watchers, not
# work, so they don't count.
claude_stop() {
  local transcript origin_line summary
  transcript=$(field .transcript_path)
  # Transcripts reach 150+ MB; the turn's first line is almost always in the last 8 MB.
  if [ -f "$transcript" ]; then
    origin_line=$(tail -c 8000000 "$transcript" | /usr/bin/grep -a '"turnOrigin"' | tail -n 1)
    [ -n "$origin_line" ] || origin_line=$(/usr/bin/grep -a '"turnOrigin"' "$transcript" | tail -n 1)
  fi
  running=$(printf '%s' "$input" | /usr/bin/jq -r '
    [(.background_tasks // [])[]
      | select(.status == "running" or .status == "pending")
      | select(.type | IN("monitor", "dream", "auto-mode scan", "memory import", "memory save") | not)]
    | group_by(.type)
    | map("\(length) \(.[0].type)\(if length > 1 then "s" else "" end)")
    | join(", ")' 2>/dev/null)
  case "$(printf '%s' "$origin_line" | /usr/bin/jq -r '.turnOrigin // ""' 2>/dev/null)" in
    scheduled) origin=scheduled ;;
    task_notification)
      summary=$(printf '%s' "$origin_line" | /usr/bin/jq -r '
        .message.content | if type == "array" then map(.text? // "") | join(" ") else . end
        | capture("<summary>(?<s>[^<]*)</summary>").s // ""' 2>/dev/null)
      origin=finished
      case "$summary" in
        Monitor*) origin=monitor ;;
        "Background command"* | "Background shell"*) what="background command" ;;
        "Dynamic workflow"*) what=workflow ;;
      esac
      case "$summary" in *" failed"*) verb=failed ;; esac ;;
  esac
}

# Droid: the last real user message in the transcript. Finished background
# work arrives as "execute-completion:…" (command) or "Background task
# completed." (subagent); a Loop/cron prompt is a plain message whose text is
# the prompt of one of this session's crons. Still running: this session's
# entries in background-processes.json (pid alive) and running background
# subagents in task-invocations.json.
droid_stop() {
  local fdir=${FACTORY_DIR:-$HOME/.factory} sid transcript last id text f
  sid=$(field .session_id) transcript=$(field .transcript_path)
  if [ -f "$transcript" ]; then
    last=$(tail -c 8000000 "$transcript" | /usr/bin/jq -c -R 'fromjson? | select(.type == "message" and .message.role == "user")
      | (.message.content | if type == "array" then . else [{type: "text", text: .}] end) as $c
      | select(any($c[]; .type == "tool_result") | not)
      | [$c[] | select(.type == "text") | .text | select(startswith("<system-reminder>") | not)] as $t
      | select(($t | length) > 0)
      | select(.id | test("^(context-|__internal__|todo-|mcp-auth|tool-catalog)") | not)
      | {id, text: $t[-1]}' 2>/dev/null | tail -n 1)
    id=$(printf '%s' "$last" | /usr/bin/jq -r '.id // ""' 2>/dev/null)
    text=$(printf '%s' "$last" | /usr/bin/jq -r '.text // ""' 2>/dev/null)
  fi
  case "$id:$text" in
    execute-completion:*)
      origin=finished what="background command"
      case "$text" in *"exit_status: 0"*) ;; *exit_status:*) verb=failed ;; esac ;;
    *:"Background task completed."*)
      origin=finished
      case "$text" in *"reason: completed"*) ;; *reason:*) verb=failed ;; esac ;;
    *)
      for f in "$fdir"/crons/*/"$sid"/*.json; do
        [ -f "$f" ] && [ -n "$text" ] &&
          [ "$(/usr/bin/jq -r '.payload.prompt // ""' "$f" 2>/dev/null)" = "$text" ] && { origin=scheduled; break; }
      done ;;
  esac
  local shells=0 agents pid
  for pid in $(/usr/bin/jq -r --arg s "$sid" '.processes[]? | select(.sessionId == $s) | .pid' "$fdir/background-processes.json" 2>/dev/null); do
    kill -0 "$pid" 2>/dev/null && shells=$((shells + 1))
  done
  agents=$(/usr/bin/jq -r --arg s "$sid" '[.invocations[]? | select(.parentSessionId == $s and .status == "running")] | length' "$fdir/task-invocations.json" 2>/dev/null)
  running=$( { [ "${agents:-0}" -gt 0 ] && printf '%s subagent%s\n' "$agents" "$([ "$agents" -gt 1 ] && echo s)"
               [ "$shells" -gt 0 ] && printf '%s shell%s\n' "$shells" "$([ "$shells" -gt 1 ] && echo s)"; } | paste -sd, - | sed 's/,/, /g')
}

# Grok: chat_history.jsonl (next to transcriptPath) tags turns Grok started
# itself with synthetic_reason (see SyntheticReason in grok-build's
# xai-grok-sampling-types/src/conversation.rs): task_completed (background
# command), subagent_completed, notification_drain (monitor events or commands
# that ended while idle), scheduler_fired (/loop), goal_summary and
# goal_classifier_nudge (/goal steps). The Stop input lists running work in
# backgroundTasks (camelCase).
grok_stop() {
  local chat line reason text
  chat="$(dirname "$(field '.transcriptPath // .transcript_path')")/chat_history.jsonl"
  [ -f "$chat" ] && line=$(tail -c 8000000 "$chat" | /usr/bin/grep -a '"prompt_index"' | tail -n 1)
  reason=$(printf '%s' "$line" | /usr/bin/jq -r '.synthetic_reason // ""' 2>/dev/null)
  text=$(printf '%s' "$line" | /usr/bin/jq -r '.content | if type == "array" then map(.text? // "") | join(" ") else . end' 2>/dev/null)
  case "$reason" in
    # Wording from grok-build crates/codegen/xai-grok-tools/src/reminders/task_completion.rs
    task_completed) origin=finished what="background command"
      case "${text%%$'\n'*}" in
        *"(exit code: 0)"*) ;;
        *"(exit code:"*) verb=failed ;;
        *"(terminated by signal"*) verb=stopped ;;
      esac ;;
    subagent_completed) origin=finished
      case "${text%%$'\n'*}" in
        *") completed with failure."*) verb=failed ;;
        *") was cancelled."*) verb=cancelled ;;
      esac ;;
    # Batched monitor events and/or background commands that ended while idle.
    notification_drain)
      case "$text" in *"monitor event"*) origin=monitor ;; *) origin=finished what="background command" ;; esac ;;
    scheduler_fired) origin=scheduled ;;
    goal_summary | goal_classifier_nudge) origin=goal ;;
  esac
  running=$(printf '%s' "$input" | /usr/bin/jq -r '
    [(.backgroundTasks // [])[] | select(.status == "running" or .status == "pending") | select(.type != "monitor")]
    | group_by(.type)
    | map("\(length) \(.[0].type)\(if length > 1 then "s" else "" end)")
    | join(", ")' 2>/dev/null)
}

# Codex: a turn with no UserMessage of its own was started by Codex itself;
# while a /goal is active that is a goal step. Running subagents come from the
# files kept by SubagentStart/SubagentStop (older than 12 h count as stale).
codex_stop() {
  local tid transcript n
  tid=$(field .turn_id) transcript=$(field .transcript_path)
  if [ -f "$transcript" ] && [ -n "$tid" ] &&
     ! /usr/bin/grep -a "\"turn_id\":\"$tid\"" "$transcript" | /usr/bin/grep -aq '"type":"UserMessage"' &&
     [ "$(/usr/bin/grep -a '"thread_goal_updated"' "$transcript" | tail -n 1 | /usr/bin/jq -r '.payload.goal.status // ""' 2>/dev/null)" = active ]; then
    origin=goal
  fi
  if [ -d "$agents_dir" ]; then
    find "$agents_dir" -type f -mmin +720 -delete 2>/dev/null
    n=$(find "$agents_dir" -type f | wc -l | tr -d ' ')
    [ "$n" -gt 0 ] && running="$n subagent$([ "$n" -gt 1 ] && echo s)"
  fi
}

message= origin=human what=subagent verb=finished running=
case "$(field .hook_event_name)" in
  Stop)
    # Grok also fires Stop when the session ends; only a finished turn counts.
    if [ "$tool" = grok ] && [ "$(field .reason)" != end_turn ]; then exit 0; fi
    case "$tool" in claude) claude_stop ;; droid) droid_stop ;; codex) codex_stop ;; grok) grok_stop ;; esac
    case "$origin" in
      scheduled) class=quiet message="$name scheduled check" ;;
      goal) class=quiet message="$name goal step" ;;
      monitor) class=quiet message="$name monitor event" ;;
      finished) [ -n "$running" ] && class=progress message="$name $what $verb · $running still running" ;;
      *) [ -n "$running" ] && class=progress message="$name replied · $running still running" ;;
    esac
    # A finished-task turn with nothing left running is the real finish.
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

# The hook's cwd follows the agent's shell, so after a `cd` into a subfolder it
# names that subfolder. Claude Code and Droid also pass the folder the session
# was opened in, which is the project the title should name.
case "$tool" in
  claude) project=${CLAUDE_PROJECT_DIR:-} ;;
  droid) project=${FACTORY_PROJECT_DIR:-} ;;
  *) project= ;;
esac
cwd=${project:-$(field .cwd)}
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

# Glass banner tinted by class (Agent Notify.app, built by install.sh); it stays
# up a while, so it runs detached. Without it, the plain macOS banner.
# Title and message go in as argv, never into script source.
overlay="${AGENT_NOTIFY_APP:-$HOME/Applications/Agent Notify.app}/Contents/MacOS/notify-overlay"
mode=$(cat "$mode_file" 2>/dev/null); [ "$mode" = sticky ] || mode=auto
if [ -x "$overlay" ]; then
  case "$tool" in
    droid) icon=/Applications/Factory.app ;;
    grok) icon=grok ;;
    codex) icon=codex ;;
    *) icon=claude ;;
  esac
  nohup "$overlay" "$class" "$title" "$message" "$icon" "$mode" >/dev/null 2>&1 &
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
