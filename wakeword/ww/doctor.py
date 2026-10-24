import importlib
import inspect
import shutil
import sys

from . import config, generate

EXPECT = {
    "microwakeword.audio.clips.Clips": ["input_directory", "file_pattern", "max_clip_duration_s", "remove_silence", "random_split_seed", "split_count"],
    "microwakeword.audio.augmentation.Augmentation": [
        "augmentation_duration_s", "augmentation_probabilities", "impulse_paths", "background_paths",
        "background_min_snr_db", "background_max_snr_db", "min_jitter_s", "max_jitter_s"],
    "microwakeword.audio.spectrograms.SpectrogramGeneration": ["clips", "augmenter", "slide_frames", "step_ms"],
}
IMPORTS = ("tensorflow", "tensorboard", "torch", "piper_phonemize", "piper_train.vits.monotonic_align", "piper_sample_generator",
           "audiomentations", "audio_metadata", "librosa", "datasets", "pymicro_features", "mmap_ninja", "microwakeword",
           "soundfile", "huggingface_hub")


def _row(ok, what, extra=""):
    print(f"[{'ok' if ok else '!!'}] {what} {extra}")
    return ok


def check(cfg):
    good = _row(sys.version_info[:2] == (3, 10), "python 3.10", f"(running {sys.version.split()[0]})")
    for mod in IMPORTS:
        try:
            importlib.import_module(mod)
            good &= _row(True, f"import {mod}")
        except Exception as e:
            good &= _row(False, f"import {mod}", str(e)[:100])
    try:
        import audiomentations

        good &= _row(hasattr(audiomentations, "AddColorNoise"), "audiomentations has AddColorNoise", audiomentations.__version__)
    except Exception:
        pass
    _row(bool(shutil.which("espeak-ng")), "espeak-ng installed", "(sudo apt install espeak-ng)")
    try:
        import tensorflow as tf

        _row(bool(tf.config.list_physical_devices("GPU")), "tensorflow sees a GPU")
        import torch

        _row(torch.cuda.is_available(), "torch sees a GPU")
    except Exception:
        pass
    for path, names in EXPECT.items():
        mod, cls = path.rsplit(".", 1)
        try:
            have = set(inspect.signature(getattr(importlib.import_module(mod), cls).__init__).parameters)
            miss = [n for n in names if n not in have]
            good &= _row(not miss, f"{cls} signature", f"missing {miss}" if miss else "")
        except Exception as e:
            good &= _row(False, f"{cls} signature", str(e)[:100])
    try:
        c = generate.caps()
        print("    piper_sample_generator flags:", " ".join(sorted(c)))
        good &= _row({"--model", "--max-samples", "--output-dir", "--batch-size", "--phoneme-input"} <= c, "required piper flags present")
    except Exception as e:
        good &= _row(False, "piper_sample_generator --help", str(e)[:100])
    voice = config.ROOT / cfg["generate"]["voice_model"]
    _row(voice.exists() and voice.with_name(voice.name + ".json").exists(), "piper voice model + json downloaded", "(python cli.py fetch-voice)")
    print("doctor:", "all required checks passed" if good else "fix the [!!] items first")
