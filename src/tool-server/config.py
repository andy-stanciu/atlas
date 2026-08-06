import os
from pathlib import Path
from zoneinfo import ZoneInfo

ROOT = Path(__file__).parent
DATABASE_PATH = Path(
    os.environ.get("ATLAS_DATABASE_PATH", ROOT / "data" / "atlas_v2.db")
)
TOOLS_PATH = ROOT / "tools.json"
HOST = "127.0.0.1"
PORT = 8090
TIMEZONE = ZoneInfo("America/Los_Angeles")
SCHEDULER_INTERVAL_SECONDS = 0.5

SPEAKER_MODEL_NAME = "speechbrain/spkrec-ecapa-voxceleb"
SPEAKER_MODEL_DIR = ROOT / "data" / "speaker_model"
SPEAKER_KNOWN_THRESHOLD = 0.60
SPEAKER_REVIEW_THRESHOLD = 0.40
SPEAKER_MIN_AUDIO_SECONDS = 2.0
SPEAKER_MAX_SAMPLES = 10
