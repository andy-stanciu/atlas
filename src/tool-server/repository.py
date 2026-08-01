import json
from sqlalchemy import select, update
from db import Base, Session, engine
from models import (
    ReminderRow,
    ReminderStatus,
    SequenceRow,
    SequenceStatus,
    SpeechItemRow,
    SpeechKind,
    SpeechStatus,
)
from time_utils import now_utc, to_storage


class Repository:
    def initialize(self):
        Base.metadata.create_all(engine)
        with Session.begin() as session:
            session.execute(
                update(SequenceRow)
                .where(SequenceRow.status == SequenceStatus.EXECUTING)
                .values(status=SequenceStatus.SCHEDULED, error=None)
            )
            session.execute(
                update(SpeechItemRow)
                .where(SpeechItemRow.status == SpeechStatus.ACTIVE)
                .values(status=SpeechStatus.QUEUED, activated_at_utc=None)
            )

    def create_reminder(self, text, scheduled_for, sequence_id=None):
        now = to_storage(now_utc())
        with Session.begin() as session:
            row = ReminderRow(
                text=text,
                scheduled_for_utc=to_storage(scheduled_for),
                status=ReminderStatus.SCHEDULED,
                sequence_id=sequence_id,
                created_at_utc=now,
            )
            session.add(row)
            session.flush()
            return row.id

    def list_reminders(self):
        with Session() as session:
            return session.scalars(
                select(ReminderRow)
                .where(ReminderRow.status == ReminderStatus.SCHEDULED)
                .order_by(ReminderRow.scheduled_for_utc)
            ).all()

    def cancel_reminder(self, reminder_id):
        with Session.begin() as session:
            result = session.execute(
                update(ReminderRow)
                .where(
                    ReminderRow.id == reminder_id,
                    ReminderRow.status == ReminderStatus.SCHEDULED,
                )
                .values(status=ReminderStatus.CANCELLED)
            )
            return result.rowcount == 1

    def claim_due_reminder(self, now):
        with Session.begin() as session:
            row = session.scalars(
                select(ReminderRow)
                .where(
                    ReminderRow.status == ReminderStatus.SCHEDULED,
                    ReminderRow.scheduled_for_utc <= to_storage(now),
                )
                .order_by(ReminderRow.scheduled_for_utc, ReminderRow.id)
                .limit(1)
            ).first()
            if row is None:
                return None
            result = session.execute(
                update(ReminderRow)
                .where(
                    ReminderRow.id == row.id,
                    ReminderRow.status == ReminderStatus.SCHEDULED,
                )
                .values(status=ReminderStatus.ACTIVE, activated_at_utc=to_storage(now))
            )
            return (row.id, row.text) if result.rowcount == 1 else None

    def activate_reminder(self, reminder_id):
        now = to_storage(now_utc())
        with Session.begin() as session:
            result = session.execute(
                update(ReminderRow)
                .where(
                    ReminderRow.id == reminder_id,
                    ReminderRow.status == ReminderStatus.SCHEDULED,
                )
                .values(status=ReminderStatus.ACTIVE, activated_at_utc=now)
            )
            return result.rowcount == 1

    def create_sequence(self, actions, scheduled_for):
        now = to_storage(now_utc())
        with Session.begin() as session:
            row = SequenceRow(
                actions_json=json.dumps(actions),
                scheduled_for_utc=to_storage(scheduled_for),
                status=SequenceStatus.SCHEDULED,
                created_at_utc=now,
            )
            session.add(row)
            session.flush()
            return row.id

    def list_sequences(self):
        with Session() as session:
            return session.scalars(
                select(SequenceRow)
                .where(SequenceRow.status == SequenceStatus.SCHEDULED)
                .order_by(SequenceRow.scheduled_for_utc, SequenceRow.id)
            ).all()

    def cancel_sequence(self, sequence_id):
        with Session.begin() as session:
            result = session.execute(
                update(SequenceRow)
                .where(
                    SequenceRow.id == sequence_id,
                    SequenceRow.status == SequenceStatus.SCHEDULED,
                )
                .values(status=SequenceStatus.CANCELLED)
            )
            return result.rowcount == 1

    def claim_due_sequence(self, now):
        with Session.begin() as session:
            row = session.scalars(
                select(SequenceRow)
                .where(
                    SequenceRow.status == SequenceStatus.SCHEDULED,
                    SequenceRow.scheduled_for_utc <= to_storage(now),
                )
                .order_by(SequenceRow.scheduled_for_utc, SequenceRow.id)
                .limit(1)
            ).first()
            if row is None:
                return None
            result = session.execute(
                update(SequenceRow)
                .where(
                    SequenceRow.id == row.id,
                    SequenceRow.status == SequenceStatus.SCHEDULED,
                )
                .values(status=SequenceStatus.EXECUTING)
            )
            return (
                (row.id, json.loads(row.actions_json)) if result.rowcount == 1 else None
            )

    def finish_sequence(self, sequence_id, error=None):
        with Session.begin() as session:
            session.execute(
                update(SequenceRow)
                .where(SequenceRow.id == sequence_id)
                .values(
                    status=SequenceStatus.FAILED if error else SequenceStatus.COMPLETED,
                    completed_at_utc=to_storage(now_utc()),
                    error=error,
                )
            )

    def enqueue_speech(self, kind, text, reminder_id=None):
        with Session.begin() as session:
            session.add(
                SpeechItemRow(
                    kind=kind,
                    status=SpeechStatus.QUEUED,
                    text=text,
                    reminder_id=reminder_id,
                    created_at_utc=to_storage(now_utc()),
                )
            )

    def next_speech(self):
        now = to_storage(now_utc())
        with Session.begin() as session:
            row = session.scalars(
                select(SpeechItemRow)
                .where(SpeechItemRow.status == SpeechStatus.ACTIVE)
                .order_by(SpeechItemRow.id)
                .limit(1)
            ).first()

            if row is None:
                row = session.scalars(
                    select(SpeechItemRow)
                    .where(SpeechItemRow.status == SpeechStatus.QUEUED)
                    .order_by(SpeechItemRow.created_at_utc, SpeechItemRow.id)
                    .limit(1)
                ).first()
                if row is not None:
                    row.status = SpeechStatus.ACTIVE
                    row.activated_at_utc = now

            if row is None:
                return None

            return {
                "id": row.id,
                "kind": row.kind,
                "text": row.text,
                "reminder_id": row.reminder_id,
            }

    def deliver_announcement(self, speech_id):
        with Session.begin() as session:
            result = session.execute(
                update(SpeechItemRow)
                .where(
                    SpeechItemRow.id == speech_id,
                    SpeechItemRow.kind == SpeechKind.ANNOUNCEMENT,
                    SpeechItemRow.status == SpeechStatus.ACTIVE,
                )
                .values(
                    status=SpeechStatus.DELIVERED,
                    delivered_at_utc=to_storage(now_utc()),
                )
            )
            return result.rowcount == 1

    def acknowledge_active_reminder(self):
        now = to_storage(now_utc())
        with Session.begin() as session:
            item = session.scalars(
                select(SpeechItemRow)
                .where(
                    SpeechItemRow.kind == SpeechKind.REMINDER,
                    SpeechItemRow.status == SpeechStatus.ACTIVE,
                )
                .order_by(SpeechItemRow.id)
                .limit(1)
            ).first()

            if item is None:
                return None

            item.status = SpeechStatus.ACKNOWLEDGED
            item.acknowledged_at_utc = now

            result = session.execute(
                update(ReminderRow)
                .where(
                    ReminderRow.id == item.reminder_id,
                    ReminderRow.status == ReminderStatus.ACTIVE,
                )
                .values(status=ReminderStatus.ACKNOWLEDGED, acknowledged_at_utc=now)
            )

            return item.reminder_id if result.rowcount == 1 else None
