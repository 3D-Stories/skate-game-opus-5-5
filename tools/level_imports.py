#!/usr/bin/env python3
"""Give a kit-built level's textures the same Godot import settings as the Warehouse's
(VRAM-compressed S3TC/BPTC, mipmaps, 1024 px albedo / 2048 px normal limits; the lightmap
BPTC high quality without mipmaps). Run after the level's first Godot import, then
re-import:

    python3 tools/level_imports.py <id>      (then: godot --headless --path . --import)

Only the [params] of each .import file change; Godot keeps them from then on, and the
.import files are committed with the assets.
"""
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
REF = {
    "albedo": "assets/park_park_brick_albedo.webp.import",
    "normal": "assets/park_park_brick_normal.webp.import",
    "lightmap": "assets/park_lightmap.png.import",
}


def params(path):
    s = open(os.path.join(ROOT, path)).read()
    return s[s.index("[params]"):]


def main(level_id):
    d = os.path.join(ROOT, "assets", "levels", level_id)
    n = 0
    for f in sorted(os.listdir(d)):
        if not f.endswith(".import") or f.endswith(".glb.import"):
            continue
        src = f[:-len(".import")]
        kind = "lightmap" if src.endswith("_lightmap.png") else "normal" if "_normal." in src else "albedo"
        p = params(REF[kind])
        if kind == "normal":
            p = re.sub(r'roughness/src_normal="[^"]*"', f'roughness/src_normal="res://assets/levels/{level_id}/{src}"', p)
        path = os.path.join(d, f)
        s = open(path).read()
        new = s[:s.index("[params]")] + p
        if new != s:
            open(path, "w").write(new)
            n += 1
    print(f"{level_id}: {n} import files updated")


if __name__ == "__main__":
    main(sys.argv[1])
