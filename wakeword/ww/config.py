import pathlib

import yaml

ROOT = pathlib.Path(__file__).resolve().parent.parent


def load(path=None):
    with open(path or ROOT / "config.yaml") as f:
        return yaml.safe_load(f)


def path(cfg, key, *parts):
    return ROOT.joinpath(cfg["paths"][key], *parts)
