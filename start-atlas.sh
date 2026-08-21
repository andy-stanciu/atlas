#!/bin/bash
set -euo pipefail

ROOT="$HOME/workplace/atlas"
LLM_BASE="http://192.168.1.232:8000"


if ! curl -sf --max-time 3 "$LLM_BASE/v1/models" >/dev/null; then
  echo "warning: vllm not reachable at $LLM_BASE - check 'sudo systemctl status vllm' on the desktop" >&2
fi
if ! timeout 3 bash -c "</dev/tcp/192.168.1.232/8767" 2>/dev/null; then
  echo "warning: tts server not reachable - check 'sudo systemctl status atlas-tts' on the desktop" >&2
fi
if ! timeout 3 bash -c "</dev/tcp/192.168.1.232/8080" 2>/dev/null; then
  echo "warning: stt server not reachable - check 'sudo systemctl status atlas-stt' on the desktop" >&2
fi


cmds=()
cmds+=("cd $ROOT/src/tool-server && uv run python app.py")
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
