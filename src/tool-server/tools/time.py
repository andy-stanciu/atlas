from datetime import datetime
from zoneinfo import ZoneInfo

PACIFIC = ZoneInfo("America/Los_Angeles")


def current_datetime_payload() -> dict[str, str]:
    now = datetime.now(PACIFIC)

    return {
        "date": now.strftime("%Y-%m-%d"),
        "time": now.strftime("%-I:%M %p"),
        "day_of_week": now.strftime("%A"),
    }

def current_datetime() -> dict:
    return { "ok": True } | current_datetime_payload()
