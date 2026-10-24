import numpy as np

from . import audio, config


def trim(x, r):
    fr = audio.SR // 100
    n = len(x) // fr
    rms = np.sqrt((x[: n * fr].reshape(n, fr) ** 2).mean(1) + 1e-12)
    idx = np.where(rms > max(0.004, 3 * np.percentile(rms, 20)))[0]
    if not len(idx):
        return None
    a = max(0, idx[0] * fr - int(r["pad_pre_s"] * audio.SR))
    b = min(len(x), (idx[-1] + 1) * fr + int(r["pad_post_s"] * audio.SR))
    return x[a:b]


def prepare(cfg):
    r = cfg["real"]
    rows = ["split\tkind\tfile\tstatus"]
    for split in ("train", "test"):
        for kind in ("positive", "negative"):
            src = config.path(cfg, "data", "real", split, kind)
            dst = config.path(cfg, "work", "real_prepared", split, kind)
            dst.mkdir(parents=True, exist_ok=True)
            for f in sorted(src.glob("*.wav")):
                x = audio.pick(audio.read(f), r["channel"])
                status, y = "ok", None
                if np.abs(x).max() >= r["clip_peak"]:
                    status = "clipped"
                else:
                    y = trim(x, r)
                    if y is None:
                        status = "silent"
                    elif not r["min_s"] <= len(y) / audio.SR <= r["max_s"]:
                        status = f"duration {len(y) / audio.SR:.2f}s"
                if status == "ok":
                    audio.write(dst / f.name, y)
                rows.append(f"{split}\t{kind}\t{f.name}\t{status}")
    out = config.path(cfg, "work", "real_prepared", "qc.tsv")
    out.write_text("\n".join(rows) + "\n")
    bad = [r_ for r_ in rows[1:] if not r_.endswith("ok")]
    print(f"{len(rows) - 1} clips, {len(bad)} rejected -> {out}")
