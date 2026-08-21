import json
from pathlib import Path
from lights import LightService
from time_utils import ValidationError, current_datetime


class ToolRegistry:
    def __init__(self, tools_path: Path, service, lights: LightService):
        self.tools = load_tools(tools_path)
        self.service = service
        self.lights = lights

    def run(self, name, arguments):
        if not isinstance(arguments, dict):
            return {"ok": False, "error": "Tool arguments must be a JSON object."}

        handlers = {
            "get_current_datetime": lambda: {"ok": True, **current_datetime()},
            "get_light_status": lambda: self.lights.get(arguments.get("room")),
            "set_light": lambda: self.lights.set(
                arguments.get("room"), arguments.get("power")
            ),
            "schedule_reminder": lambda: self.service.schedule_reminder(arguments),
            "list_reminders": self.service.list_reminders,
            "cancel_reminder": lambda: self.service.cancel_reminder(arguments),
            "address_reminder": lambda: self.service.address_reminder(arguments),
            "schedule_sequence": lambda: self.service.schedule_sequence(arguments),
            "list_sequences": self.service.list_sequences,
            "cancel_sequence": lambda: self.service.cancel_sequence(arguments),
        }

        handler = handlers.get(name)

        if handler is None:
            return {"ok": False, "error": f"Unknown tool: {name}."}

        try:
            return handler()
        except ValidationError as error:
            return {"ok": False, "error": str(error)}


def load_tools(path):
    with path.open(encoding="utf-8") as file:
        tools = json.load(file)

    if not isinstance(tools, list):
        raise RuntimeError("tools.json must contain an array.")

    return tools
