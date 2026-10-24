#!/usr/bin/env python3
import argparse

from ww import arch, config, data, doctor, evaluate, export, features, generate, real, smoke, train, upstream

cfg = config.load()


def _train(a):
    train.train(cfg, fresh=a.fresh, smoke=a.smoke)


def _eval(a):
    c = evaluate.evaluate(cfg, a.model)
    if a.export and c:
        export.export(cfg, c)


def _all(a):
    generate.positives(cfg)
    generate.negatives(cfg)
    real.prepare(cfg)
    features.build(cfg)
    train.train(cfg, fresh=a.fresh)
    export.export(cfg)
    evaluate.evaluate(cfg)


def main():
    p = argparse.ArgumentParser(description="Atlas wake-word pipeline")
    sub = p.add_subparsers(dest="cmd", required=True)
    simple = {
        "doctor": lambda a: doctor.check(cfg),
        "fetch-voice": lambda a: data.fetch_voice(cfg),
        "fetch-data": lambda a: data.fetch(cfg),
        "fetch-stock": lambda a: evaluate.fetch_stock(cfg),
        "smoke": lambda a: smoke.run(cfg),
        "patch-upstream": lambda a: upstream.patch(),
        "audition": lambda a: generate.audition(cfg),
        "generate": lambda a: (generate.positives(cfg), generate.negatives(cfg)),
        "prepare-real": lambda a: real.prepare(cfg),
        "features": lambda a: features.build(cfg, force=a.force),
        "export": lambda a: export.export(cfg),
        "mine": lambda a: evaluate.mine(cfg, a.model),
        "selftest": lambda a: evaluate.selftest(cfg),
        "arch": lambda a: arch.report(a.model),
    }
    for name, fn in simple.items():
        s = sub.add_parser(name)
        s.add_argument("--force", action="store_true")
        s.add_argument("--model")
        s.set_defaults(fn=fn)
    s = sub.add_parser("train")
    s.add_argument("--fresh", action="store_true")
    s.add_argument("--smoke", action="store_true", help="20-step run to exercise the upstream trainer")
    s.set_defaults(fn=_train)
    s = sub.add_parser("eval")
    s.add_argument("--model")
    s.add_argument("--export", action="store_true", help="re-export the manifest with the recommended cutoff")
    s.set_defaults(fn=_eval)
    s = sub.add_parser("arch-diff")
    s.add_argument("a")
    s.add_argument("b")
    s.set_defaults(fn=lambda a: arch.compare(a.a, a.b))
    s = sub.add_parser("all")
    s.add_argument("--fresh", action="store_true")
    s.set_defaults(fn=_all)
    a = p.parse_args()
    a.fn(a)


if __name__ == "__main__":
    main()
