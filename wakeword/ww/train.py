import os
import shutil
import sys

import yaml

from . import config
from .sh import run

FINAL = "tflite_stream_state_internal_quant/stream_state_internal_quant.tflite"


def _feature(path, s):
    return {
        "features_dir": str(path), "sampling_weight": s["sampling_weight"], "penalty_weight": s["penalty_weight"],
        "truth": s.get("truth", False), "truncation_strategy": s["truncation"], "type": "mmap",
    }


def train_dir(cfg, smoke=False):
    return config.path(cfg, "work", "trained", cfg["wake_word"]["name"] + ("_smoke" if smoke else ""))


def write_config(cfg, smoke=False):
    feats = []
    for name, s in cfg["features"]["sets"].items():
        p = config.path(cfg, "work", "features", name)
        if p.exists():
            feats.append(_feature(p, s))
    for name, s in cfg["negative_datasets"].items():
        p = config.path(cfg, "data", "negatives", name)
        if p.exists():
            feats.append(_feature(p, s))
    t = dict(cfg["training"])
    if smoke:
        t.update(steps=[20, 20], batch_size=64, eval_step_interval=10)
    conf = {
        "window_step_ms": 10, "train_dir": str(train_dir(cfg, smoke)), "features": feats,
        "training_steps": t["steps"], "positive_class_weight": t["positive_class_weight"],
        "negative_class_weight": t["negative_class_weight"], "learning_rates": t["learning_rates"],
        "batch_size": t["batch_size"], "time_mask_max_size": t["time_mask_max_size"],
        "time_mask_count": t["time_mask_count"], "freq_mask_max_size": t["freq_mask_max_size"],
        "freq_mask_count": t["freq_mask_count"], "eval_step_interval": t["eval_step_interval"],
        "clip_duration_ms": t["clip_duration_ms"], "target_minimization": t["target_minimization"],
        "minimization_metric": t["minimization_metric"], "maximization_metric": t["maximization_metric"],
    }
    out = config.path(cfg, "work", "training_parameters.yaml")
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(yaml.safe_dump(conf, sort_keys=False))
    return out


def train(cfg, fresh=False, smoke=False):
    out, tdir = write_config(cfg, smoke), train_dir(cfg, smoke)
    if fresh or smoke or (tdir.exists() and not (tdir / FINAL).exists()):
        shutil.rmtree(tdir, ignore_errors=True)
    elif (tdir / FINAL).exists():
        print(f"{tdir} already holds a finished model; use --fresh to retrain")
        return
    a = cfg["architecture"]
    cmd = [
        sys.executable, "-m", "microwakeword.model_train_eval", "--training_config", out,
        "--train", 1, "--restore_checkpoint", 0,
        "--test_tf_nonstreaming", 0, "--test_tflite_nonstreaming", 0, "--test_tflite_nonstreaming_quantized", 0,
        "--test_tflite_streaming", 0, "--test_tflite_streaming_quantized", 1,
        "--use_weights", "best_weights", a["type"],
        "--pointwise_filters", a["pointwise_filters"], "--repeat_in_block", a["repeat_in_block"],
        "--mixconv_kernel_sizes", a["mixconv_kernel_sizes"], "--residual_connection", a["residual_connection"],
        "--first_conv_filters", a["first_conv_filters"], "--first_conv_kernel_size", a["first_conv_kernel_size"],
        "--stride", a["stride"],
    ]
    run(cmd, env={**os.environ, "TF_FORCE_GPU_ALLOW_GROWTH": "true"})
