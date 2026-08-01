import logging
import threading
from models import ActionType, SpeechKind
from time_utils import now_utc


class Scheduler:
    def __init__(self, repository, lights, interval):
        self.repository = repository
        self.lights = lights
        self.interval = interval
        self.stop_event = threading.Event()
        self.thread = None
        self.logger = logging.getLogger(__name__)

    def start(self):
        if self.thread is not None:
            return
        self.thread = threading.Thread(
            target=self.run, name="atlas-scheduler", daemon=True
        )
        self.thread.start()

    def stop(self):
        self.stop_event.set()
        if self.thread is not None:
            self.thread.join(timeout=2)
            self.thread = None

    def run(self):
        self.logger.info("Scheduler started.")
        while not self.stop_event.is_set():
            try:
                self.run_due()
            except Exception:
                self.logger.exception("Scheduler error.")
            self.stop_event.wait(self.interval)
        self.logger.info("Scheduler stopped.")

    def run_due(self):
        now = now_utc()

        while reminder := self.repository.claim_due_reminder(now):
            reminder_id, text = reminder
            self.repository.enqueue_speech(SpeechKind.REMINDER, text, reminder_id)

        while sequence := self.repository.claim_due_sequence(now):
            sequence_id, actions = sequence

            try:
                for action in actions:
                    if action["type"] == ActionType.LIGHT:
                        result = self.lights.set(action["room"], action["power"])
                        if not result["ok"]:
                            raise RuntimeError(result["error"])

                    elif action["type"] == ActionType.ANNOUNCEMENT:
                        self.repository.enqueue_speech(
                            SpeechKind.ANNOUNCEMENT, action["text"]
                        )

                    elif action["type"] == ActionType.REMINDER:
                        reminder_id = self.repository.create_reminder(
                            action["text"], now, sequence_id
                        )
                        if not self.repository.activate_reminder(reminder_id):
                            raise RuntimeError("Could not activate sequence reminder.")
                        self.repository.enqueue_speech(
                            SpeechKind.REMINDER, action["text"], reminder_id
                        )

                    else:
                        raise RuntimeError(f"Unsupported action type: {action['type']}")

                self.repository.finish_sequence(sequence_id)

            except Exception as error:
                self.repository.finish_sequence(sequence_id, str(error))
                raise
