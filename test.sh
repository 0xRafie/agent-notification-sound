#!/bin/bash
# Usage: test.sh  — feeds synthetic hook inputs to notify.sh in dry-run mode.
N=~/agent-notification-sound/notify.sh; fail=0; d=$(mktemp -d)
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
t() { # name tool json expected
  got=$(printf '%s' "$3" | NOTIFY_DRY_RUN=1 bash "$N" "$2")
  if [ "$got" = "$4" ]; then echo "ok   $1"; else echo "FAIL $1"; echo "     want: $4"; echo "     got:  $got"; fail=1; fi; }
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
  got=$(cd "$(dirname "$N")/omp" && NOTIFY_DRY_RUN=1 "$BUN" test.ts 2>&1)
  if [ "$got" = "$want" ]; then echo "ok   omp (8 cases)"; else echo "FAIL omp"; diff <(echo "$want") <(echo "$got"); fail=1; fi
else
  echo "skip omp (bun not found)"
fi
rm -rf "$d"; exit $fail
