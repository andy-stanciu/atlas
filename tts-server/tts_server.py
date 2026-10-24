"""Kokoro TTS server for Atlas.

Listens on TCP 8767. One request at a time per connection; requests are
processed in arrival order, which is how sentence N+1's synthesis
overlaps sentence N's playback on the client.

Wire protocol (all integers little-endian):
  request : [u32 len][u8 0x01][json {"id": u32, "text": str}]
  response: [u32 len][u8 0x02][u32 id][u32 sample_rate][s16le pcm]  (1+)
            [u32 len][u8 0x03][u32 id]                               (end)
            [u32 len][u8 0x04][u32 id][utf8 error message]
"""

import json
import socket
import struct

import numpy as np
import torch
from kokoro import KPipeline

HOST = "0.0.0.0"
PORT = 8767
VOICE = "af_heart"
SAMPLE_RATE = 24_000

FRAME_SYNTH = 0x01
FRAME_AUDIO = 0x02
FRAME_END = 0x03
FRAME_ERROR = 0x04

pipeline = None


def synthesize(text):
    parts = [
        audio
        for _, _, audio in pipeline(
            text, voice=VOICE, speed=1.0, split_pattern=r"\n+"
        )
    ]
    if not parts:
        raise RuntimeError("Kokoro produced no audio.")
    audio = np.concatenate(parts)
    pcm = (np.clip(audio, -1.0, 1.0) * 32767).astype("<i2")
    return pcm.tobytes()


def recv_exact(conn, length):
    data = b""
    while len(data) < length:
        chunk = conn.recv(length - len(data))
        if not chunk:
            return None
        data += chunk
    return data


def send_frame(conn, frame_type, payload):
    conn.sendall(struct.pack("<IB", len(payload), frame_type) + payload)


def handle(conn):
    while True:
        header = recv_exact(conn, 5)
        if header is None:
            return
        (length,) = struct.unpack("<I", header[:4])
        frame_type = header[4]
        payload = recv_exact(conn, length)
        if payload is None:
            return
        if frame_type != FRAME_SYNTH:
            continue

        try:
            request = json.loads(payload)
            request_id = int(request["id"])
            pcm = synthesize(request["text"].strip())
            send_frame(
                conn,
                FRAME_AUDIO,
                struct.pack("<II", request_id, SAMPLE_RATE) + pcm,
            )
            send_frame(conn, FRAME_END, struct.pack("<I", request_id))
        except Exception as error:
            try:
                request_id = int(request.get("id", 0))
            except Exception:
                request_id = 0
            send_frame(
                conn,
                FRAME_ERROR,
                struct.pack("<I", request_id) + str(error).encode(),
            )


def main():
    global pipeline
    device = "cuda" if torch.cuda.is_available() else "cpu"
    print(f"[tts] loading kokoro (device: {device})", flush=True)
    pipeline = KPipeline(lang_code="a")

    # Warmup: the first CUDA synthesis pays kernel-load and allocator
    # costs. Pay them here so the first real sentence is warm.
    for _ in range(2):
        synthesize("Warming up.")
    print("[tts] ready", flush=True)

    server = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    server.bind((HOST, PORT))
    server.listen(1)
    print(f"[tts] listening on {HOST}:{PORT}", flush=True)

    while True:
        conn, address = server.accept()
        conn.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
        print(f"[tts] client connected: {address}", flush=True)
        try:
            handle(conn)
        except (ConnectionError, OSError):
            pass
        finally:
            conn.close()
            print("[tts] client disconnected", flush=True)


if __name__ == "__main__":
    main()
