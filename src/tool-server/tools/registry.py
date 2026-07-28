import json
from datetime import datetime
from pathlib import Path
from zoneinfo import ZoneInfo

from events.tool_handlers import EventToolHandlers

from .lights import LightService


class ToolRegistry:
    def __init__(
        self,
        tools_file: Path,
        lights: LightService,
        events: EventToolHandlers,
    ) -> None:
        self._tools = load_tools(tools_file)
        self._lights = lights
        self._events = events

    @property
    def definitions(self) -> list[dict]:
        return self._tools

    def run(self, name: str, arguments: object) -> dict:
        if not isinstance(arguments, dict):
            return {
                "ok": False,
                "error": "Tool arguments must be a JSON object.",
            }

        if name == "get_current_datetime":
            return current_datetime()

        if name == "get_light_status":
            return self._lights.get_status(arguments)

        if name == "set_light":
            return self._lights.set_power(arguments)

        if self._events.handles(name):
            return self._events.run(name, arguments)

        return {
            "ok": False,
            "error": f"Unknown tool: {name}.",
        }

    def should_print_light_snapshot(self, name: str) -> bool:
        return name in {"get_light_status", "set_light"}

    def print_light_snapshot(self) -> None:
        self._lights.print_snapshot()


def current_datetime() -> dict:
    now = datetime.now(ZoneInfo("America/Los_Angeles"))

    return {
        "ok": True,
        "date": now.strftime("%Y-%m-%d"),
        "time": now.strftime("%-I:%M %p"),
        "day_of_week": now.strftime("%A"),
    }


def load_tools(tools_file: Path) -> list[dict]:
    try:
        with tools_file.open(encoding="utf-8") as file:
            loaded_tools = json.load(file)
    except FileNotFoundError as error:
        raise RuntimeError(
            f"Tool definition file not found: {tools_file}"
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
        function = tool.get("function") if isinstance(tool, dict) else None

        if (
            tool.get("type") != "function"
            or not isinstance(function, dict)
            or not isinstance(function.get("name"), str)
        ):
            raise RuntimeError(
                "Every tool must have type 'function' and a function name."
            )

    return loaded_tools