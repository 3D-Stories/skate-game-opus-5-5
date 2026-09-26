"""Level kit: builds a data-defined level from its definition, levels/<id>/level.json.

    blender --background --python blender/build_all.py -- --only <id>      (one level)
    blender --background --python blender/build_all.py -- --only levels   (every kit level)

The definition's "build" section lists the level's materials, lights, features (ramps,
bowls, rails, stairs, walls, props ...), breakables, pickups, gaps and graffiti in Blender
coordinates (metres, +Y north, Z up). The build writes, for the game:

    assets/levels/<id>/<id>.glb           visual meshes merged per material (each with a
                                          'Lightmap' UV set), collision as COL_<surface>-colonly,
                                          breakables as their own nodes
    assets/levels/<id>/<id>_data.json     rails, spawn, pickups, breakables, gaps, lighting
                                          ... in Godot axes (Y up, -Z = north)
    assets/levels/<id>/<id>_lightmap.png  the Cycles bake (levelkit/lighting.py)
    blender/work/<id>.blend               for the renders (renders.py render_level)

Every feature type is one function below, f_<type>(L, spec); docs/LEVELS.md lists them
with their parameters. A level can add its own feature types in levels/<id>/features.py
(def f_<type>(L, spec)) without touching the kit.
"""
import importlib.util
import json
import math
import os
import time

import bpy
import numpy as np
from mathutils import Vector

from lib import common as C
from levelkit import geo as G
from levelkit import materials as KM
from levelkit import lighting as KL
from levelkit import breakables as KB
from levelkit import props as KP

LEVELS_DIR = os.path.join(C.PROJECT_DIR, "levels")


def registry():
    with open(os.path.join(LEVELS_DIR, "registry.json")) as f:
        return json.load(f)


def load_def(level_id):
    with open(os.path.join(LEVELS_DIR, level_id, "level.json")) as f:
        return json.load(f)


def kit_levels():
    """Ids of the registered levels that are built by the kit (not the Warehouse's park.py)."""
    out = []
    for lid in registry()["levels"]:
        d = load_def(lid)
        if d.get("build", {}).get("builder", "levelkit") == "levelkit" and "features" in d.get("build", {}):
            out.append(lid)
    return out


def to_godot(p):
    return [round(float(p[0]), 4), round(float(p[2]), 4), round(float(-p[1]), 4)]


class LevelBuild:
    """State of one level build: the geometry builder, rails, data for the game, breakable
    objects, floor holes, extra lights."""

    def __init__(self, defn):
        self.defn = defn
        self.id = defn["id"]
        b = defn["build"]
        self.b = b
        self.prefix = b.get("material_prefix", self.id + "_")
        self.obj_prefix = b.get("object_prefix", self.id.capitalize() + "_")
        self.B = G.Builder()
        self.rails = []
        self.data = {}
        self.breakables = []
        self.holes = []
        self.lights_extra = {"areas": [], "points": []}
        self.coll = None
        self.mats = {}
        self.imgs = {}
        self.gfx = None
        self.custom = {}

    g = staticmethod(to_godot)

    def add_rail(self, pts, kind="metal", tag="rail", name=""):
        self.rails.append(dict(name=name or f"rail_{len(self.rails)}", kind=kind, tag=tag,
                               points=[to_godot(p) for p in pts]))

    def box_g(self, lo, hi):
        """Blender AABB (lo, hi) -> Godot {min, max}."""
        return dict(min=to_godot((lo[0], hi[1], lo[2])), max=to_godot((hi[0], lo[1], hi[2])))


# ==================================================================== feature types

def _opening_s(side, rect, o):
    """World-coordinate opening -> (s0, s1, zlo, zhi) along the hall wall walked anticlockwise."""
    x0, y0, x1, y1 = rect
    if side in ("east", "west"):
        a, b = o["y"]
        s0, s1 = (a - y0, b - y0) if side == "east" else (y1 - b, y1 - a)
    else:
        a, b = o["x"]
        s0, s1 = (a - x0, b - x0) if side == "south" else (x1 - b, x1 - a)
    return (s0, s1, o["z"][0], o["z"][1])


def f_hall(L, s):
    """A rectangular hall: walls in height bands with openings (windows get frames and
    glazing), pilasters, a roof (flat or vaulted with a glazed lantern); the floor is laid
    at the end, round every hole the features cut into it (bowls)."""
    x0, y0, x1, y1 = s["rect"]
    h = s["height"]
    bands = [tuple(b) for b in s["bands"]]
    ends = [(0.0, h, bands[-1][2])]
    walls = {"south": ((x0, y0), (x1, y0)), "east": ((x1, y0), (x1, y1)), "north": ((x1, y1), (x0, y1)),
             "west": ((x0, y1), (x0, y0))}
    L.data["windows_static"] = []
    for side, (a, b) in walls.items():
        ops = s.get("openings", {}).get(side, [])
        G.wall(L.B, a, b, bands, True, [_opening_s(side, s["rect"], o) for o in ops], col=s.get("col", "wall"))
        for o in ops:
            if o.get("kind", "window") == "window":
                s0, s1, zlo, zhi = _opening_s(side, s["rect"], o)
                glass = G.window_frame(L.B, a, b, s0, s1, zlo, zhi, mullions=o.get("mullions", 2),
                                       transoms=o.get("transoms", 2), mat=o.get("frame_mat", "steel_paint"))
                L.B.quad(o.get("glass_mat", "frosted"), glass, col=s.get("col", "wall"))
                # a sill to the inside
                A, Bv = Vector((*a, 0)), Vector((*b, 0))
                d = (Bv - A).normalized()
                n = Vector((-d.y, d.x, 0))
                p, q = A + d * s0, A + d * s1
                lo = [min(p[i], q[i], p[i] + n[i] * 0.25, q[i] + n[i] * 0.25) for i in range(2)]
                hi = [max(p[i], q[i], p[i] + n[i] * 0.25, q[i] + n[i] * 0.25) for i in range(2)]
                L.B.box(o.get("sill_mat", "concrete"), (lo[0], lo[1], zlo - 0.12), (hi[0], hi[1], zlo), col="wall")
                c = (p + q) / 2
                L.data["windows_static"].append(dict(side=side, center=to_godot((c.x, c.y, (zlo + zhi) / 2)),
                                                     size=[round(s1 - s0, 3), round(zhi - zlo, 3)]))
    # pilasters (engaged piers) along the long walls
    pil = s.get("pilasters")
    if pil:
        w, dpt, every = pil.get("width", 0.5), pil.get("depth", 0.3), pil.get("every", 6.0)
        skip = [tuple(v) for v in pil.get("skip", [])]
        for side in pil.get("sides", ["east", "west"]):
            (a, b) = walls[side]
            A, Bv = Vector((*a, 0)), Vector((*b, 0))
            Lw = (Bv - A).length
            d = (Bv - A) / Lw
            n = Vector((-d.y, d.x, 0))
            for sv in np.arange(pil.get("start", every), Lw - 0.5, every):
                c = A + d * sv
                if any(k[0] <= (c.y if side in ("east", "west") else c.x) <= k[1] for k in skip):
                    continue
                q0 = c - d * w / 2
                q1 = c + d * w / 2 + n * dpt
                lo = (min(q0.x, q1.x), min(q0.y, q1.y), 0.0)
                hi = (max(q0.x, q1.x), max(q0.y, q1.y), pil.get("height", h))
                L.B.box(pil.get("mat", bands[0][2]), lo, hi, col="wall", faces=("north", "south", "east", "west"),
                        mat_top=None)
    roof = s.get("roof", {"type": "flat"})
    if roof["type"] == "vault":
        lan = roof.get("lantern")
        L.data["vault"] = dict(spring=h, rise=roof["rise"])
        G.vault(L.B, x0, x1, y0, y1, h, roof["rise"], roof.get("segs", 12), roof.get("mat", "roof"),
                roof.get("rib_mat", "steel_paint"), roof.get("rib_every", 4.0), roof.get("end_mat", bands[-1][2]),
                tuple(lan) if lan else None, roof.get("glass_mat", "skylight"), roof.get("lantern_mat", "steel_paint"),
                roof.get("lantern_h", 0.9))
    else:
        L.B.quad(roof.get("mat", "roof"), [(x0, y1, h), (x1, y1, h), (x1, y0, h), (x0, y0, h)])
    L.hall = dict(rect=(x0, y0, x1, y1), height=h, floor=s.get("floor", {"mat": "concrete_floor"}))
    L.data["hall"] = dict(min=to_godot((x0, y1, 0.0)), max=to_godot((x1, y0, h)))


def f_room(L, s):
    """A closed room (e.g. a hidden room) with a doorway on one side (cut the same doorway
    into the hall wall as an opening of kind "door")."""
    x0, y0, x1, y1 = s["rect"]
    h = s["height"]
    B = L.B
    B.quad(s.get("floor_mat", "concrete_floor"), [(x0, y0, 0), (x1, y0, 0), (x1, y1, 0), (x0, y1, 0)], col="concrete")
    B.quad(s.get("ceiling_mat", "roof"), [(x0, y1, h), (x1, y1, h), (x1, y0, h), (x0, y0, h)], col="wall")
    walls = {"south": ((x0, y0), (x1, y0)), "east": ((x1, y0), (x1, y1)), "north": ((x1, y1), (x0, y1)),
             "west": ((x0, y1), (x0, y0))}
    bands = [tuple(b) for b in s.get("bands", [[0.0, h, s.get("wall_mat", "brick")]])]
    door = s.get("door")
    for side, (a, b) in walls.items():
        ops = [_opening_s(side, s["rect"], door)] if door and door["side"] == side else []
        G.wall(B, a, b, bands, True, ops)
    if s.get("hidden", True):
        area = dict(name=s.get("label", s.get("name", "room")), **L.box_g((x0, y0, 0.0), (x1, y1, h)))
        if door:
            # the doorway (Godot): its centre on the wall, the way in, its width and height
            sd = door["side"]
            inward = {"west": (1, 0), "east": (-1, 0), "south": (0, 1), "north": (0, -1)}[sd]
            wx = x0 if sd == "west" else x1 if sd == "east" else sum(door["x"]) / 2
            wy = y0 if sd == "south" else y1 if sd == "north" else sum(door["y"]) / 2
            span = door["y"] if sd in ("east", "west") else door["x"]
            area["door"] = dict(center=to_godot((wx, wy, sum(door["z"]) / 2)), inward=to_godot((inward[0], inward[1], 0)),
                                width=round(span[1] - span[0], 4), height=round(door["z"][1] - door["z"][0], 4))
        L.data.setdefault("hidden_areas", []).append(area)


def f_quarterpipe(L, s):
    lip = G.quarter_pipe(L.B, tuple(s["at"]), s["facing"], s["width"], s["radius"], s["height"], s.get("deck", 1.0),
                         surf=s.get("surface", "plywood"), side=s.get("side", "rampside"), coping=s.get("coping_mat", "coping"),
                         struct=s.get("side", "rampside"), col_surface=s.get("col", "wood"), back_wall=s.get("back_wall", True))
    if s.get("coping"):
        L.add_rail(lip, "metal", "coping", s["coping"])
    return lip


def f_halfpipe(L, s):
    ca, cb = G.halfpipe(L.B, tuple(s["center"]), s["axis"], s["width"], s["radius"], s["height"], s.get("deck", 1.5),
                        s.get("flat", 4.0), surf=s.get("surface", "plywood"))
    for c, nm in ((ca, s.get("coping_a")), (cb, s.get("coping_b"))):
        if nm:
            L.add_rail(c, "metal", "coping", nm)
    if s.get("vert_zone", True):
        cx, cy, _ = s["center"]
        L.data.setdefault("vert_zones", []).append(dict(center=to_godot((cx, cy, 0.0)), axis=s["axis"],
                                                        half=[s.get("flat", 4.0) / 2 + s["radius"] + 1.5, s["width"] / 2 + 0.5]))


def f_spine(L, s):
    ca, cb = G.spine(L.B, tuple(s["center"]), s["axis"], s["width"], s["radius"], s["height"], surf=s.get("surface", "plywood"))
    if s.get("coping"):
        L.add_rail(ca, "metal", "coping", s["coping"])


def f_bank(L, s):
    prof, top = G.bank(L.B, tuple(s["at"]), s["facing"], s["width"], s["height"], s.get("angle", 30.0), s.get("fillet", 2.5),
                       s.get("round_top", 0.8), s.get("deck", 0.0), surf=s.get("surface", "plywood"),
                       side=s.get("side", "rampside"), col_surface=s.get("col", "wood"), back=s.get("back", "rampside"))
    if s.get("edge_rail"):
        L.add_rail(top, "wood", "ledge", s["edge_rail"])


def f_kicker(L, s):
    G.kicker(L.B, tuple(s["at"]), s["facing"], s["width"], s["length"], s["height"], surf=s.get("surface", "plywood"))


def f_funbox(L, s):
    edges = G.funbox(L.B, tuple(s["center"]), s["top"][0], s["top"][1], s["height"], s["bank"],
                     surf=s.get("surface", "plywood"))
    if s.get("edge_rails"):
        for i, (a, b) in enumerate(edges):
            L.add_rail([a, b], "wood", "ledge", f"{s['edge_rails']}_{i}")
    r = s.get("rail")
    if r:
        top = G.rail(L.B, [tuple(r["a"]), tuple(r["b"])], r.get("height", 0.42), post_every=r.get("post_every", 2.6))
        L.add_rail(top, "metal", "rail", r.get("name", "funbox_rail"))


def f_rail(L, s):
    top = G.rail(L.B, [tuple(p) for p in s["points"]], s.get("height", 0.5), r=s.get("r", 0.024),
                 post_every=s.get("post_every", 2.5), mat=s.get("mat", "rail"), post_mat=s.get("post_mat", "steel"))
    L.add_rail(top, "metal", s.get("tag", "rail"), s.get("name", ""))


def f_ledge(L, s):
    es = G.ledge(L.B, tuple(s["a"]), tuple(s["b"]), s.get("width", 0.6), s.get("height", 0.5), mat=s.get("mat", "concrete"),
                 edge_mat=s.get("edge_mat", "coping"))
    for i, e in enumerate(es):
        L.add_rail(e, "concrete", "ledge", f"{s.get('name', 'ledge')}_{i}" if len(es) > 1 else s.get("name", "ledge"))


def f_bench(L, s):
    es = G.bench(L.B, tuple(s["a"]), tuple(s["b"]), s.get("height", 0.45), s.get("depth", 0.42), mat=s.get("mat", "crate"))
    for i, e in enumerate(es):
        L.add_rail(e, "wood", "ledge", f"{s.get('name', 'bench')}_{i}")


def f_stairs(L, s):
    nos, top_z, run = G.stairs(L.B, tuple(s["at"]), s["facing"], s["width"], s["n"], s["rise"], s["tread"],
                               mat=s.get("mat", "concrete"), nosing_mat=s.get("nosing_mat"), back=s.get("back", True))
    for k in s.get("ledges", []):
        a, b = nos[k - 1]
        L.add_rail([a, b], "concrete", "ledge", s.get("name", "stairs") + f"_step{k}")
    for hr in s.get("handrails", []):
        top = G.stair_rail(L.B, tuple(s["at"]), s["facing"], hr["x"], s["n"], s["rise"], s["tread"],
                           height=hr.get("height", 0.85), flat_top=hr.get("flat_top", 0.6), flat_bottom=hr.get("flat_bottom", 0.8))
        L.add_rail(top, "metal", "rail", hr["name"])


def f_bowl(L, s):
    """A pool-style bowl (see geo.bowl). coping: {"north": name, ...} grind lines along the lip
    by side (north/south include their corners)."""
    x0, y0, x1, y1 = s["rect"]
    m = s.get("materials", {})
    res = G.bowl(L.B, (x0, y0, x1, y1), s["corner"], s["radius"], [tuple(k) for k in s["depth"]], z0=s.get("z", 0.0),
                 wall_mat=m.get("wall", "pool_tile"), floor_mat=m.get("floor", "pool_tile"), band_mat=m.get("band", "pool_band"),
                 coping_mat=m.get("coping", "coping_stone"), ring_mat=m.get("ring", "coping_stone"), deck_mat=m.get("deck", "deck"),
                 ring_w=s.get("ring_w", 0.35), margin=s.get("margin", 1.2))
    L.holes.append(res["outer"])
    L.custom[s.get("name", "bowl")] = res
    rc = s["corner"]
    ring = res["ring"]
    z0 = s.get("z", 0.0)
    xc = (x0 + x1) / 2

    def side_of(p):
        if p[1] >= y1 - rc - 1e-6:
            return "north"
        if p[1] <= y0 + rc + 1e-6:
            return "south"
        return "east" if p[0] > xc else "west"
    sides = [side_of(p) for (p, n, c) in ring]
    for side, name in s.get("coping", {}).items():
        idx = [i for i, sd in enumerate(sides) if sd == side]
        if not idx:
            continue
        # rotate so the run is contiguous (the ring starts mid-south)
        n = len(ring)
        start = next(i for i in idx if sides[(i - 1) % n] != side)
        run = []
        i = start
        while sides[i % n] == side:
            run.append(i % n)
            i += 1
            if len(run) > n:
                break
        run.append(i % n)                         # up to the first point of the next side
        pts = [(ring[k][0][0], ring[k][0][1], z0 + 0.01) for k in run]
        L.add_rail(pts, "concrete", s.get("coping_tag", "coping"), name)
    # lane lines (dark tile strips on the floor) and the vert zone for THPS auto-align airs
    depth = res["depth"]
    Rof = res["R"]
    zf = lambda x, y: z0 - depth(y)
    for ln in s.get("lanes", []):
        xa = xc + ln
        ya, yb = y0 + Rof(y0) + 1.6, y1 - Rof(y1) - 1.6
        G.floor_strip(L.B, m.get("line", "pool_line"), [(xa, ya), (xa, yb)], 0.25, zf)
        for yy in (ya, yb):
            G.floor_strip(L.B, m.get("line", "pool_line"), [(xa - 0.5, yy), (xa + 0.5, yy)], 0.25, zf, lift=0.009)
    for vz in s.get("vert_zones", []):
        # [ya, yb]: a straight stretch where airs come straight back down (across x)
        cy = (vz[0] + vz[1]) / 2
        L.data.setdefault("vert_zones", []).append(dict(center=to_godot((xc, cy, 0.0)), axis=0.0,
                                                        half=[(x1 - x0) / 2 + 1.0, (vz[1] - vz[0]) / 2]))
    L.data.setdefault("bowls", []).append(dict(name=s.get("name", "bowl"), rect=[to_godot((x0, y1, z0)), to_godot((x1, y0, z0))],
                                               corner=rc, radius=s["radius"], depth=s["depth"], z=z0))


def f_bridge(L, s):
    """A raised walkway (gantry, gallery bridge) from a to b (2D) at height z: deck, fascias,
    underside, posts down to given bottoms, optional grindable handrails on both sides.
    posts: [[x, y, z_bottom], ...]; rails: {"left": name, "right": name} (left of a->b)."""
    B = L.B
    a, b = Vector((*s["a"], 0)), Vector((*s["b"], 0))
    z = s["z"]
    w = s.get("width", 1.8) / 2
    t = s.get("thick", 0.25)
    d = (b - a).normalized()
    n = Vector((-d.y, d.x, 0))
    c = [a - n * w, b - n * w, b + n * w, a + n * w]
    top = [tuple(p + Vector((0, 0, z))) for p in c]
    bot = [tuple(p + Vector((0, 0, z - t))) for p in c]
    B.quad(s.get("deck_mat", "diamond"), top, col=s.get("col", "metal"))
    B.quad(s.get("under_mat", "steel_paint"), list(reversed(bot)))
    for i in range(4):
        if i == 3 and s.get("open_start", True):
            continue                      # the start end joins the landing it leaves from
        j = (i + 1) % 4
        B.quad(s.get("fascia_mat", "steel_paint"), [bot[i], bot[j], top[j], top[i]], col="wall")
    for p in s.get("posts", []):
        for side in (-1, 1):
            q = Vector((p[0], p[1], 0)) + n * side * (w - 0.12)
            B.box(s.get("post_mat", "steel_paint"), (q.x - 0.07, q.y - 0.07, p[2]), (q.x + 0.07, q.y + 0.07, z - t), col="wall")
            L.data.setdefault("hangers", []).append([to_godot((q.x, q.y, p[2])), to_godot((q.x, q.y, z - t))])
    for side, key in ((1, "left"), (-1, "right")):
        name = s.get("rails", {}).get(key)
        if not name:
            continue
        o = n * side * (w - 0.06)
        ra = a + o + Vector((0, 0, z))
        rb = b + o + Vector((0, 0, z))
        topl = G.rail(B, [tuple(ra), tuple(rb)], s.get("rail_height", 1.0), r=0.025, post_every=2.0,
                      mat=s.get("rail_mat", "rail"), post_mat=s.get("post_mat", "steel_paint"))
        L.add_rail(topl, "metal", "rail", name)


def f_box(L, s):
    L.B.box(s["mat"], tuple(s["lo"]), tuple(s["hi"]), col=s.get("col"), faces=s.get("faces", "all"),
            mat_top=s.get("mat_top"), col_top=s.get("col_top"))
    if s.get("edge_rails"):
        lo, hi = s["lo"], s["hi"]
        z = hi[2]
        edges = {"south": ((lo[0], lo[1], z), (hi[0], lo[1], z)), "north": ((hi[0], hi[1], z), (lo[0], hi[1], z)),
                 "west": ((lo[0], hi[1], z), (lo[0], lo[1], z)), "east": ((hi[0], lo[1], z), (hi[0], hi[1], z))}
        for side, name in s["edge_rails"].items():
            a, b = edges[side]
            L.B.cylinder(s.get("edge_mat", "coping"), a, b, 0.012, 6)
            L.add_rail([a, b], s.get("edge_kind", "concrete"), "ledge", name)


def f_cylinder(L, s):
    L.B.cylinder(s["mat"], tuple(s["a"]), tuple(s["b"]), s["r"], s.get("seg", 12), col=s.get("col"))


def f_beam(L, s):
    G.ibeam(L.B, tuple(s["a"]), tuple(s["b"]), h=s.get("h", 0.36), w=s.get("w", 0.2), mat=s.get("mat", "steel_paint"),
            col=s.get("col"))


def f_pipe(L, s):
    top = G.pipe_run(L.B, [tuple(p) for p in s["points"]], s.get("r", 0.08), s.get("mat", "steel"),
                     s.get("bracket_every", 3.0), s.get("wall_side"), col=s.get("col"))
    if s.get("name"):
        L.add_rail(top, "metal", s.get("tag", "pipe"), s["name"])


def f_crates(L, s):
    r = C.rng(s.get("seed", 5))
    for (x, y) in s["stacks"]:
        n = int(r.integers(2, 4))
        for k in range(n):
            sz = r.uniform(1.0, 1.4)
            G.crate(L.B, (x + r.uniform(-0.4, 0.4), y + r.uniform(-0.4, 0.4), 0.0 if k < 2 else sz * 0.98),
                    (sz, sz, sz * 0.95), rot=r.uniform(-20, 20))
            if k == 0:
                x += sz * 1.05


def f_barrels(L, s):
    for p in s["at"]:
        G.barrel(L.B, (p[0], p[1], p[2] if len(p) > 2 else 0.0))


def f_bunting(L, s):
    G.bunting(L.B, tuple(s["a"]), tuple(s["b"]), s.get("sag", 0.25), s.get("n", 14), s.get("flag", 0.28),
              mats=tuple(s.get("mats", ["flag_a", "flag_b"])))


def f_lamps(L, s):
    """Hanging globe lamps; each also gets a point light for the bake."""
    lt = s.get("light", {})
    for p in s["at"]:
        x, y = p[0], p[1]
        z = s.get("z", 5.5)
        top = s.get("ceiling", 9.0)
        if top == "vault" and "vault" in L.data:
            hx0, hy0, hx1, hy1 = L.hall["rect"]
            v = L.data["vault"]
            sp = (hx1 - hx0) / 2
            Rv = (sp * sp + v["rise"] ** 2) / (2 * v["rise"])
            zc = v["spring"] + v["rise"] - Rv
            xc = (hx0 + hx1) / 2
            top = zc + math.sqrt(max(0.0, Rv * Rv - (x - xc) ** 2)) - 0.05
        KP.pendant(L.B, (x, y, z), top, s.get("globe", 0.22), s.get("mat", "lamp"))
        L.lights_extra["points"].append(dict(name="Globe", at=[x, y, z], energy=lt.get("energy", 120.0),
                                             color=lt.get("color", [1.0, 0.9, 0.75]), radius=s.get("globe", 0.22)))


def f_lifeguard_chair(L, s):
    KP.lifeguard_chair(L.B, tuple(s["at"]), s.get("facing", 0.0), s.get("height", 1.9))


def f_ladder(L, s):
    KP.ladder_arches(L.B, tuple(s["at"]), tuple(s["inward"]), s.get("width", 0.5), s.get("height", 0.75),
                     s.get("mat", "chrome"))


def f_clock(L, s):
    KP.clock(L.B, tuple(s["at"]), tuple(s["normal"]), s.get("r", 0.45))


def f_boiler(L, s):
    KP.boiler(L.B, tuple(s["a"]), tuple(s["b"]), s.get("r", 1.1))


def f_quad(L, s):
    L.B.quad(s["mat"], [tuple(p) for p in s["points"]], col=s.get("col"), flip=s.get("flip", False))


def f_strip(L, s):
    z = s.get("z", 0.0)
    G.floor_strip(L.B, s["mat"], [tuple(p) for p in s["points"]], s.get("width", 0.12), lambda x, y: z, s.get("lift", 0.004))


def f_grille(L, s):
    KB.grille(L, s, L.mats[s.get("mat", "grille")])


def f_boards(L, s):
    KB.boards(L, s, L.mats[s.get("mat", "boards")], L.mats[s.get("batten_mat", "crate_frame")])


def f_sign(L, s):
    gf = L.b["graffiti"]
    KB.sign(L, s, L.mats[s.get("post_mat", "steel_paint")], L.mats[s.get("post_mat", "steel_paint")], L.gfx,
            gf["cells"], gf.get("atlas", 2048))


# ==================================================================== the build

def _features_module(level_id):
    p = os.path.join(LEVELS_DIR, level_id, "features.py")
    if not os.path.exists(p):
        return None
    spec = importlib.util.spec_from_file_location(f"level_{level_id}_features", p)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def _floor_decal(p, cells, atlas_px):
    """A decal lying on a floor: {"floor": true, "key", "at": [x, y, z], "up": [ux, uy] (the
    text's up direction on the floor), "width"} -> (points, uvs) like graffiti._quad."""
    x, y, w, h = cells[p["key"]]
    c = Vector(p["at"])
    up = Vector((p["up"][0], p["up"][1], 0.0)).normalized()
    right = Vector((up.y, -up.x, 0.0))
    W = p["width"]
    H = W * h / w
    pts = [c - right * W / 2 - up * H / 2, c + right * W / 2 - up * H / 2, c + right * W / 2 + up * H / 2,
           c - right * W / 2 + up * H / 2]
    u0, u1 = x / atlas_px, (x + w) / atlas_px
    v1, v0 = 1 - y / atlas_px, 1 - (y + h) / atlas_px
    return pts, [(u0, v0), (u1, v0), (u1, v1), (u0, v1)]


def finish_mesh(bm, name, coll):
    import bmesh
    bmesh.ops.remove_doubles(bm, verts=bm.verts, dist=0.0005)
    bmesh.ops.dissolve_degenerate(bm, edges=bm.edges, dist=0.0002)
    return C.bm_to_object(bm, name, coll)


def build_level(level_id, export=True, bake=True):
    t0 = time.time()
    defn = load_def(level_id)
    L = LevelBuild(defn)
    b = L.b
    C.reset_scene()
    L.coll = C.collection(L.obj_prefix.rstrip("_"))
    import graffiti
    # materials: textured (photo sources) + specials (emissive / glass)
    L.imgs = KM.build_textures(b["materials"], L.prefix)
    L.mats = KM.make_materials(L.imgs, L.prefix)
    L.mats.update(KM.specials(b.get("special_materials", {}), L.prefix))
    # decal atlases: "graffiti" (also the signs' faces) and any extra "decals" sets (e.g. grime)
    gf = b.get("graffiti")
    decal_sets = ([dict(gf, name="graffiti")] if gf else []) + list(b.get("decals", []))
    for ds in decal_sets:
        ds["cells"] = {k: tuple(v) for k, v in ds["cells"].items()}
        ds["_mat"] = graffiti.build_atlas(ds["cells"], ds["pieces"], L.prefix + ds["name"], ds.get("atlas", 2048))
    if gf:
        gf["cells"] = decal_sets[0]["cells"]
        L.gfx = decal_sets[0]["_mat"]
    extra = _features_module(level_id)
    for spec in b["features"]:
        t = spec["type"]
        fn = getattr(extra, "f_" + t, None) if extra else None
        fn = fn or globals().get("f_" + t)
        if fn is None:
            raise ValueError(f"{level_id}: unknown feature type '{t}'")
        fn(L, spec)
    # the hall floor round the holes the features cut
    if hasattr(L, "hall"):
        fl = L.hall["floor"]
        x0, y0, x1, y1 = L.hall["rect"]
        G.floor_minus(L.B, x0, y0, x1, y1, L.holes + [tuple(h) for h in fl.get("holes", [])],
                      fl.get("mat", "concrete_floor"), fl.get("col", "concrete"),
                      cell=tuple(fl.get("cell", (8.0, 6.0))))
    # graffiti / signage / grime decals
    decal_objs = []
    for ds in decal_sets:
        if not ds.get("placements"):
            continue
        quads = [_floor_decal(p, ds["cells"], ds.get("atlas", 2048)) if isinstance(p, dict) else
                 graffiti._quad(p[0], tuple(p[1]), tuple(p[2]), p[3], p[4], cells=ds["cells"], atlas_px=ds.get("atlas", 2048))
                 for p in ds["placements"]]
        decal_objs.append(graffiti._decal_object(L.obj_prefix + ds["name"], quads, ds["_mat"], L.coll))
    # merge per material; collision per surface
    special = set(b.get("special_materials", {}).keys())
    visual = []
    for name, bm in L.B.parts.items():
        ob = finish_mesh(bm, L.obj_prefix + name, L.coll)
        if name not in L.mats:
            raise ValueError(f"{level_id}: material '{name}' is used but not defined")
        C.assign(ob, L.mats[name])
        scale = L.imgs[name][2] if name in L.imgs else 2.0
        C.box_uv(ob, scale)
        for p in ob.data.polygons:
            p.use_smooth = False
        ob.data.set_sharp_from_angle(angle=math.radians(35))
        for p in ob.data.polygons:
            p.use_smooth = True
        visual.append(ob)
    cols = []
    for surf, bm in L.B.cols.items():
        ob = finish_mesh(bm, f"COL_{surf}-colonly", L.coll)
        ob.display_type = 'WIRE'
        ob.hide_render = True
        cols.append(ob)
    lm_objs = [o for o in visual if o.name[len(L.obj_prefix):] not in special] + L.breakables + decal_objs
    lmc = b.get("lightmap", {})
    weights = {L.obj_prefix + k if not k.startswith(("Sign", "Break")) else k: v for k, v in lmc.get("weights", {}).items()}
    for o in L.breakables:
        if o.name not in weights:
            weights[o.name] = lmc.get("breakable_weight", 0.6)
    for o in decal_objs:
        weights.setdefault(o.name, lmc.get("decal_weight", 0.35))
    C.lightmap_uv(lm_objs, "Lightmap", margin=lmc.get("margin", 0.0015), weights=weights)
    C.show(visual, 'MATERIAL', azimuth=210, elevation=35, margin=0.55)
    # data for the game
    out_dir = os.path.join(C.ASSETS, "levels", level_id)
    os.makedirs(out_dir, exist_ok=True)
    D = L.data
    D["id"] = level_id
    D["rails"] = L.rails
    sp = b["spawn"]
    fw = Vector((sp["dir"][0], sp["dir"][1], 0.0)).normalized()
    D["spawn"] = dict(pos=to_godot(sp["at"]), forward=to_godot(tuple(fw)))
    D["respawns"] = [to_godot(p) for p in b.get("respawns", [])]
    D["letters"] = [dict(letter=l["letter"], pos=to_godot(l["at"])) for l in b.get("letters", [])]
    if "tape" in b:
        D["tape"] = to_godot(b["tape"]["at"])
    D["gaps"] = [dict(id=g["id"], name=g["name"], points=g.get("points", 250),
                      **{"from": L.box_g(*g["from"]), "to": L.box_g(*g["to"])}) for g in b.get("gaps", [])]
    if "hall_centre" in b:
        D["hall_centre"] = to_godot(b["hall_centre"])
    D["material_prefix"] = L.prefix
    D["decal_materials"] = [ds["name"] for ds in decal_sets]
    D["shading"] = b.get("shading", {})
    D["unshaded"] = {k: v.get("game_boost", 1.4) for k, v in b.get("special_materials", {}).items() if v.get("kind", "emissive") != "glass"}
    D["lightmapped"] = [o.name for o in lm_objs]
    D["units"] = "metres, Godot axes (Y up, -Z = north)"
    lt = b["lights"]
    sun = lt["sun"]
    lm_scale = lt.get("lm_scale", 6.0)
    D["lighting"] = KL.lighting_data(Vector(sun["dir"]).normalized(), tuple(sun.get("color", (1, 1, 1))), sun.get("strength", 5.0),
                                     lm_scale, tuple(lt.get("sky", {}).get("color", (0.55, 0.66, 0.85))))
    data_path = os.path.join(out_dir, f"{level_id}_data.json")
    with open(data_path, "w") as f:
        json.dump(D, f, indent=1)
    print(f"[levelkit] {level_id}: geometry + data in {time.time() - t0:.0f}s "
          f"({len(visual)} meshes, {len(cols)} collision sets, {len(L.rails)} grind lines, {len(L.breakables)} breakable nodes)")
    if bake:
        spec = dict(lt)
        spec["areas"] = list(lt.get("areas", [])) + L.lights_extra["areas"]
        spec["points"] = list(lt.get("points", [])) + L.lights_extra["points"]
        lights = KL.lights_from_spec(spec, L.obj_prefix + "Lights")
        KL.bake_lightmap(lm_objs, lights, f"{level_id}_lightmap", out_dir, hide_prefixes=("COL_",) + tuple(lt.get("hide", [])),
                         lm_scale=lm_scale, size=lt.get("size"), samples=lt.get("samples"))
        print(f"[levelkit] {level_id}: baked in {time.time() - t0:.0f}s")
    if export:
        export_objs = visual + decal_objs + cols + L.breakables
        C.export_glb(os.path.join(out_dir, f"{level_id}.glb"), objects=export_objs, extra=dict(
            export_image_format='WEBP', export_image_quality=90, export_lights=False))
        C.save_blend(level_id)
    print(f"[levelkit] {level_id}: done in {time.time() - t0:.0f}s")
    return L
