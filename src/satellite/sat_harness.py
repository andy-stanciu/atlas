import asyncio
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
        print(f"recording uplink -> {name}")

    def send(self, ftype, payload=b""):
        self.writer.write(struct.pack("<IB", len(payload), ftype) + payload)

    async def read_loop(self):
        while True:
            hdr = await self.reader.readexactly(5)
            (n,) = struct.unpack("<I", hdr[:4])
            ftype = hdr[4]
            payload = await self.reader.readexactly(n) if n else b""
            if ftype == MIC:
                self.wav.writeframes(payload)
                self.frames += 1
            elif ftype == EV and payload == b"\x01" and self.flush_t is not None:
                print(f"\nflush rtt: {(time.monotonic() - self.flush_t) * 1000:.1f} ms")
                self.flush_t = None

    async def play(self, path):
        with wave.open(path, "rb") as w:
            assert (w.getframerate(), w.getnchannels(), w.getsampwidth()) == (48000, 1, 2), \
                "need 48kHz mono s16le wav: afconvert -f WAVE -d LEI16@48000 -c 1 in out.wav"
            self.send(CTRL, bytes([CTRL_TTS_START]))
            try:
                while chunk := w.readframes(960):
                    self.send(TTS, chunk)
                    await asyncio.sleep(0.0195)
            except asyncio.CancelledError:
                pass

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


def play_done(fut):
    if fut.cancelled():
        return
    if fut.exception():
        print(f"play failed: {fut.exception()}")


async def main():
    global session

    async def on_client(reader, writer):
        global session
        session = Session(reader, writer)
        print("satellite connected")
        try:
            await session.read_loop()
        except (asyncio.IncompleteReadError, ConnectionResetError) as e:
            print(f"satellite lost: {e}")
        finally:
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
        if cmd == "play" and len(parts) == 2 and session:
            fut = asyncio.run_coroutine_threadsafe(session.play(parts[1]), loop)
            fut.add_done_callback(play_done)
            session.play_fut = fut
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
