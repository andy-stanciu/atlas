import os
from pathlib import Path
from zoneinfo import ZoneInfo

ROOT = Path(__file__).parent


def _load_env_file():
    path = ROOT / ".env"
    if not path.exists():
        return
    for line in path.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, _, value = line.partition("=")
        os.environ.setdefault(key.strip(), value.strip().strip('"').strip("'"))


_load_env_file()

DATABASE_PATH = Path(
    os.environ.get("ATLAS_DATABASE_PATH", ROOT / "data" / "atlas_v2.db")
)
TOOLS_PATH = ROOT / "tools.json"
HOST = "127.0.0.1"
PORT = 8090
TIMEZONE = ZoneInfo("America/Los_Angeles")
LIBRESPOT_URL = os.environ.get("ATLAS_LIBRESPOT_URL", "http://127.0.0.1:3678")
LIBRESPOT_TIMEOUT = 5
SPOTIFY_CLIENT_ID = os.environ.get("ATLAS_SPOTIFY_CLIENT_ID", "")
SPOTIFY_CLIENT_SECRET = os.environ.get("ATLAS_SPOTIFY_CLIENT_SECRET", "")
SCHEDULER_INTERVAL_SECONDS = 0.5

SPEAKER_MODEL_NAME = "speechbrain/spkrec-ecapa-voxceleb"
SPEAKER_MODEL_DIR = ROOT / "data" / "speaker_model"
SPEAKER_IDENTIFY_MIN_SECONDS = 1.5
SPEAKER_ENROLLMENT_MIN_SECONDS = 3.0
SPEAKER_REINFORCE_MIN_SECONDS = 3.0
SPEAKER_MAX_SAMPLES = 10

# similarity thresholds
SPEAKER_REVIEW_THRESHOLD = 0.35
SPEAKER_KNOWN_THRESHOLD = 0.50
SPEAKER_REINFORCE_THRESHOLD = 0.60
SPEAKER_REDUNDANCY_THRESHOLD = 0.90

SPEAKER_ANONYMOUS_GC_INTERVAL_SECONDS = 24 * 60 * 60
SPEAKER_ANONYMOUS_ASK_CADENCE = 3
