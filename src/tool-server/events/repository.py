import json
from datetime import datetime, timezone
from pathlib import Path

from sqlalchemy import (
    ForeignKey,
    Index,
    String,
    Text,
    create_engine,
    event,
    select,
    update,
)
from sqlalchemy.orm import (
    DeclarativeBase,
    Mapped,
    mapped_column,
    sessionmaker,
)

from .models import (
    ActionType,
    EventStatus,
    Notification,
    ScheduledEvent,
)


class Base(DeclarativeBase):
    pass


class ScheduledEventRow(Base):
    __tablename__ = "scheduled_events"

    id: Mapped[str] = mapped_column(String, primary_key=True)
    summary: Mapped[str] = mapped_column(Text, nullable=False)
    scheduled_for_utc: Mapped[str] = mapped_column(
        String,
        nullable=False,
    )
    timezone: Mapped[str] = mapped_column(String, nullable=False)
    action_type: Mapped[str] = mapped_column(String, nullable=False)
    action_payload_json: Mapped[str] = mapped_column(
        Text,
        nullable=False,
    )
    status: Mapped[str] = mapped_column(String, nullable=False)
    created_at_utc: Mapped[str] = mapped_column(
        String,
        nullable=False,
    )
    completed_at_utc: Mapped[str | None] = mapped_column(
        String,
        nullable=True,
    )


Index(
    "scheduled_events_due_index",
    ScheduledEventRow.status,
    ScheduledEventRow.scheduled_for_utc,
)


class EventExecutionRow(Base):
    __tablename__ = "event_executions"

    id: Mapped[str] = mapped_column(String, primary_key=True)
    event_id: Mapped[str] = mapped_column(
        ForeignKey("scheduled_events.id"),
        unique=True,
        nullable=False,
    )
    started_at_utc: Mapped[str] = mapped_column(
        String,
        nullable=False,
    )
    completed_at_utc: Mapped[str | None] = mapped_column(
        String,
        nullable=True,
    )
    status: Mapped[str] = mapped_column(String, nullable=False)
    error: Mapped[str | None] = mapped_column(Text, nullable=True)


class NotificationRow(Base):
    __tablename__ = "notifications"

    id: Mapped[str] = mapped_column(String, primary_key=True)
    event_id: Mapped[str] = mapped_column(
        ForeignKey("scheduled_events.id"),
        nullable=False,
    )
    execution_id: Mapped[str] = mapped_column(
        ForeignKey("event_executions.id"),
        unique=True,
        nullable=False,
    )
    text: Mapped[str] = mapped_column(Text, nullable=False)
    scheduled_for_utc: Mapped[str] = mapped_column(
        String,
        nullable=False,
    )
    created_at_utc: Mapped[str] = mapped_column(
        String,
        nullable=False,
    )
    acknowledged_at_utc: Mapped[str | None] = mapped_column(
        String,
        nullable=True,
    )


Index(
    "notifications_pending_index",
    NotificationRow.acknowledged_at_utc,
    NotificationRow.created_at_utc,
)


class EventRepository:
    def __init__(self, database_path: Path) -> None:
        database_url = (
            f"sqlite+pysqlite:///{database_path.resolve()}"
        )

        self._engine = create_engine(
            database_url,
            connect_args={
                "timeout": 5,
                "check_same_thread": False,
            },
        )

        event.listen(
            self._engine,
            "connect",
            _configure_sqlite_connection,
        )

        self._session_factory = sessionmaker(
            bind=self._engine,
            expire_on_commit=False,
        )

    def initialize(self) -> None:
        Base.metadata.create_all(self._engine)

    def recover_incomplete_events(self) -> None:
        with self._session_factory.begin() as session:
            session.execute(
                update(ScheduledEventRow)
                .where(
                    ScheduledEventRow.status
                    == EventStatus.EXECUTING.value
                )
                .values(status=EventStatus.SCHEDULED.value)
            )

            session.execute(
                update(EventExecutionRow)
                .where(EventExecutionRow.status == "running")
                .values(
                    status="abandoned",
                    error=(
                        "Tool server stopped before execution "
                        "completed."
                    ),
                )
            )

    def create_event(self, event: ScheduledEvent) -> None:
        with self._session_factory.begin() as session:
            session.add(
                ScheduledEventRow(
                    id=event.id,
                    summary=event.summary,
                    scheduled_for_utc=_to_storage_time(
                        event.scheduled_for_utc
                    ),
                    timezone=event.timezone,
                    action_type=event.action_type.value,
                    action_payload_json=json.dumps(
                        event.action_payload
                    ),
                    status=event.status.value,
                    created_at_utc=_to_storage_time(
                        event.created_at_utc
                    ),
                )
            )

    def list_events(
        self,
        include_history: bool = False,
    ) -> list[ScheduledEvent]:
        statement = select(ScheduledEventRow)

        if not include_history:
            statement = statement.where(
                ScheduledEventRow.status == EventStatus.SCHEDULED.value
            )

        statement = statement.order_by(
            ScheduledEventRow.scheduled_for_utc.asc()
        )

        with self._session_factory() as session:
            rows = session.scalars(statement).all()

        return [_event_from_row(row) for row in rows]

    def cancel_event(self, event_id: str) -> bool:
        with self._session_factory.begin() as session:
            result = session.execute(
                update(ScheduledEventRow)
                .where(
                    ScheduledEventRow.id == event_id,
                    ScheduledEventRow.status
                    == EventStatus.SCHEDULED.value,
                )
                .values(status=EventStatus.CANCELLED.value)
            )

        return result.rowcount == 1

    def claim_next_due_event(
        self,
        now_utc: datetime,
        execution_id: str,
    ) -> ScheduledEvent | None:
        with self._session_factory.begin() as session:
            row = session.scalars(
                select(ScheduledEventRow)
                .where(
                    ScheduledEventRow.status
                    == EventStatus.SCHEDULED.value,
                    ScheduledEventRow.scheduled_for_utc
                    <= _to_storage_time(now_utc),
                )
                .order_by(ScheduledEventRow.scheduled_for_utc.asc())
                .limit(1)
            ).first()

            if row is None:
                return None

            result = session.execute(
                update(ScheduledEventRow)
                .where(
                    ScheduledEventRow.id == row.id,
                    ScheduledEventRow.status
                    == EventStatus.SCHEDULED.value,
                )
                .values(status=EventStatus.EXECUTING.value)
            )

            if result.rowcount != 1:
                return None

            session.add(
                EventExecutionRow(
                    id=execution_id,
                    event_id=row.id,
                    started_at_utc=_to_storage_time(now_utc),
                    status="running",
                )
            )

            return _event_from_row(row)

    def complete_voice_notification(
        self,
        event: ScheduledEvent,
        execution_id: str,
        notification_id: str,
        completed_at_utc: datetime,
    ) -> None:
        completed_at = _to_storage_time(completed_at_utc)
        text = event.action_payload["text"]

        with self._session_factory.begin() as session:
            session.add(
                NotificationRow(
                    id=notification_id,
                    event_id=event.id,
                    execution_id=execution_id,
                    text=text,
                    scheduled_for_utc=_to_storage_time(
                        event.scheduled_for_utc
                    ),
                    created_at_utc=completed_at,
                )
            )

            session.execute(
                update(EventExecutionRow)
                .where(EventExecutionRow.id == execution_id)
                .values(
                    status="succeeded",
                    completed_at_utc=completed_at,
                )
            )

            session.execute(
                update(ScheduledEventRow)
                .where(ScheduledEventRow.id == event.id)
                .values(
                    status=EventStatus.COMPLETED.value,
                    completed_at_utc=completed_at,
                )
            )

    def fail_execution(
        self,
        event_id: str,
        execution_id: str,
        error: str,
        failed_at_utc: datetime,
    ) -> None:
        failed_at = _to_storage_time(failed_at_utc)

        with self._session_factory.begin() as session:
            session.execute(
                update(EventExecutionRow)
                .where(EventExecutionRow.id == execution_id)
                .values(
                    status="failed",
                    error=error,
                    completed_at_utc=failed_at,
                )
            )

            session.execute(
                update(ScheduledEventRow)
                .where(ScheduledEventRow.id == event_id)
                .values(status=EventStatus.SCHEDULED.value)
            )

    def next_unacknowledged_notification(
        self,
    ) -> Notification | None:
        with self._session_factory() as session:
            row = session.scalars(
                select(NotificationRow)
                .where(NotificationRow.acknowledged_at_utc.is_(None))
                .order_by(NotificationRow.created_at_utc.asc())
                .limit(1)
            ).first()

        return None if row is None else _notification_from_row(row)

    def acknowledge_notification(
        self,
        notification_id: str,
        acknowledged_at_utc: datetime,
    ) -> bool:
        with self._session_factory.begin() as session:
            result = session.execute(
                update(NotificationRow)
                .where(
                    NotificationRow.id == notification_id,
                    NotificationRow.acknowledged_at_utc.is_(None),
                )
                .values(
                    acknowledged_at_utc=_to_storage_time(
                        acknowledged_at_utc
                    )
                )
            )

        return result.rowcount == 1


def _configure_sqlite_connection(
    dbapi_connection,
    _connection_record,
) -> None:
    cursor = dbapi_connection.cursor()

    try:
        cursor.execute("PRAGMA foreign_keys = ON")
        cursor.execute("PRAGMA journal_mode = WAL")
    finally:
        cursor.close()


def _event_from_row(row: ScheduledEventRow) -> ScheduledEvent:
    return ScheduledEvent(
        id=row.id,
        summary=row.summary,
        scheduled_for_utc=_from_storage_time(
            row.scheduled_for_utc
        ),
        timezone=row.timezone,
        action_type=ActionType(row.action_type),
        action_payload=json.loads(row.action_payload_json),
        status=EventStatus(row.status),
        created_at_utc=_from_storage_time(row.created_at_utc),
    )


def _notification_from_row(row: NotificationRow) -> Notification:
    return Notification(
        id=row.id,
        event_id=row.event_id,
        text=row.text,
        scheduled_for_utc=_from_storage_time(
            row.scheduled_for_utc
        ),
        created_at_utc=_from_storage_time(row.created_at_utc),
    )


def _to_storage_time(value: datetime) -> str:
    return value.astimezone(timezone.utc).isoformat()


def _from_storage_time(value: str) -> datetime:
    return datetime.fromisoformat(value).astimezone(
        timezone.utc
    )
