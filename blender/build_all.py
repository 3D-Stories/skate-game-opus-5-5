"""Rebuilds every 3D asset of Pro Skater from scratch.

    blender --background --python blender/build_all.py            (full quality)
    blender --background --python blender/build_all.py -- --fast  (quick check)
    blender --background --python blender/build_all.py -- --only board,park

Outputs: assets/board.glb, assets/skater.glb, assets/park.glb, assets/park_data.json,
renders/*.png. The same modules are run in the live Blender window while developing,
so the headless rebuild matches the live build.
"""
import os
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
if HERE not in sys.path:
    sys.path.insert(0, HERE)

import addon_utils  # noqa: E402
import bpy  # noqa: E402

if "bl_ext.blender_org.mpfb" not in bpy.context.preferences.addons:
    addon_utils.enable("bl_ext.blender_org.mpfb", default_set=True)

from lib import common as C  # noqa: E402


def parse():
    argv = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []
    fast = "--fast" in argv
    only = None
    if "--only" in argv:
        only = set(argv[argv.index("--only") + 1].split(","))
    return fast, only


def main():
    fast, only = parse()
    C.FAST = fast
    t0 = time.time()
    want = lambda k: only is None or k in only
    import board, skater, anims, park, pickups, renders
    if want("pickups"):
        pickups.build()
        print(f"[build_all] pickups done {time.time() - t0:.0f}s")
    if want("board"):
        board.build()
        print(f"[build_all] board done {time.time() - t0:.0f}s")
    if want("skater"):
        info = skater.build()
        rig, made = anims.build(info)
        anims.export_skater(rig)
        print(f"[build_all] skater done {time.time() - t0:.0f}s")
    if want("park"):
        park.build()
        print(f"[build_all] park done {time.time() - t0:.0f}s")
    if want("renders"):
        renders.build()
        print(f"[build_all] renders done {time.time() - t0:.0f}s")
    print(f"[build_all] finished in {time.time() - t0:.0f}s")


main()
