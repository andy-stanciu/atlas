import json
import urllib.request
from pathlib import Path

import numpy as np
from tqdm import tqdm

from . import audio, config, generate
from .export import trained_model
from .infer import Detector

CUTOFFS = [round(c, 3) for c in np.arange(0.50, 0.995, 0.02)]
STOCK_URLS = [
    "https://github.com/esphome/micro-wake-word-models/raw/main/models/v2/{n}.{e}",
    "https://github.com/esphome/micro-wake-word-models/raw/main/models/{n}.{e}",
]


def _wavs(d):
    return sorted(Path(d).glob("*.wav")) if Path(d).exists() else []


def _events(trace, cutoff, step_s, refractory_s=2.0):
    n, last = 0, -1e9
    for i in np.where(trace > cutoff)[0]:
        if i - last >= refractory_s / step_s:
            n += 1
            last = i
    return n


def _model(cfg, model):
    return Path(model) if model else trained_model(cfg)


def evaluate(cfg, model=None, window=None):
    det = Detector(_model(cfg, model), window or cfg["export"]["sliding_window_size"])
    prep, amb = config.path(cfg, "work", "real_prepared", "test"), config.path(cfg, "data", "ambient", "test")
    pos = [det.run_file(f).max() for f in tqdm(_wavs(prep / "positive"), desc="test positives")]
    neg = [det.run_file(f).max() for f in tqdm(_wavs(prep / "negative"), desc="test hard negatives")]
    traces, hours = [], 0.0
    for f in tqdm(_wavs(amb), desc="ambient"):
        x = audio.pick(audio.read(f), 1)
        traces.append(det.run(x))
        hours += len(x) / audio.SR / 3600
    e = cfg["eval"]
    rows, best = [], None
    for c in CUTOFFS:
        recall = float(np.mean(np.array(pos) > c)) if pos else float("nan")
        hn = float(np.mean(np.array(neg) > c)) if neg else float("nan")
        faph = sum(_events(t, c, det.step_s) for t in traces) / hours if hours else float("nan")
        rows.append((c, recall, hn, faph))
        ok = (hours == 0 or faph <= e["target_faph"]) and (not neg or hn <= e["hard_negative_max_fp_rate"])
        if ok and pos and (best is None or recall > best[1]):
            best = (c, recall)
    lines = [f"positives {len(pos)}, hard negatives {len(neg)}, ambient {hours:.2f} h", "cutoff | recall | hard-neg FP rate | false accepts/hour"]
    lines += [f"{c:.2f} | {r:.3f} | {h:.3f} | {f:.2f}" for c, r, h, f in rows]
    lines.append(f"recommended cutoff: {best[0] if best else 'none meets targets'}")
    out = config.path(cfg, "work", "eval_report.md")
    out.write_text("\n".join(lines) + "\n")
    print("\n".join(lines))
    return best[0] if best else None


def mine(cfg, model=None):
    det = Detector(_model(cfg, model), cfg["export"]["sliding_window_size"])
    dst = config.path(cfg, "data", "fp_negatives")
    dst.mkdir(parents=True, exist_ok=True)
    cut, n = cfg["eval"]["mine_cutoff"], 0
    for f in tqdm(_wavs(config.path(cfg, "data", "ambient", "train")), desc="mining"):
        x = audio.pick(audio.read(f), 1)
        t, last = det.run(x), -1e9
        for i in np.where(t > cut)[0]:
            if i - last < 2.0 / det.step_s:
                continue
            last = i
            c = int((i + 1) * det.step_s * audio.SR)
            clip = x[max(0, c - int(2.0 * audio.SR)) : c + int(0.3 * audio.SR)]
            audio.write(dst / f"{f.stem}_{i:08d}.wav", clip)
            n += 1
    print(f"mined {n} false-positive clips -> {dst}")


def fetch_stock(cfg, name="hey_jarvis"):
    out = config.path(cfg, "models", "stock")
    out.mkdir(parents=True, exist_ok=True)
    for ext in ("tflite", "json"):
        for u in STOCK_URLS:
            try:
                urllib.request.urlretrieve(u.format(n=name, e=ext), out / f"{name}.{ext}")
                break
            except Exception:
                continue
        else:
            print(f"could not download {name}.{ext}; copy it from your ESPHome cache: find <satellite>/.esphome -name '{name}*'")
    return out


def selftest(cfg):
    ref = config.path(cfg, "models").parent / (cfg["export"]["reference_model"] + ".tflite")
    if not ref.exists():
        fetch_stock(cfg)
    d = config.path(cfg, "work", "selftest")
    generate.gen(cfg, [{"text": "hey jarvis", "samples": 6}], d)
    det = Detector(ref, cfg["export"]["sliding_window_size"])
    scores = [float(det.run_file(f, ch=0).max()) for f in _wavs(d)]
    silence = float(det.run(np.zeros(audio.SR * 5, dtype=np.float32)).max())
    print("stock hey_jarvis on synthetic 'hey jarvis':", [round(s, 2) for s in scores], "| silence:", round(silence, 2))
    print("PASS" if max(scores) > 0.9 and silence < 0.2 else "CHECK: inference mirror or TTS output looks off")
