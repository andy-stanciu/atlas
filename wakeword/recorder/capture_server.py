#!/usr/bin/env python3
"""Capture server for the recorder firmware (stdlib only; run on the Mac).

  python3 capture_server.py positives --speaker andy --split train --cond quiet --dist 1m --count 60
  python3 capture_server.py negatives --speaker andy --split train --cond quiet --dist 1m --count 60
  python3 capture_server.py ambient   --label tv --split train --minutes 30

Clips are saved as stereo 16 kHz WAV (left = comms channel, right = ASR channel, the one the wake
model hears) under <out>/real/<split>/<positive|negative>/, ambient as mono ASR-channel WAV
under <out>/ambient/<split>/. LED: amber = get ready, green = speak now, blue = saved.
"""
import argparse
import array
import asyncio
import json
import random
import struct
import time
import wave
from collections import deque
from pathlib import Path

FRAME_AUDIO, FRAME_CTRL, CTRL_STATE = 1, 3, 1
ST_IDLE, ST_READY, ST_GO, ST_DONE, ST_AMBIENT = range(5)
SR, FRAME_MS = 16000, 20
FRAME_BYTES = 320 * 4
SILENCE = bytes(FRAME_BYTES)


class Link:
    def __init__(self, reader, writer):
        self.r, self.w, self.alive = reader, writer, True
        self.frames, self.base, self.next_seq, self.gaps, self.sink = deque(maxlen=3000), 0, 0, 0, None

    def _push(self, frame):
        if len(self.frames) == self.frames.maxlen:
            self.base += 1
        self.frames.append(frame)
        if self.sink:
            self.sink(frame)

    async def pump(self):
        try:
            while True:
                n, t = struct.unpack("<IB", await self.r.readexactly(5))
                p = await self.r.readexactly(n) if n else b""
                if t != FRAME_AUDIO or n != 4 + FRAME_BYTES:
                    continue
                seq = struct.unpack_from("<I", p)[0]
                if seq < self.next_seq:
                    continue
                for _ in range(seq - self.next_seq):
                    self.gaps += 1
                    self._push(SILENCE)
                self._push(p[4:])
                self.next_seq = seq + 1
        except (asyncio.IncompleteReadError, ConnectionError):
            self.alive = False

    def state(self, st):
        self.w.write(struct.pack("<IB", 2, FRAME_CTRL) + bytes([CTRL_STATE, st]))

    def grab(self, start, end):
        lo = max(start, self.base)
        return b"".join(list(self.frames)[lo - self.base : end - self.base])


def stats(stereo):
    a = array.array("h")
    a.frombytes(stereo)
    asr = a[1::2]
    peak = max((abs(x) for x in asr), default=0) / 32768
    rms = (sum(x * x for x in asr) / max(1, len(asr))) ** 0.5 / 32768
    return peak, rms


def save_wav(path, pcm, channels):
    path.parent.mkdir(parents=True, exist_ok=True)
    with wave.open(str(path), "wb") as f:
        f.setnchannels(channels)
        f.setsampwidth(2)
        f.setframerate(SR)
        f.writeframes(pcm)


def next_index(d, prefix):
    return len(list(d.glob(prefix + "*.wav")))


async def clip(link, a):
    link.state(ST_READY)
    await asyncio.sleep(a.ready)
    go = link.next_seq
    link.state(ST_GO)
    await asyncio.sleep(a.window)
    link.state(ST_DONE)
    await asyncio.sleep(a.post)
    pre = int(a.pre * 1000 / FRAME_MS)
    return link.grab(max(0, go - pre), link.next_seq)


async def prompts(link, a):
    kind = "positive" if a.mode == "positives" else "negative"
    phrases = [a.phrase]
    if kind == "negative":
        phrases = [l.strip() for l in Path(a.phrases_file).read_text().splitlines() if l.strip()]
    d = Path(a.out) / "real" / a.split / kind
    prefix = f"{a.speaker}__{a.cond}__{a.dist}__"
    idx = next_index(d, prefix)
    meta = d.parent / "meta.jsonl"
    loop = asyncio.get_running_loop()
    for i in range(a.count):
        phrase = random.choice(phrases)
        print(f"[{i + 1}/{a.count}] say: \"{phrase}\"   ({a.speaker}, {a.cond}, {a.dist}, {a.split})", flush=True)
        if a.pause:
            await loop.run_in_executor(None, input, "  press Enter when ready ")
        pcm = await clip(link, a)
        if not link.alive:
            print("satellite disconnected")
            return
        peak, rms = stats(pcm)
        warn = "  CLIPPED" if peak > 0.98 else "  too quiet?" if rms < 0.002 else ""
        name = f"{prefix}{idx:04d}.wav"
        save_wav(d / name, pcm, 2)
        with open(meta, "a") as f:
            f.write(json.dumps({"file": name, "phrase": phrase, "speaker": a.speaker, "cond": a.cond, "dist": a.dist,
                                "split": a.split, "peak": round(peak, 3), "rms": round(rms, 4), "t": time.time()}) + "\n")
        print(f"  saved {name}  peak {peak:.2f} rms {rms:.3f}  gaps {link.gaps}{warn}", flush=True)
        idx += 1
        await asyncio.sleep(a.gap)
    link.state(ST_IDLE)


async def ambient(link, a):
    d = Path(a.out) / "ambient" / a.split
    d.mkdir(parents=True, exist_ok=True)
    state = {"f": None, "n": 0, "chunk": 0}

    def open_next():
        if state["f"]:
            state["f"].close()
        name = d / f"{a.label}__{time.strftime('%Y%m%d_%H%M%S')}_{state['chunk']:03d}.wav"
        f = wave.open(str(name), "wb")
        f.setnchannels(2 if a.stereo else 1)
        f.setsampwidth(2)
        f.setframerate(SR)
        state.update(f=f, n=0, chunk=state["chunk"] + 1)

    def sink(frame):
        if state["n"] >= a.chunk_min * 60 * 1000 // FRAME_MS:
            open_next()
        if a.stereo:
            state["f"].writeframes(frame)
        else:
            arr = array.array("h")
            arr.frombytes(frame)
            state["f"].writeframes(arr[1::2].tobytes())
        state["n"] += 1

    open_next()
    link.sink = sink
    link.state(ST_AMBIENT)
    end = time.time() + a.minutes * 60
    while link.alive and time.time() < end:
        await asyncio.sleep(60)
        print(f"  ambient {int((time.time() - (end - a.minutes * 60)) / 60)}/{a.minutes} min, gaps {link.gaps}", flush=True)
    link.sink = None
    state["f"].close()
    link.state(ST_IDLE)


async def main_async(a):
    done = asyncio.Event()

    async def on_client(reader, writer):
        link = Link(reader, writer)
        print("satellite connected")
        pump = asyncio.create_task(link.pump())
        await asyncio.sleep(1.0)
        try:
            await (ambient if a.mode == "ambient" else prompts)(link, a)
        finally:
            await asyncio.sleep(0.5)
            pump.cancel()
            writer.close()
            done.set()

    server = await asyncio.start_server(on_client, "0.0.0.0", a.port)
    print(f"listening on :{a.port}; waiting for the recorder firmware to connect...")
    await done.wait()
    server.close()


def main():
    p = argparse.ArgumentParser()
    p.add_argument("mode", choices=["positives", "negatives", "ambient"])
    p.add_argument("--port", type=int, default=8766)
    p.add_argument("--out", default=str(Path(__file__).resolve().parent.parent / "data"))
    p.add_argument("--split", choices=["train", "test"], required=True)
    p.add_argument("--speaker", default="andy")
    p.add_argument("--cond", default="quiet", help="quiet|music|tv|kitchen|... (free text, no spaces)")
    p.add_argument("--dist", default="1m")
    p.add_argument("--count", type=int, default=50)
    p.add_argument("--phrase", default="Hey Atlas")
    p.add_argument("--phrases-file", default=str(Path(__file__).resolve().parent / "negative_phrases.txt"))
    p.add_argument("--ready", type=float, default=0.9)
    p.add_argument("--window", type=float, default=2.4)
    p.add_argument("--pre", type=float, default=0.6)
    p.add_argument("--post", type=float, default=0.3)
    p.add_argument("--gap", type=float, default=0.8)
    p.add_argument("--pause", action="store_true", help="wait for Enter before each clip")
    p.add_argument("--label", default="ambient")
    p.add_argument("--minutes", type=int, default=30)
    p.add_argument("--chunk-min", type=int, default=10)
    p.add_argument("--stereo", action="store_true", help="ambient: keep both channels")
    a = p.parse_args()
    try:
        asyncio.run(main_async(a))
    except KeyboardInterrupt:
        print("stopped")


if __name__ == "__main__":
    main()
