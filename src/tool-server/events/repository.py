import json
import sqlite3
from datetime import datetime, timezone
from pathlib import Path

from .models import ActionType, EventStatus, Notification, ScheduledEvent


class EventRepository:
    def __init__(self, database_path: Path) -> None:
        self._database_path = database_path

    def initialize(self) -> None:
        self._database_path.parent.mkdir(parents=True, exist_ok=True)

        with self._connection() as connection:
            connection.executescript(
                """
                CREATE TABLE IF NOT EXISTS scheduled_events (
                    id TEXT PRIMARY KEY,
                    summary TEXT NOT NULL,
                    scheduled_for_utc TEXT NOT NULL,
                    timezone TEXT NOT NULL,
                    action_type TEXT NOT NULL,
                    action_payload_json TEXT NOT NULL,
                    status TEXT NOT NULL,
                    created_at_utc TEXT NOT NULL,
                    completed_at_utc TEXT
                );

                CREATE INDEX IF NOT EXISTS scheduled_events_due_index
                ON scheduled_events (status, scheduled_for_utc);

                CREATE TABLE IF NOT EXISTS event_executions (
                    id TEXT PRIMARY KEY,
                    event_id TEXT NOT NULL UNIQUE,
                    started_at_utc TEXT NOT NULL,
                    completed_at_utc TEXT,
                    status TEXT NOT NULL,
                    error TEXT,
                    FOREIGN KEY (event_id) REFERENCES scheduled_events(id)
                );

                CREATE TABLE IF NOT EXISTS notifications (
                    id TEXT PRIMARY KEY,
                    event_id TEXT NOT NULL,
                    execution_id TEXT NOT NULL UNIQUE,
                    text TEXT NOT NULL,
                    scheduled_for_utc TEXT NOT NULL,
                    created_at_utc TEXT NOT NULL,
                    acknowledged_at_utc TEXT,
                    FOREIGN KEY (event_id) REFERENCES scheduled_events(id),
                    FOREIGN KEY (execution_id) REFERENCES event_executions(id)
                );

                CREATE INDEX IF NOT EXISTS notifications_pending_index
                ON notifications (acknowledged_at_utc, created_at_utc);
                """
            )

    def recover_incomplete_events(self) -> None:
        """
        The server is single-process. On startup, an event left in executing
        state means the prior process stopped before completion.
        """
        with self._connection() as connection:
            connection.execute(
                """
                UPDATE scheduled_events
                SET status = ?
                WHERE status = ?
                """,
                (
                    EventStatus.SCHEDULED.value,
                    EventStatus.EXECUTING.value,
                ),
            )

            connection.execute(
                """
                UPDATE event_executions
                SET status = ?, error = ?
                WHERE status = ?
                """,
                (
                    "abandoned",
                    "Tool server stopped before execution completed.",
                    "running",
                ),
            )

    def create_event(self, event: ScheduledEvent) -> None:
        with self._connection() as connection:
            connection.execute(
                """
                INSERT INTO scheduled_events (
                    id,
                    summary,
                    scheduled_for_utc,
                    timezone,
                    action_type,
                    action_payload_json,
                    status,
                    created_at_utc
                )
                VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                """,
                (
                    event.id,
                    event.summary,
                    _to_storage_time(event.scheduled_for_utc),
                    event.timezone,
                    event.action_type.value,
                    json.dumps(event.action_payload),
                    event.status.value,
                    _to_storage_time(event.created_at_utc),
                ),
            )

    def list_events(self, include_history: bool = False) -> list[ScheduledEvent]:
        query = """
            SELECT *
            FROM scheduled_events
        """

        parameters: tuple[object, ...] = ()

        if not include_history:
            query += """
                WHERE status = ?
            """
            parameters = (EventStatus.SCHEDULED.value,)

        query += """
            ORDER BY scheduled_for_utc ASC
        """

        with self._connection() as connection:
            rows = connection.execute(
                query,
                parameters,
            ).fetchall()

        return [_event_from_row(row) for row in rows]

    def cancel_event(self, event_id: str) -> bool:
        with self._connection() as connection:
            cursor = connection.execute(
                """
                UPDATE scheduled_events
                SET status = ?
                WHERE id = ? AND status = ?
                """,
                (
                    EventStatus.CANCELLED.value,
                    event_id,
                    EventStatus.SCHEDULED.value,
                ),
            )

        return cursor.rowcount == 1

    def claim_next_due_event(
        self,
        now_utc: datetime,
        execution_id: str,
    ) -> ScheduledEvent | None:
        """
        Claims one due event in a short SQLite transaction.

        The status update is conditional, so a second scheduler iteration
        cannot claim the same event after the first has claimed it.
        """
        with self._connection() as connection:
            connection.execute("BEGIN IMMEDIATE")

            row = connection.execute(
                """
                SELECT *
                FROM scheduled_events
                WHERE status = ?
                  AND scheduled_for_utc <= ?
                ORDER BY scheduled_for_utc ASC
                LIMIT 1
                """,
                (
                    EventStatus.SCHEDULED.value,
                    _to_storage_time(now_utc),
                ),
            ).fetchone()

            if row is None:
                connection.commit()
                return None

            event = _event_from_row(row)

            cursor = connection.execute(
                """
                UPDATE scheduled_events
                SET status = ?
                WHERE id = ? AND status = ?
                """,
                (
                    EventStatus.EXECUTING.value,
                    event.id,
                    EventStatus.SCHEDULED.value,
                ),
            )

            if cursor.rowcount != 1:
                connection.rollback()
                return None

            connection.execute(
                """
                INSERT INTO event_executions (
                    id,
                    event_id,
                    started_at_utc,
                    status
                )
                VALUES (?, ?, ?, ?)
                """,
                (
                    execution_id,
                    event.id,
                    _to_storage_time(now_utc),
                    "running",
                ),
            )

            connection.commit()
            return event

    def complete_voice_notification(
        self,
        event: ScheduledEvent,
        execution_id: str,
        notification_id: str,
        completed_at_utc: datetime,
    ) -> None:
        """
        Notification insertion and event completion are one transaction.
        A successful event therefore has exactly one durable notification.
        """
        text = event.action_payload["text"]

        with self._connection() as connection:
            connection.execute("BEGIN IMMEDIATE")

            connection.execute(
                """
                INSERT INTO notifications (
                    id,
                    event_id,
                    execution_id,
                    text,
                    scheduled_for_utc,
                    created_at_utc
                )
                VALUES (?, ?, ?, ?, ?, ?)
                """,
                (
                    notification_id,
                    event.id,
                    execution_id,
                    text,
                    _to_storage_time(event.scheduled_for_utc),
                    _to_storage_time(completed_at_utc),
                ),
            )

            connection.execute(
                """
                UPDATE event_executions
                SET status = ?, completed_at_utc = ?
                WHERE id = ?
                """,
                (
                    "succeeded",
                    _to_storage_time(completed_at_utc),
                    execution_id,
                ),
            )

            connection.execute(
                """
                UPDATE scheduled_events
                SET status = ?, completed_at_utc = ?
                WHERE id = ?
                """,
                (
                    EventStatus.COMPLETED.value,
                    _to_storage_time(completed_at_utc),
                    event.id,
                ),
            )

            connection.commit()

    def fail_execution(
        self,
        event_id: str,
        execution_id: str,
        error: str,
        failed_at_utc: datetime,
    ) -> None:
        with self._connection() as connection:
            connection.execute(
                """
                UPDATE event_executions
                SET status = ?, error = ?, completed_at_utc = ?
                WHERE id = ?
                """,
                (
                    "failed",
                    error,
                    _to_storage_time(failed_at_utc),
                    execution_id,
                ),
            )

            connection.execute(
                """
                UPDATE scheduled_events
                SET status = ?
                WHERE id = ?
                """,
                (
                    EventStatus.SCHEDULED.value,
                    event_id,
                ),
            )

    def next_unacknowledged_notification(self) -> Notification | None:
        with self._connection() as connection:
            row = connection.execute(
                """
                SELECT *
                FROM notifications
                WHERE acknowledged_at_utc IS NULL
                ORDER BY created_at_utc ASC
                LIMIT 1
                """
            ).fetchone()

        return None if row is None else _notification_from_row(row)

    def acknowledge_notification(
        self,
        notification_id: str,
        acknowledged_at_utc: datetime,
    ) -> bool:
        with self._connection() as connection:
            cursor = connection.execute(
                """
                UPDATE notifications
                SET acknowledged_at_utc = ?
                WHERE id = ? AND acknowledged_at_utc IS NULL
                """,
                (
                    _to_storage_time(acknowledged_at_utc),
                    notification_id,
                ),
            )

        return cursor.rowcount == 1

    def _connection(self) -> sqlite3.Connection:
        connection = sqlite3.connect(
            self._database_path,
            timeout=5,
        )
        connection.row_factory = sqlite3.Row
        connection.execute("PRAGMA foreign_keys = ON")
        connection.execute("PRAGMA journal_mode = WAL")
        return connection


def _event_from_row(row: sqlite3.Row) -> ScheduledEvent:
    return ScheduledEvent(
        id=row["id"],
        summary=row["summary"],
        scheduled_for_utc=_from_storage_time(row["scheduled_for_utc"]),
        timezone=row["timezone"],
        action_type=ActionType(row["action_type"]),
        action_payload=json.loads(row["action_payload_json"]),
        status=EventStatus(row["status"]),
        created_at_utc=_from_storage_time(row["created_at_utc"]),
    )


def _notification_from_row(row: sqlite3.Row) -> Notification:
    return Notification(
        id=row["id"],
        event_id=row["event_id"],
        text=row["text"],
        scheduled_for_utc=_from_storage_time(row["scheduled_for_utc"]),
        created_at_utc=_from_storage_time(row["created_at_utc"]),
    )


def _to_storage_time(value: datetime) -> str:
    return value.astimezone(timezone.utc).isoformat()


def _from_storage_time(value: str) -> datetime:
    return datetime.fromisoformat(value).astimezone(timezone.utc)