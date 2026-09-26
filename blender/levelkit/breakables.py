"""Level kit, breakables: things the skater smashes. Each is its own object (not merged into
the park meshes) so the game can hide, tip over or throw it; each writes one entry into
the level data's "breakables" list (Godot axes):

    {"id": "grille", "group": "grille", "kind": "impact", "nodes": [...], "center": [...],
     "size": [...], "fx": "metal", "points": 250}          kind impact: a collision box; rolling
                                                           or flying into it at speed breaks it
    {"id": "sign_2", "group": "signs", "kind": "touch", "nodes": [...], "center": [...],
     "radius": 0.9, "pivot": [...], "fall": [...], "fx": "sign", "points": 150}
                                                           kind touch: no collision; passing
                                                           through it at speed knocks it over

The groups are what goals count ("Knock down the 5 signs" = group "signs", count 5).
"""
import math

import bmesh
import bpy
from mathutils import Matrix, Vector

from lib import common as C


def _box_bm(bm, lo, hi):
    vs = bmesh.ops.create_cube(bm, size=1)["verts"]
    c = [(lo[i] + hi[i]) / 2 for i in range(3)]
    s = [hi[i] - lo[i] for i in range(3)]
    bmesh.ops.scale(bm, vec=s, verts=vs)
    bmesh.ops.translate(bm, vec=c, verts=vs)


def _cyl_bm(bm, a, b, r, seg=10):
    a, b = Vector(a), Vector(b)
    d = b - a
    res = bmesh.ops.create_cone(bm, cap_ends=True, segments=seg, radius1=r, radius2=r, depth=d.length)
    rot = d.normalized().to_track_quat('Z', 'Y').to_matrix().to_4x4()
    bmesh.ops.transform(bm, matrix=Matrix.Translation((a + b) / 2) @ rot, verts=res["verts"])


def grille(L, spec, mat):
    """A steel bar grille closing a doorway in a wall plane x = const (or y = const):
    spec: name, group, plane ("x" | "y"), at (the plane coordinate), span [a, b], z [lo, hi],
    bar spacing, points."""
    name = spec.get("name", "grille")
    plane = spec.get("plane", "x")
    at = spec["at"]
    a, b = spec["span"]
    zlo, zhi = spec["z"]
    sp = spec.get("spacing", 0.16)
    bm = bmesh.new()

    def P(u, z, o=0.0):
        return (at + o, u, z) if plane == "x" else (u, at + o, z)

    def box(u0, u1, z0, z1, t=0.05):
        p, q = P(u0, z0, -t), P(u1, z1, t)
        _box_bm(bm, [min(p[i], q[i]) for i in range(3)], [max(p[i], q[i]) for i in range(3)])
    # frame and cross bars (flat steel), round vertical bars
    box(a, b, zlo, zlo + 0.08)
    box(a, b, zhi - 0.08, zhi)
    box(a, a + 0.08, zlo, zhi)
    box(b - 0.08, b, zlo, zhi)
    for z in (zlo + (zhi - zlo) * 0.36, zlo + (zhi - zlo) * 0.7):
        box(a, b, z - 0.03, z + 0.03, 0.035)
    n = int((b - a - 0.16) / sp)
    for k in range(1, n + 1):
        u = a + 0.08 + (b - a - 0.16) * k / (n + 1)
        _cyl_bm(bm, P(u, zlo + 0.04, 0.0), P(u, zhi - 0.04, 0.0), 0.014, 8)
    ob = C.bm_to_object(bm, f"Break_{name}", L.coll)
    C.box_uv(ob, 0.8)
    C.assign(ob, mat)
    mid = P((a + b) / 2, (zlo + zhi) / 2)
    size_b = (0.3, b - a, zhi - zlo) if plane == "x" else (b - a, 0.3, zhi - zlo)
    L.breakables.append(ob)
    L.data.setdefault("breakables", []).append(dict(
        id=name, group=spec.get("group", name), kind="impact", nodes=[ob.name], center=L.g(mid),
        size=[round(size_b[0], 4), round(size_b[2], 4), round(size_b[1], 4)], fx=spec.get("fx", "metal"),
        points=spec.get("points", 250), label=spec.get("label", "")))
    return ob


def sign(L, spec, post_mat, plate_mat, face_mat, cells, atlas_px):
    """A sign on a post (e.g. NO DIVING): the post + plate object and the painted face (a quad
    textured from the level's signage atlas). Knocked over (kind touch) in the game."""
    i = len([b for b in L.data.get("breakables", []) if b.get("group") == spec.get("group", "signs")])
    name = spec.get("name", f"Sign_{i}")
    x, y = spec["at"][:2]
    z0 = spec["at"][2] if len(spec["at"]) > 2 else 0.0
    face_deg = spec.get("facing", 0.0)            # direction the face looks (0 = +y, north)
    H = spec.get("height", 1.7)
    pw, ph = spec.get("plate", [0.62, 0.46])
    th = math.radians(face_deg)
    fwd = Vector((-math.sin(th), math.cos(th), 0.0))
    right = Vector((math.cos(th), math.sin(th), 0.0))
    base = Vector((x, y, z0))
    bm = bmesh.new()
    _cyl_bm(bm, base, base + Vector((0, 0, H - ph * 0.5)), 0.03, 10)
    _cyl_bm(bm, base - Vector((0, 0, 0.0)), base + Vector((0, 0, 0.04)), 0.14, 14)     # weighted foot
    # plate: a thin box centred on the post top, face toward fwd
    pc = base + Vector((0, 0, H - ph * 0.5)) + fwd * 0.035
    corners = []
    for sx in (-1, 1):
        for sz in (-1, 1):
            for sd in (-1, 1):
                corners.append(pc + right * sx * pw / 2 + Vector((0, 0, sz * ph / 2)) + fwd * sd * 0.008)
    lo = [min(c[k] for c in corners) for k in range(3)]
    hi = [max(c[k] for c in corners) for k in range(3)]
    if abs(math.sin(th)) < 1e-6 or abs(math.cos(th)) < 1e-6:
        _box_bm(bm, lo, hi)
    else:
        vs = bmesh.ops.create_cube(bm, size=1)["verts"]
        bmesh.ops.scale(bm, vec=(pw, 0.016, ph), verts=vs)
        bmesh.ops.transform(bm, matrix=Matrix.Translation(pc) @ Matrix.Rotation(th, 4, 'Z'), verts=vs)
    ob = C.bm_to_object(bm, name, L.coll)
    C.box_uv(ob, 0.6)
    C.assign(ob, post_mat)
    # painted face just in front of the plate
    key = spec.get("cell", "nodiving")
    cx, cy, cw, chh = cells[key]
    fc = pc + fwd * 0.0095
    hw, hh = pw / 2 - 0.01, ph / 2 - 0.01
    pts = [fc - right * hw - Vector((0, 0, hh)), fc + right * hw - Vector((0, 0, hh)),
           fc + right * hw + Vector((0, 0, hh)), fc - right * hw + Vector((0, 0, hh))]
    u0, u1 = cx / atlas_px, (cx + cw) / atlas_px
    v1, v0 = 1 - cy / atlas_px, 1 - (cy + chh) / atlas_px
    me = bpy.data.meshes.new(name + "_face")
    me.from_pydata([tuple(p) for p in pts], [], [(0, 1, 2, 3)])
    uvl = me.uv_layers.new(name="UVMap")
    for li, loop in enumerate(me.loops):
        uvl.data[li].uv = [(u0, v0), (u1, v0), (u1, v1), (u0, v1)][loop.vertex_index]
    fo = bpy.data.objects.new(name + "_face", me)
    C.link(fo, L.coll)
    C.assign(fo, face_mat)
    L.breakables += [ob, fo]
    fall = Vector(spec.get("fall", tuple(-fwd)))
    L.data.setdefault("breakables", []).append(dict(
        id=name, group=spec.get("group", "signs"), kind="touch", nodes=[ob.name, fo.name],
        center=L.g(base + Vector((0, 0, 0.9))), radius=spec.get("radius", 1.0), pivot=L.g(base),
        fall=[round(fall.x, 4), round(fall.z, 4), round(-fall.y, 4)], fx=spec.get("fx", "sign"),
        points=spec.get("points", 150), label=spec.get("label", "")))
    return ob, fo


def boards(L, spec, board_mat, batten_mat):
    """Boarded-up plywood panels closing a doorway (the Warehouse's kind of breakable wall),
    in a wall plane x = const: spec: name, at (x), span [y0, y1], z [0, h], panels."""
    name = spec.get("name", "boards")
    x = spec["at"]
    y0, y1 = spec["span"]
    zlo, zhi = spec["z"]
    n = spec.get("panels", max(1, int(round(y1 - y0))))
    objs = []
    for i in range(n):
        ya = y0 + (y1 - y0) * i / n
        yb = y0 + (y1 - y0) * (i + 1) / n
        bm = bmesh.new()
        _box_bm(bm, (x - 0.03, ya + 0.01, zlo), (x + 0.03, yb - 0.01, zhi - 0.02))
        ob = C.bm_to_object(bm, f"Break_{name}_{i}", L.coll)
        C.box_uv(ob, 1.5)
        C.assign(ob, board_mat)
        objs.append(ob)
    for z in (zlo + (zhi - zlo) * 0.25, zlo + (zhi - zlo) * 0.75):
        bm = bmesh.new()
        _box_bm(bm, (x + 0.03, y0, z - 0.09), (x + 0.08, y1, z + 0.09))
        ob = C.bm_to_object(bm, f"Break_{name}_batten{int(z * 10)}", L.coll)
        C.box_uv(ob, 1.5)
        C.assign(ob, batten_mat)
        objs.append(ob)
    L.breakables += objs
    L.data.setdefault("breakables", []).append(dict(
        id=name, group=spec.get("group", name), kind="impact", nodes=[o.name for o in objs],
        center=L.g((x, (y0 + y1) / 2, (zlo + zhi) / 2)), size=[0.3, round(zhi - zlo, 4), round(y1 - y0, 4)],
        fx=spec.get("fx", "wood"), points=spec.get("points", 250), label=spec.get("label", "")))
    return objs
