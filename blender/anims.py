"""Skater animation clips, authored as Python keyframes, baked to FK and exported.

A temporary control rig drives the MPFB game_engine skeleton:
  * 'board'        - a real (exported) bone that carries the skateboard. The game attaches
                     board.glb to it, so the board's motion is its own animated object.
  * ik_foot_l/r    - leg IK targets (with auto-solved pole angles). Each frame they are
                     placed on the deck at the foot's stance spot, i.e. computed from the
                     board bone's transform, so the feet stay planted through every trick.
                     During flips the feet hover a few cm over the board, ignore its roll,
                     and catch it again exactly on the bolts.
  * ik_hand_l/r    - arm IK used for grabs (the hand is pinned to the board edge).
Clips are lists of keyed poses (Catmull-Rom interpolated); every frame is evaluated with
the constraints, read back as bone matrices and written as plain FK keys, then the
control bones and constraints are removed before export.
"""
import math

import bpy
import numpy as np
from mathutils import Euler, Matrix, Quaternion, Vector

from lib import common as C
import board as B

FPS = 30
DECK_TOP = B.THICK / 2 + 0.003       # deck top above the board bone (mid-deck)
ANKLE_H = 0.0725                     # ankle above the shoe sole
ANKLE_BACK = 0.082                   # ankle sits this far behind the shoe centre
BOARD_REST = Vector((0.0, 0.0, B.DECK_Z))
SPINE = [("spine_01", 0.3), ("spine_02", 0.3), ("spine_03", 0.4)]
FK_BONES = ["pelvis", "spine_01", "spine_02", "spine_03", "neck_01", "head",
            "clavicle_l", "upperarm_l", "lowerarm_l", "hand_l",
            "clavicle_r", "upperarm_r", "lowerarm_r", "hand_r"]
FINGERS = ["index", "middle", "ring", "pinky", "thumb"]

# ------------------------------------------------------------------ pose defaults (riding)
BASE = dict(
    b_pos=(0.0, 0.0, 0.0), b_rot=(0.0, 0.0, 0.0), stick=1.0, stick_yaw=1.0,
    fl=(0.165, 0.018, 52.0, 0.0),        # front (left) foot on the deck: x, y, yaw, lift
    fr=(-0.225, 0.006, 14.0, 0.0),       # back (right) foot
    fl_ground=(0.0, 0.1, -0.15, 0.0, 60.0),   # blend, x, y, z(lift), yaw  (world/root frame)
    fr_ground=(0.0, -0.05, -0.17, 0.0, 70.0),
    hips=(-0.03, 0.05, -0.125),          # pelvis offset from 'standing on the deck'
    hips_rot=(10.0, 0.0, 22.0),
    sp=(8.0, 0.0, 14.0), neck=(0.0, 0.0, 14.0), head=(-6.0, 0.0, 40.0),
    clav_l=(0.0, 0.0, 0.0), ua_l=(12.0, 28.0, 0.0), la_l=(0.0, 0.0, 0.0), hand_l=(0.0, 0.0, 0.0),
    clav_r=(0.0, 0.0, 0.0), ua_r=(12.0, 28.0, 0.0), la_r=(0.0, 0.0, 0.0), hand_r=(0.0, 0.0, 0.0),
    ik_hand_l=(0.0, 0.0, 0.0, 0.0), ik_hand_r=(0.0, 0.0, 0.0, 0.0),
    knee_l=0.0, knee_r=0.0, fingers=0.35,
)


class Clip:
    def __init__(self, name, frames, loop=False):
        self.name, self.frames, self.loop = name, frames, loop
        self.keys = []

    def key(self, t, **ch):
        self.keys.append((t, ch))
        return self

    def channel(self, name, t):
        ks = sorted([(kt, kc[name]) for kt, kc in self.keys if name in kc], key=lambda k: k[0])
        if not ks:
            return BASE[name]
        if len(ks) == 1:
            return ks[0][1]
        if self.loop:
            # wrap: add the first key at t=1 and the last at t<0
            ks = [(ks[-1][0] - 1.0, ks[-1][1])] + ks + [(ks[0][0] + 1.0, ks[0][1]), (ks[1][0] + 1.0, ks[1][1])]
            t = t % 1.0
        if t <= ks[0][0]:
            return ks[0][1]
        if t >= ks[-1][0]:
            return ks[-1][1]
        i = max(k for k in range(len(ks) - 1) if ks[k][0] <= t)
        t0, v0 = ks[i]
        t1, v1 = ks[i + 1]
        vm = ks[i - 1][1] if i > 0 else v0
        vp = ks[i + 2][1] if i + 2 < len(ks) else v1
        u = (t - t0) / max(1e-6, t1 - t0)
        return _catmull(vm, v0, v1, vp, u)


def _catmull(p0, p1, p2, p3, u):
    a0 = np.atleast_1d(np.asarray(p0, float)); a1 = np.atleast_1d(np.asarray(p1, float))
    a2 = np.atleast_1d(np.asarray(p2, float)); a3 = np.atleast_1d(np.asarray(p3, float))
    # centripetal-ish tangents scaled down to avoid overshoot
    m1 = (a2 - a0) * 0.35
    m2 = (a3 - a1) * 0.35
    u2, u3 = u * u, u * u * u
    r = (2 * u3 - 3 * u2 + 1) * a1 + (u3 - 2 * u2 + u) * m1 + (-2 * u3 + 3 * u2) * a2 + (u3 - u2) * m2
    return tuple(r) if r.size > 1 else float(r[0])


def rot(e):
    return Euler((math.radians(e[0]), math.radians(e[1]), math.radians(e[2])), 'XYZ').to_matrix()


def mirror(e):
    return (e[0], -e[1], -e[2])


def wrap180(a):
    return (a + 180.0) % 360.0 - 180.0


# ------------------------------------------------------------------ control rig

def setup_control_rig(rig):
    C.select_only(rig)
    bpy.ops.object.mode_set(mode='EDIT')
    eb = rig.data.edit_bones
    b = eb.new("board")
    b.head = BOARD_REST
    b.tail = BOARD_REST + Vector((0.15, 0, 0))
    b.roll = 0
    b.parent = eb["Root"]
    b.use_deform = True
    for s in "lr":
        f = eb[f"foot_{s}"]
        ik = eb.new(f"ik_foot_{s}")
        ik.head, ik.tail, ik.roll = f.head.copy(), f.tail.copy(), f.roll
        ik.use_deform = False
        k = eb[f"calf_{s}"]
        p = eb.new(f"pole_{s}")
        p.head = k.head + Vector((0, -0.6, 0.05))
        p.tail = p.head + Vector((0, 0, 0.05))
        p.use_deform = False
        h = eb[f"hand_{s}"]
        ih = eb.new(f"ik_hand_{s}")
        ih.head, ih.tail, ih.roll = h.head.copy(), h.tail.copy(), h.roll
        ih.use_deform = False
        ep = eb.new(f"pole_arm_{s}")
        ep.head = eb[f"lowerarm_{s}"].head + Vector((0.0, 0.5, -0.1))
        ep.tail = ep.head + Vector((0, 0, 0.05))
        ep.use_deform = False
    bpy.ops.object.mode_set(mode='POSE')
    pb = rig.pose.bones
    for p in pb:
        p.rotation_mode = 'QUATERNION'
    for s in "lr":
        c = pb[f"calf_{s}"].constraints.new('IK')
        c.target, c.subtarget = rig, f"ik_foot_{s}"
        c.pole_target, c.pole_subtarget = rig, f"pole_{s}"
        c.chain_count = 2
        c.name = "LegIK"
        cr = pb[f"foot_{s}"].constraints.new('COPY_ROTATION')
        cr.target, cr.subtarget = rig, f"ik_foot_{s}"
        cr.name = "FootRot"
        a = pb[f"lowerarm_{s}"].constraints.new('IK')
        a.target, a.subtarget = rig, f"ik_hand_{s}"
        a.pole_target, a.pole_subtarget = rig, f"pole_arm_{s}"
        a.chain_count = 2
        a.influence = 0.0
        a.name = "ArmIK"
    bpy.ops.object.mode_set(mode='OBJECT')
    tune_poles(rig)


def tune_poles(rig):
    """Find the pole angle that keeps each chain in its rest shape."""
    pb = rig.pose.bones
    for chain, tip, cname in (("calf", "calf", "LegIK"), ("lowerarm", "lowerarm", "ArmIK")):
        for s in "lr":
            c = pb[f"{chain}_{s}"].constraints[cname]
            old_inf = c.influence
            c.influence = 1.0
            rest = rig.data.bones[f"{chain}_{s}"].head_local.copy()
            best = (1e9, 0)
            for deg in range(-180, 180, 3):
                c.pole_angle = math.radians(deg)
                bpy.context.view_layer.update()
                d = (pb[f"{chain}_{s}"].head - rest).length
                if d < best[0]:
                    best = (d, deg)
            c.pole_angle = math.radians(best[1])
            c.influence = old_inf
            print("pole", chain, s, best)


# ------------------------------------------------------------------ pose application

class Poser:
    def __init__(self, rig):
        self.rig = rig
        self.rest = {b.name: b.matrix_local.copy() for b in rig.data.bones}
        self.pb = rig.pose.bones

    def _set_rot(self, name, R3):
        rest3 = self.rest[name].to_3x3()
        q = (rest3.inverted() @ R3 @ rest3).to_quaternion()
        self.pb[name].rotation_quaternion = q

    def _set_world(self, name, M):
        """Pose an unparented/root-child bone to an armature-space matrix."""
        basis = self.rest[name].inverted() @ M
        loc, q, _ = basis.decompose()
        self.pb[name].location = loc
        self.pb[name].rotation_quaternion = q

    def apply(self, clip, t):
        g = lambda n: clip.channel(n, t)
        pb = self.pb
        # --- board
        bp = Vector(g("b_pos"))
        roll, pitch, yaw = g("b_rot")
        Rb = (Matrix.Rotation(math.radians(yaw), 3, 'Z') @ Matrix.Rotation(math.radians(pitch), 3, 'Y')
              @ Matrix.Rotation(math.radians(roll), 3, 'X'))
        center = BOARD_REST + bp
        Mb = Matrix.Translation(center) @ (Rb @ self.rest["board"].to_3x3()).to_4x4()
        self._set_world("board", Mb)
        # feet frame: follows the board but only 'stick' of its flip roll / shove-it yaw
        st, sty = min(1.0, max(0.0, g("stick"))), min(1.0, max(0.0, g("stick_yaw")))
        Rf = (Matrix.Rotation(math.radians(wrap180(yaw) * sty), 3, 'Z') @ Matrix.Rotation(math.radians(pitch), 3, 'Y')
              @ Matrix.Rotation(math.radians(wrap180(roll) * st), 3, 'X'))
        Rfull = Rb
        for s, key in (("l", "fl"), ("r", "fr")):
            fx, fy, fyaw, lift = g(key)
            Ryaw = Matrix.Rotation(math.radians(fyaw), 3, 'Z')
            ctr = Vector((fx, fy, DECK_TOP + ANKLE_H + lift))
            ankle_local = ctr + Ryaw @ Vector((0, ANKLE_BACK, 0))
            p_board = center + Rf @ ankle_local
            R_board = Rf @ Ryaw @ self.rest[f"foot_{s}"].to_3x3()
            gb, gx, gy, gz, gyaw = g(key + "_ground")
            gb = min(1.0, max(0.0, gb))
            Rg = Matrix.Rotation(math.radians(gyaw), 3, 'Z')
            p_ground = Vector((gx, gy, ANKLE_H + gz)) + Rg @ Vector((0, ANKLE_BACK, 0))
            R_ground = Rg @ self.rest[f"foot_{s}"].to_3x3()
            p = p_board.lerp(p_ground, gb)
            q = R_board.to_quaternion().slerp(R_ground.to_quaternion(), gb)
            M = Matrix.Translation(p) @ q.to_matrix().to_4x4()
            self._set_world(f"ik_foot_{s}", M)
            # knee pole: in front of the knee, toward the toes
            kyaw = math.radians(fyaw + wrap180(yaw) * sty + g("knee_" + s)) * (1 - gb) + math.radians(gyaw + g("knee_" + s)) * gb
            toe_dir = Matrix.Rotation(kyaw, 3, 'Z') @ Vector((0, -1, 0))
            pole = p + toe_dir * 0.7 + Vector((0, 0, 0.45))
            self._set_world(f"pole_{s}", Matrix.Translation(pole) @ self.rest[f"pole_{s}"].to_3x3().to_4x4())
        # --- pelvis + spine
        hx, hy, hz = g("hips")
        stand = Vector((0, 0, B.DECK_Z + DECK_TOP))
        pel_rest = self.rest["pelvis"]
        loc = stand + Vector((hx, hy, hz))
        pb["pelvis"].location = pel_rest.to_3x3().inverted() @ loc
        self._set_rot("pelvis", rot(g("hips_rot")))
        sx, sy, sz = g("sp")
        for name, w in SPINE:
            self._set_rot(name, rot((sx * w, sy * w, sz * w)))
        self._set_rot("neck_01", rot(g("neck")))
        self._set_rot("head", rot(g("head")))
        for s in "lr":
            m = (lambda e: e) if s == "l" else mirror
            self._set_rot(f"clavicle_{s}", rot(m(g("clav_" + s))))
            self._set_rot(f"upperarm_{s}", rot(m(g("ua_" + s))))
            self._set_rot(f"lowerarm_{s}", rot(m(g("la_" + s))))
            self._set_rot(f"hand_{s}", rot(m(g("hand_" + s))))
            inf, ix, iy, iz = g("ik_hand_" + s)
            c = pb[f"lowerarm_{s}"].constraints["ArmIK"]
            c.influence = max(0.0, min(1.0, inf))
            if inf > 0.001:
                hp = center + Rfull @ Vector((ix, iy, iz))
                self._set_world(f"ik_hand_{s}", Matrix.Translation(hp) @ self.rest[f"hand_{s}"].to_3x3().to_4x4())
                pole = hp + Vector((0.0, 0.45, 0.25)) if s == "r" else hp + Vector((0.0, 0.45, 0.25))
                self._set_world(f"pole_arm_{s}", Matrix.Translation(pole) @ self.rest[f"pole_arm_{s}"].to_3x3().to_4x4())
        # fingers: gentle curl (grabs curl more)
        curl = g("fingers")
        for p in pb:
            n = p.name
            if any(n.startswith(f) for f in FINGERS):
                if n.startswith("thumb"):
                    p.rotation_quaternion = Quaternion((1, 0, 0), curl * 0.3)
                else:
                    p.rotation_quaternion = Quaternion((1, 0, 0), curl * (0.9 if "_01_" in n else 1.1))


# ------------------------------------------------------------------ baking to plain FK

def _channelbag(action, slot):
    from bpy_extras import anim_utils
    return anim_utils.action_ensure_channelbag_for_slot(action, slot)


def bake_clip(rig, poser, clip, bones):
    n = clip.frames
    frames = list(range(1, n + 2)) if clip.loop else list(range(1, n + 1))
    data = {b: ([], []) for b in bones}
    rest = poser.rest
    for i, f in enumerate(frames):
        t = (i / n) if clip.loop else (i / max(1, n - 1))
        poser.apply(clip, t)
        bpy.context.view_layer.update()
        mats = {b: rig.pose.bones[b].matrix.copy() for b in bones}
        for b in bones:
            bone = rig.data.bones[b]
            if bone.parent and bone.parent.name in mats:
                par_pose = mats[bone.parent.name]
                par_rest = rest[bone.parent.name]
                local = (par_rest.inverted() @ rest[b]).inverted() @ par_pose.inverted() @ mats[b]
            elif bone.parent:
                local = (rest[bone.parent.name].inverted() @ rest[b]).inverted() @ rig.pose.bones[bone.parent.name].matrix.inverted() @ mats[b]
            else:
                local = rest[b].inverted() @ mats[b]
            loc, q, _ = local.decompose()
            data[b][0].append(loc)
            data[b][1].append(q)
    act = bpy.data.actions.get(clip.name)
    if act:
        bpy.data.actions.remove(act)
    act = bpy.data.actions.new(clip.name)
    act.use_fake_user = True
    slot = act.slots.new(id_type='OBJECT', name=rig.name)
    cb = _channelbag(act, slot)
    for b in bones:
        locs, qs = data[b]
        # keep quaternion signs continuous
        for k in range(1, len(qs)):
            if qs[k].dot(qs[k - 1]) < 0:
                qs[k] = -qs[k]
        paths = [("location", 3, [tuple(v) for v in locs]), ("rotation_quaternion", 4, [tuple(q) for q in qs])]
        for path, dim, vals in paths:
            if path == "location" and b not in ("pelvis", "board", "Root") and max(np.abs(np.array(vals)).max(0)) < 1e-5:
                continue
            for idx in range(dim):
                fc = cb.fcurves.new(f'pose.bones["{b}"].{path}', index=idx, group_name=b)
                fc.keyframe_points.add(len(frames))
                co = []
                for f, v in zip(frames, vals):
                    co += [f, v[idx]]
                fc.keyframe_points.foreach_set("co", co)
                for kp in fc.keyframe_points:
                    kp.interpolation = 'LINEAR'
                fc.update()
    return act, slot


# ------------------------------------------------------------------ the clips

def clips():
    out = []
    RIDE = dict()  # BASE is the riding stance
    AIR = dict(b_pos=(0.0, 0.0, 0.22), hips=(-0.03, 0.05, -0.14), sp=(14.0, 0.0, 12.0),
               ua_l=(-5.0, 5.0, 0.0), ua_r=(-5.0, 5.0, 0.0), la_l=(0.0, 0.0, 25.0), la_r=(0.0, 0.0, 25.0),
               head=(-2.0, 0.0, 38.0), hips_rot=(14.0, 0.0, 18.0))
    CROUCH = dict(hips=(-0.03, 0.07, -0.33), sp=(28.0, 0.0, 10.0), head=(-22.0, 0.0, 35.0),
                  ua_l=(-35.0, 32.0, 0.0), ua_r=(-35.0, 32.0, 0.0), la_l=(0.0, 0.0, 35.0), la_r=(0.0, 0.0, 35.0),
                  hips_rot=(20.0, 0.0, 18.0))

    c = Clip("idle", 60, loop=True)
    c.key(0.0, hips=(-0.02, 0.04, -0.06), sp=(4.0, 0.0, 10.0), head=(-3.0, 0.0, 30.0), ua_l=(6.0, 36.0, 0.0), ua_r=(6.0, 36.0, 0.0), la_l=(0, 0, 12.0), la_r=(0, 0, 12.0))
    c.key(0.5, hips=(-0.02, 0.04, -0.07), sp=(6.0, 0.0, 12.0), head=(-5.0, 0.0, 42.0), ua_l=(4.0, 37.0, 0.0), ua_r=(8.0, 35.0, 0.0), la_l=(0, 0, 14.0), la_r=(0, 0, 10.0))
    out.append(c)

    c = Clip("ride", 40, loop=True)
    c.key(0.0, hips=(-0.03, 0.05, -0.125), ua_l=(12.0, 26.0, 0.0), ua_r=(10.0, 24.0, 0.0), la_l=(0, 0, 18.0), la_r=(0, 0, 15.0))
    c.key(0.5, hips=(-0.03, 0.05, -0.135), ua_l=(10.0, 24.0, 0.0), ua_r=(13.0, 27.0, 0.0), la_l=(0, 0, 15.0), la_r=(0, 0, 19.0), sp=(9.0, 0.0, 15.0))
    out.append(c)

    c = Clip("crouch", 20, loop=True)
    c.key(0.0, **CROUCH)
    c.key(0.5, **dict(CROUCH, hips=(-0.03, 0.07, -0.34)))
    out.append(c)

    # push: face the nose, back foot pushes on the toe side of the board
    PUSH = dict(hips_rot=(18.0, 0.0, 62.0), sp=(14.0, 0.0, 10.0), head=(-8.0, 0.0, 15.0), neck=(0.0, 0.0, 5.0),
                fl=(0.13, 0.0, 84.0, 0.0), ua_l=(30.0, 30.0, 0.0), ua_r=(-25.0, 30.0, 0.0), la_l=(0, 0, 25.0), la_r=(0, 0, 25.0))
    c = Clip("push", 36, loop=True)
    c.key(0.0, **dict(PUSH, fr_ground=(0.0, 0.02, -0.16, 0.06, 80.0), hips=(0.0, 0.02, -0.14)))
    c.key(0.22, **dict(PUSH, fr_ground=(1.0, 0.12, -0.17, 0.0, 80.0), hips=(0.0, 0.0, -0.21), ua_l=(-20.0, 30.0, 0.0), ua_r=(35.0, 30.0, 0.0)))
    c.key(0.55, **dict(PUSH, fr_ground=(1.0, -0.36, -0.16, 0.0, 80.0), hips=(0.02, 0.0, -0.2), ua_l=(35.0, 30.0, 0.0), ua_r=(-30.0, 30.0, 0.0)))
    c.key(0.78, **dict(PUSH, fr_ground=(1.0, -0.38, -0.14, 0.09, 80.0), hips=(0.0, 0.01, -0.16)))
    out.append(c)

    c = Clip("ollie", 22)
    c.key(0.0, **CROUCH)
    c.key(0.16, **dict(CROUCH, b_pos=(0.0, 0.0, 0.07), b_rot=(0.0, -24.0, 0.0), hips=(-0.03, 0.05, -0.10), sp=(12.0, 0.0, 12.0),
                       fl=(0.23, 0.018, 58.0, 0.02), ua_l=(-10.0, 5.0, 0.0), ua_r=(-10.0, 5.0, 0.0)))
    c.key(0.42, **dict(AIR, b_pos=(0.0, 0.0, 0.2), b_rot=(0.0, -6.0, 0.0), fl=(0.2, 0.018, 55.0, 0.0)))
    c.key(1.0, **AIR)
    out.append(c)

    c = Clip("air", 30, loop=True)
    c.key(0.0, **AIR)
    c.key(0.5, **dict(AIR, b_pos=(0.0, 0.0, 0.235), ua_l=(-8.0, 8.0, 0.0), sp=(16.0, 0.0, 14.0)))
    out.append(c)

    def flip(name, roll=0.0, yaw=0.0, frames=18, lift=0.075, extra=None):
        c = Clip(name, frames)
        c.key(0.0, **dict(AIR, stick=1.0, stick_yaw=1.0))
        c.key(0.08, **dict(AIR, stick=0.0, stick_yaw=0.0, fl=(0.24, 0.018 + (0.03 if roll > 0 else -0.03), 55.0, 0.02), b_rot=(roll * 0.02, -8.0, yaw * 0.02), b_pos=(0.0, 0.0, 0.25)))
        c.key(0.4, **dict(AIR, stick=0.0, stick_yaw=0.0, b_rot=(roll * 0.5, -4.0, yaw * 0.5), b_pos=(0.0, 0.0, 0.25),
                          fl=(0.2, 0.018, 52.0, lift), fr=(-0.23, 0.006, 14.0, lift * 0.8), ua_l=(-15.0, -5.0, 0.0), ua_r=(-10.0, 10.0, 0.0)))
        c.key(0.74, **dict(AIR, stick=0.0, stick_yaw=0.0, b_rot=(roll * 0.97, 0.0, yaw * 0.97), fl=(0.17, 0.018, 52.0, 0.02), fr=(-0.225, 0.006, 14.0, 0.015)))
        c.key(0.84, **dict(AIR, stick=1.0, stick_yaw=1.0, b_rot=(roll, 0.0, yaw)))
        c.key(1.0, **dict(AIR, b_rot=(roll, 0.0, yaw)))
        if extra:
            extra(c)
        out.append(c)

    flip("kickflip", roll=-360.0)
    flip("heelflip", roll=360.0)
    flip("shoveit", yaw=180.0, lift=0.05)

    def grab(name, hand, target, board_rot=(0.0, 0.0, 0.0), body=None):
        c = Clip(name, 14)
        ik = "ik_hand_" + hand
        pose = dict(AIR, b_pos=(0.0, 0.0, 0.34), hips=(-0.03, 0.08, -0.18), sp=(34.0, 0.0, 10.0), head=(-20.0, 0.0, 30.0),
                    fingers=0.9, b_rot=board_rot)
        pose[ik] = (1.0,) + tuple(target)
        if body:
            pose.update(body)
        c.key(0.0, **dict(AIR))
        c.key(0.55, **pose)
        c.key(1.0, **pose)
        out.append(c)

    grab("indy", "r", (-0.02, -0.108, 0.0), board_rot=(8.0, 0.0, 0.0),
         body=dict(ua_l=(-20.0, -25.0, 0.0), la_l=(0, 0, 10.0)))
    grab("melon", "l", (0.0, 0.108, 0.0), board_rot=(-8.0, 0.0, 0.0),
         body=dict(ua_r=(-30.0, -20.0, 0.0), la_r=(0, 0, 15.0), hips_rot=(18.0, 0.0, 10.0)))
    grab("nosegrab", "l", (0.34, 0.0, 0.0), board_rot=(0.0, -14.0, 0.0),
         body=dict(ua_r=(-10.0, -30.0, 0.0), sp=(38.0, 0.0, 25.0), hips=(0.02, 0.08, -0.2)))
    grab("tailgrab", "r", (-0.36, 0.0, 0.0), board_rot=(0.0, 14.0, 0.0),
         body=dict(ua_l=(-10.0, -30.0, 0.0), sp=(34.0, 0.0, 0.0), hips=(-0.07, 0.08, -0.2)))

    # vert air: backside grab with the front arm stretched up and the board tweaked
    c = Clip("vert_air", 30, loop=True)
    va = dict(AIR, b_pos=(0.0, 0.0, 0.3), b_rot=(14.0, 0.0, -8.0), hips=(-0.03, 0.07, -0.16), sp=(26.0, 8.0, 20.0),
              ik_hand_r=(1.0, 0.05, 0.108, 0.0), ua_l=(-60.0, -60.0, 0.0), la_l=(0.0, 0.0, 10.0), fingers=0.8, head=(-10.0, 0.0, 55.0))
    c.key(0.0, **va)
    c.key(0.5, **dict(va, b_rot=(20.0, 0.0, -12.0), ua_l=(-65.0, -65.0, 0.0)))
    out.append(c)

    # grinds: root at the rail top
    GR = dict(hips=(-0.03, 0.05, -0.2), sp=(16.0, 0.0, 12.0), ua_l=(-5.0, -20.0, 0.0), ua_r=(-5.0, -15.0, 0.0),
              la_l=(0, 0, 20.0), la_r=(0, 0, 20.0), head=(-12.0, 0.0, 45.0))
    c = Clip("grind_5050", 40, loop=True)
    c.key(0.0, **dict(GR, b_pos=(0.0, 0.0, -0.022)))
    c.key(0.5, **dict(GR, b_pos=(0.0, 0.0, -0.022), hips=(-0.03, 0.05, -0.21), ua_l=(-8.0, -25.0, 0.0), ua_r=(-2.0, -10.0, 0.0)))
    out.append(c)
    c = Clip("boardslide", 40, loop=True)
    BS = dict(GR, b_pos=(0.0, 0.0, -0.077), hips=(-0.03, 0.03, -0.24), sp=(18.0, 0.0, 30.0), head=(-12.0, 0.0, 40.0),
              ua_l=(-10.0, -35.0, 0.0), ua_r=(10.0, -30.0, 0.0))
    c.key(0.0, **BS)
    c.key(0.5, **dict(BS, ua_l=(-5.0, -30.0, 0.0), ua_r=(5.0, -35.0, 0.0), hips=(-0.03, 0.03, -0.25)))
    out.append(c)

    # manuals: board pitched on one truck
    def manual(name, pitch, hips_x):
        c = Clip(name, 40, loop=True)
        x_truck = -0.18 if pitch < 0 else 0.18
        lift = abs(math.sin(math.radians(pitch)) * 0.18)
        p = dict(b_rot=(0.0, pitch, 0.0), b_pos=(0.0, 0.0, lift), hips=(hips_x, 0.05, -0.16), sp=(12.0, 0.0, 12.0),
                 ua_l=(-20.0, -10.0, 0.0), ua_r=(-20.0, -10.0, 0.0), la_l=(0, 0, 20.0), la_r=(0, 0, 20.0))
        c.key(0.0, **p)
        c.key(0.5, **dict(p, ua_l=(-25.0, -15.0, 0.0), ua_r=(-15.0, -5.0, 0.0), hips=(hips_x * 1.1, 0.05, -0.17)))
        out.append(c)

    manual("manual", -11.0, -0.07)
    manual("nose_manual", 11.0, 0.05)

    c = Clip("land", 12)
    c.key(0.0, **AIR)
    c.key(0.3, **dict(CROUCH, hips=(-0.03, 0.07, -0.28)))
    c.key(1.0)
    out.append(c)

    # bail: board kicked away, skater falls back onto the concrete
    c = Clip("bail", 45)
    c.key(0.0, **dict(AIR, b_pos=(0.0, 0.0, 0.05)))
    c.key(0.18, **dict(b_pos=(0.35, -0.1, 0.25), b_rot=(60.0, 30.0, 40.0), stick=0.0, stick_yaw=0.0,
                       fl_ground=(1.0, 0.25, -0.12, 0.1, 50.0), fr_ground=(1.0, -0.15, -0.05, 0.12, 20.0),
                       hips=(0.0, 0.12, -0.2), hips_rot=(-15.0, 10.0, 25.0), sp=(-10.0, 0.0, 10.0),
                       ua_l=(-80.0, -40.0, 0.0), ua_r=(-70.0, -45.0, 0.0), head=(10.0, 0.0, 20.0)))
    c.key(0.45, **dict(b_pos=(1.0, -0.3, 0.1), b_rot=(200.0, 50.0, 90.0), stick=0.0, stick_yaw=0.0,
                       fl_ground=(1.0, 0.3, -0.35, 0.05, 40.0), fr_ground=(1.0, -0.05, -0.38, 0.15, 10.0),
                       hips=(0.0, 0.25, -0.75), hips_rot=(-55.0, 8.0, 20.0), sp=(-5.0, 0.0, 10.0),
                       ua_l=(30.0, -10.0, 0.0), ua_r=(35.0, -15.0, 0.0), head=(25.0, 0.0, 10.0)))
    c.key(0.7, **dict(b_pos=(1.4, -0.4, -0.08), b_rot=(360.0, 0.0, 120.0), stick=0.0, stick_yaw=0.0,
                      fl_ground=(1.0, 0.25, -0.55, 0.0, 30.0), fr_ground=(1.0, -0.1, -0.6, 0.06, 0.0),
                      hips=(0.0, 0.3, -0.86), hips_rot=(-80.0, 5.0, 15.0), sp=(10.0, 0.0, 5.0),
                      ua_l=(55.0, 20.0, 0.0), ua_r=(55.0, 15.0, 0.0), head=(20.0, 0.0, 15.0)))
    c.key(1.0, **dict(b_pos=(1.5, -0.45, -0.08), b_rot=(360.0, 0.0, 130.0), stick=0.0, stick_yaw=0.0,
                      fl_ground=(1.0, 0.3, -0.62, 0.0, 30.0), fr_ground=(1.0, -0.12, -0.64, 0.0, 0.0),
                      hips=(0.0, 0.32, -0.88), hips_rot=(-86.0, 5.0, 15.0), sp=(8.0, 0.0, 5.0),
                      ua_l=(60.0, 30.0, 0.0), ua_r=(60.0, 25.0, 0.0), head=(15.0, 0.0, 20.0)))
    out.append(c)

    # the special: "Tiger Claw Tre" - a double 360 flip (double tre) with a spread-eagle
    # Christ pose over it, caught into a tweaked indy
    c = Clip("special", 42)
    spread = dict(AIR, stick=0.0, stick_yaw=0.0, b_pos=(0.0, 0.0, 0.2), hips=(-0.03, 0.05, -0.02), sp=(-8.0, 0.0, 0.0),
                  ua_l=(0.0, -55.0, 0.0), ua_r=(0.0, -55.0, 0.0), la_l=(0, 0, 0), la_r=(0, 0, 0), head=(12.0, 0.0, 20.0),
                  fl=(0.18, 0.018, 52.0, 0.2), fr=(-0.23, 0.006, 14.0, 0.2), fingers=0.1)
    c.key(0.0, **AIR)
    c.key(0.1, **dict(AIR, stick=0.0, stick_yaw=0.0, b_rot=(-40.0, -8.0, 40.0), fl=(0.24, -0.02, 55.0, 0.03)))
    c.key(0.35, **dict(spread, b_rot=(-300.0, 0.0, 190.0)))
    c.key(0.55, **dict(spread, b_rot=(-520.0, 0.0, 280.0), sp=(-12.0, 0.0, 0.0)))
    c.key(0.72, **dict(AIR, stick=0.0, stick_yaw=0.0, b_rot=(-700.0, 0.0, 350.0), fl=(0.17, 0.018, 52.0, 0.03)))
    c.key(0.8, **dict(AIR, b_rot=(-720.0, 0.0, 360.0)))
    ind = dict(AIR, b_rot=(-712.0, 0.0, 360.0), b_pos=(0.0, 0.0, 0.34), hips=(-0.03, 0.08, -0.18), sp=(34.0, 0.0, 10.0),
               ik_hand_r=(1.0, -0.02, -0.108, 0.0), ua_l=(-20.0, -40.0, 0.0), fingers=0.9)
    c.key(0.92, **ind)
    c.key(1.0, **dict(ind, b_rot=(-720.0, 0.0, 360.0)))
    out.append(c)
    return out


def build(info=None, export=True, only=None):
    rig = bpy.data.objects["SkaterRig"]
    setup_control_rig(rig)
    poser = Poser(rig)
    bones = [b.name for b in rig.data.bones if b.use_deform or b.name == "board"]
    # speed: skip mesh deformation while baking
    meshes = [o for o in bpy.data.objects if o.type == 'MESH' and o.parent == rig]
    for o in meshes:
        for m in o.modifiers:
            if m.type == 'ARMATURE':
                m.show_viewport = False
    rig.animation_data_create()
    made = []
    for clip in clips():
        if only and clip.name not in only:
            continue
        act, slot = bake_clip(rig, poser, clip, bones)
        made.append((clip, act, slot))
    for o in meshes:
        for m in o.modifiers:
            if m.type == 'ARMATURE':
                m.show_viewport = True
    return rig, made


def finalize(rig):
    """Remove the control rig so only the baked FK skeleton + board bone remain."""
    C.select_only(rig)
    bpy.ops.object.mode_set(mode='POSE')
    for p in rig.pose.bones:
        for c in list(p.constraints):
            p.constraints.remove(c)
        p.location = (0, 0, 0)
        p.rotation_quaternion = (1, 0, 0, 0)
    bpy.ops.object.mode_set(mode='EDIT')
    eb = rig.data.edit_bones
    for n in [b.name for b in eb if b.name.startswith(("ik_", "pole_"))]:
        eb.remove(eb[n])
    bpy.ops.object.mode_set(mode='OBJECT')


# ------------------------------------------------------------------ export

GAME_TEX = {"skin_albedo": 2048, "skin_normal": 2048, "hair_atlas": 1024, "eye_albedo": 512}
GAME_TEX_DEFAULT = 1024


def game_textures(objs):
    """Downscaled copies of every texture used by objs, written to work/tex_game and
    swapped into the materials (the full-size maps stay in the .blend for renders)."""
    out_dir = C.os.path.join(C.WORK, "tex_game")
    C.os.makedirs(out_dir, exist_ok=True)
    done = {}
    for o in objs:
        for slot in o.material_slots:
            m = slot.material
            if not m or not m.node_tree:
                continue
            for n in m.node_tree.nodes:
                if n.type != 'TEX_IMAGE' or not n.image:
                    continue
                img = n.image
                if img.name in done:
                    n.image = done[img.name]
                    continue
                limit = GAME_TEX.get(img.name, GAME_TEX_DEFAULT)
                w, h = img.size
                if max(w, h) <= limit:
                    done[img.name] = img
                    continue
                cp = img.copy()
                cp.name = img.name + "_game"
                cp.scale(limit, int(h * limit / w))
                cp.filepath_raw = C.os.path.join(out_dir, img.name + ".png")
                cp.file_format = 'PNG'
                cp.save()
                cp.colorspace_settings.name = img.colorspace_settings.name
                done[img.name] = cp
                n.image = cp


def export_skater(rig, path=None):
    path = path or C.os.path.join(C.ASSETS, "skater.glb")
    finalize(rig)
    board = bpy.data.objects.get("Skateboard")
    objs = [rig] + [o for o in bpy.data.objects if o.parent == rig and o.type == 'MESH']
    C.save_blend("skater")
    game_textures(objs)
    # the last clip stays assigned; ACTIONS mode exports every action with a rig slot
    act = bpy.data.actions.get("idle")
    if act:
        rig.animation_data.action = act
        rig.animation_data.action_slot = act.slots[0]
    C.export_glb(path, objects=objs, animations=True, extra=dict(
        export_animation_mode='ACTIONS', export_def_bones=False, export_optimize_animation_size=True,
        export_image_format='WEBP', export_image_quality=88, export_skins=True, export_morph=False,
        export_reset_pose_bones=True, export_force_sampling=True, export_frame_step=1))
    return path
