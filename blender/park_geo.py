"""Geometry builders for the Warehouse: ramps with real transitions, boxes, rails, beams.

Everything is built as bmesh geometry at real-world scale (metres, Z up) and tagged with a
material name; park.py merges the pieces per material. Transitions are true circular
arcs with 24+ segments so the skater's ground snapping follows them smoothly.
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
