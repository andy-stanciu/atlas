import logging
import threading
from datetime import datetime, timezone
from uuid import uuid4

from tools.lights import LightService

from .models import ActionType, EventAction, ScheduledEvent
from .repository import EventRepository


class EventScheduler:
    def __init__(
        self,
        repository: EventRepository,
        lights: LightService,
        poll_seconds: float = 1.0,
    ) -> None:
        self._repository = repository
        self._lights = lights
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

                self._repository.fail_event_execution(
                    event.id,
                    execution_id,
                    "See server logs for traceback.",
                    datetime.now(timezone.utc),
                )

    def _execute(
        self,
        event: ScheduledEvent,
        execution_id: str,
    ) -> None:
        for action_index, action in enumerate(event.actions):
            action_execution_id = f"action_execution_{uuid4().hex}"
            started_at = datetime.now(timezone.utc)

            self._logger.info(
                "Executing action %s (%s) for event %s.",
                action_index,
                action.type.value,
                event.id,
            )

            self._repository.start_action_execution(
                action_execution_id=action_execution_id,
                execution_id=execution_id,
                action_index=action_index,
                action_type=action.type,
                started_at_utc=started_at,
            )

            try:
                self._execute_action(
                    event=event,
                    execution_id=execution_id,
                    action_index=action_index,
                    action=action,
                )
            except Exception as error:
                self._repository.fail_action_execution(
                    action_execution_id=action_execution_id,
                    error=str(error),
                    failed_at_utc=datetime.now(timezone.utc),
                )
                raise

            self._repository.complete_action_execution(
                action_execution_id=action_execution_id,
                completed_at_utc=datetime.now(timezone.utc),
            )

        self._repository.complete_event_execution(
            event_id=event.id,
            execution_id=execution_id,
            completed_at_utc=datetime.now(timezone.utc),
        )

    def _execute_action(
        self,
        event: ScheduledEvent,
        execution_id: str,
        action_index: int,
        action: EventAction,
    ) -> None:
        if action.type is ActionType.VOICE_NOTIFICATION:
            self._repository.create_notification(
                notification_id=f"notification_{uuid4().hex}",
                event=event,
                execution_id=execution_id,
                action_index=action_index,
                kind="reminder",
                text=action.payload["text"],
                created_at_utc=datetime.now(timezone.utc),
            )
            return

        if action.type is ActionType.SET_LIGHT:
            result = self._lights.set_power(action.payload)

            if not result["ok"]:
                raise RuntimeError(result["error"])

            if action.confirmation_message is not None:
                self._repository.create_notification(
                    notification_id=f"notification_{uuid4().hex}",
                    event=event,
                    execution_id=execution_id,
                    action_index=action_index,
                    kind="confirmation",
                    text=action.confirmation_message,
                    created_at_utc=datetime.now(timezone.utc),
                )

            return

        raise ValueError(
            f"Unsupported action type: {action.type.value}"
        )