from enum import StrEnum
from sqlalchemy import ForeignKey, Index, Integer, String, Text, UniqueConstraint
from sqlalchemy.orm import Mapped, mapped_column
from db import Base


class ReminderStatus(StrEnum):
    SCHEDULED = "scheduled"
    ACTIVE = "active"
    ACKNOWLEDGED = "acknowledged"
    CANCELLED = "cancelled"


class SequenceStatus(StrEnum):
    SCHEDULED = "scheduled"
    EXECUTING = "executing"
    COMPLETED = "completed"
    CANCELLED = "cancelled"
    FAILED = "failed"


class ActionType(StrEnum):
    LIGHT = "light"
    ANNOUNCEMENT = "announcement"
    REMINDER = "reminder"


class SpeechKind(StrEnum):
    REMINDER = "reminder"
    ANNOUNCEMENT = "announcement"


class SpeechStatus(StrEnum):
    QUEUED = "queued"
    ACTIVE = "active"
    DELIVERED = "delivered"
    ACKNOWLEDGED = "acknowledged"


class ReminderRow(Base):
    __tablename__ = "reminders"

    id: Mapped[int] = mapped_column(Integer, primary_key=True, autoincrement=True)
    text: Mapped[str] = mapped_column(Text, nullable=False)
    scheduled_for_utc: Mapped[str] = mapped_column(String, nullable=False)
    status: Mapped[str] = mapped_column(
        String, nullable=False, default=ReminderStatus.SCHEDULED
    )
    sequence_id: Mapped[int | None] = mapped_column(
        ForeignKey("sequences.id"), nullable=True
    )
    created_at_utc: Mapped[str] = mapped_column(String, nullable=False)
    activated_at_utc: Mapped[str | None] = mapped_column(String, nullable=True)
    acknowledged_at_utc: Mapped[str | None] = mapped_column(String, nullable=True)


Index("reminders_due", ReminderRow.status, ReminderRow.scheduled_for_utc)


class SequenceRow(Base):
    __tablename__ = "sequences"

    id: Mapped[int] = mapped_column(Integer, primary_key=True, autoincrement=True)
    scheduled_for_utc: Mapped[str] = mapped_column(String, nullable=False)
    status: Mapped[str] = mapped_column(
        String, nullable=False, default=SequenceStatus.SCHEDULED
    )
    actions_json: Mapped[str] = mapped_column(Text, nullable=False)
    created_at_utc: Mapped[str] = mapped_column(String, nullable=False)
    completed_at_utc: Mapped[str | None] = mapped_column(String, nullable=True)
    error: Mapped[str | None] = mapped_column(Text, nullable=True)


Index("sequences_due", SequenceRow.status, SequenceRow.scheduled_for_utc)


class SpeechItemRow(Base):
    __tablename__ = "speech_items"
    __table_args__ = (
        UniqueConstraint("reminder_id", name="one_speech_item_per_reminder"),
    )

    id: Mapped[int] = mapped_column(Integer, primary_key=True, autoincrement=True)
    kind: Mapped[str] = mapped_column(String, nullable=False)
    status: Mapped[str] = mapped_column(
        String, nullable=False, default=SpeechStatus.QUEUED
    )
    text: Mapped[str] = mapped_column(Text, nullable=False)
    reminder_id: Mapped[int | None] = mapped_column(
        ForeignKey("reminders.id"), nullable=True
    )
    created_at_utc: Mapped[str] = mapped_column(String, nullable=False)
    activated_at_utc: Mapped[str | None] = mapped_column(String, nullable=True)
    delivered_at_utc: Mapped[str | None] = mapped_column(String, nullable=True)
    acknowledged_at_utc: Mapped[str | None] = mapped_column(String, nullable=True)


Index("speech_queue", SpeechItemRow.status, SpeechItemRow.created_at_utc)
