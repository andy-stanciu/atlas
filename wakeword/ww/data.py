import io
import shutil
import urllib.request
import zipfile
from pathlib import Path

import soundfile as sf
from huggingface_hub import hf_hub_download, snapshot_download
from tqdm import tqdm

from . import audio, config


def _have(d, n=1):
    return d.exists() and len(list(d.glob("*.wav"))) >= n


def _unzip(zpath, name, root):
    with zipfile.ZipFile(zpath) as z:
        tops = {n.split("/")[0] for n in z.namelist() if n.strip("/")}
        z.extractall(root if tops == {name} else root / name)


def _download(url, dst):
    dst.parent.mkdir(parents=True, exist_ok=True)
    if not dst.exists():
        print("downloading", url)
        urllib.request.urlretrieve(url, dst)


def fetch_voice(cfg):
    g = cfg["generate"]
    voice = config.ROOT / g["voice_model"]
    _download(g["voice_url"], voice)
    _download(g["voice_config_url"], voice.with_name(voice.name + ".json"))
    print("voice model:", voice)


def _rirs(dst):
    if _have(dst, 200):
        return
    p = snapshot_download("davidscripka/MIT_environmental_impulse_responses", repo_type="dataset", allow_patterns=["16khz/*.wav"])
    dst.mkdir(parents=True, exist_ok=True)
    for f in (Path(p) / "16khz").glob("*.wav"):
        shutil.copy(f, dst)


def _audioset(dst, target):
    have = len(list(dst.glob("*.wav"))) if dst.exists() else 0
    if have >= target * 0.9:
        return
    import datasets

    dst.mkdir(parents=True, exist_ok=True)
    try:
        ds = datasets.load_dataset("agkphysics/AudioSet", "balanced", split="train", streaming=True, trust_remote_code=True)
    except Exception:
        ds = datasets.load_dataset("agkphysics/AudioSet", "balanced", split="train", streaming=True)
    ds = ds.cast_column("audio", datasets.Audio(decode=False))
    count = have
    for row in tqdm(ds, total=target, desc="audioset"):
        if count >= target:
            break
        try:
            a = row["audio"]
            x, sr = sf.read(io.BytesIO(a["bytes"])) if a.get("bytes") else sf.read(a["path"])
            x = x.mean(axis=1) if x.ndim > 1 else x
            audio.write(dst / f"audioset_{count}.wav", audio.resample(x.astype("float32")[:, None], sr)[:, 0])
            count += 1
        except Exception:
            continue


def _fma(dst, tmp):
    if _have(dst, 150):
        return
    import librosa

    z = hf_hub_download("mchl914/fma_xsmall", "fma_xs.zip", repo_type="dataset")
    with zipfile.ZipFile(z) as zf:
        zf.extractall(tmp / "fma")
    dst.mkdir(parents=True, exist_ok=True)
    for n, mp3 in enumerate(tqdm(sorted((tmp / "fma").rglob("*.mp3")), desc="fma")):
        try:
            x, _ = librosa.load(str(mp3), sr=audio.SR, mono=True)
            audio.write(dst / f"fma_{n}.wav", x)
        except Exception:
            continue


def fetch(cfg):
    d, tmp = config.path(cfg, "data"), config.path(cfg, "work", "tmp")
    tmp.mkdir(parents=True, exist_ok=True)
    fetch_voice(cfg)
    _rirs(d / "aug" / "mit_rirs")
    _audioset(d / "aug" / "audioset_16k", cfg["datasets"]["audioset_clips"])
    _fma(d / "aug" / "fma_16k", tmp)
    neg = d / "negatives"
    neg.mkdir(parents=True, exist_ok=True)
    for name in cfg["negative_datasets"]:
        if not (neg / name).exists():
            _unzip(hf_hub_download("kahrendt/microwakeword", f"{name}.zip", repo_type="dataset"), name, neg)
