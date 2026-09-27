"""Level kit, props: small set pieces built into the merged park meshes (they are lit by the
lightmap like everything else). Each takes the geometry Builder and plain numbers."""
import math

from mathutils import Matrix, Vector

from levelkit import geo as G


def sphere(B, mat, c, r, seg=14, rings=8, col=None):
    c = Vector(c)
    rows = []
    for i in range(1, rings):
        t = math.pi * i / rings
        rows.append([tuple(c + Vector((math.sin(t) * math.cos(2 * math.pi * k / seg) * r,
                                       math.sin(t) * math.sin(2 * math.pi * k / seg) * r, math.cos(t) * r)))
                     for k in range(seg)])
    B.strip(mat, rows, col=col, closed=True, flip=True)
    top, bot = tuple(c + Vector((0, 0, r))), tuple(c - Vector((0, 0, r)))
    for k in range(seg):
        k2 = (k + 1) % seg
        B.quad(mat, [rows[0][k], rows[0][k2], top], col=col)
        B.quad(mat, [rows[-1][k2], rows[-1][k], bot], col=col)


def pendant(B, at, drop_to, globe=0.22, mat="lamp", cord_mat="steel", shade_mat="steel_paint"):
    """A globe pendant lamp hanging from drop_to down to at (x, y, z = globe centre)."""
    x, y, z = at
    B.cylinder(cord_mat, (x, y, z + globe * 0.9), (x, y, drop_to), 0.008, 4)
    sphere(B, mat, (x, y, z), globe, 12, 7)
    # a little steel gallery ring on top of the globe
    B.cylinder(shade_mat, (x, y, z + globe * 0.78), (x, y, z + globe * 1.02), globe * 0.45, 10)


def lifeguard_chair(B, at, facing=0.0, h=1.9, mat="steel_paint", seat_mat="crate"):
    """A tall pool-side lifeguard chair (legs are solid: the skater hits them)."""
    M = G.frame(at, facing)
    for sx in (-0.4, 0.4):
        for sy in (-0.45, 0.35):
            a = G.xf(M, (sx, sy, 0.0))
            b = G.xf(M, (sx * 0.8, sy * 0.7, h))
            B.cylinder(mat, a, b, 0.03, 8, col="metal")
    for z in (0.5, 1.0, 1.45):
        f = 1 - 0.2 * z / h
        B.cylinder(mat, G.xf(M, (-0.4 * f, -0.45 * (1 - 0.3 * z / h), z)), G.xf(M, (0.4 * f, -0.45 * (1 - 0.3 * z / h), z)), 0.02, 6)
    c = G.xf(M, (0, 0, h))
    lo = Vector(G.xf(M, (-0.38, -0.36, h))); hi = Vector(G.xf(M, (0.38, 0.28, h + 0.06)))
    B.box(seat_mat, tuple(Vector(map(min, lo, hi))), tuple(Vector(map(max, lo, hi))))
    lo = Vector(G.xf(M, (-0.36, 0.26, h + 0.06))); hi = Vector(G.xf(M, (0.36, 0.3, h + 0.7)))
    B.box(seat_mat, tuple(Vector(map(min, lo, hi))), tuple(Vector(map(max, lo, hi))))
    return c


def ladder_arches(B, lip, inward, width=0.5, height=0.75, mat="chrome"):
    """A pool ladder's two grab-rail arches over the coping (deck side only: the rungs are long
    gone). lip: point on the coping line; inward: 2D unit vector into the pool."""
    L = Vector((lip[0], lip[1], lip[2]))
    n = Vector((inward[0], inward[1], 0)).normalized()
    s = Vector((-n.y, n.x, 0))
    for side in (-1, 1):
        o = L + s * side * width / 2
        pts = []
        for i in range(9):
            t = math.pi * i / 8
            pts.append(tuple(o - n * (0.55 * math.cos(t)) + n * 0.0 + Vector((0, 0, height * math.sin(t)))))
        B.tube_path(mat, pts, 0.022, 10)


def clock(B, at, normal, r=0.45, face_mat="lamp", rim_mat="steel_paint", hand_mat="steel"):
    """A round pool clock on a wall: rim, lit face, hands at ten to four."""
    c = Vector(at)
    n = Vector(normal).normalized()
    B.cylinder(rim_mat, tuple(c - n * 0.02), tuple(c + n * 0.08), r, 24)
    B.cylinder(face_mat, tuple(c + n * 0.08), tuple(c + n * 0.085), r * 0.9, 24)
    up = Vector((0, 0, 1))
    right = n.cross(up).normalized()
    for ang, ln, w in ((-60.0, 0.55, 0.018), (115.0, 0.8, 0.012)):
        d = (Matrix.Rotation(math.radians(ang), 3, n) @ up)
        B.cylinder(hand_mat, tuple(c + n * 0.09), tuple(c + n * 0.09 + d * r * ln), w, 4)
    return right


def boiler(B, a, b, r=1.1, mat="boiler", band_mat="steel", plinth_mat="concrete", door_mat="firebox"):
    """A horizontal fire-tube boiler: a riveted drum from a to b on two plinths, with a glowing
    firebox door at the a end. Its top is solid (the skater can land on it)."""
    A, Bv = Vector(a), Vector(b)
    B.cylinder(mat, tuple(A), tuple(Bv), r, 20, col="metal")
    d = (Bv - A).normalized()
    L = (Bv - A).length
    for t in (0.12, 0.5, 0.88):
        p = A + d * L * t
        B.cylinder(band_mat, tuple(p - d * 0.05), tuple(p + d * 0.05), r * 1.02, 20)
    for t in (0.2, 0.8):
        p = A + d * L * t
        side = Vector((-d.y, d.x, 0))
        lo = p - side * r * 0.8 - d * 0.3
        hi = p + side * r * 0.8 + d * 0.3
        B.box(plinth_mat, (min(lo.x, hi.x), min(lo.y, hi.y), 0.0), (max(lo.x, hi.x), max(lo.y, hi.y), A.z - r * 0.7), col="wall")
    B.cylinder(door_mat, tuple(A - d * 0.02), tuple(A - d * 0.04), r * 0.45, 16)
    return (A.x, A.y, A.z + r)
