#!/bin/bash
# usage: start-atlas.sh local|pc
set -euo pipefail

ROOT="$HOME/workplace/atlas"
PC_BASE="http://192.168.1.232:11434"
WHISPER="$ROOT/argmax-oss-swift/Models/whisperkit-coreml/openai_whisper-large-v3-v20240930_626MB"

mode="${1:-}"
[[ "$mode" == "local" || "$mode" == "pc" ]] || { echo "usage: $(basename "$0") local|pc" >&2; exit 1; }

if [[ "$mode" == "pc" ]] && ! curl -sf --max-time 3 "$PC_BASE/api/version" >/dev/null; then
  echo "warning: ollama not reachable at $PC_BASE - is atlas-ollama running on the PC?" >&2
fi

cmds=()
if [[ "$mode" == "local" ]]; then
  cmds+=("ollama serve")
fi
cmds+=("cd $ROOT/src/tool-server && uv run python app.py")
cmds+=("cd $ROOT/src/client && swift build && swift run sttd $WHISPER")
if [[ "$mode" == "pc" ]]; then
  cmds+=("cd $ROOT/src/client && swift build && ATLAS_OLLAMA_URL=$PC_BASE/api/chat swift run atlas")
else
  cmds+=("cd $ROOT/src/client && swift build && swift run atlas")
fi

code "$ROOT"
sleep 6

spawn() { # $1 = command; opens a new vscode terminal and runs it
  osascript - "$1" <<'AS'
on run argv
  set cmd to item 1 of argv
  tell application "Visual Studio Code" to activate
  delay 0.4
  tell application "System Events"
    keystroke "`" using {control down, shift down}
    delay 1.2
    keystroke cmd
    key code 36
  end tell
end run
AS
}

for c in "${cmds[@]}"; do
  spawn "$c"
  sleep 1
done
