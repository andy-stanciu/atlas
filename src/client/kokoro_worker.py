import json
import sys
from pathlib import Path

import soundfile as sf
from kokoro import KPipeline


VOICE = "af_heart"
SAMPLE_RATE = 24_000


def emit(value):
    print(value, flush=True)


def emit_json(value):
    emit(json.dumps(value, ensure_ascii=False))


def main():
    pipeline = KPipeline(lang_code="a")

    # Swift waits for this exact line before starting the audio engine.
    emit("READY")

    for line in sys.stdin:
        try:
            request = json.loads(line)

            text = request["text"].strip()
            output_path = Path(request["output_path"])

            if not text:
                raise ValueError("Text must not be empty.")

            output_path.parent.mkdir(parents=True, exist_ok=True)

            audio_parts = []

            generator = pipeline(
                text,
                voice=VOICE,
                speed=1.0,
                split_pattern=r"\n+",
            )

            for _, _, audio in generator:
                audio_parts.append(audio)

            if not audio_parts:
                raise RuntimeError("Kokoro produced no audio.")

            if len(audio_parts) == 1:
                audio = audio_parts[0]
            else:
                import numpy as np
                audio = np.concatenate(audio_parts)

            sf.write(
                str(output_path),
                audio,
                SAMPLE_RATE,
                subtype="PCM_16",
            )

            emit_json({
                "ok": True,
                "output_path": str(output_path),
            })

        except Exception as error:
            emit_json({
                "ok": False,
                "error": str(error),
            })


if __name__ == "__main__":
    main()