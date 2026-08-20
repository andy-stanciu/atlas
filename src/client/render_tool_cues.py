"""Render per-tool spoken cues with Kokoro into the sfx resource folder.

Usage (from the client directory):
    uv run python render_tool_cues.py

Writes tool_<name>.wav files next to the existing sfx. SoundEffects
loads .wav automatically when no .mp3 exists. To convert to mp3:
    for f in Sources/atlas/resources/sfx/tool_*.wav; do
        ffmpeg -y -i "$f" -codec:a libmp3lame -q:a 4 "${f%.wav}.mp3" && rm "$f"
    done
"""

import os

import numpy as np
import soundfile as sf
from kokoro import KPipeline

# Match the voice/speed used by kokoro_worker.py so cues sound like Atlas.
VOICE = "af_heart"
SPEED = 1.0
SAMPLE_RATE = 24_000

OUT_DIR = os.path.join(
    os.path.dirname(os.path.abspath(__file__)),
    "Sources",
    "atlas",
    "resources",
    "sfx",
)

CUES = {
    "tool_get_current_datetime": "Let me check the time.",
    "tool_set_light": "Adjusting the lights.",
    "tool_get_light_status": "Checking the lights.",
    "tool_schedule_reminder": "Setting that reminder.",
    "tool_list_reminders": "Checking your reminders.",
    "tool_cancel_reminder": "Canceling that reminder.",
    "tool_address_reminder": "Addressing that reminder.",
    "tool_schedule_sequence": "Scheduling that sequence.",
    "tool_list_sequences": "Checking your sequences.",
    "tool_cancel_sequence": "Canceling that sequence.",
}


def main() -> None:
    pipeline = KPipeline(lang_code="a")
    os.makedirs(OUT_DIR, exist_ok=True)
    for name, text in CUES.items():
        chunks = [audio for _, _, audio in pipeline(text, voice=VOICE, speed=SPEED)]
        if not chunks:
            print(f"[skip] {name}: no audio generated")
            continue
        audio = np.concatenate(chunks)
        path = os.path.join(OUT_DIR, f"{name}.wav")
        sf.write(path, audio, SAMPLE_RATE)
        print(f'[ok] {name}.wav  ({len(audio) / SAMPLE_RATE:.2f}s)  "{text}"')


if __name__ == "__main__":
    main()
