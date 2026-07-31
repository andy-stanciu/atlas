import json
from datetime import datetime, timezone
from pathlib import Path

from sqlalchemy import (
    ForeignKey,
    Index,
    Integer,
    String,
    Text,
    UniqueConstraint,
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
    EventAction,
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
    actions_json: Mapped[str] = mapped_column(Text, nullable=False)
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


class EventActionExecutionRow(Base):
    __tablename__ = "event_action_executions"
    __table_args__ = (
        UniqueConstraint(
            "event_execution_id",
            "action_index",
            name="event_action_execution_unique",
        ),
    )

    id: Mapped[str] = mapped_column(String, primary_key=True)
    event_execution_id: Mapped[str] = mapped_column(
        ForeignKey("event_executions.id"),
        nullable=False,
    )
    action_index: Mapped[int] = mapped_column(
        Integer,
        nullable=False,
    )
    action_type: Mapped[str] = mapped_column(String, nullable=False)
    status: Mapped[str] = mapped_column(String, nullable=False)
    started_at_utc: Mapped[str] = mapped_column(
        String,
        nullable=False,
    )
    completed_at_utc: Mapped[str | None] = mapped_column(
        String,
        nullable=True,
    )
    error: Mapped[str | None] = mapped_column(Text, nullable=True)


Index(
    "event_action_executions_status_index",
    EventActionExecutionRow.event_execution_id,
    EventActionExecutionRow.status,
)


class NotificationRow(Base):
    __tablename__ = "notifications"
    __table_args__ = (
        UniqueConstraint(
            "event_execution_id",
            "action_index",
            "kind",
            name="notification_action_kind_unique",
        ),
    )

    id: Mapped[str] = mapped_column(String, primary_key=True)
    event_id: Mapped[str] = mapped_column(
        ForeignKey("scheduled_events.id"),
        nullable=False,
    )
    event_execution_id: Mapped[str] = mapped_column(
        ForeignKey("event_executions.id"),
        nullable=False,
    )
    action_index: Mapped[int] = mapped_column(
        Integer,
        nullable=False,
    )
    kind: Mapped[str] = mapped_column(String, nullable=False)
    text: Mapped[str] = mapped_column(Text, nullable=False)
    scheduled_for_utc: Mapped[str] = mapped_column(
        String,
        nullable=False,
    )
    created_at_utc: Mapped[str] = mapped_column(
        String,
        nullable=False,
    )
    delivered_at_utc: Mapped[str | None] = mapped_column(
        String,
        nullable=True,
    )
    acknowledged_at_utc: Mapped[str | None] = mapped_column(
        String,
        nullable=True,
    )


Index(
    "notifications_pending_index",
    NotificationRow.kind,
    NotificationRow.delivered_at_utc,
    NotificationRow.acknowledged_at_utc,
    NotificationRow.created_at_utc,
)


class EventRepository:
    def __init__(self, database_path: Path) -> None:
        database_path.parent.mkdir(parents=True, exist_ok=True)

        self._engine = create_engine(
            f"sqlite+pysqlite:///{database_path.resolve()}",
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
                .values(status=EventStatus.FAILED.value)
            )

            session.execute(
                update(EventExecutionRow)
                .where(EventExecutionRow.status == "running")
                .values(
                    status="failed",
                    error=(
                        "Tool server stopped before execution "
                        "completed."
                    ),
                )
            )

            session.execute(
                update(EventActionExecutionRow)
                .where(EventActionExecutionRow.status == "running")
                .values(
                    status="failed",
                    error=(
                        "Tool server stopped before action "
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
                    actions_json=json.dumps(
                        _actions_to_json(event.actions)
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
        now = _to_storage_time(now_utc)

        with self._session_factory.begin() as session:
            row = session.scalars(
                select(ScheduledEventRow)
                .where(
                    ScheduledEventRow.status
                    == EventStatus.SCHEDULED.value,
                    ScheduledEventRow.scheduled_for_utc <= now,
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
                    started_at_utc=now,
                    status="running",
                )
            )

            return _event_from_row(row)

    def start_action_execution(
        self,
        action_execution_id: str,
        execution_id: str,
        action_index: int,
        action_type: ActionType,
        started_at_utc: datetime,
    ) -> None:
        with self._session_factory.begin() as session:
            session.add(
                EventActionExecutionRow(
                    id=action_execution_id,
                    event_execution_id=execution_id,
                    action_index=action_index,
                    action_type=action_type.value,
                    status="running",
                    started_at_utc=_to_storage_time(started_at_utc),
                )
            )

    def complete_action_execution(
        self,
        action_execution_id: str,
        completed_at_utc: datetime,
    ) -> None:
        with self._session_factory.begin() as session:
            session.execute(
                update(EventActionExecutionRow)
                .where(
                    EventActionExecutionRow.id == action_execution_id
                )
                .values(
                    status="succeeded",
                    completed_at_utc=_to_storage_time(completed_at_utc),
                    error=None,
                )
            )

    def fail_action_execution(
        self,
        action_execution_id: str,
        error: str,
        failed_at_utc: datetime,
    ) -> None:
        with self._session_factory.begin() as session:
            session.execute(
                update(EventActionExecutionRow)
                .where(
                    EventActionExecutionRow.id == action_execution_id
                )
                .values(
                    status="failed",
                    error=error,
                    completed_at_utc=_to_storage_time(failed_at_utc),
                )
            )

    def create_notification(
        self,
        notification_id: str,
        event: ScheduledEvent,
        execution_id: str,
        action_index: int,
        kind: str,
        text: str,
        created_at_utc: datetime,
    ) -> None:
        with self._session_factory.begin() as session:
            session.add(
                NotificationRow(
                    id=notification_id,
                    event_id=event.id,
                    event_execution_id=execution_id,
                    action_index=action_index,
                    kind=kind,
                    text=text,
                    scheduled_for_utc=_to_storage_time(
                        event.scheduled_for_utc
                    ),
                    created_at_utc=_to_storage_time(created_at_utc),
                )
            )

    def complete_event_execution(
        self,
        event_id: str,
        execution_id: str,
        completed_at_utc: datetime,
    ) -> None:
        completed_at = _to_storage_time(completed_at_utc)

        with self._session_factory.begin() as session:
            session.execute(
                update(EventExecutionRow)
                .where(EventExecutionRow.id == execution_id)
                .values(
                    status="succeeded",
                    completed_at_utc=completed_at,
                    error=None,
                )
            )

            session.execute(
                update(ScheduledEventRow)
                .where(ScheduledEventRow.id == event_id)
                .values(
                    status=EventStatus.COMPLETED.value,
                    completed_at_utc=completed_at,
                )
            )

    def fail_event_execution(
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
                .values(
                    status=EventStatus.FAILED.value,
                    completed_at_utc=failed_at,
                )
            )

    def next_pending_notification(self) -> Notification | None:
        with self._session_factory() as session:
            row = session.scalars(
                select(NotificationRow)
                .where(
                    (
                        (NotificationRow.kind == "reminder")
                        & (
                            NotificationRow.acknowledged_at_utc.is_(
                                None
                            )
                        )
                    )
                    | (
                        (NotificationRow.kind == "confirmation")
                        & (NotificationRow.delivered_at_utc.is_(None))
                    )
                )
                .order_by(NotificationRow.created_at_utc.asc())
                .limit(1)
            ).first()

        return None if row is None else _notification_from_row(row)

    def mark_notification_delivered(
        self,
        notification_id: str,
        delivered_at_utc: datetime,
    ) -> bool:
        with self._session_factory.begin() as session:
            result = session.execute(
                update(NotificationRow)
                .where(
                    NotificationRow.id == notification_id,
                    NotificationRow.kind == "confirmation",
                    NotificationRow.delivered_at_utc.is_(None),
                )
                .values(
                    delivered_at_utc=_to_storage_time(delivered_at_utc)
                )
            )

        return result.rowcount == 1

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
                    NotificationRow.kind == "reminder",
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


def _actions_to_json(
    actions: tuple[EventAction, ...],
) -> list[dict]:
    return [
        {
            "type": action.type.value,
            "payload": action.payload,
            "confirmation_message": action.confirmation_message,
        }
        for action in actions
    ]


def _actions_from_json(value: str) -> tuple[EventAction, ...]:
    raw_actions = json.loads(value)

    return tuple(
        EventAction(
            type=ActionType(raw_action["type"]),
            payload=raw_action["payload"],
            confirmation_message=raw_action.get(
                "confirmation_message"
            ),
        )
        for raw_action in raw_actions
    )


def _event_from_row(row: ScheduledEventRow) -> ScheduledEvent:
    return ScheduledEvent(
        id=row.id,
        summary=row.summary,
        scheduled_for_utc=_from_storage_time(
            row.scheduled_for_utc
        ),
        timezone=row.timezone,
        actions=_actions_from_json(row.actions_json),
        status=EventStatus(row.status),
        created_at_utc=_from_storage_time(row.created_at_utc),
    )


def _notification_from_row(row: NotificationRow) -> Notification:
    return Notification(
        id=row.id,
        event_id=row.event_id,
        action_index=row.action_index,
        kind=row.kind,
        text=row.text,
        scheduled_for_utc=_from_storage_time(
            row.scheduled_for_utc
        ),
        created_at_utc=_from_storage_time(row.created_at_utc),
        delivered_at_utc=(
            None
            if row.delivered_at_utc is None
            else _from_storage_time(row.delivered_at_utc)
        ),
        acknowledged_at_utc=(
            None
            if row.acknowledged_at_utc is None
            else _from_storage_time(row.acknowledged_at_utc)
        ),
    )


def _to_storage_time(value: datetime) -> str:
    return value.astimezone(timezone.utc).isoformat()


def _from_storage_time(value: str) -> datetime:
    return datetime.fromisoformat(value).astimezone(
        timezone.utc
    )