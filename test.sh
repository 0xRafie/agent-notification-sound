#!/bin/bash
# Usage: test.sh  — feeds synthetic hook inputs to notify.sh in dry-run mode.
N=~/agent-notification-sound/notify.sh; fail=0; d=$(mktemp -d)
unset CLAUDE_PROJECT_DIR FACTORY_PROJECT_DIR # set when the tests run inside an agent
mk() { printf '%s\n' '{"type":"assistant"}' "$1" '{"type":"user","message":{"content":[{"type":"tool_result"}]}}' >"$d/$2.jsonl"; }
mk '{"type":"user","turnOrigin":"human","message":{"content":"halo"}}' human
mk '{"type":"user","turnOrigin":"scheduled","isMeta":true,"message":{"content":"If the task..."}}' sched
mk '{"type":"user","turnOrigin":"task_notification","message":{"content":"<task-notification><task-id>a1</task-id><status>completed</status><summary>Agent \"Review\" finished</summary></task-notification>"}}' agent
mk '{"type":"user","turnOrigin":"task_notification","message":{"content":[{"type":"text","text":"<task-notification><summary>Background command \"x\" completed (exit code 0)</summary>"}]}}' bash
mk '{"type":"user","turnOrigin":"task_notification","message":{"content":"<task-notification><summary>Agent \"x\" failed: limit</summary>"}}' agentfail
mk '{"type":"user","turnOrigin":"task_notification","message":{"content":"<task-notification><task-id>m</task-id><summary>Monitor event: \"poller\"</summary><event>ok</event>"}}' monitor
mk '{"type":"user","turnOrigin":"task_notification","message":{"content":"<task-notification><summary>Dynamic workflow \"w\" completed</summary>"}}' wf
BG2='[{"id":"a","type":"subagent","status":"running"},{"id":"b","type":"subagent","status":"running"},{"id":"m","type":"monitor","status":"running"},{"id":"c","type":"shell","status":"completed"}]'
BG1='[{"id":"s","type":"shell","status":"running"},{"id":"m","type":"monitor","status":"running"}]'
MON='[{"id":"m","type":"monitor","status":"running"}]'
# Expectations name the macOS sounds; on Linux the hooks use freedesktop ones.
snd() { if [ "$(uname -s)" = Linux ]; then printf '%s' "$1" | sed -e 's/Basso\.aiff/dialog-error.oga/' \
  -e 's/Submarine\.aiff/message-new-instant.oga/' -e 's/Tink\.aiff/message.oga/' -e 's/Glass\.aiff/complete.oga/'; else printf '%s' "$1"; fi; }
t() { # name tool json expected
  got=$(printf '%s' "$3" | NOTIFY_DRY_RUN=1 bash "$N" "$2"); want=$(snd "$4")
  if [ "$got" = "$want" ]; then echo "ok   $1"; else echo "FAIL $1"; echo "     want: $want"; echo "     got:  $got"; fail=1; fi; }
S() { printf '{"hook_event_name":"Stop","cwd":"/x/proj","transcript_path":"%s","background_tasks":%s}' "$d/$1.jsonl" "${2:-[]}"; }
t "human done"            claude "$(S human)"            "done|Claude [proj]|Claude task completed|fx-ok01.wav"
t "human, monitor only"   claude "$(S human "$MON")"     "done|Claude [proj]|Claude task completed|fx-ok01.wav"
t "human, agents running" claude "$(S human "$BG2")"     "progress|Claude [proj]|Claude replied · 2 subagents still running|Tink.aiff"
t "agent done, 1 left"    claude "$(S agent "$BG1")"     "progress|Claude [proj]|Claude subagent finished · 1 shell still running|Tink.aiff"
t "agent done, none left" claude "$(S agent)"            "done|Claude [proj]|Claude task completed|fx-ok01.wav"
t "bash done, 2 left"     claude "$(S bash "$BG2")"      "progress|Claude [proj]|Claude background command finished · 2 subagents still running|Tink.aiff"
t "agent failed, 1 left"  claude "$(S agentfail "$BG1")" "progress|Claude [proj]|Claude subagent failed · 1 shell still running|Tink.aiff"
t "workflow, 1 left"      claude "$(S wf "$BG1")"        "progress|Claude [proj]|Claude workflow finished · 1 shell still running|Tink.aiff"
t "monitor event"         claude "$(S monitor "$BG1")"   "quiet|Claude [proj]|Claude monitor event|"
t "scheduled"             claude "$(S sched)"            "quiet|Claude [proj]|Claude scheduled check|"
t "no transcript"         claude '{"hook_event_name":"Stop","cwd":"/x/proj"}' "done|Claude [proj]|Claude task completed|fx-ok01.wav"
t "failure"               claude '{"hook_event_name":"StopFailure","cwd":"/x/proj"}' "failed|Claude [proj]|Claude task failed|Basso.aiff"
t "question"              claude '{"hook_event_name":"PreToolUse","tool_name":"AskUserQuestion","cwd":"/x/proj"}' "question|Claude [proj]|Claude asks a question|Submarine.aiff"
CLAUDE_PROJECT_DIR=/x/edw t "project, not cwd" claude '{"hook_event_name":"Stop","cwd":"/x/edw/methods"}' "done|Claude [edw]|Claude task completed|fx-ok01.wav"
t "cwd without project"   claude '{"hook_event_name":"Stop","cwd":"/x/edw/methods"}' "done|Claude [methods]|Claude task completed|fx-ok01.wav"
FACTORY_PROJECT_DIR=/x/edw t "droid project"   droid '{"hook_event_name":"Stop","cwd":"/x/edw/methods"}' "done|Droid [edw]|Droid task completed|fx-ok01.wav"
t "other tool silent"     claude '{"hook_event_name":"PreToolUse","tool_name":"Bash","cwd":"/x/proj"}' ""
t "droid done"            droid  '{"hook_event_name":"Stop","cwd":"/x/proj"}' "done|Droid [proj]|Droid task completed|fx-ok01.wav"
t "grok session end"      grok   '{"hook_event_name":"Stop","reason":"other","cwd":"/x/proj"}' ""
t "grok question"         grok   '{"hook_event_name":"PreToolUse","tool_name":"ask_user_question","cwd":"/x/proj"}' "question|Grok [proj]|Grok asks a question|Submarine.aiff"
# Droid: transcript lines + a fake ~/.factory (FACTORY_DIR) with crons, subagents and processes.
F="$d/factory"; mkdir -p "$F/crons/-x-proj/sid1"
printf '%s\n' '{"version":1,"id":"c1","payload":{"prompt":"Laporkan progres"}}' >"$F/crons/-x-proj/sid1/c1.json"
dm() { printf '%s\n' '{"type":"message","id":"u0","message":{"role":"user","content":[{"type":"text","text":"<system-reminder>x</system-reminder>"}]}}' "$1" \
  '{"type":"message","id":"context-1","message":{"role":"user","content":[{"type":"text","text":"ctx"}]}}' \
  '{"type":"message","id":"t1","message":{"role":"user","content":[{"type":"tool_result","content":"r"}]}}' >"$d/$2.jsonl"; }
dm '{"type":"message","id":"a1","message":{"role":"user","content":[{"type":"text","text":"halo droid"}]}}' dhuman
dm '{"type":"message","id":"a2","message":{"role":"user","content":[{"type":"text","text":"Laporkan progres"}]}}' dcron
dm '{"type":"message","id":"execute-completion:call_1","message":{"role":"user","content":[{"type":"text","text":"Background Execute command finished.\nexit_status: 0"}]}}' dexec
dm '{"type":"message","id":"task-9","message":{"role":"user","content":[{"type":"text","text":"Background task completed. task_id: x reason: failed"}]}}' dtask
idle() { printf '{"processes":[]}' >"$F/background-processes.json"; printf '{"invocations":[]}' >"$F/task-invocations.json"; }
busy() { sleep 30 & SLEEPER=$!
  printf '{"processes":[{"pid":%s,"sessionId":"sid1"},{"pid":%s,"sessionId":"other"},{"pid":999999,"sessionId":"sid1"}]}' $SLEEPER $SLEEPER >"$F/background-processes.json"
  printf '{"invocations":[{"parentSessionId":"sid1","status":"running"},{"parentSessionId":"sid1","status":"running"},{"parentSessionId":"sid1","status":"completed"}]}' >"$F/task-invocations.json"; }
D() { printf '{"hook_event_name":"Stop","cwd":"/x/proj","session_id":"sid1","transcript_path":"%s"}' "$d/$1.jsonl"; }
export FACTORY_DIR=$F
idle
t "droid human done"      droid "$(D dhuman)" "done|Droid [proj]|Droid task completed|fx-ok01.wav"
t "droid cron"            droid "$(D dcron)"  "quiet|Droid [proj]|Droid scheduled check|"
t "droid exec, none left" droid "$(D dexec)"  "done|Droid [proj]|Droid task completed|fx-ok01.wav"
busy
t "droid human, busy"     droid "$(D dhuman)" "progress|Droid [proj]|Droid replied · 2 subagents, 1 shell still running|Tink.aiff"
t "droid exec, busy"      droid "$(D dexec)"  "progress|Droid [proj]|Droid background command finished · 2 subagents, 1 shell still running|Tink.aiff"
t "droid task failed"     droid "$(D dtask)"  "progress|Droid [proj]|Droid subagent failed · 2 subagents, 1 shell still running|Tink.aiff"
kill $SLEEPER 2>/dev/null; unset FACTORY_DIR
# Codex: rollout fixtures (first line = originator) and a fake subagent dir.
export CODEX_AGENTS_DIR="$d/codex-agents"
cx() { # name originator goal-status user-turn?
  { printf '{"type":"session_meta","payload":{"originator":"%s"}}\n' "$2"
    [ -n "$3" ] && printf '{"type":"event_msg","payload":{"type":"thread_goal_updated","goal":{"status":"%s"}}}\n' "$3"
    [ "$4" = yes ] && printf '{"type":"event_msg","payload":{"type":"item_completed","turn_id":"T1","item":{"type":"UserMessage"}}}\n'
    printf '{"type":"event_msg","payload":{"type":"task_started","turn_id":"T1"}}\n'; } >"$d/$1.jsonl"; }
cx ctui codex-tui "" yes; cx cexec codex_exec "" yes; cx cdesk "Codex Desktop" "" yes; cx cgoal codex-tui active no; cx cgoaldone codex-tui complete no
C() { printf '{"hook_event_name":"%s","cwd":"/x/proj","session_id":"S1","turn_id":"T1","agent_id":"%s","tool_name":"%s","transcript_path":"%s"}' "$1" "${3:-}" "${4:-}" "$d/$2.jsonl"; }
t "codex done"            codex "$(C Stop ctui)"      "done|Codex [proj]|Codex task completed|fx-ok01.wav"
t "codex exec silent"     codex "$(C Stop cexec)"     ""
t "codex desktop silent"  codex "$(C Stop cdesk)"     ""
t "codex goal step"       codex "$(C Stop cgoal)"     "quiet|Codex [proj]|Codex goal step|"
t "codex goal finished"   codex "$(C Stop cgoaldone)" "done|Codex [proj]|Codex task completed|fx-ok01.wav"
t "codex question"        codex "$(C PreToolUse ctui "" request_user_input)" "question|Codex [proj]|Codex asks a question|Submarine.aiff"
t "codex other tool"      codex "$(C PreToolUse ctui "" Bash)" ""
t "codex subagent start"  codex "$(C SubagentStart ctui A1)" ""
printf '%s' "$(C SubagentStart ctui A2)" | NOTIFY_DRY_RUN=1 bash "$N" codex
t "codex 2 running"       codex "$(C Stop ctui)"      "progress|Codex [proj]|Codex replied · 2 subagents still running|Tink.aiff"
t "codex subagent stop"   codex "$(C SubagentStop ctui A1)" ""
t "codex 1 running"       codex "$(C Stop ctui)"      "progress|Codex [proj]|Codex replied · 1 subagent still running|Tink.aiff"
printf '%s' "$(C SubagentStop ctui A2)" | NOTIFY_DRY_RUN=1 bash "$N" codex
t "codex none running"    codex "$(C Stop ctui)"      "done|Codex [proj]|Codex task completed|fx-ok01.wav"
unset CODEX_AGENTS_DIR
# Grok: chat_history.jsonl next to transcriptPath, camelCase backgroundTasks.
gk() { mkdir -p "$d/grok-$1"; printf '%s\n' '{"type":"user","prompt_index":0,"content":[{"type":"text","text":"hi"}]}' "$2" \
  '{"type":"assistant","content":"ok"}' >"$d/grok-$1/chat_history.jsonl"; : >"$d/grok-$1/updates.jsonl"; }
gk human '{"type":"user","prompt_index":1,"content":[{"type":"text","text":"fix it"}]}'
gk task '{"type":"user","prompt_index":1,"synthetic_reason":"task_completed","content":[{"type":"text","text":"Background task \"x\" completed (exit code: 1)."}]}'
gk sub '{"type":"user","prompt_index":1,"synthetic_reason":"subagent_completed","content":[{"type":"text","text":"<system-reminder>\nBackground subagent \"s1\" (explore: \"find x\") completed successfully.\nfailed tests: none"}]}'
gk subfail '{"type":"user","prompt_index":1,"synthetic_reason":"subagent_completed","content":[{"type":"text","text":"Background subagent \"s2\" (general: \"fix\") completed with failure.\n"}]}'
gk sig '{"type":"user","prompt_index":1,"synthetic_reason":"task_completed","content":[{"type":"text","text":"Background task \"t\" completed (terminated by signal SIGTERM).\n"}]}'
gk mon '{"type":"user","prompt_index":1,"synthetic_reason":"notification_drain","content":[{"type":"text","text":"2 monitor events"}]}'
gk drain '{"type":"user","prompt_index":1,"synthetic_reason":"notification_drain","content":[{"type":"text","text":"<system-reminder>\nBackground task \"t\" completed (exit code: 0).\n"}]}'
gk gsum '{"type":"user","prompt_index":1,"synthetic_reason":"goal_summary","content":[{"type":"text","text":"summarize progress"}]}'
gk cron '{"type":"user","prompt_index":1,"synthetic_reason":"scheduler_fired","content":[{"type":"text","text":"check"}]}'
gk goal '{"type":"user","prompt_index":1,"synthetic_reason":"goal_classifier_nudge","content":[{"type":"text","text":"keep going"}]}'
G() { printf '{"hook_event_name":"Stop","reason":"end_turn","cwd":"/x/proj","transcriptPath":"%s","backgroundTasks":%s}' "$d/grok-$1/updates.jsonl" "${2:-[]}"; }
GB='[{"id":"a","type":"subagent","status":"running"},{"id":"b","type":"shell","status":"running"},{"id":"m","type":"monitor","status":"running"}]'
t "grok done"             grok "$(G human)"       "done|Grok [proj]|Grok task completed|fx-ok01.wav"
t "grok replied, busy"    grok "$(G human "$GB")" "progress|Grok [proj]|Grok replied · 1 shell, 1 subagent still running|Tink.aiff"
t "grok task failed, busy" grok "$(G task "$GB")" "progress|Grok [proj]|Grok background command failed · 1 shell, 1 subagent still running|Tink.aiff"
t "grok subagent, none"   grok "$(G sub)"         "done|Grok [proj]|Grok task completed|fx-ok01.wav"
t "grok subagent ok, busy" grok "$(G sub "$GB")"  "progress|Grok [proj]|Grok subagent finished · 1 shell, 1 subagent still running|Tink.aiff"
t "grok subagent failed"  grok "$(G subfail "$GB")" "progress|Grok [proj]|Grok subagent failed · 1 shell, 1 subagent still running|Tink.aiff"
t "grok shell killed"     grok "$(G sig "$GB")"   "progress|Grok [proj]|Grok background command stopped · 1 shell, 1 subagent still running|Tink.aiff"
t "grok monitor"          grok "$(G mon)"         "quiet|Grok [proj]|Grok monitor event|"
t "grok loop"             grok "$(G cron)"        "quiet|Grok [proj]|Grok scheduled check|"
t "grok drain commands"   grok "$(G drain "$GB")" "progress|Grok [proj]|Grok background command finished · 1 shell, 1 subagent still running|Tink.aiff"
t "grok goal summary"     grok "$(G gsum)"        "quiet|Grok [proj]|Grok goal step|"
t "grok goal step"        grok "$(G goal)"        "quiet|Grok [proj]|Grok goal step|"
t "grok failure"          grok '{"hook_event_name":"StopFailure","cwd":"/x/proj"}' "failed|Grok [proj]|Grok task failed|Basso.aiff"
# Banner mode: notify.sh mode [auto|sticky], stored under XDG_CONFIG_HOME.
export XDG_CONFIG_HOME="$d/xdg"
m() { got=$(bash "$N" mode "$@" 2>&1); [ "$got" = "$want" ] && echo "ok   mode $* -> $want" || { echo "FAIL mode $*: got '$got' want '$want'"; fail=1; }; }
want=auto m; want=sticky m sticky; want=sticky m; want=auto m auto
bash "$N" mode bogus >/dev/null 2>&1 && { echo "FAIL mode bogus accepted"; fail=1; } || echo "ok   mode bogus rejected"
unset XDG_CONFIG_HOME
# OMP: omp/test.ts drives the extension with a fake host.
BUN=$(command -v bun || echo "$HOME/.bun/bin/bun")
if [ -x "$BUN" ]; then
  want='done|done|OMP [proj]|OMP task completed|fx-ok01.wav
failed|failed|OMP [proj]|OMP task failed|Basso.aiff
replied, busy|progress|OMP [proj]|OMP replied · 2 subagents, 1 shell still running|Tink.aiff
job done, none left|done|OMP [proj]|OMP task completed|fx-ok01.wav
shell done, 1 left|progress|OMP [proj]|OMP background command finished · 1 subagent still running|Tink.aiff
subagent failed, 1 left|progress|OMP [proj]|OMP subagent failed · 1 shell still running|Tink.aiff
loop run|quiet|OMP [proj]|OMP loop run|
question|question|OMP [proj]|OMP asks a question|Submarine.aiff'
  want=$(snd "$want")
  got=$(cd "$(dirname "$N")/omp" && NOTIFY_DRY_RUN=1 "$BUN" test.ts 2>&1)
  if [ "$got" = "$want" ]; then echo "ok   omp (8 cases)"; else echo "FAIL omp"; diff <(echo "$want") <(echo "$got"); fail=1; fi
else
  echo "skip omp (bun not found)"
fi
rm -rf "$d"; exit $fail
