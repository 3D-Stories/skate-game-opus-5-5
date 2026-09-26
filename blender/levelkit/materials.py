"""Level kit, materials: seamless PBR textures from the imagegen photo sources, and the
special (emissive / glass) materials every level uses.

A material table maps a name to how its textures are made from a photo in
blender/textures_src:

    name: (source photo, tile metres, tint (r, g, b), roughness range, normal strength, metallic)

or, in a level definition (JSON), the same as a dict:

    {"src": "pool_tile", "tile": 1.2, "tint": [1, 1, 1], "rough": [0.3, 0.6], "normal": 2.0,
     "metallic": 0.0, "flat": [0.1, 0.3, 0.6], "flat_mix": [0.75, 0.35], "rough_invert": false}

"flat" paints the surface one colour, modulated by the photo's luminance (painted lines,
coping); "rough_invert" makes darker (worn) areas rougher instead of smoother. Albedo keeps
the roughness in its alpha channel; the normal map comes from the photo's high-passed
luminance. Every level's textures are written as <prefix><name>_albedo / _normal.
"""
import numpy as np

from lib import common as C


def entry(v):
    """A table row as a dict (accepts the Warehouse's tuples and the JSON dicts)."""
    if isinstance(v, dict):
        return dict(src=v["src"], tile=float(v.get("tile", 2.0)), tint=tuple(v.get("tint", (1.0, 1.0, 1.0))),
                    rough=tuple(v.get("rough", (0.5, 0.8))), normal=float(v.get("normal", 2.0)),
                    metallic=float(v.get("metallic", 0.0)), flat=v.get("flat"), flat_mix=tuple(v.get("flat_mix", (0.75, 0.35))),
                    rough_invert=bool(v.get("rough_invert", False)))
    src, tile, tint, rr, ns, metal = v
    return dict(src=src, tile=tile, tint=tint, rough=rr, normal=ns, metallic=metal, flat=None, flat_mix=None,
                rough_invert=False)


def build_textures(table, prefix, albedo_fns=None, rough_invert=(), size=1024):
    """Seamless albedo (roughness packed in alpha) + normal maps for every material in
    table. albedo_fns: name -> f(photo, luminance) for a hand-made albedo; rough_invert:
    names whose roughness follows the photo's darkness. Returns
    name -> (albedo image, normal image, tile metres, metallic, mean roughness)."""
    albedo_fns = albedo_fns or {}
    cache = {}
    imgs = {}
    for name, raw in table.items():
        e = entry(raw)
        src, tint, rr, ns = e["src"], e["tint"], e["rough"], e["normal"]
        if src not in cache:
            a = C.make_seamless(C.src_array(src, size))
            cache[src] = a
        a = cache[src]
        lum = C.luminance(a)
        alb = np.clip(a * np.array(tint), 0, 1)
        if name in albedo_fns:
            alb = albedo_fns[name](a, lum)
        elif e["flat"] is not None:
            k0, k1 = e["flat_mix"]
            alb = np.clip(np.array(e["flat"]) * (k0 + k1 * lum[..., None]), 0, 1)
        # roughness: brighter/smoother polish where the photo is darker (worn tracks)
        ln = (lum - lum.min()) / max(1e-6, lum.max() - lum.min())
        inv = name in rough_invert or e["rough_invert"]
        rough = rr[0] + (rr[1] - rr[0]) * (1 - ln if inv else ln)
        height = C.highpass(lum, 8)
        height = height / (height.std() + 1e-6)
        nrm = C.height_to_normal(height, ns * 0.35)
        rgba = np.concatenate([alb, rough[..., None]], -1)
        imgs[name] = (C.save_png(rgba, prefix + name + "_albedo"),
                      C.save_png(nrm, prefix + name + "_normal", 'Non-Color'), e["tile"], e["metallic"], float(np.mean(rr)))
    return imgs


def make_materials(imgs, prefix):
    """One Principled material per built texture set, named <prefix><name>."""
    mats = {}
    for name, (alb, nrm, tile, metal, rough) in imgs.items():
        mats[name] = C.pbr_material(prefix + name, base=alb, normal=nrm, roughness=rough, metallic=metal, normal_strength=1.0)
    return mats


def emissive(name, color=(1, 1, 1, 1), emission=(1, 1, 1, 1), strength=10.0, roughness=0.3):
    """A light-emitting surface (lamps, skylight glazing, signs). The game draws these
    unshaded and brighter, without shadows; the bake leaves the light to real lights."""
    kw = dict(base_color=tuple(color), emission=tuple(emission), emission_strength=strength)
    if roughness is not None:
        kw["roughness"] = roughness
    return C.pbr_material(name, **kw)


def glass(name, color=(0.6, 0.7, 0.72, 1), alpha=0.35, roughness=0.05):
    m = C.pbr_material(name, base_color=tuple(color), roughness=roughness, metallic=0.0)
    C.principled(m).inputs['Alpha'].default_value = alpha
    return m


def specials(spec, prefix):
    """Special materials from a level definition:
        {"lamp": {"kind": "emissive", "color": [...], "emission": [...], "strength": 25}, ...}"""
    out = {}
    for name, s in spec.items():
        if s.get("kind", "emissive") == "glass":
            out[name] = glass(prefix + name, tuple(s.get("color", (0.6, 0.7, 0.72, 1))), s.get("alpha", 0.35))
        else:
            e = tuple(s.get("emission", (1, 1, 1, 1)))
            out[name] = emissive(prefix + name, tuple(s.get("color", e)), e, s.get("strength", 10.0), s.get("roughness", 0.3))
    return out
