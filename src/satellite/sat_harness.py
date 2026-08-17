import asyncio
import math
import struct
import threading
import time
import wave

PORT = 8765
MIC, TTS, CTRL, EV = 0x01, 0x02, 0x03, 0x04
CTRL_FLUSH, CTRL_TTS_START = 0x01, 0x02

session = None


class Session:
    def __init__(self, reader, writer):
        self.reader = reader
        self.writer = writer
        name = f"uplink-{int(time.time())}.wav"
        self.wav = wave.open(name, "wb")
        self.wav.setnchannels(1)
        self.wav.setsampwidth(2)
        self.wav.setframerate(16000)  # mic uplink is 16 kHz s16le mono
        self.frames = 0
        self.flush_t = None
        self.play_fut = None
        self.last_rx = time.monotonic()
        print(f"recording uplink -> {name}")

    def send(self, ftype, payload=b""):
        self.writer.write(struct.pack("<IB", len(payload), ftype) + payload)

    async def read_loop(self):
        while True:
            hdr = await self.reader.readexactly(5)
            (n,) = struct.unpack("<I", hdr[:4])
            ftype = hdr[4]
            payload = await self.reader.readexactly(n) if n else b""
            self.last_rx = time.monotonic()
            if ftype == MIC:
                self.wav.writeframes(payload)
                self.frames += 1
            elif ftype == EV and payload == b"\x01" and self.flush_t is not None:
                print(f"\nflush rtt: {(time.monotonic() - self.flush_t) * 1000:.1f} ms")
                self.flush_t = None

    async def watchdog(self):
        warned = False
        while True:
            await asyncio.sleep(1)
            quiet = time.monotonic() - self.last_rx
            if quiet > 3 and not warned:
                warned = True
                print(f"\n!! uplink silent for {quiet:.0f}s (device wedged?)")
            elif quiet <= 3:
                warned = False

    async def _stream(self, frames):
        # Absolute-deadline pacing at 20 ms per frame
        start = time.monotonic()
        for i, chunk in enumerate(frames):
            self.send(TTS, chunk)
            target = start + (i + 1) * 0.02
            delay = target - time.monotonic()
            if delay > 0:
                await asyncio.sleep(delay)

    async def play(self, path):
        with wave.open(path, "rb") as w:
            assert (w.getframerate(), w.getnchannels(), w.getsampwidth()) == (
                24000,
                1,
                2,
            ), (
                "need 24kHz mono s16le wav: afconvert -f WAVE -d LEI16@24000 -c 1 in out.wav"
            )
            frames = []
            while chunk := w.readframes(480):
                frames.append(chunk)
            self.send(CTRL, bytes([CTRL_TTS_START]))
            try:
                await self._stream(frames)
            except asyncio.CancelledError:
                pass

    async def tone(self, seconds):
        # 440 Hz sine, 24 kHz s16le mono, one second looped
        base = b"".join(
            int(12000 * math.sin(2 * math.pi * 440 * i / 24000)).to_bytes(
                2, "little", signed=True
            )
            for i in range(24000)
        )
        frames = [base[i : i + 960] for i in range(0, len(base), 960)]
        self.send(CTRL, bytes([CTRL_TTS_START]))
        try:
            await self._stream(frames * int(seconds))
        except asyncio.CancelledError:
            pass

    async def blast(self, seconds):
        # Raw throughput test: unpaced frames with the gate CLOSED (no
        # TTS_START), so the device drops and counts them without playing.
        frame = bytes(960)
        end = time.monotonic() + seconds
        sent = 0
        started = time.monotonic()
        while time.monotonic() < end:
            self.send(TTS, frame)
            sent += 1
            if sent % 25 == 0:
                await self.writer.drain()
                await asyncio.sleep(0)
        elapsed = time.monotonic() - started
        print(f"blasted {sent} frames in {elapsed:.1f}s ({sent / elapsed:.0f} fps)")

    def flush(self):
        if self.play_fut is not None:
            self.play_fut.cancel()
            self.play_fut = None
        self.flush_t = time.monotonic()
        self.send(CTRL, bytes([CTRL_FLUSH]))

    def stats(self):
        print(f"uplink: {self.frames} frames ({self.frames * 20 / 1000:.0f}s)")

    def close(self):
        self.wav.close()


def run_done(fut):
    if fut.cancelled():
        return
    if fut.exception():
        print(f"command failed: {fut.exception()}")


async def main():
    global session

    async def on_client(reader, writer):
        global session
        session = Session(reader, writer)
        print("satellite connected")
        watchdog_task = asyncio.create_task(session.watchdog())
        try:
            await session.read_loop()
        except (asyncio.IncompleteReadError, ConnectionResetError) as e:
            print(f"satellite lost: {e}")
        finally:
            watchdog_task.cancel()
            session.close()
            session = None

    server = await asyncio.start_server(on_client, "0.0.0.0", PORT)
    print(f"listening on :{PORT}")
    await server.serve_forever()


def repl(loop):
    while True:
        try:
            parts = input("> ").split(maxsplit=1)
        except EOFError:
            break
        if not parts:
            continue
        cmd = parts[0]
        arg = parts[1] if len(parts) == 2 else ""
        if cmd == "play" and arg and session:
            fut = asyncio.run_coroutine_threadsafe(session.play(arg), loop)
            fut.add_done_callback(run_done)
            session.play_fut = fut
        elif cmd == "tone" and arg and session:
            fut = asyncio.run_coroutine_threadsafe(session.tone(float(arg)), loop)
            fut.add_done_callback(run_done)
            session.play_fut = fut
        elif cmd == "blast" and arg and session:
            fut = asyncio.run_coroutine_threadsafe(session.blast(float(arg)), loop)
            fut.add_done_callback(run_done)
        elif cmd == "flush" and session:
            loop.call_soon_threadsafe(session.flush)
        elif cmd == "stats" and session:
            loop.call_soon_threadsafe(session.stats)
        elif cmd == "quit":
            loop.call_soon_threadsafe(loop.stop)
            break


if __name__ == "__main__":
    loop = asyncio.new_event_loop()
    threading.Thread(target=repl, args=(loop,), daemon=True).start()
    try:
        loop.run_until_complete(main())
    except (KeyboardInterrupt, RuntimeError):
        pass
