import json
from datetime import datetime
import threading
from pathlib import Path

from flask import Flask, jsonify, request


HOST = "127.0.0.1"
PORT = 8090

app = Flask(__name__)

lights_lock = threading.Lock()

lights = {
    "kitchen": False,
    "living_room": False,
    "office": False,
    "bedroom": False,
}

rooms = [
    "kitchen",
    "living_room",
    "office",
    "bedroom",
]

TOOLS_FILE = Path(__file__).with_name("tools.json")

def load_tools() -> list[dict]:
    try:
        with TOOLS_FILE.open(encoding="utf-8") as file:
            loaded_tools = json.load(file)
    except FileNotFoundError as error:
        raise RuntimeError(
            f"Tool definition file not found: {TOOLS_FILE}"
        ) from error
    except json.JSONDecodeError as error:
        raise RuntimeError(
            f"Invalid JSON in tool definition file: {error}"
        ) from error

    if not isinstance(loaded_tools, list):
        raise RuntimeError(
            "tools.json must contain a top-level JSON array."
        )

    for tool in loaded_tools:
        if not isinstance(tool, dict):
            raise RuntimeError(
                "Each item in tools.json must be a JSON object."
            )

        function = tool.get("function")

        if (
            tool.get("type") != "function"
            or not isinstance(function, dict)
            or not isinstance(function.get("name"), str)
        ):
            raise RuntimeError(
                "Every tool must have type 'function' and a function name."
            )

    return loaded_tools


tools = load_tools()


def current_datetime() -> dict:
    now = datetime.now().astimezone()

    return {
        "ok": True,
        "iso_8601": now.isoformat(),
        "date": now.strftime("%Y-%m-%d"),
        "time": now.strftime("%H:%M:%S"),
        "day_of_week": now.strftime("%A"),
        "time_zone": now.tzname(),
        "utc_offset": now.strftime("%z"),
    }


def normalize_room(value: object) -> str | None:
    if not isinstance(value, str):
        return None

    normalized = value.lower().strip().replace(" ", "_")

    aliases = {
        "kitchen": "kitchen",
        "living_room": "living_room",
        "livingroom": "living_room",
        "lounge": "living_room",
        "office": "office",
        "study": "office",
        "bedroom": "bedroom",
    }

    return aliases.get(normalized)


def light_snapshot() -> dict[str, str]:
    with lights_lock:
        return {
            room: "on" if lights[room] else "off"
            for room in rooms
        }


def print_light_snapshot() -> None:
    print("\n[mock light status]", flush=True)

    for room, power in light_snapshot().items():
        print(f"  {room}: {power}", flush=True)


def run_tool(name: str, arguments: object) -> dict:
    if not isinstance(arguments, dict):
        return {
            "ok": False,
            "error": "Tool arguments must be a JSON object.",
        }

    if name == "get_current_datetime":
        return current_datetime()

    room = normalize_room(arguments.get("room"))

    if room is None:
        return {
            "ok": False,
            "error": (
                "Unknown room. Valid rooms are kitchen, living_room, "
                "office, and bedroom."
            ),
        }

    if name == "get_light_status":
        with lights_lock:
            power = "on" if lights[room] else "off"

        return {
            "ok": True,
            "room": room,
            "power": power,
        }

    if name == "set_light":
        power = arguments.get("power")

        if power not in {"on", "off"}:
            return {
                "ok": False,
                "error": "Power must be either on or off.",
            }

        with lights_lock:
            lights[room] = power == "on"

        return {
            "ok": True,
            "room": room,
            "power": power,
        }

    return {
        "ok": False,
        "error": f"Unknown tool: {name}.",
    }


@app.get("/health")
def health():
    return jsonify(ok=True)


@app.get("/tools")
def get_tools():
    return jsonify(tools=tools)


@app.post("/tools/call")
def call_tool():
    payload = request.get_json(silent=True)

    if not isinstance(payload, dict):
        return jsonify(
            ok=False,
            error="Request body must be a JSON object.",
        ), 400

    name = payload.get("name")
    arguments = payload.get("arguments")

    if not isinstance(name, str) or not name:
        return jsonify(
            ok=False,
            error="Field 'name' must be a non-empty string.",
        ), 400

    result = run_tool(name, arguments)

    print(f"\n[tool] {name} {arguments}", flush=True)
    
    if name in {"get_light_status", "set_light"}:
        print_light_snapshot()

    return jsonify(result)


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


if __name__ == "__main__":
    print(
        f"Tool server listening on http://{HOST}:{PORT}",
        flush=True,
    )

    app.run(
        host=HOST,
        port=PORT,
        debug=False,
        threaded=True,
    )