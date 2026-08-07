from speaker_service import SpeakerError, SpeakerService
import logging
from flask import Flask, jsonify, request
from config import HOST, PORT, SCHEDULER_INTERVAL_SECONDS, TOOLS_PATH
from lights import LightService
from registry import ToolRegistry
from repository import Repository
from scheduler import Scheduler
from services import AtlasService


def create_app():
    class SuppressSpeechPollLogs(logging.Filter):
        def filter(self, record: logging.LogRecord) -> bool:
            message = record.getMessage()
            return '"GET /speech/next HTTP/1.1" 200' not in message

    app = Flask(__name__)
    logger = logging.getLogger("werkzeug")
    logger.addFilter(SuppressSpeechPollLogs())

    repository = Repository()
    repository.initialize()
    speaker_service = SpeakerService(repository)

    lights = LightService()
    service = AtlasService(repository)
    registry = ToolRegistry(TOOLS_PATH, service, lights)
    scheduler = Scheduler(repository, lights, SCHEDULER_INTERVAL_SECONDS)

    app.extensions["repository"] = repository
    app.extensions["registry"] = registry
    app.extensions["scheduler"] = scheduler
    app.extensions["speaker_service"] = speaker_service

    @app.get("/health")
    def health():
        return jsonify(ok=True)

    @app.get("/tools")
    def tools():
        return jsonify(tools=registry.tools)

    @app.post("/tools/call")
    def call_tool():
        payload = request.get_json(silent=True)

        if not isinstance(payload, dict):
            return jsonify(ok=False, error="Request body must be a JSON object."), 400

        name = payload.get("name")
        arguments = payload.get("arguments", {})
        app.logger.info("tool invocation: %s %s", name, arguments)

        if not isinstance(name, str) or not name.strip():
            return jsonify(ok=False, error="name must be a non-empty string."), 400

        result = registry.run(name.strip(), arguments)
        app.logger.info("tool result: %s %s", name, result)
        return jsonify(result)

    @app.get("/speech/next")
    def next_speech():
        return jsonify(ok=True, speech=repository.next_speech())

    @app.post("/speech/announcement/<int:speech_id>/delivered")
    def announcement_delivered(speech_id):
        if repository.deliver_announcement(speech_id):
            return jsonify(ok=True, speech_id=speech_id, status="delivered")
        return jsonify(ok=False, error="Active announcement was not found."), 404

    @app.get("/speaker/profiles")
    def speaker_profiles():
        return jsonify(speaker_service.profiles_response())

    @app.post("/speaker/enroll")
    def enroll_speaker():
        try:
            return jsonify(
                speaker_service.enroll_from_uploads(
                    display_name=request.form.get("name", ""),
                    uploads=request.files.getlist("audio"),
                )
            )
        except SpeakerError as error:
            return jsonify(
                ok=False,
                error=str(error),
            ), error.status_code
        except Exception:
            app.logger.exception("Speaker enrollment failed.")
            return jsonify(
                ok=False,
                error="Speaker enrollment failed.",
            ), 500

    @app.post("/speaker/<int:profile_id>/samples")
    def add_speaker_sample(profile_id):
        try:
            return jsonify(
                speaker_service.add_sample_from_uploads(
                    profile_id=profile_id,
                    uploads=request.files.getlist("audio"),
                )
            )
        except SpeakerError as error:
            return jsonify(
                ok=False,
                error=str(error),
            ), error.status_code
        except Exception:
            app.logger.exception("Speaker sample addition failed.")
            return jsonify(
                ok=False,
                error="Speaker sample addition failed.",
            ), 500

    @app.post("/speaker/<int:profile_id>/reinforce")
    def reinforce_speaker(profile_id):
        try:
            result = speaker_service.reinforce_from_uploads(
                profile_id=profile_id,
                uploads=request.files.getlist("audio"),
            )
            app.logger.info("Speaker reinforcement result: %s", result)
            return jsonify(result)
        except SpeakerError as error:
            return jsonify(ok=False, error=str(error)), error.status_code
        except Exception:
            app.logger.exception("Speaker reinforcement failed.")
            return jsonify(ok=False, error="Speaker reinforcement failed."), 500

    @app.post("/speaker/identify")
    def identify_speaker():
        try:
            result = speaker_service.identify_from_uploads(
                uploads=request.files.getlist("audio"),
            )
            app.logger.info("Speaker identification result: %s", result)
            return jsonify(result)
        except SpeakerError as error:
            return jsonify(
                ok=False,
                error=str(error),
            ), error.status_code
        except Exception:
            app.logger.exception("Speaker identification failed.")
            return jsonify(
                ok=False,
                error="Speaker identification failed.",
            ), 500

    @app.errorhandler(404)
    def not_found(_):
        return jsonify(ok=False, error="Not found."), 404

    @app.errorhandler(405)
    def method_not_allowed(_):
        return jsonify(ok=False, error="Method not allowed."), 405

    @app.errorhandler(500)
    def internal_error(error):
        app.logger.exception("Unhandled server error: %s", error)
        return jsonify(ok=False, error="Internal server error."), 500

    return app


if __name__ == "__main__":
    logging.basicConfig(
        level=logging.INFO, format="%(asctime)s %(levelname)s %(name)s: %(message)s"
    )

    app = create_app()
    scheduler = app.extensions["scheduler"]
    scheduler.start()

    print(f"Tool server listening on http://{HOST}:{PORT}", flush=True)

    try:
        app.run(host=HOST, port=PORT, threaded=True, debug=False, use_reloader=False)
    finally:
        scheduler.stop()
