from datetime import datetime, timedelta, timezone
from config import TIMEZONE


class ValidationError(ValueError):
    pass


def now_utc():
    return datetime.now(timezone.utc)


def to_storage(value):
    return value.astimezone(timezone.utc).isoformat()


def from_storage(value):
    return datetime.fromisoformat(value).astimezone(timezone.utc)


def current_datetime():
    now = datetime.now(TIMEZONE)
    return {
        "date": now.strftime("%Y-%m-%d"),
        "time": now.strftime("%-I:%M %p"),
        "day_of_week": now.strftime("%A"),
    }


def resolve_schedule(arguments):
    minutes = arguments.get("in_minutes")
    date = arguments.get("date")
    time = arguments.get("time")
    has_minutes = minutes is not None
    has_date = date is not None
    has_time = time is not None

    if has_minutes:
        if (
            isinstance(minutes, bool)
            or not isinstance(minutes, int)
            or not 1 <= minutes <= 525600
        ):
            raise ValidationError(
                "in_minutes must be a whole number between 1 and 525600."
            )
        if has_date or has_time:
            raise ValidationError(
                "Give in_minutes, or time with optional date, not both."
            )
        return now_utc() + timedelta(minutes=minutes)

    if not has_time:
        raise ValidationError("Provide in_minutes, or time with optional date.")
    if not isinstance(time, str) or not time.strip():
        raise ValidationError("time must be a non-empty string.")
    if has_date and (not isinstance(date, str) or not date.strip()):
        raise ValidationError("date must be YYYY-MM-DD.")

    try:
        parsed_time = datetime.strptime(time.strip().upper(), "%I:%M %p").time()
    except ValueError as error:
        raise ValidationError(
            "time must use h:mm AM or h:mm PM, for example 5:30 PM."
        ) from error

    local_now = datetime.now(TIMEZONE)
    if has_date:
        try:
            local_date = datetime.strptime(date.strip(), "%Y-%m-%d").date()
        except ValueError as error:
            raise ValidationError("date must use YYYY-MM-DD format.") from error
    else:
        local_date = local_now.date()

    local = datetime.combine(local_date, parsed_time, tzinfo=TIMEZONE)
    if not has_date and local <= local_now:
        local += timedelta(days=1)
    if local <= local_now:
        raise ValidationError("The scheduled time must be in the future.")
    return local.astimezone(timezone.utc)


def schedule_fields(value):
    local = value.astimezone(TIMEZONE)
    now = datetime.now(TIMEZONE)

    if local.date() == now.date():
        speakable = f"today at {local.strftime('%-I:%M %p')}"
    elif local.date() == (now + timedelta(days=1)).date():
        speakable = f"tomorrow at {local.strftime('%-I:%M %p')}"
    elif 1 < (local.date() - now.date()).days < 7:
        speakable = f"{local.strftime('%A')} at {local.strftime('%-I:%M %p')}"
    else:
        speakable = (
            f"{local.strftime('%B')} {local.day} at {local.strftime('%-I:%M %p')}"
        )

    return {
        "scheduled_for": {
            "date": local.strftime("%Y-%m-%d"),
            "time": local.strftime("%-I:%M %p"),
            "day_of_week": local.strftime("%A"),
            "speakable_time": speakable,
        }
    }
