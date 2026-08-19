#!/bin/bash
# usage: start-atlas.sh local|pc
set -euo pipefail

ROOT="$HOME/workplace/atlas"
WHISPER="$ROOT/argmax-oss-swift/Models/whisperkit-coreml/openai_whisper-large-v3-v20240930_626MB"

mode="${1:-}"
[[ "$mode" == "local" || "$mode" == "pc" ]] || { echo "usage: $(basename "$0") local|pc" >&2; exit 1; }

if [[ "$mode" == "pc" ]]; then
  LLM_BASE="http://192.168.1.232:8000"
else
  LLM_BASE="http://127.0.0.1:8000"
fi


if ! curl -sf --max-time 3 "$LLM_BASE/v1/models" >/dev/null; then
  if [[ "$mode" == "pc" ]]; then
    echo "warning: vllm not reachable at $LLM_BASE - check 'sudo systemctl status vllm' on the PC" >&2
  else
    echo "warning: vllm not reachable at $LLM_BASE - start a local server first" >&2
  fi
fi


cmds=()
cmds+=("cd $ROOT/src/tool-server && uv run python app.py")
cmds+=("cd $ROOT/src/client && swift build && swift run sttd $WHISPER")
cmds+=("cd $ROOT/src/client && swift build && ATLAS_LLM_URL=$LLM_BASE/v1 swift run atlas")

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
