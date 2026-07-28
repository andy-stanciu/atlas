import logging
import threading
from datetime import datetime, timezone
from uuid import uuid4

from .models import ActionType
from .repository import EventRepository


class EventScheduler:
    def __init__(
        self,
        repository: EventRepository,
        poll_seconds: float = 1.0,
    ) -> None:
        self._repository = repository
        self._poll_seconds = poll_seconds
        self._stop_event = threading.Event()
        self._thread: threading.Thread | None = None
        self._logger = logging.getLogger(__name__)

    def start(self) -> None:
        if self._thread is not None:
            return

        self._repository.recover_incomplete_events()

        self._thread = threading.Thread(
            target=self._run,
            name="event-scheduler",
            daemon=True,
        )
        self._thread.start()

    def stop(self) -> None:
        self._stop_event.set()

        if self._thread is not None:
            self._thread.join(timeout=2)
            self._thread = None

    def _run(self) -> None:
        self._logger.info("Event scheduler started.")

        while not self._stop_event.is_set():
            try:
                self._run_due_events()
            except Exception:
                self._logger.exception(
                    "Unhandled error in event scheduler."
                )

            self._stop_event.wait(self._poll_seconds)

        self._logger.info("Event scheduler stopped.")

    def _run_due_events(self) -> None:
        now = datetime.now(timezone.utc)

        self._logger.debug(
            "Scheduler tick: checking due events at %s",
            now.isoformat(),
        )

        while True:
            execution_id = f"execution_{uuid4().hex}"

            event = self._repository.claim_next_due_event(
                now,
                execution_id,
            )

            if event is None:
                self._logger.debug("Scheduler tick: no due events.")
                return

            self._logger.info(
                "Claimed event %s: %s, due %s",
                event.id,
                event.summary,
                event.scheduled_for_utc.isoformat(),
            )

            try:
                self._execute(event, execution_id)

                self._logger.info(
                    "Completed event %s.",
                    event.id,
                )
            except Exception:
                self._logger.exception(
                    "Event %s execution failed.",
                    event.id,
                )

                self._repository.fail_execution(
                    event.id,
                    execution_id,
                    "See server logs for traceback.",
                    datetime.now(timezone.utc),
                )

    def _execute(self, event, execution_id: str) -> None:
        self._logger.info(
            "Executing %s action for event %s.",
            event.action_type.value,
            event.id,
        )

        if event.action_type is ActionType.VOICE_NOTIFICATION:
            self._repository.complete_voice_notification(
                event=event,
                execution_id=execution_id,
                notification_id=f"notification_{uuid4().hex}",
                completed_at_utc=datetime.now(timezone.utc),
            )

            self._logger.info(
                "Created notification for event %s.",
                event.id,
            )
            return

        raise ValueError(
            f"Unsupported action type: {event.action_type.value}"
        )