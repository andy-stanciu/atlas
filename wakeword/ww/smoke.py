import shutil

import numpy as np
import soundfile as sf

from . import config, generate


def run(cfg):
    d = config.path(cfg, "work", "smoke")
    shutil.rmtree(d, ignore_errors=True)
    (d / "bg").mkdir(parents=True)
    (d / "rir").mkdir()
    generate.gen(cfg, [{**cfg["generate"]["positives"][0], "samples": 20}], d / "clips")
    sf.write(d / "bg" / "noise.wav", (np.random.randn(16000 * 3) * 1000).astype(np.int16), 16000)
    rir = np.zeros(4000, dtype=np.float32)
    rir[0], rir[100] = 1.0, 0.3
    sf.write(d / "rir" / "rir.wav", rir, 16000)

    from microwakeword.audio.augmentation import Augmentation
    from microwakeword.audio.clips import Clips
    from microwakeword.audio.spectrograms import SpectrogramGeneration
    from mmap_ninja.ragged import RaggedMmap

    a = cfg["augment"]
    clips = Clips(input_directory=str(d / "clips"), file_pattern="*.wav", max_clip_duration_s=None,
                  remove_silence=cfg["features"]["remove_silence"], random_split_seed=42, split_count=0.1)
    aug = Augmentation(
        augmentation_duration_s=a["duration_s"], augmentation_probabilities=a["probabilities"],
        impulse_paths=[str(d / "rir")], background_paths=[str(d / "bg")],
        background_min_snr_db=a["snr_db"][0], background_max_snr_db=a["snr_db"][1],
        min_jitter_s=a["jitter_s"][0], max_jitter_s=a["jitter_s"][1])
    spec = SpectrogramGeneration(clips=clips, augmenter=aug, slide_frames=10, step_ms=10)
    RaggedMmap.from_generator(out_dir=str(d / "features"), sample_generator=spec.spectrogram_generator(split="train", repeat=1),
                              batch_size=8, verbose=False)
    print("augmentation + feature smoke OK")

    import tensorflow as tf

    m = tf.keras.Sequential([tf.keras.layers.Dense(4)])
    m.compile("adam", "mse")
    m.fit(np.random.rand(64, 8), np.random.rand(64, 4), epochs=1, verbose=0)
    print("TF training smoke OK on", "GPU" if tf.config.list_physical_devices("GPU") else "CPU(!)")
