import json
from datetime import timedelta
from models import ActionType
from lights import normalize_room
from recurrence import RecurrenceError, attach_anchor, parse_repeat
from time_utils import (
    TIMEZONE,
    ValidationError,
    current_datetime,
    from_storage,
    now_utc,
    resolve_schedule,
    schedule_fields,
)


def required_text(arguments, field):
    value = arguments.get(field)
    if not isinstance(value, str) or not value.strip():
        raise ValidationError(f"{field} must be a non-empty string.")
    return value.strip()


def required_int(arguments, field):
    value = arguments.get(field)
    if isinstance(value, bool) or not isinstance(value, int) or value < 1:
        raise ValidationError(f"{field} must be a positive integer.")
    return value


def parse_actions(arguments):
    raw_actions = arguments.get("actions")
    if not isinstance(raw_actions, list) or not raw_actions:
        raise ValidationError("actions must be a non-empty array.")

    actions = []

    for index, raw_action in enumerate(raw_actions):
        if not isinstance(raw_action, dict):
            raise ValidationError(f"actions[{index}] must be an object.")

        action_type = raw_action.get("type")

        if action_type in (ActionType.REMINDER, ActionType.ANNOUNCEMENT):
            actions.append(
                {"type": action_type, "text": required_text(raw_action, "text")}
            )
            continue

        if action_type == ActionType.LIGHT:
            room = normalize_room(raw_action.get("room"))
            power = raw_action.get("power")

            if room is None:
                raise ValidationError(f"actions[{index}].room is invalid.")
            if power not in ("on", "off"):
                raise ValidationError(f"actions[{index}].power must be on or off.")

            actions.append({"type": action_type, "room": room, "power": power})
            continue

        raise ValidationError(
            f"actions[{index}].type must be reminder, announcement, or light."
        )

    return actions


def describe_actions(actions):
    descriptions = []

    for action in actions:
        if action["type"] == ActionType.LIGHT:
            descriptions.append(f"turn {action['power']} {action['room']} lights")
        elif action["type"] == ActionType.REMINDER:
            descriptions.append(f"remind: {action['text']}")
        else:
            descriptions.append(f"announce: {action['text']}")

    return descriptions


def resolve_schedule_and_recurrence(arguments):
    repeat = arguments.get("repeat")

    if repeat is None:
        return resolve_schedule(arguments), None

    try:
        rule = parse_repeat(repeat)
    except RecurrenceError as error:
        raise ValidationError(str(error)) from error

    has_timing = any(
        arguments.get(field) is not None for field in ("in_minutes", "time", "date")
    )

    if rule["freq"] == "hourly" and not has_timing:
        # "Every hour" with no clock time anchors at the top of the
        # next interval rather than demanding one from the user.
        now_local = now_utc().astimezone(TIMEZONE)
        top = now_local.replace(minute=0, second=0, microsecond=0)
        anchor_local = top + timedelta(hours=rule["interval"])
        scheduled_for = anchor_local
    else:
        if not has_timing:
            raise ValidationError(
                "Repeating schedules need a time of day, for example "
                "time='8:00 AM'. Ask the user what time."
            )
        scheduled_for = resolve_schedule(arguments)
        anchor_local = scheduled_for.astimezone(TIMEZONE)

    return scheduled_for, attach_anchor(rule, anchor_local)


def recurrence_fields(rule):
    return {"recurrence": rule["speakable"]} if rule else {}


class AtlasService:
    def __init__(self, repository):
        self.repository = repository

    def schedule_reminder(self, arguments):
        text = required_text(arguments, "text")
        scheduled_for, recurrence = resolve_schedule_and_recurrence(arguments)
        reminder_id = self.repository.create_reminder(
            text, scheduled_for, recurrence=recurrence
        )

        return {
            "ok": True,
            "reminder_id": reminder_id,
            "text": text,
            **schedule_fields(scheduled_for),
            **recurrence_fields(recurrence),
        }

    def list_reminders(self):
        reminders = [
            {
                "reminder_id": row.id,
                "text": row.text,
                **schedule_fields(from_storage(row.scheduled_for_utc)),
                **recurrence_fields(
                    json.loads(row.recurrence_json) if row.recurrence_json else None
                ),
            }
            for row in self.repository.list_reminders()
        ]

        return {
            "ok": True,
            "reminders": reminders,
            "current_datetime": current_datetime(),
        }

    def cancel_reminder(self, arguments):
        reminder_id = required_int(arguments, "reminder_id")

        if not self.repository.cancel_reminder(reminder_id):
            return {
                "ok": False,
                "error": "Reminder was not found or is no longer scheduled.",
            }

        return {"ok": True, "reminder_id": reminder_id, "status": "cancelled"}

    def address_reminder(self, arguments):
        acknowledged = arguments.get("acknowledged")
        if not isinstance(acknowledged, bool):
            raise ValidationError("acknowledged must be a boolean.")
        if not acknowledged:
            return {"ok": True, "status": "still_active"}

        reminder_id = self.repository.acknowledge_active_reminder()

        if reminder_id is None:
            return {"ok": False, "error": "No active reminder."}

        return {"ok": True, "reminder_id": reminder_id, "status": "acknowledged"}

    def schedule_sequence(self, arguments):
        actions = parse_actions(arguments)
        scheduled_for, recurrence = resolve_schedule_and_recurrence(arguments)
        sequence_id = self.repository.create_sequence(
            actions, scheduled_for, recurrence=recurrence
        )

        return {
            "ok": True,
            "sequence_id": sequence_id,
            "actions": describe_actions(actions),
            **schedule_fields(scheduled_for),
            **recurrence_fields(recurrence),
        }

    def list_sequences(self):
        sequences = [
            {
                "sequence_id": row.id,
                "actions": describe_actions(json.loads(row.actions_json)),
                **schedule_fields(from_storage(row.scheduled_for_utc)),
                **recurrence_fields(
                    json.loads(row.recurrence_json) if row.recurrence_json else None
                ),
            }
            for row in self.repository.list_sequences()
        ]

        return {
            "ok": True,
            "sequences": sequences,
            "current_datetime": current_datetime(),
        }

    def cancel_sequence(self, arguments):
        sequence_id = required_int(arguments, "sequence_id")

        if not self.repository.cancel_sequence(sequence_id):
            return {
                "ok": False,
                "error": "Sequence was not found or is no longer scheduled.",
            }

        return {"ok": True, "sequence_id": sequence_id, "status": "cancelled"}
