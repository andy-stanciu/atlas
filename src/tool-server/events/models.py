from dataclasses import dataclass
from datetime import datetime
from enum import StrEnum


class EventStatus(StrEnum):
    SCHEDULED = "scheduled"
    EXECUTING = "executing"
    COMPLETED = "completed"
    CANCELLED = "cancelled"


class ActionType(StrEnum):
    VOICE_NOTIFICATION = "voice_notification"


@dataclass(frozen=True)
class ScheduledEvent:
    id: str
    summary: str
    scheduled_for_utc: datetime
    timezone: str
    action_type: ActionType
    action_payload: dict
    status: EventStatus
    created_at_utc: datetime


@dataclass(frozen=True)
class Notification:
    id: str
    event_id: str
    text: str
    scheduled_for_utc: datetime
    created_at_utc: datetime