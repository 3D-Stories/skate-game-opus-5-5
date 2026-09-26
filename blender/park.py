"""The Warehouse - an homage to the THPS1 Warehouse (Woodland Hills), all assets original.

Real-world scale (metres). Layout (Blender coords, +Y = north, Z up):
  * South end: the start deck at 5 m with the steep drop-in (9 m radius roll-in).
  * Main hall 40 x 66 m, 11.5 m to the roof, brick below / corrugated steel above,
    steel columns, roof trusses and ten skylights.
  * Halfpipe (3.7 m, 3.2 m transitions + vert, coping, 1.5 m decks) at the north end,
    entered from its open south end.
  * Quarterpipes: a 3.2 m quarter along the whole east wall (five breakable windows above
    it) and a 2.4 m quarter in the south-east corner.
  * Street section: funbox with a top rail, two kickers, an 18 m flat rail, concrete
    ledges, a grindable wall pipe above the east quarter.
  * High catwalks (5 m) from the start deck along the south and west walls, with a kicker
    at the end launching onto the yellow rafter beam (the "grind the rafters" goal).
  * A boarded-up breakable wall in the west wall hides a secret room with the tape.
  * Props: crates, barrels, pallets, dumpster, hanging lamps; original graffiti decals
    drawn in code by graffiti.py.

Outputs assets/park.glb (visual meshes merged per material with a 'Lightmap' UV set,
collision meshes as '-colonly', breakables as separate nodes), assets/park_lightmap.png
(baked in bake.py) and assets/park_data.json (rails, spawn, pickups, goals) in Godot
coordinates.
"""
import json
import math
import os

import bpy
import bmesh
import numpy as np
from mathutils import Matrix, Vector

from lib import common as C
import park_geo as G

HALL = dict(x0=-20.0, x1=20.0, y0=-16.0, y1=50.0, h=11.5)
START_Z = 5.0
DROP_R = 9.0


def lamp_positions():
    """Hanging fluorescent fixtures under the trusses (shared with the bake's area lights).
    None directly over the start deck, which sits only 3 m below them."""
    out = []
    for yy in np.arange(-12.0, 49.0, 8.0):
        for xx in (-12.0, -4.0, 4.0, 12.0):
            if yy < -6.0 and abs(xx) < 9.0:
                continue
            out.append((float(xx), float(yy)))
    return out


def to_godot(p):
    return [round(float(p[0]), 4), round(float(p[2]), 4), round(float(-p[1]), 4)]


# ------------------------------------------------------------------ materials

MATS = {
    # name: (source photo, tile metres, tint, roughness range, normal strength, metallic)
    "concrete_floor": ("concrete_floor", 3.2, (0.95, 0.95, 0.95), (0.55, 0.85), 2.0, 0.0),
    "concrete": ("concrete_floor", 2.0, (1.1, 1.08, 1.04), (0.7, 0.9), 2.5, 0.0),
    "brick": ("brick", 3.0, (1.0, 1.0, 1.0), (0.75, 0.95), 4.0, 0.0),
    "cinder": ("cinderblock", 2.6, (1.0, 1.0, 1.0), (0.7, 0.9), 3.0, 0.0),
    "corrugated": ("corrugated", 2.2, (0.95, 0.95, 0.95), (0.4, 0.8), 5.0, 0.6),
    "roof": ("corrugated", 2.2, (0.55, 0.55, 0.58), (0.5, 0.8), 5.0, 0.5),
    "plywood": ("plywood", 2.44, (1.0, 1.0, 1.0), (0.55, 0.8), 1.5, 0.0),
    "rampside": ("plywood", 2.44, (0.5, 0.52, 0.56), (0.6, 0.85), 1.5, 0.0),
    "steel": ("painted_steel", 1.2, (1.0, 1.0, 1.0), (0.45, 0.75), 2.0, 0.3),
    "steel_paint": ("painted_steel", 1.5, (0.62, 0.64, 0.7), (0.45, 0.75), 2.0, 0.3),
    "rafter": ("painted_steel", 1.0, (2.2, 1.7, 0.35), (0.45, 0.7), 2.0, 0.2),
    "rail": ("painted_steel", 0.8, (1.6, 0.45, 0.35), (0.35, 0.6), 1.5, 0.4),
    "coping": ("diamond_plate", 0.5, (0.85, 0.85, 0.87), (0.25, 0.45), 0.5, 1.0),
    "diamond": ("diamond_plate", 1.2, (0.9, 0.9, 0.9), (0.35, 0.6), 3.0, 0.9),
    "crate": ("crate_wood", 1.3, (1.0, 1.0, 1.0), (0.7, 0.9), 2.0, 0.0),
    "crate_frame": ("crate_wood", 1.0, (0.62, 0.55, 0.48), (0.7, 0.9), 2.0, 0.0),
    "barrel": ("painted_steel", 1.0, (0.55, 0.8, 1.5), (0.4, 0.7), 1.5, 0.4),
    "dumpster": ("painted_steel", 1.5, (0.55, 1.0, 0.55), (0.45, 0.75), 2.0, 0.3),
    "boards": ("crate_wood", 1.5, (0.9, 0.85, 0.8), (0.7, 0.9), 2.5, 0.0),
    "paint_line": ("concrete_floor", 3.2, (1.9, 1.5, 0.25), (0.5, 0.7), 1.0, 0.0),
}
SPECIAL = ("lamp", "skylight", "glass", "exit_sign", "yard")
LIGHTMAPPED_EXCLUDE = set(SPECIAL)


def build_textures():
    """Seamless albedo (roughness packed in alpha) + normal maps for every material."""
    cache = {}
    imgs = {}
    for name, (src, tile, tint, rr, ns, metal) in MATS.items():
        if src not in cache:
            a = C.make_seamless(C.src_array(src, 1024))
            cache[src] = a
        a = cache[src]
        lum = C.luminance(a)
        alb = np.clip(a * np.array(tint), 0, 1)
        if name == "paint_line":
            alb = np.clip(np.array([0.85, 0.66, 0.08]) * (0.75 + 0.35 * lum[..., None]), 0, 1)
        if name == "coping":
            alb = np.clip(np.full_like(a, 0.62) * (0.8 + 0.3 * lum[..., None]), 0, 1)
        # roughness: brighter/smoother polish where the photo is darker (worn tracks)
        ln = (lum - lum.min()) / max(1e-6, lum.max() - lum.min())
        rough = rr[0] + (rr[1] - rr[0]) * (1 - ln if name == "concrete_floor" else ln)
        height = C.highpass(lum, 8)
        height = height / (height.std() + 1e-6)
        nrm = C.height_to_normal(height, ns * 0.35)
        rgba = np.concatenate([alb, rough[..., None]], -1)
        imgs[name] = (C.save_png(rgba, "park_" + name + "_albedo"),
                      C.save_png(nrm, "park_" + name + "_normal", 'Non-Color'), tile, metal, float(np.mean(rr)))
    return imgs


def make_materials(imgs):
    mats = {}
    for name, (alb, nrm, tile, metal, rough) in imgs.items():
        m = C.pbr_material("park_" + name, base=alb, normal=nrm, roughness=rough, metallic=metal, normal_strength=1.0)
        mats[name] = m
    em = C.pbr_material("park_lamp", base_color=(1, 1, 1, 1), roughness=0.3, emission=(1.0, 0.97, 0.9, 1), emission_strength=25.0)
    mats["lamp"] = em
    sk = C.pbr_material("park_skylight", base_color=(0.8, 0.85, 0.9, 1), roughness=0.1, emission=(0.85, 0.92, 1.0, 1), emission_strength=6.0)
    mats["skylight"] = sk
    # the yard outside the east windows: bright overcast daylight (unlit in the game)
    mats["yard"] = C.pbr_material("park_yard", base_color=(0.85, 0.9, 1.0, 1), roughness=0.9,
                                  emission=(0.85, 0.9, 1.0, 1), emission_strength=3.0)
    gl = C.pbr_material("park_glass", base_color=(0.6, 0.7, 0.72, 1), roughness=0.05, metallic=0.0)
    C.principled(gl).inputs['Alpha'].default_value = 0.35
    mats["glass"] = gl
    ex = C.pbr_material("park_exit_sign", base_color=(0.1, 0.6, 0.2, 1), emission=(0.2, 1.0, 0.35, 1), emission_strength=8.0)
    mats["exit_sign"] = ex
    return mats


# ------------------------------------------------------------------ layout

class Park:
    def __init__(self):
        self.B = G.Builder()
        self.rails = []
        self.data = {}
        self.windows = []
        self.breakables = []

    def hanger(self, bottom, top):
        """A thin vertical hanger rod (catwalks, rafters): the game gives the chase camera a
        blocker for each, so a rod never ends up right in front of the lens."""
        self.data.setdefault("hangers", []).append([to_godot(bottom), to_godot(top)])

    def add_rail(self, pts, kind="metal", tag="", name=""):
        self.rails.append(dict(name=name or f"rail_{len(self.rails)}", kind=kind, tag=tag,
                               points=[to_godot(p) for p in pts]))

    # -------------------------------------------------------------- shell
    def shell(self):
        B = self.B
        x0, x1, y0, y1, h = HALL["x0"], HALL["x1"], HALL["y0"], HALL["y1"], HALL["h"]
        # floor in strips (so the lightmap islands stay reasonable)
        for yy in np.arange(y0, y1, 6.0):
            ya, yb = yy, min(y1, yy + 6.0)
            for xx in np.arange(x0, x1, 8.0):
                B.quad("concrete_floor", [(xx, ya, 0), (xx + 8, ya, 0), (xx + 8, yb, 0), (xx, yb, 0)], col="concrete")
        # walls: brick to 4.5 m, corrugated above; the east wall gets window openings,
        # the west wall a doorway for the breakable wall
        wall_split = 4.5
        self._wall_x(x0, y0, y1, wall_split, h, inward=+1, hole=(34.0, 39.0, 0.0, 3.2))
        self._wall_x(x1, y0, y1, wall_split, h, inward=-1, windows=self.window_spans())
        self._wall_y(y0, x0, x1, wall_split, h, inward=+1)
        self._wall_y(y1, x0, x1, wall_split, h, inward=-1)
        # roof with skylight openings
        self.roof()
        # columns along the walls
        for yy in np.arange(y0 + 4, y1 - 1, 8.0):
            for x, s in ((x0 + 0.2, 1), (x1 - 0.2, -1)):
                if s == 1 and 33.5 < yy < 39.5:
                    continue        # no column in the boarded-up doorway to the secret room
                B.box("steel_paint", (x - 0.15, yy - 0.15, 0), (x + 0.15, yy + 0.15, h), col="wall")

    def window_spans(self):
        spans = []
        for i in range(5):
            yc = 9.0 + i * 5.2
            spans.append((yc - 1.4, yc + 1.4, 4.4, 6.4))
        return spans

    def _wall_x(self, x, y0, y1, split, h, inward, hole=None, windows=()):
        B = self.B
        # build the wall as columns of segments between openings
        cuts = sorted([y0, y1] + [v for w in windows for v in (w[0], w[1])] + ([hole[0], hole[1]] if hole else []))
        ys = sorted(set(cuts))
        for ya, yb in zip(ys[:-1], ys[1:]):
            mid = (ya + yb) / 2
            win = next((w for w in windows if w[0] <= mid <= w[1]), None)
            is_hole = hole and hole[0] <= mid <= hole[1]
            spans = [(0.0, split, "brick"), (split, h, "corrugated")]
            for (za, zb, mat) in spans:
                segs = [(za, zb)]
                if win:
                    segs = [(a, b) for (a, b) in ((za, min(zb, win[2])), (max(za, win[3]), zb)) if b - a > 1e-3]
                if is_hole:
                    segs = [(a, b) for (a, b) in ((max(za, hole[3]), zb),) if b - a > 1e-3]
                for (a, b) in segs:
                    pts = [(x, ya, a), (x, yb, a), (x, yb, b), (x, ya, b)]
                    B.quad(mat, pts if inward > 0 else list(reversed(pts)), col="wall")
            if win:
                # window frame sill and head
                self.windows.append(dict(y0=win[0], y1=win[1], z0=win[2], z1=win[3], x=x))
            if is_hole:
                pass

    def _wall_y(self, y, x0, x1, split, h, inward):
        B = self.B
        for (za, zb, mat) in ((0.0, split, "brick"), (split, h, "corrugated")):
            pts = [(x0, y, za), (x1, y, za), (x1, y, zb), (x0, y, zb)]
            B.quad(mat, list(reversed(pts)) if inward > 0 else pts, col="wall")

    def skylight_rects(self):
        rects = []
        for i in range(5):
            yc = -8.0 + i * 13.0
            for xc in (-9.0, 9.0):
                rects.append((xc - 2.0, xc + 2.0, yc - 3.0, yc + 3.0))
        return rects

    def roof(self):
        B = self.B
        x0, x1, y0, y1, h = HALL["x0"], HALL["x1"], HALL["y0"], HALL["y1"], HALL["h"]
        rects = self.skylight_rects()
        xs = sorted(set([x0, x1] + [v for r in rects for v in (r[0], r[1])]))
        ys = sorted(set([y0, y1] + [v for r in rects for v in (r[2], r[3])]))
        for xa, xb in zip(xs[:-1], xs[1:]):
            for ya, yb in zip(ys[:-1], ys[1:]):
                cx, cy = (xa + xb) / 2, (ya + yb) / 2
                if any(r[0] <= cx <= r[1] and r[2] <= cy <= r[3] for r in rects):
                    continue
                B.quad("roof", [(xa, yb, h), (xb, yb, h), (xb, ya, h), (xa, ya, h)])
        # skylight wells + glazing (glazing is special: emissive, no lightmap, no shadow)
        for (a, b, c, d) in rects:
            for pts in ([(a, c, h), (b, c, h), (b, c, h + 0.5), (a, c, h + 0.5)], [(b, d, h), (a, d, h), (a, d, h + 0.5), (b, d, h + 0.5)],
                        [(a, d, h), (a, c, h), (a, c, h + 0.5), (a, d, h + 0.5)], [(b, c, h), (b, d, h), (b, d, h + 0.5), (b, c, h + 0.5)]):
                B.quad("steel_paint", list(reversed(pts)))
            B.quad("skylight", [(a, d, h + 0.5), (b, d, h + 0.5), (b, c, h + 0.5), (a, c, h + 0.5)])
            # glazing bars
            for k in range(1, 4):
                yy = c + (d - c) * k / 4
                B.box("steel", (a, yy - 0.03, h + 0.42), (b, yy + 0.03, h + 0.48))
        # roof trusses every 8 m spanning east-west
        for yy in np.arange(y0 + 4, y1 - 1, 8.0):
            G.ibeam(B, (x0, yy, h - 2.0), (x1, yy, h - 2.0), h=0.3, w=0.18, mat="steel_paint", col=None)
            G.ibeam(B, (x0, yy, h), (x1, yy, h), h=0.25, w=0.18, mat="steel_paint", col=None)
            for xx in np.arange(x0 + 2.5, x1 - 1, 2.5):
                k = int((xx - x0) / 2.5)
                ztop = h - 0.25
                a = (xx, yy, h - 2.0)
                b = (xx + (1.25 if k % 2 == 0 else -1.25), yy, ztop)
                B.cylinder("steel_paint", a, b, 0.05, 6)
        # purlins along Y
        for xx in np.arange(x0 + 4, x1 - 1, 4.0):
            G.ibeam(B, (xx, y0, h - 0.02), (xx, y1, h - 0.02), h=0.18, w=0.1, mat="steel_paint", col=None)

    # -------------------------------------------------------------- start deck & drop-in
    def entry(self):
        B = self.B
        # start deck block
        B.box("concrete", (-8.0, -16.0, 0.0), (8.0, -7.0, START_Z), col="wall", faces=("east", "west", "south"))
        B.quad("plywood", [(-8, -16, START_Z), (8, -16, START_Z), (8, -7.0, START_Z), (-8, -7.0, START_Z)], col="wood")
        # drop-in: a 9 m radius roll-in facing north (about 64 degrees at the lip), lip at the
        # deck edge, so the run starts by rolling in from 5 m up
        run = DROP_R * math.sin(math.acos(1 - START_Z / DROP_R))
        lip = G.quarter_pipe(B, (0.0, -7.0 + run, 0.0), 180.0, 16.0, DROP_R, START_Z, 0.0,
                             back_wall=False)
        self.add_rail(lip, "metal", "coping", "dropin_coping")
        # deck railing on the south side of the deck
        top = G.rail(B, [(-7.5, -15.6, START_Z), (7.5, -15.6, START_Z)], 0.9)
        # catwalk from the deck along the south wall to the west wall, then north
        self.catwalk([(-8.0, -14.6), (-17.6, -14.6)], width=2.4, z=START_Z)
        self.catwalk([(-18.8, -15.8), (-18.8, 24.0)], width=2.4, z=START_Z, rail_side=-1, rail_to=18.0)
        # the catwalk kicker (launch north toward the rafter)
        G.kicker(B, (-18.8, 22.4, START_Z), 0.0, 2.2, 1.6, 0.45)
        self.data["catwalk_kicker"] = to_godot((-18.8, 24.0, START_Z + 0.45))

    def catwalk(self, pts, width, z, rail_side=0, rail_to=None):
        B = self.B
        (ax, ay), (bx, by) = pts
        d = Vector((bx - ax, by - ay, 0)).normalized()
        n = Vector((-d.y, d.x, 0)) * (width / 2)
        a, b = Vector((ax, ay, z)), Vector((bx, by, z))
        c = [a - n, b - n, b + n, a + n]
        B.quad("diamond", [tuple(p) for p in c], col="metal")
        under = [tuple(p - Vector((0, 0, 0.25))) for p in c]
        B.quad("steel_paint", list(reversed(under)))
        for i in range(4):
            p, q = c[i], c[(i + 1) % 4]
            B.quad("steel_paint", [tuple(p - Vector((0, 0, 0.25))), tuple(q - Vector((0, 0, 0.25))), tuple(q), tuple(p)], col="wall")
        # hanger rods to the roof
        L = (b - a).length
        for k in range(int(L / 4) + 1):
            p = a.lerp(b, k / max(1, int(L / 4)))
            for s in (-1, 1):
                q = p + n * s * 0.95
                B.cylinder("steel", (q.x, q.y, z), (q.x, q.y, HALL["h"] - 2.0), 0.02, 6)
                self.hanger((q.x, q.y, z), (q.x, q.y, HALL["h"] - 2.0))
        if rail_side:
            e = b if rail_to is None else a + d * (rail_to - a.y if abs(d.y) > 0.5 else rail_to - a.x)
            ra = a + n * rail_side * 0.95
            rb = e + n * rail_side * 0.95
            top = G.rail(B, [tuple(ra), tuple(rb)], 1.0, r=0.025, post_every=2.0)
            self.add_rail(top, "metal", "catwalk", "catwalk_handrail")

    # -------------------------------------------------------------- ramps
    def ramps(self):
        B = self.B
        # halfpipe: riding east-west, open to the south
        R, H, deck = 3.2, 3.7, 1.5
        flat = 5.0
        w = 12.0
        cy = 43.0
        west = G.quarter_pipe(B, (-flat / 2, cy, 0.0), 90.0, w, R, H, deck)   # rises toward -x
        east = G.quarter_pipe(B, (flat / 2, cy, 0.0), -90.0, w, R, H, deck)   # rises toward +x
        self.add_rail(west, "metal", "coping", "hp_coping_w")
        self.add_rail(east, "metal", "coping", "hp_coping_e")
        # flat bottom in plywood too
        B.quad("plywood", [(-flat / 2, cy - w / 2, 0.005), (flat / 2, cy - w / 2, 0.005), (flat / 2, cy + w / 2, 0.005), (-flat / 2, cy + w / 2, 0.005)], col="wood")
        self.data["halfpipe"] = dict(center=to_godot((0, cy, 0)), height=H)
        # east wall quarter pipe (full length) with the windows above
        east_qp = G.quarter_pipe(B, (20.0 - 0.8 - 2.8, 16.0, 0.0), -90.0, 60.0, 2.8, 3.2, 0.8)
        self.add_rail(east_qp, "metal", "coping", "east_qp_coping")
        # grindable pipe above the east quarter, below the windows
        pa, pb = (19.55, -12.0, 3.95), (19.55, 44.0, 3.95)
        B.cylinder("steel", pa, pb, 0.11, 14)
        for yy in np.arange(-12.0, 44.1, 4.0):
            B.box("steel", (19.55, yy - 0.05, 3.84), (20.0, yy + 0.05, 3.9))
        self.add_rail([(pa[0], pa[1], pa[2] + 0.11), (pb[0], pb[1], pb[2] + 0.11)], "metal", "pipe", "wall_pipe")
        # south-east corner quarter
        se = G.quarter_pipe(B, (12.2, -16.0 + 0.8 + 2.4, 0.0), 180.0, 7.6, 2.4, 2.4, 0.8)
        self.add_rail(se, "metal", "coping", "se_qp_coping")
        # kickers
        G.kicker(B, (0.0, 5.0, 0.0), 0.0, 3.0, 1.8, 0.7)
        G.kicker(B, (-9.0, 29.0, 0.0), 0.0, 2.6, 1.6, 0.6)
        # funbox with a rail on top
        edges = G.funbox(B, (0.0, 16.5), 4.0, 3.0, 0.9, 2.3)
        for i, (a, b) in enumerate(edges):
            self.add_rail([a, b], "wood", "ledge", f"funbox_edge_{i}")
        top = G.rail(B, [(0.0, 15.2, 0.9), (0.0, 17.8, 0.9)], 0.42, post_every=2.6)
        self.add_rail(top, "metal", "rail", "funbox_rail")

    # -------------------------------------------------------------- street
    def street(self):
        B = self.B
        top = G.rail(B, [(-12.0, 2.0, 0.0), (-12.0, 20.0, 0.0)], 0.5)
        self.add_rail(top, "metal", "rail", "long_rail")
        top = G.rail(B, [(6.0, 26.0, 0.0), (13.0, 32.0, 0.0)], 0.45)
        self.add_rail(top, "metal", "rail", "diag_rail")
        for e in G.ledge(B, (8.5, 2.0, 0), (8.5, 12.0, 0), 0.6, 0.5):
            self.add_rail(e, "concrete", "ledge", "ledge_a")
        for e in G.ledge(B, (-6.0, 23.0, 0), (-1.0, 23.0, 0), 0.7, 0.42):
            self.add_rail(e, "concrete", "ledge", "ledge_b")
        # manual pad
        B.box("concrete", (3.0, 23.0, 0.0), (6.5, 25.0, 0.18), col="concrete")

    # -------------------------------------------------------------- rafters
    def rafters(self):
        B = self.B
        a = (-18.8, 27.5, 6.0)
        b = (-18.8, 47.0, 6.0)
        G.ibeam(B, a, b, h=0.36, w=0.24, mat="rafter", col="metal")
        # hangers from the truss above
        for yy in np.arange(28.0, 47.1, 4.0):
            B.cylinder("steel", (-18.8, yy, 6.0), (-18.8, yy, HALL["h"] - 2.0), 0.03, 6)
            self.hanger((-18.8, yy, 6.0), (-18.8, yy, HALL["h"] - 2.0))
        self.add_rail([(a[0], a[1], a[2] + 0.01), (b[0], b[1], b[2] + 0.01)], "metal", "rafter", "rafter_west")
        # a second rafter high above the east quarter's coping (clear of ordinary airs): a big
        # vert air meets its underside, and holding grind there pops the skater up onto it
        c = (19.0, 32.0, 6.8)
        d = (19.0, 46.0, 6.8)
        G.ibeam(B, c, d, h=0.36, w=0.24, mat="rafter", col="metal")
        for yy in np.arange(32.0, 46.1, 3.5):
            B.cylinder("steel", (19.0, yy, 6.8), (19.0, yy, HALL["h"] - 2.0), 0.03, 6)
            self.hanger((19.0, yy, 6.8), (19.0, yy, HALL["h"] - 2.0))
        self.add_rail([(c[0], c[1], c[2] + 0.01), (d[0], d[1], d[2] + 0.01)], "metal", "rafter", "rafter_east")

    # -------------------------------------------------------------- secret room
    def secret_room(self):
        B = self.B
        x0, x1, y0, y1, h = -30.0, -20.0, 31.0, 43.0, 5.0
        B.quad("concrete_floor", [(x0, y0, 0), (x1, y0, 0), (x1, y1, 0), (x0, y1, 0)], col="concrete")
        B.quad("roof", [(x0, y1, h), (x1, y1, h), (x1, y0, h), (x0, y0, h)], col="wall")   # solid ceiling: airs off the room's quarter stop here
        for pts in ([(x0, y0, 0), (x1, y0, 0), (x1, y0, h), (x0, y0, h)],
                    [(x1, y1, 0), (x0, y1, 0), (x0, y1, h), (x1, y1, h)],
                    [(x0, y1, 0), (x0, y0, 0), (x0, y0, h), (x0, y1, h)]):
            B.quad("cinder", list(reversed(pts)), col="wall")
        # outside face of the west hall wall above the doorway
        B.quad("cinder", [(x1, y0, 0), (x1, 34.0, 0), (x1, 34.0, h), (x1, y0, h)], col="wall", flip=True)
        B.quad("cinder", [(x1, 39.0, 0), (x1, y1, 0), (x1, y1, h), (x1, 39.0, h)], col="wall", flip=True)
        B.quad("cinder", [(x1, 34.0, 3.2), (x1, 39.0, 3.2), (x1, 39.0, h), (x1, 34.0, h)], col="wall", flip=True)
        # a mini quarter on the far wall and a kicker aimed at the tape
        G.quarter_pipe(B, (x0 + 0.6 + 2.0, 37.0, 0.0), 90.0, 11.8, 2.0, 2.0, 0.6)
        G.kicker(B, (-23.5, 37.0, 0.0), 90.0, 2.4, 1.5, 0.6)
        top = G.rail(B, [(-27.0, 32.5, 0), (-21.5, 32.5, 0)], 0.4)
        self.add_rail(top, "metal", "rail", "secret_rail")
        # lamp
        B.box("lamp", (-25.5, 36.8, h - 0.08), (-24.0, 37.2, h - 0.04))
        self.data["tape"] = to_godot((-26.4, 37.0, 2.5))
        self.data["secret_room"] = dict(min=to_godot((x0, y1, 0)), max=to_godot((x1, y0, h)))

    def breakable_wall(self, coll, mats):
        """Boarded-up plywood panels closing the doorway at x=-20, y 34..39."""
        pieces = []
        for i in range(5):
            y = 34.0 + i * 1.0
            bm = bmesh.new()
            bmesh.ops.create_cube(bm, size=1)
            bmesh.ops.scale(bm, vec=(0.06, 0.98, 3.18), verts=bm.verts)
            bmesh.ops.translate(bm, vec=(-20.05, y + 0.5, 1.6), verts=bm.verts)
            ob = C.bm_to_object(bm, f"BreakWall_{i}", coll)
            C.box_uv(ob, 1.5)
            C.assign(ob, mats["boards"])
            pieces.append(ob)
        # a couple of cross battens
        for z in (0.8, 2.4):
            bm = bmesh.new()
            bmesh.ops.create_cube(bm, size=1)
            bmesh.ops.scale(bm, vec=(0.05, 5.0, 0.18), verts=bm.verts)
            bmesh.ops.rotate(bm, cent=(0, 0, 0), matrix=Matrix.Rotation(math.radians(8 if z < 1 else -8), 3, 'X'), verts=bm.verts)
            bmesh.ops.translate(bm, vec=(-19.98, 36.5, z), verts=bm.verts)
            ob = C.bm_to_object(bm, f"BreakWall_batten{int(z*10)}", coll)
            C.box_uv(ob, 1.5)
            C.assign(ob, mats["crate_frame"])
            pieces.append(ob)
        self.data["break_wall"] = dict(center=to_godot((-20.05, 36.5, 1.6)), size=[0.3, 3.2, 5.0],
                                       nodes=[p.name for p in pieces])
        return pieces

    def window_objects(self, coll, mats):
        objs = []
        for i, w in enumerate(self.windows):
            y0, y1, z0, z1, x = w["y0"], w["y1"], w["z0"], w["z1"], w["x"]
            # frame (static) + glass (breakable)
            B = self.B
            for (a, b) in (((x - 0.12, y0 - 0.08, z0 - 0.1), (x, y1 + 0.08, z0)), ((x - 0.12, y0 - 0.08, z1), (x, y1 + 0.08, z1 + 0.1)),
                           ((x - 0.12, y0 - 0.08, z0), (x, y0, z1)), ((x - 0.12, y1, z0), (x, y1 + 0.08, z1)),
                           ((x - 0.1, (y0 + y1) / 2 - 0.03, z0), (x, (y0 + y1) / 2 + 0.03, z1)),
                           ((x - 0.1, y0, (z0 + z1) / 2 - 0.03), (x, y1, (z0 + z1) / 2 + 0.03))):
                B.box("steel_paint", a, b)
            me = bpy.data.meshes.new(f"Window_{i}")
            me.from_pydata([(x - 0.05, y0, z0), (x - 0.05, y1, z0), (x - 0.05, y1, z1), (x - 0.05, y0, z1)], [], [(0, 3, 2, 1)])
            ob = bpy.data.objects.new(f"Window_{i}", me)
            C.link(ob, coll)
            C.box_uv(ob, 3.0)
            C.assign(ob, mats["glass"])
            objs.append(ob)
            self.data.setdefault("windows", []).append(dict(name=ob.name, center=to_godot((x - 0.05, (y0 + y1) / 2, (z0 + z1) / 2)),
                                                            size=[y1 - y0, z1 - z0]))
        # outside backdrop behind the windows: bright daylight so the glass glows
        B = self.B
        B.quad("yard", [(26.0, -16.0, 0), (26.0, 50.0, 0), (26.0, 50.0, 12), (26.0, -16.0, 12)], flip=True)
        B.quad("yard", [(20.4, -16.0, 0.0), (26.0, -16.0, 0.0), (26.0, 50.0, 0.0), (20.4, 50.0, 0.0)])
        return objs

    # -------------------------------------------------------------- props
    def props(self):
        B = self.B
        r = C.rng(5)
        stacks = [(-15.5, -10.0), (-15.0, 6.0), (-16.5, 26.0), (15.5, -12.5), (-16.5, 45.5), (14.0, 47.0),
                  (-28.0, 41.0), (-28.5, 33.0)]
        for (x, y) in stacks:
            n = int(r.integers(2, 4))
            for k in range(n):
                sz = r.uniform(1.0, 1.4)
                G.crate(B, (x + r.uniform(-0.4, 0.4), y + r.uniform(-0.4, 0.4), 0.0 if k < 2 else sz * 0.98),
                        (sz, sz, sz * 0.95), rot=r.uniform(-20, 20))
                if k == 0:
                    x += sz * 1.05
        # barrels
        for (x, y) in [(-14.0, 30.5), (-13.3, 31.1), (-14.1, 31.7), (15.3, 44.0), (15.9, 44.6), (-7.0, -1.0), (10.5, 20.0)]:
            G.barrel(B, (x, y, 0.0))
        # pallets
        for (x, y) in [(-13.0, 40.0), (11.0, 44.5)]:
            for k in range(3):
                B.box("crate", (x - 0.6, y - 0.5 + k * 0.45, 0.0), (x + 0.6, y - 0.4 + k * 0.45, 0.12), col="concrete")
            B.box("crate", (x - 0.6, y - 0.5, 0.12), (x + 0.6, y + 0.5, 0.15), col="concrete")
        # dumpster
        B.box("dumpster", (13.0, -8.5, 0.0), (15.5, -6.9, 1.3), col="wall")
        B.box("dumpster", (12.95, -8.55, 1.3), (15.55, -6.85, 1.38))
        # hanging fluorescent lamps under the trusses
        for (xx, yy) in lamp_positions():
            B.box("steel", (xx - 1.3, yy - 0.12, 8.2), (xx + 1.3, yy + 0.12, 8.3))
            B.box("lamp", (xx - 1.2, yy - 0.06, 8.14), (xx + 1.2, yy + 0.06, 8.2))
            B.cylinder("steel", (xx - 1.0, yy, 8.3), (xx - 1.0, yy, HALL["h"] - 2.0), 0.008, 4)
            B.cylinder("steel", (xx + 1.0, yy, 8.3), (xx + 1.0, yy, HALL["h"] - 2.0), 0.008, 4)
        # floor paint lines
        for (a, b) in (((-15.0, -3.0), (15.0, -3.0)), ((-15.0, 33.0), (15.0, 33.0))):
            B.quad("paint_line", [(a[0], a[1] - 0.06, 0.004), (b[0], b[1] - 0.06, 0.004), (b[0], b[1] + 0.06, 0.004), (a[0], a[1] + 0.06, 0.004)])
        # roll-up door (south wall, east of the deck) and exit sign
        B.quad("corrugated", [(10.0, -15.95, 0.0), (16.0, -15.95, 0.0), (16.0, -15.95, 5.0), (10.0, -15.95, 5.0)])
        B.box("exit_sign", (-1.0, 49.9, 7.0), (1.0, 50.0, 7.5))

    # -------------------------------------------------------------- pickups
    def pickups(self):
        self.data["letters"] = [
            dict(letter="S", pos=to_godot((0.0, 9.0, 2.5))),             # over the kicker jump
            dict(letter="K", pos=to_godot((18.9, 21.8, 5.6))),           # air above the east quarter
            dict(letter="A", pos=to_godot((-18.8, 10.0, START_Z + 1.2))),  # on the west catwalk
            dict(letter="T", pos=to_godot((-5.4, 43.0, 5.9))),          # vert air off the halfpipe
            dict(letter="E", pos=to_godot((-9.0, 31.5, 2.9))),           # kicker gap
        ]
        self.data["spawn"] = dict(pos=to_godot((0.0, -12.5, START_Z + 0.02)), yaw_deg=0.0,
                                  forward=to_godot((0.0, 1.0, 0.0)))
        self.data["respawns"] = [to_godot(p) for p in ((0.0, 2.0, 0.0), (0.0, 30.0, 0.0), (-24.0, 36.0, 0.0), (10.0, 10.0, 0.0))]


# ------------------------------------------------------------------ assembly

def finish_mesh(bm, name, coll, smooth_angle=None):
    bmesh.ops.remove_doubles(bm, verts=bm.verts, dist=0.0005)
    bmesh.ops.dissolve_degenerate(bm, edges=bm.edges, dist=0.0002)
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces) if False else None
    ob = C.bm_to_object(bm, name, coll)
    return ob


def build(export=True, bake=True):
    C.reset_scene()
    coll = C.collection("Park")
    imgs = build_textures()
    mats = make_materials(imgs)
    P = Park()
    P.shell()
    P.entry()
    P.ramps()
    P.street()
    P.rafters()
    P.secret_room()
    P.props()
    wins = P.window_objects(coll, mats)
    walls = P.breakable_wall(coll, mats)
    # original graffiti (graffiti.py): decals on the walls + a stencil on the boarded wall
    import graffiti
    gfx, sign = graffiti.build(coll)
    walls.append(sign)
    P.data["break_wall"]["nodes"].append(sign.name)
    P.pickups()
    visual = []
    for name, bm in P.B.parts.items():
        ob = finish_mesh(bm, "Park_" + name, coll)
        C.assign(ob, mats[name])
        scale = imgs[name][2] if name in imgs else 2.0
        C.box_uv(ob, scale)
        for p in ob.data.polygons:
            p.use_smooth = False
        ob.data.set_sharp_from_angle(angle=math.radians(35))
        for p in ob.data.polygons:
            p.use_smooth = True
        visual.append(ob)
    cols = []
    for surf, bm in P.B.cols.items():
        ob = finish_mesh(bm, f"COL_{surf}-colonly", coll)
        ob.display_type = 'WIRE'
        ob.hide_render = True
        cols.append(ob)
    for o in walls + wins:
        pass
    import bake as BK
    lm_objs = [o for o in visual if o.name.replace("Park_", "") not in LIGHTMAPPED_EXCLUDE] + walls + [gfx]
    # roof, trusses and props get less lightmap space than the skateable surfaces; the thin
    # coping and rail pipes (2-3 cm, built as <= 2 m pieces) get twice the density, or their
    # islands would be only a few texels round and bleed into the black margin
    C.lightmap_uv(lm_objs, "Lightmap", margin=0.0015,
                  weights={"Park_roof": 0.3, "Park_steel_paint": 0.45, "Park_steel": 0.5, "Park_corrugated": 0.6,
                           "Park_crate_frame": 0.6, "Park_lamp": 0.3, "Park_graffiti": 0.35, "BreakWall_sign": 0.3,
                           "Park_coping": 2.0, "Park_rail": 2.0})
    C.show(visual, 'MATERIAL', azimuth=210, elevation=35, margin=0.55)
    P.data["rails"] = P.rails
    P.data["lightmapped"] = [o.name for o in lm_objs]
    P.data["units"] = "metres, Godot axes (Y up, -Z = north)"
    with open(os.path.join(C.ASSETS, "park_data.json"), "w") as f:
        json.dump(P.data, f, indent=1)
    if bake:
        BK.bake_lightmap(lm_objs, visual, P)
    if export:
        export_objs = visual + [gfx] + cols + wins + walls
        C.export_glb(os.path.join(C.ASSETS, "park.glb"), objects=export_objs, extra=dict(
            export_image_format='WEBP', export_image_quality=90, export_lights=False))
        C.save_blend("park")
    return P
