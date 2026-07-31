import logging
from pathlib import Path

from flask import Flask, jsonify, request

from events.notifications import NotificationService
from events.repository import EventRepository
from events.scheduler import EventScheduler
from events.service import EventService
from events.tool_handlers import EventToolHandlers
from tools.lights import LightService
from tools.registry import ToolRegistry


HOST = "127.0.0.1"
PORT = 8090

BASE_DIR = Path(__file__).parent
DATABASE_PATH = BASE_DIR / "data" / "atlas.db"
TOOLS_FILE = BASE_DIR / "tools.json"


class NotificationPollFilter(logging.Filter):
    def filter(self, record: logging.LogRecord) -> bool:
        message = record.getMessage()

        return not (
            '"GET /notifications/next HTTP/' in message
            and " 200 -" in message
        )


def create_app() -> Flask:
    app = Flask(__name__)

    repository = EventRepository(DATABASE_PATH)
    repository.initialize()

    lights = LightService()
    event_service = EventService(repository)
    notification_service = NotificationService(repository)
    scheduler = EventScheduler(repository=repository, lights=lights)
    event_tools = EventToolHandlers(event_service)

    registry = ToolRegistry(
        tools_file=TOOLS_FILE,
        lights=lights,
        events=event_tools,
        notifications=notification_service,
    )

    app.extensions["event_scheduler"] = scheduler
    app.extensions["notification_service"] = notification_service
    app.extensions["tool_registry"] = registry

    @app.get("/health")
    def health():
        return jsonify(ok=True)

    @app.get("/tools")
    def get_tools():
        return jsonify(tools=registry.definitions)

    @app.post("/tools/call")
    def call_tool():
        payload = request.get_json(silent=True)

        if not isinstance(payload, dict):
            return jsonify(
                ok=False,
                error="Request body must be a JSON object.",
            ), 400

        name = payload.get("name")
        arguments = payload.get("arguments", {})

        if not isinstance(name, str) or not name.strip():
            return jsonify(
                ok=False,
                error="Field 'name' must be a non-empty string.",
            ), 400

        result = registry.run(name.strip(), arguments)

        print(f"\n[tool] {name} {arguments}", flush=True)

        if registry.should_print_light_snapshot(name):
            registry.print_light_snapshot()

        return jsonify(result)

    @app.get("/notifications/next")
    def next_notification():
        return jsonify(notification_service.next_notification())

    @app.post("/notifications/<notification_id>/ack")
    def acknowledge_notification(notification_id: str):
        result = notification_service.acknowledge(notification_id)

        return jsonify(result), 200 if result["ok"] else 404

    @app.post("/notifications/<notification_id>/delivered")
    def mark_notification_delivered(notification_id: str):
        result = notification_service.mark_delivered(notification_id)

        return jsonify(result), 200 if result["ok"] else 404

    @app.errorhandler(404)
    def not_found(_error):
        return jsonify(
            ok=False,
            error="Not found.",
        ), 404

    @app.errorhandler(405)
    def method_not_allowed(_error):
        return jsonify(
            ok=False,
            error="Method not allowed.",
        ), 405

    @app.errorhandler(500)
    def internal_error(error):
        app.logger.exception("Unhandled tool-server error: %s", error)

        return jsonify(
            ok=False,
            error="Internal tool-server error.",
        ), 500

    return app

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s %(levelname)s %(name)s: %(message)s",
)
logging.getLogger("werkzeug").addFilter(
    NotificationPollFilter()
)
app = create_app()


if __name__ == "__main__":
    scheduler = app.extensions["event_scheduler"]
    scheduler.start()

    print(
        f"Tool server listening on http://{HOST}:{PORT}",
        flush=True,
    )

    try:
        app.run(
            host=HOST,
            port=PORT,
            debug=False,
            threaded=True,
            use_reloader=False,
        )
    finally:
        scheduler.stop()
