from .service import EventService, EventValidationError
from tools.time import current_datetime_payload


class EventToolHandlers:
    def __init__(self, event_service: EventService) -> None:
        self._event_service = event_service

    def handles(self, name: str) -> bool:
        return name in {
            "schedule_event",
            "list_scheduled_events",
            "cancel_scheduled_event",
        }

    def run(self, name: str, arguments: dict) -> dict:
        try:
            if name == "schedule_event":
                return self._event_service.schedule_one_time_reminder(arguments)

            if name == "list_scheduled_events":
                return self._event_service.list_events_for_tool(arguments)

            if name == "cancel_scheduled_event":
                return self._event_service.cancel_event(arguments)

        except EventValidationError as error:
            return {
                "ok": False,
                "error": str(error),
                "current_datetime": current_datetime_payload()
            }

        return {
            "ok": False,
            "error": f"Unknown event tool: {name}.",
        }