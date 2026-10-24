from collections import Counter


def _load(path):
    import tensorflow as tf

    it = tf.lite.Interpreter(model_path=str(path))
    it.allocate_tensors()
    return it


def signature(path):
    it = _load(path)
    i, o = it.get_input_details()[0], it.get_output_details()[0]
    ops = Counter(d["op_name"] for d in it._get_ops_details())
    shapes = Counter(tuple(int(s) for s in t["shape"]) for t in it.get_tensor_details() if len(t["shape"]) == 4)
    import os

    return {
        "bytes": os.path.getsize(path), "input": (tuple(i["shape"]), str(i["dtype"]), i["quantization"]),
        "output": (tuple(o["shape"]), str(o["dtype"]), o["quantization"]), "ops": dict(ops), "shapes4d": dict(shapes),
    }


def report(path):
    for k, v in signature(path).items():
        print(f"{k}: {v}")


def compare(a, b):
    sa, sb = signature(a), signature(b)
    same = True
    for k in ("input", "output", "ops", "shapes4d"):
        ok = sa[k] == sb[k]
        same &= ok
        print(f"{k}: {'MATCH' if ok else 'DIFFERS'}")
        if not ok:
            print("  ", a, sa[k])
            print("  ", b, sb[k])
    print(f"bytes: {sa['bytes']} vs {sb['bytes']}")
    print("ARCHITECTURE MATCH" if same else "ARCHITECTURE DIFFERS (quantization params may legitimately differ)")
