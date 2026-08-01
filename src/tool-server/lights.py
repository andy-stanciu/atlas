import threading

ROOMS = ("kitchen", "living_room", "office", "bathroom", "bedroom")

ALIASES = {
    "kitchen": "kitchen",
    "living room": "living_room",
    "living_room": "living_room",
    "lounge": "living_room",
    "office": "office",
    "study": "office",
    "bathroom": "bathroom",
    "bedroom": "bedroom",
}


def normalize_room(value):
    if not isinstance(value, str):
        return None
    return ALIASES.get(value.strip().lower().replace("-", "_"))


class LightService:
    def __init__(self):
        self.lock = threading.Lock()
        self.state = dict.fromkeys(ROOMS, False)

    def get(self, room):
        room = normalize_room(room)
        if room is None:
            return {"ok": False, "error": "Unknown room."}
        with self.lock:
            return {
                "ok": True,
                "room": room,
                "power": "on" if self.state[room] else "off",
            }

    def set(self, room, power):
        room = normalize_room(room)
        if room is None:
            return {"ok": False, "error": "Unknown room."}
        if power not in ("on", "off"):
            return {"ok": False, "error": "power must be on or off."}
        with self.lock:
            self.state[room] = power == "on"
        return {"ok": True, "room": room, "power": power}
