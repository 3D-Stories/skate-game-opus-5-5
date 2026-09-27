#!/usr/bin/env python3
"""Pixel hashes of a tests/skater_snapshot.gd capture (SHA-256 of each image's raw RGB),
and a comparison against a stored set, so "the default skater renders exactly as before"
is checkable without committing the images.

    python3 tests/snapshot_hashes.py DIR > tests/data/skater_baseline_snapshots.json
    python3 tests/snapshot_hashes.py DIR --compare tests/data/skater_baseline_snapshots.json [--against OLD_DIR]
With --against, differing images are also diffed pixel by pixel (max difference, count).
"""
import hashlib
import json
import os
import sys

from PIL import Image, ImageChops


def hashes(d):
    names = json.load(open(os.path.join(d, "index.json")))["images"]
    return {n: hashlib.sha256(Image.open(os.path.join(d, n)).convert("RGB").tobytes()).hexdigest() for n in names}


def main():
    d = sys.argv[1]
    h = hashes(d)
    if "--compare" not in sys.argv:
        print(json.dumps(h, indent=1, sort_keys=True))
        return
    ref = json.load(open(sys.argv[sys.argv.index("--compare") + 1]))
    old = sys.argv[sys.argv.index("--against") + 1] if "--against" in sys.argv else None
    same = [n for n in ref if h.get(n) == ref[n]]
    bad = [n for n in ref if h.get(n) != ref[n]]
    for n in bad:
        line = f"DIFF  {n}"
        if old and n in h:
            x = Image.open(os.path.join(old, n)).convert("RGB")
            y = Image.open(os.path.join(d, n)).convert("RGB")
            hist = ImageChops.difference(x, y).convert("L").histogram()
            line += f"  max {max(i for i, c in enumerate(hist) if c)}/255, {sum(hist[1:])} px differ"
        print(line)
    print(f"{len(same)} of {len(ref)} images pixel-identical to the baseline")
    sys.exit(0 if not bad else 1)


main()
