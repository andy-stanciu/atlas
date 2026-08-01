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
