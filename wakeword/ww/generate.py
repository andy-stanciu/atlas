import re
import shutil
import subprocess
import sys

from . import audio, config
from .sh import run

MODULE = "piper_sample_generator"


def slug(t):
    return re.sub(r"[^a-z0-9]+", "_", t.lower()).strip("_") or "ipa"


def caps():
    r = subprocess.run([sys.executable, "-m", MODULE, "--help"], capture_output=True, text=True)
    return set(re.findall(r"--[a-z][a-z-]*", r.stdout + r.stderr))


def _once(cmd, batch):
    try:
        run(cmd + ["--batch-size", batch], cwd=config.ROOT)
    except subprocess.CalledProcessError:
        print(f"piper failed at batch {batch}; retrying at {batch // 2} (likely VRAM)")
        run(cmd + ["--batch-size", batch // 2], cwd=config.ROOT)


def gen(cfg, items, out_dir):
    g, c = cfg["generate"], caps()
    voice = config.ROOT / g["voice_model"]
    if not voice.exists():
        raise SystemExit(f"missing {voice}; run: python cli.py fetch-voice")
    out_dir.mkdir(parents=True, exist_ok=True)
    profiles = g["profiles"]
    for it in items:
        text, n, ipa = it["text"], it["samples"], it.get("ipa", False)
        if ipa and "--phoneme-input" not in c:
            raise SystemExit("this piper_sample_generator has no --phoneme-input; use text spellings instead")
        for pi, prof in enumerate(profiles):
            share = n // len(profiles) + (n % len(profiles) if pi == 0 else 0)
            tmp = out_dir.parent / f".tmp_{slug(text)}_{pi}"
            shutil.rmtree(tmp, ignore_errors=True)
            tmp.mkdir(parents=True)
            cmd = [sys.executable, "-m", MODULE, text, "--model", voice, "--max-samples", share, "--output-dir", tmp]
            if ipa:
                cmd.append("--phoneme-input")
            if g.get("max_speakers") and "--max-speakers" in c:
                cmd += ["--max-speakers", g["max_speakers"]]
            for flag, key in (("--noise-scales", "noise_scale"), ("--noise-scale-ws", "noise_scale_w"), ("--length-scales", "length_scale")):
                if flag in c and key in prof:
                    cmd += [flag, prof[key]]
            _once(cmd, g["batch_size"])
            for i, f in enumerate(sorted(tmp.glob("*.wav"))):
                audio.write(out_dir / f"{slug(text)}_{pi}_{i:05d}.wav", audio.read(f).mean(axis=1))
            shutil.rmtree(tmp)


def positives(cfg):
    gen(cfg, cfg["generate"]["positives"], config.path(cfg, "data", "generated", "positive"))


def negatives(cfg):
    n = cfg["generate"]["negatives"]
    gen(cfg, [{"text": p, "samples": n["samples_per_phrase"]} for p in n["phrases"]], config.path(cfg, "data", "generated", "negative"))


def audition(cfg):
    out = config.path(cfg, "work", "audition")
    gen(cfg, [{**p, "samples": 6} for p in cfg["generate"]["positives"]], out)
    print("listen to:", out)
