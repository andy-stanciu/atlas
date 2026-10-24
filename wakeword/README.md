# Atlas wake-word pipeline ("hey atlas")

Isolated from `src/`: own venv, own config, own recorder firmware. Everything is driven by `config.yaml`.

## What this trains

A microWakeWord streaming model using the upstream recipe (`OHF-Voice/micro-wake-word`, pinned in
`setup.sh`): Piper multi-speaker synthetic speech + room-impulse/music/noise augmentation, plus
your real recordings, hard negatives and mined false positives. Architecture defaults are the
upstream MixedNet config (`architecture:` in `config.yaml`). Verify it matches `hey_jarvis` with
`arch-diff` before trusting it (step 8).

## One-time setup (Ubuntu desktop, stop vLLM first: training wants the 3090)

    cd wakeword && ./setup.sh          # python3.10 venv, clones upstream, installs, runs doctor
    . .venv/bin/activate
    python cli.py doctor               # every line must be [ok] (GPU lines are warnings)
    python cli.py fetch-data           # ~30 GB: RIRs, AudioSet, FMA, upstream negatives, Piper voice
    python cli.py fetch-stock          # stock hey_jarvis model for comparison
    python cli.py selftest             # sanity-check the inference mirror against hey_jarvis

## Recording (on the Mac, any time before step 4)

1. `cd wakeword/recorder && ln -s ../../src/satellite/secrets.yaml secrets.yaml`
2. Flash: `esphome run atlas-recorder.yaml`. The ring shows red breathing until the server connects.
3. Quit the Atlas client (it listens on 8765; the recorder uses 8766, but the satellite is no longer an Atlas satellite while flashed).
4. Record (`python3 capture_server.py ...`; amber = ready, green = speak, blue = saved). Suggested:

| Run | Command (add `--pause` if you want to pace yourself) |
|---|---|
| train positives, 1 m quiet | `positives --split train --speaker andy --cond quiet --dist 1m --count 60` |
| train positives, 3 m music | `positives --split train --speaker andy --cond music --dist 3m --count 60` |
| test positives (different speaker/distance/room mix) | `positives --split test --speaker <name> --cond tv --dist 2m --count 60` |
| hard negatives (train + test) | `negatives --split train ... --count 80`, then `--split test` |
| ambient train (TV, music, cooking) | `ambient --split train --label tv --minutes 30` |
| ambient test (different sessions) | `ambient --split test --label kitchen --minutes 30` |

Keep the test split truly held out: different people, distances, rooms, or days than train.
Aim for 150+ train and 75+ test positives, 2 h+ ambient per split.

5. Restore the satellite: `cd ../../src/satellite && esphome run atlas-satellite.yaml`.

## Training (back on the desktop)

    python cli.py audition             # listen to work/audition/*.wav; fix spellings in config.yaml
    python cli.py generate             # synthetic positives + hard negatives
    # copy recorder data/ (rsync from the Mac) into wakeword/data/
    python cli.py prepare-real         # QC + trim -> work/real_prepared, report in qc.tsv
    python cli.py features
    python cli.py train --fresh
    python cli.py export               # models/hey_atlas.{tflite,json}
    python cli.py arch models/hey_atlas.tflite
    python cli.py arch-diff models/hey_atlas.tflite models/stock/hey_jarvis.tflite
    python cli.py eval --export        # test positives, hard negatives, ambient FAPH; writes the best cutoff
    python cli.py all --fresh          # generate -> prepare-real -> features -> train -> export -> eval

`eval` replays the held-out real positives, held-out hard negatives, and `data/ambient/test` through a
streaming mirror of the on-device pipeline (`ww/infer.py`) and tabulates recall, hard-negative false
positive rate and false accepts per hour per cutoff.

## Iterating

    python cli.py mine                 # false triggers on data/ambient/train -> data/fp_negatives
    python cli.py features --force && python cli.py train --fresh && python cli.py export && python cli.py eval --export

## Putting it on the satellite

Copy `models/hey_atlas.json` and `.tflite` next to `src/satellite/atlas-satellite.yaml` (or reference
the manifest by path) and change the wake-word model entry from `hey_jarvis` to `hey_atlas.json`. Then
remove `"jarvis"` from `Config.wakeWords` in the Atlas client.

## Known assumptions (verify with `doctor`/`selftest`)

* Upstream Python API names (`Clips`, `Augmentation`, `SpectrogramGeneration`) are checked by signature in `doctor`.
* Piper flags are discovered from `generate_samples.py --help`; unsupported optional flags are skipped.
* `ww/infer.py` assumes `pymicro_features.MicroFrontend.process_samples`; `selftest` proves it against stock hey_jarvis.
* The stock-model download URLs are tried in two layouts; if both fail, copy the files from the ESPHome cache.
