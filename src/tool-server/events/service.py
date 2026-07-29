from datetime import datetime, timedelta, timezone
from uuid import uuid4
from zoneinfo import ZoneInfo

from .models import ActionType, EventStatus, ScheduledEvent
from .repository import EventRepository
from tools.time import current_datetime_payload


DEFAULT_TIMEZONE = "America/Los_Angeles"
PACIFIC_TIMEZONE = ZoneInfo(DEFAULT_TIMEZONE)


class EventValidationError(ValueError):
    pass


class EventService:
    def __init__(self, repository: EventRepository) -> None:
        self._repository = repository

    def schedule_one_time_reminder(self, arguments: dict) -> dict:
        summary = _required_text(arguments, "summary")
        message = _required_text(arguments, "message")
        scheduled_for_utc = _resolve_scheduled_for(arguments)

        event = ScheduledEvent(
            id=f"event_{uuid4().hex}",
            summary=summary,
            scheduled_for_utc=scheduled_for_utc,
            timezone=DEFAULT_TIMEZONE,
            action_type=ActionType.VOICE_NOTIFICATION,
            action_payload={"text": message},
            status=EventStatus.SCHEDULED,
            created_at_utc=datetime.now(timezone.utc),
        )

        self._repository.create_event(event)
        return event_to_response(event)

    def list_events(self, include_history: bool = False) -> dict:
        return {
            "ok": True,
            "events": [
                event_to_response(event)
                for event in self._repository.list_events(include_history=include_history)
            ],
            "current_datetime": current_datetime_payload(),
        }

    def list_events_for_tool(self, arguments: dict) -> dict:
        include_history = arguments.get("include_history", False)

        if not isinstance(include_history, bool):
            raise EventValidationError(
                "include_history must be a boolean."
            )
    
        return self.list_events(include_history=include_history)

    def cancel_event(self, arguments: dict) -> dict:
        event_id = _required_text(arguments, "event_id")
        cancelled = self._repository.cancel_event(event_id)

        if not cancelled:
            return {
                "ok": False,
                "error": (
                    "Event was not found or is no longer scheduled. "
                    "If the event has already fired, it can no longer be canceled."
                ),
            }

        return {
            "ok": True,
            "event_id": event_id,
            "status": EventStatus.CANCELLED.value,
            "current_datetime": current_datetime_payload(),
        }


def event_to_response(event: ScheduledEvent) -> dict:
    pacific_time = event.scheduled_for_utc.astimezone(
        PACIFIC_TIMEZONE
    )

    return {
        "ok": True,
        "event_id": event.id,
        "summary": event.summary,
        "action_type": event.action_type.value,
        "status": event.status.value,
        "date": pacific_time.strftime("%Y-%m-%d"),
        "time": pacific_time.strftime("%-I:%M %p"),
        "current_datetime": current_datetime_payload(),
    }


def _required_text(arguments: dict, field: str) -> str:
    value = arguments.get(field)

    if not isinstance(value, str) or not value.strip():
        raise EventValidationError(
            f"{field} must be a non-empty string."
        )

    return value.strip()


def _resolve_scheduled_for(arguments: dict) -> datetime:
    date_value = arguments.get("date")
    time_value = arguments.get("time")
    offset_minutes = arguments.get("offset_minutes")

    has_calendar_time = (
        isinstance(date_value, str)
        and bool(date_value.strip())
        and isinstance(time_value, str)
        and bool(time_value.strip())
    )
    has_offset = offset_minutes is not None

    if has_calendar_time == has_offset:
        raise EventValidationError(
            "Provide either offset_minutes or both date and time."
        )

    if has_calendar_time:
        return _parse_future_pacific_time(
            date_value.strip(),
            time_value.strip(),
        )

    if isinstance(offset_minutes, bool) or not isinstance(
        offset_minutes,
        int,
    ):
        raise EventValidationError(
            "offset_minutes must be a whole number."
        )

    if not 1 <= offset_minutes <= 525_600:
        raise EventValidationError(
            "offset_minutes must be between 1 and 525600."
        )

    return datetime.now(timezone.utc) + timedelta(
        minutes=offset_minutes
    )


def _parse_future_pacific_time(
    date_value: str,
    time_value: str,
) -> datetime:
    if not _is_valid_date(date_value):
        raise EventValidationError(
            "date must use YYYY-MM-DD format."
        )

    try:
        parsed = datetime.strptime(
            f"{date_value} {time_value.upper()}",
            "%Y-%m-%d %I:%M %p",
        )
    except ValueError as error:
        raise EventValidationError(
            "time must use 12-hour format, for example 9:30 AM."
        ) from error

    local_time = parsed.replace(tzinfo=PACIFIC_TIMEZONE)
    scheduled_for_utc = local_time.astimezone(timezone.utc)

    if scheduled_for_utc <= datetime.now(timezone.utc):
        raise EventValidationError(
            "date and time must be in the future."
        )

    return scheduled_for_utc


def _is_valid_date(value: str) -> bool:
    try:
        return datetime.strptime(
            value,
            "%Y-%m-%d",
        ).strftime("%Y-%m-%d") == value
    except ValueError:
        return False