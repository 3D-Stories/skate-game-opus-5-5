"""Skater stage 2: eyes, eyelashes, eyebrows, teeth and tongue.

The MakeHuman helper geometry gives the placement (eye sockets, lash strips, teeth);
the eyeballs, corneas, lash/brow cards and every texture here are built by this script.
The iris colour comes from the imagegen iris photo, remapped radially onto a sclera that
is painted procedurally (limbal ring, veins, wet edge).
"""
import math

import bpy
import bmesh
import numpy as np
from mathutils import Vector, Matrix
from mathutils.bvhtree import BVHTree

from lib import common as C


def _world_verts(obj):
    return np.array([obj.matrix_world @ v.co for v in obj.data.vertices])


def weight_all(obj, bone, rig):
    for g in list(obj.vertex_groups):
        obj.vertex_groups.remove(g)
    g = obj.vertex_groups.new(name=bone)
    g.add(list(range(len(obj.data.vertices))), 1.0, 'REPLACE')
    obj.parent = rig
    mod = obj.modifiers.new("Armature", 'ARMATURE')
    mod.object = rig


# ------------------------------------------------------------------ eye texture

def eye_texture(size=1024, iris_frac=0.54, pupil_frac=0.30, tint=(1.2, 0.86, 0.6), gain=0.62, name="eye_albedo"):
    """Front-projected eyeball texture: rho = distance from the corneal axis / eye radius."""
    iris = C.src_array("iris", 1024)
    h = size
    y, x = np.mgrid[0:h, 0:h].astype(np.float32)
    u = (x + 0.5) / h * 2 - 1
    v = (y + 0.5) / h * 2 - 1
    rho = np.sqrt(u * u + v * v)
    ang = np.arctan2(v, u)
    # iris photo: pupil ~0.17 of the image half-width, iris edge ~0.96
    t = np.clip(rho / iris_frac, 0, 1)
    src_pupil, src_edge = 0.20, 0.95
    # remap so our pupil size is pupil_frac of the iris radius
    src_r = np.where(t < pupil_frac, t / pupil_frac * src_pupil,
                     src_pupil + (t - pupil_frac) / (1 - pupil_frac) * (src_edge - src_pupil))
    sx = (0.5 + 0.5 * src_r * np.cos(ang)) * 1023
    sy = (0.5 + 0.5 * src_r * np.sin(ang)) * 1023
    iris_col = iris[sy.astype(int).clip(0, 1023), sx.astype(int).clip(0, 1023)]
    # a natural medium brown (the source photo is a light hazel that reads orange under a
    # warm key light), matching the brown eyes of the face photo
    lum = (iris_col * np.array([0.2126, 0.7152, 0.0722])).sum(-1, keepdims=True)
    iris_col = (iris_col * 0.45 + lum * np.array(tint) * 0.55) * gain
    pupil = np.clip((pupil_frac - t) / 0.02, 0, 1)[..., None]
    iris_col = iris_col * (1 - pupil) + np.array([0.01, 0.01, 0.012]) * pupil
    # sclera
    n1 = C.value_noise(h, 6, 11, 4)
    n2 = C.value_noise(h, 24, 12, 3)
    sclera = np.stack([0.80 + 0.05 * n1, 0.76 + 0.04 * n1, 0.72 + 0.03 * n1], -1)
    # veins: thin ridges of noise, stronger towards the corners of the eye
    ridge = 1 - np.abs(C.value_noise(h, 10, 13, 5) * 2 - 1)
    veins = np.clip((ridge - 0.9) / 0.1, 0, 1) * np.clip((rho - 0.55) / 0.4, 0, 1) * (0.4 + 0.6 * np.abs(np.cos(ang)))
    sclera = sclera * (1 - veins[..., None] * 0.5) + veins[..., None] * np.array([0.55, 0.12, 0.10]) * 0.5
    pink = np.clip((rho - 0.75) / 0.25, 0, 1)[..., None] * (0.5 + 0.5 * np.abs(np.cos(ang)))[..., None]
    sclera = sclera * (1 - 0.25 * pink) + np.array([0.75, 0.45, 0.42]) * 0.25 * pink
    # limbal ring and blend
    edge = np.clip((rho - iris_frac) / 0.035 + 0.5, 0, 1)[..., None]
    limbal = np.exp(-((rho - iris_frac) / 0.03) ** 2)[..., None]
    col = iris_col * (1 - edge) + sclera * edge
    col = col * (1 - 0.65 * limbal)
    col *= (0.96 + 0.08 * n2[..., None])
    return C.save_png(np.clip(col, 0, 1), name)


def gaze_matrix(gaze):
    """Rotation taking the eye's rest view axis (-Y) onto `gaze`."""
    if gaze is None:
        return Matrix.Identity(4)
    return Vector((0, -1, 0)).rotation_difference(Vector(gaze).normalized()).to_matrix().to_4x4()


def make_eyeball(name, center, radius, coll, gaze=None):
    """UV sphere with its pole on the view axis (-Y, turned to `gaze`); iris slightly flattened."""
    bm = bmesh.new()
    bmesh.ops.create_uvsphere(bm, u_segments=48, v_segments=32, radius=radius)
    rot = Matrix.Rotation(math.radians(90), 4, 'X')  # pole Z -> -Y
    bmesh.ops.transform(bm, matrix=rot, verts=bm.verts)
    uv = bm.loops.layers.uv.new("UVMap")
    for vtx in bm.verts:
        d = vtx.co.normalized()
        if -d.y > math.cos(math.radians(33)):  # flatten the iris a touch behind the cornea
            vtx.co *= 0.985 + 0.015 * (1 - (-d.y - math.cos(math.radians(33))) / (1 - math.cos(math.radians(33))))
    for f in bm.faces:
        for l in f.loops:
            p = l.vert.co / radius
            if p.y < 0:
                l[uv].uv = (0.5 + 0.5 * p.x, 0.5 + 0.5 * p.z)
            else:
                l[uv].uv = (0.5 + 0.5 * math.copysign(1, p.x) * 0.99, 0.5 + 0.5 * p.z)
    bmesh.ops.transform(bm, matrix=gaze_matrix(gaze), verts=bm.verts)
    # fixed triangulation: a sphere's quads have equal diagonals, so leaving the split to
    # the exporter lets float noise pick it (different triangle order build to build)
    bmesh.ops.triangulate(bm, faces=bm.faces[:], quad_method='FIXED', ngon_method='BEAUTY')
    ob = C.bm_to_object(bm, name, coll, smooth=True)
    ob.location = center
    C.apply_transform(ob)
    return ob


def make_cornea(name, center, radius, coll, gaze=None):
    bm = bmesh.new()
    bmesh.ops.create_uvsphere(bm, u_segments=48, v_segments=32, radius=radius * 1.012)
    bmesh.ops.transform(bm, matrix=Matrix.Rotation(math.radians(90), 4, 'X'), verts=bm.verts)
    lim = math.cos(math.radians(38))
    for vtx in bm.verts:
        d = vtx.co.normalized()
        f = -d.y
        if f > lim:
            k = (f - lim) / (1 - lim)
            vtx.co += d * radius * 0.085 * (k ** 0.8)
    # keep only the front half: the eyeball does the rest
    bmesh.ops.delete(bm, geom=[v for v in bm.verts if v.co.y > radius * 0.25], context='VERTS')
    bmesh.ops.transform(bm, matrix=gaze_matrix(gaze), verts=bm.verts)
    bmesh.ops.triangulate(bm, faces=bm.faces[:], quad_method='FIXED', ngon_method='BEAUTY')
    ob = C.bm_to_object(bm, name, coll, smooth=True)
    ob.location = center
    C.apply_transform(ob)
    return ob


def eye_materials(prof=None):
    prof = prof or {}
    sfx = prof.get("suffix", "")
    tex = eye_texture(tint=prof.get("iris_tint", (1.2, 0.86, 0.6)), gain=prof.get("iris_gain", 0.62), name="eye_albedo" + sfx)
    m = C.pbr_material("Eye", base=tex, roughness=0.15)
    p = C.principled(m)
    p.inputs['Subsurface Weight'].default_value = 0.15
    p.inputs['Subsurface Radius'].default_value = (0.9, 0.35, 0.25)
    p.inputs['Subsurface Scale'].default_value = 0.002
    c = C.new_material("Cornea")
    cp = C.principled(c)
    cp.inputs['Base Color'].default_value = (1, 1, 1, 1)
    cp.inputs['Roughness'].default_value = 0.0
    cp.inputs['IOR'].default_value = 1.376
    cp.inputs['Transmission Weight'].default_value = 1.0
    cp.inputs['Alpha'].default_value = 0.12
    try:
        c.surface_render_method = 'BLENDED'
    except Exception:
        pass
    return m, c


# ------------------------------------------------------------------ strand textures (lashes, brows)

def strand_atlas(name, size=512, strands=60, seed=1, color=(0.03, 0.022, 0.018), curl=0.25,
                 thickness=1.4, taper=True, root_at_bottom=True):
    """Alpha strands from root (v=0) to tip (v=1). Drawn with numpy, antialiased by supersampling."""
    r = C.rng(seed)
    ss = 2
    H = W = size * ss
    alpha = np.zeros((H, W), np.float32)
    yy = np.arange(H)
    for _ in range(strands):
        x0 = r.uniform(0.02, 0.98) * W
        bend = r.uniform(-curl, curl) * W * 0.25
        L = r.uniform(0.55, 1.0)
        th = thickness * ss * r.uniform(0.7, 1.3)
        n = int(H * L)
        t = np.linspace(0, 1, n)
        xs = x0 + bend * t * t + r.normal(0, 0.3, n).cumsum() * 0.2
        for i in range(0, n, 1):
            w = th * ((1 - t[i]) ** 0.6 if taper else 1)
            xa = int(xs[i] - w - 1); xb = int(xs[i] + w + 2)
            cols = np.arange(max(0, xa), min(W, xb))
            if len(cols) == 0:
                continue
            a = np.clip(w - np.abs(cols - xs[i]) + 0.5, 0, 1)
            row = H - 1 - i if root_at_bottom else i
            alpha[row, cols] = np.maximum(alpha[row, cols], a)
    alpha = alpha.reshape(size, ss, size, ss).mean((1, 3))
    rgb = np.ones((size, size, 3), np.float32) * np.array(color, np.float32)
    shade = C.value_noise(size, 8, seed + 7, 3)[..., None]
    rgb = rgb * (0.8 + 0.4 * shade)
    return C.save_png(np.concatenate([rgb, alpha[..., None]], -1), name)


def strand_material(name, img, color_mult=1.0, rough=0.45):
    m = C.pbr_material(name, base=img, roughness=rough, alpha='texture')
    try:
        m.surface_render_method = 'DITHERED'
    except Exception:
        pass
    m.use_backface_culling = False
    return m


def lash_uvs(obj, eye_center, upper=True):
    """u runs along the lid, v from the lid (root) to the tip."""
    me = obj.data
    if not me.uv_layers:
        me.uv_layers.new(name="UVMap")
    uvl = me.uv_layers[0].data
    co = np.array([v.co[:] for v in me.vertices]) - np.array(eye_center)
    ang = np.arctan2(co[:, 2], co[:, 0])
    rad = np.sqrt(co[:, 0] ** 2 + co[:, 2] ** 2)
    a0, a1 = ang.min(), ang.max()
    r0, r1 = rad.min(), rad.max()
    for p in me.polygons:
        for li in p.loop_indices:
            vi = me.loops[li].vertex_index
            uvl[li].uv = ((ang[vi] - a0) / max(1e-6, a1 - a0), (rad[vi] - r0) / max(1e-6, r1 - r0))


BROW = dict(count=140, rise=0.0165, arch=0.0055, drop=0.004, thick=0.0085, taper=0.6,
            length=(0.005, 0.0095), width=(0.0014, 0.0022), color=(0.085, 0.06, 0.042))


def brow_arc(t, bp=BROW):
    """Height of the brow line over the eye centre and its thickness at t (0 medial -> 1
    lateral); the skin stage paints its brow mask along the same arc."""
    return bp["rise"] + bp["arch"] * np.sin(np.pi * np.minimum(1, t * 1.25)) - bp["drop"] * t, bp["thick"] * (1 - bp["taper"] * t)


def eyebrow_cards(body, eye_center, side, coll, seed, bp=BROW):
    """Short hair cards laid on the brow ridge, growing medial->lateral like real brows."""
    r = C.rng(seed)
    bvh = C.rest_bvh(body)
    ex, ey, ez = eye_center
    s = 1 if side == 'L' else -1
    verts, faces, uvs = [], [], []
    count = bp["count"]        # the photo face texture carries the brow colour; cards add depth
    for i in range(count):
        t = r.random()  # 0 medial -> 1 lateral
        dx = (-0.013 + t * 0.041)
        # brow arc: rises toward 60% then drops laterally, thicker medially
        dz = bp["rise"] + bp["arch"] * math.sin(math.pi * min(1, t * 1.25)) - bp["drop"] * t
        thick = bp["thick"] * (1 - bp["taper"] * t)
        dz += r.uniform(-0.5, 0.5) * thick
        origin = Vector((ex + s * dx, ey - 0.06, ez + dz))
        hit, nrm, _, _ = bvh.ray_cast(origin, Vector((0, 1, 0)), 0.12)
        if hit is None:
            continue
        # growth: medial hairs point up, lateral hairs sweep outward and slightly down
        up_amt = 1.0 - t * 1.1
        g = Vector((s * (0.35 + t), 0, up_amt)).normalized()
        g = (g - nrm * g.dot(nrm)).normalized()
        side_v = nrm.cross(g).normalized()
        L = r.uniform(*bp["length"])
        W = r.uniform(*bp["width"])
        root = hit + nrm * 0.0004
        base = len(verts)
        segs = 3
        for k in range(segs + 1):
            f = k / segs
            p = root + g * (L * f) + nrm * (0.0012 * f * f)
            verts.append(p - side_v * W * 0.5)
            verts.append(p + side_v * W * 0.5)
        col = r.integers(0, 4)
        for k in range(segs):
            a = base + 2 * k
            faces.append((a, a + 1, a + 3, a + 2))
            uvs.append([((col + 0) / 4, k / segs), ((col + 1) / 4, k / segs),
                        ((col + 1) / 4, (k + 1) / segs), ((col + 0) / 4, (k + 1) / segs)])
    ob = C.mesh_object(f"Eyebrow_{side}", verts, faces, coll)
    uvl = ob.data.uv_layers.new(name="UVMap")
    for p, quad in zip(ob.data.polygons, uvs):
        for li, uv in zip(p.loop_indices, quad):
            uvl.data[li].uv = uv
    ob.data.shade_smooth()
    return ob


def lengthen_lashes(ob, eye_center, factor):
    """Longer lashes: move each vertex outward from the eye by (factor - 1) of its distance
    along the strip (0 at the lid, the full lash length at the tip); the roots stay put."""
    if abs(factor - 1.0) < 1e-6:
        return
    co = np.array([v.co[:] for v in ob.data.vertices])
    c = np.array(eye_center)
    d = co - c
    rad = np.sqrt(d[:, 0] ** 2 + d[:, 2] ** 2)
    r0, r1 = rad.min(), rad.max()
    t = (rad - r0) / max(1e-6, r1 - r0)
    u = d / np.maximum(np.linalg.norm(d, axis=1, keepdims=True), 1e-6)
    co = co + u * (t * (r1 - r0) * (factor - 1.0))[:, None]
    ob.data.vertices.foreach_set("co", co.astype(np.float32).ravel())
    ob.data.update()


def build(rig, body, helpers, coll=None, prof=None):
    prof = prof or {}
    sfx = prof.get("suffix", "")
    bp = dict(BROW, **prof.get("brow", {}))
    lp = prof.get("lashes", {})
    coll = coll or C.collection("Skater")
    eye_mat, cornea_mat = eye_materials(prof)
    out = {}
    for side in ('L', 'R'):
        sock = helpers[f"EyeSocket_{side}"]
        wv = _world_verts(sock)
        center = wv.mean(0)
        radius = float(np.mean((wv.max(0) - wv.min(0)) * 0.5)) * 0.97
        # The socket helper sits a few mm medial of the lid opening, so an eye looking
        # straight out reads cross-eyed. Seat the eyeball under the opening (between the
        # lash strips) and aim both eyes at a point 1.2 m ahead: a relaxed, level gaze.
        lash = np.concatenate([_world_verts(helpers[f"Lashes{p}_{side}"]) for p in ("Top", "Bot")])
        ap = np.array([(lash[:, 0].min() + lash[:, 0].max()) / 2, center[1], np.median(lash[:, 2])])
        eye_c = center + (ap - center) * np.array([0.7, 0.0, 0.7])
        gaze = Vector((0.0, center[1] - 1.2, center[2] - 0.01)) - Vector(eye_c)
        eye = make_eyeball(f"Eye_{side}", Vector(eye_c), radius, coll, gaze)
        C.assign(eye, eye_mat)
        cor = make_cornea(f"Cornea_{side}", Vector(eye_c), radius, coll, gaze)
        C.assign(cor, cornea_mat)
        for o in (eye, cor):
            weight_all(o, "head", rig)
        out[f"eye_{side}"] = (tuple(center), radius)
        bpy.data.objects.remove(sock, do_unlink=True)

    up = dict(dict(strands=110, seed=3, curl=0.5, thickness=0.75), **lp.get("upper", {}))
    lo = dict(dict(strands=45, seed=4, curl=0.3, thickness=0.6), **lp.get("lower", {}))
    lash_img = strand_atlas("lash_alpha" + sfx, 512, **up)
    lash_mat = strand_material("Lashes", lash_img)
    lash_low = strand_atlas("lash_low_alpha" + sfx, 512, **lo)
    lash_low_mat = strand_material("LashesLower", lash_low)
    for side in ('L', 'R'):
        c = out[f"eye_{side}"][0]
        for part in ('Top', 'Bot'):
            ob = helpers[f"Lashes{part}_{side}"]
            lengthen_lashes(ob, c, lp.get("length", 1.0))
            lash_uvs(ob, c, part == 'Top')
            # the '-1' helper strips sit on the upper lid on this mesh
            z = np.mean([v.co.z for v in ob.data.vertices])
            C.assign(ob, lash_mat if z > c[2] - 0.004 else lash_low_mat)
            if not ob.modifiers:
                mod = ob.modifiers.new("Armature", 'ARMATURE')
                mod.object = rig

    brow_img = strand_atlas("brow_alpha" + sfx, 512, strands=30, seed=5, curl=0.5, thickness=1.3,
                            color=bp["color"])
    brow_mat = strand_material("Eyebrows", brow_img)
    for i, side in enumerate(('L', 'R')):
        b = eyebrow_cards(body, out[f"eye_{side}"][0], side, coll, 40 + i, bp)
        C.assign(b, brow_mat)
        weight_all(b, "head", rig)
        out[f"brow_{side}"] = b

    teeth = C.pbr_material("Teeth", base_color=(0.82, 0.78, 0.70, 1), roughness=0.25)
    tongue = C.pbr_material("Tongue", base_color=(0.55, 0.22, 0.22, 1), roughness=0.4)
    for name in ("TeethUpper", "TeethLower"):
        C.assign(helpers[name], teeth)
    C.assign(helpers["Tongue"], tongue)
    for name in ("TeethUpper", "TeethLower", "Tongue"):
        ob = helpers[name]
        if not ob.modifiers:
            mod = ob.modifiers.new("Armature", 'ARMATURE')
            mod.object = rig
    out["brow_params"] = bp
    return out
