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


def clump_atlas(size=1024, cols=8, seed=7, root=HAIR_ROOT, tip=HAIR_TIP, name="hair_atlas", spread=0.3, root_fade=0.0,
                stagger=0.0):
    """Each column holds one clump of strands: dense at the root (v=0), tapering and
    separating toward the tip. stagger: each strand starts up to this far along the card
    (a ragged root line, not a straight card edge: exposed hairlines). Returns an RGBA
    image (colour + alpha)."""
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
            tipx = base + r.uniform(-spread, spread) * colw * (0.6 + 0.4 * r.random())
            L = r.uniform(0.6, 1.0)
            th = r.uniform(0.7, 1.5) * ss
            wig = r.uniform(0, 1.5) * ss
            ph = r.uniform(0, 6.28)
            lum = r.uniform(0.5, 1.0)
            s0 = r.uniform(0.0, stagger) if stagger > 0 else 0.0   # (no draw when off: the crop's atlas is unchanged)
            steps = int(H * L)
            t = np.arange(steps) / H
            xs = x0 + base + (tipx - base) * (t / L) ** 1.6 + wig * np.sin(t * 9 + ph)
            rows = H - 1 - np.arange(steps)
            w = th * (1 - (t / L) ** 3 * 0.7)
            vis = (t >= s0).astype(np.float32)
            for k in (-2, -1, 0, 1, 2):
                cx = np.floor(xs).astype(int) + k
                a = np.clip(w / 2 + 0.5 - np.abs(cx + 0.5 - xs), 0, 1) * vis
                ok = (cx >= x0) & (cx < x0 + colw)
                np.maximum.at(alpha, (rows[ok], cx[ok]), a[ok])
                np.maximum.at(shade, (rows[ok], cx[ok]), (a * lum)[ok])
    alpha = alpha.reshape(size, ss, size, ss).mean((1, 3))
    shade = shade.reshape(size, ss, size, ss).mean((1, 3)) / np.maximum(alpha, 1e-3)
    v = np.linspace(1, 0, size)[:, None]  # row 0 is the tip (v = 1)
    tipness = np.clip(v, 0, 1) ** 1.3
    col = np.asarray(root)[None, None, :] * (1 - tipness[..., None]) + np.asarray(tip)[None, None, :] * tipness[..., None]
    col = col * (0.6 + 0.6 * shade[..., None])
    alpha = np.clip(alpha * 1.35, 0, 1)
    # feather the card edges so card borders never show as hard lines
    xin = (np.arange(size) % (size // cols)) / (size // cols)
    edge = np.clip(np.minimum(xin, 1 - xin) / 0.12, 0, 1)
    alpha *= edge[None, :] ** 0.7
    # fade the very tip
    alpha *= np.clip((1 - v) * 1.0 / 0.04 + 0.0, 0, 1) if False else 1.0
    if root_fade > 0:
        # soft roots: a card's first few per cent fade in, so hairlines have no hard edge
        alpha *= sstep(0.0, root_fade, v)
    srgb = np.where(col <= 0.0031308, col * 12.92, 1.055 * np.power(np.clip(col, 0, 1), 1 / 2.4) - 0.055)
    return C.save_png(np.concatenate([srgb, alpha[..., None]], -1), name)


def scalp_samples(body, count, seed, min_w=0.35, max_w=1.01, with_weights=False, field=None):
    me = body.data
    if field is not None:
        w = field
    else:
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
    keep = (tw > min_w) & (tw <= max_w)
    tris = tris[keep]
    tw = tw[keep]
    a, b, c = co[tris[:, 0]], co[tris[:, 1]], co[tris[:, 2]]
    area = 0.5 * np.linalg.norm(np.cross(b - a, c - a), axis=1)
    r = C.rng(seed)
    pick = r.choice(len(tris), count, p=area / area.sum())
    u = r.random(count); v = r.random(count)
    flip = u + v > 1
    u[flip] = 1 - u[flip]; v[flip] = 1 - v[flip]
    pts = a[pick] + (b[pick] - a[pick]) * u[:, None] + (c[pick] - a[pick]) * v[:, None]
    return (pts, tw[pick]) if with_weights else pts


def build(body, rig, coll=None, prof=None):
    if prof and prof.get("hair_style") == "bun":
        return build_bun(body, rig, coll, prof)
    coll = coll or C.collection("Skater")
    atlas = clump_atlas(1024 if not C.FAST else 512)
    bvh = C.rest_bvh(body)
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
    ob = hair_object(verts, faces, uvs, atlas, rig, coll)
    store_card_roots(ob, 14)          # (6 segments per card; for the hat masks)
    return ob


def hair_object(verts, faces, uvs, atlas, rig, coll, roots=None):
    """The card mesh, weighted to the head, with the Hair material. roots: per card, the
    root point (stored as a face attribute for the hat masks, see skater_hats)."""
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
    m = C.pbr_material("Hair", base=atlas, roughness=0.58, alpha='texture')
    p = C.principled(m)
    # hair highlights are tinted by the fibre colour (and there are many overlapping cards)
    p.inputs['Specular IOR Level'].default_value = 0.2
    p.inputs['Specular Tint'].default_value = (0.62, 0.46, 0.32, 1)
    p.inputs['Sheen Weight'].default_value = 0.0
    p.inputs['Sheen Tint'].default_value = (0.5, 0.35, 0.25, 1)
    try:
        m.surface_render_method = 'DITHERED'
    except Exception:
        pass
    m.use_backface_culling = False
    C.assign(ob, m)
    return ob


# ------------------------------------------------------------------ pulled back into a bun

BUN_ROOT = np.array([0.0075, 0.0052, 0.0040])   # linear: near-black brown, a little warm
BUN_TIP = np.array([0.030, 0.019, 0.012])


def _ribbon(verts, faces, uvs, pts, normals, width, col, cols, taper=0.35):
    """One card along pts, lying flat on the surface given by normals (width across it)."""
    n = len(pts)
    base = len(verts)
    for k in range(n):
        t = k / (n - 1)
        tang = (pts[min(k + 1, n - 1)] - pts[max(k - 1, 0)]).normalized()
        wv = tang.cross(normals[k]).normalized()
        half = width * (1 - taper * t) * 0.5
        verts.append(pts[k] - wv * half)
        verts.append(pts[k] + wv * half)
    for k in range(n - 1):
        a = base + 2 * k
        faces.append((a, a + 1, a + 3, a + 2))
        v0, v1 = k / (n - 1), (k + 1) / (n - 1)
        u0, u1 = col / cols, (col + 1) / cols
        uvs.append([(u0, v0), (u1, v0), (u1, v1), (u0, v1)])


def build_bun(body, rig, coll=None, prof=None):
    """Long hair pulled back over the scalp into a high bun. Scalp cards run from area-
    weighted roots along the surface towards the bun's base, lying flat (sleek, pulled
    back), rooted ever more sparsely toward the scalp's soft edge (the hairline); the
    bun is a coil of wide cards wound round its own axis, with a few curled flyaways."""
    prof = prof or {}
    coll = coll or C.collection("Skater")
    cols = 8
    atlas = clump_atlas(1024 if not C.FAST else 512, cols=cols, seed=17, root=BUN_ROOT, tip=BUN_TIP,
                        name="hair_atlas" + prof.get("suffix", ""), spread=0.18, root_fade=0.12, stagger=0.14)
    bvh = C.rest_bvh(body)
    co = S._vertex_array(body)
    head_w = S._group_weights(body, "head")
    hv = co[head_w > 0.8]
    hc = Vector(((hv.max(0) + hv.min(0)) / 2).tolist())
    top_z = float(hv[:, 2].max())
    r = C.rng(123)
    # the bun sits on the back of the crown
    bdir = Vector((0.0, 0.62, 0.78)).normalized()
    hit, bn, _, _ = bvh.ray_cast(hc + bdir * 0.3, -bdir, 0.6)
    surf = hit if hit is not None else hc + bdir * 0.1
    bun_base = surf + bdir * 0.006
    bun_r = 0.030

    def on_surface(q, off):
        loc, n, _, _ = bvh.find_nearest(q)
        if loc is None:
            return q, bdir
        n = n.normalized()
        return loc + n * off, n

    verts, faces, uvs, roots = [], [], [], []
    # count, surface offset, width, scalp weight band, length cap. (No layer of short fine
    # cards along the hairline: a card a few mm wide still carries a whole atlas column of
    # strands, ten times denser than the wide cards, and reads as dark blocks.)
    layers = [(900, 0.0018, 0.020, (0.45, 1.01), 0.27), (800, 0.0036, 0.017, (0.5, 1.01), 0.27),
              (500, 0.0054, 0.014, (0.55, 1.01), 0.27)]
    # roots come from a smoothed scalp field: the MakeHuman scalp group ends in a per-face
    # staircase, the smoothed field's level lines are a soft, natural hairline
    field = S.smooth_field(S._group_weights(body, "scalp"), S._neighbours(body), 10)
    field = np.clip(field * 1.25, 0, 1)
    for li, (count, off, width, band, cap) in enumerate(layers, 1):
        # root density ramps up across the band's lower edge instead of starting at a level
        # line: the faded roots of a dozen cards rooted on one line stack into an opaque,
        # flat-bottomed block (a toothed hairline)
        lo = band[0] - 0.12
        pts0, wts = scalp_samples(body, count * 2, 200 + li, min_w=lo, max_w=band[1], with_weights=True, field=field)
        ramp = sstep(lo, band[0] + 0.3, wts) ** 1.5
        keep = np.flatnonzero(C.rng(300 + li).random(len(wts)) < ramp)[:count]
        pts0, wts = pts0[keep], wts[keep]
        for p0, wt in zip(pts0, wts):
            q, n = on_surface(Vector(p0), off)
            path, nrms = [q], [n]
            step = 0.014
            total = 0.0
            for k in range(22):
                to = bun_base - q
                if to.length < bun_r * (0.85 + 0.25 * r.random()) or total > cap * r.uniform(0.7, 1.0):
                    break
                tang = to - n * to.dot(n)
                if tang.length < 1e-5:
                    break
                d = tang.normalized()
                # a slight fan: strands cross a little on the way, not dead straight
                d = (d + n.cross(d) * (0.08 * r.normal())).normalized()
                q, n = on_surface(q + d * step, off + 0.0006 * li * (k / 22))
                path.append(q)
                nrms.append(n)
                total += step
            if len(path) < 3:
                continue
            # cards rooted near the scalp's edge are narrower (a finer hairline)
            wscale = 0.55 + 0.45 * float(sstep(0.45, 0.8, wt))
            _ribbon(verts, faces, uvs, path, nrms, width * wscale * r.uniform(0.8, 1.25), int(r.integers(0, cols)), cols,
                    taper=0.25)
            roots += [tuple(p0)] * (len(path) - 1)
    # the bun: a coil wound round its axis, rising outward, radius shrinking to the top
    ax = bdir
    u = ax.cross(Vector((1, 0, 0))).normalized()
    v = ax.cross(u).normalized()
    turns = 2.6
    for i in range(110):
        th0 = r.uniform(0, turns * 2 * math.pi)
        span = r.uniform(1.6, 2.6)
        jr = r.normal(0, 0.003)
        jh = r.normal(0, 0.002)
        pts, nrms = [], []
        for k in range(11):
            th = th0 + span * k / 10
            f = th / (turns * 2 * math.pi)
            R = (bun_r * (1.0 - 0.45 * f) + jr) * (1.0 + 0.05 * math.sin(th * 3))
            h = 0.004 + 0.034 * f + jh
            radial = u * math.cos(th) + v * math.sin(th)
            pts.append(bun_base + ax * h + radial * R)
            # the card faces outward from the coil (its width runs along the bun's axis)
            tang = -u * math.sin(th) + v * math.cos(th)
            nrms.append(radial)
        _ribbon(verts, faces, uvs, pts, nrms, r.uniform(0.018, 0.026), int(r.integers(0, cols)), cols, taper=0.2)
        roots += [tuple(bun_base)] * 10
    # a few short flyaways curling out of the bun
    for i in range(12):
        th = r.uniform(0, 2 * math.pi)
        f = r.uniform(0.2, 0.8)
        R = bun_r * (1.0 - 0.45 * f)
        radial = u * math.cos(th) + v * math.sin(th)
        p = bun_base + ax * (0.004 + 0.034 * f) + radial * (R - 0.002)
        tang = -u * math.sin(th) + v * math.cos(th)
        pts = []
        for k in range(6):
            a = k / 5
            pts.append(p + radial * (0.009 * a) + tang * (0.02 * a) + Vector((0, 0, -0.008 * a * a)))
        _ribbon(verts, faces, uvs, pts, [radial] * 6, 0.005, int(r.integers(0, cols)), cols, taper=0.7)
        roots += [tuple(bun_base)] * 5
    ob = hair_object(verts, faces, uvs, atlas, rig, coll)
    _store_roots(ob, roots)
    return ob


def _store_roots(ob, roots):
    """Per face: the root point of its card (the hat masks hide cards by where they grow)."""
    a = ob.data.attributes.new("card_root", 'FLOAT_VECTOR', 'FACE')
    a.data.foreach_set("vector", np.array(roots, np.float32).ravel())


def store_card_roots(ob, verts_per_card):
    """card_root for a mesh of equal-length cards (the crop): each card's first edge midpoint."""
    co = S._vertex_array(ob)
    n = len(co) // verts_per_card
    roots = []
    for c in range(n):
        root = (co[c * verts_per_card] + co[c * verts_per_card + 1]) / 2
        roots += [tuple(root)] * (verts_per_card // 2 - 1)
    _store_roots(ob, roots)
