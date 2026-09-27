#!/usr/bin/env python3
"""Gives the character builder's textures the import settings the editor gave the original
skater's textures (VRAM compressed - S3TC + ETC2 for the web - mipmaps, a size limit at the
image's own size, normal maps flagged as such with roughness filtered from them). A headless
`godot --import` creates new .import files with plain defaults instead (lossless: several
times larger in the web build), and the male garments' maps, which moved from skater.glb to
assets/outfit/, would then render differently from before.

    python3 tests/texture_imports.py          (then: godot --headless --path . --import)

The male garments' maps take their original import (from git, the commit before the
character builder) verbatim, but for the path; the female's body maps take the import of
the male's matching map (size limit included); every other new map copies the original
import of its kind (albedo / normal / roughness / alpha) with its own size and path.
"""
import glob
import os
import re
import subprocess

from PIL import Image

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ORIGINAL = "696364b"            # the last commit before the character builder
# the male garment maps that moved out of skater.glb: new name -> original name
MOVED = {"male_hoodie_Hoodie": "skater_Hoodie", "male_hoodie_Hood_hood_back": "skater_Hood_hood_back",
         "male_hoodie_Hood_hood_roll": "skater_Hood_hood_roll", "male_jeans_Jeans": "skater_Jeans",
         "male_suede_ShoeUpper": "skater_ShoeUpper", "male_suede_ShoeSole": "skater_ShoeSole"}
KIND_TEMPLATE = {"albedo": "skater_Hoodie_albedo", "normal": "skater_Hoodie_normal", "rough": "skater_Hoodie_rough",
                 "alpha": "skater_lash_alpha", "atlas": "skater_hair_atlas", "eye": "skater_eye_albedo"}


def original_import(name):
    return subprocess.run(["git", "-C", ROOT, "show", f"{ORIGINAL}:assets/{name}.webp.import"],
                          capture_output=True, text=True, check=True).stdout


def kind(base):
    b = base[:-2] if base.endswith("_f") else base
    if b.endswith("_normal"):
        return "normal"
    if b.endswith("_rough"):
        return "rough"
    if "atlas" in b:
        return "atlas"
    if "alpha" in b:
        return "alpha"
    if b.endswith("eye_albedo"):
        return "eye"
    return "albedo"


def size_limit(rel, base):
    """The new garments' maps (the web download budget): albedo at its own size, normal
    maps at 512 (the in-game camera never resolves more; today's hoodie, jeans and shoes
    keep their original 1024), a roughness map of one flat value at 16 px (most are: the
    same look for a fraction of the download), any other roughness map at 512."""
    im = Image.open(os.path.join(ROOT, rel))
    w = im.size[0]
    if base.endswith("_rough"):
        flat = all(lo == hi for lo, hi in im.convert("RGB").getextrema())
        return 16 if flat else min(w, 512)
    if base.endswith("_normal"):
        return min(w, 512)
    return w


def main():
    files = sorted(glob.glob(os.path.join(ROOT, "assets/outfit/*.webp.import")) +
                   glob.glob(os.path.join(ROOT, "assets/skater_female_*.webp.import")))
    changed = 0
    stale = 0
    for f in files:
        rel = os.path.relpath(f, ROOT)[:-len(".import")]          # assets/.../x.webp
        base = os.path.basename(rel)[:-len(".webp")]
        stem, _, suffix = base.rpartition("_")
        moved = MOVED.get(stem)
        twin = None
        if base.startswith("skater_female_") and base.endswith("_f"):
            # her body maps: his matching map's import, size limit and all (the same budget)
            twin = "skater_" + base[len("skater_female_"):-2]
        tmpl = original_import(f"{moved}_{suffix}" if moved else twin if twin else KIND_TEMPLATE[kind(base)])
        p = tmpl[tmpl.index("[params]"):]
        p = re.sub(r'roughness/src_normal="[^"]*"',
                   f'roughness/src_normal="res://{rel}"' if 'roughness/src_normal="res' in p else 'roughness/src_normal=""', p)
        if not moved and not twin:
            p = re.sub(r"process/size_limit=\d+", f"process/size_limit={size_limit(rel, base)}", p)
        cur = open(f).read()
        vram = re.search(r'"vram_texture": (true|false)', tmpl).group(0)
        new = re.sub(r'"vram_texture": (true|false)', vram, cur[:cur.index("[params]")]) + p
        if new != cur:
            open(f, "w").write(new)
            changed += 1
        # a VRAM-compressed texture whose imported files are still the lossless ones: Godot
        # keeps them while they exist (the .import's remap names them), so delete them and
        # the cache's record of this source: the next import writes the compressed ones
        # (and any texture whose settings just changed: its imported files are all redone)
        if new != cur or ('"vram_texture": true' in new and ".s3tc.ctex" not in new):
            for old in glob.glob(os.path.join(ROOT, ".godot/imported", os.path.basename(rel) + "-*")):
                if old.endswith((".md5", ".ctex")) and (new != cur or (".s3tc." not in old and ".etc2." not in old)):
                    os.remove(old)
            stale += 1
    print(f"{changed} of {len(files)} texture imports set to the original skater's texture settings, "
          f"{stale} queued for re-import (run godot --headless --path . --import)")


main()
