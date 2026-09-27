"""Skater stage 4: the character builder's wardrobe, fitted to both bodies.

Tops: fleece hoodie, cotton tee, flannel shirt. Bottoms: denim jeans, twill cargo pants,
chino shorts. Shoes: suede low-tops (grey, navy/gum) and canvas hi-tops, with crew socks.
Headwear: none, a rib-knit beanie, a six-panel cap.

The garments that are cut from the body (hoodie, tee, flannel, jeans, cargo, shorts,
socks) carry its skin weights, so they deform with the same skeleton. Both bodies come
from the same MakeHuman base mesh, so every garment is cut from the male body's vertex
masks on both: the two versions of a garment have one topology, one UV layout and share
one set of baked textures (the fold patterns are evaluated in the male's proportions, so
the baked folds and ambient occlusion land on the same fabric). The male hoodie, jeans and
suede shoes are exactly the original skater's (skater_clothes.py).

Layering follows the original hem pass: every top hangs over every bottom (tops flare to
clear all bottoms, bottoms tuck under the hoodie), and the body is never cut: each face
records which garments cover it (a bit mask in the 'cells' colour attribute), and the
game's skin shader drops the faces the worn garments cover. Hair cards record which hats
cover their roots the same way.
"""
import math
import os
import json

import bpy
import bmesh
import numpy as np
from mathutils import Vector, Matrix

from lib import common as C
import skater_skin as S
import skater_clothes as SC

sstep = S.sstep
verts_np, set_verts, bone, axis_coords, axis_snap = SC.verts_np, SC.set_verts, SC.bone, SC.axis_coords, SC.axis_snap
binned_mean, noise1, fabric_uv, snap_openings = SC.binned_mean, SC.noise1, SC.fabric_uv, SC.snap_openings

# ------------------------------------------------------------------ catalogue
# slot -> options, in the builder's order; the first is the default (today's skater)
SLOTS = {
    "top": ["hoodie", "tee", "flannel"],
    "bottom": ["jeans", "cargo", "shorts"],
    "shoes": ["suede", "suede_navy", "hitop"],
    "hat": ["none", "beanie", "cap"],
}
LABELS = {
    "hoodie": "Red fleece hoodie", "tee": "White graphic tee", "flannel": "Green flannel shirt",
    "jeans": "Blue jeans", "cargo": "Olive cargo pants", "shorts": "Khaki chino shorts",
    "suede": "Grey suede low-tops", "suede_navy": "Navy suede low-tops (gum sole)", "hitop": "Black canvas hi-tops",
    "none": "No hat", "beanie": "Mustard rib beanie", "cap": "Navy six-panel cap",
}
# body cells: one bit per coverage class (garments that cover the same skin share one)
CELL_BITS = {"hoodie": 0, "tee": 1, "flannel": 2, "jeans": 3, "cargo": 4, "shorts": 5,
             "shoes_low": 6, "shoes_high": 7, "socks": 8}
COVERS = {"hoodie": ["hoodie"], "tee": ["tee"], "flannel": ["flannel"], "jeans": ["jeans"], "cargo": ["cargo"],
          "shorts": ["shorts"], "suede": ["shoes_low"], "suede_navy": ["shoes_low"], "hitop": ["shoes_high"]}
HAT_BITS = {"beanie": 0, "cap": 1}
def sock_top(rig):
    """Crew socks end at mid-calf: 42% of the way from the ankle to the knee (25.6 cm on him)."""
    f = bone(rig, "foot_l")[0][2]
    return float(f + (bone(rig, "calf_l")[0][2] - f) * 0.42)


# ------------------------------------------------------------------ geometry helpers

def torso_theta(co, yc):
    """Angle round the torso's vertical axis (0 = front, +x = +pi/2)."""
    return np.arctan2(co[:, 0], -(co[:, 1] - yc))


def leg_axis(co, legs, side):
    th_h, ca_h, ft_h = legs[side]
    ground = np.array([ft_h[0], ft_h[1] + 0.01, 0.0])
    return axis_coords(co, [th_h, ca_h, ft_h, ground], (0, -1, 0))


def data_transfer_weights(ob, body):
    """Skin weights from the body (nearest face, interpolated), then an armature modifier."""
    rig = body.parent
    ob.parent = rig
    dt = ob.modifiers.new("DT", 'DATA_TRANSFER')
    dt.object = body
    dt.use_vert_data = True
    dt.data_types_verts = {'VGROUP_WEIGHTS'}
    dt.vert_mapping = 'POLYINTERP_NEAREST'
    C.select_only(ob)
    bpy.ops.object.datalayout_transfer(modifier="DT")
    bpy.ops.object.modifier_apply(modifier="DT")
    am = ob.modifiers.new("Armature", 'ARMATURE')
    am.object = rig


def rigid_weights(ob, rig, groups):
    """groups: {bone: weight array or scalar} per vertex."""
    ob.parent = rig
    for g in list(ob.vertex_groups):
        ob.vertex_groups.remove(g)
    n = len(ob.data.vertices)
    for name, w in groups.items():
        w = np.broadcast_to(np.asarray(w, np.float32), (n,))
        g = ob.vertex_groups.new(name=name)
        for i in range(n):
            if w[i] > 1e-4:
                g.add([i], float(w[i]), 'REPLACE')
    am = ob.modifiers.new("Armature", 'ARMATURE')
    am.object = rig


def neck_ring_y(body, z, neck):
    co = verts_np(body)
    ring = co[(np.abs(co[:, 2] - z) < 0.01)]
    ring = ring[np.linalg.norm(ring[:, :2] - neck[:2], axis=1) < 0.12]
    return float(ring[:, 1].mean()) if len(ring) else float(neck[1])


# ------------------------------------------------------------------ dimensions and masks
# Everything that decides *which* body vertices a garment is cut from, or *which* skin it
# covers, is computed on the male body (the topology reference) and reused on the female.

def top_dims(rig, kind):
    hip = bone(rig, "thigh_l")[0]
    neck = bone(rig, "neck_01")[0]
    arm = SC.arm_bones(rig)
    upper = {s: float(np.linalg.norm(arm[s][1] - arm[s][0])) for s in "lr"}
    wrist = {s: upper[s] + float(np.linalg.norm(arm[s][2] - arm[s][1])) - 0.012 for s in "lr"}
    if kind == "tee":
        # (a body-cut garment cannot hang below the crotch: the hem sits where the hoodie's does)
        return dict(z_hem=hip[2] - 0.036, z_col_back=neck[2] - 0.008, z_col_front=neck[2] - 0.036, neck=neck, arm=arm,
                    sleeve_t={s: upper[s] * 0.62 for s in "lr"}, v_depth=0.0, v_half=0.05)
    # flannel: a shirttail hem (longer front and back), an open collar (a V to the first
    # fastened button), sleeves to the wrist with a buttoned cuff
    return dict(z_hem=hip[2] - 0.028, tail=0.024, z_col_back=neck[2] - 0.012, z_col_front=neck[2] - 0.03, neck=neck,
                arm=arm, sleeve_t=wrist, v_depth=0.075, v_half=0.055)


def neckline_z(co, d):
    """Neckline height per vertex: back to front, and the V opening at the front."""
    neck = d["neck"]
    front = sstep(0.02, -0.06, co[:, 1] - neck[1])
    z = d["z_col_back"] * (1 - front) + d["z_col_front"] * front
    if d["v_depth"] > 0:
        v = np.clip(1 - np.abs(co[:, 0]) / d["v_half"], 0, 1) * front
        z = z - d["v_depth"] * v
    return z


def hem_z(co, d, yc):
    """Hem height per vertex (flannel: the shirttail dips at front and back)."""
    if d.get("tail", 0) <= 0:
        return np.full(len(co), d["z_hem"])
    th = torso_theta(co, yc)
    return d["z_hem"] - d["tail"] * np.cos(th) ** 2 + d["tail"] * 0.5


def top_keep(body, rig, lab, kind):
    co = verts_np(body)
    d = top_dims(rig, kind)
    yc = float(co[(lab == "torso") & (np.abs(co[:, 2] - d["z_hem"]) < 0.05), 1].mean())
    keep = (lab == "torso") & (co[:, 2] > hem_z(co, d, yc)) & (co[:, 2] < neckline_z(co, d))
    for s in "lr":
        ax = axis_coords(co, list(d["arm"][s]), (0, 0, 1))
        keep |= (lab == f"arm_{s}") & (ax["t"] < d["sleeve_t"][s])
    return keep


def bottom_dims(rig, kind):
    legs = SC.leg_bones(rig)
    pel = bone(rig, "pelvis")[0]
    t_knee = {s: float(np.linalg.norm(legs[s][1] - legs[s][0])) for s in "lr"}
    t_ank = {s: t_knee[s] + float(np.linalg.norm(legs[s][2] - legs[s][1])) for s in "lr"}
    d = dict(z_waist=pel[2] + 0.075, legs=legs, t_knee=t_knee, t_ank=t_ank)
    if kind == "shorts":
        d["t_hem"] = {s: t_knee[s] - 0.055 for s in "lr"}     # skate length: just above the knee
    else:
        d["t_hem"] = {s: t_ank[s] + (0.04 if kind == "cargo" else 0.028) for s in "lr"}
    return d


def bottom_keep(body, rig, lab, kind):
    if kind in ("jeans", "cargo"):
        return SC.jeans_keep(body, rig, lab)
    co = verts_np(body)
    d = bottom_dims(rig, kind)
    keep = (lab == "torso") & (co[:, 2] < d["z_waist"])
    for s in "lr":
        ax = leg_axis(co, d["legs"], s)
        keep |= (lab == f"leg_{s}") & (ax["t"] < d["t_hem"][s] + 0.01)
    return keep


def socks_keep(body, rig, lab):
    co = verts_np(body)
    legs = (lab == "leg_l") | (lab == "leg_r")
    # from inside the shoe's top (the leg enters the closed upper at ~10 cm) to mid-calf
    return legs & (co[:, 2] > 0.08) & (co[:, 2] < sock_top(rig) + 0.01)


def kill_masks(body, rig, lab):
    """Per coverage class: the body vertices under the garment, keeping a margin of skin
    inside each opening (a face is covered if any of its vertices is). hoodie | jeans |
    shoes_low together are exactly the original skater's trimmed skin."""
    co = verts_np(body)
    z = co[:, 2]
    torso = lab == "torso"
    legs = (lab == "leg_l") | (lab == "leg_r")
    K = {}
    hd = SC.hoodie_dims(rig)
    k = torso & (z < hd["z_col_front"] - 0.045)
    for s in "lr":
        ax = axis_coords(co, list(hd["arm"][s]), (0, 0, 1))
        k |= (lab == f"arm_{s}") & (ax["t"] < hd["wrist_t"][s] - 0.045)
    K["hoodie"] = k
    for kind in ("tee", "flannel"):
        d = top_dims(rig, kind)
        k = torso & (z < neckline_z(co, d) - 0.04)
        for s in "lr":
            ax = axis_coords(co, list(d["arm"][s]), (0, 0, 1))
            k |= (lab == f"arm_{s}") & (ax["t"] < d["sleeve_t"][s] - 0.045)
        K[kind] = k
    for kind in ("jeans", "cargo", "shorts"):
        d = bottom_dims(rig, kind)
        k = torso & (z < d["z_waist"] - 0.045)
        if kind == "shorts":
            for s in "lr":
                ax = leg_axis(co, d["legs"], s)
                k |= (lab == f"leg_{s}") & (ax["t"] < d["t_hem"][s] - 0.045)
        else:
            k |= legs                    # full length: down into the shoes (as the original trim)
        K[kind] = k
    K["shoes_low"] = legs & (z < 0.075)
    K["shoes_high"] = legs & (z < 0.125)
    K["socks"] = legs & (z < sock_top(rig) - 0.04)
    return K


def reference(prof_male):
    """Cut masks, cover masks and the dimensions the fold patterns use, from the male body
    (built on its own, stage 1 only; the scene is reset afterwards)."""
    import skater_body
    C.reset_scene()
    coll = C.collection("Reference")
    rig, body, helpers = skater_body.build(coll, prof_male)
    lab = SC.classify(body)
    keep = {"hoodie": SC.hoodie_keep(body, rig, lab), "tee": top_keep(body, rig, lab, "tee"),
            "flannel": top_keep(body, rig, lab, "flannel"), "jeans": SC.jeans_keep(body, rig, lab),
            "cargo": bottom_keep(body, rig, lab, "cargo"), "shorts": bottom_keep(body, rig, lab, "shorts"),
            "socks": socks_keep(body, rig, lab)}
    hd = SC.hoodie_dims(rig)
    dims = {"hoodie": dict(z_hem=hd["z_hem"], z_col_back=hd["z_col_back"], wrist_t=hd["wrist_t"])}
    for kind in ("tee", "flannel"):
        d = top_dims(rig, kind)
        dims[kind] = dict(z_hem=d["z_hem"], z_col_back=d["z_col_back"], sleeve_t=d["sleeve_t"])
    for kind in ("jeans", "cargo", "shorts"):
        d = bottom_dims(rig, kind)
        dims[kind] = dict(t_hem=d["t_hem"], t_knee=d["t_knee"])
    import anims
    dims["body"] = body_dims(body, rig, lab)
    ref = dict(keep=keep, kill=kill_masks(body, rig, lab), dims=dims, lab=lab, rest_rot=anims.rest_rotations(rig))
    C.reset_scene()
    return ref


def body_dims(body, rig, lab):
    """Leg length (hip to ankle), ankle height and foot length: what the animation re-solve
    scales by."""
    th = bone(rig, "thigh_l")[0]
    ft, fb = bone(rig, "foot_l")[0], bone(rig, "ball_l")[0]
    co = verts_np(body)
    fv = co[(lab == "leg_l") & (co[:, 2] < 0.12)]
    d = fb - ft
    d[2] = 0
    d /= np.linalg.norm(d)
    along = (fv - ft) @ d
    return dict(leg=float(np.linalg.norm(th - ft)), ankle_h=float(ft[2]), foot_len=float(along.max() - along.min()))


# ------------------------------------------------------------------ tops: tee and flannel

def build_top(body, rig, lab, coll, kind, keep=None, ref=None):
    """A cotton tee (crew neck, short loose sleeves) or a flannel shirt (open collar,
    shirttail hem, long sleeves with cuffs), cut from the body and draped: straight-hanging
    from the chest, tube sleeves, folds sculpted at the armpits, elbows and cuffs."""
    name = "Tee" if kind == "tee" else "Flannel"
    co = verts_np(body)
    d = top_dims(rig, kind)
    neck = d["neck"]
    arm = d["arm"]
    sleeve_t = d["sleeve_t"]
    if keep is None:
        keep = top_keep(body, rig, lab, kind)
    tm0 = (lab == "torso") & keep
    yc0 = float(co[(lab == "torso") & (np.abs(co[:, 2] - d["z_hem"]) < 0.05), 1].mean())
    ob = SC.garment_from_body(body, name, keep, coll)
    SC.laplacian(ob, 10, 0.8)
    SC.laplacian(ob, 10, 0.8)
    z_hem = d["z_hem"]
    z_top = d["z_col_back"]

    def rules():
        r = [(lambda c: (c[:, 2] < z_hem + 0.06) & (np.abs(c[:, 0]) < 0.3),
              lambda c: np.column_stack([c[:, 0], c[:, 1], hem_z(c, d, yc0)])),
             # (smoothing pulls the open neckline down several cm: catch all of it)
             (lambda c: (c[:, 2] > neckline_z(c, d) - 0.1) & (np.abs(c[:, 0]) < 0.14) & (c[:, 2] > z_hem + 0.25),
              lambda c: np.column_stack([c[:, 0], c[:, 1], neckline_z(c, d)]))]
        for s in "lr":
            ua, la, ha = arm[s]
            sx = 1 if s == "l" else -1
            end = ha if kind == "flannel" else la
            r.append((lambda c, sx=sx, ua=ua, la=la, ha=ha, st=sleeve_t[s]:
                      (c[:, 0] * sx > 0.18) & (np.abs(axis_coords(c, [ua, la, ha], (0, 0, 1))["t"] - st) < 0.05),
                      axis_snap([ua, la, ha], sleeve_t[s])))
        return r

    snap_openings(ob, rules())
    co = verts_np(ob)
    hl = lab[keep]
    x, y, z = co.T
    out = co.copy()
    fu = np.zeros(len(co)); fv = np.zeros(len(co)); per = np.zeros(len(co))
    # --- torso
    tm = hl == "torso"
    yc = binned_mean(y[tm], z[tm], 40, z_hem - 0.05, z_top + 0.05)
    ctr = np.stack([np.zeros(tm.sum()), yc, z[tm]], 1)
    rad = co[tm] - ctr
    r = np.linalg.norm(rad[:, :2], axis=1)
    th = np.arctan2(rad[:, 0], -rad[:, 1])
    radu = np.stack([rad[:, 0], rad[:, 1], np.zeros_like(r)], 1) / np.maximum(r, 1e-6)[:, None]
    span = z_top - z_hem
    z_chest = z_hem + 0.62 * span
    zf = z[tm] if ref is None else ref["z_hem"] + (z[tm] - z_hem) * ((ref["z_col_back"] - ref["z_hem"]) / span)
    nb, nz = 48, 40
    tb = ((th + np.pi) / (2 * np.pi) * nb).astype(int) % nb
    zb = np.clip(((z[tm] - (z_hem - 0.05)) / (span + 0.05) * nz).astype(int), 0, nz - 1)
    grid = np.zeros((nb, nz))
    np.maximum.at(grid, (tb, zb), r)
    zc_bin = int((z_chest - (z_hem - 0.05)) / (span + 0.05) * nz)
    chest_r = grid[:, max(0, zc_bin - 3):zc_bin + 1].max(1)
    chest_r = (chest_r + np.roll(chest_r, 1) + np.roll(chest_r, -1)) / 3
    frontback = np.abs(np.cos(th))
    r_hang = chest_r[tb] * (0.975 - 0.02 * sstep(z_chest - 0.1, z_hem, z[tm]))
    below = sstep(z_chest, z_chest - 0.12, z[tm]) * (0.35 + 0.65 * frontback)
    r_new = np.maximum(r, r_hang) * below + r * (1 - below)
    light = kind == "tee"
    r_new = r_new + (0.009 if light else 0.011) + 0.004 * below
    fold = (0.0028 if light else 0.0032) * np.sin(th * 7 + 1.4 * noise1(zf * 8, 31)) * below
    fold += 0.0008 * np.sin(zf * 2 * np.pi / 0.05 + 2.0 * noise1(th * 2, 32)) * sstep(z_hem + 0.1, z_hem + 0.03, z[tm]) * (0.3 + 0.7 * np.abs(np.sin(th * 2.5)))
    side = np.abs(np.sin(th))
    fold += 0.0035 * np.sin(zf * 28 + np.abs(th) * 3.0) * sstep(0.6, 0.95, side) * sstep(z_chest + 0.05, z_chest - 0.1, z[tm])
    if not light:
        # the button placket stands a touch proud of the front
        fold += 0.0015 * sstep(0.03, 0.012, np.abs(co[tm, 0])) * sstep(0.0, 0.4, np.cos(th))
    out[tm] = ctr + radu * (r_new + fold)[:, None]
    out[tm, 2] = z[tm]
    fu[tm] = th * 0.16 + 0.6
    fv[tm] = z[tm]
    per[tm] = 2 * np.pi * 0.16
    # --- sleeves
    for s in "lr":
        am = hl == f"arm_{s}"
        ua, la, ha = arm[s]
        ax = axis_coords(co[am], [ua, la, ha], (0, 0, 1))
        t = ax["t"]; L = sleeve_t[s]
        tn = t / L
        rr = ax["r"]
        rmean = binned_mean(rr, t, 30, 0, L)
        rr = np.minimum(rr, rmean * (1.35 - 0.25 * sstep(0.8, 0.92, tn)))
        r_round = rr * 0.55 + rmean * 0.45
        tf = t if ref is None else t * (ref["sleeve_t"][s] / L)
        thv = ax["theta"]
        sd = 40 + (s == "r")
        if light:
            r_min = np.interp(tn, [0, 0.35, 0.7, 1.0], [0.068, 0.064, 0.062, 0.06])
            r_t = np.maximum(r_round + 0.01, r_min)
            f = 0.0032 * np.sin(thv * 3 + tf * 18 + noise1(tf * 6, sd)) * sstep(0.05, 0.3, tn)
            f += 0.002 * np.sin(tf * 2 * np.pi / 0.04 + 2.0 * noise1(thv, sd + 2)) * sstep(0.6, 0.95, tn)
        else:
            r_min = np.interp(tn, [0, 0.2, 0.45, 0.8, 0.9, 1.0], [0.068, 0.06, 0.054, 0.048, 0.04, 0.036])
            r_t = np.maximum(r_round + 0.011, r_min)
            cuff = sstep(0.9, 0.94, tn)
            r_t = r_t * (1 - cuff) + np.maximum(r_round + 0.005, 0.035) * cuff
            elbow = np.linalg.norm(la - ua) / L
            f = 0.004 * np.sin(tf * 2 * np.pi / 0.033 + 2.2 * noise1(thv, sd)) * np.exp(-((tn - elbow) / 0.08) ** 2)
            f += 0.0042 * np.sin(tf * 2 * np.pi / 0.03 + 2.4 * noise1(thv * 1.3, sd + 2)) * sstep(0.64, 0.82, tn) * (1 - cuff)
            f += 0.0028 * np.sin(thv * 3 + tf * 20) * sstep(0.1, 0.3, tn) * sstep(0.55, 0.4, tn)
        s_str = sstep(0.04, 0.2, tn)
        r_final = rr * (1 - s_str) + (r_t + f) * s_str + 0.011 * (1 - s_str)
        sub = ax["foot"] + ax["rad"] * r_final[:, None]
        over = t > L
        if over.any():
            sub[over] = axis_snap([ua, la, ha], L)(sub[over])
        out[am] = sub
        fu[am] = thv * 0.06 + (1.9 if s == "l" else 2.4)
        fv[am] = t
        per[am] = 2 * np.pi * 0.06
    set_verts(ob, out)
    SC.smooth(ob, 2, 0.5)
    snap_openings(ob, rules())
    clamp_neckline(ob, d, z_hem)
    relax_boundary(ob, 3)
    fabric_uv(ob, fu, fv, wrap=per)
    SC.rim(ob, 0.004 if light else 0.005, even=False)
    info = dict(kind=kind, z_hem=z_hem, z_hem_max=z_hem + d.get("tail", 0) * 0.5, z_col_back=z_top,
                z_col_front=d["z_col_front"], sleeve_t=sleeve_t, neck=neck, d=d, yc=yc0)
    return ob, info


def clamp_neckline(ob, d, z_hem):
    """Nothing above the neckline: smoothing can lift a vertex next to the cut above its
    snapped edge, which folds the edge into teeth."""
    co = verts_np(ob)
    nz = neckline_z(co, d)
    m = (np.abs(co[:, 0]) < 0.16) & (co[:, 2] > z_hem + 0.2) & (co[:, 2] > nz)
    co[m, 2] = nz[m]
    set_verts(ob, co)


def relax_boundary(ob, iterations=3, factor=0.5):
    """Smooth every open edge loop along itself (a clean hem, cuff and neckline line)."""
    bm = bmesh.new()
    bm.from_mesh(ob.data)
    bm.verts.ensure_lookup_table()
    nb = {}
    for e in bm.edges:
        if e.is_boundary:
            a, b = e.verts[0].index, e.verts[1].index
            nb.setdefault(a, []).append(b)
            nb.setdefault(b, []).append(a)
    bm.free()
    co = verts_np(ob)
    idx = np.array([k for k, v in nb.items() if len(v) == 2], np.int64)
    if len(idx) == 0:
        return
    n0 = np.array([nb[k][0] for k in idx]); n1 = np.array([nb[k][1] for k in idx])
    for _ in range(iterations):
        mid = (co[n0] + co[n1]) / 2
        co[idx] = co[idx] * (1 - factor) + mid * factor
    set_verts(ob, co)


def build_collar(body, top, info, coll):
    """The flannel's collar: a stand round the neckline folding over into a leaf that lies
    on the shoulders, with pointed tips at the open front."""
    d = info["d"]
    neck = info["neck"]
    co = verts_np(top)
    b = SC.boundary_verts(top)
    bc = co[b]
    ring = bc[(bc[:, 2] > d["z_hem"] + 0.2) & (np.abs(bc[:, 0]) < 0.12)]
    yc = neck_ring_y(body, info["z_col_back"], neck)
    ang = np.arctan2(ring[:, 0], ring[:, 1] - yc)          # 0 = back centre, +-pi = front
    order = np.argsort(ang)
    ring, ang = ring[order], ang[order]
    # resample the neckline evenly from one side of the V round the back to the other
    n = 72
    a_s = np.linspace(ang.min(), ang.max(), n)
    pts = np.stack([np.interp(a_s, ang, ring[:, k]) for k in range(3)], 1)
    prof = [(0.000, -0.002), (0.004, 0.012), (0.006, 0.024), (0.012, 0.030), (0.024, 0.022), (0.040, 0.004), (0.050, -0.014)]
    verts = []
    for i, (p, a) in enumerate(zip(pts, a_s)):
        o = np.array([p[0], p[1] - yc, 0.0])
        o /= max(1e-6, np.linalg.norm(o))
        front = float(sstep(1.9, 2.9, abs(a)))                   # towards the front ends
        tip = 1.0 + 0.55 * front                                  # the leaf reaches further: collar points
        for j, (dr, dz) in enumerate(prof):
            k = j / (len(prof) - 1)
            dr2 = dr * (tip if k > 0.5 else 1.0)
            dz2 = dz - (0.012 * front * max(0.0, k - 0.5) * 2)
            verts.append(Vector((p[0] + o[0] * dr2, p[1] + o[1] * dr2, p[2] + dz2)))
    m = len(prof)
    faces = []
    for i in range(n - 1):
        for j in range(m - 1):
            a0 = i * m + j
            faces.append((a0, a0 + 1, a0 + m + 1, a0 + m))
    col = C.mesh_object("Collar", verts, faces, coll, smooth=True)
    uvl = col.data.uv_layers.new(name="UVMap")
    fab = col.data.uv_layers.new(name="Fabric")
    for poly in col.data.polygons:
        for li in poly.loop_indices:
            vi = col.data.loops[li].vertex_index
            i, j = divmod(vi, m)
            uvl.data[li].uv = (i / (n - 1), j / (m - 1))
            fab.data[li].uv = (i / (n - 1) * 0.42, j / (m - 1) * 0.1)
    SC.smooth(col, 1, 0.4)
    SC.rim(col, 0.0035)
    data_transfer_weights(col, body)
    return col


def build_buttons(body, top, info, coll, count=6):
    """Shirt buttons down the placket (and one on each cuff)."""
    from mathutils.bvhtree import BVHTree
    bvh = C.rest_bvh(top)
    d = info["d"]
    z0 = d["z_col_front"] - d["v_depth"] - 0.01
    zs = [z0 - k * 0.085 for k in range(count)]
    bm = bmesh.new()
    for zz in zs:
        if zz < d["z_hem"] + 0.03:
            continue
        hit, n, _, _ = bvh.ray_cast(Vector((0.0, -0.5, zz)), Vector((0, 1, 0)), 1.0)
        if hit is None:
            continue
        geom = bmesh.ops.create_cone(bm, cap_ends=True, segments=14, radius1=0.0058, radius2=0.0052, depth=0.0026)
        vs = geom["verts"]
        rot = Vector(n).to_track_quat('Z', 'Y').to_matrix().to_4x4()
        bmesh.ops.transform(bm, matrix=rot, verts=vs)
        bmesh.ops.translate(bm, vec=hit + Vector(n) * 0.0022, verts=vs)
    ob = C.bm_to_object(bm, "Buttons", coll, smooth=False)
    data_transfer_weights(ob, body)
    return ob


def build_crew_band(body, top, info, coll):
    """The tee's ribbed crew-neck band, rolled round the neckline."""
    neck = info["neck"]
    co = verts_np(top)
    b = SC.boundary_verts(top)
    bc = co[b]
    ring = bc[(bc[:, 2] > info["z_hem"] + 0.2) & (np.abs(bc[:, 0]) < 0.14)]
    yc = neck_ring_y(body, info["z_col_back"], neck)
    ang = np.arctan2(ring[:, 0], ring[:, 1] - yc)
    order = np.argsort(ang)
    ring, ang = ring[order], ang[order]
    n = 80
    a_s = np.linspace(-np.pi, np.pi, n, endpoint=False)
    # periodic interpolation of the neckline, smoothed along the loop
    A = np.concatenate([ang - 2 * np.pi, ang, ang + 2 * np.pi])
    R = np.concatenate([ring, ring, ring])
    pts = np.stack([np.interp(a_s, A, R[:, k]) for k in range(3)], 1)
    for _ in range(4):
        pts = 0.5 * pts + 0.25 * (np.roll(pts, 1, 0) + np.roll(pts, -1, 0))
    prof = [(-0.001, -0.009), (0.0035, -0.004), (0.005, 0.004), (0.003, 0.011), (-0.0015, 0.012), (-0.003, 0.006)]
    verts = []
    for p in pts:
        o = np.array([p[0], p[1] - yc, 0.0])
        o /= max(1e-6, np.linalg.norm(o))
        for dr, dz in prof:
            verts.append(Vector((p[0] + o[0] * dr, p[1] + o[1] * dr, p[2] + dz)))
    m = len(prof)
    faces = []
    for i in range(n):
        i2 = (i + 1) % n
        for j in range(m - 1):
            faces.append((i * m + j, i * m + j + 1, i2 * m + j + 1, i2 * m + j))
    ob = C.mesh_object("CrewBand", verts, faces, coll, smooth=True)
    uvl = ob.data.uv_layers.new(name="UVMap")
    fab = ob.data.uv_layers.new(name="Fabric")
    for poly in ob.data.polygons:
        vis = [ob.data.loops[li].vertex_index for li in poly.loop_indices]
        iis = [v // m for v in vis]
        wrap = max(iis) - min(iis) > 1
        for li, vi in zip(poly.loop_indices, vis):
            i, j = divmod(vi, m)
            if wrap and i == 0:
                i = n
            uvl.data[li].uv = (i / n, j / (m - 1))
            fab.data[li].uv = (i / n * 0.42, j / (m - 1) * 0.03)
    data_transfer_weights(ob, body)
    return ob


# ------------------------------------------------------------------ bottoms: cargo pants and shorts

def build_trousers(body, rig, lab, coll, kind, keep=None, ref=None):
    """Baggy twill cargo pants (stacking on the shoes, a bellows pocket on each thigh) or
    chino shorts ending just above the knee with a wide leg opening. Same construction as
    the jeans: cut from the body, legs re-shaped as tubes round the leg axis, folds
    sculpted at the knees and hems."""
    name = "Cargo" if kind == "cargo" else "Shorts"
    co = verts_np(body)
    d = bottom_dims(rig, kind)
    legs = d["legs"]
    z_waist = d["z_waist"]
    hip = bone(rig, "thigh_l")[0]
    if keep is None:
        keep = bottom_keep(body, rig, lab, kind)
    ob = SC.garment_from_body(body, name, keep, coll)
    SC.laplacian(ob, 10, 0.8)
    SC.laplacian(ob, 8, 0.8)

    def rules(reshaped=False):
        r = [(lambda c: np.abs(c[:, 2] - z_waist) < 0.03, lambda c: np.column_stack([c[:, 0], c[:, 1], np.full(len(c), z_waist)]))]
        for s in "lr":
            th_h, ca_h, ft_h = legs[s]
            ground = np.array([ft_h[0], ft_h[1] + 0.01, 0.0])
            pts = [th_h, ca_h, ft_h, ground]
            if kind == "shorts":
                sx = 1 if s == "l" else -1
                r.append((lambda c, sx=sx, pts=pts, th=d["t_hem"][s]: (c[:, 0] * sx > 0.0) & (c[:, 2] < z_waist - 0.15)
                          & (np.abs(axis_coords(c, pts, (0, -1, 0))["t"] - th) < 0.06),
                          axis_snap(pts, d["t_hem"][s], ref=(0, -1, 0))))
            elif not reshaped:
                # (the cut above the ankle; once the legs are re-shaped the hem is 4 cm past
                # the ankle - snapping it back up to this plane folded the leg's last rows up
                # inside it)
                zc = ft_h[2] + 0.055
                r.append((lambda c, zc=zc: c[:, 2] < zc + 0.03, lambda c, zc=zc: np.column_stack([c[:, 0], c[:, 1], np.full(len(c), zc)])))
        return r

    snap_openings(ob, rules())
    co = verts_np(ob)
    jl = lab[keep]
    # where round each leg a vertex sits comes from the body it was cut from: the smoothing
    # pulls the ankle opening in towards the leg's axis, where the angle is undefined (rows a
    # few mm apart there were thrown to opposite sides of the tube)
    body_co = verts_np(body)[keep]
    # edges from the nearest opening (up to 12)
    e = _edges(ob)
    hops = np.full(len(co), 12)
    front = SC.boundary_verts(ob)
    hops[front] = 0
    for k in range(1, 12):
        nxt = np.zeros(len(co), bool)
        nxt[e[:, 0]] |= hops[e[:, 1]] == k - 1
        nxt[e[:, 1]] |= hops[e[:, 0]] == k - 1
        new_k = nxt & (hops == 12)
        if not new_k.any():
            break
        hops[new_k] = k
    out = co.copy()
    fu = np.zeros(len(co)); fv = co[:, 2].copy(); per = np.zeros(len(co))
    pm = jl == "torso"
    yc = binned_mean(co[pm, 1], co[pm, 2], 20, hip[2] - 0.2, z_waist)
    ctr = np.stack([np.zeros(pm.sum()), yc, co[pm, 2]], 1)
    rad = co[pm] - ctr; rad[:, 2] = 0
    r = np.linalg.norm(rad, axis=1)
    radu = rad / np.maximum(r, 1e-6)[:, None]
    th = np.arctan2(rad[:, 0], -rad[:, 1])
    under = sstep(hip[2] - 0.07, hip[2] - 0.02, co[pm, 2])       # under the tops' hems
    out[pm] = ctr + radu * (r + 0.009 - 0.009 * under)[:, None]
    fu[pm] = th * 0.17 + 0.55
    per[pm] = 2 * np.pi * 0.17
    info = dict(z_waist=z_waist, legs=legs, t_hem=d["t_hem"], pocket={})
    for s in "lr":
        lm = jl == f"leg_{s}"
        th_h, ca_h, ft_h = legs[s]
        ground = np.array([ft_h[0], ft_h[1] + 0.01, 0.0])
        pts = [th_h, ca_h, ft_h, ground]
        ax = axis_coords(co[lm], pts, (0, -1, 0))
        ax0 = axis_coords(body_co[lm], pts, (0, -1, 0))
        ax = dict(ax, theta=ax0["theta"], rad=ax0["rad"])
        t = ax["t"]
        t_knee = d["t_knee"][s]
        t_hem = d["t_hem"][s]
        if kind == "cargo":
            # no row under the opening: the snap lifted the low parts of the cut's ragged edge
            # up to the opening's plane, above the rows next to them (the leg's last rows then
            # turned up inside it). Each vertex stays above the opening, 5 mm per edge from it.
            bnd = hops[lm] == 0
            t_open = float(np.median(t[bnd])) if bnd.any() else float(t.max())
            t = np.where(t > t_open - 0.06, np.minimum(t, t_open - 0.005 * hops[lm]), t)
            t_ank = d["t_ank"][s]
            t_a = t_ank - 0.25
            t_body_end = t.max()
            stretch = (t_hem - t_a) / max(1e-3, t_body_end - t_a)
            t2 = np.where(t > t_a, t_a + (t - t_a) * stretch, t)
        else:
            t2 = np.minimum(t, t_hem)
        tn = t2 / t_hem
        rr = ax["r"]
        rmean = binned_mean(rr, t, 40, 0, max(t.max(), 1e-3))
        r_round = rr * 0.4 + rmean * 0.6
        tf = t2 if ref is None else t2 * (ref["t_hem"][s] / t_hem)
        thv = ax["theta"]
        sd = 60 + (s == "r")
        back = (1 - np.cos(thv)) / 2
        lateral = (ax["rad"][:, 0] * (1 if s == "l" else -1))      # +1 on the outside of the leg
        if kind == "cargo":
            r_min = np.interp(t2, [0, 0.15, t_knee, t_knee + 0.2, t_hem - 0.06, t_hem], [0.104, 0.098, 0.088, 0.085, 0.08, 0.074])
            r_t = np.maximum(r_round + 0.011, r_min)
            f = 0.008 * np.sin(tf * 2 * np.pi / 0.036 + 2.6 * noise1(thv, sd)) * sstep(t_hem - 0.24, t_hem - 0.06, t2)
            f += 0.005 * np.sin(tf * 2 * np.pi / 0.034 + 1.5 * noise1(thv, sd + 2)) * np.exp(-((t2 - t_knee) / 0.055) ** 2) * (0.3 + 0.7 * back)
            f += 0.004 * np.sin(thv * 3 + tf * 5 + noise1(tf * 3, sd + 4)) * sstep(t_knee, t_knee + 0.1, t2)
            # bellows pocket on the outer thigh: a raised box with a flap, 16 x 19 cm
            p0, p1 = 0.20, 0.39
            across = np.arctan2(ax["rad"][:, 1], np.abs(ax["rad"][:, 0]))    # 0 = straight out sideways
            box = sstep(p0 - 0.01, p0 + 0.008, t2) * sstep(p1 + 0.01, p1 - 0.008, t2) * sstep(0.62, 0.5, np.abs(across)) * (lateral > 0)
            flap = sstep(p0 + 0.045, p0 + 0.04, t2) * box
            f += 0.012 * box + 0.004 * flap
            info["pocket"][s] = (p0, p1)
        else:
            r_min = np.interp(tn, [0, 0.25, 0.7, 1.0], [0.108, 0.1, 0.095, 0.094])
            r_t = np.maximum(r_round + 0.012, r_min)
            f = 0.0035 * np.sin(thv * 5 + tf * 9 + noise1(tf * 4, sd)) * sstep(0.2, 0.6, tn)
            f += 0.003 * np.sin(tf * 2 * np.pi / 0.04 + thv * 2) * sstep(0.4, 0.05, tn) * (1 - back)
            # the turned-up hem: a 3 cm cuff that stands off the leg a little more
            f += 0.003 * sstep(t_hem - 0.035, t_hem - 0.03, t2)
        s_str = sstep(0.02, 0.16, tn)
        r_final = rr * (1 - s_str) + (r_t + f) * s_str + 0.01 * (1 - s_str)
        fpt = np.zeros_like(co[lm])
        cum = [0]
        for a, b in zip(pts[:-1], pts[1:]):
            cum.append(cum[-1] + np.linalg.norm(b - a))
        for k in range(3):
            m = (t2 >= cum[k]) & (t2 <= cum[k + 1] + (1e9 if k == 2 else 0))
            if k == 0:
                m |= t2 < 0
            dd = (pts[k + 1] - pts[k]) / np.linalg.norm(pts[k + 1] - pts[k])
            fpt[m] = pts[k] + dd * (t2[m] - cum[k])[:, None]
        new = fpt + ax["rad"] * r_final[:, None]
        out[lm] = co[lm] * (1 - s_str[:, None]) + new * s_str[:, None] + ax["rad"] * (0.01 * (1 - s_str))[:, None]
        fu[lm] = thv * 0.075 + (1.2 if s == "l" else 1.75)
        fv[lm] = -t2
        per[lm] = 2 * np.pi * 0.075
    set_verts(ob, out)
    SC.smooth(ob, 2, 0.5)
    snap_openings(ob, rules(reshaped=True))
    relax_boundary(ob, 3)
    if kind == "cargo":
        # the fabric runs down the legs as they finally lie (the rows kept above the opening
        # were spread again by the smoothing: their re-shaping arc lengths would squash it)
        fco = verts_np(ob)
        for s in "lr":
            lm = jl == f"leg_{s}"
            th_h, ca_h, ft_h = legs[s]
            pts = [th_h, ca_h, ft_h, np.array([ft_h[0], ft_h[1] + 0.01, 0.0])]
            fv[lm] = -axis_coords(fco[lm], pts, (0, -1, 0))["t"]
    fabric_uv(ob, fu, fv, wrap=per)
    SC.rim(ob, 0.006, even=False)
    return ob, info


def build_socks(body, rig, lab, coll, keep=None):
    top = sock_top(rig)
    """White crew socks with a ribbed cuff, from the ankle to mid-calf (they show with
    shorts; the shoe covers the foot)."""
    if keep is None:
        keep = socks_keep(body, rig, lab)
    ob = SC.garment_from_body(body, "Socks", keep, coll)
    SC.laplacian(ob, 4, 0.5)
    co = verts_np(ob)
    me = ob.data
    n = np.zeros(len(co) * 3, np.float32)
    me.vertices.foreach_get("normal", n)
    n = n.reshape(-1, 3)
    z = co[:, 2]
    cuff = sstep(top - 0.035, top - 0.03, z)
    co = co + n * (0.0026 + 0.0012 * cuff)[:, None]
    set_verts(ob, co)
    snap_openings(ob, [(lambda c: c[:, 2] > top - 0.03, lambda c: np.column_stack([c[:, 0], c[:, 1], np.full(len(c), top)])),
                       (lambda c: c[:, 2] < 0.1, lambda c: np.column_stack([c[:, 0], c[:, 1], np.full(len(c), 0.08)]))])
    relax_boundary(ob, 3)
    # fabric uv: around each leg x height
    fu = np.zeros(len(co)); per = np.zeros(len(co))
    for s, sx in (("l", 1), ("r", -1)):
        m = co[:, 0] * sx > 0
        cx = co[m, :2].mean(0)
        a = np.arctan2(co[m, 0] - cx[0], co[m, 1] - cx[1])
        fu[m] = a * 0.045 + (0.3 if s == "l" else 0.8)
        per[m] = 2 * np.pi * 0.045
    fabric_uv(ob, fu, co[:, 2], wrap=per)
    SC.rim(ob, 0.003, even=False)
    return ob


# ------------------------------------------------------------------ shoes: canvas hi-tops

def hitop_profiles(s):
    """A classic vulcanised canvas hi-top: slimmer toe box, the heel and collar rising
    round the ankle to 15.5 cm."""
    w = np.interp(s, [0, 0.06, 0.25, 0.5, 0.7, 0.85, 0.94, 1.0],
                  [0.058, 0.074, 0.077, 0.084, 0.100, 0.095, 0.078, 0.0])
    h = np.interp(s, [0, 0.05, 0.14, 0.26, 0.36, 0.44, 0.52, 0.62, 0.78, 0.9, 0.97, 1.0],
                  [0.150, 0.158, 0.156, 0.150, 0.140, 0.122, 0.096, 0.078, 0.060, 0.049, 0.040, 0.034])
    return w, h


def build_hitop(body, rig, side, coll, lab):
    sh = SC.build_shoe(body, rig, side, coll, lab, profiles=hitop_profiles, prefix="HiTop",
                       opening=(0.07, 0.43, 0.62))
    # the ankle collar flexes with the shin: blend its upper part towards the calf bone
    up = sh["upper"]
    co = verts_np(up)
    wc = sstep(0.095, 0.155, co[:, 2]) * 0.45
    gf, gb = up.vertex_groups[f"foot_{side}"], up.vertex_groups[f"ball_{side}"]
    gc = up.vertex_groups.new(name=f"calf_{side}")
    for v in up.data.vertices:
        w = float(wc[v.index])
        if w <= 1e-4:
            continue
        wf = 0.0
        for g in v.groups:
            if g.group == gf.index:
                wf = g.weight
        gf.add([v.index], max(0.0, wf * (1 - w)), 'REPLACE')
        gc.add([v.index], w, 'REPLACE')
    return sh


# ------------------------------------------------------------------ headwear

def head_frame(body, face):
    co = verts_np(body)
    hw = S._group_weights(body, "head")
    hv = co[hw > 0.8]
    hc = Vector(((hv.max(0) + hv.min(0)) / 2).tolist())
    eye_z = float((face["eye_L"][0][2] + face["eye_R"][0][2]) / 2)
    y_front = float(hv[:, 1].min())
    y_back = float(hv[:, 1].max())
    return dict(hc=hc, eye_z=eye_z, y_front=y_front, y_back=y_back, top=float(hv[:, 2].max()))


def hat_line(hf, kind):
    """Height of a hat's lower edge as a function of y (front to back), a tilted plane."""
    if kind == "beanie":
        zf, zb = hf["eye_z"] + 0.052, hf["eye_z"] - 0.022
    else:   # cap band: lower at the front (just above the brows), over the ears, the occiput
        zf, zb = hf["eye_z"] + 0.036, hf["eye_z"] - 0.03
    y0, y1 = hf["y_front"], hf["y_back"]
    return lambda y: zf + (zb - zf) * np.clip((np.asarray(y) - y0) / (y1 - y0), 0, 1)


def _scalp_shell(body, hf, line, n_az, n_el, offset):
    """Points over the scalp above `line`: for each azimuth a meridian from the crown down
    to the line, pushed out from the scalp by offset(az, t) (t: 0 crown -> 1 edge)."""
    bvh = C.rest_bvh(body)
    hc = hf["hc"]
    rows = []
    for i in range(n_az):
        az = 2 * math.pi * i / n_az          # 0 = front (-y), +pi/2 = the skater's left (+x)
        dirxy = Vector((math.sin(az), -math.cos(az), 0.0))

        def surf(el):
            d = (dirxy * math.cos(el) + Vector((0, 0, math.sin(el)))).normalized()
            hit, n, _, _ = bvh.ray_cast(hc + d * 0.35, -d, 0.6)
            if hit is None:
                hit, n = hc + d * 0.09, d
            return hit, Vector(n).normalized(), d
        # elevation where the scalp meets the line (bisection)
        lo, hi = math.radians(-40), math.radians(89)
        for _ in range(30):
            mid = (lo + hi) / 2
            p, _, _ = surf(mid)
            if p.z > float(line(p.y)):
                hi = mid
            else:
                lo = mid
        el_edge = hi
        row = []
        for j in range(n_el + 1):
            t = j / n_el
            el = math.radians(89.5) * (1 - t) + el_edge * t
            p, n, d = surf(el)
            row.append((p, d, t, az))
        rows.append(row)
    return rows


def build_beanie(body, hf, coll, rig):
    """A cuffed rib-knit beanie: the crown sits on the (flattened) hair, slouching a little
    at the back, and the cuff is folded up outside."""
    line = hat_line(hf, "beanie")
    n_az, n_el = 72, 26
    rows = _scalp_shell(body, hf, line, n_az, n_el, None)
    verts, uv = [], []
    prof_len = None
    for i, row in enumerate(rows):
        strip = []
        az = row[0][3]
        back = 0.5 - 0.5 * math.cos(az)                  # 0 front, 1 back
        for (p, d, t, _) in row:
            slouch = 0.016 * back * math.sin(min(1.0, t * 1.6) * math.pi) * (1 - t)
            off = 0.0125 + slouch
            strip.append(p + d * off)
        # the folded cuff: out and up the outside of the lower 5 cm
        p_edge, d_edge = row[-1][0], row[-1][1]
        base = strip[-1]
        up = (strip[-1] - strip[-4]).normalized() * -1.0          # back up the crown
        for k, (out, rise) in enumerate(((0.0035, -0.004), (0.0065, 0.002), (0.0068, 0.02), (0.0066, 0.04),
                                         (0.0062, 0.05), (0.0035, 0.055), (0.001, 0.054))):
            strip.append(base + d_edge * out + up * rise)
        verts.append(strip)
    m = len(verts[0])
    flat = [v for strip in verts for v in strip]
    faces = []
    for i in range(n_az):
        i2 = (i + 1) % n_az
        for j in range(m - 1):
            faces.append((i * m + j, i * m + j + 1, i2 * m + j + 1, i2 * m + j))
    # close the crown (the first ring is all but one point)
    ob = C.mesh_object("Beanie", flat, faces, coll, smooth=True)
    _analytic_uv(ob, n_az, m, v_split=n_el)       # (per face corner, before the crown is welded)
    C.select_only(ob)
    bpy.ops.object.mode_set(mode='EDIT')
    bpy.ops.mesh.select_all(action='SELECT')
    bpy.ops.mesh.remove_doubles(threshold=0.0008)
    bpy.ops.mesh.select_all(action='DESELECT')
    bpy.ops.mesh.select_non_manifold()
    bpy.ops.mesh.fill_holes(sides=0)
    bpy.ops.object.mode_set(mode='OBJECT')
    SC.smooth(ob, 1, 0.3)
    rigid_weights(ob, rig, {"head": 1.0})
    return ob, dict(line=line, kind="beanie")


def _analytic_uv(ob, n_az, m, v_split):
    """UVMap: u = round the head, v = down the crown (0..0.72) then up the cuff (0.72..1).
    Fabric: the same in metres-ish (ribs run along v)."""
    me = ob.data
    uvl = me.uv_layers.new(name="UVMap")
    fab = me.uv_layers.new(name="Fabric")
    co = verts_np(ob)
    for poly in me.polygons:
        vis = [me.loops[li].vertex_index for li in poly.loop_indices]
        iis = [min(v // m, n_az - 1) for v in vis]
        wrap = max(iis) - min(iis) > n_az // 2
        for li, vi in zip(poly.loop_indices, vis):
            i, j = divmod(vi, m)
            i = min(i, n_az - 1)
            if wrap and i < n_az // 2:
                i += n_az
            u = i / n_az
            v = (j / v_split) * 0.72 if j <= v_split else 0.72 + (j - v_split) / max(1, m - 1 - v_split) * 0.28
            uvl.data[li].uv = (u, 1 - v)
            fab.data[li].uv = (u * 0.6, v * 0.25)


def build_cap(body, hf, coll, rig):
    """A structured six-panel cap: crown over the hair above a band line, seams and a top
    button, a pre-curved brim, and an opening with a strap at the back."""
    line = hat_line(hf, "cap")
    n_az, n_el = 72, 22
    rows = _scalp_shell(body, hf, line, n_az, n_el, None)
    verts = []
    for i, row in enumerate(rows):
        az = row[0][3]
        front = 0.5 + 0.5 * math.cos(az)
        strip = []
        for (p, d, t, _) in row:
            # structured front panels stand a little proud; seams sink in a touch
            seam = min(abs(((az + math.pi / 6) % (math.pi / 3)) - math.pi / 6), 0.5)
            groove = -0.0009 * math.exp(-(seam / 0.03) ** 2)
            off = 0.0115 + 0.007 * front ** 2 * math.sin(min(1.0, t * 1.3) * math.pi) + groove
            strip.append(p + d * off)
        verts.append(strip)
    m = n_el + 1
    flat = [v for strip in verts for v in strip]
    faces = []
    for i in range(n_az):
        i2 = (i + 1) % n_az
        for j in range(m - 1):
            # the back opening above the strap (az near pi, 2-4.5 cm above the band)
            az_c = 2 * math.pi * (i + 0.5) / n_az
            tj = (j + 0.5) / n_el
            if abs(az_c - math.pi) < math.radians(24) and 0.62 < tj < 0.9:
                continue
            faces.append((i * m + j, i * m + j + 1, i2 * m + j + 1, i2 * m + j))
    crown = C.mesh_object("CapCrown", flat, faces, coll, smooth=True)
    _analytic_uv_cap(crown, n_az, m)
    C.select_only(crown)
    bpy.ops.object.mode_set(mode='EDIT')
    bpy.ops.mesh.select_all(action='SELECT')
    bpy.ops.mesh.remove_doubles(threshold=0.0008)
    bpy.ops.object.mode_set(mode='OBJECT')
    SC.smooth(crown, 1, 0.3)
    SC.rim(crown, 0.004, even=False)
    # the brim: from the front band, forward and curving down at the sides
    n_b, rows_b = 33, 6
    bverts = []
    band = [verts[i][-1] for i in range(n_az)]
    for k in range(n_b):
        a = math.radians(-78 + 156 * k / (n_b - 1))
        ai = (a % (2 * math.pi)) / (2 * math.pi) * n_az
        i0 = int(math.floor(ai)) % n_az
        f = ai - math.floor(ai)
        A = band[i0].lerp(band[(i0 + 1) % n_az], f)
        fwd = Vector((math.sin(a), -math.cos(a), 0.0))
        depth = 0.074 * max(0.0, math.cos(a * 1.05)) ** 0.55 + 0.004
        for r in range(rows_b + 1):
            q = r / rows_b
            dn = (0.006 + 0.022 * (a / math.radians(78)) ** 2) * q ** 1.4 + 0.004 * q
            bverts.append(A + fwd * (depth * q + 0.003) + Vector((0, 0, -dn)))
    bfaces = []
    for k in range(n_b - 1):
        for r in range(rows_b):
            a0 = k * (rows_b + 1) + r
            bfaces.append((a0, a0 + rows_b + 1, a0 + rows_b + 2, a0 + 1))
    brim = C.mesh_object("CapBrim", bverts, bfaces, coll, smooth=True)
    uvl = brim.data.uv_layers.new(name="UVMap")
    fab = brim.data.uv_layers.new(name="Fabric")
    for poly in brim.data.polygons:
        for li in poly.loop_indices:
            vi = brim.data.loops[li].vertex_index
            k, r = divmod(vi, rows_b + 1)
            uvl.data[li].uv = (k / (n_b - 1), 0.3 * r / rows_b)
            fab.data[li].uv = (k / (n_b - 1) * 0.2, r / rows_b * 0.08)
    sol = brim.modifiers.new("Solid", 'SOLIDIFY')
    sol.thickness = 0.0045
    sol.offset = 0.0
    C.select_only(brim)
    bpy.ops.object.modifier_apply(modifier="Solid")
    # top button
    bm = bmesh.new()
    top = verts[0][0]
    bmesh.ops.create_uvsphere(bm, u_segments=12, v_segments=6, radius=0.0075)
    for v in bm.verts:
        v.co.z *= 0.45
    bmesh.ops.translate(bm, vec=top + Vector((0, 0, 0.001)), verts=bm.verts)
    btn = C.bm_to_object(bm, "CapButton", coll, smooth=True)
    bu = btn.data.uv_layers.new(name="UVMap")
    for poly in btn.data.polygons:
        for li in poly.loop_indices:
            bu.data[li].uv = (0.98, 0.98)
    for o in (crown, brim, btn):
        rigid_weights(o, rig, {"head": 1.0})
    cap = C.join([crown, brim, btn], "Cap")
    return cap, dict(line=line, kind="cap")


def _analytic_uv_cap(ob, n_az, m):
    me = ob.data
    uvl = me.uv_layers.new(name="UVMap")
    fab = me.uv_layers.new(name="Fabric")
    for poly in me.polygons:
        vis = [me.loops[li].vertex_index for li in poly.loop_indices]
        iis = [v // m for v in vis]
        wrap = max(iis) - min(iis) > n_az // 2
        for li, vi in zip(poly.loop_indices, vis):
            i, j = divmod(vi, m)
            if wrap and i < n_az // 2:
                i += n_az
            u = i / n_az
            v = j / (m - 1)
            uvl.data[li].uv = (u, 1 - 0.7 * v)
            fab.data[li].uv = (u * 0.6, v * 0.14)


# ------------------------------------------------------------------ layering

def _rest_bvh_many(objs):
    from mathutils.bvhtree import BVHTree
    verts, polys, off = [], [], 0
    for o in objs:
        me = o.data
        verts += [v.co.copy() for v in me.vertices]
        polys += [tuple(i + off for i in p.vertices) for p in me.polygons]
        off += len(me.vertices)
    return BVHTree.FromPolygons(verts, polys, all_triangles=False)


def _torso_axis(co, z_hem):
    tors = np.abs(co[:, 0]) < 0.25
    yb = binned_mean(co[tors, 1], co[tors, 2], 30, z_hem - 0.05, z_hem + 0.6)
    return lambda z: yb[np.clip(((np.asarray(z) - (z_hem - 0.05)) / 0.65 * 30).astype(int), 0, 29)]


def _far_hit(bvh, o, u, maxd=0.45):
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


def flare_top(top, bottoms, z_hem, margin=0.009):
    """The lower 20 cm of a top flares just enough to hang over every bottom (the
    original hem pass, against all the bottoms at once)."""
    co = verts_np(top)
    axis_y = _torso_axis(co, z_hem)
    bvh = _rest_bvh_many(bottoms)
    tors = np.abs(co[:, 0]) < 0.25
    zone = tors & (co[:, 2] > z_hem - 0.04) & (co[:, 2] < z_hem + 0.3)
    push = np.zeros(len(co)); dirs = np.zeros_like(co)
    for i in np.nonzero(zone)[0]:
        p = co[i]
        a = np.array([0.0, float(axis_y(np.array([p[2]]))[0]), p[2]])
        d = p - a; d[2] = 0
        R = np.linalg.norm(d)
        if R < 1e-4:
            continue
        u = Vector(d / R)
        dirs[i] = d / R
        need = 0.0
        for dz in (0.0, -0.03):
            rj = _far_hit(bvh, (a[0], a[1], p[2] + dz), u)
            if rj is not None:
                need = max(need, rj + margin - R)
        push[i] = min(need, 0.045)
    for _ in range(10):
        push = np.maximum(push, 0.55 * push + 0.45 * SC._neighbour_mean(top, push))
    # a long, soft transition: the fabric falls outward from the chest, no crease
    push *= sstep(z_hem + 0.34, z_hem + 0.08, co[:, 2]) ** 1.5 * tors
    set_verts(top, co + dirs * push[:, None])
    return int((push > 1e-4).sum()), float(push.max())


def tuck_bottom(bottom, top, z_hem, margin=0.008):
    """Anything of a bottom above a top's hem stays inside the top."""
    tco = verts_np(top)
    axis_y = _torso_axis(tco, z_hem)
    bh = C.rest_bvh(top)
    jco = verts_np(bottom)
    w_all = sstep(z_hem - 0.03, z_hem + 0.005, jco[:, 2])
    moved = 0
    for i in np.nonzero(w_all > 0)[0]:
        p = jco[i]
        a = np.array([0.0, float(axis_y(np.array([max(p[2], z_hem)]))[0]), p[2]])
        d = p - a; d[2] = 0
        R = np.linalg.norm(d)
        if R < 1e-4:
            continue
        loc, _n, _i, dist = bh.ray_cast(Vector((a[0], a[1], max(p[2], z_hem + 0.006))), Vector(d / R), 0.45)
        if loc is None:
            continue
        lim = dist - margin
        if R > lim:
            jco[i] = a + (d / R) * (R + (lim - R) * w_all[i]) + np.array([0, 0, p[2] - a[2]])
            moved += 1
    set_verts(bottom, jco)
    return moved


# ------------------------------------------------------------------ body and hair cells

# ------------------------------------------------------------------ fit in motion (skin weights)
# The layering passes fit the clothes in the rest pose. In motion a garment must also move
# with whatever it covers. Each piece is cut from the body and keeps the weights of the body
# vertex it came from, but shaping moves some of it far from there - trouser hems stretched
# down over the shoes, cuffs rounded off over the back of the hand, hems flared out over the
# hips - and a rigid shoe and a trouser leg, or a hem and the thigh under it, swing apart:
# the lower layer comes through the upper one (a shoe tongue through a trouser hem when the
# ankle flexes, a thigh through a hoodie hem in a grab). So, once everything is shaped:
#  * where one garment lies over another - the hip band (top hems over waistbands) and the
#    ankle band (trouser hems over shoe collars and tongues) - both take the same weights,
#    the body's own at that place (BodyField): they move as one. The covered part of the
#    lower layer is out of sight, so it can follow; a shoe collar flexes with the shin, as a
#    real one does, while the sole stays on the foot.
#  * skin that shows at a garment's edge (neck, wrists, hands) cannot change, so it pushes
#    its weights out along its normal onto the garment over it (cover_transfer).
#  * the part of a sock inside a shoe moves exactly with the shoe.
# Everywhere else a garment keeps its weights. tests/test_outfits.gd checks every clip
# frame by frame.

BONE_PREFIX = ("pelvis", "spine", "neck", "head", "clavicle", "upperarm", "lowerarm", "hand", "index", "middle",
               "ring", "pinky", "thumb", "thigh", "calf", "foot", "ball")


def _dense_weights(ob, names=None):
    names = names or [g.name for g in ob.vertex_groups if g.name.startswith(BONE_PREFIX)]
    return list(names), SC.bone_weight_matrix(ob, names)


def _write_weights(ob, names, W):
    """Replace ob's bone vertex groups by the columns of W (rows normalised)."""
    W = np.asarray(W, np.float32)
    s = W.sum(1, keepdims=True)
    W = np.where(s > 1e-8, W / np.maximum(s, 1e-8), W)
    for g in list(ob.vertex_groups):
        if g.name.startswith(BONE_PREFIX):
            ob.vertex_groups.remove(g)
    for j, name in enumerate(names):
        col = W[:, j]
        nz = np.nonzero(col > 1e-4)[0]
        if len(nz) == 0:
            continue
        g = ob.vertex_groups.new(name=name)
        for i in nz:
            g.add([int(i)], float(col[i]), 'REPLACE')


def _merge_names(names, W, more):
    for n in more:
        if n not in names:
            names.append(n)
            W = np.hstack([W, np.zeros((len(W), 1), np.float32)])
    return names, W


def _vertex_normals(ob):
    n = np.zeros(len(ob.data.vertices) * 3, np.float32)
    ob.data.vertices.foreach_get("normal", n)
    return n.reshape(-1, 3)


def _edges(ob):
    e = np.zeros(len(ob.data.edges) * 2, np.int64)
    ob.data.edges.foreach_get("vertices", e)
    return e.reshape(-1, 2)


def rim_sources(ob):
    """The rim-only solidify of each garment (SC.rim) adds a copy of every opening vertex,
    joined to it by one rung: copy -> source, so a copy can take its source's weights."""
    bm = bmesh.new()
    bm.from_mesh(ob.data)
    out = {}
    for v in bm.verts:
        if not v.is_boundary:
            continue
        inner = [e.other_vert(v) for e in v.link_edges if not e.other_vert(v).is_boundary]
        if inner:
            src = min(inner, key=lambda u: (u.co - v.co).length)
            if (src.co - v.co).length < 0.012:
                out[v.index] = src.index
    bm.free()
    return out


def cover_transfer(outer, inners, near=0.012, far=0.03, full=0.35, smooth=3):
    """inners: [(object, vertex mask or None)]. Each inner vertex casts along its normal; the
    outer surface it meets within `far` takes its weights (fully within `near`)."""
    from mathutils import Vector as V3
    from mathutils.interpolate import poly_3d_calc
    names, W = _dense_weights(outer)
    co = verts_np(outer)
    bvh = C.rest_bvh(outer)
    polys = [tuple(p.vertices) for p in outer.data.polygons]
    acc = None
    wsum = np.zeros(len(co), np.float64)
    for ob, mask in inners:
        inames, IW = _dense_weights(ob)
        names, W = _merge_names(names, W, inames)
        if acc is None or acc.shape[1] < len(names):
            acc = np.zeros((len(co), len(names))) if acc is None else np.hstack([acc, np.zeros((len(co), len(names) - acc.shape[1]))])
        cols = [names.index(n) for n in inames]
        ico = verts_np(ob)
        inr = _vertex_normals(ob)
        idx = np.nonzero(mask)[0] if mask is not None else range(len(ico))
        for i in idx:
            nv = V3(inr[i])
            if nv.length < 0.5:
                continue
            loc, _n, face, dist = bvh.ray_cast(V3(ico[i]) + nv * 0.0005, nv, far)
            if loc is None:
                continue
            f = 1.0 if dist < near else (far - dist) / (far - near)
            vi = polys[face]
            bw = poly_3d_calc([V3(co[v]) for v in vi], loc)
            row = np.zeros(len(names))
            row[cols] = IW[i]
            for v, b in zip(vi, bw):
                acc[v] += row * (b * f)
                wsum[v] += b * f
    if acc is None:
        return 0
    e = _edges(outer)
    for _ in range(smooth):              # spread over the garment a little: no single-ray speckle
        a2 = acc.copy(); s2 = wsum.copy(); cnt = np.ones(len(co))
        np.add.at(a2, e[:, 0], acc[e[:, 1]]); np.add.at(a2, e[:, 1], acc[e[:, 0]])
        np.add.at(s2, e[:, 0], wsum[e[:, 1]]); np.add.at(s2, e[:, 1], wsum[e[:, 0]])
        np.add.at(cnt, e[:, 0], 1); np.add.at(cnt, e[:, 1], 1)
        acc = a2 / cnt[:, None]; wsum = s2 / cnt
    c = np.clip(wsum / full, 0, 1)
    Wn = acc / np.maximum(wsum, 1e-9)[:, None]
    W = W * (1 - c)[:, None] + Wn.astype(np.float32) * c[:, None]
    for cp, src in rim_sources(outer).items():
        W[cp] = W[src]
    _write_weights(outer, names, W)
    return int((c > 0.05).sum())


def socks_in_shoes(socks, uppers, collar_lift=0.01, collar_blend=0.03):
    """Inside the shoe (below its collar, per direction round the ankle, and 1 cm past it),
    the sock takes the weights of the shoe upper right outside it; over the next 3 cm it
    hands back to its own."""
    from mathutils.kdtree import KDTree
    co = verts_np(socks)
    names, W = _dense_weights(socks)
    for side, up in uppers.items():
        sx = 1 if side == "l" else -1
        uco = verts_np(up)
        un, UW = _dense_weights(up)
        names, W = _merge_names(names, W, un)
        UWf = np.zeros((len(uco), len(names)), np.float32)
        for j, n in enumerate(un):
            UWf[:, names.index(n)] = UW[:, j]
        kd = KDTree(len(uco))
        for i, p in enumerate(uco):
            kd.insert(p, i)
        kd.balance()
        ctr = uco[uco[:, 2] > 0.06, :2].mean(0)
        ang_u = np.arctan2(uco[:, 1] - ctr[1], uco[:, 0] - ctr[0])
        bins = 36
        top = np.zeros(bins)
        bi = ((ang_u + np.pi) / (2 * np.pi) * bins).astype(int) % bins
        for b in range(bins):
            m = bi == b
            if m.any():
                top[b] = uco[m, 2].max()
        m = co[:, 0] * sx > 0
        ang = np.arctan2(co[m, 1] - ctr[1], co[m, 0] - ctr[0])
        cz = top[((ang + np.pi) / (2 * np.pi) * bins).astype(int) % bins]
        b = sstep(cz + collar_lift + collar_blend, cz + collar_lift, co[m, 2])
        near = np.array([kd.find(p)[1] for p in co[m]])
        W[m] = W[m] * (1 - b)[:, None] + UWf[near] * b[:, None]
    for cp, src in rim_sources(socks).items():
        W[cp] = W[src]
    _write_weights(socks, names, W)


def _closest_on_polyline(p, pts):
    """For each point of p (n x 3), the closest point on the polyline pts."""
    best = np.full(len(p), 1e9)
    out = np.zeros_like(p)
    for a, b in zip(pts[:-1], pts[1:]):
        a = np.asarray(a, np.float64)
        ab = np.asarray(b, np.float64) - a
        t = np.clip(((p - a) @ ab) / max(float(ab @ ab), 1e-12), 0.0, 1.0)
        q = a + t[:, None] * ab
        d = np.linalg.norm(p - q, axis=1)
        m = d < best
        best[m] = d[m]
        out[m] = q[m]
    return out


class BodyField:
    """The body's skin weights as a field in space: at a point, the weights of the skin where a
    ray from the point towards an axis (the spine, a leg) meets it. Two garments lying one
    over the other ask it for the same place and get the same weights."""

    def __init__(self, body, band=None, smooth=0):
        """band (zlo, zhi), smooth: the weights inside the band are diffused over the body's
        surface `smooth` times first (a gentler pelvis-to-thigh change: the layers on it
        then bend without pinching or folding into each other)."""
        bones = body.parent.data.bones
        self.names, self.W = _dense_weights(body, [g.name for g in body.vertex_groups if g.name in bones])
        self.co = verts_np(body)
        if smooth and band:
            e = _edges(body)
            inb = (self.co[:, 2] > band[0]) & (self.co[:, 2] < band[1])
            W = self.W.astype(np.float64)
            for _ in range(smooth):
                acc = W.copy(); cnt = np.ones(len(W))
                np.add.at(acc, e[:, 0], W[e[:, 1]]); np.add.at(acc, e[:, 1], W[e[:, 0]])
                np.add.at(cnt, e[:, 0], 1); np.add.at(cnt, e[:, 1], 1)
                W[inb] = (acc / cnt[:, None])[inb]
            self.W = (W / np.maximum(W.sum(1, keepdims=True), 1e-9)).astype(np.float32)
        self.bvh = C.rest_bvh(body)
        self.polys = [tuple(p.vertices) for p in body.data.polygons]

    def sample(self, pts, axis):
        from mathutils import Vector as V3
        from mathutils.interpolate import poly_3d_calc
        pts = np.asarray(pts, np.float64)
        tgt = _closest_on_polyline(pts, axis)
        out = np.zeros((len(pts), len(self.names)), np.float32)
        for i in range(len(pts)):
            p = V3(pts[i])
            d = V3(tgt[i]) - p
            L = d.length
            loc = None
            if L > 1e-6:
                loc, _n, face, _dist = self.bvh.ray_cast(p, d / L, L + 0.05)
            if loc is None:
                loc, _n, face, _dist = self.bvh.find_nearest(p)
            vi = self.polys[face]
            for v, w in zip(vi, poly_3d_calc([V3(self.co[v]) for v in vi], loc)):
                out[i] += self.W[v] * w
        return out


def take_field(ob, field, axis, f):
    """Blend ob's weights towards the body field by f (per vertex, 0..1)."""
    names, W = _dense_weights(ob)
    names, W = _merge_names(names, W, field.names)
    m = f > 1e-4
    if m.any():
        co = verts_np(ob)
        Fw = np.zeros((int(m.sum()), len(names)), np.float32)
        Fw[:, [names.index(n) for n in field.names]] = field.sample(co[m], axis)
        W[m] = W[m] * (1 - f[m])[:, None] + Fw * f[m][:, None]
        for cp, src in rim_sources(ob).items():
            W[cp] = W[src]
        _write_weights(ob, names, W)
    return int(m.sum())


def _arm_share(ob):
    names, W = _dense_weights(ob)
    a = np.zeros(len(ob.data.vertices))
    for j, n in enumerate(names):
        if n.startswith(ARM_BONES):
            a += W[:, j]
    return a


HIP_SMOOTH = 60          # diffusion passes over the body's hip weights (tried 0, 60, 90, 150: 60 fits best)
ARM_BONES = ("clavicle", "upperarm", "lowerarm", "hand", "index", "middle", "ring", "pinky", "thumb")


def skin_fit(ob, body, skin, gap=0.004, reach=0.03, full=0.015, under=None):
    """Where skin that stays visible lies under a garment (the band of skin inside each
    opening): the garment takes the skin's own weights at the nearest skin point - fully
    within `full`, handing back to its own by `reach` - and keeps at least `gap` off it.
    under: (garment, its push per vertex) this one lies over (a collar over its shirt): it is
    pushed at least as far as the nearest vertex of that. Returns the push per vertex."""
    from mathutils import Vector as V3
    from mathutils.bvhtree import BVHTree
    from mathutils.interpolate import poly_3d_calc
    from mathutils.kdtree import KDTree
    bnames, BW = _dense_weights(body, [g.name for g in body.vertex_groups if g.name in body.parent.data.bones])
    bco = verts_np(body)
    faces = [tuple(p.vertices) for p in body.data.polygons if all(skin[v] for v in p.vertices)]
    bvh = BVHTree.FromPolygons([V3(c) for c in bco], faces)
    names, W = _dense_weights(ob)
    names, W = _merge_names(names, W, bnames)
    cols = [names.index(n) for n in bnames]
    co = verts_np(ob)
    gn = _vertex_normals(ob)
    need = np.zeros(len(co))
    dirs = np.zeros((len(co), 3))
    for i in range(len(co)):
        loc, nrm, fi, dist = bvh.find_nearest(V3(co[i]), reach)
        if loc is None:
            continue
        gs = float((V3(co[i]) - loc).dot(nrm))
        if gs < -0.006 or (V3(gn[i]).dot(nrm) < 0.2 and dist > 0.008):
            continue            # skin of another part (a forearm beside the waist), not under it
                                # (right on the skin, a rolled lip at an opening faces sideways)
        vi = faces[fi]
        row = np.zeros(len(names), np.float32)
        for v, b in zip(vi, poly_3d_calc([V3(bco[v]) for v in vi], loc)):
            row[cols] += BW[v] * b
        f = float(sstep(reach, full, np.array([dist]))[0])
        W[i] = W[i] * (1 - f) + row * f
        need[i] = max(0.0, gap - gs)
        dirs[i] = nrm                   # straight off the skin: the clearance comes out exact
    if under is not None:
        uco = verts_np(under[0])
        kd = KDTree(len(uco))
        for j, q in enumerate(uco):
            kd.insert(q, j)
        kd.balance()
        for i in range(len(co)):
            q, j, dd = kd.find(co[i])
            if dd < 0.012 and under[1][j] > need[i]:
                need[i] = under[1][j]
                if not dirs[i].any():
                    dirs[i] = gn[i]
    # a smooth falloff round the pushed spots (no dents), each vertex still clear
    e = _edges(ob)
    m = need.copy()
    for _ in range(6):
        nb = np.zeros(len(m)); np.maximum.at(nb, e[:, 0], m[e[:, 1]]); np.maximum.at(nb, e[:, 1], m[e[:, 0]])
        m = np.maximum(m, nb * 0.7)
    missing = ~dirs.any(1)
    dirs[missing] = gn[missing]
    rim = rim_sources(ob)
    for cp, src in rim.items():
        m[cp] = m[src] = max(m[cp], m[src])
        dirs[cp] = dirs[src]
        W[cp] = W[src]
    set_verts(ob, co + dirs * m[:, None])
    _write_weights(ob, names, W)
    return m


def clear_of(ob, inners, gap=0.005, reach=0.03, deep=0.03):
    """Keep ob at least `gap` outside the garments under it at rest (a trouser hem over a
    hi-top's tall collar): each vertex over (or up to `deep` into) one of them is pushed out
    along its surface, with a smooth falloff round the pushed spots. Returns the pushes."""
    from mathutils import Vector as V3
    from mathutils.bvhtree import BVHTree
    verts, faces = [], []
    for o in inners:
        base = len(verts)
        mw = o.matrix_world
        verts += [mw @ v.co for v in o.data.vertices]
        faces += [tuple(base + i for i in p.vertices) for p in o.data.polygons]
    bvh = BVHTree.FromPolygons(verts, faces)
    co = verts_np(ob)
    gn = _vertex_normals(ob)
    need = np.zeros(len(co))
    dirs = np.zeros((len(co), 3))
    for i in range(len(co)):
        loc, nrm, fi, dist = bvh.find_nearest(V3(co[i]), reach)
        if loc is None:
            continue
        gs = float((V3(co[i]) - loc).dot(nrm))
        if gs < -deep or V3(gn[i]).dot(nrm) < 0.2:
            continue
        need[i] = max(0.0, gap - gs)
        dirs[i] = nrm
    e = _edges(ob)
    m = need.copy()
    for _ in range(6):
        nb = np.zeros(len(m)); np.maximum.at(nb, e[:, 0], m[e[:, 1]]); np.maximum.at(nb, e[:, 1], m[e[:, 0]])
        m = np.maximum(m, nb * 0.7)
    missing = ~dirs.any(1)
    dirs[missing] = gn[missing]
    for cp, src in rim_sources(ob).items():
        m[cp] = m[src] = max(m[cp], m[src])
        dirs[cp] = dirs[src]
    set_verts(ob, co + dirs * m[:, None])
    return m


def top_spots(ob, rig):
    """Where a top follows the body's small shapes to a point: each bust apex (the top's most
    forward point on each side of the chest - on her the fabric hangs from there and reads as
    nipples) and the navel (the belly midline's deepest hollow). Found on the top itself (its
    re-shaping moves them off the body's). Returns [(point, radius)]."""
    co = verts_np(ob)
    nrm = _vertex_normals(ob)
    e = _edges(ob)
    acc = np.zeros_like(co); cnt = np.zeros(len(co))
    np.add.at(acc, e[:, 0], co[e[:, 1]]); np.add.at(acc, e[:, 1], co[e[:, 0]])
    np.add.at(cnt, e[:, 0], 1); np.add.at(cnt, e[:, 1], 1)
    h = ((co - acc / np.maximum(cnt, 1)[:, None]) * nrm).sum(1)
    bh = lambda b: np.array(rig.data.bones[b].head_local)
    z_lo, z_hi = float(bh("spine_02")[2]), float(bh("neck_01")[2])
    spots = []
    for sx in (1, -1):
        m = (co[:, 0] * sx > 0.02) & (co[:, 0] * sx < 0.16) & (co[:, 2] > z_lo) & (co[:, 2] < z_hi - 0.06)
        if m.any():
            i = np.nonzero(m)[0][np.argmin(co[m, 1])]
            spots.append((co[i], 0.035))
    zp, zs = float(bh("pelvis")[2]), float(bh("spine_02")[2])
    m = (np.abs(co[:, 0]) < 0.03) & (co[:, 2] > zp - 0.04) & (co[:, 2] < zs) & (co[:, 1] < bh("spine_01")[1] - 0.04)
    if m.any():
        i = np.nonzero(m)[0][np.argmin(h[m])]
        spots.append((co[i], 0.035))
    return spots


def flatten_spots(ob, spots):
    """A top bridges its spots (top_spots): round each, its surface within the radius
    is replaced by a smooth quadratic fitted to the ring just outside (fully inside 0.45 of
    the radius, blending out to it) - the fabric's own folds elsewhere stay as they are.
    The body under a worn top is not drawn (its cover mask), so the fabric may lie a
    little inside it there. Returns the largest change."""
    co = verts_np(ob)
    out = co.copy()
    worst = 0.0
    for c, R in spots:
        d = np.linalg.norm(co - c, axis=1)
        ring = (d > R) & (d < 1.7 * R)
        inner = d < R
        if ring.sum() < 12 or not inner.any():
            continue
        # a local frame: the plane through the ring
        P = co[ring]
        ctr = P.mean(0)
        u, sv, vt = np.linalg.svd(P - ctr)
        n = vt[2]
        if np.dot(n, c - np.array([0.0, 0.0, c[2]])) < 0:     # (outward)
            n = -n
        e1, e2 = vt[0], vt[1]
        def local(q):
            r = q - ctr
            return r @ e1, r @ e2, r @ n
        x, y, h = local(P)
        A = np.stack([np.ones_like(x), x, y, x * x, x * y, y * y], 1)
        coef, *_ = np.linalg.lstsq(A, h, rcond=None)
        idx = np.nonzero(inner)[0]
        xi, yi, hi = local(co[idx])
        hf = np.stack([np.ones_like(xi), xi, yi, xi * xi, xi * yi, yi * yi], 1) @ coef
        w = sstep(R, 0.45 * R, d[idx])
        new_h = hi + (hf - hi) * w
        out[idx] = ctr + e1 * xi[:, None] + e2 * yi[:, None] + n * new_h[:, None]
        worst = max(worst, float(np.abs(new_h - hi).max()))
    for cp, src in rim_sources(ob).items():
        out[cp] = out[src] + (co[cp] - co[src])
    set_verts(ob, out)
    return worst


def rest_fix(ob, inners, body, gap=0.003, cap=0.035, iters=8, outward=0.5, layer=0.015, near=0.03, tol=0.0015):
    """The fit test's rest check, exactly (tests/test_outfits.gd: make_shell, the pairing and
    rest_through, on the triangles the export makes): ob's shell is its triangles facing
    away from the body (within 60 degrees of the nearest body vertex's normal) less those
    ob itself covers within `layer`; an inner vertex with no shell triangle behind it within
    `near` (closest point inside the triangle) shows through if a ray from it towards the
    body - against that body normal, as far as the body and 4 mm - meets a shell triangle
    facing it. After drape_hem only a few do, at the hem's edge: each pushes the triangles
    it meets out past it by `gap` (at most `cap` in all, a short falloff round them) until
    none shows. Returns a summary."""
    from mathutils import Vector as V3
    from mathutils.bvhtree import BVHTree
    from mathutils.interpolate import poly_3d_calc
    from mathutils.kdtree import KDTree
    from mathutils.geometry import intersect_ray_tri
    me_b = body.data
    bco = verts_np(body)
    if "custom_normal" in me_b.attributes:        # (what the export writes for the male)
        bn = np.zeros(len(bco) * 3, np.float32)
        me_b.attributes["custom_normal"].data.foreach_get("vector", bn)
        bn = bn.reshape(-1, 3)
    else:
        bn = _vertex_normals(body)
    kd = KDTree(len(bco))
    for i, q in enumerate(bco):
        kd.insert(q, i)
    kd.balance()

    def body_at(q):
        _c, bi, d = kd.find(q)
        return (bi, d) if d <= 0.12 else (None, d)
    pts = []
    for o in inners:
        mw = o.matrix_world
        pts += [mw @ v.co for v in o.data.vertices]
    e = _edges(ob)
    rims = rim_sources(ob)
    total = np.zeros(len(ob.data.vertices))
    shown = []
    me = ob.data
    for _ in range(iters):
        co = verts_np(ob)
        me.calc_loop_triangles()
        tris = np.array([t.vertices[:] for t in me.loop_triangles], np.int64)
        a, b, c = co[tris[:, 0]], co[tris[:, 1]], co[tris[:, 2]]
        nrm = np.cross(b - a, c - a)
        ln = np.linalg.norm(nrm, axis=1)
        ctr = (a + b + c) / 3
        cand = []
        for k in np.nonzero(ln > 1e-7)[0]:
            n = nrm[k] / ln[k]
            bi, _d = body_at(V3(ctr[k]))
            if bi is None or np.dot(n, bn[bi]) < outward or np.dot(ctr[k] - bco[bi], bn[bi]) < 0.0:
                continue
            cand.append(k)
        cand = np.array(cand, np.int64)
        cb = BVHTree.FromPolygons([V3(q) for q in co], [tuple(t) for t in tris[cand]])
        shell = []
        for j, k in enumerate(cand):
            n = V3(nrm[k] / ln[k])
            o = V3(ctr[k]) + n * 0.0008
            covered = False
            q = o
            for _s in range(4):
                loc, _n2, fi, dist = cb.ray_cast(q, n, layer)
                if loc is None or (loc - o).length >= layer:
                    break
                if fi != j:
                    covered = True
                    break
                q = loc + n * 1e-5
            if not covered:
                shell.append(k)
        shell = np.array(shell, np.int64)
        sb = BVHTree.FromPolygons([V3(q) for q in co], [tuple(t) for t in tris[shell]])
        need = np.zeros(len(co))
        dirs = np.zeros((len(co), 3))
        hits = 0
        for p in pts:
            under = False
            for loc, n2, fi, dist in sb.find_nearest_range(p, near):
                if n2.dot(p - loc) >= 0.0:
                    continue
                t = tris[shell[fi]]
                w = poly_3d_calc([V3(co[t[0]]), V3(co[t[1]]), V3(co[t[2]])], loc)
                if min(w) > 1e-4:
                    under = True
                    break
            if under:
                continue
            bi, d = body_at(p)
            if bi is None or np.linalg.norm(bn[bi]) < 0.5:
                continue
            u = V3(-bn[bi] / np.linalg.norm(bn[bi]))
            length = min(d + 0.004, near)
            hit = False
            for loc, n2, fi, dist in sb.find_nearest_range(p, length + 0.01):
                if n2.dot(u) >= 0.0:
                    continue
                t = tris[shell[fi]]
                x = intersect_ray_tri(V3(co[t[0]]), V3(co[t[1]]), V3(co[t[2]]), u, p, True)
                if x is None:
                    continue
                dd = (x - p).length
                if tol < dd <= length:
                    hit = True
                    for vi in t:
                        need[vi] = max(need[vi], dd + gap)
                        dirs[vi] -= np.array(u)
            hits += hit
        shown.append(hits)
        if hits == 0:
            break
        m = np.minimum(need, np.maximum(cap - total, 0.0))
        for _s in range(3):
            nb = np.zeros(len(m)); np.maximum.at(nb, e[:, 0], m[e[:, 1]]); np.maximum.at(nb, e[:, 1], m[e[:, 0]])
            m = np.maximum(m, nb * 0.6)
        m = np.minimum(m, np.maximum(cap - total, 0.0))
        dl = np.linalg.norm(dirs, axis=1)
        dirs = np.where(dl[:, None] > 1e-6, dirs / np.maximum(dl, 1e-6)[:, None], _vertex_normals(ob))
        for cp, src in rims.items():
            m[cp] = m[src] = max(m[cp], m[src])
            dirs[cp] = dirs[src]
        set_verts(ob, co + dirs * m[:, None])
        total += m
    return f"showing {shown}, {int((total > 1e-4).sum())} pushed (up to {total.max() * 1000:.1f} mm)"


def drape_hem(trousers, shoes, rig, gap=0.004, taper=0.06, nth=48, dz=0.01):
    """At rest nothing of the shoe shows through the trouser hem over it (the fit test's rest
    check): a tongue top or lace bow standing in front of the hem, a collar outside a hem
    tucked into it. Like fit_layers' hoodie flare: round each ankle's vertical axis the leg
    must reach, at every angle and height, `gap` past the shoe's outline there (bins of
    360/nth degrees and dz). Below the highest need at an angle the leg holds the widest
    radius needed above it (the hem hangs straight down past a lace bow, it does not curl
    back in under it); above it the push fades out over `taper`; the push is then smoothed
    over the leg, never below what is needed. Radial, so the hem keeps its line.
    shoes: {side: [parts]}. Returns a summary."""
    co = verts_np(trousers)
    need_p = np.zeros(len(co))
    push = np.zeros(len(co))
    rad = np.zeros((len(co), 3))
    lifted = 0.0
    for side, parts in shoes.items():
        sx = 1 if side == "l" else -1
        ax = np.array(rig.data.bones[f"foot_{side}"].head_local)[:2]
        P = np.concatenate([np.array([(o.matrix_world @ v.co)[:] for v in o.data.vertices]) for o in parts])
        z_shoe = float(P[:, 2].max())
        idx = np.nonzero((co[:, 0] * sx > 0) & (co[:, 2] < z_shoe + taper + 0.02))[0]
        if len(idx) == 0:
            continue

        def polar(q):
            d = q[:, :2] - ax
            return ((np.arctan2(d[:, 0], -d[:, 1]) + np.pi) / (2 * np.pi) * nth) % nth, np.linalg.norm(d, axis=1)
        z0 = float(co[idx, 2].min()) - dz
        nz = int((z_shoe - z0) / dz) + 3

        def bins():
            """The leg per bin: its radius, and per angle its hem's height."""
            tb, r = polar(co[idx])
            t0 = tb.astype(int)
            kb = np.clip(np.floor((co[idx, 2] - z0) / dz).astype(int), 0, nz - 1)
            r_leg = np.full((nth, nz), np.inf)
            np.minimum.at(r_leg, (t0, kb), r)
            gaps = np.isinf(r_leg)              # (a bin between the leg's vertices: its neighbours')
            nbm = np.minimum(np.minimum(np.roll(r_leg, 1, 0), np.roll(r_leg, -1, 0)),
                             np.minimum(np.roll(r_leg, 1, 1), np.roll(r_leg, -1, 1)))
            r_leg[gaps] = nbm[gaps]
            z_bot = np.full(nth, np.inf)
            np.minimum.at(z_bot, t0, co[idx, 2])
            z_bot = np.minimum(z_bot, np.minimum(np.roll(z_bot, 1), np.roll(z_bot, -1)))
            return tb, r, t0, (t0 + 1) % nth, tb - t0, kb, r_leg, z_bot
        tb_s, r_s = polar(P)
        zb_s = np.floor((P[:, 2] - z0) / dz).astype(int)
        ts = tb_s.astype(int)
        inb = (zb_s >= 0) & (zb_s < nz)
        zbc = np.clip(zb_s, 0, nz - 1)
        # 1. what the leg cannot drape - shoe points above its hem more than 3 cm outside it
        #    (the laces down the instep) - it clears instead: the hem is raised over them at
        #    that angle, the leg's bottom `band` compressed upwards (the break sits higher in
        #    front, as on real trousers over a low shoe)
        tb, r, t0, t1, ft, kb, r_leg, z_bot = bins()
        band = 0.10
        far = inb & (P[:, 2] >= z_bot[ts] - 0.005) & (P[:, 2] < z_bot[ts] + band) & \
            np.isfinite(r_leg[ts, zbc]) & (r_s > r_leg[ts, zbc] + 0.03)
        z_need = np.full(nth, -np.inf)
        np.maximum.at(z_need, ts[far], P[far, 2] + gap)
        lift = np.clip(np.where(np.isfinite(z_need), z_need - z_bot, 0.0), 0.0, 0.6 * band)
        for _ in range(3):
            lift = np.maximum(lift, 0.5 * (np.roll(lift, 1) + np.roll(lift, -1)))
        L = lift[t0] * (1 - ft) + lift[t1] * ft
        zb_v = np.minimum(z_bot[t0] * (1 - ft) + z_bot[t1] * ft, co[idx, 2])
        f = np.clip((zb_v + band - co[idx, 2]) / band, 0.0, 1.0)
        co[idx, 2] = co[idx, 2] + L * f
        lifted = max(lifted, float(lift.max()))
        # 2. the drape, over the raised leg: only shoe points it could be over - not below
        #    its hem there, and not more than 3 cm outside it
        tb, r, t0, t1, ft, kb, r_leg, z_bot = bins()
        ok = inb.copy()
        ok[ok] &= (P[ok, 2] >= z_bot[ts[ok]] - 0.005) & np.isfinite(r_leg[ts[ok], zb_s[ok]]) & \
            (r_s[ok] <= r_leg[ts[ok], zb_s[ok]] + 0.03)
        need = np.zeros((nth, nz))
        np.maximum.at(need, (ts[ok], zb_s[ok]), r_s[ok] + gap)
        need[:, 1:] = np.maximum(need[:, 1:], need[:, :-1])      # a shoe point needs the leg round it
        need[:, :-1] = np.maximum(need[:, :-1], need[:, 1:])     # a little above and below too
        hold = np.maximum.accumulate(need[:, ::-1], axis=1)[:, ::-1]   # widest need at or above
        top = np.array([np.nonzero(need[t])[0].max() if need[t].any() else -1 for t in range(nth)])
        R = hold[t0, kb] * (1 - ft) + hold[t1, kb] * ft
        zone = (kb <= np.maximum(top[t0], top[t1]))
        p = np.where(zone, np.maximum(0.0, R - r), 0.0)
        # above the need: fade the push at the zone's top out over `taper`
        ptop = np.zeros(nth)
        np.maximum.at(ptop, t0[zone], p[zone])
        for _ in range(2):
            ptop = np.maximum(ptop, 0.5 * (np.roll(ptop, 1) + np.roll(ptop, -1)))
        zt = z0 + (np.maximum(top[t0], top[t1]) + 1) * dz
        f = np.clip(1 - (co[idx, 2] - zt) / taper, 0, 1)
        q = np.where(zone, p, (ptop[t0] * (1 - ft) + ptop[t1] * ft) * f)
        need_p[idx] = p
        push[idx] = q
        d = co[idx, :2] - ax
        rad[idx, :2] = d / np.maximum(np.linalg.norm(d, axis=1), 1e-6)[:, None]
    e = _edges(trousers)
    for _ in range(4):                   # smooth over the leg, never below the need
        acc = push.copy(); cnt = np.ones(len(push))
        np.add.at(acc, e[:, 0], push[e[:, 1]]); np.add.at(acc, e[:, 1], push[e[:, 0]])
        np.add.at(cnt, e[:, 0], 1); np.add.at(cnt, e[:, 1], 1)
        push = np.maximum(need_p, acc / cnt)
    moved = push > 1e-4
    rad[moved & ~rad.any(1)] = _vertex_normals(trousers)[moved & ~rad.any(1)]
    for cp, src in rim_sources(trousers).items():
        push[cp] = push[src] = max(push[cp], push[src])
        rad[cp] = rad[src]
    set_verts(trousers, co + rad * push[:, None])
    return f"hem raised up to {lifted * 1000:.0f} mm, {int(moved.sum())} widened (up to {push.max() * 1000:.1f} mm)"


def rigid_shoe(parts, side):
    """A shoe moves as one piece on the foot (and its toe box on the ball of the foot), as
    the original skater's does: any other bone's share goes to the foot."""
    keep = (f"foot_{side}", f"ball_{side}")
    for ob in parts:
        names, W = _dense_weights(ob)
        if f"foot_{side}" not in names:
            names, W = _merge_names(names, W, [f"foot_{side}"])
        fi = names.index(f"foot_{side}")
        for j, n in enumerate(names):
            if n not in keep:
                W[:, fi] += W[:, j]
                W[:, j] = 0
        _write_weights(ob, names, W)


def hem_on_shoes(trousers, shoes, lift=0.03, blend=0.05):
    """shoes: {side: [shoe parts]}. The trouser leg over a shoe moves with it: every vertex
    below the shoe's top (+lift) takes the weights of the nearest shoe vertex - the foot's,
    shoes being rigid - and hands back to its own over the next `blend`. The hem and the
    shoe under it then move as one, whatever the ankle does; above the shoe the leg inside
    is hidden skin. Returns the rigid height per side."""
    from mathutils.kdtree import KDTree
    co = verts_np(trousers)
    names, W = _dense_weights(trousers)
    tops = {}
    for side, parts in shoes.items():
        sx = 1 if side == "l" else -1
        pts, rows = [], []
        for ob in parts:
            sn, SW = _dense_weights(ob)
            names, W = _merge_names(names, W, sn)
            R = np.zeros((len(SW), len(names)), np.float32)
            R[:, [names.index(n) for n in sn]] = SW
            pts.append(verts_np(ob))
            rows.append(R)
        width = max(r.shape[1] for r in rows)
        P = np.concatenate(pts)
        R = np.concatenate([np.hstack([r, np.zeros((len(r), width - r.shape[1]), np.float32)]) for r in rows])
        R = np.hstack([R, np.zeros((len(R), len(names) - R.shape[1]), np.float32)])
        top = float(P[:, 2].max()) + lift
        tops[side] = top
        kd = KDTree(len(P))
        for i, q in enumerate(P):
            kd.insert(q, i)
        kd.balance()
        m = (co[:, 0] * sx > 0) & (co[:, 2] < top + blend)
        f = sstep(top + blend, top, co[m, 2])
        near = np.array([kd.find(q)[1] for q in co[m]])
        W[m] = W[m] * (1 - f)[:, None] + R[near] * f[:, None]
    for cp, src in rim_sources(trousers).items():
        W[cp] = W[src]
    _write_weights(trousers, names, W)
    return tops


def fit_in_motion(G, body, kill, reference=True):
    """The pass above for every garment of this body, after texturing (the bakes see the
    garments exactly as the rest-pose layering left them: today's hoodie, jeans and shoes
    bake to the same textures as before). The copies G[socks_high / jeans_high /
    cargo_high] get the weights that move with hi-tops. reference: the male body (today's
    hoodie keeps its shape; the other body's hoodie is fitted to her skin like the tee)."""
    rig = body.parent
    bone_head = lambda b: np.array(rig.data.bones[b].head_local)
    spine = [bone_head("pelvis") - np.array([0, 0, 0.4])] + [bone_head(b) for b in ("pelvis", "spine_01", "spine_02", "spine_03", "neck_01")]
    tops = [G["hoodie"]["Hoodie"], G["tee"]["Tee"], G["flannel"]["Flannel"]]
    bottoms = [G["jeans"]["Jeans"], G["cargo"]["Cargo"], G["shorts"]["Shorts"]]
    n = {}
    # 1. the hip band: from just under the lowest top hem to just over the highest waistband
    def torso_z(ob):
        a = _arm_share(ob)
        return verts_np(ob)[a < 0.5, 2]
    hem_lo = min(float(torso_z(t).min()) for t in tops)
    waist_hi = max(float(verts_np(b)[:, 2].max()) for b in bottoms)
    field = BodyField(body, band=(hem_lo - 0.25, waist_hi + 0.15), smooth=HIP_SMOOTH)
    for ob in tops:
        z = verts_np(ob)[:, 2]
        f = sstep(waist_hi + 0.07, waist_hi + 0.01, z) * (_arm_share(ob) < 0.5)
        n[ob.name] = take_field(ob, field, spine, f)
    for ob in bottoms:
        z = verts_np(ob)[:, 2]
        n[ob.name] = take_field(ob, field, spine, sstep(hem_lo - 0.08, hem_lo - 0.01, z))
    # 2. the ankle band: shoes stay rigid on the foot (the hi-tops made so too); the trouser
    #    leg over them moves with them. Low shoes and hi-tops reach different heights, so the
    #    long trousers come in two weightings: <id> over low shoes, <id>_high over hi-tops.
    for s in "lr":
        rigid_shoe([ob for n, ob in G["hitop"].items() if n.endswith("_" + s.upper())], s)
    by_side = lambda g: {s: [ob for n, ob in G[g].items() if n.endswith("_" + s.upper()) and "Sole" not in n] for s in "lr"}
    for g in ("jeans", "cargo"):
        ob = next(iter(G[g].values()))
        hi = next(iter(G[g + "_high"].values()))
        names, W = _dense_weights(ob)     # (the copy was made before the hip band: take it from the base)
        _write_weights(hi, names, W)
        # the hems were shaped over low shoes: over hi-tops they must clear the tall collar
        push = clear_of(hi, [o for part in by_side("hitop").values() for o in part])
        n[hi.name + "_clear"] = f"{int((push > 1e-4).sum())} pushed (up to {push.max() * 1000:.1f} mm)"
        # nothing of the shoe under a hem shows through it at rest (today's jeans keep their
        # shape: over the grey suede shoes his tongue tops sit in front of the hem, as before)
        for tr, shoe in ((ob, "suede"), (hi, "hitop")):
            if not (reference and tr.name == "Jeans"):
                n[tr.name + "_drape"] = drape_hem(tr, {sd: [o for nm, o in G[shoe].items() if nm.endswith("_" + sd.upper())] for sd in "lr"}, rig)
                n[tr.name + "_rest"] = rest_fix(tr, list(G[shoe].values()), body)
        n[ob.name + "_hem"] = hem_on_shoes(ob, by_side("suede"))
        # (over a hi-top the rigid band reaches higher: in a bail's deep ankle bend her tall
        # collar swings into the leg just over a 3 cm band)
        n[hi.name + "_hem"] = hem_on_shoes(hi, by_side("hitop"), lift=0.05)
    # 3. skin that shows at a garment's edges (neck, wrists, hands) pushes its weights out
    all_bottoms = kill["jeans"] & kill["cargo"] & kill["shorts"]
    if reference:
        # today's hoodie keeps its shape: the skin at its openings only lends it weights
        for p in ("Hoodie", "HoodRoll", "HoodBack"):
            n[p + "_skin"] = cover_transfer(G["hoodie"][p], [(body, ~kill["hoodie"] & ~all_bottoms)])
    else:
        skin = ~kill["hoodie"] & ~all_bottoms
        push = skin_fit(G["hoodie"]["Hoodie"], body, skin)
        n["Hoodie_skin"] = f"{int((push > 1e-4).sum())} pushed (up to {push.max() * 1000:.1f} mm)"
        for p in ("HoodRoll", "HoodBack"):
            pc = skin_fit(G["hoodie"][p], body, skin, under=(G["hoodie"]["Hoodie"], push))
            n[p + "_skin"] = f"{int((pc > 1e-4).sum())} pushed (up to {pc.max() * 1000:.1f} mm)"
        # and, as his does, the skin lends its weights to the sleeve wall it faces (a palm
        # swinging into the cuff as the wrist bends right back in getup_front)
        n["Hoodie_cover"] = cover_transfer(G["hoodie"]["Hoodie"], [(body, skin)])
    #    the new tops lie closer to the skin (the tee's crew neck, the flannel's shoulders):
    #    there they take the skin's weights exactly and keep 4 mm clear of it
    for g, shirt, collar in (("tee", "Tee", "CrewBand"), ("flannel", "Flannel", "Collar")):
        skin = ~kill[g] & ~all_bottoms
        push = skin_fit(G[g][shirt], body, skin)
        n[shirt + "_skin"] = f"{int((push > 1e-4).sum())} pushed (up to {push.max() * 1000:.1f} mm)"
        pc = skin_fit(G[g][collar], body, skin, under=(G[g][shirt], push))
        n[collar + "_skin"] = f"{int((pc > 1e-4).sum())} pushed (up to {pc.max() * 1000:.1f} mm)"
    # 4. socks: inside the shoe they move with it
    low = G["socks"]["Socks"]
    hs = G["socks_high"]["SocksHigh"]
    socks_in_shoes(low, {"l": G["suede"]["ShoeUpper_L"], "r": G["suede"]["ShoeUpper_R"]})
    socks_in_shoes(hs, {"l": G["hitop"]["HiTopUpper_L"], "r": G["hitop"]["HiTopUpper_R"]})
    print(f"[outfit] fit in motion (hip band {hem_lo:.3f}..{waist_hi:.3f} m): {n}")


def body_cells(body, kill):
    """Per face, the bit mask of the coverage classes that hide it (a face is hidden by a
    class if any of its vertices is under it), in the 'cells' colour attribute (red: bits
    0-7, green: bits 8-15, in 1/255 steps; the skin shader decodes it)."""
    me = body.data
    n = len(me.vertices)
    vbits = np.zeros(n, np.int64)
    for cls, bit in CELL_BITS.items():
        vbits |= kill[cls].astype(np.int64) << bit
    fbits = np.zeros(len(me.polygons), np.int64)
    loops = np.zeros(len(me.loops), np.int64)
    me.loops.foreach_get("vertex_index", loops)
    start = np.zeros(len(me.polygons), np.int64); count = np.zeros(len(me.polygons), np.int64)
    me.polygons.foreach_get("loop_start", start); me.polygons.foreach_get("loop_total", count)
    for k in range(int(count.max())):
        m = count > k
        fbits[m] |= vbits[loops[start[m] + k]]
    _write_face_bits(me, "cells", fbits)
    return fbits


def _write_face_bits(me, name, fbits):
    a = me.color_attributes.get(name)
    if a:
        me.color_attributes.remove(a)
    a = me.color_attributes.new(name, 'FLOAT_COLOR', 'CORNER')
    start = np.zeros(len(me.polygons), np.int64); count = np.zeros(len(me.polygons), np.int64)
    me.polygons.foreach_get("loop_start", start); me.polygons.foreach_get("loop_total", count)
    per_loop = np.repeat(fbits, count)
    col = np.zeros((len(me.loops), 4), np.float32)
    col[:, 0] = (per_loop & 255) / 255.0
    col[:, 1] = ((per_loop >> 8) & 255) / 255.0
    col[:, 3] = 1.0
    a.data.foreach_set("color", col.ravel())
    me.color_attributes.active_color = a
    try:
        me.color_attributes.render_color_index = me.color_attributes.find(name)
    except Exception:
        pass


def hair_cells(hair, hats):
    """Per hair face, the bits of the hats that cover its card's root (a card growing
    under a hat is tucked under it; one growing below the hat's edge stays)."""
    me = hair.data
    roots = np.zeros(len(me.polygons) * 3, np.float32)
    me.attributes["card_root"].data.foreach_get("vector", roots)
    roots = roots.reshape(-1, 3)
    fbits = np.zeros(len(me.polygons), np.int64)
    for key, info in hats.items():
        line = info["line"]
        covered = roots[:, 2] > line(roots[:, 1]) - 0.004
        fbits |= covered.astype(np.int64) << HAT_BITS[key]
    _write_face_bits(me, "hatcells", fbits)
    return fbits


# ------------------------------------------------------------------ textures
# The male versions are baked (skater_clothes.bake_garment: a unique UV, fabric photo tiled
# at true scale through the analytic 'Fabric' UV, seams / prints / wear painted in fabric
# space, ambient occlusion from the garment's own folds). The female versions have the
# same topology: they take the male's UV layout and the same images.

UV_CACHE = {}
UV_DIR = os.path.join(C.WORK, "outfit_uv")


def _save_uv(ob):
    me = ob.data
    a = np.zeros(len(me.loops) * 2, np.float32)
    me.uv_layers["UVMap"].data.foreach_get("uv", a)
    UV_CACHE[ob.name] = a
    os.makedirs(UV_DIR, exist_ok=True)
    np.save(os.path.join(UV_DIR, ob.name + ".npy"), a)


def _load_uv(ob):
    a = UV_CACHE.get(ob.name)
    if a is None:
        path = os.path.join(UV_DIR, ob.name + ".npy")
        if not os.path.exists(path):
            raise RuntimeError(f"no male UV layout for {ob.name}: build the male skater first")
        a = np.load(path)
    me = ob.data
    if len(a) != len(me.loops) * 2:
        raise RuntimeError(f"{ob.name}: topology differs from the male garment ({len(me.loops)} vs {len(a) // 2} loops)")
    if "UVMap" not in me.uv_layers:
        me.uv_layers.new(name="UVMap")
    me.uv_layers["UVMap"].data.foreach_set("uv", a)


def shared_material(name, flat=None):
    """The male garment's material, rebuilt from its images in blender/work/tex (flat:
    kwargs for a plain colour material instead)."""
    m = bpy.data.materials.get(name)
    if m is not None:
        return m
    if flat is not None:
        return C.pbr_material(name, **flat)
    t = C.TEX_OUT
    a = C.load_png(os.path.join(t, name + "_albedo.png"), name + "_albedo")
    n = C.load_png(os.path.join(t, name + "_normal.png"), name + "_normal", 'Non-Color')
    r = C.load_png(os.path.join(t, name + "_rough.png"), name + "_rough", 'Non-Color')
    return C.pbr_material(name, base=a, normal=n, rough=r)


def _tile(name, tint=None):
    t = SC.srgb_to_lin(C.make_seamless(C.src_array(name, 1024)))
    return t


def _stitch_line(d, width=0.0012, dash=0.005, along=None):
    """Mask of a dashed stitch line at distance d from a seam (d: signed distance field)."""
    m = np.abs(d) < width
    if along is not None:
        m &= (along / dash) % 1 < 0.55
    return m


def plaid(u, v):
    """A brushed-cotton flannel plaid (green / navy / black, a yellow and a white line),
    warp and weft each through the same 10 cm sett; colour = the mix a twill weave shows."""
    sett = [((0.028, 0.075, 0.042), 0.030), ((0.012, 0.012, 0.014), 0.006), ((0.028, 0.075, 0.042), 0.004),
            ((0.012, 0.012, 0.014), 0.006), ((0.02, 0.03, 0.085), 0.026), ((0.62, 0.48, 0.07), 0.002),
            ((0.02, 0.03, 0.085), 0.008), ((0.012, 0.012, 0.014), 0.010), ((0.7, 0.7, 0.66), 0.0015),
            ((0.012, 0.012, 0.014), 0.0075)]
    total = sum(w for _, w in sett)
    edges = np.cumsum([0] + [w for _, w in sett])
    cols = np.array([c for c, _ in sett])

    def stripe(x):
        xm = np.mod(x, total)
        idx = np.clip(np.searchsorted(edges, xm, side='right') - 1, 0, len(sett) - 1)
        return cols[idx]
    return 0.5 * stripe(u) + 0.5 * stripe(v)


def _print_art(kind):
    """Artwork drawn in code (Blender text curves via the graffiti canvas), RGBA."""
    import graffiti as G
    cv = G.Canvas()
    tmp = os.path.join(C.WORK, "print_tmp.png")
    if kind == "tee":
        P = dict(style="piece", text="SKATE", fill=((0.95, 0.16, 0.12), (1.0, 0.62, 0.08)), inner=(1, 1, 1),
                 outline=(0.02, 0.02, 0.03), block=(0.06, 0.12, 0.4), seed=31)
        G.draw_piece(cv, P)
        img = cv.render(1024, 512, tmp, margin=1.08)
    else:
        r = C.rng(41)
        lay = G._word_layout(cv, "W", 1.0, r, overlap=0.0, shear=0.1, rot_j=0.0, y_j=0.0, s_j=0.0)
        for L in lay:
            cv.text(L["ch"], 1.0, 0.1, 0.0, (0.96, 0.95, 0.9), loc=(L["x"], L["y"], 1.0), rot=0.0, scale=1.0)
        lo, hi = cv.bounds()
        c = ((lo.x + hi.x) / 2, (lo.y + hi.y) / 2)
        cv.disc(c, max(hi.x - lo.x, hi.y - lo.y) * 0.72, (0.8, 0.09, 0.08), 0.5)
        img = cv.render(512, 512, tmp, margin=1.1)
    cv.free()
    if os.path.exists(tmp):
        os.remove(tmp)
    return img


def _sample_art(art, x, y):
    """art RGBA top row first; x, y in 0..1 (outside -> transparent)."""
    h, w = art.shape[:2]
    inside = (x >= 0) & (x < 1) & (y >= 0) & (y < 1)
    xi = np.clip((x * w).astype(int), 0, w - 1)
    yi = np.clip((y * h).astype(int), 0, h - 1)
    out = art[yi, xi]
    out[~inside] = 0
    return out


def tee_extra(info):
    art = _print_art("tee")
    zc = info["z_hem"] + 0.66 * (info["z_col_back"] - info["z_hem"])

    def f(col, height, rough, fab, pos):
        u, v = fab[..., 0], fab[..., 1]
        # hems: a double-needle cover stitch 2 cm from the bottom and the sleeve ends
        z = pos[..., 2]
        torso = u < 1.8
        hem_d = np.where(torso, v - info["z_hem"], 0.0)
        for off in (0.016, 0.022):
            st = _stitch_line(hem_d - off, 0.0009, 0.004, u) & torso
            col = np.where(st[..., None], col * 0.82, col)
            height = height + st * 0.8
        # the chest print (plastisol ink: sits on the knit, slightly cracked)
        px = (u - (0.6 - 0.13)) / 0.26
        py = 1 - (v - (zc - 0.065)) / 0.13
        a = _sample_art(art, px, py) * torso[..., None]
        crack = C.resize(C.value_noise(256, 40, 71, 3), col.shape[0]) > 0.78
        al = a[..., 3] * (1 - 0.6 * crack)
        ink = SC.srgb_to_lin(np.clip(a[..., :3], 0, 1))
        lum = C.luminance(col) / max(1e-4, float(C.luminance(col).mean()))
        col = col * (1 - al[..., None]) + ink * (0.92 + 0.08 * lum)[..., None] * al[..., None]
        height = height * (1 - 0.6 * al) + al * 0.4
        rough = rough * (1 - al) + 0.62 * al
        return col, height, rough
    return f


def flannel_extra(info):
    def f(col, height, rough, fab, pos):
        u, v = fab[..., 0], fab[..., 1]
        z = pos[..., 2]
        torso = u < 1.8
        weave = col / np.maximum(C.luminance(col)[..., None].mean(), 1e-4)
        pl = plaid(u, v)
        col = pl * (0.55 + 0.45 * np.clip(weave, 0.4, 1.8))
        # placket down the front: stitched either side
        du = (u - 0.6)
        for off in (-0.016, 0.016):
            st = _stitch_line(du - off, 0.0008, 0.004, v) & torso
            col = np.where(st[..., None], col * 1.35 + 0.02, col)
            height = height + st * 0.7
        edge = np.abs(du) < 0.0012
        height = height - edge * torso * 1.2
        # two chest pockets with flaps (plaid cut on the bias would be fancier; these match)
        zc = info["z_hem"] + 0.72 * (info["z_col_back"] - info["z_hem"])
        for cu in (0.6 - 0.1, 0.6 + 0.1):
            inx = np.abs(u - cu) < 0.055
            iny = (v < zc + 0.02) & (v > zc - 0.11)
            box = inx & iny & torso
            border = box & ((np.abs(np.abs(u - cu) - 0.055) < 0.0025) | (np.abs(v - (zc - 0.11)) < 0.0025))
            flap = inx & (np.abs(v - (zc + 0.005)) < 0.0015) & torso
            col = np.where(border[..., None], col * 0.7, col)
            height = height + box * 0.5 - border * 1.0 - flap * 1.2
        # cuffs: the last 6 cm of each sleeve, stitched
        cuff = (~torso) & (v > info["cuff_t"] - 0.06)
        st = (~torso) & _stitch_line(v - (info["cuff_t"] - 0.062), 0.0008, 0.004, u)
        height = height + cuff * 0.3 - st * 0.8
        rough[:] = 0.9
        return col, height, rough
    return f


def trousers_extra(kind, info):
    def f(col, height, rough, fab, pos):
        u, v = fab[..., 0], fab[..., 1]
        z = pos[..., 2]
        legs = u > 1.0
        for c0 in (1.2 + 0.075 * np.pi / 2, 1.2 - 0.075 * np.pi / 2, 1.75 + 0.075 * np.pi / 2, 1.75 - 0.075 * np.pi / 2):
            dseam = u - c0
            seam = np.exp(-(dseam / 0.0025) ** 2) * legs
            st = _stitch_line(np.abs(dseam) - 0.006, 0.001, 0.005, v) & legs
            col = col * (1 - 0.22 * seam[..., None])
            col = np.where(st[..., None], col * 0.75, col)
            height = height - seam * 1.1 + st * 0.5
        # waistband and belt loops
        wb = (~legs) & (z > info["z_waist"] - 0.04)
        col = np.where(wb[..., None], col * 0.93, col)
        height = height + (np.abs(z - (info["z_waist"] - 0.04)) < 0.002) * (~legs) * -1.2
        loops = (~legs) & (z > info["z_waist"] - 0.045) & ((np.mod(u - 0.55, 0.17 * np.pi / 3) < 0.012))
        height = height + loops * 1.2
        col = np.where(loops[..., None], col * 0.88, col)
        if kind == "cargo":
            for s, c0 in (("l", 1.2), ("r", 1.75)):
                p0, p1 = info["pocket"][s]
                # outer thigh: theta ~ +-pi/2 around the leg (both signs: the outseam sits there)
                for sgn in (1, -1):
                    cu = c0 + sgn * 0.075 * np.pi / 2
                    inx = np.abs(u - cu) < 0.085
                    iny = (-v > p0) & (-v < p1)
                    border = inx & iny & ((np.abs(np.abs(u - cu) - 0.085) < 0.003) | (np.abs(-v - p1) < 0.003))
                    flapline = inx & (np.abs(-v - (p0 + 0.045)) < 0.0025)
                    snap = inx & ((u - cu) ** 2 + (-v - (p0 + 0.03)) ** 2 < 0.006 ** 2)
                    col = np.where((border | flapline)[..., None], col * 0.72, col)
                    col = np.where(snap[..., None], np.array([0.05, 0.05, 0.045]), col)
                    height = height - border * 1.0 - flapline * 1.4 + snap * 1.5
            dirt = sstep(0.14, 0.04, z)
            col = col * (1 - 0.3 * dirt[..., None]) + np.array([0.1, 0.09, 0.07]) * 0.3 * dirt[..., None]
        else:
            # the turned-up cuff line and a bit of fade on the thighs
            for s in "lr":
                pass
            hem = legs & (np.abs(-v - (info["t_hem_mean"] - 0.03)) < 0.002)
            height = height - hem * 1.3
            col = np.where(hem[..., None], col * 0.8, col)
        rough[:] = 0.86
        return col, height, rough
    return f


def socks_extra(top):
    def f(col, height, rough, fab, pos):
        z = pos[..., 2]
        u = fab[..., 0]
        ribs = np.sin(u / 0.0022 * np.pi)
        cuff = z > top - 0.035
        height = height + ribs * (0.5 + 0.9 * cuff)
        for zz in (top - 0.05, top - 0.065):
            band = np.abs(z - zz) < 0.004
            col = np.where(band[..., None], np.array([0.03, 0.05, 0.16]), col)
        rough[:] = 0.92
        return col, height, rough
    return f


def canvas_shoe_texture(size=1024):
    """Hi-top upper in its analytic UV (u = heel->toe, v = round the section): black
    canvas, a white rubber toe cap and foxing tape, eyelets, a heel stripe."""
    cv = C.make_seamless(C.src_array("twill", 1024))
    cv = C.resize(cv, size)
    u = np.linspace(0, 1, size)[None, :].repeat(size, 0)
    v = 1 - np.linspace(0, 1, size)[:, None].repeat(size, 1)
    ang = v * 2 * np.pi
    top = np.sin(ang)
    lum = C.luminance(cv)
    col = np.ones((size, size, 3)) * np.array([0.028, 0.028, 0.032]) * (0.7 + 0.6 * (lum / lum.mean()))[..., None]
    toe = (u > 0.82) & (top < 0.35)
    fox = top < -0.55
    rub = np.array([0.86, 0.85, 0.8])
    col = np.where((toe | fox)[..., None], rub, col)
    red = (np.abs(top + 0.5) < 0.025)
    col = np.where(red[..., None], np.array([0.6, 0.05, 0.04]), col)
    ey = np.zeros_like(u, bool)
    for k in range(10):
        uc = 0.2 + k * 0.05
        for vc in (0.25 - 0.08, 0.25 + 0.08):
            ey |= ((u - uc) ** 2 * 1400 + (v - vc) ** 2 * 1400) < 0.02
    col = np.where(ey[..., None], np.array([0.75, 0.75, 0.74]), col)
    stitch = (np.abs(u - 0.8) < 0.0018) & ((v * 180) % 1 < 0.5) & (top < 0.35)
    col = np.where(stitch[..., None], np.array([0.7, 0.7, 0.68]), col)
    height = C.highpass(lum, 4) * 2.5 + ey * -2.0 - stitch * 0.8 + toe * 0.8
    rough = np.where(toe | fox, 0.55, 0.9)
    return col, height, rough


def suede_colourway(size=1024):
    """The suede low-top in navy with a white stripe and a gum sole: the grey suede photo
    re-dyed, the same layout as skater_clothes.suede_shoe_texture."""
    col, height, rough = SC.suede_shoe_texture(size)
    lum = C.luminance(col)
    stripe = rough < 0.5
    navy = np.array([0.09, 0.12, 0.27]) * (0.6 + 0.8 * (lum / max(1e-4, float(lum.mean()))))[..., None]
    white = np.array([0.86, 0.85, 0.82])
    out = np.where(stripe[..., None], white, navy)
    bright = lum > 0.5         # stitching stays light
    out = np.where((bright & ~stripe)[..., None], np.array([0.8, 0.78, 0.72]), out)
    return out, height, rough


def gum_sole(size=512):
    col, height, rough = SC.sole_texture(size)
    lum = C.luminance(col)
    gum = np.array([0.62, 0.42, 0.22]) * (0.75 + 0.35 * lum / max(1e-4, float(lum.mean())))[..., None]
    return gum, height, rough


def knit_texture(size, tint, cuff_v=0.72):
    """Beanie in its analytic UV: rib knit tiled round (u) and down (v), a fold shadow
    at the cuff, the crown gathered at the top."""
    tile = SC.srgb_to_lin(C.make_seamless(C.src_array("rib_knit", 1024)))
    u = np.linspace(0, 1, size)[None, :].repeat(size, 0)
    v = 1 - np.linspace(0, 1, size)[:, None].repeat(size, 1)     # 0 = crown ... 0.72 edge ... 1 cuff top
    vv = np.where(v < cuff_v, v / cuff_v * 0.2, 0.2 + (v - cuff_v) / (1 - cuff_v) * 0.058)
    uu = u * 0.62
    tm = 0.12
    th, tw = tile.shape[:2]
    samp = tile[((vv / tm) % 1 * th).astype(int) % th, ((uu / tm) % 1 * tw).astype(int) % tw]
    lum = C.luminance(samp)
    col = samp * np.array(tint) / max(1e-4, float(C.luminance(tile).mean()))
    fold = np.exp(-((v - cuff_v) / 0.012) ** 2)
    crown = sstep(0.12, 0.0, v)
    col = col * (1 - 0.35 * fold[..., None]) * (1 - 0.25 * crown[..., None])
    hp = C.highpass(C.luminance(tile), 5)
    hp /= hp.std() + 1e-6
    height = hp[((vv / tm) % 1 * th).astype(int) % th, ((uu / tm) % 1 * tw).astype(int) % tw] * 1.2 - fold * 2.0
    rough = np.full((size, size), 0.93)
    return col, height, rough


def cap_texture(size):
    """Cap in its analytic UV (crown v 0.3..1, brim 0..0.3): navy twill, six panel seams
    with top-stitching, eyelets, a front logo, the brim's rows of stitching."""
    tile = SC.srgb_to_lin(C.make_seamless(C.src_array("twill", 1024)))
    u = np.linspace(0, 1, size)[None, :].repeat(size, 0)
    v = 1 - np.linspace(0, 1, size)[:, None].repeat(size, 1)
    th, tw = tile.shape[:2]
    tm = 0.06
    samp = tile[((v * 0.5 / tm) % 1 * th).astype(int) % th, ((u * 0.6 / tm) % 1 * tw).astype(int) % tw]
    lum = C.luminance(samp) / max(1e-4, float(C.luminance(tile).mean()))
    navy = np.array([0.02, 0.028, 0.07])
    col = navy * (0.7 + 0.5 * lum)[..., None]
    crown = v > 0.3
    tt = (1 - v) / 0.7          # 0 at the top of the crown .. 1 at the band
    seam_u = np.abs(((u + 1 / 12) % (1 / 6)) - 1 / 12)
    seam = crown & (seam_u < 0.0012)
    st = crown & (np.abs(seam_u - 0.004) < 0.0008) & ((tt * 140) % 1 < 0.55)
    col = np.where(st[..., None], col * 2.2 + 0.03, col)
    height = (lum - 1) * 1.2 - seam * 1.5 + st * 0.5
    eye = crown & (((u % (1 / 6)) - 1 / 12) ** 2 * 1600 + (tt - 0.32) ** 2 * 900 < 0.03)
    col = np.where(eye[..., None], navy * 0.4, col)
    height = height - eye * 1.5
    band = crown & (tt > 0.93)
    col = np.where(band[..., None], col * 0.8, col)
    # the logo on the two front panels (u ~ 0 / 1 wraps at the centre front)
    art = _print_art("cap")
    uc = ((u + 0.5) % 1.0) - 0.5
    a = _sample_art(art, (uc + 0.07) / 0.14, (tt - 0.38) / 0.3) * crown[..., None]
    al = a[..., 3]
    col = col * (1 - al[..., None]) + SC.srgb_to_lin(np.clip(a[..., :3], 0, 1)) * al[..., None]
    height = height + al * 0.8
    # brim: concentric stitching rows
    brim = ~crown
    rows = brim & (np.abs(((v / 0.3) * 8) % 1 - 0.5) < 0.05) & ((u * 400) % 1 < 0.55)
    col = np.where(rows[..., None], col * 2.0 + 0.02, col)
    height = height + rows * 0.4
    btn = (u > 0.96) & (v > 0.96)
    rough = np.full((size, size), 0.86)
    return col, height, rough


def texture(G, info, prof, male_ref=True, size=None):
    """G: garment id -> {part name: object}. The male bakes; the female reuses."""
    size = size or (1024 if C.FAST else 2048)
    male = prof.get("key", "male") == "male"
    if bpy.context.scene.world is None:
        bpy.context.scene.world = bpy.data.worlds.new("World")
    jobs = []   # (object, material name, tile, tile_m, tint, extra, strength, bake size)
    jobs.append((G["tee"]["Tee"], "Tee", "cotton_tee", 0.06, (0.88, 0.86, 0.82), tee_extra(info["tee"]), 1.0, size))
    jobs.append((G["tee"]["CrewBand"], "CrewBand", "cotton_tee", 0.03, (0.86, 0.84, 0.8), None, 1.4, size // 4))
    jobs.append((G["flannel"]["Flannel"], "Flannel", "flannel", 0.08, (1, 1, 1), flannel_extra(info["flannel"]), 1.1, size))
    jobs.append((G["flannel"]["Collar"], "Collar", "flannel", 0.08, (1, 1, 1), flannel_extra(dict(info["flannel"], cuff_t=99)), 1.0, size // 4))
    jobs.append((G["cargo"]["Cargo"], "Cargo", "twill", 0.07, (0.3, 0.32, 0.17), trousers_extra("cargo", info["cargo"]), 1.4, size))
    jobs.append((G["shorts"]["Shorts"], "Shorts", "twill", 0.07, (0.62, 0.52, 0.36), trousers_extra("shorts", info["shorts"]), 1.3, size))
    jobs.append((G["socks"]["Socks"], "Socks", "rib_knit", 0.05, (0.86, 0.86, 0.84), socks_extra(info["socks_top"]), 1.0, size // 2))
    if male:
        SC.texture(info["parts"], size)          # the original hoodie, jeans and suede shoes
        for ob, mname, tile, tm, tint, extra, strength, sz in jobs:
            col, height, rough, ao = SC.bake_garment(ob, sz, _tile(tile), tm, tint, extra)
            m = SC.material_from_maps(mname, SC.to_srgb(col), height, rough, strength * sz / 2048)
            C.assign(ob, m)
        for key in ("hoodie", "jeans", "hood_roll", "hood_back"):
            _save_uv(info["parts"][key])
        for ob, *_ in jobs:
            _save_uv(ob)
        # shoes that are not baked: analytic UVs, the same on both bodies
        col, height, rough = canvas_shoe_texture(1024 if not C.FAST else 512)
        SC.material_from_maps("HiTopUpper", col, height, rough, 1.4)
        col, height, rough = SC.sole_texture(512)
        SC.material_from_maps("HiTopSole", col * np.array([1.0, 1.0, 1.0]), height, rough, 1.0)
        col, height, rough = suede_colourway(1024 if not C.FAST else 512)
        SC.material_from_maps("ShoeUpperNavy", col, height, rough, 1.5).use_fake_user = True
        col, height, rough = gum_sole(512)
        SC.material_from_maps("ShoeSoleGum", col, height, rough, 1.0).use_fake_user = True
        col, height, rough = knit_texture(1024, (0.62, 0.40, 0.08))
        SC.material_from_maps("Beanie", SC.to_srgb(col), height, rough, 1.3)
        col, height, rough = cap_texture(1024)
        SC.material_from_maps("Cap", SC.to_srgb(col), height, rough, 1.0)
    else:
        for key in ("hoodie", "jeans", "hood_roll", "hood_back"):
            _load_uv(info["parts"][key])
        for ob, *_ in jobs:
            _load_uv(ob)
        mats = {"hoodie": "Hoodie", "jeans": "Jeans", "hood_roll": "Hood_hood_roll", "hood_back": "Hood_hood_back"}
        for key, mname in mats.items():
            C.assign(info["parts"][key], shared_material(mname))
        for ob, mname, *_ in jobs:
            C.assign(ob, shared_material(mname))
        cord = shared_material("Cord", dict(base_color=(0.75, 0.74, 0.7, 1), roughness=0.8))
        metal = shared_material("Aglet", dict(base_color=(0.6, 0.6, 0.62, 1), roughness=0.3, metallic=1.0))
        for s, a in info["parts"]["strings"]:
            C.assign(s, cord)
            C.assign(a, metal)
        up, so = shared_material("ShoeUpper"), shared_material("ShoeSole")
        lace = shared_material("Laces", dict(base_color=(0.02, 0.02, 0.022, 1), roughness=0.75))
        tongue = shared_material("ShoeTongue", dict(base_color=(0.16, 0.16, 0.17, 1), roughness=0.9))
        for sh in info["parts"]["shoes"]:
            C.assign(sh["upper"], up); C.assign(sh["sole"], so); C.assign(sh["laces"], lace); C.assign(sh["tongue"], tongue)
    # everything below uses analytic UVs or plain materials: same on both bodies
    hu, hs = shared_material("HiTopUpper"), shared_material("HiTopSole")
    hl = shared_material("HiTopLaces", dict(base_color=(0.82, 0.81, 0.78, 1), roughness=0.8))
    ht = shared_material("HiTopTongue", dict(base_color=(0.03, 0.03, 0.035, 1), roughness=0.92))
    for sh in info["hitops"]:
        C.assign(sh["upper"], hu); C.assign(sh["sole"], hs); C.assign(sh["laces"], hl); C.assign(sh["tongue"], ht)
    C.assign(G["beanie"]["Beanie"], shared_material("Beanie"))
    C.assign(G["cap"]["Cap"], shared_material("Cap"))
    C.assign(G["flannel"]["Buttons"], shared_material("Buttons", dict(base_color=(0.78, 0.74, 0.64, 1), roughness=0.35)))
    # the hi-top weightings (socks, jeans, cargo): the same UVs and materials as the base
    for g in ("socks", "jeans", "cargo"):
        lo = next(iter(G[g].values()))
        hi = next(iter(G[g + "_high"].values()))
        for uv in lo.data.uv_layers:
            if uv.name not in hi.data.uv_layers:
                hi.data.uv_layers.new(name=uv.name)
            a = np.zeros(len(lo.data.loops) * 2, np.float32)
            uv.data.foreach_get("uv", a)
            hi.data.uv_layers[uv.name].data.foreach_set("uv", a)
        hi.data.uv_layers.active_index = lo.data.uv_layers.active_index
        hi.data.materials.clear()
        for m in lo.data.materials:
            hi.data.materials.append(m)


# ------------------------------------------------------------------ the whole wardrobe

def build(body, rig, face, coll, prof, ref=None):
    """Every garment for this body. ref: None for the male (the reference), else the
    male's masks and dimensions (reference()). Returns (G, info): G maps garment id ->
    {object name: object}; info holds what texturing, hair masks and export need."""
    lab = SC.classify(body)
    male = ref is None
    K = (lambda k: None) if male else (lambda k: ref["keep"][k])
    D = (lambda k: None) if male else (lambda k: ref["dims"][k])
    # the original skater's three, built exactly as skater_clothes.build made them
    hoodie, hinfo = SC.build_hoodie(body, rig, lab, coll, keep=K("hoodie"), ref=D("hoodie"))
    # the tops bridge the bust apexes and the navel (today's hoodie keeps its shape)
    bridged = {}
    if not male:
        bridged["hoodie"] = flatten_spots(hoodie, top_spots(hoodie, rig))
    roll, pillow = SC.build_hood(body, rig, hoodie, hinfo, coll)
    strings = SC.build_drawstrings(hoodie, rig, hinfo, coll)
    jeans, jinfo = SC.build_jeans(body, rig, lab, coll, keep=K("jeans"), ref=D("jeans"))
    SC.fit_layers(hoodie, jeans, hinfo)
    shoes = [SC.build_shoe(body, rig, s, coll, lab) for s in ("l", "r")]
    parts = dict(hoodie=hoodie, hood_roll=roll, hood_back=pillow, strings=strings, jeans=jeans,
                 shoes=shoes, hinfo=hinfo, jinfo=jinfo)
    # the new ones
    tee, tinfo = build_top(body, rig, lab, coll, "tee", keep=K("tee"), ref=D("tee"))
    bridged["tee"] = flatten_spots(tee, top_spots(tee, rig))
    band = build_crew_band(body, tee, tinfo, coll)
    fl, finfo = build_top(body, rig, lab, coll, "flannel", keep=K("flannel"), ref=D("flannel"))
    bridged["flannel"] = flatten_spots(fl, top_spots(fl, rig))
    print(f"[outfit] tops bridge the bust apexes and navel: { {k: f'{v * 1000:.1f} mm' for k, v in bridged.items()} }")
    cargo, cinfo = build_trousers(body, rig, lab, coll, "cargo", keep=K("cargo"), ref=D("cargo"))
    shorts, sinfo = build_trousers(body, rig, lab, coll, "shorts", keep=K("shorts"), ref=D("shorts"))
    tucks = [tuck_bottom(b, hoodie, hinfo["z_hem"]) for b in (cargo, shorts)]
    flares = [flare_top(tee, [jeans, cargo, shorts], tinfo["z_hem"]),
              flare_top(fl, [jeans, cargo, shorts], finfo["d"]["z_hem"] - finfo["d"]["tail"] * 0.5)]
    print(f"[outfit] layering: cargo/shorts tucked under the hoodie ({tucks} verts), tee/flannel flared {flares}")
    collar = build_collar(body, fl, finfo, coll)
    buttons = build_buttons(body, fl, finfo, coll)
    socks = build_socks(body, rig, lab, coll, keep=K("socks"))
    hitops = [build_hitop(body, rig, s, coll, lab) for s in ("l", "r")]
    hf = head_frame(body, face)
    beanie, binfo = build_beanie(body, hf, coll, rig)
    cap, capinfo = build_cap(body, hf, coll, rig)
    # body cells: which garments cover each face
    kill = kill_masks(body, rig, lab) if male else ref["kill"]
    if male:
        default = kill["hoodie"] | kill["jeans"] | kill["shoes_low"] | kill["socks"]
        orig = SC.trim_kill(body, rig, lab, hinfo)
        assert np.array_equal(default, orig), "default outfit must hide exactly the original trim"
    fbits = body_cells(body, kill)
    print(f"[outfit] body cells: {len(np.unique(fbits))} distinct cover masks over {len(fbits)} faces")

    def objs(*obs):
        return {o.name: o for o in obs}
    G = {
        "hoodie": objs(hoodie, roll, pillow, *[x for pair in strings for x in pair]),
        "tee": objs(tee, band), "flannel": objs(fl, collar, buttons),
        "jeans": objs(jeans), "cargo": objs(cargo), "shorts": objs(shorts),
        "suede": objs(*[sh[k] for sh in shoes for k in ("upper", "sole", "tongue", "laces")]),
        "hitop": objs(*[sh[k] for sh in hitops for k in ("upper", "sole", "tongue", "laces")]),
        "socks": objs(socks), "beanie": objs(beanie), "cap": objs(cap),
    }
    # the hi-top weightings: copies of the socks, jeans and cargo (fit_in_motion re-weights them)
    for g in ("socks", "jeans", "cargo"):
        ob = next(iter(G[g].values()))
        hi = ob.copy()
        hi.data = ob.data.copy()
        hi.name = ob.name + "High"
        C.link(hi, coll)
        G[g + "_high"] = {hi.name: hi}
    finfo = dict(finfo, cuff_t=float(np.mean(list(finfo["sleeve_t"].values()))))
    sinfo = dict(sinfo, t_hem_mean=float(np.mean(list(sinfo["t_hem"].values()))))
    info = dict(parts=parts, tee=tinfo, flannel=finfo, cargo=cinfo, shorts=sinfo, socks_top=sock_top(rig),
                hitops=hitops, hats={"beanie": binfo, "cap": capinfo}, kill=kill, lab=lab, hf=hf)
    return G, info


def trimmed_copy(body, kill):
    """A copy of the body without the skin the default outfit hides (what the hair stage
    and anything else that measured the original trimmed body should see)."""
    ob = body.copy()                      # (keeps the vertex group names)
    ob.data = body.data.copy()
    me = ob.data
    ob.name = body.name + "_trimmed"
    bpy.context.scene.collection.objects.link(ob)
    bm = bmesh.new()
    bm.from_mesh(me)
    bm.verts.ensure_lookup_table()
    k = kill["hoodie"] | kill["jeans"] | kill["shoes_low"] | kill["socks"]
    bmesh.ops.delete(bm, geom=[bm.verts[i] for i in np.nonzero(k)[0]], context='VERTS')
    bm.to_mesh(me)
    bm.free()
    return ob


def keep_default_normals(body, kill):
    """The original skater's body was cut back to the skin his outfit leaves, so the
    vertices along the cut (collar, cuffs, hems, shoe tops) had normals from the visible side
    alone. The whole body now carries every face, which would turn those normals by up to
    ~5 degrees. Give the body exact per-vertex normals ('custom_normal', free float
    vectors): the trimmed body's (computed the way the original export computed them) where
    it has faces, the whole body's own everywhere else - so the default skater is drawn
    exactly as before, and one normal serves both sides of the cut when other clothes show
    the skin beyond it."""
    me = body.data
    if "custom_normal" in me.attributes:
        me.attributes.remove(me.attributes["custom_normal"])
    full = np.zeros(len(me.vertices) * 3, np.float32)
    me.vertices.foreach_get("normal", full)
    full = full.reshape(-1, 3)
    k = kill["hoodie"] | kill["jeans"] | kill["shoes_low"] | kill["socks"]
    kept = np.nonzero(~k)[0]
    tr = trimmed_copy(body, kill)
    tn = np.zeros(len(tr.data.vertices) * 3, np.float32)
    tr.data.vertices.foreach_get("normal", tn)
    tn = tn.reshape(-1, 3)
    used = np.zeros(len(tr.data.vertices), bool)
    lv = np.zeros(len(tr.data.loops), np.int64)
    tr.data.loops.foreach_get("vertex_index", lv)
    used[lv] = True
    bpy.data.objects.remove(tr, do_unlink=True)
    assert len(kept) == len(tn)
    out = full.copy()
    out[kept[used]] = tn[used]
    changed = int((np.abs(out - full).max(1) > 0).sum())
    a = me.attributes.new("custom_normal", 'FLOAT_VECTOR', 'POINT')
    a.data.foreach_set("vector", out.ravel())
    me.update()
    return changed


# ------------------------------------------------------------------ wearing an outfit (renders)

DEFAULT = {"top": "hoodie", "bottom": "jeans", "shoes": "suede", "hat": "none"}


def worn_bits(outfit):
    bits = 1 << CELL_BITS["socks"]
    for slot in ("top", "bottom", "shoes"):
        for cls in COVERS.get(outfit[slot], []):
            bits |= 1 << CELL_BITS[cls]
    hat = 0 if outfit["hat"] == "none" else 1 << HAT_BITS[outfit["hat"]]
    return bits, hat


def _face_bits(me, name):
    a = me.color_attributes.get(name)
    col = np.zeros(len(me.loops) * 4, np.float32)
    a.data.foreach_get("color", col)
    col = col.reshape(-1, 4)
    start = np.zeros(len(me.polygons), np.int64)
    me.polygons.foreach_get("loop_start", start)
    c = col[start]
    return np.round(c[:, 0] * 255).astype(np.int64) | (np.round(c[:, 1] * 255).astype(np.int64) << 8)


def wear(outfit):
    """Show one outfit in the Blender scene (renders): garment objects of other options are
    hidden, the body and hair lose the faces the worn garments and hat cover."""
    cat = json.load(open(os.path.join(C.ASSETS, "outfit", "catalog.json")))
    bits, hat = worn_bits(outfit)
    show = set()
    high = "shoes_high" in cat["garments"][outfit["shoes"]].get("covers", [])
    for slot in ("top", "bottom", "shoes", "hat"):
        g = outfit[slot]
        if g == "none":
            continue
        base = cat["garments"][g].get("base", g)
        if high and cat["garments"][base].get("with_high_shoes"):
            base = cat["garments"][base]["with_high_shoes"]
        show |= set(cat["garments"][base]["parts"])
    if cat["garments"][outfit["bottom"]].get("shows_socks"):
        show |= set(cat["garments"]["socks_high" if high else "socks"]["parts"])
    all_parts = set()
    for g in cat["garments"].values():
        all_parts |= set(g.get("parts", []))
    for o in bpy.data.objects:
        if o.name in all_parts:
            o.hide_render = o.name not in show
            o.hide_viewport = o.name not in show
    for name, attr, mask in (("SkaterBody", "cells", bits), ("Hair", "hatcells", hat)):
        ob = bpy.data.objects.get(name)
        if ob is None or ob.data.color_attributes.get(attr) is None:
            continue
        fb = _face_bits(ob.data, attr)
        bm = bmesh.new()
        bm.from_mesh(ob.data)
        bm.faces.ensure_lookup_table()
        bmesh.ops.delete(bm, geom=[bm.faces[i] for i in np.nonzero(fb & mask)[0]], context='FACES')
        bm.to_mesh(ob.data)
        bm.free()
    # colourways: swap the base garment's materials
    over = cat["garments"][outfit["shoes"]].get("materials", {})
    for o in bpy.data.objects:
        if o.name in show:
            for sl in o.material_slots:
                if sl.material and sl.material.name in over:
                    sl.material = bpy.data.materials.get(over[sl.material.name]) or sl.material


# ------------------------------------------------------------------ export

def catalog(prof_keys=("male", "female")):
    out = {"slots": SLOTS, "labels": LABELS, "cell_bits": CELL_BITS, "hat_bits": HAT_BITS, "garments": {}}
    return out


def export(G, info, rig, prof, extra_mats=()):
    """assets/outfit/<body>_<garment>.glb: the garment's meshes skinned to the body's rig.
    The male files carry the textures; the female files carry none (the game gives her
    garments the male garment's materials: one set of textures for both)."""
    import anims
    male = prof.get("key", "male") == "male"
    folder = os.path.join(C.ASSETS, "outfit")
    os.makedirs(folder, exist_ok=True)
    fabric = {"Hoodie", "Jeans", "Hood_hood_roll", "Hood_hood_back", "Tee", "CrewBand", "Flannel", "Collar",
              "Cargo", "Shorts", "Socks", "Beanie", "Cap"}
    cat_path = os.path.join(folder, "catalog.json")
    cat = json.load(open(cat_path)) if os.path.exists(cat_path) else catalog()
    cat.update(catalog())
    for g, parts in G.items():
        objs = list(parts.values())
        # the cap's top button is a bmesh UV sphere: like the eyes, its triangles come out in
        # a varying order from build to build, so sort the cap's faces into a fixed order
        anims._fix_face_order([o for o in objs if o.name == "Cap"])
        anims.game_textures(objs)
        path = os.path.join(folder, f"{prof['key']}_{g}.glb")
        C.export_glb(path, objects=[rig] + objs, animations=False, extra=dict(
            export_image_format='WEBP' if male and not g.endswith("_high") else 'NONE', export_image_quality=88, export_skins=True,
            export_def_bones=False, export_morph=False, export_vertex_color='NONE'))
        mats = sorted({sl.material.name for o in objs for sl in o.material_slots if sl.material})
        e = cat["garments"].setdefault(g, {})
        e.update(parts=sorted(parts.keys()), materials_used=mats, fabric=sorted(set(mats) & fabric))
    # the navy colourway: its two materials on a hidden swatch (the game swaps them onto the
    # grey suede shoes' meshes)
    if male:
        sw = []
        for k, mname in enumerate(("ShoeUpperNavy", "ShoeSoleGum")):  # noqa
            ob = C.mesh_object(f"Swatch_{mname}", [(k, 0, 0), (k + 0.01, 0, 0), (k, 0, 0.01)], [(0, 1, 2)], None)
            ob.data.uv_layers.new(name="UVMap")
            C.assign(ob, shared_material(mname))
            sw.append(ob)
        anims.game_textures(sw)
        C.export_glb(os.path.join(folder, "male_suede_navy.glb"), objects=sw, animations=False,
                     extra=dict(export_image_format='WEBP', export_image_quality=88))
        for ob in sw:
            bpy.data.objects.remove(ob, do_unlink=True)
    for g in SLOTS["top"] + SLOTS["bottom"] + SLOTS["shoes"] + SLOTS["hat"]:
        if g == "none":
            continue
        e = cat["garments"].setdefault(g, {})
        e["label"] = LABELS[g]
        e["slot"] = next(s for s, opts in SLOTS.items() if g in opts)
        e["covers"] = COVERS.get(g, [])
        if g in HAT_BITS:
            e["hat_bit"] = HAT_BITS[g]
    cat["garments"]["socks"].update(label="Crew socks", slot="", covers=["socks"])
    for g, lab in (("socks", "Crew socks"), ("jeans", LABELS["jeans"]), ("cargo", LABELS["cargo"])):
        base = cat["garments"][g]
        cat["garments"][g + "_high"].update(label=lab + " (with hi-tops)", slot="", covers=base["covers"] if g != "socks" else ["socks"],
                                            materials={m: m for m in base["materials_used"]}, material_source=f"male_{g}.glb")
        if g != "socks":
            base["with_high_shoes"] = g + "_high"
    cat["garments"]["shorts"]["shows_socks"] = True
    cat["garments"]["suede_navy"].update(base="suede", materials={"ShoeUpper": "ShoeUpperNavy", "ShoeSole": "ShoeSoleGum"},
                                         material_source="male_suede_navy.glb")
    cat["default"] = DEFAULT
    cat.setdefault("bodies", {})[prof["key"]] = dict(glb=prof["glb"], ankle_h=info.get("ankle_h"))
    with open(cat_path, "w") as f:
        json.dump(cat, f, indent=1, sort_keys=True)
    return cat
