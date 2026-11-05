#!/bin/bash
# Wires notify.sh into Claude Code, Droid, Grok and Codex, and omp/ into Oh My Pi.
# Works on macOS, Linux and Windows (run it from Git Bash on Windows).
# Safe to re-run: older notification hooks are replaced, other hooks are kept.
set -euo pipefail
repo="$(cd "$(dirname "$0")" && pwd)"
windows=; case "$(uname -s)" in MINGW* | MSYS* | CYGWIN*) windows=1 ;; esac
notify_cmd="/bin/bash $repo/notify.sh"

# Glass banner (overlay/Overlay.swift), built as ~/Applications/Agent Notify.app:
# Notification Center only takes apps from there, not from this folder or /tmp.
# Without swiftc, notify.sh falls back to the plain macOS banner.
# On Linux there is nothing to build: notify.sh and OMP use notify-send.
app="$HOME/Applications/Agent Notify.app"
if [ -n "$windows" ]; then
  # Git Bash. notify.sh needs jq. The banner (windows/Overlay.cs) is compiled
  # with the C# compiler that ships with Windows (.NET Framework 4).
  local_app=$(cygpath -u "$LOCALAPPDATA")
  jq_exe=$(command -v jq || ls "$local_app"/Microsoft/WinGet/Packages/jqlang.jq_*/jq.exe 2>/dev/null | head -n 1 || true)
  [ -n "$jq_exe" ] || { echo "error: jq not found (install it with: winget install jqlang.jq)"; exit 1; }
  jq() { "$jq_exe" -b "$@"; } # -b: LF line ends, not CRLF
  exe="$local_app/Programs/Agent Notify/notify-overlay.exe"
  csc="$(cygpath -u "$SYSTEMROOT")/Microsoft.NET/Framework64/v4.0.30319/csc.exe"
  [ -f "$csc" ] || csc="$(cygpath -u "$SYSTEMROOT")/Microsoft.NET/Framework/v4.0.30319/csc.exe"
  if [ -f "$csc" ]; then
    mkdir -p "$(dirname "$exe")"
    taskkill //IM notify-overlay.exe //F >/dev/null 2>&1 || true # a banner on screen locks the old .exe
    # Dash options: Git Bash would turn /out: and the like into file paths.
    out=$("$csc" -nologo -optimize -target:winexe -out:"$(cygpath -w "$exe")" \
      -r:System.Windows.Forms.dll -r:System.Drawing.dll "$(cygpath -w "$repo/windows/Overlay.cs")") ||
      { echo "$out"; echo "error: could not build the banner"; exit 1; }
    echo "built: $exe"
  else
    echo "warning: the .NET Framework 4 C# compiler was not found; notifications will only play a sound"
  fi
  # Claude Code runs hooks in Git Bash; other agents may use cmd. Both accept a
  # quoted Windows path to Git's bash.exe.
  notify_cmd="\"$(cygpath -m /)bin/bash.exe\" \"$(cygpath -m "$repo")/notify.sh\""
elif [ "$(uname -s)" = Linux ]; then
  [ -x /usr/bin/jq ] || { echo "error: /usr/bin/jq not found (install jq with your package manager)"; exit 1; }
  command -v notify-send >/dev/null || echo "warning: notify-send not found (libnotify); only sounds will play"
  command -v pw-play >/dev/null || command -v paplay >/dev/null ||
    echo "warning: neither pw-play nor paplay found; notifications will be silent"
  # GNOME: the extension in gnome-extension/ tints the banners by class.
  uuid=agent-notify-colors@agent-notification-sound
  if command -v gnome-extensions >/dev/null; then
    ext_dir="${XDG_DATA_HOME:-$HOME/.local/share}/gnome-shell/extensions/$uuid"
    mkdir -p "$(dirname "$ext_dir")"
    if [ -e "$ext_dir" ] && [ ! -L "$ext_dir" ]; then
      echo "warning: $ext_dir is a real folder; move it away and re-run"
    else
      ln -sfn "$repo/gnome-extension" "$ext_dir"
      echo "linked: $ext_dir"
      # GNOME Shell only finds a new extension after it restarts (on Wayland: log
      # out and back in). Until then, add it to the enabled list directly.
      if gnome-extensions enable "$uuid" 2>/dev/null; then
        echo "enabled: $uuid"
      else
        cur=$(gsettings get org.gnome.shell enabled-extensions)
        case "$cur" in
          *"'$uuid'"*) ;;
          "@as []" | "[]") gsettings set org.gnome.shell enabled-extensions "['$uuid']" ;;
          *) gsettings set org.gnome.shell enabled-extensions "${cur%]}, '$uuid']" ;;
        esac
        echo "note: log out and back in to load the GNOME extension (banner colors)"
      fi
    fi
  fi
elif command -v swiftc >/dev/null; then
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
  jq --argjson p "$2" --arg cmd "$notify_cmd $3" --arg ask "$4" --argjson events "$5" '
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
  elif [ -n "$windows" ]; then
    # Git Bash's ln -s copies the folder; a junction links it without admin rights.
    rm -f "$ext"
    cmd.exe //c mklink //J "$(cygpath -w "$ext")" "$(cygpath -w "$repo/omp")" >/dev/null
    echo "linked: $ext"
  else
    ln -sfn "$repo/omp" "$ext"
    echo "linked: $ext"
  fi
fi
echo "Done. Restart running agents to load it (in Claude Code, opening /hooks once is enough; in Codex, open /hooks and trust the new hooks)."
