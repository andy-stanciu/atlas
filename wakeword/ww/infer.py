from collections import deque

import numpy as np

from . import audio


class Detector:
    def __init__(self, tflite, window=5):
        import tensorflow as tf
        from pymicro_features import MicroFrontend

        self.fe_cls, self.window = MicroFrontend, window
        self.it = tf.lite.Interpreter(model_path=str(tflite))
        self.it.allocate_tensors()
        i, o = self.it.get_input_details()[0], self.it.get_output_details()[0]
        self.i, self.o = i, o
        self.stride = int(i["shape"][1])
        self.step_s = self.stride * 0.01

    def _q(self, x, d):
        scale, zp = d["quantization"]
        if d["dtype"] in (np.int8, np.uint8):
            info = np.iinfo(d["dtype"])
            return np.clip(np.round(x / scale + zp), info.min, info.max).astype(d["dtype"])
        return x.astype(d["dtype"])

    def _dq(self, x, d):
        scale, zp = d["quantization"]
        return float((x.astype(np.float32) - zp) * scale) if d["dtype"] in (np.int8, np.uint8) else float(x)

    def features(self, pcm):
        fe, data, idx, out = self.fe_cls(), (np.clip(pcm, -1, 1) * 32767).astype("<i2").tobytes(), 0, []
        while idx + 320 <= len(data):
            r = fe.process_samples(data[idx:])
            if r.samples_read <= 0:
                break
            idx += r.samples_read * 2
            if r.features:
                out.append(np.asarray(r.features, dtype=np.float32))
        return out

    def run(self, pcm):
        self.it.reset_all_variables()
        feats, probs = self.features(pcm), []
        for k in range(0, len(feats) - self.stride + 1, self.stride):
            x = np.stack(feats[k : k + self.stride])[None]
            self.it.set_tensor(self.i["index"], self._q(x, self.i))
            self.it.invoke()
            probs.append(self._dq(self.it.get_tensor(self.o["index"]).ravel()[0], self.o))
        p = np.asarray(probs, dtype=np.float32)
        if len(p) < self.window:
            return np.zeros(len(p), dtype=np.float32)
        avg = np.convolve(p, np.ones(self.window) / self.window, mode="valid")
        return np.concatenate([np.zeros(self.window - 1, dtype=np.float32), avg])

    def run_file(self, path, ch=1, pad=(0.5, 1.0)):
        x = audio.pick(audio.read(path), ch)
        z = lambda s: np.zeros(int(s * audio.SR), dtype=np.float32)
        return self.run(np.concatenate([z(pad[0]), x, z(pad[1])]))
