"""Level kit, lighting: the lights a level is baked with, and the Cycles lightmap bake.

The game renders the SUN's direct light in real time (with shadows), so the lightmap holds
everything else:
    pass A: all lights except the sun, direct + indirect diffuse
    pass B: the sun alone, indirect (bounce) diffuse only
    lightmap = A + B, stored as (L / lm_scale) ** (1/2.2) in an 8-bit PNG.
The sun direction and colour go into the level's data JSON for Godot (lighting_data()).

Lights in a level definition ("lights"):
    {"sun": {"dir": [x, y, z], "color": [...], "strength": 5.0, "angle": 1.2},
     "sky": {"color": [...], "strength": 1.2},
     "areas": [{"name": "Lamp", "at": [x, y, z], "size": [sx, sy], "energy": 200, "color": [...],
                "rot": [rx, ry, rz] (deg, optional), "shape": "RECTANGLE" | "DISK"}, ...],
     "points": [{"name": "Bulb", "at": [...], "energy": 80, "color": [...], "radius": 0.05}, ...],
     "lm_scale": 6.0, "size": 2048, "samples": 200}
"""
import math

import bpy
import numpy as np
from mathutils import Vector

from lib import common as C


def sun(coll, direction, color, strength, angle_deg=1.2, name="Sun"):
    sd = bpy.data.lights.new(name, 'SUN')
    sd.energy = strength
    sd.color = color
    sd.angle = math.radians(angle_deg)
    so = bpy.data.objects.new(name, sd)
    C.link(so, coll)
    so.rotation_euler = Vector(direction).normalized().to_track_quat('-Z', 'Y').to_euler()
    return so


def area(coll, name, loc, size, size_y=None, energy=100.0, color=(1, 1, 1), rot=None, shape=None):
    ld = bpy.data.lights.new(name, 'AREA')
    ld.shape = shape or ('RECTANGLE' if size_y else 'SQUARE')
    ld.size = size
    if size_y:
        ld.size_y = size_y
    ld.energy = energy
    ld.color = color
    lo = bpy.data.objects.new(name, ld)
    C.link(lo, coll)
    lo.location = loc
    if rot:
        lo.rotation_euler = tuple(math.radians(v) for v in rot)
    return lo


def point(coll, name, loc, energy=50.0, color=(1, 1, 1), radius=0.05):
    ld = bpy.data.lights.new(name, 'POINT')
    ld.energy = energy
    ld.color = color
    ld.shadow_soft_size = radius
    lo = bpy.data.objects.new(name, ld)
    C.link(lo, coll)
    lo.location = loc
    return lo


def world(color, strength):
    scn = bpy.context.scene
    if scn.world is None:
        scn.world = bpy.data.worlds.new("World")
    w = scn.world
    try:
        w.use_nodes = True
    except Exception:
        pass
    bg = w.node_tree.nodes.get("Background")
    bg.inputs[0].default_value = (*color, 1)
    bg.inputs[1].default_value = strength
    return w


def lights_from_spec(spec, coll_name="LevelLights"):
    """Creates the lights of a level definition. Returns {"sun": [...], "other": [...]}."""
    coll = C.collection(coll_name)
    out = {"sun": [], "other": []}
    s = spec["sun"]
    out["sun"].append(sun(coll, s["dir"], tuple(s.get("color", (1, 1, 1))), s.get("strength", 5.0), s.get("angle", 1.2)))
    for a in spec.get("areas", []):
        sz = a.get("size", [1.0])
        sz = sz if isinstance(sz, list) else [sz]
        out["other"].append(area(coll, a.get("name", "Area"), tuple(a["at"]), sz[0], sz[1] if len(sz) > 1 else None,
                                 a.get("energy", 100.0), tuple(a.get("color", (1, 1, 1))), a.get("rot"), a.get("shape")))
    for p in spec.get("points", []):
        out["other"].append(point(coll, p.get("name", "Point"), tuple(p["at"]), p.get("energy", 50.0),
                                  tuple(p.get("color", (1, 1, 1))), p.get("radius", 0.05)))
    sky = spec.get("sky", {"color": (0.55, 0.66, 0.85), "strength": 1.0})
    world(tuple(sky["color"]), sky.get("strength", 1.0))
    return out


def lighting_data(sun_dir, sun_color, sun_strength, lm_scale, sky_color):
    """The "lighting" block of a level's data JSON (Godot axes)."""
    d = Vector(sun_dir)
    if abs(d.length - 1.0) > 1e-6:
        d = d.normalized()
    return dict(sun_dir=[round(v, 4) for v in (d.x, d.z, -d.y)], sun_color=list(sun_color), sun_strength=sun_strength,
                lightmap_scale=lm_scale, sky_color=list(sky_color))


def _set_visible(objs, on):
    for o in objs:
        o.hide_render = not on


def bake_lightmap(lm_objs, lights, name, folder, hide_prefixes=(), lm_scale=6.0, size=None, samples=None):
    """Two-pass diffuse bake of every object in lm_objs into their 'Lightmap' UV set; writes
    <folder>/<name>.png. Objects whose names start with hide_prefixes are left out."""
    size = size or (1024 if C.FAST else 2048)
    samples = samples or (48 if C.FAST else 200)
    if C.FAST:
        samples = min(samples, 48)
    scn = C.cycles(samples)
    scn.cycles.samples = samples
    scn.cycles.max_bounces = 6
    scn.cycles.diffuse_bounces = 4
    hide = [o for o in bpy.data.objects if o.name.startswith(tuple(hide_prefixes))] if hide_prefixes else []
    _set_visible(hide, False)
    img = C.float_image(name + "_raw", size, alpha=False)
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
    enc = np.power(np.clip(L / lm_scale, 0, 1), 1 / 2.2)
    out = C.save_png(enc, name, 'Non-Color', folder=folder)
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
