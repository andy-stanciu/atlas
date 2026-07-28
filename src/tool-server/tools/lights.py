import threading


class LightService:
    def __init__(self) -> None:
        self._lock = threading.Lock()

        # mock lights for now by plainly storing state in memory
        self._lights = {
            "kitchen": False,
            "living_room": False,
            "office": False,
            "bedroom": False,
        }

    def get_status(self, arguments: dict) -> dict:
        room = normalize_room(arguments.get("room"))

        if room is None:
            return unknown_room_response()

        with self._lock:
            power = "on" if self._lights[room] else "off"

        return {
            "ok": True,
            "room": room,
            "power": power,
        }

    def set_power(self, arguments: dict) -> dict:
        room = normalize_room(arguments.get("room"))

        if room is None:
            return unknown_room_response()

        power = arguments.get("power")

        if power not in {"on", "off"}:
            return {
                "ok": False,
                "error": "Power must be either on or off.",
            }

        with self._lock:
            self._lights[room] = power == "on"

        return {
            "ok": True,
            "room": room,
            "power": power,
        }

    def snapshot(self) -> dict[str, str]:
        with self._lock:
            return {
                room: "on" if is_on else "off"
                for room, is_on in self._lights.items()
            }

    def print_snapshot(self) -> None:
        print("\n[mock light status]", flush=True)

        for room, power in self.snapshot().items():
            print(f"  {room}: {power}", flush=True)


def normalize_room(value: object) -> str | None:
    if not isinstance(value, str):
        return None

    aliases = {
        "kitchen": "kitchen",
        "living_room": "living_room",
        "livingroom": "living_room",
        "lounge": "living_room",
        "office": "office",
        "study": "office",
        "bedroom": "bedroom",
    }

    return aliases.get(value.lower().strip().replace(" ", "_"))


def unknown_room_response() -> dict:
    return {
        "ok": False,
        "error": (
            "Unknown room. Valid rooms are kitchen, living_room, "
            "office, and bedroom."
        ),
    }