"""Lighting for the Warehouse and the Cycles lightmap bake.

Lights: a warm low sun through the skylights and the east windows, cool sky light,
32 hanging fluorescent fixtures (area lights), glow from the skylight glazing and a lamp
in the secret room.

The game renders the SUN's direct light in real time (with shadows through the skylights),
so the lightmap holds everything else:
    pass A: all lights except the sun, direct + indirect diffuse
    pass B: the sun alone, indirect (bounce) diffuse only
    lightmap = A + B, stored as (L / LM_SCALE) ** (1/2.2) in an 8-bit PNG.
The same sun direction and colour are written to park_data.json for Godot. The bake itself
is the level kit's (levelkit/lighting.py); this module holds the Warehouse's lights.
"""
import math
import os

import bpy
import numpy as np
from mathutils import Vector

from lib import common as C
from levelkit import lighting as KL

SUN_DIR = Vector((0.42, 0.52, -0.74)).normalized()   # direction the light travels
SUN_COLOR = (1.0, 0.86, 0.68)
SUN_STRENGTH = 5.0
SKY_COLOR = (0.55, 0.66, 0.85)
LM_SCALE = 6.0


def setup_lights(P):
    scn = bpy.context.scene
    coll = C.collection("ParkLights")
    lights = {"sun": [], "other": []}
    sd = bpy.data.lights.new("Sun", 'SUN')
    sd.energy = SUN_STRENGTH
    sd.color = SUN_COLOR
    sd.angle = math.radians(1.2)
    so = bpy.data.objects.new("Sun", sd)
    C.link(so, coll)
    so.rotation_euler = SUN_DIR.to_track_quat('-Z', 'Y').to_euler()
    lights["sun"].append(so)
    h = 11.5
    # hanging fluorescent fixtures
    import park
    for (xx, yy) in park.lamp_positions():
        ld = bpy.data.lights.new("Tube", 'AREA')
        ld.shape = 'RECTANGLE'
        ld.size, ld.size_y = 2.4, 0.15
        ld.energy = 220.0
        ld.color = (1.0, 0.96, 0.88)
        lo = bpy.data.objects.new("Tube", ld)
        C.link(lo, coll)
        lo.location = (xx, yy, 8.12)
        lights["other"].append(lo)
    # sky light pouring through each skylight
    for (a, b, c, d) in P.skylight_rects():
        ld = bpy.data.lights.new("SkyPanel", 'AREA')
        ld.shape = 'RECTANGLE'
        ld.size, ld.size_y = b - a, d - c
        ld.energy = 1800.0
        ld.color = SKY_COLOR
        lo = bpy.data.objects.new("SkyPanel", ld)
        C.link(lo, coll)
        lo.location = ((a + b) / 2, (c + d) / 2, h - 0.05)
        lights["other"].append(lo)
    # daylight through the east windows (soft, from outside)
    for w in P.windows:
        ld = bpy.data.lights.new("WinPanel", 'AREA')
        ld.shape = 'RECTANGLE'
        ld.size, ld.size_y = w["y1"] - w["y0"], w["z1"] - w["z0"]
        ld.energy = 900.0
        ld.color = (0.8, 0.86, 1.0)
        lo = bpy.data.objects.new("WinPanel", ld)
        C.link(lo, coll)
        lo.location = (w["x"] + 0.3, (w["y0"] + w["y1"]) / 2, (w["z0"] + w["z1"]) / 2)
        lo.rotation_euler = (0, math.radians(90), 0)
        lights["other"].append(lo)
    # secret room lamp
    ld = bpy.data.lights.new("SecretLamp", 'AREA')
    ld.size = 1.5
    ld.energy = 350.0
    ld.color = (1.0, 0.75, 0.5)
    lo = bpy.data.objects.new("SecretLamp", ld)
    C.link(lo, coll)
    lo.location = (-24.8, 37.0, 4.9)
    lights["other"].append(lo)
    # world: overcast sky seen through skylights/windows
    if scn.world is None:
        scn.world = bpy.data.worlds.new("World")
    w = scn.world
    try:
        w.use_nodes = True
    except Exception:
        pass
    bg = w.node_tree.nodes.get("Background")
    bg.inputs[0].default_value = (*SKY_COLOR, 1)
    bg.inputs[1].default_value = 1.2
    return lights


def bake_lightmap(lm_objs, visual, P, size=None):
    """The Warehouse's lights, baked by the level kit (levelkit/lighting.py)."""
    lights = setup_lights(P)
    # the yard's glow is modelled by the window area lights; keep it out of the bake
    out = KL.bake_lightmap(lm_objs, lights, "park_lightmap", C.ASSETS, hide_prefixes=("Window_", "COL_", "Park_yard"),
                           lm_scale=LM_SCALE, size=size)
    # the Blender materials show the bake too (for the park turntable render)
    P.data["lighting"] = KL.lighting_data(SUN_DIR, SUN_COLOR, SUN_STRENGTH, LM_SCALE, SKY_COLOR)
    import json
    with open(os.path.join(C.ASSETS, "park_data.json"), "w") as f:
        json.dump(P.data, f, indent=1)
    return out
