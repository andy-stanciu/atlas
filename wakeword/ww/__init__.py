import os
import pathlib
import sys

_p = pathlib.Path(__file__).resolve().parent.parent / "third_party" / "piper" / "src" / "python"
if _p.exists():
    sys.path.insert(0, str(_p))
    os.environ["PYTHONPATH"] = os.pathsep.join(filter(None, [str(_p), os.environ.get("PYTHONPATH", "")]))
