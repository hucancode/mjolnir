#!/usr/bin/env python3
"""Aggregate Mjolnir bench JSON outputs into github-action-benchmark inputs.

Reads any number of input JSON files (each = list of {name,unit,value,extra}),
splits records into three output files based on the metric kind:

  * smaller_out  — latency/time metrics (smaller is better)
  * bigger_out   — throughput metrics (bigger is better)
  * context_out  — counters / observational metrics (no regression alerts)

The first two are consumed by `benchmark-action/github-action-benchmark`
with tool=customSmallerIsBetter / customBiggerIsBetter respectively.
"""

import argparse
import json
import sys
from pathlib import Path

BIGGER_UNITS = {
    "rays_per_ms",
    "M_ops_per_s",
    "ops_per_s",
    "bodies_per_ms",
    "fps",
}

CONTEXT_UNITS = {
    "bodies",
    "contacts",
    "pairs",
    "nodes",
    "count",
}


def classify(unit: str) -> str:
    if unit in BIGGER_UNITS:
        return "bigger"
    if unit in CONTEXT_UNITS:
        return "context"
    return "smaller"


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("inputs", nargs="+", help="bench JSON files to merge")
    ap.add_argument("--smaller-out", default="bench-smaller.json")
    ap.add_argument("--bigger-out", default="bench-bigger.json")
    ap.add_argument("--context-out", default="bench-context.json")
    args = ap.parse_args()

    buckets: dict[str, list[dict]] = {"smaller": [], "bigger": [], "context": []}
    for path in args.inputs:
        with open(path) as f:
            data = json.load(f)
        if not isinstance(data, list):
            print(f"skip {path}: not a list", file=sys.stderr)
            continue
        for rec in data:
            if not all(k in rec for k in ("name", "unit", "value")):
                print(f"skip malformed in {path}: {rec}", file=sys.stderr)
                continue
            buckets[classify(rec["unit"])].append(
                {
                    "name": rec["name"],
                    "unit": rec["unit"],
                    "value": rec["value"],
                    "extra": rec.get("extra", ""),
                }
            )

    Path(args.smaller_out).write_text(json.dumps(buckets["smaller"], indent=2))
    Path(args.bigger_out).write_text(json.dumps(buckets["bigger"], indent=2))
    Path(args.context_out).write_text(json.dumps(buckets["context"], indent=2))

    summary = " ".join(f"{k}={len(v)}" for k, v in buckets.items())
    print(f"agg_bench: {summary}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
