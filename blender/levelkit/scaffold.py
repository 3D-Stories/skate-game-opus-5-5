#!/usr/bin/env python3
"""Create a new level skeleton, wired into the build and the game (plain python3, no Blender).

    python3 blender/levelkit/scaffold.py <id> "<Level Name>" [--blurb "..."] [--force]

Writes
    levels/<id>/level.json          the level definition: game (name, goals, assets, look),
                                    test (scale checks, rides, pump, camera segments, shots)
                                    and build (materials, lights, graffiti, features, pickups)
    levels/<id>/autopilot_route.gd  a starter two-minute route (drop in, halfpipe airs)
and adds <id> to levels/registry.json. From then on
    blender --background --python blender/build_all.py -- --only <id>     builds it
    godot --headless --path . --import                                   imports it
    godot --headless --path . --fixed-fps 60 -s tests/test_level.gd -- --level=<id>   tests it
    tests/run_all.sh, the level select, tools/export_web.sh              pick it up from the registry

The starter park is small but complete, so the first build, import and test all work: a
30 x 40 m hall (concrete and brick, two windows, a flat roof), a drop-in quarterpipe, a
halfpipe, a kicker, a funbox with a rail, a flat rail, a ledge, three knock-over signs and a
storeroom behind a breakable grille with the tape in it, S-K-A-T-E, a gap, a lit bake. Move,
replace and add features from there; docs/LEVELS.md is the step-by-step guide.
"""
import argparse
import json
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
LEVELS = os.path.join(ROOT, "levels")


def starter(lid, name, blurb):
    P = lid.capitalize()
    return {
        "id": lid,
        "format": 1,
        "game": {
            "name": name,
            "blurb": blurb,
            "assets": {"glb": f"res://assets/levels/{lid}/{lid}.glb", "data": f"res://assets/levels/{lid}/{lid}_data.json",
                       "lightmap": f"res://assets/levels/{lid}/{lid}_lightmap.png"},
            "pack": f"levels/{lid}.pck",
            "run_time": 120,
            "cleared": f"{name} cleared",
            "autopilot": f"res://levels/{lid}/autopilot_route.gd",
            "goals": [
                {"id": "score", "type": "score", "target": 20000},
                {"id": "skate", "type": "letters", "title": "Collect S-K-A-T-E"},
                {"id": "tape", "type": "tape", "title": "Find the Secret Tape"},
                {"id": "signs", "type": "break", "group": "signs", "count": 3, "title": "Knock Down the 3 Signs"},
                {"id": "flat_rail", "type": "grind", "rails": ["flat_rail"], "time": 1.0, "title": "Grind the Flat Rail"},
                {"id": "kicker_gap", "type": "gap", "gap": "kicker_gap", "title": "Hit the Kicker Gap"}
            ],
            "environment": {"ambient_color": [0.5, 0.52, 0.56], "ambient_energy": 0.7, "fog_color": [0.6, 0.62, 0.66],
                            "fog_density": 0.003, "sun_color": [1.0, 0.88, 0.72], "sun_energy": 2.0, "exposure": 1.0}
        },
        "test": {
            "scale": [
                {"what": "the hall floor is at 0 m", "down": [0.0, 0.0], "expect": [-0.02, 0.02]},
                {"what": "the hall is 30 m wide", "width": [0.0, 4.0, 1.2], "axis": [1, 0, 0], "expect": [29.8, 30.05]},
                {"what": "the hall is 40 m long", "width": [-11.0, 0.0, 1.2], "axis": [0, 1, 0], "expect": [39.8, 40.05]},
                {"what": "the roof is 7 m up (the roof mesh)", "mesh_top": f"{P}_roof", "expect": [6.95, 7.05]},
                {"what": "the drop-in deck is 2.4 m up", "down": [0.0, -18.8], "expect": [2.37, 2.43]},
                {"what": "the halfpipe's decks are 3.2 m up", "down": [6.2, 12.0], "expect": [3.17, 3.23]}
            ],
            "rides": [
                {"what": "halfpipe: across and up both walls", "at": [0.0, 12.0, 0.0], "dir": [1, 0, 0], "speed": 8.0, "frames": 300,
                 "expect": {"rev": True, "wood_above": 2.0}},
                {"what": "drop in off the south deck", "at": [0.0, -18.6, 2.4], "dir": [0, 1, 0], "speed": 1.0, "frames": 180,
                 "expect": {"below": 0.1, "steep": 60.0}},
                {"what": "kicker launches into the air", "at": [8.0, -11.0, 0.0], "dir": [0, 1, 0], "speed": 7.5, "frames": 120,
                 "expect": {"air": True, "air_above": 0.9}}
            ],
            "pump": {"what": "halfpipe", "at": [0.0, 12.0, 0.0], "axis": [1, 0, 0], "speed": 6.0, "seconds": 20},
            "segments": {"start": [0.0, 10.0], "halfpipe": [10.0, 60.0], "end": [110.0, 121.0]},
            "shots": [
                {"name": "spawn", "at": [0.0, -18.6, 2.4], "dir": [0, 1, 0]},
                {"name": "halfpipe", "at": [-8.0, 5.0, 0.0], "dir": [1, 1, 0]},
                {"name": "street", "at": [10.0, -12.0, 0.0], "dir": [-1, 1, 0]},
                {"name": "storeroom", "at": [11.0, 0.0, 0.0], "dir": [1, 0, 0]}
            ]
        },
        "build": {
            "builder": "levelkit",
            "material_prefix": f"{lid}_",
            "object_prefix": f"{P}_",
            "materials": {
                "concrete": {"texture_px": 1024, "src": "concrete_floor", "tile": 2.0, "tint": [1.1, 1.08, 1.04], "rough": [0.7, 0.9], "normal": 2.5},
                "concrete_floor": {"texture_px": 1024, "src": "concrete_floor", "tile": 3.2, "tint": [0.9, 0.9, 0.9], "rough": [0.55, 0.85], "normal": 2.0, "rough_invert": True},
                "brick": {"texture_px": 1024, "src": "brick", "tile": 3.0, "rough": [0.75, 0.95], "normal": 4.0},
                "roof": {"src": "plywood", "tile": 2.44, "tint": [0.55, 0.52, 0.48], "rough": [0.6, 0.85], "normal": 1.2},
                "plywood": {"texture_px": 1024, "src": "plywood", "tile": 2.44, "rough": [0.55, 0.8], "normal": 1.5},
                "rampside": {"src": "plywood", "tile": 2.44, "tint": [0.5, 0.52, 0.56], "rough": [0.6, 0.85], "normal": 1.5},
                "coping": {"src": "diamond_plate", "tile": 0.5, "flat": [0.62, 0.62, 0.62], "flat_mix": [0.8, 0.3], "rough": [0.25, 0.45], "normal": 0.5, "metallic": 1.0},
                "steel": {"src": "painted_steel", "tile": 1.2, "rough": [0.45, 0.75], "normal": 2.0, "metallic": 0.3},
                "steel_paint": {"src": "painted_steel", "tile": 1.5, "tint": [0.62, 0.6, 0.55], "rough": [0.45, 0.75], "normal": 2.0, "metallic": 0.3},
                "rail": {"texture_px": 256, "src": "painted_steel", "tile": 0.8, "tint": [0.95, 0.45, 0.12], "rough": [0.35, 0.6], "normal": 1.5, "metallic": 0.4},
                "grille": {"texture_px": 256, "src": "painted_steel", "tile": 1.0, "tint": [0.62, 0.38, 0.26], "rough": [0.5, 0.8], "normal": 2.5, "metallic": 0.4},
                "crate": {"src": "crate_wood", "tile": 1.3, "rough": [0.7, 0.9], "normal": 2.0}
            },
            "special_materials": {
                "frosted": {"kind": "emissive", "color": [0.9, 0.92, 0.95, 1], "emission": [0.95, 0.93, 0.88, 1], "strength": 3.2,
                            "roughness": 0.2, "game_boost": 1.25},
                "lamp": {"kind": "emissive", "color": [1, 0.96, 0.88, 1], "emission": [1.0, 0.9, 0.72, 1], "strength": 14.0, "game_boost": 2.0}
            },
            "shading": {"coping": {"metallic": 0.85}, "rail": {"metallic": 0.45}, "steel": {"metallic": 0.35},
                        "steel_paint": {"metallic": 0.3}, "grille": {"metallic": 0.4}, "plywood": {"normal_depth": 0.6},
                        "brick": {"normal_depth": 1.4}},
            "lights": {
                "sun": {"dir": [0.7, 0.35, -0.6], "color": [1.0, 0.86, 0.68], "strength": 4.0, "angle": 1.2},
                "sky": {"color": [0.6, 0.7, 0.88], "strength": 1.0},
                "lm_scale": 6.0,
                "areas": [
                    {"name": "EastWin", "at": [15.3, -12.0, 4.5], "size": [4.0, 2.0], "energy": 700, "color": [1.0, 0.9, 0.78], "rot": [0, 90, 0]},
                    {"name": "EastWin", "at": [15.3, 12.0, 4.5], "size": [4.0, 2.0], "energy": 700, "color": [1.0, 0.9, 0.78], "rot": [0, 90, 0]},
                    {"name": "RoofFill", "at": [-7.0, -9.0, 6.8], "size": [8.0, 8.0], "energy": 2400, "color": [0.9, 0.92, 1.0]},
                    {"name": "RoofFill", "at": [7.0, -9.0, 6.8], "size": [8.0, 8.0], "energy": 2400, "color": [0.9, 0.92, 1.0]},
                    {"name": "RoofFill", "at": [-7.0, 9.0, 6.8], "size": [8.0, 8.0], "energy": 2400, "color": [0.9, 0.92, 1.0]},
                    {"name": "RoofFill", "at": [7.0, 9.0, 6.8], "size": [8.0, 8.0], "energy": 2400, "color": [0.9, 0.92, 1.0]}
                ],
                "points": [{"name": "StoreBulb", "at": [19.0, 0.0, 3.1], "energy": 140, "color": [1.0, 0.8, 0.55], "radius": 0.06}]
            },
            "lightmap": {"margin": 0.0015, "weights": {"roof": 0.3, "coping": 2.0, "rail": 2.0, "graffiti": 0.35, "brick": 0.6},
                         "breakable_weight": 0.8},
            "graffiti": {
                "atlas": 2048,
                "cells": {"name_board": [0, 0, 2048, 512], "piece": [0, 512, 1024, 512], "throwup": [1024, 512, 1024, 512],
                          "nodiving": [0, 1536, 512, 384], "tag_a": [1024, 1536, 512, 256], "tag_b": [1536, 1536, 512, 256]},
                "pieces": {
                    "name_board": {"style": "sign", "text": name.upper(), "color": [0.95, 0.92, 0.82], "panel": [0.1, 0.12, 0.16],
                                   "border": [0.9, 0.6, 0.15], "aspect": 4.0, "size": 0.8, "spacing": 1.1, "wear": 0.4, "seed": 1, "margin": 1.02},
                    "piece": {"style": "piece", "text": "SKATE", "fill": [[1.0, 0.8, 0.1], [0.95, 0.3, 0.05]], "inner": [1, 1, 1],
                              "outline": [0.02, 0.02, 0.05], "block": [0.1, 0.4, 0.95], "seed": 2},
                    "throwup": {"style": "throwup", "text": "RAMP", "fill": [[0.97, 0.97, 0.98], [0.6, 0.62, 0.68]],
                                "outline": [0.02, 0.02, 0.02], "cloud": [0.2, 0.8, 0.3], "seed": 3},
                    "nodiving": {"style": "sign", "text": "NO\nSKATING", "color": [0.78, 0.06, 0.05], "panel": [0.95, 0.94, 0.9],
                                 "border": [0.78, 0.06, 0.05], "aspect": 1.33, "size": 0.8, "spacing": 1.05, "wear": 0.25, "seed": 4, "margin": 1.0},
                    "tag_a": {"style": "tag", "text": lid[:6], "color": [0.95, 0.2, 0.55], "seed": 5},
                    "tag_b": {"style": "tag", "text": "locals", "color": [0.1, 0.1, 0.1], "seed": 6}
                },
                "placements": [
                    ["name_board", [0.0, 19.985, 5.4], [0, -1, 0], 8.0, 0.0],
                    ["piece", [-14.985, 6.0, 3.6], [1, 0, 0], 6.0, 0.0],
                    ["throwup", [-14.985, -10.0, 3.2], [1, 0, 0], 4.5, 2.0],
                    ["tag_a", [14.985, 8.0, 1.4], [-1, 0, 0], 1.5, -3.0],
                    ["tag_b", [-6.0, -19.985, 1.5], [0, 1, 0], 1.6, 4.0]
                ]
            },
            "features": [
                {"type": "hall", "rect": [-15, -20, 15, 20], "height": 7.0,
                 "bands": [[0.0, 2.4, "concrete"], [2.4, 7.0, "brick"]],
                 "openings": {"east": [{"kind": "window", "y": [-14.0, -10.0], "z": [3.5, 5.5]},
                                       {"kind": "window", "y": [10.0, 14.0], "z": [3.5, 5.5]},
                                       {"kind": "door", "y": [-1.5, 1.5], "z": [0.0, 2.8]}]},
                 "roof": {"type": "flat", "mat": "roof"},
                 "floor": {"mat": "concrete_floor", "col": "concrete", "cell": [8.0, 6.0]}},
                {"type": "room", "name": "storeroom", "label": "Storeroom", "rect": [15, -4, 22, 4], "height": 3.4,
                 "door": {"side": "west", "y": [-1.5, 1.5], "z": [0.0, 2.8]}, "bands": [[0.0, 3.4, "brick"]],
                 "floor_mat": "concrete_floor", "ceiling_mat": "concrete"},
                {"type": "grille", "name": "grille", "group": "grille", "label": "Storeroom grille", "plane": "x", "at": 15.0,
                 "span": [-1.5, 1.5], "z": [0.0, 2.8], "spacing": 0.16, "points": 250},
                {"type": "quarterpipe", "at": [0.0, -15.0, 0.0], "facing": 180, "width": 12.0, "radius": 2.4, "height": 2.4, "deck": 1.6,
                 "coping": "dropin_coping"},
                {"type": "halfpipe", "center": [0.0, 12.0, 0.0], "axis": 0, "width": 8.0, "radius": 2.8, "height": 3.2, "deck": 1.5,
                 "flat": 4.0, "coping_a": "hp_coping_w", "coping_b": "hp_coping_e"},
                {"type": "kicker", "at": [8.0, -8.0, 0.0], "facing": 0, "width": 2.4, "length": 1.8, "height": 0.6},
                {"type": "funbox", "center": [-7.0, -2.0], "top": [3.0, 2.0], "height": 0.7, "bank": 1.8, "edge_rails": "funbox_edge",
                 "rail": {"a": [-8.2, -2.0, 0.7], "b": [-5.8, -2.0, 0.7], "height": 0.4, "name": "funbox_rail"}},
                {"type": "rail", "name": "flat_rail", "points": [[4.0, 2.0, 0.0], [12.0, 2.0, 0.0]], "height": 0.45},
                {"type": "ledge", "name": "west_ledge", "a": [-13.0, -12.0, 0.0], "b": [-13.0, 2.0, 0.0], "width": 0.6, "height": 0.5},
                {"type": "lamps", "at": [[-7.0, -9.0], [7.0, -9.0], [-7.0, 9.0], [7.0, 9.0]], "z": 5.4, "ceiling": 7.0,
                 "light": {"energy": 180, "color": [1.0, 0.9, 0.75]}},
                {"type": "sign", "group": "signs", "cell": "nodiving", "at": [-10.0, 6.0, 0.0], "facing": -90},
                {"type": "sign", "group": "signs", "cell": "nodiving", "at": [11.0, -14.0, 0.0], "facing": 0},
                {"type": "sign", "group": "signs", "cell": "nodiving", "at": [-3.0, -12.0, 0.0], "facing": 0}
            ],
            "spawn": {"at": [0.0, -18.6, 2.4], "dir": [0, 1, 0]},
            "respawns": [[0.0, 0.0, 0.0], [-8.0, 8.0, 0.0], [8.0, -12.0, 0.0]],
            "hall_centre": [0.0, 0.0, 3.0],
            "letters": [
                {"letter": "S", "at": [5.0, 12.0, 4.4]},
                {"letter": "K", "at": [8.0, -4.8, 1.6]},
                {"letter": "A", "at": [-7.0, -2.0, 1.9]},
                {"letter": "T", "at": [-5.0, 12.0, 4.4]},
                {"letter": "E", "at": [12.8, 2.0, 1.3]}
            ],
            "tape": {"at": [19.5, 0.0, 1.2]},
            "gaps": [
                {"id": "kicker_gap", "name": "Kicker Gap", "points": 250,
                 "from": [[7.0, -6.6, 0.2], [9.0, -5.8, 1.2]], "to": [[5.5, -3.5, -0.1], [10.5, 1.5, 0.3]]}
            ],
            "render": {"target": [2.0, 0.0, 0.0], "dist": 56.0, "elev": 42.0, "az": -35.0, "lens": 30, "cut_z": 6.9, "samples": 160}
        }
    }


ROUTE = '''extends RefCounted
## The two-minute autopilot route through {name} (a starter: drop in, then halfpipe airs to the
## buzzer). Godot coordinates: the level definition's Blender (x, y, z) is Godot (x, z, -y).
## Extend it until tests/test_level.gd's "every pickup is reachable" and "every goal" checks
## pass: R.go(point, note, opts) steers there, R.until(cond, note, opts) holds inputs until
## cond, R.tap(actions, note, opts) presses buttons; see scripts/game/autopilot_route.gd
## (the Warehouse) and levels/baths/autopilot_route.gd for complete routes.

const R := preload("res://scripts/game/autopilot_route.gd")


static func route() -> Array:
	var r: Array = []
	# drop in off the south deck, slow down and roll in through the halfpipe's open end
	r.append(R.go(Vector3(0.0, 0.0, 5.0), "drop in", {{"radius": 1.5, "timeout": 6.0}}))
	r.append(R.go(Vector3(0.0, 0.0, -5.0), "to the halfpipe mouth", {{"radius": 1.2, "max_speed": 5.0, "timeout": 6.0}}))
	r.append(R.go(Vector3(-1.0, 0.0, -12.0), "into the halfpipe", {{"radius": 1.2, "max_speed": 5.0, "timeout": 6.0}}))
	var kick_indy := [["flip", Vector2.ZERO, 0.06, 0.06], ["grab", Vector2(1, 0), 0.5, 0.05], ["grab", Vector2.ZERO, 0.55, 0.3]]
	var shove_nose := [["flip", Vector2(0, -1), 0.06, 0.05], ["grab", Vector2(0, 1), 0.5, 0.05], ["grab", Vector2.ZERO, 0.55, 0.3]]
	r.append({{"do": "halfpipe", "note": "halfpipe airs to the buzzer", "z": -12.0, "timeout": 110.0, "count": 60,
			"airs": [kick_indy, shove_nose], "fallback": shove_nose}})
	return r
'''


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("id", help="level id: lower case letters, digits, _ (the folder and asset names)")
    ap.add_argument("name", help='display name, e.g. "Harbour Yard"')
    ap.add_argument("--blurb", default="", help="one or two sentences for the level select")
    ap.add_argument("--force", action="store_true", help="overwrite an existing levels/<id>/")
    a = ap.parse_args()
    lid = a.id
    if not re.fullmatch(r"[a-z][a-z0-9_]{1,23}", lid):
        sys.exit("scaffold: the id must be 2-24 characters of a-z, 0-9, _ (starting with a letter)")
    d = os.path.join(LEVELS, lid)
    if os.path.exists(os.path.join(d, "level.json")) and not a.force:
        sys.exit(f"scaffold: levels/{lid}/level.json exists (use --force to overwrite)")
    os.makedirs(d, exist_ok=True)
    blurb = a.blurb or f"{a.name}: a new park. (Write one or two sentences for the level select.)"
    with open(os.path.join(d, "level.json"), "w") as f:
        json.dump(starter(lid, a.name, blurb), f, indent=1)
        f.write("\n")
    with open(os.path.join(d, "autopilot_route.gd"), "w") as f:
        f.write(ROUTE.format(name=a.name))
    reg_p = os.path.join(LEVELS, "registry.json")
    reg = json.load(open(reg_p))
    if lid not in reg["levels"]:
        reg["levels"].append(lid)
        with open(reg_p, "w") as f:
            f.write('{\n "default": %s,\n "levels": %s\n}\n' % (json.dumps(reg["default"]), json.dumps(reg["levels"])))
    print(f"""scaffold: created levels/{lid}/level.json and levels/{lid}/autopilot_route.gd; '{lid}' added to levels/registry.json
next (docs/LEVELS.md has the whole checklist):
  1. build     ~/.local/bin/blender --background --python blender/build_all.py -- --only {lid}   (-- --fast --only {lid}: a quick look)
  2. import    godot --headless --path . --import && python3 tools/level_imports.py {lid} && godot --headless --path . --import
  3. test      godot --headless --path . --fixed-fps 60 -s tests/test_level.gd -- --level={lid}
  4. play      godot --path . -- --level={lid}        (or Tab on the start screen)
then design: edit levels/{lid}/level.json (features, goals, pickups, lights), rebuild, and extend
levels/{lid}/autopilot_route.gd until the suite passes.""")


if __name__ == "__main__":
    main()
