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
rm -rf "$d"; exit $fail
