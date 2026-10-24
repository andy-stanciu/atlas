#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
if [ ! -d .venv ]; then
  if command -v python3.10 >/dev/null; then python3.10 -m venv .venv
  elif command -v uv >/dev/null; then uv venv --seed --python 3.10 .venv
  else echo "need python3.10 or uv: curl -LsSf https://astral.sh/uv/install.sh | sh"; exit 1; fi
fi
. .venv/bin/activate
pip install -U pip wheel "setuptools<81"
command -v espeak-ng >/dev/null || echo "note: sudo apt install espeak-ng (piper phonemization)"
MWW_REF=${MWW_REF:-a70bd7}
mkdir -p third_party
[ -d third_party/micro-wake-word ] || git clone https://github.com/OHF-Voice/micro-wake-word.git third_party/micro-wake-word
git -C third_party/micro-wake-word checkout "$MWW_REF" 2>/dev/null || echo "ref $MWW_REF not found; staying on default branch"
[ -d third_party/piper ] || git clone --depth 1 https://github.com/rhasspy/piper.git third_party/piper
pip install -r requirements.txt
pip install -e third_party/micro-wake-word
pip install piper-phonemize-cross || pip install piper-phonemize
pip install --upgrade piper-tts piper-sample-generator
if command -v nvidia-smi >/dev/null && ! python -c "import tensorflow as tf,sys;sys.exit(0 if tf.config.list_physical_devices('GPU') else 1)"; then
  pip install "tensorflow[and-cuda]==$(python -c 'import tensorflow as tf;print(tf.__version__)')"
fi
pip install -U "audiomentations>=0.35" cython
MA=third_party/piper/src/python/piper_train/vits/monotonic_align
if ! ls "$MA"/monotonic_align/core*.so >/dev/null 2>&1; then
  ( cd "$MA" && CFLAGS="-I$(python -c 'import numpy;print(numpy.get_include())')" cythonize -3 -i core.pyx )
  mkdir -p "$MA/monotonic_align" && cp "$MA"/core*.so "$MA/monotonic_align/"
fi
python cli.py doctor
