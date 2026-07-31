from dataclasses import dataclass
from datetime import datetime
from enum import StrEnum


class EventStatus(StrEnum):
    SCHEDULED = "scheduled"
    EXECUTING = "executing"
    COMPLETED = "completed"
    FAILED = "failed"
    CANCELLED = "cancelled"


class ActionType(StrEnum):
    VOICE_NOTIFICATION = "voice_notification"
    SET_LIGHT = "set_light"


@dataclass(frozen=True)
class EventAction:
    type: ActionType
    payload: dict
    confirmation_message: str | None = None


@dataclass(frozen=True)
class ScheduledEvent:
    id: str
    summary: str
    scheduled_for_utc: datetime
    timezone: str
    actions: tuple[EventAction, ...]
    status: EventStatus
    created_at_utc: datetime


@dataclass(frozen=True)
class Notification:
    id: str
    event_id: str
    action_index: int
    kind: str
    text: str
    scheduled_for_utc: datetime
    created_at_utc: datetime
    delivered_at_utc: datetime | None
    acknowledged_at_utc: datetime | None