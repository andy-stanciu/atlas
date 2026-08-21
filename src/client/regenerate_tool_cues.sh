uv run python render_tool_cues.py
for f in Sources/atlas/resources/sfx/tool_*.wav; do
    ffmpeg -y -i "$f" -codec:a libmp3lame -q:a 4 "${f%.wav}.mp3" && rm "$f"
done
echo "Regenerated all tool cues!"