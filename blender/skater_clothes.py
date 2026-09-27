"""Skater stage 4: clothes - a fleece hoodie, loose denim jeans and suede skate shoes.

The hoodie and jeans are cut from the body mesh itself, so they carry the body's skin
weights and deform with it: anatomy is smoothed away, the fabric is inflated and draped
(straight-hanging front, tube legs, loose sleeves), then folds are sculpted procedurally
(elbow and cuff stacking, knee creases, ankle stacks, torso drape). A second 'Fabric' UV
set is laid out analytically (circumference x length, in metres, seams at the real
garment seams) so the fabric photo tiles at true scale; baking puts colour, folds, seams,
wear and ambient occlusion into a unique texture per garment.

The shoes are lofted from cross-sections around each foot: suede upper with a leather
side stripe, padded tongue, criss-cross laces with a bow, and a white rubber cupsole.
"""
import math

import bpy
import bmesh
import numpy as np
from mathutils import Vector

from lib import common as C
import skater_skin as S

sstep = S.sstep


def bone(rig, name):
    b = rig.data.bones[name]
    return np.array(b.head_local), np.array(b.tail_local)


def verts_np(obj):
    return S._vertex_array(obj)


def set_verts(obj, co):
    obj.data.vertices.foreach_set('co', co.astype(np.float32).ravel())
    obj.data.update()


def bone_weight_matrix(obj, names):
    idx = {obj.vertex_groups[n].index: i for i, n in enumerate(names) if n in obj.vertex_groups}
    W = np.zeros((len(obj.data.vertices), len(names)), np.float32)
    for v in obj.data.vertices:
        for g in v.groups:
            j = idx.get(g.group)
            if j is not None:
                W[v.index, j] = g.weight
    return W


TORSO = ["pelvis", "spine_01", "spine_02", "spine_03", "neck_01", "clavicle_l", "clavicle_r", "head"]
ARM_L = ["upperarm_l", "lowerarm_l", "hand_l"]
ARM_R = ["upperarm_r", "lowerarm_r", "hand_r"]
LEG_L = ["thigh_l", "calf_l", "foot_l", "ball_l"]
LEG_R = ["thigh_r", "calf_r", "foot_r", "ball_r"]
PARTS = {"torso": TORSO, "arm_l": ARM_L, "arm_r": ARM_R, "leg_l": LEG_L, "leg_r": LEG_R}


def classify(body):
    """Part label per vertex (by the dominant limb weight) - fingers count as hand."""
    names = sum(PARTS.values(), [])
    W = bone_weight_matrix(body, names)
    fingers = [g.name for g in body.vertex_groups if any(g.name.startswith(p) for p in ("index", "middle", "ring", "pinky", "thumb"))]
    Wf = bone_weight_matrix(body, fingers)
    part_w = {}
    k = 0
    for p, bl in PARTS.items():
        part_w[p] = W[:, k:k + len(bl)].sum(1)
        k += len(bl)
    fl = np.array([n.endswith("_l") for n in fingers])
    if len(fingers):
        part_w["arm_l"] += Wf[:, fl].sum(1)
        part_w["arm_r"] += Wf[:, ~fl].sum(1)
    keys = list(part_w)
    M = np.stack([part_w[p] for p in keys], 1)
    lab = np.array(keys)[M.argmax(1)]
    return lab


def axis_coords(co, pts, ref):
    """Project points on a polyline axis. Returns t (arc length), theta, radius, foot point,
    radial unit vector and the local frame used for theta (b1 = ref projected)."""
    pts = [np.asarray(p, np.float64) for p in pts]
    best_d = np.full(len(co), 1e9)
    t_out = np.zeros(len(co)); foot = np.zeros_like(co); seg_dir = np.zeros_like(co)
    acc = 0.0
    for a, b in zip(pts[:-1], pts[1:]):
        ab = b - a
        L = np.linalg.norm(ab)
        dirv = ab / L
        s = np.clip(((co - a) @ dirv), -0.5, L + 0.5)
        if a is not pts[0]:
            s = np.maximum(s, 0)
        if b is not pts[-1]:
            s = np.minimum(s, L)
        f = a + s[:, None] * dirv
        d = np.linalg.norm(co - f, axis=1)
        m = d < best_d
        best_d[m] = d[m]; t_out[m] = acc + s[m]; foot[m] = f[m]; seg_dir[m] = dirv
        acc += L
    radial = co - foot
    r = np.linalg.norm(radial, axis=1)
    rad_u = radial / np.maximum(r, 1e-6)[:, None]
    ref = np.asarray(ref, np.float64)
    b1 = ref - seg_dir * (seg_dir @ ref)[:, None]
    b1 /= np.linalg.norm(b1, axis=1, keepdims=True)
    b2 = np.cross(seg_dir, b1)
    theta = np.arctan2((rad_u * b2).sum(1), (rad_u * b1).sum(1))
    return dict(t=t_out, theta=theta, r=r, foot=foot, rad=rad_u, dir=seg_dir, length=acc)


def binned_mean(values, t, bins, lo, hi):
    idx = np.clip(((t - lo) / (hi - lo) * bins).astype(int), 0, bins - 1)
    s = np.bincount(idx, values, bins)
    c = np.bincount(idx, None, bins)
    m = s / np.maximum(c, 1)
    # fill empty bins from neighbours
    for i in range(bins):
        if c[i] == 0:
            j = np.nonzero(c)[0]
            m[i] = m[j[np.argmin(np.abs(j - i))]] if len(j) else 0
    return m[idx]


def garment_from_body(body, name, keep, coll):
    me = body.data.copy()
    ob = bpy.data.objects.new(name, me)
    C.link(ob, coll)
    ob.parent = body.parent
    bm = bmesh.new()
    bm.from_mesh(me)
    bm.verts.ensure_lookup_table()
    bmesh.ops.delete(bm, geom=[v for v in bm.verts if not keep[v.index]], context='VERTS')
    bm.to_mesh(me)
    bm.free()
    for a in list(me.color_attributes):
        me.color_attributes.remove(a)
    me.materials.clear()
    mod = ob.modifiers.new("Armature", 'ARMATURE')
    mod.object = body.parent
    return ob


def laplacian(ob, iterations=6, factor=0.6, preserve=True):
    C.select_only(ob)
    m = ob.modifiers.new("Lap", 'LAPLACIANSMOOTH')
    m.iterations = iterations
    m.lambda_factor = factor
    m.use_volume_preserve = preserve
    m.use_normalized = True
    bpy.ops.object.modifier_move_to_index(modifier="Lap", index=0)
    bpy.ops.object.modifier_apply(modifier="Lap")


def smooth(ob, iterations=3, factor=0.5):
    C.select_only(ob)
    m = ob.modifiers.new("Sm", 'SMOOTH')
    m.iterations = iterations
    m.factor = factor
    bpy.ops.object.modifier_move_to_index(modifier="Sm", index=0)
    bpy.ops.object.modifier_apply(modifier="Sm")


def rim(ob, thickness=0.006, even=True):
    C.select_only(ob)
    m = ob.modifiers.new("Rim", 'SOLIDIFY')
    m.thickness = thickness
    m.offset = -1
    m.use_rim_only = True
    m.use_even_offset = even
    bpy.ops.object.modifier_move_to_index(modifier="Rim", index=0)
    bpy.ops.object.modifier_apply(modifier="Rim")


def boundary_verts(ob):
    bm = bmesh.new()
    bm.from_mesh(ob.data)
    idx = np.array([v.index for v in bm.verts if v.is_boundary], np.int64)
    bm.free()
    return idx


def snap_openings(ob, rules):
    """Move boundary vertices onto clean cut planes. rules: list of (predicate(co)->mask,
    projector(co[mask])->new co)."""
    co = verts_np(ob)
    b = boundary_verts(ob)
    if len(b) == 0:
        return
    bc = co[b]
    for pred, proj in rules:
        m = pred(bc)
        if m.any():
            bc[m] = proj(bc[m])
    co[b] = bc
    set_verts(ob, co)


def axis_snap(pts, t_target, ref=(0, 0, 1)):
    """Projector that slides points along a polyline axis to arc length t_target."""
    def proj(c):
        ax = axis_coords(c, pts, ref)
        # rebuild the axis point at t_target
        cum = [0.0]
        P = [np.asarray(p, np.float64) for p in pts]
        for a, b in zip(P[:-1], P[1:]):
            cum.append(cum[-1] + np.linalg.norm(b - a))
        k = max(0, min(len(P) - 2, int(np.searchsorted(cum, t_target) - 1)))
        d = (P[k + 1] - P[k]) / np.linalg.norm(P[k + 1] - P[k])
        f = P[k] + d * (t_target - cum[k])
        return f + ax["rad"] * ax["r"][:, None]
    return proj


def noise1(x, seed, freq=1.0):
    r = C.rng(seed)
    ph = r.uniform(0, 6.28, 4)
    fr = np.array([1.0, 2.1, 3.7, 5.3]) * freq
    am = np.array([1.0, 0.5, 0.25, 0.13])
    return sum(a * np.sin(x * f + p) for a, f, p in zip(am, fr, ph)) / am.sum()


def fabric_uv(ob, u, v, name="Fabric", wrap=None):
    """Write analytic per-vertex (u, v) into a UV layer, un-wrapping faces that straddle
    a seam (wrap = period of u in metres)."""
    me = ob.data
    if name not in me.uv_layers:
        me.uv_layers.new(name=name)
    uvl = me.uv_layers[name].data
    for p in me.polygons:
        vs = list(p.vertices)
        us = u[vs].copy()
        if wrap is not None:
            per = wrap[vs]
            ref = us[0]
            for i in range(len(us)):
                if per[i] > 0:
                    while us[i] - ref > per[i] / 2:
                        us[i] -= per[i]
                    while us[i] - ref < -per[i] / 2:
                        us[i] += per[i]
        for li, uu, vi in zip(p.loop_indices, us, vs):
            uvl[li].uv = (uu, v[vi])


# ------------------------------------------------------------------ hoodie

def arm_bones(rig):
    out = {}
    for side in ("l", "r"):
        out[side] = (bone(rig, f"upperarm_{side}")[0], bone(rig, f"lowerarm_{side}")[0], bone(rig, f"hand_{side}")[0])
    return out


def hoodie_dims(rig):
    hip = bone(rig, "thigh_l")[0]
    neck = bone(rig, "neck_01")[0]
    arm = arm_bones(rig)
    wrist_t = {s: np.linalg.norm(arm[s][1] - arm[s][0]) + np.linalg.norm(arm[s][2] - arm[s][1]) - 0.012 for s in "lr"}
    return dict(z_hem=hip[2] - 0.035, z_col_back=neck[2] - 0.015, z_col_front=neck[2] - 0.04, neck=neck, arm=arm,
                wrist_t=wrist_t)


def hoodie_keep(body, rig, lab):
    """Body vertices the hoodie is cut from (torso between hem and neckline, arms to the wrist)."""
    co = verts_np(body)
    z = co[:, 2]
    d = hoodie_dims(rig)
    front = sstep(0.02, -0.06, co[:, 1] - d["neck"][1])
    z_col = d["z_col_back"] * (1 - front) + d["z_col_front"] * front
    keep = (lab == "torso") & (z > d["z_hem"]) & (z < z_col)
    for side in ("l", "r"):
        ax = axis_coords(co, list(d["arm"][side]), (0, 0, 1))
        keep |= (lab == f"arm_{side}") & (ax["t"] < d["wrist_t"][side])
    return keep


def build_hoodie(body, rig, lab, coll, keep=None, ref=None):
    """ref (the female): the male's cut mask, so both hoodies share one topology (and one
    baked texture), and the male's dimensions, which put the sculpted folds on the same
    vertices (fold patterns are evaluated in his proportions)."""
    co = verts_np(body)
    z = co[:, 2]
    d = hoodie_dims(rig)
    hip = bone(rig, "thigh_l")[0]
    neck = d["neck"]
    z_hem, z_col_back, z_col_front = d["z_hem"], d["z_col_back"], d["z_col_front"]
    arm = d["arm"]
    wrist_t = d["wrist_t"]
    if keep is None:
        keep = hoodie_keep(body, rig, lab)
    hood = garment_from_body(body, "Hoodie", keep, coll)
    laplacian(hood, 10, 0.8)
    laplacian(hood, 10, 0.8)
    neck_y = neck[1]

    def col_z(c):
        fr = sstep(0.02, -0.06, c[:, 1] - neck_y)
        return z_col_back * (1 - fr) + z_col_front * fr

    rules = [
        (lambda c: np.abs(c[:, 2] - z_hem) < 0.03, lambda c: np.column_stack([c[:, 0], c[:, 1], np.full(len(c), z_hem)])),
        (lambda c: (c[:, 2] > z_col_front - 0.04) & (np.abs(c[:, 0]) < 0.12), lambda c: np.column_stack([c[:, 0], c[:, 1], col_z(c)])),
    ]
    for side in ("l", "r"):
        ua, la, ha = arm[side]
        sx = 1 if side == "l" else -1
        rules.append((lambda c, sx=sx, ha=ha: (c[:, 0] * sx > 0.3) & (np.linalg.norm(c - ha, axis=1) < 0.09),
                      axis_snap([ua, la, ha], wrist_t[side])))
    snap_openings(hood, rules)

    co = verts_np(hood)
    hl = lab[keep]
    x, y, z = co.T
    out = co.copy()
    # --- torso: cylinder around a vertical axis through the chest centre
    tm = hl == "torso"
    yc = binned_mean(y[tm], z[tm], 40, z_hem, z_col_back + 0.05)
    ctr = np.stack([np.zeros(tm.sum()), yc, z[tm]], 1)
    rad = co[tm] - ctr
    r = np.linalg.norm(rad[:, :2], axis=1)
    th = np.arctan2(rad[:, 0], -rad[:, 1])  # 0 = front
    radu = np.stack([rad[:, 0], rad[:, 1], np.zeros_like(r)], 1) / np.maximum(r, 1e-6)[:, None]
    z_chest = 1.30
    zf = z[tm]           # the height the fold patterns are evaluated at
    if ref is not None:
        # chest line and fold heights in the male's proportions (same vertices, same folds)
        k = (ref["z_col_back"] - ref["z_hem"]) / (z_col_back - z_hem)
        z_chest = z_hem + (1.30 - ref["z_hem"]) / k
        zf = ref["z_hem"] + (z[tm] - z_hem) * k
    # drape: below the chest the fabric hangs from the widest point above it
    nb = 48
    tb = ((th + np.pi) / (2 * np.pi) * nb).astype(int) % nb
    zb = np.clip(((z[tm] - z_hem) / (z_col_back - z_hem) * 40).astype(int), 0, 39)
    grid = np.zeros((nb, 40))
    np.maximum.at(grid, (tb, zb), r)
    # the fabric hangs from the chest band only (not from the shoulders)
    zc_bin = int((z_chest - z_hem) / (z_col_back - z_hem) * 40)
    chest_r = grid[:, max(0, zc_bin - 3):zc_bin + 1].max(1)
    chest_r = (chest_r + np.roll(chest_r, 1) + np.roll(chest_r, -1)) / 3
    # at the sides (under the arms) the drape is weak
    frontback = np.abs(np.cos(th))
    r_hang = chest_r[tb] * (0.965 - 0.03 * sstep(z_chest - 0.1, z_hem, z[tm]))
    below = sstep(z_chest, z_chest - 0.12, z[tm]) * (0.35 + 0.65 * frontback)
    r_new = np.maximum(r, r_hang) * below + r * (1 - below)
    inflate = 0.013 + 0.006 * below
    # ribbed waistband pulls in at the hem
    band = sstep(z_hem + 0.07, z_hem + 0.02, z[tm])
    r_new = r_new + inflate - band * 0.004
    # drape folds (vertical) and bunching over the waistband
    fold = 0.0035 * np.sin(th * 7 + 1.5 * noise1(zf * 8, 3)) * below * (1 - band)
    fold += 0.0012 * np.sin(zf * 2 * np.pi / 0.04 + 2.5 * noise1(th * 2, 4)) * sstep(z_hem + 0.13, z_hem + 0.07, z[tm]) * (1 - band) * (0.3 + 0.7 * np.abs(np.sin(th * 2.5)))
    # diagonal folds from under the arms
    side = np.abs(np.sin(th))
    fold += 0.004 * np.sin((zf * 30 + np.abs(th) * 3.0)) * sstep(0.6, 0.95, side) * sstep(z_chest + 0.05, z_chest - 0.1, z[tm])
    r_new += fold
    out[tm] = ctr + radu * r_new[:, None] + np.stack([np.zeros_like(r), np.zeros_like(r), np.zeros_like(r)], 1)
    out[tm, 2] = z[tm]
    fu = np.zeros(len(co)); fv = np.zeros(len(co)); per = np.zeros(len(co))
    fu[tm] = th * 0.16 + 0.6
    fv[tm] = z[tm]
    per[tm] = 2 * np.pi * 0.16
    # --- sleeves
    for side in ("l", "r"):
        am = hl == f"arm_{side}"
        ua, la, ha = arm[side]
        ax = axis_coords(co[am], [ua, la, ha], (0, 0, 1))
        t = ax["t"]; L = wrist_t[side]
        tn = t / L
        r = ax["r"]
        rmean = binned_mean(r, t, 30, 0, L)
        # the body cut at the wrist takes in the base of the thumb, far off the forearm
        # axis; clip those outliers so the cuff is a clean ring, not a hanging flap
        r = np.minimum(r, rmean * (1.35 - 0.25 * sstep(0.8, 0.92, tn)))
        r_round = r * 0.55 + rmean * 0.45
        r_min = np.interp(tn, [0, 0.2, 0.45, 0.8, 0.92, 1.0], [0.07, 0.062, 0.056, 0.05, 0.041, 0.037])
        s_str = sstep(0.04, 0.2, tn)
        r_t = np.maximum(r_round + 0.012, r_min)
        cuff = sstep(0.9, 0.96, tn)
        r_t = r_t * (1 - cuff) + np.maximum(r_round + 0.006, 0.036) * cuff
        elbow = np.linalg.norm(la - ua) / L
        th = ax["theta"]
        tf = t if ref is None else t * (ref["wrist_t"][side] / L)     # folds in the male's arm length
        f = 0.0045 * np.sin(tf * 2 * np.pi / 0.035 + 2.2 * noise1(th, 7 + (side == "r"))) * np.exp(-((tn - elbow) / 0.08) ** 2)
        f += 0.005 * np.sin(tf * 2 * np.pi / 0.028 + 2.5 * noise1(th * 1.3, 9 + (side == "r"))) * sstep(0.62, 0.8, tn) * (1 - cuff)
        f += 0.003 * np.sin(th * 3 + tf * 20) * sstep(0.1, 0.3, tn) * sstep(0.55, 0.4, tn)
        r_t = r_t + f
        r_final = r * (1 - s_str) + r_t * s_str + 0.012 * (1 - s_str)
        sub = ax["foot"] + ax["rad"] * r_final[:, None]
        # the cut at the wrist is a clean ring: nothing may reach past it onto the hand
        # (a ragged tongue there is skinned to the hand and flaps when the wrist bends)
        over = t > L
        if over.any():
            sub[over] = axis_snap([ua, la, ha], L)(sub[over])
        out[am] = sub
        fu[am] = th * 0.055 + (1.9 if side == "l" else 2.4)
        fv[am] = t
        per[am] = 2 * np.pi * 0.055
    set_verts(hood, out)
    smooth(hood, 2, 0.5)
    final_rules = [(lambda c: np.abs(c[:, 2] - z_hem) < 0.02, lambda c: np.column_stack([c[:, 0], c[:, 1], np.full(len(c), z_hem)])),
                   (lambda c: (c[:, 2] > z_col_front - 0.04) & (np.abs(c[:, 0]) < 0.12), lambda c: np.column_stack([c[:, 0], c[:, 1], col_z(c)]))]
    for side in ("l", "r"):
        ua, la, ha = arm[side]
        sx = 1 if side == "l" else -1
        final_rules.append((lambda c, sx=sx, ha=ha: (c[:, 0] * sx > 0.3) & (np.linalg.norm(c - ha, axis=1) < 0.09),
                            axis_snap([ua, la, ha], wrist_t[side])))
    snap_openings(hood, final_rules)
    fabric_uv(hood, fu, fv, wrap=per)
    rim(hood, 0.007)
    return hood, dict(z_hem=z_hem, z_col_back=z_col_back, z_col_front=z_col_front, wrist_t=wrist_t)


def build_hood(body, rig, hoodie, info, coll):
    """Collapsed hood: a padded roll around the neckline and a pillow lying on the back."""
    neck = bone(rig, "neck_01")[0]
    co = verts_np(body)
    ring = co[(np.abs(co[:, 2] - info["z_col_back"]) < 0.01)]
    ring = ring[np.linalg.norm(ring[:, :2] - neck[:2], axis=1) < 0.12]
    cx, cy = neck[0], ring[:, 1].mean() if len(ring) else neck[1]
    rx = np.abs(ring[:, 0]).max() + 0.018 if len(ring) else 0.075
    ry_back = ring[:, 1].max() - cy + 0.02 if len(ring) else 0.07
    ry_front = cy - ring[:, 1].min() + 0.02 if len(ring) else 0.07
    verts, faces = [], []
    nu, nv = 56, 14
    # angle a: 0 = front centre, +-pi = back centre; the roll opens slightly at the front
    a_span = np.linspace(np.pi * 0.10, np.pi * 1.90, nu)
    for i, a in enumerate(a_span):
        back = (1 - np.cos(a)) / 2  # 0 front, 1 back
        ry = ry_front * (1 - back) + ry_back * back
        px = cx + np.sin(a) * rx
        py = cy - np.cos(a) * ry
        zc = info["z_col_back"] * back + info["z_col_front"] * (1 - back) + 0.005
        tube = 0.012 + 0.03 * back ** 1.3
        out_dir = np.array([np.sin(a) * ry, -np.cos(a) * rx, 0.0])
        out_dir /= np.linalg.norm(out_dir)
        for j in range(nv):
            b = j / nv * 2 * np.pi
            # flattened section: a fold of fleece lying on the shoulders, not a round tube
            p = np.array([px, py, zc]) + out_dir * (tube * 1.25 * (np.cos(b) + 0.75)) + np.array([0, 0, 1]) * tube * 0.42 * np.sin(b)
            verts.append(p)
    for i in range(nu - 1):
        for j in range(nv):
            a = i * nv + j; b = i * nv + (j + 1) % nv
            faces.append((a, b, b + nv, a + nv))
    # caps at both front ends of the roll
    for i0 in (0, nu - 1):
        c = len(verts)
        verts.append(np.mean(verts[i0 * nv:(i0 + 1) * nv], axis=0))
        for j in range(nv):
            a = i0 * nv + j; b = i0 * nv + (j + 1) % nv
            faces.append((a, b, c) if i0 else (b, a, c))
    roll = C.mesh_object("HoodRoll", verts, faces, coll, smooth=True)
    # the hood itself lies on the back: a smooth parametric panel projected onto the hoodie
    from mathutils.bvhtree import BVHTree
    bvh = C.rest_bvh(hoodie)
    zc = info["z_col_back"]
    nu_, nv_ = 26, 18
    pv, pf = [], []
    for j in range(nv_ + 1):
        v = j / nv_
        half = 0.14 * (1 - 0.3 * v) * np.sqrt(max(0.0, 1 - max(0.0, (v - 0.65) / 0.35) ** 2)) + 0.004
        for i in range(nu_ + 1):
            u = i / nu_ * 2 - 1
            x = u * half
            zz = zc - 0.025 - v * 0.24
            hit, n, _, _ = bvh.ray_cast(Vector((x, 0.5, zz)), Vector((0, -1, 0)), 1.0)
            if hit is None:
                hit, n = Vector((x, 0.12, zz)), Vector((0, 1, 0))
            eu = math.sin(min(1.0, (1 - abs(u)) * 1.6) * math.pi / 2)
            ev = math.sin(min(1.0, (1 - v) * 2.2) * math.pi / 2) * math.sin(min(1.0, v * 3 + 0.25) * math.pi / 2)
            puff = 0.004 + 0.042 * (eu * ev) ** 0.7 * (0.85 + 0.15 * math.sin(u * 3 + v * 5))
            pv.append(hit + n * puff)
    for j in range(nv_):
        for i in range(nu_):
            a = j * (nu_ + 1) + i
            pf.append((a, a + nu_ + 1, a + nu_ + 2, a + 1))
    pillow = C.mesh_object("HoodBack", pv, pf, coll, smooth=True)
    smooth(pillow, 2, 0.5)
    rim(pillow, 0.006)
    for o in (pillow,):
        o.parent = rig
        dt = o.modifiers.new("DT", 'DATA_TRANSFER')
        dt.object = body
        dt.use_vert_data = True
        dt.data_types_verts = {'VGROUP_WEIGHTS'}
        dt.vert_mapping = 'POLYINTERP_NEAREST'
        C.select_only(o)
        bpy.ops.object.datalayout_transfer(modifier="DT")
        bpy.ops.object.modifier_apply(modifier="DT")
        am = o.modifiers.new("Armature", 'ARMATURE')
        am.object = rig
    # weights for the roll from the body
    for o in (roll,):
        o.parent = rig
        dt = o.modifiers.new("DT", 'DATA_TRANSFER')
        dt.object = body
        dt.use_vert_data = True
        dt.data_types_verts = {'VGROUP_WEIGHTS'}
        dt.vert_mapping = 'POLYINTERP_NEAREST'
        C.select_only(o)
        bpy.ops.object.datalayout_transfer(modifier="DT")
        bpy.ops.object.modifier_apply(modifier="DT")
        am = o.modifiers.new("Armature", 'ARMATURE')
        am.object = rig
    return roll, pillow


def build_drawstrings(hoodie, rig, info, coll):
    """Two cords hanging from the neckline with metal aglets."""
    neck = bone(rig, "neck_01")[0]
    bvh = C.rest_bvh(hoodie)
    objs = []
    for s in (-1, 1):
        pts = []
        for i in range(12):
            f = i / 11
            x = s * (0.028 + 0.008 * f) + s * 0.004 * math.sin(f * 5)
            zz = info["z_col_front"] - 0.005 - f * 0.20
            hit, n, _, _ = bvh.ray_cast(Vector((x, -0.4, zz)), Vector((0, 1, 0)), 1.0)
            p = hit + n * 0.006 if hit else Vector((x, -0.12, zz))
            pts.append(p)
        cu = bpy.data.curves.new(f"Drawstring_{'L' if s > 0 else 'R'}", 'CURVE')
        cu.dimensions = '3D'
        sp = cu.splines.new('POLY')
        sp.points.add(len(pts) - 1)
        for p, q in zip(sp.points, pts):
            p.co = (q.x, q.y, q.z, 1)
        cu.bevel_depth = 0.0032
        cu.bevel_resolution = 3
        cu.use_fill_caps = True
        ob = bpy.data.objects.new(cu.name, cu)
        C.link(ob, coll)
        C.select_only(ob)
        bpy.ops.object.convert(target='MESH')
        ob = bpy.context.object
        # aglet
        bm = bmesh.new()
        bmesh.ops.create_cone(bm, cap_ends=True, segments=10, radius1=0.0036, radius2=0.0036, depth=0.022)
        tipd = (pts[-1] - pts[-2]).normalized()
        rot = tipd.to_track_quat('Z', 'Y').to_matrix().to_4x4()
        bmesh.ops.transform(bm, matrix=rot, verts=bm.verts)
        bmesh.ops.translate(bm, vec=pts[-1] + tipd * 0.011, verts=bm.verts)
        ag = C.bm_to_object(bm, "Aglet", coll, smooth=True)
        for o in (ob, ag):
            o.parent = rig
            g = o.vertex_groups.new(name="spine_03")
            g.add(list(range(len(o.data.vertices))), 1.0, 'REPLACE')
            am = o.modifiers.new("Armature", 'ARMATURE')
            am.object = rig
        objs.append((ob, ag))
    return objs


# ------------------------------------------------------------------ jeans

def leg_bones(rig):
    return {s: (bone(rig, f"thigh_{s}")[0], bone(rig, f"calf_{s}")[0], bone(rig, f"foot_{s}")[0]) for s in "lr"}


def jeans_keep(body, rig, lab):
    co = verts_np(body)
    z = co[:, 2]
    z_waist = bone(rig, "pelvis")[0][2] + 0.075
    keep = (lab == "torso") & (z < z_waist)
    for side, (th_h, ca_h, ft_h) in leg_bones(rig).items():
        keep |= (lab == f"leg_{side}") & (z > ft_h[2] + 0.055)
    return keep


def build_jeans(body, rig, lab, coll, keep=None, ref=None, name="Jeans"):
    co = verts_np(body)
    z = co[:, 2]
    pel = bone(rig, "pelvis")[0]
    hip = bone(rig, "thigh_l")[0]
    z_waist = pel[2] + 0.075
    legs = leg_bones(rig)
    if keep is None:
        keep = jeans_keep(body, rig, lab)
    jeans = garment_from_body(body, name, keep, coll)
    laplacian(jeans, 10, 0.8)
    laplacian(jeans, 8, 0.8)
    rules = [(lambda c: np.abs(c[:, 2] - z_waist) < 0.03, lambda c: np.column_stack([c[:, 0], c[:, 1], np.full(len(c), z_waist)]))]
    for side in ("l", "r"):
        ft = legs[side][2]
        zc = ft[2] + 0.055
        rules.append((lambda c, zc=zc: c[:, 2] < zc + 0.03, lambda c, zc=zc: np.column_stack([c[:, 0], c[:, 1], np.full(len(c), zc)])))
    snap_openings(jeans, rules)
    co = verts_np(jeans)
    jl = lab[keep]
    out = co.copy()
    fu = np.zeros(len(co)); fv = co[:, 2].copy(); per = np.zeros(len(co))
    # pelvis part: gentle inflate
    pm = jl == "torso"
    yc = binned_mean(co[pm, 1], co[pm, 2], 20, hip[2] - 0.2, z_waist)
    ctr = np.stack([np.zeros(pm.sum()), yc, co[pm, 2]], 1)
    rad = co[pm] - ctr; rad[:, 2] = 0
    r = np.linalg.norm(rad, axis=1)
    radu = rad / np.maximum(r, 1e-6)[:, None]
    th = np.arctan2(rad[:, 0], -rad[:, 1])
    band = sstep(z_waist - 0.05, z_waist - 0.01, co[pm, 2])
    under = sstep(hip[2] - 0.07, hip[2] - 0.02, co[pm, 2])  # hidden under the hoodie hem
    out[pm] = ctr + radu * (r + 0.007 - 0.009 * under)[:, None]
    fu[pm] = th * 0.17 + 0.55
    per[pm] = 2 * np.pi * 0.17
    for side in ("l", "r"):
        lm = jl == f"leg_{side}"
        th_h, ca_h, ft_h = legs[side]
        ground = np.array([ft_h[0], ft_h[1] + 0.01, 0.0])
        ax = axis_coords(co[lm], [th_h, ca_h, ft_h, ground], (0, -1, 0))
        t = ax["t"]
        t_knee = np.linalg.norm(ca_h - th_h)
        t_ank = t_knee + np.linalg.norm(ft_h - ca_h)
        # stretch the bottom so the hem stacks on the shoe (body ends above the ankle)
        t_a = t_ank - 0.25
        t_body_end = t.max()
        t_hem = t_ank + 0.028
        stretch = (t_hem - t_a) / max(1e-3, t_body_end - t_a)
        t2 = np.where(t > t_a, t_a + (t - t_a) * stretch, t)
        tn = t2 / t_hem
        r = ax["r"]
        rmean = binned_mean(r, t, 40, 0, t_body_end)
        r_round = r * 0.45 + rmean * 0.55
        r_min = np.interp(t2, [0, 0.15, t_knee, t_knee + 0.2, t_hem], [0.10, 0.088, 0.070, 0.068, 0.067])
        s_str = sstep(0.02, 0.16, tn)
        r_t = np.maximum(r_round + 0.008, r_min)
        thv = ax["theta"]
        sd = 1 if side == "l" else 2
        tf = t2 if ref is None else t2 * (ref["t_hem"][side] / t_hem)    # folds in the male's leg length
        # ankle stacks
        f = 0.0065 * np.sin(tf * 2 * np.pi / 0.032 + 2.8 * noise1(thv, 20 + sd)) * sstep(t_hem - 0.2, t_hem - 0.05, t2)
        # knee: creases behind, soft bulge in front
        back = (1 - np.cos(thv)) / 2
        f += 0.0045 * np.sin(tf * 2 * np.pi / 0.03 + 1.5 * noise1(thv, 22 + sd)) * np.exp(-((t2 - t_knee) / 0.05) ** 2) * (0.3 + 0.7 * back)
        # long twisting drape lines down the shin
        f += 0.0035 * np.sin(thv * 4 + tf * 6 + noise1(tf * 3, 24 + sd)) * sstep(t_knee, t_knee + 0.1, t2)
        # crotch whisker creases (front, top of the thigh)
        f += 0.0025 * np.sin(tf * 2 * np.pi / 0.04 + thv * 2) * sstep(0.35, 0.05, t2) * (1 - back)
        r_t = r_t + f
        r_final = r * (1 - s_str) + r_t * s_str + 0.009 * (1 - s_str)
        fpt = np.zeros_like(co[lm])
        # rebuild foot points for stretched t along the same polyline
        pts = [th_h, ca_h, ft_h, ground]
        cum = [0]
        for a, b in zip(pts[:-1], pts[1:]):
            cum.append(cum[-1] + np.linalg.norm(b - a))
        for k in range(3):
            m = (t2 >= cum[k]) & (t2 <= cum[k + 1] + (1e9 if k == 2 else 0))
            if k == 0:
                m |= t2 < 0
            d = (pts[k + 1] - pts[k]) / np.linalg.norm(pts[k + 1] - pts[k])
            fpt[m] = pts[k] + d * (t2[m] - cum[k])[:, None]
        new = fpt + ax["rad"] * r_final[:, None]
        # keep the original position near the crotch where the two parts meet
        out[lm] = co[lm] * (1 - s_str[:, None]) + new * s_str[:, None] + ax["rad"] * (0.009 * (1 - s_str))[:, None]
        fu[lm] = thv * 0.07 + (1.2 if side == "l" else 1.75)
        fv[lm] = -t2
        per[lm] = 2 * np.pi * 0.07
    set_verts(jeans, out)
    smooth(jeans, 2, 0.5)
    fabric_uv(jeans, fu, fv, wrap=per)
    rim(jeans, 0.006)
    t_hem_all = {s: np.linalg.norm(legs[s][1] - legs[s][0]) + np.linalg.norm(legs[s][2] - legs[s][1]) + 0.028 for s in "lr"}
    return jeans, dict(z_waist=z_waist, legs=legs, t_hem=t_hem_all)


# ------------------------------------------------------------------ shoes

def shoe_profiles(s):
    w = np.interp(s, [0, 0.06, 0.25, 0.5, 0.7, 0.85, 0.94, 1.0],
                  [0.055, 0.074, 0.078, 0.086, 0.104, 0.098, 0.080, 0.0])
    h = np.interp(s, [0, 0.08, 0.22, 0.30, 0.42, 0.5, 0.62, 0.78, 0.9, 0.97, 1.0],
                  [0.100, 0.108, 0.096, 0.098, 0.112, 0.098, 0.080, 0.062, 0.050, 0.040, 0.034])
    return w, h


def build_shoe(body, rig, side, coll, lab, profiles=None, prefix="Shoe", opening=None):
    """profiles(s) -> (width, height) of the upper along the shoe; opening: (s0, s1, top)
    removes the upper's top between s0 and s1 above sin(angle) > top (a hi-top's collar)."""
    shoe_profiles_ = profiles or shoe_profiles
    fh, ft = bone(rig, f"foot_{side}")
    bh, bt = bone(rig, f"ball_{side}")
    co = verts_np(body)
    fm = lab == f"leg_{side}"
    fm &= co[:, 2] < 0.12
    fv = co[fm]
    d = bt - fh
    d[2] = 0
    d /= np.linalg.norm(d)
    lat = np.cross(d, [0, 0, 1])  # points to the character's right for d=-Y
    along = (fv - fh) @ d
    heel = along.min() - 0.012
    toe = along.max() + 0.02
    L = toe - heel
    center_lat = ((fv - fh) @ lat).mean()
    origin = fh + d * heel + lat * center_lat
    origin[2] = 0
    ns, na = 64, 40
    sole_top = 0.028
    verts, faces, uvs = [], [], []
    for i in range(ns + 1):
        s = i / ns
        w, h = shoe_profiles_(s)
        w = max(w, 0.004) * 1.0
        for j in range(na):
            a = j / na * 2 * np.pi
            ca, sa = np.cos(a), np.sin(a)
            ex = 2.6
            px = np.sign(ca) * abs(ca) ** (2 / ex) * w / 2
            pz_n = np.sign(sa) * abs(sa) ** (2 / ex)
            pz = sole_top - 0.004 + (pz_n * 0.5 + 0.5) * (h - sole_top + 0.004)
            # round the toe down, flatten sides a touch
            p = origin + d * (s * L) + lat * px
            p[2] = pz
            verts.append(p)
    for i in range(ns):
        for j in range(na):
            a = i * na + j; b = i * na + (j + 1) % na
            faces.append((a, b, b + na, a + na))
    # close the toe and heel
    upper = C.mesh_object(f"{prefix}Upper_{side.upper()}", verts, faces, coll, smooth=True)
    uvl = upper.data.uv_layers.new(name="UVMap")
    for p in upper.data.polygons:
        for li in p.loop_indices:
            vi = upper.data.loops[li].vertex_index
            i, j = divmod(vi, na)
            uvl.data[li].uv = (i / ns, j / na)
    # fix the wrap seam in u/v: faces with j = na-1 -> j+1 wraps to 0
    for p in upper.data.polygons:
        js = [divmod(upper.data.loops[li].vertex_index, na)[1] for li in p.loop_indices]
        if max(js) == na - 1 and min(js) == 0:
            for li in p.loop_indices:
                u, v = uvl.data[li].uv
                if v < 0.5:
                    uvl.data[li].uv = (u, v + 1.0)
    for p in upper.data.polygons:
        for li in p.loop_indices:
            u, v = uvl.data[li].uv
            uvl.data[li].uv = (u, v / (1 + 1.0 / na))
    C.select_only(upper)
    bpy.ops.object.mode_set(mode='EDIT')
    bpy.ops.mesh.select_all(action='SELECT')
    bpy.ops.mesh.remove_doubles(threshold=0.0015)
    bpy.ops.mesh.select_all(action='DESELECT')
    bpy.ops.mesh.select_non_manifold()
    bpy.ops.mesh.fill_holes(sides=0)
    bpy.ops.object.mode_set(mode='OBJECT')
    if opening is not None:
        s0, s1, top = opening
        bm = bmesh.new()
        bm.from_mesh(upper.data)
        kill = []
        for f in bm.faces:
            c = f.calc_center_median()
            sc = ((np.array(c) - origin) @ d) / L
            wv, hv = shoe_profiles_(min(1.0, max(0.0, sc)))
            if s0 < sc < s1 and c.z > sole_top + (hv - sole_top) * top:
                kill.append(f)
        bmesh.ops.delete(bm, geom=kill, context='FACES')
        bm.to_mesh(upper.data)
        bm.free()
        rim(upper, 0.009, even=False)

    # sole: wider slab with a toe bumper
    verts, faces = [], []
    for i in range(ns + 1):
        s = i / ns
        w, h = shoe_profiles_(s)
        w = max(w + 0.009, 0.01)
        top = sole_top + 0.004 + 0.012 * sstep(0.88, 0.97, s)
        for j in range(na):
            a = j / na * 2 * np.pi
            ca, sa = np.cos(a), np.sin(a)
            ex = 5.0
            px = np.sign(ca) * abs(ca) ** (2 / ex) * w / 2
            pz_n = np.sign(sa) * abs(sa) ** (2 / ex)
            pz = (pz_n * 0.5 + 0.5) * top
            p = origin + d * (s * (L + 0.006) - 0.003) + lat * px
            p[2] = pz
            verts.append(p)
    for i in range(ns):
        for j in range(na):
            a = i * na + j; b = i * na + (j + 1) % na
            faces.append((a, b, b + na, a + na))
    sole = C.mesh_object(f"{prefix}Sole_{side.upper()}", verts, faces, coll, smooth=True)
    uvl = sole.data.uv_layers.new(name="UVMap")
    for p in sole.data.polygons:
        for li in p.loop_indices:
            vi = sole.data.loops[li].vertex_index
            i, j = divmod(vi, na)
            uvl.data[li].uv = (i / ns, j / na)
    C.select_only(sole)
    bpy.ops.object.mode_set(mode='EDIT')
    bpy.ops.mesh.select_all(action='SELECT')
    bpy.ops.mesh.remove_doubles(threshold=0.0015)
    bpy.ops.mesh.select_all(action='DESELECT')
    bpy.ops.mesh.select_non_manifold()
    bpy.ops.mesh.fill_holes(sides=0)
    bpy.ops.object.mode_set(mode='OBJECT')

    # tongue + laces
    parts = []
    tverts, tfaces = [], []
    nt_s, nt_a = 16, 10
    for i in range(nt_s + 1):
        s = 0.40 + 0.22 * i / nt_s
        w, h = shoe_profiles_(s)
        hh = h + 0.006 + 0.012 * sstep(0.47, 0.40, s)
        for j in range(nt_a + 1):
            f = j / nt_a * 2 - 1
            p = origin + d * (s * L) + lat * f * 0.024
            p[2] = hh + 0.004 * (1 - f * f) - 0.006 * f * f
            tverts.append(p)
    for i in range(nt_s):
        for j in range(nt_a):
            a = i * (nt_a + 1) + j
            tfaces.append((a, a + 1, a + nt_a + 2, a + nt_a + 1))
    tongue = C.mesh_object(f"{prefix}Tongue_{side.upper()}", tverts, tfaces, coll, smooth=True)
    rim(tongue, 0.006)
    parts.append(tongue)
    lace_pts = []
    for k in range(6):
        s0 = 0.47 + k * 0.05
        for sgn in (1, -1):
            s1 = s0 + 0.05
            w0, h0 = shoe_profiles_(s0)
            w1, h1 = shoe_profiles_(s1)
            a = origin + d * (s0 * L) + lat * sgn * 0.021
            b = origin + d * (s1 * L) - lat * sgn * 0.021
            a[2] = h0 + 0.004
            b[2] = h1 + 0.004
            if k < 5:
                lace_pts.append((a, b))
    # bow
    s_b = 0.46
    wb, hb = shoe_profiles_(s_b)
    bow_c = origin + d * (s_b * L)
    bow_c[2] = hb + 0.012
    curves = []
    for (a, b) in lace_pts:
        mid = (a + b) / 2
        mid[2] += 0.0035
        curves.append([a, mid, b])
    for sgn in (1, -1):
        loop = []
        for k in range(9):
            ang = k / 8 * 2 * np.pi
            p = bow_c + lat * sgn * (0.014 + 0.011 * np.cos(ang)) + d * (0.009 * np.sin(ang))
            p = p.copy(); p[2] += 0.004 * np.sin(ang) + 0.003
            loop.append(p)
        curves.append(loop)
        tail = [bow_c + lat * sgn * 0.004, bow_c + lat * sgn * 0.012 - d * 0.02 + np.array([0, 0, -0.012]),
                bow_c + lat * sgn * 0.02 - d * 0.03 + np.array([0, 0, -0.03])]
        curves.append(tail)
    cu = bpy.data.curves.new(f"{prefix.replace('Shoe', '')}Laces_{side.upper()}", 'CURVE')
    cu.dimensions = '3D'
    for pts in curves:
        sp = cu.splines.new('NURBS')
        sp.points.add(len(pts) - 1)
        for p, q in zip(sp.points, pts):
            p.co = (q[0], q[1], q[2], 1)
        sp.use_endpoint_u = True
        sp.order_u = 3
    cu.bevel_depth = 0.0022
    cu.bevel_resolution = 2
    cu.resolution_u = 6
    lob = bpy.data.objects.new(cu.name, cu)
    C.link(lob, coll)
    C.select_only(lob)
    bpy.ops.object.convert(target='MESH')
    laces = bpy.context.object
    parts.append(laces)
    # rigid weights: heel/midfoot -> foot bone, toe box -> ball bone
    s_ball = ((bh - fh) @ d - heel) / L
    for o in [upper, sole] + parts:
        o.parent = rig
        for g in list(o.vertex_groups):
            o.vertex_groups.remove(g)
        gf = o.vertex_groups.new(name=f"foot_{side}")
        gb = o.vertex_groups.new(name=f"ball_{side}")
        for v in o.data.vertices:
            s = ((np.array(v.co) - origin) @ d) / L
            wb = float(sstep(s_ball - 0.04, s_ball + 0.06, s))
            if wb < 1:
                gf.add([v.index], 1 - wb, 'REPLACE')
            if wb > 0:
                gb.add([v.index], wb, 'REPLACE')
        am = o.modifiers.new("Armature", 'ARMATURE')
        am.object = rig
    return dict(upper=upper, sole=sole, tongue=tongue, laces=laces, origin=origin, d=d, lat=lat, L=L)


# ------------------------------------------------------------------ body trim

def _neighbour_mean(ob, f):
    """Mean of a per-vertex field over each vertex's edge neighbours."""
    e = np.zeros(len(ob.data.edges) * 2, np.int64)
    ob.data.edges.foreach_get("vertices", e)
    e = e.reshape(-1, 2)
    acc = np.zeros(len(f)); cnt = np.zeros(len(f))
    np.add.at(acc, e[:, 0], f[e[:, 1]]); np.add.at(acc, e[:, 1], f[e[:, 0]])
    np.add.at(cnt, e[:, 0], 1); np.add.at(cnt, e[:, 1], 1)
    return acc / np.maximum(cnt, 1)


def fit_layers(hoodie, jeans, hinfo, margin=0.008):
    """Layer the garments like real clothes: the hoodie hem hangs over the jeans' hips and
    no denim shows through the fleece. Radii are measured with ray casts outward from the
    torso's vertical axis (rest pose, where both garments were built)."""
    from mathutils.bvhtree import BVHTree
    z_hem = hinfo["z_hem"]
    hco = verts_np(hoodie)
    tors = np.abs(hco[:, 0]) < 0.25
    yc_bins = binned_mean(hco[tors, 1], hco[tors, 2], 30, z_hem - 0.05, z_hem + 0.6)

    def axis_y(z):
        idx = np.clip(((z - (z_hem - 0.05)) / 0.65 * 30).astype(int), 0, 29)
        return yc_bins[idx]

    def bvh_of(ob):
        return C.rest_bvh(ob)

    def far_hit(bvh, o, u, maxd=0.45):
        """Distance to the farthest surface along a horizontal ray from inside."""
        far, trav, o = None, 0.0, Vector(o)
        for _ in range(8):
            loc, _n, _i, dist = bvh.ray_cast(o, u, maxd - trav)
            if loc is None:
                break
            trav += dist
            far = trav
            o = loc + u * 1e-4
            trav += 1e-4
        return far

    def first_hit(bvh, o, u, maxd=0.45):
        loc, _n, _i, dist = bvh.ray_cast(Vector(o), u, maxd)
        return dist if loc is not None else None

    # 1) hoodie: flare the lower 20 cm just enough to clear the jeans
    bj = bvh_of(jeans)
    zone = tors & (hco[:, 2] > z_hem - 0.01) & (hco[:, 2] < z_hem + 0.22)
    push = np.zeros(len(hco))
    dirs = np.zeros_like(hco)
    for i in np.nonzero(zone)[0]:
        p = hco[i]
        a = np.array([0.0, axis_y(np.array([p[2]]))[0], p[2]])
        d = p - a; d[2] = 0
        R = np.linalg.norm(d)
        if R < 1e-4:
            continue
        u = Vector(d / R)
        dirs[i] = d / R
        need = 0.0
        for dz in (0.0, -0.03):      # the jeans just below the hem must fit inside it too
            rj = far_hit(bj, (a[0], a[1], p[2] + dz), u)
            if rj is not None:
                need = max(need, rj + margin - R)
        push[i] = min(need, 0.045)
    for _ in range(6):               # spread smoothly so the flare reads as drape, not bumps
        push = np.maximum(push, 0.55 * push + 0.45 * _neighbour_mean(hoodie, push))
    push *= sstep(z_hem + 0.24, z_hem + 0.12, hco[:, 2]) * tors
    hco = hco + dirs * push[:, None]
    set_verts(hoodie, hco)
    # 2) jeans: anything above the hem stays inside the (flared) hoodie
    bh = bvh_of(hoodie)
    jco = verts_np(jeans)
    w_all = sstep(z_hem - 0.03, z_hem + 0.005, jco[:, 2])
    moved = 0
    for i in np.nonzero(w_all > 0)[0]:
        p = jco[i]
        a = np.array([0.0, axis_y(np.array([max(p[2], z_hem)]))[0], p[2]])
        d = p - a; d[2] = 0
        R = np.linalg.norm(d)
        if R < 1e-4:
            continue
        u = Vector(d / R)
        rh = first_hit(bh, (a[0], a[1], max(p[2], z_hem + 0.006)), u)
        if rh is None:
            continue
        lim = rh - margin
        if R > lim:
            jco[i] = a + (d / R) * (R + (lim - R) * w_all[i]) + np.array([0, 0, p[2] - a[2]])
            moved += 1
    set_verts(jeans, jco)
    print(f"[clothes] layering: hoodie hem flared on {int((push > 1e-4).sum())} verts "
          f"(max {push.max() * 100:.1f} cm), {moved} jeans verts tucked inside the hoodie")


def trim_kill(body, rig, lab, hinfo):
    """The skin the original skater's trim deleted (hoodie + jeans + shoes)."""
    co = verts_np(body)
    z = co[:, 2]
    kill = np.zeros(len(co), bool)
    kill |= (lab == "torso") & (z < hinfo["z_col_front"] - 0.045)
    for side in ("l", "r"):
        ua, la, ha = (bone(rig, f"upperarm_{side}")[0], bone(rig, f"lowerarm_{side}")[0], bone(rig, f"hand_{side}")[0])
        ax = axis_coords(co, [ua, la, ha], (0, 0, 1))
        kill |= (lab == f"arm_{side}") & (ax["t"] < hinfo["wrist_t"][side] - 0.045)
        kill |= lab == f"leg_{side}"
    return kill


def trim_body(body, rig, lab, hinfo, jinfo):
    """Delete skin that is fully covered, keeping a margin under each opening."""
    co = verts_np(body)
    z = co[:, 2]
    kill = np.zeros(len(co), bool)
    neck = bone(rig, "neck_01")[0]
    kill |= (lab == "torso") & (z < hinfo["z_col_front"] - 0.045)
    for side in ("l", "r"):
        ua, la, ha = (bone(rig, f"upperarm_{side}")[0], bone(rig, f"lowerarm_{side}")[0], bone(rig, f"hand_{side}")[0])
        ax = axis_coords(co, [ua, la, ha], (0, 0, 1))
        kill |= (lab == f"arm_{side}") & (ax["t"] < hinfo["wrist_t"][side] - 0.045)
        kill |= lab == f"leg_{side}"
    bm = bmesh.new()
    bm.from_mesh(body.data)
    bm.verts.ensure_lookup_table()
    bmesh.ops.delete(bm, geom=[bm.verts[i] for i in np.nonzero(kill)[0]], context='VERTS')
    bm.to_mesh(body.data)
    bm.free()


# ------------------------------------------------------------------ textures

def bake_garment(ob, size, fabric_tile, tile_m, tint, extra=None, ao_objects=()):
    """Unique UV + baked maps (position, fabric uv, AO) -> albedo/normal/roughness in numpy."""
    me = ob.data
    if "UVMap" not in me.uv_layers:
        me.uv_layers.new(name="UVMap")
    # smart project into the bake UV
    C.select_only(ob)
    me.uv_layers.active = me.uv_layers["UVMap"]
    bpy.ops.object.mode_set(mode='EDIT')
    bpy.ops.mesh.select_all(action='SELECT')
    bpy.ops.uv.smart_project(angle_limit=math.radians(60), island_margin=0.004, area_weight=0.0)
    bpy.ops.uv.pack_islands(margin=0.004, rotate=True)
    bpy.ops.object.mode_set(mode='OBJECT')
    # make sure the bake UV is the first layer (UV0 in glTF)
    if me.uv_layers[0].name != "UVMap":
        pass

    def fab_shader(nt):
        uvn = nt.nodes.new('ShaderNodeUVMap'); uvn.uv_map = "Fabric"
        return C.encode_vec(nt, uvn.outputs[0], (0.0, 4.0, 0.0), (1 / 4.0, 1 / 8.0, 1.0))

    def pos_shader(nt):
        g = nt.nodes.new('ShaderNodeNewGeometry')
        return C.encode_vec(nt, g.outputs['Position'], (1.0, 1.0, 0.0), (0.5, 0.5, 0.5))

    fimg = C.float_image("_bake_fab", size)
    C.bake(ob, fimg, fab_shader, samples=1, margin=16)
    fab = C.image_array(fimg)[..., :2] * np.array([4.0, 8.0]) - np.array([0.0, 4.0])
    pimg = C.float_image("_bake_pos", size)
    C.bake(ob, pimg, pos_shader, samples=1, margin=16)
    pos = C.image_array(pimg)[..., :3] * 2 - np.array([1.0, 1.0, 0.0])
    # ambient occlusion from the whole character
    aoimg = C.float_image("_bake_ao", size)
    hidden = []
    for o in bpy.context.view_layer.objects:
        if o.type == 'MESH' and o not in ao_objects and o != ob and not o.hide_render:
            hidden.append(o)
            o.hide_render = True
    bpy.context.scene.world.light_settings.distance = 0.06
    C.bake(ob, aoimg, lambda nt: None if False else _ao_shader(nt), bake_type='AO', samples=24 if not C.FAST else 8, margin=16)
    for o in hidden:
        o.hide_render = False
    ao = C.image_array(aoimg)[..., 0]
    for im in (fimg, pimg, aoimg):
        bpy.data.images.remove(im)

    th, tw = fabric_tile.shape[:2]
    uu = (fab[..., 0] / tile_m) % 1.0
    vv = (fab[..., 1] / tile_m) % 1.0
    col = fabric_tile[(vv * th).astype(int) % th, (uu * tw).astype(int) % tw]
    col = col * np.array(tint)
    lum = C.luminance(fabric_tile)
    hp = C.highpass(lum, 6)
    hp /= hp.std() + 1e-6
    weave = hp[(vv * th).astype(int) % th, (uu * tw).astype(int) % tw]
    height = weave * 0.25
    rough = np.full(col.shape[:2], 0.85, np.float32)
    if extra:
        col, height, rough = extra(col, height, rough, fab, pos)
    ao_s = np.clip(ao, 0, 1)
    col = col * (0.5 + 0.5 * ao_s[..., None])
    return col, height, rough, ao_s


def _ao_shader(nt):
    return None


def jeans_extra(col, height, rough, fab, pos):
    u, v = fab[..., 0], fab[..., 1]
    z = pos[..., 2]
    # outseam: lateral side of each leg (theta = +-pi/2 around the leg axis)
    n_lo = C.resize(C.value_noise(256, 6, 31, 4), col.shape[0])
    fade = 0.25 * sstep(0.35, 0.7, n_lo)
    # knees / thigh fronts fade lighter, hem darker with dirt
    knee = np.exp(-((z - 0.52) / 0.08) ** 2) * 0.5 + np.exp(-((z - 0.72) / 0.12) ** 2) * 0.3
    col = col * (1 + fade[..., None] * 0.4 + knee[..., None] * 0.25)
    col = col + np.array([0.06, 0.06, 0.08]) * knee[..., None] * 0.4
    dirt = sstep(0.16, 0.05, z)
    col = col * (1 - 0.35 * dirt[..., None]) + np.array([0.12, 0.1, 0.08]) * 0.35 * dirt[..., None]
    for c0 in (1.2 + 0.07 * np.pi / 2, 1.2 - 0.07 * np.pi / 2, 1.75 + 0.07 * np.pi / 2, 1.75 - 0.07 * np.pi / 2):
        dseam = np.abs(u - c0)
        seam = np.exp(-(dseam / 0.0025) ** 2)
        stitch = (np.abs(dseam - 0.006) < 0.0012) * ((v / 0.006) % 1 < 0.55)
        col = col * (1 - 0.25 * seam[..., None]) + np.array([0.75, 0.55, 0.25]) * stitch[..., None] * 0.8
        height = height - seam * 1.2 + stitch * 0.6
    # waistband stitching and yoke line
    wb = (np.abs(z - 1.02) < 0.0015) | (np.abs(z - 0.99) < 0.0012)
    col = np.where(wb[..., None], np.array([0.72, 0.52, 0.24]), col)
    rough[:] = 0.88
    return col, height, rough


def hoodie_extra(col, height, rough, fab, pos):
    u, v = fab[..., 0], fab[..., 1]
    z = pos[..., 2]
    # ribbing on cuffs and waistband: vertical ribs
    rib_band = (z < 0.955) & (u < 1.8)
    ribs = np.sin(u / 0.0035 * np.pi) * rib_band
    height = height + ribs * 1.4
    # sleeve cuffs: last 6 cm of each sleeve (fab v = distance along arm)
    cuff = (u > 1.8) & (v > 0.47)
    height = height + np.sin(u / 0.0028 * np.pi) * cuff * 1.4
    col = col * (1 - 0.08 * (rib_band | cuff)[..., None])
    return col, height, rough


def suede_shoe_texture(size=1024):
    """Shoe upper in its own analytic UV (u = heel->toe, v = around the section)."""
    su = C.make_seamless(C.src_array("suede", 1024))
    su = C.resize(su, size)
    tile = np.tile(su, (2, 2, 1))[::2, ::2]
    u = np.linspace(0, 1, size)[None, :].repeat(size, 0)
    v = np.linspace(0, 1, size)[:, None].repeat(size, 1)
    v = 1 - v  # image rows top->bottom
    col = tile * np.array([1.05, 1.02, 1.0])
    ang = v * 2 * np.pi
    side = np.cos(ang)  # +1 lateral side, -1 medial
    top = np.sin(ang)
    # toe cap darker suede, heel counter panel
    toe = sstep(0.78, 0.8, u)
    heel = sstep(0.2, 0.18, u)
    col = col * (1 - 0.3 * toe[..., None]) * (1 - 0.2 * heel[..., None])
    # side stripe: a swoosh-free original 'wave' band in black leather
    band_c = 0.25 + 0.2 * u + 0.05 * np.sin(u * 9)
    stripe = (np.abs(top - (band_c - 0.4)) < 0.1) & (u > 0.18) & (u < 0.72) & (np.abs(side) > 0.3)
    col = np.where(stripe[..., None], np.array([0.03, 0.03, 0.035]), col)
    stitch = np.zeros_like(u, bool)
    for edge in (0.78, 0.2):
        stitch |= (np.abs(u - edge + 0.008) < 0.0015) & ((v * 180) % 1 < 0.5)
    stitch |= ((np.abs(np.abs(top - (band_c - 0.4)) - 0.11) < 0.004) & (u > 0.18) & (u < 0.72) & (np.abs(side) > 0.3)) & ((u * 300) % 1 < 0.5)
    col = np.where(stitch[..., None], np.array([0.85, 0.83, 0.78]), col)
    # eyelets (on top, both sides of the lacing)
    ey = np.zeros_like(u, bool)
    for k in range(7):
        uc = 0.47 + k * 0.05
        for vc in (0.25 - 0.09, 0.25 + 0.09):
            ey |= ((u - uc) ** 2 * 900 + (v - vc) ** 2 * 900) < 0.012
    col = np.where(ey[..., None], np.array([0.02, 0.02, 0.02]), col)
    # scuffs: lighter abrasion near the toe and ollie area on the lateral side
    sc = C.resize(C.value_noise(256, 12, 51, 4), size)
    scuff = sstep(0.6, 0.8, sc) * (sstep(0.6, 0.9, u) * sstep(0.2, 0.8, side) + toe * 0.6)
    col = col * (1 - 0.4 * scuff[..., None]) + np.array([0.62, 0.6, 0.57]) * 0.4 * scuff[..., None]
    col = col * (0.9 + 0.1 * sstep(0, 1, sc)[..., None])
    lum = C.luminance(tile)
    height = C.highpass(lum, 4) * 3 - stitch * 1.0 + ey * -2.0 - stripe * 0.5
    rough = np.where(stripe, 0.45, 0.92)
    return col, height, rough


def sole_texture(size=512):
    u = np.linspace(0, 1, size)[None, :].repeat(size, 0)
    v = 1 - np.linspace(0, 1, size)[:, None].repeat(size, 1)
    ang = v * 2 * np.pi
    s = np.sin(ang)
    rubber = np.array([0.86, 0.84, 0.80])
    col = np.ones((size, size, 3)) * rubber
    stripe = (np.abs(s - 0.1) < 0.12)
    col = np.where(stripe[..., None], np.array([0.12, 0.2, 0.42]), col)
    bottom = s < -0.75
    tread = ((np.sin(u * 180) > 0.2) ^ (np.sin(v * 140 + u * 60) > 0.3)) & bottom
    col = np.where(bottom[..., None], np.array([0.3, 0.28, 0.25]), col)
    n = C.resize(C.value_noise(128, 8, 61, 3), size)
    grime = sstep(0.4, 0.8, n) * (1 - bottom) * 0.35
    col = col * (1 - grime[..., None]) + np.array([0.35, 0.32, 0.28]) * grime[..., None]
    height = tread * 2.0 + (np.sin(u * 700) * (np.abs(s + 0.3) < 0.2)) * 0.5
    rough = np.full((size, size), 0.7)
    return col, height, rough


HOODIE_TINT = (0.78, 0.17, 0.16)


def to_srgb(lin):
    lin = np.clip(lin, 0, 1)
    return np.where(lin <= 0.0031308, lin * 12.92, 1.055 * np.power(lin, 1 / 2.4) - 0.055)


def srgb_to_lin(c):
    return np.where(c <= 0.04045, c / 12.92, ((c + 0.055) / 1.055) ** 2.4)


def material_from_maps(name, col_srgb, height, rough, strength, uv="UVMap", ao=None, colorspace_linear=False):
    a = C.save_png(col_srgb, name + "_albedo")
    n = C.save_png(C.height_to_normal(height, strength), name + "_normal", 'Non-Color')
    r = C.save_png(np.stack([np.ones_like(rough), rough, np.zeros_like(rough)], -1), name + "_rough", 'Non-Color')
    return C.pbr_material(name, base=a, normal=n, rough=r, uv=uv)


def build(body, rig, coll=None):
    coll = coll or C.collection("Skater")
    lab = S_label = classify(body)
    hoodie, hinfo = build_hoodie(body, rig, lab, coll)
    roll, pillow = build_hood(body, rig, hoodie, hinfo, coll)
    strings = build_drawstrings(hoodie, rig, hinfo, coll)
    jeans, jinfo = build_jeans(body, rig, lab, coll)
    fit_layers(hoodie, jeans, hinfo)
    shoes = [build_shoe(body, rig, s, coll, lab) for s in ("l", "r")]
    trim_body(body, rig, lab, hinfo, jinfo)
    return dict(hoodie=hoodie, hood_roll=roll, hood_back=pillow, strings=strings, jeans=jeans,
                shoes=shoes, hinfo=hinfo, jinfo=jinfo)


def texture(parts, size=None):
    size = size or (1024 if C.FAST else 2048)
    if bpy.context.scene.world is None:
        bpy.context.scene.world = bpy.data.worlds.new("World")
    fleece = C.make_seamless(C.src_array("hoodie_fleece", 1024))
    denim = C.make_seamless(C.src_array("denim", 1024))
    mats = {}
    # hoodie body + hood pieces share one fabric material each baked separately
    for key, tile, tm, tint, extra, strength in (
            ("hoodie", fleece, 0.09, HOODIE_TINT, hoodie_extra, 1.2),
            ("jeans", denim, 0.085, (0.42, 0.5, 0.72), jeans_extra, 1.6)):
        ob = parts[key]
        col, height, rough, ao = bake_garment(ob, size, srgb_to_lin(tile), tm, tint, extra)
        mats[key] = material_from_maps(key.capitalize(), to_srgb(col), height, rough, strength * size / 2048)
        C.assign(ob, mats[key])
    # hood pieces reuse the hoodie fleece at their own UVs
    for key in ("hood_roll", "hood_back"):
        ob = parts[key]
        uvs = verts_np(ob)
        if "Fabric" not in ob.data.uv_layers:
            fabric_uv(ob, uvs[:, 0] * 1.0 + uvs[:, 1] * 0.3 + 3.0, uvs[:, 2])
        col, height, rough, ao = bake_garment(ob, size // 2, srgb_to_lin(fleece), 0.09, HOODIE_TINT)
        m = material_from_maps("Hood_" + key, to_srgb(col), height, rough, 1.2 * size / 2048)
        C.assign(ob, m)
    cord = C.pbr_material("Cord", base_color=(0.75, 0.74, 0.7, 1), roughness=0.8)
    metal = C.pbr_material("Aglet", base_color=(0.6, 0.6, 0.62, 1), roughness=0.3, metallic=1.0)
    for s, a in parts["strings"]:
        C.assign(s, cord)
        C.assign(a, metal)
    col, height, rough = suede_shoe_texture(1024 if not C.FAST else 512)
    up_mat = material_from_maps("ShoeUpper", col, height, rough, 1.5)
    col, height, rough = sole_texture(512)
    sole_mat = material_from_maps("ShoeSole", col, height, rough, 1.0)
    lace = C.pbr_material("Laces", base_color=(0.02, 0.02, 0.022, 1), roughness=0.75)
    tongue = C.pbr_material("ShoeTongue", base_color=(0.16, 0.16, 0.17, 1), roughness=0.9)
    for sh in parts["shoes"]:
        C.assign(sh["upper"], up_mat)
        C.assign(sh["sole"], sole_mat)
        C.assign(sh["laces"], lace)
        C.assign(sh["tongue"], tongue)
    return mats
