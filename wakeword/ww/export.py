import json
import shutil

from . import config


def trained_model(cfg):
    root = config.path(cfg, "work", "trained", cfg["wake_word"]["name"])
    hits = sorted(root.rglob("stream_state_internal_quant.tflite"))
    if not hits:
        raise SystemExit(f"no streaming tflite under {root}; run train first")
    return hits[-1]


def export(cfg, cutoff=None):
    w, e = cfg["wake_word"], cfg["export"]
    out = config.path(cfg, "models")
    out.mkdir(parents=True, exist_ok=True)
    shutil.copy(trained_model(cfg), out / f"{w['name']}.tflite")
    arena = e["tensor_arena_size"]
    ref = config.path(cfg, "models").parent / (e["reference_model"] + ".json")
    if ref.exists():
        arena = json.loads(ref.read_text())["micro"]["tensor_arena_size"]
    else:
        print(f"no reference manifest; using tensor_arena_size {arena} (raise it if ESPHome reports allocation errors)")
    manifest = {
        "type": "micro", "wake_word": w["display"], "author": w["author"], "website": "",
        "model": f"{w['name']}.tflite", "trained_languages": ["en"], "version": 2,
        "micro": {
            "probability_cutoff": cutoff or e["probability_cutoff"],
            "sliding_window_size": e["sliding_window_size"], "feature_step_size": e["feature_step_size"],
            "tensor_arena_size": arena, "minimum_esphome_version": e["minimum_esphome_version"],
        },
    }
    (out / f"{w['name']}.json").write_text(json.dumps(manifest, indent=2) + "\n")
    print("wrote", out / f"{w['name']}.json")
