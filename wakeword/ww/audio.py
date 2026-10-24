from math import gcd

import numpy as np
import soundfile as sf
from scipy.signal import resample_poly

SR = 16000


def resample(x, sr):
    if sr == SR:
        return x
    g = gcd(sr, SR)
    return resample_poly(x, SR // g, sr // g, axis=0).astype("float32")


def read(path):
    x, sr = sf.read(str(path), dtype="float32", always_2d=True)
    return resample(x, sr)


def write(path, x, sr=SR):
    sf.write(str(path), x, sr, subtype="PCM_16")


def pick(x, ch):
    return x[:, min(ch, x.shape[1] - 1)]
