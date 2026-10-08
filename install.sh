#!/bin/bash
# Wires notify.sh into Claude Code, Droid and Grok, and omp/ into Oh My Pi.
# Safe to re-run: older notification hooks are replaced, other hooks are kept.
set -euo pipefail
repo="$(cd "$(dirname "$0")" && pwd)"

hook() { # <json file> <jq path to the hooks object> <tool> <ask tool> <events json>
  local file=$1 tmp
  tmp=$(mktemp)
  [ -s "$file" ] || echo '{}' > "$file"
  jq --argjson p "$2" --arg cmd "/bin/bash $repo/notify.sh $3" --arg ask "$4" --argjson events "$5" '
    def ours: any(.hooks[]?; (.command // "") | test("notify\\.sh|notification-sound\\.sh"));
    def entry($e): {hooks: [{type: "command", command: $cmd, timeout: 5}]}
      + (if $e == "PreToolUse" then {matcher: $ask} else {} end);
    . as $doc
    | ($doc | getpath($p) // {})
    | with_entries(if (.value | type) == "array" then .value |= map(select(ours | not)) else . end)
    | with_entries(select((.value | type) != "array" or (.value | length) > 0))
    | reduce $events[] as $e (.; .[$e] = ((.[$e] // []) + [entry($e)]))
    | . as $hooks | $doc | setpath($p; $hooks)' "$file" > "$tmp"
  cat "$tmp" > "$file" # keeps symlinks and permissions
  rm -f "$tmp"
  echo "hooked: $file"
}

if [ -d ~/.claude ]; then
  hook ~/.claude/settings.json '["hooks"]' claude AskUserQuestion '["Stop","StopFailure","PreToolUse"]'
fi
if [ -d ~/.factory ]; then
  hook ~/.factory/hooks.json '[]' droid AskUser '["Stop","PreToolUse"]'
fi
if [ -d ~/.grok ]; then
  mkdir -p ~/.grok/hooks
  hook ~/.grok/hooks/agent-notification-sound.json '["hooks"]' grok ask_user_question '["Stop","StopFailure","PreToolUse"]'
  grep -l 'notification-sound\.sh' ~/.grok/hooks/*.json | grep -v '/agent-notification-sound\.json$' |
    sed 's/^/warning: remove this old Grok hook or it chimes twice: /' || true
fi
if [ -d ~/.omp ]; then
  ext=~/.omp/agent/extensions/notification-sound
  mkdir -p "$(dirname "$ext")"
  if [ -e "$ext" ] && [ ! -L "$ext" ]; then
    echo "warning: $ext is a real folder; move it away and re-run"
  else
    ln -sfn "$repo/omp" "$ext"
    echo "linked: $ext"
  fi
fi
echo "Done. Restart running agents to load it (in Claude Code, opening /hooks once is enough)."
