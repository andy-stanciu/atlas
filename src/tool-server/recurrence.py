import calendar
import re
from datetime import datetime, timedelta


class RecurrenceError(ValueError):
    pass


_WORD_NUMBERS = {
    "a": 1,
    "an": 1,
    "one": 1,
    "two": 2,
    "three": 3,
    "four": 4,
    "five": 5,
    "six": 6,
    "seven": 7,
    "eight": 8,
    "nine": 9,
    "ten": 10,
    "eleven": 11,
    "twelve": 12,
}

_DAYS = {
    "monday": 0,
    "tuesday": 1,
    "wednesday": 2,
    "thursday": 3,
    "friday": 4,
    "saturday": 5,
    "sunday": 6,
}

_DAY_NAMES = [
    "Monday",
    "Tuesday",
    "Wednesday",
    "Thursday",
    "Friday",
    "Saturday",
    "Sunday",
]

_UNITS = ("hour", "day", "week", "month")


def _interval_before_unit(phrase, unit):
    match = re.search(
        rf"\bevery\s+(\d+|other|{'|'.join(_WORD_NUMBERS)})\s+{unit}s?\b",
        phrase,
    )
    if match is None:
        return 1
    token = match.group(1)
    if token == "other":
        return 2
    if token.isdigit():
        value = int(token)
    else:
        value = _WORD_NUMBERS[token]
    if not 1 <= value <= 500:
        raise RecurrenceError(
            f"Interval {value} is out of range; keep it between 1 and 500."
        )
    return value


def parse_repeat(text):
    if not isinstance(text, str) or not text.strip():
        raise RecurrenceError("repeat must be a non-empty string.")

    phrase = re.sub(r"[^a-z0-9\s]", " ", text.lower())
    tokens = phrase.split()
    token_set = set(tokens)

    bydays = sorted(
        {
            _DAYS[stripped]
            for token in token_set
            if (stripped := token.rstrip("s")) in _DAYS
            and token not in ("weekdays", "weekends")
        }
    )

    if "hour" in token_set or "hours" in token_set or "hourly" in token_set:
        if bydays:
            raise RecurrenceError(
                "Cannot combine hours with specific days; pick one style."
            )
        return {
            "freq": "hourly",
            "interval": _interval_before_unit(phrase, "hour"),
            "bydays": None,
        }

    if "weekdays" in token_set or "weekday" in token_set:
        return {
            "freq": "weekly",
            "interval": 1,
            "bydays": [0, 1, 2, 3, 4],
        }

    if "weekends" in token_set or "weekend" in token_set:
        return {"freq": "weekly", "interval": 1, "bydays": [5, 6]}

    if bydays:
        return {
            "freq": "weekly",
            "interval": _interval_before_unit(phrase, "week"),
            "bydays": bydays,
        }

    if "day" in token_set or "days" in token_set or "daily" in token_set:
        return {
            "freq": "daily",
            "interval": _interval_before_unit(phrase, "day"),
            "bydays": None,
        }

    if "week" in token_set or "weeks" in token_set or "weekly" in token_set:
        return {
            "freq": "weekly",
            "interval": _interval_before_unit(phrase, "week"),
            "bydays": None,
        }

    if "month" in token_set or "months" in token_set or "monthly" in token_set:
        return {
            "freq": "monthly",
            "interval": _interval_before_unit(phrase, "month"),
            "bydays": None,
        }

    raise RecurrenceError(
        f"Could not understand repeat '{text.strip()}'. Try 'every day', "
        "'weekdays', 'weekends', 'every week', 'every month', 'every hour', "
        "'every 2 hours', or 'every Monday and Friday'."
    )


def attach_anchor(rule, anchor_local):
    rule["hour"] = anchor_local.hour
    rule["minute"] = anchor_local.minute
    rule["day_of_month"] = anchor_local.day
    rule["anchor_local"] = anchor_local.isoformat()
    if rule["freq"] == "weekly" and rule["bydays"] is None:
        rule["bydays"] = [anchor_local.weekday()]
    rule["speakable"] = describe_repeat(rule)
    return rule


def describe_repeat(rule):
    interval = rule["interval"]
    freq = rule["freq"]

    if freq == "hourly":
        return "every hour" if interval == 1 else f"every {interval} hours"

    if freq == "daily":
        return "every day" if interval == 1 else f"every {interval} days"

    if freq == "weekly":
        bydays = rule["bydays"]
        prefix = "every week" if interval == 1 else f"every {interval} weeks"
        if bydays == [0, 1, 2, 3, 4] and interval == 1:
            return "every weekday"
        if bydays == [5, 6] and interval == 1:
            return "every weekend"
        names = [_DAY_NAMES[d] for d in bydays]
        if len(names) == 1:
            days = names[0]
        else:
            days = ", ".join(names[:-1]) + " and " + names[-1]
        if interval == 1:
            return f"every {days}"
        return f"{prefix} on {days}"

    return "every month" if interval == 1 else f"every {interval} months"


def next_occurrence(rule, after_local):
    anchor = datetime.fromisoformat(rule["anchor_local"])
    interval = rule["interval"]
    freq = rule["freq"]

    if freq == "hourly":
        if after_local < anchor:
            return anchor
        elapsed = (after_local - anchor).total_seconds()
        steps = int(elapsed // (3600 * interval)) + 1
        return anchor + timedelta(hours=interval * steps)

    if freq == "daily":
        days = (after_local.date() - anchor.date()).days
        step = max(0, days // interval)
        while True:
            candidate = anchor + timedelta(days=step * interval)
            if candidate > after_local:
                return candidate
            step += 1

    if freq == "weekly":
        bydays = rule["bydays"]
        anchor_week = anchor.date() - timedelta(days=anchor.weekday())
        for offset in range(0, 7 * interval + 8):
            day = after_local.date() + timedelta(days=offset)
            week_start = day - timedelta(days=day.weekday())
            weeks_since = (week_start - anchor_week).days // 7
            if weeks_since < 0 or weeks_since % interval != 0:
                continue
            if day.weekday() not in bydays:
                continue
            candidate = datetime(
                day.year,
                day.month,
                day.day,
                rule["hour"],
                rule["minute"],
                tzinfo=after_local.tzinfo,
            )
            if candidate > after_local:
                return candidate

    # monthly — clamp to month length, anchored phase avoids drift
    day_of_month = rule["day_of_month"]
    anchor_months = anchor.year * 12 + anchor.month
    after_months = after_local.year * 12 + after_local.month
    step = max(0, (after_months - anchor_months) // interval)
    while True:
        total = anchor_months + step * interval
        year, month_zero = divmod(total, 12)
        month = month_zero + 1
        clamped = min(day_of_month, calendar.monthrange(year, month)[1])
        candidate = datetime(
            year,
            month,
            clamped,
            rule["hour"],
            rule["minute"],
            tzinfo=after_local.tzinfo,
        )
        if candidate > after_local:
            return candidate
        step += 1
