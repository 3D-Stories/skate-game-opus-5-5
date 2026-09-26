"""Level kit, geometry: ramps with real transitions, bowls, banks, stairs, boxes, rails,
ledges, beams, pipes, walls and roofs.

Everything is built as bmesh geometry at real-world scale (metres, Blender axes: +Y north,
Z up) and tagged with a material name; the level build merges the pieces per material
(one mesh per material, so a level has a few dozen draw calls) and keeps a collision copy
per surface type ('wood', 'pool', 'concrete', 'metal', 'metal_thin', 'wall'). Transitions
are true circular arcs with 24+ segments so the skater's ground snapping follows them.

The first half of this module is the Warehouse's original park_geo.py, unchanged (the
Warehouse's park.glb rebuilds byte-identical through it); the builders after
"level kit additions" were added for data-defined levels (levelkit/level.py).
"""
import math

import bmesh
import numpy as np
from mathutils import Matrix, Vector


class Builder:
    """Collects triangles/quads per material, plus collision copies per surface type."""

    def __init__(self):
        self.parts = {}      # material -> bmesh
        self.cols = {}       # surface -> bmesh (collision)

    def _bm(self, table, key):
        if key not in table:
            table[key] = bmesh.new()
        return table[key]

    def quad(self, mat, pts, col=None, flip=False):
        pts = [Vector(p) for p in pts]
        if flip:
            pts = list(reversed(pts))
        bm = self._bm(self.parts, mat)
        vs = [bm.verts.new(p) for p in pts]
        try:
            bm.faces.new(vs)
        except ValueError:
            pass
        if col:
            cb = self._bm(self.cols, col)
            cv = [cb.verts.new(p) for p in pts]
            try:
                cb.faces.new(cv)
            except ValueError:
                pass

    def strip(self, mat, rows, col=None, flip=False, closed=False):
        """rows: list of point lists (same length) -> quad grid."""
        for i in range(len(rows) - 1):
            a, b = rows[i], rows[i + 1]
            n = len(a)
            rng = range(n if closed else n - 1)
            for j in rng:
                j2 = (j + 1) % n
                self.quad(mat, [a[j], a[j2], b[j2], b[j]], col, flip)

    def box(self, mat, lo, hi, col=None, faces="all", mat_top=None, col_top=None):
        x0, y0, z0 = lo
        x1, y1, z1 = hi
        P = {
            "top": [(x0, y0, z1), (x1, y0, z1), (x1, y1, z1), (x0, y1, z1)],
            "bottom": [(x0, y1, z0), (x1, y1, z0), (x1, y0, z0), (x0, y0, z0)],
            "south": [(x0, y0, z0), (x1, y0, z0), (x1, y0, z1), (x0, y0, z1)],
            "north": [(x1, y1, z0), (x0, y1, z0), (x0, y1, z1), (x1, y1, z1)],
            "west": [(x0, y1, z0), (x0, y0, z0), (x0, y0, z1), (x0, y1, z1)],
            "east": [(x1, y0, z0), (x1, y1, z0), (x1, y1, z1), (x1, y0, z1)],
        }
        for k, pts in P.items():
            if faces != "all" and k not in faces:
                continue
            if k == "top" and mat_top:
                self.quad(mat_top, pts, col_top or col)
            else:
                self.quad(mat, pts, col)

    def cylinder(self, mat, a, b, r, seg=12, col=None, caps=True, chunk=2.0):
        """A pipe from a to b. Long pipes are built as <= chunk m pieces with a 1.5 mm gap
        at each join (wider than finish_mesh's 0.5 mm weld, far too small to see), so each
        piece is its own short lightmap UV island: a 60 m coping would otherwise unwrap
        into one strip longer than the whole atlas."""
        a, b = Vector(a), Vector(b)
        d = (b - a).normalized()
        up = Vector((0, 0, 1)) if abs(d.z) < 0.9 else Vector((1, 0, 0))
        u = d.cross(up).normalized()
        v = d.cross(u).normalized()
        offs = []
        for k in range(seg):
            t = 2 * math.pi * k / seg
            offs.append(u * math.cos(t) * r + v * math.sin(t) * r)
        n = max(1, math.ceil((b - a).length / chunk - 1e-6))
        gap = d * 0.00075 if n > 1 else Vector((0, 0, 0))
        for i in range(n):
            pa = a.lerp(b, i / n) + (gap if i > 0 else Vector((0, 0, 0)))
            pb = a.lerp(b, (i + 1) / n) - (gap if i < n - 1 else Vector((0, 0, 0)))
            self.strip(mat, [[pa + o for o in offs], [pb + o for o in offs]], col, closed=True)
        ra = [a + o for o in offs]
        rb = [b + o for o in offs]
        if caps:
            bm = self._bm(self.parts, mat)
            for ring, fl in ((ra, True), (rb, False)):
                vs = [bm.verts.new(p) for p in (reversed(ring) if fl else ring)]
                try:
                    bm.faces.new(vs)
                except ValueError:
                    pass

    def tube_path(self, mat, pts, r, seg=10, col=None):
        for a, b in zip(pts[:-1], pts[1:]):
            self.cylinder(mat, a, b, r, seg, col, caps=False)


def frame(origin, facing_deg):
    """Local ramp frame: local +Y = direction the ramp faces (the rider rides up toward -Y
    ... we define: local x along the ramp width, local y from the ramp's floor edge
    toward its top (into the ramp), z up. facing_deg rotates local y in world XY."""
    R = Matrix.Rotation(math.radians(facing_deg), 4, 'Z')
    return Matrix.Translation(Vector(origin)) @ R


def xf(M, p):
    return tuple(M @ Vector(p))


def transition_profile(radius, height, segs=26):
    """Points (y, z) of a quarter-pipe surface from the floor (y=0,z=0) upward. The ramp
    rises toward +y. If height > radius a vertical section is added."""
    pts = []
    arc_h = min(height, radius)
    a_max = math.acos(1 - arc_h / radius)
    for i in range(segs + 1):
        a = a_max * i / segs
        pts.append((radius * math.sin(a), radius - radius * math.cos(a)))
    if height > radius + 1e-4:
        y_top = pts[-1][0]
        n = max(2, int((height - radius) / 0.15))
        for k in range(1, n + 1):
            pts.append((y_top, radius + (height - radius) * k / n))
    return pts


def quarter_pipe(B, origin, facing, width, radius, height, deck, surf="plywood", side="rampside",
                 coping="coping", struct="rampside", col_surface="wood", back_wall=True):
    """A quarter pipe. origin = floor edge centre; the ramp rises in the local +y
    direction (world direction = facing). Returns the coping line (world) for rails."""
    M = frame(origin, facing)
    prof = transition_profile(radius, height)
    w = width / 2
    rows = [[xf(M, (x, y, z)) for (y, z) in prof] for x in (-w, w)]
    # surface quads between the two edge profiles (normal pointing to the rider = -y side)
    B.strip(surf, [rows[0], rows[1]], col=col_surface, flip=True)
    y_top = prof[-1][0]
    # deck
    B.quad(surf, [xf(M, (-w, y_top, height)), xf(M, (w, y_top, height)),
                  xf(M, (w, y_top + deck, height)), xf(M, (-w, y_top + deck, height))], col=col_surface)
    # sides (fill under the profile)
    fz = origin[2]
    for x, fl in ((-w, False), (w, True)):
        pts = [xf(M, (x, y, z)) for (y, z) in prof] + [xf(M, (x, y_top + deck, height))]
        for i in range(len(pts) - 1):
            B.quad(side, [pts[i], pts[i + 1], _floor_of(pts[i + 1], fz), _floor_of(pts[i], fz)], col="wall", flip=fl)
    if back_wall:
        B.quad(struct, [xf(M, (w, y_top + deck, 0)), xf(M, (-w, y_top + deck, 0)),
                        xf(M, (-w, y_top + deck, height)), xf(M, (w, y_top + deck, height))], col="wall")
    # coping pipe at the lip
    a = Vector(xf(M, (-w, y_top + 0.03, height - 0.03)))
    b = Vector(xf(M, (w, y_top + 0.03, height - 0.03)))
    B.cylinder(coping, a, b, 0.03, 12)
    # metal lip plate under the coping
    return [tuple(a + Vector((0, 0, 0.03))), tuple(b + Vector((0, 0, 0.03)))]


def _floor_of(p, z=0.0):
    return (p[0], p[1], z)


def kicker(B, origin, facing, width, length, height, surf="plywood", side="rampside"):
    """Launch ramp: a curved ramp (large radius) ending at 'height' with a short flat lip."""
    # choose radius so the arc spans 'length' horizontally and rises 'height'
    r = (length ** 2 + height ** 2) / (2 * height)
    M = frame(origin, facing)
    segs = 16
    a_max = math.asin(min(1.0, length / r))
    prof = [(r * math.sin(a_max * i / segs), r - r * math.cos(a_max * i / segs)) for i in range(segs + 1)]
    w = width / 2
    rows = [[xf(M, (x, y, z)) for (y, z) in prof] for x in (-w, w)]
    B.strip(surf, rows, col="wood", flip=True)
    yt, zt = prof[-1]
    # back face
    B.quad(side, [xf(M, (w, yt, 0)), xf(M, (-w, yt, 0)), xf(M, (-w, yt, zt)), xf(M, (w, yt, zt))], col="wall")
    fz = origin[2]
    for x, fl in ((-w, False), (w, True)):
        pts = [xf(M, (x, y, z)) for (y, z) in prof]
        for i in range(len(pts) - 1):
            B.quad(side, [pts[i], pts[i + 1], _floor_of(pts[i + 1], fz), _floor_of(pts[i], fz)], col="wall", flip=fl)
    # metal lip
    B.cylinder("coping", xf(M, (-w, yt - 0.01, zt - 0.02)), xf(M, (w, yt - 0.01, zt - 0.02)), 0.02, 8)
    return prof


def bank(B, lo_edge_a, lo_edge_b, top_a, top_b, surf="plywood", col="wood"):
    B.quad(surf, [lo_edge_a, lo_edge_b, top_b, top_a], col=col)


def funbox(B, center, top_w, top_l, h, bank_len, surf="plywood", side="rampside"):
    cx, cy = center
    x0, x1 = cx - top_w / 2, cx + top_w / 2
    y0, y1 = cy - top_l / 2, cy + top_l / 2
    X0, X1 = x0 - bank_len, x1 + bank_len
    Y0, Y1 = y0 - bank_len, y1 + bank_len
    B.quad(surf, [(x0, y0, h), (x1, y0, h), (x1, y1, h), (x0, y1, h)], col="wood")
    # four banks + corner triangles-as-quads
    B.quad(surf, [(x0, Y0, 0), (x1, Y0, 0), (x1, y0, h), (x0, y0, h)], col="wood")        # south
    B.quad(surf, [(x1, Y1, 0), (x0, Y1, 0), (x0, y1, h), (x1, y1, h)], col="wood")        # north
    B.quad(surf, [(X0, y1, 0), (X0, y0, 0), (x0, y0, h), (x0, y1, h)], col="wood")        # west
    B.quad(surf, [(X1, y0, 0), (X1, y1, 0), (x1, y1, h), (x1, y0, h)], col="wood")        # east
    for (a, b, c) in (((X0, y0, 0), (x0, Y0, 0), (x0, y0, h)), ((x1, Y0, 0), (X1, y0, 0), (x1, y0, h)),
                      ((X1, y1, 0), (x1, Y1, 0), (x1, y1, h)), ((x0, Y1, 0), (X0, y1, 0), (x0, y1, h))):
        B.quad(surf, [a, b, c], col="wood")
    # metal edging along the top edges (these are grindable ledges)
    edges = []
    for a, b in (((x0, y0, h), (x1, y0, h)), ((x1, y1, h), (x0, y1, h)), ((x0, y1, h), (x0, y0, h)), ((x1, y0, h), (x1, y1, h))):
        B.cylinder("coping", a, b, 0.018, 8)
        edges.append((a, b))
    return edges


def rail(B, pts, height, r=0.024, post_every=2.5, mat="rail", post_mat="steel"):
    """Round flat rail on posts. pts: floor-level polyline; returns the rail's top line."""
    top = [(p[0], p[1], p[2] + height) for p in pts]
    B.tube_path(mat, top, r, 12, col="metal_thin")
    for a, b in zip(pts[:-1], pts[1:]):
        L = (Vector(b) - Vector(a)).length
        n = max(1, int(L / post_every))
        for k in range(n + 1):
            p = Vector(a).lerp(Vector(b), k / n)
            B.cylinder(post_mat, (p.x, p.y, p.z), (p.x, p.y, p.z + height - r), 0.022, 8)
            B.box(post_mat, (p.x - 0.09, p.y - 0.09, p.z), (p.x + 0.09, p.y + 0.09, p.z + 0.012))
    return [(p[0], p[1], p[2] + r) for p in top]


def ledge(B, a, b, width, height, mat="concrete", edge_mat="coping"):
    """Concrete ledge along a->b (horizontal). Returns its two grindable top edges."""
    a, b = Vector(a), Vector(b)
    d = (b - a).normalized()
    n = Vector((-d.y, d.x, 0)) * (width / 2)
    c = [a - n, b - n, b + n, a + n]
    top = [Vector((p.x, p.y, height)) for p in c]
    B.quad(mat, top, col="concrete")
    for i in range(4):
        p, q = c[i], c[(i + 1) % 4]
        B.quad(mat, [p, q, Vector((q.x, q.y, height)), Vector((p.x, p.y, height))], col="concrete")
    e1 = (tuple(top[0]), tuple(top[1]))
    e2 = (tuple(top[2]), tuple(top[3]))
    for e in (e1, e2):
        B.cylinder(edge_mat, e[0], e[1], 0.012, 6)
    return [e1, (e2[1], e2[0])]


def ibeam(B, a, b, h=0.36, w=0.2, t=0.02, mat="steel_paint", col="metal"):
    """Steel I-beam between a and b (beam top at the given points)."""
    a, b = Vector(a), Vector(b)
    d = (b - a).normalized()
    side = Vector((-d.y, d.x, 0)).normalized() if abs(d.z) < 0.95 else Vector((1, 0, 0))
    up = side.cross(d).normalized()
    if up.z < 0:
        up = -up

    def plate(o0, o1, off_s, off_u, ws, hs):
        corners = []
        for (su, uu) in ((-ws, -hs), (ws, -hs), (ws, hs), (-ws, hs)):
            corners.append(side * (off_s + su) + up * (off_u + uu))
        ra = [o0 + c for c in corners]
        rb = [o1 + c for c in corners]
        B.strip(mat, [ra, rb], col=col, closed=True)
        for ring, fl in ((ra, True), (rb, False)):
            B.quad(mat, list(reversed(ring)) if fl else ring)

    plate(a, b, 0, -t / 2, w / 2, t / 2)              # top flange
    plate(a, b, 0, -h + t / 2, w / 2, t / 2)          # bottom flange
    plate(a, b, 0, -h / 2, t / 2, h / 2 - t)          # web


def crate(B, center, size, mat="crate", rot=0.0):
    cx, cy, cz = center
    sx, sy, sz = size
    M = Matrix.Translation(Vector((cx, cy, cz))) @ Matrix.Rotation(math.radians(rot), 4, 'Z')
    pts = lambda x, y, z: xf(M, (x, y, z))
    x0, x1, y0, y1 = -sx / 2, sx / 2, -sy / 2, sy / 2
    for quad in ([(x0, y0, sz), (x1, y0, sz), (x1, y1, sz), (x0, y1, sz)],
                 [(x0, y0, 0), (x1, y0, 0), (x1, y0, sz), (x0, y0, sz)],
                 [(x1, y1, 0), (x0, y1, 0), (x0, y1, sz), (x1, y1, sz)],
                 [(x0, y1, 0), (x0, y0, 0), (x0, y0, sz), (x0, y1, sz)],
                 [(x1, y0, 0), (x1, y1, 0), (x1, y1, sz), (x1, y0, sz)]):
        B.quad(mat, [pts(*p) for p in quad], col="concrete")
    # frame battens
    for (a, b) in (((x0, y0 - 0.01, 0.05), (x1, y0 - 0.01, 0.05)), ((x0, y0 - 0.01, sz - 0.05), (x1, y0 - 0.01, sz - 0.05)),
                   ((x0, y1 + 0.01, 0.05), (x1, y1 + 0.01, 0.05)), ((x0, y1 + 0.01, sz - 0.05), (x1, y1 + 0.01, sz - 0.05))):
        B.box("crate_frame", tuple(Vector(pts(*a)) - Vector((0.0, 0.0, 0.04))), tuple(Vector(pts(*b)) + Vector((0.0, 0.0, 0.04))))


def barrel(B, center, r=0.29, h=0.88, mat="barrel"):
    cx, cy, cz = center
    seg = 16
    rings = []
    for z, rr in ((0, r * 0.97), (0.04, r), (h * 0.33, r), (h * 0.35, r * 1.02), (h * 0.37, r), (h * 0.63, r),
                  (h * 0.65, r * 1.02), (h * 0.67, r), (h - 0.04, r), (h, r * 0.97)):
        rings.append([(cx + rr * math.cos(2 * math.pi * k / seg), cy + rr * math.sin(2 * math.pi * k / seg), cz + z) for k in range(seg)])
    B.strip(mat, rings, col="metal", closed=True)
    B.quad(mat, rings[-1])


# ==================================================================== level kit additions
# (everything below is used by data-defined levels; the Warehouse never calls it)

def extrude_profile(B, M, prof, width, surf, side, col_surface="wood", floor_z=0.0, side_col="wall",
                    back=None, sides=True):
    """Sweep a 2D ramp profile [(y, z), ...] (local: y into the ramp, z up, from the floor edge
    upward) across local x in [-width/2, width/2]. The riding surface faces -y. Side panels
    fill the profile down to floor_z; back=(mat) closes the back at the last y."""
    w = width / 2
    rows = [[xf(M, (x, y, z)) for (y, z) in prof] for x in (-w, w)]
    B.strip(surf, [rows[0], rows[1]], col=col_surface, flip=True)
    if sides:
        for x, fl in ((-w, False), (w, True)):
            pts = [xf(M, (x, y, z)) for (y, z) in prof]
            for i in range(len(pts) - 1):
                if abs(pts[i][2] - floor_z) < 1e-5 and abs(pts[i + 1][2] - floor_z) < 1e-5:
                    continue
                B.quad(side, [pts[i], pts[i + 1], _floor_of(pts[i + 1], floor_z), _floor_of(pts[i], floor_z)],
                       col=side_col, flip=fl)
    if back:
        yb, zb = prof[-1]
        B.quad(back, [xf(M, (w, yb, floor_z)), xf(M, (-w, yb, floor_z)), xf(M, (-w, yb, zb)), xf(M, (w, yb, zb))],
               col=side_col)
    return rows


def bank_profile(height, angle_deg, fillet=2.5, round_top=0.8, deck=0.0, segs=10):
    """Profile of a flat bank: a concave fillet off the floor, a straight slope at angle_deg,
    a convex rounded lip into an optional flat deck. Returns [(y, z)] from the floor edge."""
    th = math.radians(angle_deg)
    fy, fz = fillet * math.sin(th), fillet * (1 - math.cos(th))
    ty_rel, tz_rel = round_top * math.sin(th), round_top * (1 - math.cos(th))
    # the straight part joins (fy, fz) to (yE - ty_rel, height - tz_rel) along the slope
    run = (height - tz_rel - fz) / math.tan(th)
    yE = fy + run + ty_rel
    prof = [(fillet * math.sin(th * i / segs), fillet * (1 - math.cos(th * i / segs))) for i in range(segs + 1)]
    for i in range(segs + 1):
        b = th * (1 - i / segs)
        prof.append((yE - round_top * math.sin(b), height - round_top * (1 - math.cos(b))))
    if deck > 0:
        prof.append((yE + deck, height))
    return prof


def bank(B, origin, facing, width, height, angle_deg=30.0, fillet=2.5, round_top=0.8, deck=0.0,
         surf="plywood", side="rampside", col_surface="wood", back="rampside", floor_z=None):
    """A bank ramp (THPS 'bank'): rises in the facing direction from its floor edge at origin.
    Returns (profile, top edge line (world))."""
    M = frame(origin, facing)
    prof = bank_profile(height, angle_deg, fillet, round_top, deck)
    fz = origin[2] if floor_z is None else floor_z
    extrude_profile(B, M, [(y, z) for (y, z) in prof], width, surf, side, col_surface, fz,
                    back=back if deck > 0 or back else None)
    yT = prof[-1][0]
    return prof, [xf(M, (-width / 2, yT, height)), xf(M, (width / 2, yT, height))]


def halfpipe(B, center, axis_deg, width, radius, height, deck, flat, surf="plywood", **kw):
    """Two quarter pipes facing each other across a flat bottom. axis_deg: direction across the
    halfpipe (the riding direction) in world XY. Returns the two coping lines."""
    cx, cy, cz = center
    d = Vector((math.cos(math.radians(axis_deg)), math.sin(math.radians(axis_deg)), 0.0))
    a = Vector((cx, cy, cz)) + d * (flat / 2)
    b = Vector((cx, cy, cz)) - d * (flat / 2)
    ca = quarter_pipe(B, tuple(a), axis_deg - 90.0, width, radius, height, deck, surf=surf, **kw)
    cb = quarter_pipe(B, tuple(b), axis_deg + 90.0, width, radius, height, deck, surf=surf, **kw)
    s = Vector((-d.y, d.x, 0)) * (width / 2)
    B.quad(surf, [tuple(b - s + Vector((0, 0, 0.005))), tuple(a - s + Vector((0, 0, 0.005))),
                  tuple(a + s + Vector((0, 0, 0.005))), tuple(b + s + Vector((0, 0, 0.005)))],
           col=kw.get("col_surface", "wood"))
    return ca, cb


def spine(B, center, axis_deg, width, radius, height, surf="plywood", **kw):
    """Two quarter pipes back to back sharing one coping (a spine)."""
    cx, cy, cz = center
    th = math.radians(axis_deg)
    d = Vector((math.cos(th), math.sin(th), 0.0))
    ext = radius * math.sin(math.acos(1 - min(height, radius) / radius))
    a = Vector((cx, cy, cz)) - d * ext
    b = Vector((cx, cy, cz)) + d * ext
    ca = quarter_pipe(B, tuple(a), axis_deg - 90.0, width, radius, height, 0.0, surf=surf, back_wall=False, **kw)
    cb = quarter_pipe(B, tuple(b), axis_deg + 90.0, width, radius, height, 0.0, surf=surf, back_wall=False, **kw)
    return ca, cb


def stairs(B, origin, facing, width, n, rise, tread, mat="concrete", col="concrete", riser_col="wall",
           side_mat=None, nosing_mat=None, back=True):
    """n steps rising in the facing direction from origin (the bottom step's front edge
    centre). Returns (nosing lines [(a, b)] bottom to top, top z, total run)."""
    M = frame(origin, facing)
    w = width / 2
    sm = side_mat or mat
    fz = origin[2]
    nosings = []
    for k in range(1, n + 1):
        y0, y1 = (k - 1) * tread, k * tread
        z0, z1 = (k - 1) * rise, k * rise
        B.quad(mat, [xf(M, (-w, y0, z1)), xf(M, (w, y0, z1)), xf(M, (w, y1, z1)), xf(M, (-w, y1, z1))], col=col)
        B.quad(mat, [xf(M, (-w, y0, z0)), xf(M, (w, y0, z0)), xf(M, (w, y0, z1)), xf(M, (-w, y0, z1))], col=riser_col)
        for x, fl in ((-w, True), (w, False)):
            B.quad(sm, [xf(M, (x, y0, 0)), xf(M, (x, y1, 0)), xf(M, (x, y1, z1)), xf(M, (x, y0, z1))],
                   col="wall", flip=fl)
        a, b = xf(M, (-w, y0, z1)), xf(M, (w, y0, z1))
        nosings.append((a, b))
        if nosing_mat:
            B.cylinder(nosing_mat, a, b, 0.012, 6)
    if back:
        yb, zb = n * tread, n * rise
        B.quad(sm, [xf(M, (w, yb, 0)), xf(M, (-w, yb, 0)), xf(M, (-w, yb, zb)), xf(M, (w, yb, zb))], col="wall")
    return nosings, fz + n * rise, n * tread


def stair_rail(B, origin, facing, offset_x, n, rise, tread, height=0.85, flat_top=0.6, flat_bottom=0.6,
               r=0.024, mat="rail", post_mat="steel"):
    """A handrail down a flight built by stairs(): along the pitch line through the nosings,
    flat over the top step and flat again past the bottom. Returns its top line (world),
    bottom first."""
    M = frame(origin, facing)
    base = [(-tread - flat_bottom, 0.0), (-tread, 0.0), ((n - 1) * tread, n * rise),
            ((n - 1) * tread + flat_top, n * rise)]
    top = [xf(M, (offset_x, y, z + height)) for (y, z) in base]
    B.tube_path(mat, top, r, 12, col="metal_thin")

    def pitch(y):
        if y <= -tread:
            return 0.0
        if y >= (n - 1) * tread:
            return n * rise
        return rise + y * rise / tread
    # posts: at both ends and on every other nosing, standing on the step top behind it
    spots = [(-tread - flat_bottom + 0.05, 0.0)] + [(k * tread + 0.06, (k + 1) * rise) for k in range(0, n, 2)]
    spots.append(((n - 1) * tread + flat_top - 0.05, n * rise))
    for (y, zb) in spots:
        a = xf(M, (offset_x, y, zb))
        b = xf(M, (offset_x, y, pitch(y) + height - r))
        B.cylinder(post_mat, a, b, 0.022, 8)
    return [(p[0], p[1], p[2] + r) for p in top]


def floor_minus(B, x0, y0, x1, y1, holes, mat, col="concrete", z=0.0, cell=(8.0, 6.0)):
    """Floor rectangle with axis-aligned rectangular holes [(hx0, hy0, hx1, hy1)], built as
    grid cells of at most `cell` metres (lightmap islands stay reasonable)."""
    xs = set([x0, x1] + [v for h in holes for v in (h[0], h[2])])
    ys = set([y0, y1] + [v for h in holes for v in (h[1], h[3])])
    xs |= set(float(v) for v in np.arange(x0, x1, cell[0]))
    ys |= set(float(v) for v in np.arange(y0, y1, cell[1]))
    xs = sorted(v for v in xs if x0 <= v <= x1)
    ys = sorted(v for v in ys if y0 <= v <= y1)
    for xa, xb in zip(xs[:-1], xs[1:]):
        for ya, yb in zip(ys[:-1], ys[1:]):
            cx, cy = (xa + xb) / 2, (ya + yb) / 2
            if any(h[0] <= cx <= h[2] and h[1] <= cy <= h[3] for h in holes):
                continue
            if xb - xa < 1e-4 or yb - ya < 1e-4:
                continue
            B.quad(mat, [(xa, ya, z), (xb, ya, z), (xb, yb, z), (xa, yb, z)], col=col)


def wall(B, a, b, bands, inward_left=True, openings=(), col="wall", z0=0.0):
    """A straight wall from a to b (2D points) in height bands [(za, zb, mat)], with openings
    [(s0, s1, zlo, zhi)] (s: metres along the wall from a). The face points to the left of
    a->b when inward_left (so walk the hall anticlockwise). Returns the wall length."""
    A, Bv = Vector((a[0], a[1], 0)), Vector((b[0], b[1], 0))
    L = (Bv - A).length
    d = (Bv - A) / L
    cuts = sorted(set([0.0, L] + [v for o in openings for v in (o[0], o[1])]))
    for sa, sb in zip(cuts[:-1], cuts[1:]):
        mid = (sa + sb) / 2
        ops = [o for o in openings if o[0] <= mid <= o[1]]
        for (za, zb, mat) in bands:
            segs = [(za, zb)]
            for o in ops:
                nxt = []
                for (p, q) in segs:
                    if o[3] <= p or o[2] >= q:
                        nxt.append((p, q))
                        continue
                    if o[2] > p:
                        nxt.append((p, o[2]))
                    if o[3] < q:
                        nxt.append((o[3], q))
                segs = nxt
            for (p, q) in segs:
                if q - p < 1e-3:
                    continue
                P0, P1 = A + d * sa, A + d * sb
                pts = [(P0.x, P0.y, z0 + p), (P1.x, P1.y, z0 + p), (P1.x, P1.y, z0 + q), (P0.x, P0.y, z0 + q)]
                B.quad(mat, list(reversed(pts)) if inward_left else pts, col=col)
    return L


def window_frame(B, a, b, s0, s1, zlo, zhi, depth=0.12, bar=0.06, mullions=2, transoms=1, mat="steel_paint",
                 inward_left=True):
    """Steel frame + glazing bars round an opening made by wall(); returns the glass quad corners."""
    A, Bv = Vector((a[0], a[1], 0)), Vector((b[0], b[1], 0))
    d = (Bv - A).normalized()
    n = Vector((-d.y, d.x, 0)) * (1 if inward_left else -1)      # into the room
    P = lambda s, z, o=0.0: tuple(A + d * s + n * o + Vector((0, 0, z)))

    def bar_box(sa, sb, za, zb):
        pts = [Vector(P(sa, za, 0)), Vector(P(sb, za, 0)), Vector(P(sb, zb, 0)), Vector(P(sa, zb, 0))]
        lo = [min(p[i] for p in pts) for i in range(3)]
        hi = [max(p[i] for p in pts) for i in range(3)]
        lo = [min(lo[i], lo[i] + n[i] * depth) for i in range(3)]
        hi = [max(hi[i], hi[i] + n[i] * depth) for i in range(3)]
        B.box(mat, tuple(lo), tuple(hi))
    bar_box(s0 - bar, s1 + bar, zlo - bar, zlo)
    bar_box(s0 - bar, s1 + bar, zhi, zhi + bar)
    bar_box(s0 - bar, s0, zlo, zhi)
    bar_box(s1, s1 + bar, zlo, zhi)
    for k in range(1, mullions + 1):
        s = s0 + (s1 - s0) * k / (mullions + 1)
        bar_box(s - bar / 3, s + bar / 3, zlo, zhi)
    for k in range(1, transoms + 1):
        z = zlo + (zhi - zlo) * k / (transoms + 1)
        bar_box(s0, s1, z - bar / 3, z + bar / 3)
    return [P(s0, zhi, 0.02), P(s1, zhi, 0.02), P(s1, zlo, 0.02), P(s0, zlo, 0.02)]


def vault(B, x0, x1, y0, y1, spring, rise, segs=12, mat="roof", rib_mat="steel_paint", rib_every=4.0,
          end_mat="plaster", lantern=None, glass_mat="skylight", lantern_mat="steel_paint", lantern_h=0.9, col="wall"):
    """Segmental barrel vault spanning x0..x1, running along y, from the wall tops at `spring`
    to the crown at spring + rise; steel arch ribs; the end walls filled up to the curve.
    lantern=(half_width_segments, ly0, ly1): the crown segments become a glazed lantern.
    The roof has collision (`col`): nothing rides up there, but the chase camera keeps out.
    Returns [(x, z)] of the arc."""
    s = (x1 - x0) / 2
    xc = (x0 + x1) / 2
    R = (s * s + rise * rise) / (2 * rise)
    zc = spring + rise - R
    amax = math.asin(s / R)
    arc = []
    for i in range(segs + 1):
        a = -amax + 2 * amax * i / segs
        arc.append((xc + R * math.sin(a), zc + R * math.cos(a)))
    arc[0] = (x0, spring)
    arc[-1] = (x1, spring)
    mid = segs // 2
    lw = lantern[0] if lantern else 0
    for i in range(segs):
        (xa, za), (xb, zb) = arc[i], arc[i + 1]
        in_lantern = lantern and mid - lw <= i < mid + lw
        spans = [(y0, y1)] if not in_lantern else [(y0, lantern[1]), (lantern[2], y1)]
        for (ya, yb) in spans:
            for yy in np.arange(ya, yb - 1e-6, 6.0):
                yyb = min(yb, yy + 6.0)
                B.quad(mat, [(xa, yyb, za), (xb, yyb, zb), (xb, yy, zb), (xa, yy, za)], col=col)
    # end walls up to the curve (tympana)
    for (y, flip) in ((y0, False), (y1, True)):
        for i in range(segs):
            (xa, za), (xb, zb) = arc[i], arc[i + 1]
            pts = [(xa, y, spring), (xb, y, spring), (xb, y, zb), (xa, y, za)]
            B.quad(end_mat, list(reversed(pts)) if not flip else pts, col=col)
    # arch ribs
    for yy in np.arange(y0 + rib_every, y1 - 0.5, rib_every):
        for i in range(segs):
            (xa, za), (xb, zb) = arc[i], arc[i + 1]
            ibeam(B, (xa, yy, za - 0.02), (xb, yy, zb - 0.02), h=0.32, w=0.16, mat=rib_mat, col=None)
    if lantern:
        (xa, za), (xb, zb) = arc[mid - lw], arc[mid + lw]
        ly0, ly1 = lantern[1], lantern[2]
        top = max(za, zb) + lantern_h
        # glazed upstands (west + east), end glazing and a glazed top
        B.quad(glass_mat, [(xa, ly0, za), (xa, ly1, za), (xa, ly1, top), (xa, ly0, top)], col=col)
        B.quad(glass_mat, [(xb, ly1, zb), (xb, ly0, zb), (xb, ly0, top), (xb, ly1, top)], col=col)
        # the arc between the two upstand feet (under the lantern) is open; its ends are closed
        for (y, fl) in ((ly0, False), (ly1, True)):
            for i in range(mid - lw, mid + lw):
                (pa, qa), (pb, qb) = arc[i], arc[i + 1]
                pts = [(pa, y, qa), (pb, y, qb), (pb, y, top), (pa, y, top)]
                B.quad(lantern_mat, pts if fl else list(reversed(pts)), col=col)
        B.quad(glass_mat, [(xa, ly0, top), (xb, ly0, top), (xb, ly1, top), (xa, ly1, top)][::-1], col=col)
        for yy in np.arange(ly0, ly1 + 1e-6, 2.0):
            B.box(lantern_mat, (xa, yy - 0.04, top - 0.08), (xb, yy + 0.04, top))
        for x in (xa, xb):
            B.box(lantern_mat, (x - 0.05, ly0, top - 0.1), (x + 0.05, ly1, top))
    return arc


def pipe_run(B, pts, r=0.08, mat="steel", bracket_every=3.0, wall_side=None, col=None):
    """A pipe along a polyline (grindable when listed as a rail); optional brackets to a wall
    (wall_side: a 3D offset vector from the pipe centre to the wall). Returns the top line."""
    for a, b in zip(pts[:-1], pts[1:]):
        B.cylinder(mat, a, b, r, 14, col=col)
        if wall_side is not None:
            L = (Vector(b) - Vector(a)).length
            k = max(1, int(L / bracket_every))
            for i in range(k + 1):
                c = Vector(a).lerp(Vector(b), i / k)
                w = c + Vector(wall_side)
                lo = [min(c[j], w[j]) - (0.04 if j != 2 else 0.03) for j in range(3)]
                hi = [max(c[j], w[j]) + (0.04 if j != 2 else 0.03) for j in range(3)]
                lo[2] = c.z - r - 0.03
                hi[2] = c.z - r
                B.box(mat, tuple(lo), tuple(hi))
    return [(p[0], p[1], p[2] + r) for p in pts]


def bench(B, a, b, height=0.45, depth=0.42, mat="crate", leg_mat="steel", edge_mat="coping"):
    """A wooden bench a->b (floor points): a slatted top on steel legs; returns its two
    grindable top edges."""
    A, Bv = Vector(a), Vector(b)
    d = (Bv - A).normalized()
    n = Vector((-d.y, d.x, 0)) * (depth / 2)
    L = (Bv - A).length
    for k in range(4):
        o0 = -depth / 2 + depth * k / 4 + 0.01
        o1 = -depth / 2 + depth * (k + 1) / 4 - 0.01
        q = [A + n.normalized() * o0, Bv + n.normalized() * o0, Bv + n.normalized() * o1, A + n.normalized() * o1]
        top = [tuple(p + Vector((0, 0, height))) for p in q]
        low = [tuple(p + Vector((0, 0, height - 0.04))) for p in q]
        B.quad(mat, top, col="wood")
        for i in range(4):
            B.quad(mat, [low[i], low[(i + 1) % 4], top[(i + 1) % 4], top[i]], col="wood")
    for t in (0.08, 0.92):
        c = A.lerp(Bv, t)
        for s in (-1, 1):
            p = c + n * s * 0.85
            B.box(leg_mat, (p.x - 0.03, p.y - 0.03, 0.0), (p.x + 0.03, p.y + 0.03, height - 0.04), col="metal")
    e1 = (tuple(A - n + Vector((0, 0, height))), tuple(Bv - n + Vector((0, 0, height))))
    e2 = (tuple(Bv + n + Vector((0, 0, height))), tuple(A + n + Vector((0, 0, height))))
    for e in (e1, e2):
        B.cylinder(edge_mat, e[0], e[1], 0.01, 6)
    return [e1, e2]


# -------------------------------------------------------------------- bowl (a drained pool)

def smooth_knots(knots, y):
    """Piecewise smoothstep through [(y, value), ...] (sorted by y)."""
    if y <= knots[0][0]:
        return knots[0][1]
    for (ya, va), (yb, vb) in zip(knots[:-1], knots[1:]):
        if y <= yb:
            t = (y - ya) / max(1e-9, yb - ya)
            t = t * t * (3 - 2 * t)
            return va + (vb - va) * t
    return knots[-1][1]


def rounded_rect_chain(x0, y0, x1, y1, rc, ds=0.5, arc_segs=18):
    """East half of a rounded rectangle, from the middle of the south side anticlockwise to the
    middle of the north side: [(point2d, inward normal2d, corner centre or None)]."""
    xc = (x0 + x1) / 2
    out = []

    def line(p, q, n):
        L = (Vector(q) - Vector(p)).length
        k = max(1, int(math.ceil(L / ds)))
        for i in range(k):
            t = i / k
            out.append(((p[0] + (q[0] - p[0]) * t, p[1] + (q[1] - p[1]) * t), n, None))

    def arc(c, a0, a1):
        for i in range(arc_segs):
            a = a0 + (a1 - a0) * i / arc_segs
            pt = (c[0] + rc * math.cos(a), c[1] + rc * math.sin(a))
            out.append((pt, (-math.cos(a), -math.sin(a)), c))
    line((xc, y0), (x1 - rc, y0), (0.0, 1.0))
    arc((x1 - rc, y0 + rc), -math.pi / 2, 0.0)
    line((x1, y0 + rc), (x1, y1 - rc), (-1.0, 0.0))
    arc((x1 - rc, y1 - rc), 0.0, math.pi / 2)
    line((x1 - rc, y1), (xc, y1), (0.0, -1.0))
    out.append(((xc, y1), (0.0, -1.0), None))
    return out


def bowl(B, rect, corner, radius, depth_knots, z0=0.0, wall_mat="pool_tile", floor_mat="pool_floor",
         band_mat="pool_band", coping_mat="pool_coping", ring_mat="coping_stone", deck_mat="deck",
         col="pool", ring_w=0.35, margin=1.2, k_arc=14, k_vert=5, floor_cols=12, coping_r=0.055):
    """A pool-style bowl sunk into the floor: rounded-rectangle coping line `rect` (x0, y0, x1,
    y1) with corner radius `corner`, circular transitions of `radius` from the flat floor up to
    the lip (a vertical section above them where the pool is deeper than the radius), depth
    varying along y through depth_knots [(y, depth)]. radius may also be knots [(y, r)] (a
    tighter transition in a shallow end keeps its lip vertical). Also builds the coping stones (a ring
    ring_w wide), a deck frame out to `margin` from the lip (so the rest of the floor can be
    plain rectangles round rect +/- margin) and a waterline tile band. Everything shares one
    closed outline, so the pieces meet without cracks.

    Returns dict(outline=[lip points], chains, floor_z(y), outer=(x0-m, y0-m, x1+m, y1+m))."""
    x0, y0, x1, y1 = rect
    xc = (x0 + x1) / 2
    east = rounded_rect_chain(x0, y0, x1, y1, corner)
    west = [((2 * xc - p[0], p[1]), (-n[0], n[1]), (2 * xc - c[0], c[1]) if c else None) for (p, n, c) in east]
    ring = east + list(reversed(west))[1:-1]           # closed, anticlockwise from south-middle
    r_knots = [tuple(k) for k in radius] if isinstance(radius, (list, tuple)) else [(0.0, float(radius))]
    Rof = lambda y: smooth_knots(r_knots, y)

    def prof(p, n):
        R = Rof(p[1])
        h = smooth_knots(depth_knots, p[1])
        ah = min(R, h)
        amax = math.acos(1 - ah / R)
        e = R * math.sin(amax)
        v = h - ah
        pts = []
        N = Vector((n[0], n[1], 0))
        L = Vector((p[0], p[1], z0))
        for i in range(k_arc + 1):
            a = amax * i / k_arc
            u = e - R * math.sin(a)
            z = z0 - h + R * (1 - math.cos(a))
            pts.append(tuple(L + N * u + Vector((0, 0, z - z0))))
        for i in range(1, k_vert + 1):
            z = z0 - v + v * i / k_vert
            pts.append((p[0], p[1], z))
        return pts, h, e, R
    rows = []
    info = []
    for (p, n, c) in ring:
        pts, h, e, R = prof(p, n)
        rows.append(pts)
        info.append((p, n, h, e, R))
    # the walls: quads between consecutive profiles (closed loop), facing into the pool
    for i in range(len(rows)):
        a, b = rows[i], rows[(i + 1) % len(rows)]
        for j in range(len(a) - 1):
            B.quad(wall_mat, [a[j], a[j + 1], b[j + 1], b[j]], col=col)
    # the floor: zip the floor edges of the east and west chains (mirror points share y)
    ne = len(east)
    fe = [rows[i][0] for i in range(ne)]
    fw = [rows[0][0]] + [rows[len(rows) - k][0] for k in range(1, ne - 1)] + [rows[ne - 1][0]]
    for k in range(ne - 1):
        ra = [Vector(fw[k]).lerp(Vector(fe[k]), m / floor_cols) for m in range(floor_cols + 1)]
        rb = [Vector(fw[k + 1]).lerp(Vector(fe[k + 1]), m / floor_cols) for m in range(floor_cols + 1)]
        for m in range(floor_cols):
            B.quad(floor_mat, [tuple(ra[m]), tuple(ra[m + 1]), tuple(rb[m + 1]), tuple(rb[m])], col=col)
    # waterline band: a strip laid 4 mm in front of the tiles over the top 0.3 m of the wall
    def wall_at(p, n, h, e, R, t):
        # point + surface normal t metres below the lip
        N = Vector((n[0], n[1], 0))
        v = h - min(R, h)
        if t <= v:
            return Vector((p[0], p[1], z0 - t)), N
        cz = (R - h + t) / R
        a = math.acos(max(-1.0, min(1.0, cz)))
        u = e - R * math.sin(a)
        return Vector((p[0], p[1], z0 - t)) + N * u, (N * math.sin(a) + Vector((0, 0, math.cos(a)))).normalized()
    band_rows = []
    for (p, n, h, e, R) in info:
        row = []
        for t in (0.03, 0.12, 0.21, 0.3):
            q, sn = wall_at(p, n, h, e, R, min(t, h - 0.02))
            row.append(tuple(q + sn * 0.004))
        band_rows.append(row)
    for i in range(len(band_rows)):
        a, b = band_rows[i], band_rows[(i + 1) % len(band_rows)]
        for j in range(len(a) - 1):
            B.quad(band_mat, [a[j], a[j + 1], b[j + 1], b[j]], flip=True)
    # coping stones + deck frame, and the coping's rounded nose (a tube along the lip)
    lip = [Vector((p[0], p[1], z0)) for (p, n, c) in ring]
    offs = [Vector((p[0], p[1], z0)) - Vector((n[0], n[1], 0)) * ring_w for (p, n, c) in ring]
    outer = []
    for (p, n, c) in ring:
        if c is None:
            outer.append(Vector((p[0], p[1], z0)) - Vector((n[0], n[1], 0)) * margin)
        else:
            dx, dy = -n[0], -n[1]
            t = (corner + margin) / max(abs(dx), abs(dy))
            outer.append(Vector((c[0] + dx * t, c[1] + dy * t, z0)))
    for i in range(len(ring)):
        j = (i + 1) % len(ring)
        B.quad(ring_mat, [tuple(lip[i]), tuple(lip[j]), tuple(offs[j]), tuple(offs[i])], col="concrete", flip=True)
        B.quad(deck_mat, [tuple(offs[i]), tuple(offs[j]), tuple(outer[j]), tuple(outer[i])], col="concrete", flip=True)
    # rounded coping nose just inside the lip, in short pieces
    nose = [tuple(q + Vector((n[0], n[1], 0)) * coping_r * 0.6 + Vector((0, 0, -coping_r * 0.55)))
            for q, (p, n, c) in zip(lip, ring)]
    for i in range(len(nose)):
        B.cylinder(coping_mat, nose[i], nose[(i + 1) % len(nose)], coping_r, 10, caps=False)
    return dict(ring=ring, lip=[tuple(q) for q in lip], info=info, R=Rof,
                outer=(x0 - margin, y0 - margin, x1 + margin, y1 + margin),
                depth=lambda y: smooth_knots(depth_knots, y), wall_at=wall_at)


def floor_strip(B, mat, pts2d, width, zf, lift=0.008, step=0.5):
    """A painted line (decal strip) along a 2D polyline on a floor whose height is zf(x, y)."""
    for (a, b) in zip(pts2d[:-1], pts2d[1:]):
        A, Bv = Vector((a[0], a[1], 0)), Vector((b[0], b[1], 0))
        L = (Bv - A).length
        d = (Bv - A) / L
        n = Vector((-d.y, d.x, 0)) * (width / 2)
        k = max(1, int(math.ceil(L / step)))
        for i in range(k):
            p, q = A + d * (L * i / k), A + d * (L * (i + 1) / k)
            pts = [p - n, q - n, q + n, p + n]
            B.quad(mat, [(v.x, v.y, zf(v.x, v.y) + lift) for v in pts])


def bunting(B, a, b, sag=0.25, n=14, flag=0.28, cord_mat="steel", mats=("flag_a", "flag_b")):
    """Backstroke flags: a cord from a to b (sagging) with triangular pennants."""
    A, Bv = Vector(a), Vector(b)
    pts = []
    for i in range(n + 1):
        t = i / n
        pts.append(A.lerp(Bv, t) - Vector((0, 0, sag * 4 * t * (1 - t))))
    for p, q in zip(pts[:-1], pts[1:]):
        B.cylinder(cord_mat, tuple(p), tuple(q), 0.006, 4, caps=False)
    d = (Bv - A).normalized()
    for i in range(n):
        c = pts[i].lerp(pts[i + 1], 0.5)
        l, r = c - d * flag * 0.45, c + d * flag * 0.45
        tip = c - Vector((0, 0, flag))
        m = mats[i % len(mats)]
        B.quad(m, [tuple(l), tuple(r), tuple(tip)])
        B.quad(m, [tuple(r), tuple(l), tuple(tip)])
