from datetime import datetime, timezone

from .repository import EventRepository


class NotificationService:
    def __init__(self, repository: EventRepository) -> None:
        self._repository = repository

    def next_notification(self) -> dict:
        notification = self._repository.next_pending_notification()

        if notification is None:
            return {
                "ok": True,
                "notification": None,
            }

        return {
            "ok": True,
            "notification": {
                "id": notification.id,
                "event_id": notification.event_id,
                "action_index": notification.action_index,
                "kind": notification.kind,
                "text": notification.text,
                "scheduled_for": (
                    notification.scheduled_for_utc.isoformat()
                ),
                "created_at": (
                    notification.created_at_utc.isoformat()
                ),
            },
        }

    def acknowledge(self, notification_id: str) -> dict:
        acknowledged = self._repository.acknowledge_notification(
            notification_id,
            datetime.now(timezone.utc),
        )

        if not acknowledged:
            return {
                "ok": False,
                "error": (
                    "Notification was not found, already acknowledged, "
                    "or is not a reminder."
                ),
            }

        return {
            "ok": True,
            "notification_id": notification_id,
        }

    def mark_delivered(self, notification_id: str) -> dict:
        delivered = self._repository.mark_notification_delivered(
            notification_id,
            datetime.now(timezone.utc),
        )

        if not delivered:
            return {
                "ok": False,
                "error": (
                    "Notification was not found, already delivered, "
                    "or is not a confirmation."
                ),
            }

        return {
            "ok": True,
            "notification_id": notification_id,
        }