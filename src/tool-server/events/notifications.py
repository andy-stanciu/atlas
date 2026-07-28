from datetime import datetime, timezone

from .repository import EventRepository


class NotificationService:
    def __init__(self, repository: EventRepository) -> None:
        self._repository = repository

    def next_notification(self) -> dict:
        notification = (
            self._repository.next_unacknowledged_notification()
        )

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
                    "Notification was not found or was already "
                    "acknowledged."
                ),
            }

        return {
            "ok": True,
            "notification_id": notification_id,
        }