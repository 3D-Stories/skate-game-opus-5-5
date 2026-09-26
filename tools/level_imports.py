#!/usr/bin/env python3
"""Give a kit-built level's textures the same Godot import settings as the Warehouse's
(VRAM-compressed S3TC/BPTC with mipmaps; the lightmap BPTC high quality without mipmaps),
and each texture a size limit the way the Warehouse's were set: by how much of the screen
the material covers. Run after the level's first Godot import, then re-import:

    python3 tools/level_imports.py <id>      (then: godot --headless --path . --import)

Size limits (the Warehouse uses 1024 for its big walls and floors, 512 for mid-size
surfaces, 256 for small props and 2048 for the graffiti sheet): each material in the
level's build.materials may set "texture_px" (256, 512 or 1024; default 512). A shared
normal map takes the largest limit of the materials that use it. The graffiti sheet keeps
2048 and the decal atlas 1024. Only the [params] of each .import file change; Godot keeps
them from then on, and the .import files are committed with the assets.
"""
import json
import os
import re
import sys

from collections import defaultdict

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
REF = {
    "albedo": "assets/park_park_brick_albedo.webp.import",
    "normal": "assets/park_park_brick_normal.webp.import",
    "lightmap": "assets/park_lightmap.png.import",
}
DEFAULT_PX = 512
SHEET_PX = {"graffiti": 2048, "grime": 1024}


def params(path):
    s = open(os.path.join(ROOT, path)).read()
    return s[s.index("[params]"):]


def limits(level_id):
    """Texture file stem (without the level's prefix) -> size limit in px."""
    b = json.load(open(os.path.join(ROOT, "levels", level_id, "level.json")))["build"]
    out = dict(SHEET_PX)
    normal_px = defaultdict(int)
    for name, m in b["materials"].items():
        px = int(m.get("texture_px", DEFAULT_PX))
        out[name + "_albedo"] = px
        # the kit's shared normal map name: <src>_n<strength x 10> (levelkit/materials.py)
        key = "%s_n%d_normal" % (m["src"], int(round(float(m.get("normal", 2.0)) * 10)))
        normal_px[key] = max(normal_px[key], px)
        normal_px[name + "_normal"] = max(normal_px[name + "_normal"], px)
    out.update(normal_px)
    return out


def main(level_id):
    d = os.path.join(ROOT, "assets", "levels", level_id)
    lim = limits(level_id)
    n = 0
    for f in sorted(os.listdir(d)):
        if not f.endswith(".import") or f.endswith(".glb.import"):
            continue
        src = f[:-len(".import")]
        kind = "lightmap" if src.endswith("_lightmap.png") else "normal" if "_normal." in src else "albedo"
        p = params(REF[kind])
        if kind == "normal":
            p = re.sub(r'roughness/src_normal="[^"]*"', f'roughness/src_normal="res://assets/levels/{level_id}/{src}"', p)
        if kind != "lightmap":
            # the stem after the "<level>_<prefix>" Godot and the kit put in front
            stem = os.path.splitext(src)[0]
            hits = [k for k in lim if stem.endswith("_" + k)]
            px = lim[max(hits, key=len)] if hits else DEFAULT_PX
            p = re.sub(r"process/size_limit=\d+", f"process/size_limit={px}", p)
        path = os.path.join(d, f)
        s = open(path).read()
        new = s[:s.index("[params]")] + p
        if new != s:
            open(path, "w").write(new)
            n += 1
    print(f"{level_id}: {n} import files updated")


if __name__ == "__main__":
    main(sys.argv[1])
