import threading
import time

import requests

from config import (
    LIBRESPOT_TIMEOUT,
    LIBRESPOT_URL,
    SPOTIFY_CLIENT_ID,
    SPOTIFY_CLIENT_SECRET,
)
from time_utils import ValidationError

SEARCH_TYPES = ("track", "album", "playlist")
SPOTIFY_API = "https://api.spotify.com/v1"
TOKEN_URL = "https://accounts.spotify.com/api/token"


class _NotFound(Exception):
    def __init__(self, path):
        self.path = path


class MusicService:
    def __init__(self, base_url=None, timeout=LIBRESPOT_TIMEOUT):
        self.base = (base_url or LIBRESPOT_URL).rstrip("/")
        self.timeout = timeout
        self._app_token = None
        self._app_token_expires_at = 0.0

    def _request(self, method, path, body=None, params=None):
        try:
            response = requests.request(
                method,
                self.base + path,
                json=body,
                params=params,
                timeout=self.timeout,
            )
        except requests.RequestException as error:
            raise ValidationError(f"Music player unreachable: {error}.") from error

        if response.status_code == 404:
            raise _NotFound(path)
        if response.status_code == 204:
            raise ValidationError("Music player is not logged in to Spotify.")
        if not response.ok:
            raise ValidationError(
                f"Music player error ({response.status_code}): {response.text[:200]}"
            )

        try:
            return response.json()
        except ValueError:
            return {}

    def _command(self, method, path, body=None):
        try:
            return self._request(method, path, body=body)
        except _NotFound as error:
            raise ValidationError(
                f"Music player does not support '{error.path}'."
            ) from error

    def _invalidate_app_token(self):
        self._app_token = None
        self._app_token_expires_at = 0.0

    def _app_access_token(self):
        if not SPOTIFY_CLIENT_ID or not SPOTIFY_CLIENT_SECRET:
            return None
        if self._app_token and time.monotonic() < self._app_token_expires_at:
            return self._app_token
        try:
            response = requests.post(
                TOKEN_URL,
                data={
                    "grant_type": "client_credentials",
                    "client_id": SPOTIFY_CLIENT_ID,
                    "client_secret": SPOTIFY_CLIENT_SECRET,
                },
                timeout=self.timeout,
            )
        except requests.RequestException:
            return None
        if response.ok:
            data = response.json()
            self._app_token = data.get("access_token")
            expires_in = int(data.get("expires_in") or 3600)
            # Refresh 5 minutes early so a search never races the expiry.
            self._app_token_expires_at = time.monotonic() + max(60, expires_in - 300)
        return self._app_token

    def _session_token(self):
        data = self._command("POST", "/token")
        token = data.get("token")
        if not token:
            raise ValidationError("Music player did not return an access token.")
        return token

    def _spotify_get(self, path, params, token):
        try:
            for attempt in range(2):
                response = requests.get(
                    f"{SPOTIFY_API}{path}",
                    params=params,
                    headers={"Authorization": f"Bearer {token}"},
                    timeout=self.timeout,
                )
                if response.status_code == 429 and attempt == 0:
                    try:
                        delay = min(int(response.headers.get("Retry-After", "3")), 5)
                    except ValueError:
                        delay = 3
                    time.sleep(delay)
                    continue
                break
        except requests.RequestException as error:
            raise ValidationError(f"Spotify unreachable: {error}.") from error
        return response

    def _spotify_request(self, path, params):
        use_app = bool(SPOTIFY_CLIENT_ID and SPOTIFY_CLIENT_SECRET)

        for attempt in range(2):
            token = self._app_access_token() if use_app else self._session_token()
            if not token:
                raise ValidationError("No Spotify access token available.")

            response = self._spotify_get(path, params, token)

            if response.status_code == 401 and use_app and attempt == 0:
                # Expired token: re-mint once and replay.
                self._invalidate_app_token()
                continue
            break

        if not response.ok:
            if response.status_code == 429:
                raise ValidationError(
                    "Spotify search is rate limited. Set ATLAS_SPOTIFY_CLIENT_ID and "
                    "ATLAS_SPOTIFY_CLIENT_SECRET for a dedicated search quota."
                )
            raise ValidationError(
                f"Spotify error ({response.status_code}): {response.text[:200]}"
            )

        return response.json()

    def _search(self, query, limit=5):
        results = self._spotify_request(
            "/search",
            {"q": query, "type": ",".join(SEARCH_TYPES), "limit": limit},
        )
        return {
            f"{kind}s": (results.get(f"{kind}s") or {}).get("items") or []
            for kind in SEARCH_TYPES
        }

    def _current_uri(self):
        try:
            data = self._request("GET", "/status")
        except ValidationError:
            return None
        return (data.get("track") or {}).get("uri")

    def _brief(self):
        data = self._command("GET", "/status")
        track = data.get("track") or {}
        return {
            "name": track.get("name"),
            "artist": ", ".join(track.get("artist_names") or []) or None,
            "volume": data.get("volume"),
        }

    def _wait_for_track_change(self, previous_uri, seconds=3.0):
        # The daemon loads the next track asynchronously; poll /status until
        # the track differs from the one we skipped past (or time out and
        # report whatever is loaded — a rewind keeps the same track).
        deadline = time.monotonic() + seconds
        data = {}
        while time.monotonic() < deadline:
            try:
                data = self._request("GET", "/status")
            except ValidationError:
                data = {}
            track = data.get("track") or {}
            if track.get("uri") and track.get("uri") != previous_uri:
                break
            time.sleep(0.25)
        return data

    @staticmethod
    def _track_fields(data):
        track = data.get("track") or {}
        return {
            "name": track.get("name"),
            "artist": ", ".join(track.get("artist_names") or []) or None,
        }

    def _load(self, uri, kind, name, artist=None):
        # The daemon's /player/play blocks until a FIFO reader exists when
        # audio_output_pipe_wait_for_reader is set, so issue it off-thread and
        # confirm via /status instead of wedging the tool call.
        failure = []

        def issue():
            try:
                self._command("POST", "/player/play", {"uri": uri, "paused": False})
            except ValidationError as error:
                failure.append(str(error))

        thread = threading.Thread(target=issue, daemon=True)
        thread.start()
        thread.join(self.timeout)

        if failure:
            raise ValidationError(failure[0])

        confirmed = False
        volume = None
        deadline = time.monotonic() + 5
        while time.monotonic() < deadline:
            try:
                data = self._request("GET", "/status")
            except ValidationError:
                data = {}
            volume = data.get("volume")
            track = data.get("track") or {}
            if track and (
                track.get("uri") == uri
                or data.get("context_uri") == uri
                or not thread.is_alive()
            ):
                confirmed = True
                break
            if failure:
                raise ValidationError(failure[0])
            time.sleep(0.25)

        if volume is None:
            try:
                volume = self._brief()["volume"]
            except ValidationError:
                volume = None

        return {
            "ok": True,
            "playing": kind,
            "name": name,
            "artist": artist,
            "started": confirmed,
            "volume": volume,
        }

    def play(self, query):
        query = (query or "").strip()
        if not query:
            raise ValidationError("query must be a non-empty string.")

        if query.startswith("spotify:"):
            return self._load(query, "requested uri", query)

        items = self._search(query)
        lowered = query.lower()

        wants_collection = "album" in lowered or "playlist" in lowered
        if wants_collection:
            for kind in ("albums", "playlists"):
                for item in items[kind]:
                    if item.get("name", "").lower() in lowered:
                        return self._load(item["uri"], kind[:-1], item["name"])

        for track in items["tracks"]:
            artists = ", ".join(
                a["name"] for a in track.get("artists") or [] if a.get("name")
            )
            return self._load(track["uri"], "track", track["name"], artists or None)

        if not wants_collection:
            for kind in ("albums", "playlists"):
                for item in items[kind]:
                    if item.get("name", "").lower() in lowered:
                        return self._load(item["uri"], kind[:-1], item["name"])

        raise ValidationError(f"No Spotify results for '{query}'.")

    def pause(self):
        self._command("POST", "/player/pause")
        brief = self._brief()
        return {
            "ok": True,
            "status": "paused",
            "name": brief["name"],
            "artist": brief["artist"],
        }

    def resume(self):
        self._command("POST", "/player/resume")
        brief = self._brief()
        return {
            "ok": True,
            "status": "playing",
            "name": brief["name"],
            "artist": brief["artist"],
            "volume": brief["volume"],
        }

    def skip(self):
        previous = self._current_uri()
        self._command("POST", "/player/next")
        data = self._wait_for_track_change(previous)
        return {
            "ok": True,
            "status": "skipped",
            "volume": data.get("volume"),
            **self._track_fields(data),
        }

    def previous(self):
        current = self._current_uri()
        self._command("POST", "/player/prev")
        data = self._wait_for_track_change(current)
        return {
            "ok": True,
            "status": "previous",
            "volume": data.get("volume"),
            **self._track_fields(data),
        }

    def volume(self, percent):
        if (
            isinstance(percent, bool)
            or not isinstance(percent, int)
            or not 0 <= percent <= 100
        ):
            raise ValidationError("percent must be an integer from 0 to 100.")
        self._command("POST", "/player/volume", {"volume": percent})
        brief = self._brief()
        return {
            "ok": True,
            "volume": percent,
            "name": brief["name"],
            "artist": brief["artist"],
        }

    def status(self):
        data = self._command("GET", "/status")
        track = data.get("track") or {}
        return {
            "ok": True,
            "playing": not (data.get("paused") or data.get("stopped")),
            "track": track.get("name"),
            "artist": ", ".join(track.get("artist_names") or []) or None,
            "album": track.get("album_name"),
            "position_seconds": (track.get("position") or 0) // 1000,
            "duration_seconds": (track.get("duration") or 0) // 1000,
            "volume": data.get("volume"),
        }
