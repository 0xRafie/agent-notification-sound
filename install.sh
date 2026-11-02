#!/bin/bash
# Wires notify.sh into Claude Code, Droid, Grok and Codex, and omp/ into Oh My Pi.
# Safe to re-run: older notification hooks are replaced, other hooks are kept.
set -euo pipefail
repo="$(cd "$(dirname "$0")" && pwd)"

# Glass banner (overlay/Overlay.swift), built as ~/Applications/Agent Notify.app:
# Notification Center only takes apps from there, not from this folder or /tmp.
# Without swiftc, notify.sh falls back to the plain macOS banner.
app="$HOME/Applications/Agent Notify.app"
if command -v swiftc >/dev/null; then
  rm -rf "$app" "$repo/bin"
  mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources/icons"
  swiftc -O "$repo/overlay/Overlay.swift" -o "$app/Contents/MacOS/notify-overlay"
  cp "$repo/overlay/Info.plist" "$app/Contents/"
  cp "$repo/overlay/AppIcon.icns" "$app/Contents/Resources/"
  cp "$repo"/icons/*.png "$app/Contents/Resources/icons/"
  codesign --force --sign - "$app" >/dev/null 2>&1
  /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$app"
  echo "built: $app"
else
  echo "warning: swiftc not found (xcode-select --install); using the plain macOS banner"
fi

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
if [ -d ~/.codex ]; then
  # New or changed hooks stay off until you trust them: open /hooks in Codex once.
  hook ~/.codex/hooks.json '["hooks"]' codex request_user_input '["Stop","PreToolUse","SubagentStart","SubagentStop"]'
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
echo "Done. Restart running agents to load it (in Claude Code, opening /hooks once is enough; in Codex, open /hooks and trust the new hooks)."
