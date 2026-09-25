"""Skater stage 5: hair built from hair cards.

A 'textured crop' haircut: 6-9 cm on top swept forward and to the side, short tapered
sides and back. Cards are grown from area-weighted random roots on the MakeHuman scalp
region along a styled flow field, kept outside the skull with a BVH, layered for volume,
and textured with a strand-clump atlas drawn procedurally (alpha, root-to-tip colour).
"""
import math

import bpy
import numpy as np
from mathutils import Vector
from mathutils.bvhtree import BVHTree

from lib import common as C
import skater_skin as S

sstep = S.sstep

HAIR_ROOT = np.array([0.011, 0.0065, 0.004])   # linear
HAIR_TIP = np.array([0.048, 0.029, 0.016])


def clump_atlas(size=1024, cols=8, seed=7):
    """Each column holds one clump of strands: dense at the root (v=0), tapering and
    separating toward the tip. Returns an RGBA image (colour + alpha)."""
    r = C.rng(seed)
    ss = 2
    H, W = size * ss, size * ss
    colw = W // cols
    alpha = np.zeros((H, W), np.float32)
    shade = np.zeros((H, W), np.float32)
    for c in range(cols):
        n = r.integers(50, 80)
        x0 = c * colw
        for _ in range(n):
            base = r.uniform(0.12, 0.88) * colw
            tipx = base + r.uniform(-0.3, 0.3) * colw * (0.6 + 0.4 * r.random())
            L = r.uniform(0.6, 1.0)
            th = r.uniform(0.7, 1.5) * ss
            wig = r.uniform(0, 1.5) * ss
            ph = r.uniform(0, 6.28)
            lum = r.uniform(0.5, 1.0)
            steps = int(H * L)
            t = np.arange(steps) / H
            xs = x0 + base + (tipx - base) * (t / L) ** 1.6 + wig * np.sin(t * 9 + ph)
            rows = H - 1 - np.arange(steps)
            w = th * (1 - (t / L) ** 3 * 0.7)
            for k in (-2, -1, 0, 1, 2):
                cx = np.floor(xs).astype(int) + k
                a = np.clip(w / 2 + 0.5 - np.abs(cx + 0.5 - xs), 0, 1)
                ok = (cx >= x0) & (cx < x0 + colw)
                np.maximum.at(alpha, (rows[ok], cx[ok]), a[ok])
                np.maximum.at(shade, (rows[ok], cx[ok]), (a * lum)[ok])
    alpha = alpha.reshape(size, ss, size, ss).mean((1, 3))
    shade = shade.reshape(size, ss, size, ss).mean((1, 3)) / np.maximum(alpha, 1e-3)
    v = np.linspace(1, 0, size)[:, None]  # row 0 is the tip (v = 1)
    tipness = np.clip(v, 0, 1) ** 1.3
    col = HAIR_ROOT[None, None, :] * (1 - tipness[..., None]) + HAIR_TIP[None, None, :] * tipness[..., None]
    col = col * (0.6 + 0.6 * shade[..., None])
    alpha = np.clip(alpha * 1.35, 0, 1)
    # feather the card edges so card borders never show as hard lines
    xin = (np.arange(size) % (size // cols)) / (size // cols)
    edge = np.clip(np.minimum(xin, 1 - xin) / 0.12, 0, 1)
    alpha *= edge[None, :] ** 0.7
    # fade the very tip
    alpha *= np.clip((1 - v) * 1.0 / 0.04 + 0.0, 0, 1) if False else 1.0
    srgb = np.where(col <= 0.0031308, col * 12.92, 1.055 * np.power(np.clip(col, 0, 1), 1 / 2.4) - 0.055)
    return C.save_png(np.concatenate([srgb, alpha[..., None]], -1), "hair_atlas")


def scalp_samples(body, count, seed, min_w=0.35):
    me = body.data
    gi = body.vertex_groups["scalp"].index
    w = np.zeros(len(me.vertices), np.float32)
    for v in me.vertices:
        for g in v.groups:
            if g.group == gi:
                w[v.index] = g.weight
    me.calc_loop_triangles()
    tris = np.array([t.vertices[:] for t in me.loop_triangles])
    co = S._vertex_array(body)
    tw = w[tris].mean(1)
    tris = tris[tw > min_w]
    a, b, c = co[tris[:, 0]], co[tris[:, 1]], co[tris[:, 2]]
    area = 0.5 * np.linalg.norm(np.cross(b - a, c - a), axis=1)
    r = C.rng(seed)
    pick = r.choice(len(tris), count, p=area / area.sum())
    u = r.random(count); v = r.random(count)
    flip = u + v > 1
    u[flip] = 1 - u[flip]; v[flip] = 1 - v[flip]
    pts = a[pick] + (b[pick] - a[pick]) * u[:, None] + (c[pick] - a[pick]) * v[:, None]
    return pts


def build(body, rig, coll=None):
    coll = coll or C.collection("Skater")
    atlas = clump_atlas(1024 if not C.FAST else 512)
    deps = bpy.context.evaluated_depsgraph_get()
    bvh = BVHTree.FromObject(body, deps)
    co = S._vertex_array(body)
    head_w = S._group_weights(body, "head")
    hv = co[head_w > 0.8]
    hc = (hv.max(0) + hv.min(0)) / 2
    top_z = hv[:, 2].max()
    r = C.rng(99)

    layers = [  # (count, length scale, width, lift, surface offset)
        (800, 0.8, 0.024, 0.015, 0.0022),
        (800, 1.0, 0.019, 0.06, 0.005),
        (600, 1.08, 0.014, 0.12, 0.009),
    ]
    verts, faces, uvs = [], [], []
    cols = 8
    for li, (count, lscale, width, lift, off) in enumerate(layers):
        roots = scalp_samples(body, count, 100 + li, min_w=0.3 if li == 0 else 0.45)
        for p0 in roots:
            loc, n, _, _ = bvh.find_nearest(Vector(p0))
            if loc is None:
                continue
            n = n.normalized()
            rel = Vector(p0) - Vector(hc)
            topness = float(sstep(hc[2] + 0.02, top_z - 0.02, p0[2]))
            back = float(sstep(-0.01, 0.06, rel.y))
            side = float(sstep(0.045, 0.075, abs(rel.x))) * (1 - topness)
            front = float(sstep(-0.02, -0.07, rel.y)) * topness
            # length: long on top, short tapered sides/back, fringe a bit longer
            L = (0.028 + 0.055 * topness + 0.012 * front) * (1 - 0.45 * side) * (1 - 0.25 * back * (1 - topness))
            L *= lscale * r.uniform(0.75, 1.2)
            # flow: top swept forward and toward the left side, sides and back go down/back
            flow = Vector((0.35 + 0.2 * r.normal(), -1.0, 0.25)) * topness
            flow += Vector((math.copysign(0.3, rel.x), 0.5, -1.0)) * (side + back * (1 - topness))
            flow += Vector((0, 0.2, -1.0)) * (1 - topness) * (1 - side) * (1 - back)
            flow = flow - n * flow.dot(n)
            if flow.length < 1e-4:
                flow = Vector((0, 0, -1)) - n * n.z
            flow.normalize()
            d = (flow + n * (lift + 0.1 * topness * front)).normalized()
            segs = 6
            seg = L / segs
            pts = [Vector(p0) + n * off * 0.4]
            cur = d
            curl = Vector((r.normal(), r.normal(), r.normal())) * 0.1
            for k in range(segs):
                grav = Vector((0, 0, -1)) * (0.3 + 0.5 * (1 - topness)) * (k / segs)
                cur = (cur + grav + curl * (k / segs)).normalized()
                q = pts[-1] + cur * seg
                loc2, n2, _, dist = bvh.find_nearest(q)
                if loc2 is not None:
                    want = off + 0.0025 * topness * (k / segs) * (li + 1)
                    rel2 = q - loc2
                    if rel2.dot(n2) < want:
                        q = loc2 + n2 * want
                        cur = (q - pts[-1]).normalized()
                pts.append(q)
            base_i = len(verts)
            twist = r.uniform(-0.2, 0.2)
            wcard = width * r.uniform(0.75, 1.3)
            col = int(r.integers(0, cols))
            for k, q in enumerate(pts):
                t = k / segs
                loc3, n3, _, _ = bvh.find_nearest(q)
                nn = (n3 if n3 is not None else n)
                tang = (pts[min(k + 1, segs)] - pts[max(k - 1, 0)]).normalized()
                wv = tang.cross(nn).normalized()
                wv = (wv * math.cos(twist) + nn * math.sin(twist)).normalized()
                half = wcard * (1 - 0.55 * t) * 0.5
                verts.append(q - wv * half)
                verts.append(q + wv * half)
            for k in range(segs):
                a = base_i + 2 * k
                faces.append((a, a + 1, a + 3, a + 2))
                v0, v1 = k / segs, (k + 1) / segs
                u0, u1 = col / cols, (col + 1) / cols
                uvs.append([(u0, v0), (u1, v0), (u1, v1), (u0, v1)])
    ob = C.mesh_object("Hair", verts, faces, coll)
    uvl = ob.data.uv_layers.new(name="UVMap")
    for p, quad in zip(ob.data.polygons, uvs):
        for li, uv in zip(p.loop_indices, quad):
            uvl.data[li].uv = uv
    ob.data.shade_smooth()
    g = ob.vertex_groups.new(name="head")
    g.add(list(range(len(ob.data.vertices))), 1.0, 'REPLACE')
    ob.parent = rig
    am = ob.modifiers.new("Armature", 'ARMATURE')
    am.object = rig
    m = C.pbr_material("Hair", base=atlas, roughness=0.5, alpha='texture')
    p = C.principled(m)
    p.inputs['Specular IOR Level'].default_value = 0.3
    p.inputs['Sheen Weight'].default_value = 0.2
    p.inputs['Sheen Tint'].default_value = (0.5, 0.35, 0.25, 1)
    try:
        m.surface_render_method = 'DITHERED'
    except Exception:
        pass
    m.use_backface_culling = False
    C.assign(ob, m)
    return ob
