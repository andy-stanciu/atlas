import shutil
import urllib.request

import microwakeword

from pathlib import Path

BASE = "https://raw.githubusercontent.com/malonestar/custom-micro-wake-word-model/main/microWakeWord/microwakeword"
FILES = ("train.py", "test.py", "audio/clips.py")


def patch():
    root = Path(microwakeword.__file__).parent
    for rel in FILES:
        dst = root / rel
        if not (dst.with_suffix(".py.orig")).exists():
            shutil.copy(dst, dst.with_suffix(".py.orig"))
        urllib.request.urlretrieve(f"{BASE}/{rel}", dst)
        print("patched", dst)
