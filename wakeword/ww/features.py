import os
import shutil

from . import config

SPLITS = (("training", "train", 10), ("validation", "validation", 10), ("testing", "test", 1))


def _augmenter(cfg):
    from microwakeword.audio.augmentation import Augmentation

    a, d = cfg["augment"], config.path(cfg, "data")
    bg = [d / "aug" / "fma_16k", d / "aug" / "audioset_16k", d / "ambient" / "train"]
    bg = [str(p) for p in bg if p.exists() and any(p.glob("*.wav"))]
    return Augmentation(
        augmentation_duration_s=a["duration_s"], augmentation_probabilities=a["probabilities"],
        impulse_paths=[str(d / "aug" / "mit_rirs")], background_paths=bg,
        background_min_snr_db=a["snr_db"][0], background_max_snr_db=a["snr_db"][1],
        min_jitter_s=a["jitter_s"][0], max_jitter_s=a["jitter_s"][1],
    )


def clip_dirs(cfg):
    d, w = config.path(cfg, "data"), config.path(cfg, "work")
    dirs = {
        "synthetic_positive": d / "generated" / "positive",
        "synthetic_hard_negative": d / "generated" / "negative",
        "real_positive": w / "real_prepared" / "train" / "positive",
        "real_hard_negative": w / "real_prepared" / "train" / "negative",
        "fp_negative": d / "fp_negatives",
    }
    return {k: v for k, v in dirs.items() if v.exists() and any(v.glob("*.wav"))}


def build(cfg, force=False):
    from microwakeword.audio.clips import Clips
    from microwakeword.audio.spectrograms import SpectrogramGeneration
    from mmap_ninja.ragged import RaggedMmap

    work = config.path(cfg, "work")
    work.mkdir(parents=True, exist_ok=True)
    free = shutil.disk_usage(work).free / 1e9
    if free < cfg["features"]["min_free_gb"] and not os.environ.get("SMALL_DISK_OK"):
        raise SystemExit(f"only {free:.0f} GB free; feature generation can need ~{cfg['features']['min_free_gb']}+ GB. Free space, lower samples/repeat_train in config.yaml, or set SMALL_DISK_OK=1")
    aug = _augmenter(cfg)
    for seed, (name, src) in enumerate(clip_dirs(cfg).items(), start=42):
        out = config.path(cfg, "work", "features", name)
        if out.exists() and not force:
            print(f"skip {name} (exists)")
            continue
        shutil.rmtree(out, ignore_errors=True)
        s, f = cfg["features"]["sets"][name], cfg["features"]
        clips = Clips(
            input_directory=str(src), file_pattern="*.wav", max_clip_duration_s=None,
            remove_silence=f["remove_silence"], random_split_seed=seed, split_count=0.1,
        )
        reps = {"train": s.get("repeat_train", f["repeat_train"]), "validation": s.get("repeat_validation", 1), "test": 1}
        for split, kind, slide in SPLITS:
            spec = SpectrogramGeneration(clips=clips, augmenter=aug, slide_frames=slide, step_ms=10)
            (out / split).mkdir(parents=True, exist_ok=True)
            RaggedMmap.from_generator(
                out_dir=str(out / split / "wakeword_mmap"),
                sample_generator=spec.spectrogram_generator(split=kind, repeat=reps[kind]),
                batch_size=200, verbose=True,
            )
