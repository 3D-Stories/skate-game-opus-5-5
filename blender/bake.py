"""Lighting for the Warehouse and the Cycles lightmap bake.

Lights: a warm low sun through the skylights and the east windows, cool sky light,
32 hanging fluorescent fixtures (area lights), glow from the skylight glazing and a lamp
in the secret room.

The game renders the SUN's direct light in real time (with shadows through the skylights),
so the lightmap holds everything else:
    pass A: all lights except the sun, direct + indirect diffuse
    pass B: the sun alone, indirect (bounce) diffuse only
    lightmap = A + B, stored as (L / LM_SCALE) ** (1/2.2) in an 8-bit PNG.
The same sun direction and colour are written to park_data.json for Godot.
"""
import math
import os

import bpy
import numpy as np
from mathutils import Vector

from lib import common as C

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


def _set_visible(objs, on):
    for o in objs:
        o.hide_render = not on


def bake_lightmap(lm_objs, visual, P, size=None):
    size = size or (1024 if C.FAST else 2048)
    samples = 48 if C.FAST else 200
    scn = C.cycles(samples)
    scn.cycles.samples = samples
    scn.cycles.max_bounces = 6
    scn.cycles.diffuse_bounces = 4
    lights = setup_lights(P)
    # the yard's glow is modelled by the window area lights; keep it out of the bake
    hide = [o for o in bpy.data.objects if o.name.startswith(("Window_", "COL_", "Park_yard"))]
    _set_visible(hide, False)
    img = C.float_image("park_lightmap_raw", size, alpha=False)
    # pass A: everything but the sun
    _set_visible(lights["sun"], False)
    A = _bake_diffuse(lm_objs, img, {'DIRECT', 'INDIRECT'}, samples)
    # pass B: sun bounce only
    _set_visible(lights["sun"], True)
    _set_visible(lights["other"], False)
    bg = scn.world.node_tree.nodes.get("Background")
    old = bg.inputs[1].default_value
    bg.inputs[1].default_value = 0.0
    Bm = _bake_diffuse(lm_objs, img, {'INDIRECT'}, samples)
    bg.inputs[1].default_value = old
    _set_visible(lights["other"], True)
    L = A + Bm
    L = denoise(L)
    enc = np.power(np.clip(L / LM_SCALE, 0, 1), 1 / 2.2)
    out = C.save_png(enc, "park_lightmap", 'Non-Color', folder=C.ASSETS)
    # the Blender materials show the bake too (for the park turntable render)
    P.data["lighting"] = dict(sun_dir=[round(v, 4) for v in (SUN_DIR.x, SUN_DIR.z, -SUN_DIR.y)],
                              sun_color=list(SUN_COLOR), sun_strength=SUN_STRENGTH, lightmap_scale=LM_SCALE,
                              sky_color=list(SKY_COLOR))
    import json
    with open(os.path.join(C.ASSETS, "park_data.json"), "w") as f:
        json.dump(P.data, f, indent=1)
    _set_visible([o for o in hide if not o.name.startswith("COL_")], True)
    return out


def _bake_diffuse(objs, img, passes, samples):
    scn = bpy.context.scene
    scn.render.bake.margin = 6
    scn.render.bake.margin_type = 'EXTEND'
    scn.render.bake.use_clear = True
    added = []
    mats = set()
    for o in objs:
        o.data.uv_layers.active = o.data.uv_layers["Lightmap"]
        for s in o.material_slots:
            if s.material and s.material not in mats:
                mats.add(s.material)
                n = s.material.node_tree.nodes.new('ShaderNodeTexImage')
                n.image = img
                s.material.node_tree.nodes.active = n
                added.append((s.material, n))
    # the lightmap stores irradiance, which does not depend on the surface: bake every
    # material as a dielectric (a fully metallic coping has no diffuse lobe and would bake
    # black), then restore the real metallic values that are exported for the game
    metal = []
    for m in mats:
        pn = next((n for n in m.node_tree.nodes if n.type == 'BSDF_PRINCIPLED'), None)
        if pn is not None and not pn.inputs['Metallic'].is_linked:
            metal.append((pn, pn.inputs['Metallic'].default_value))
            pn.inputs['Metallic'].default_value = 0.0
    C.deselect_all()
    for o in objs:
        o.select_set(True)
    bpy.context.view_layer.objects.active = objs[0]
    bpy.ops.object.bake(type='DIFFUSE', pass_filter=passes, margin=6, use_clear=True)
    arr = C.image_array(img)[..., :3].copy()
    for pn, v in metal:
        pn.inputs['Metallic'].default_value = v
    for m, n in added:
        m.node_tree.nodes.remove(n)
    for o in objs:
        o.data.uv_layers.active = o.data.uv_layers[0]
    return arr


def denoise(L):
    """Light edge-aware smoothing: blur, but keep strong edges (shadow boundaries)."""
    lum = L.mean(-1)
    b = np.stack([C.blur(L[..., k], 1) for k in range(3)], -1)
    bl = b.mean(-1)
    diff = np.abs(lum - bl) / (bl + 0.05)
    w = np.clip(1 - diff * 3, 0, 1)[..., None]
    return L * (1 - w) + b * w
