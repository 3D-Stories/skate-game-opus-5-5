"""The skateboard: deck, trucks, wheels and hardware at real size.

Deck 80 x 20.3 cm, 36 cm wheelbase, 7-ply maple (1.2 cm) with kicked nose/tail and 4 mm
concave. Griptape top (imagegen griptape photo), tiger graphic on the bottom (imagegen,
original artwork), maple ply edges and 8 bolt heads procedural. Aluminium trucks with
bushings and kingpins, 53 mm urethane wheels with bearings; each wheel is its own object
with its origin on the axle so the game can spin it.

The board's origin is the deck centre at mid-thickness, 8.3 cm above the ground; +X is
the nose, +Z up. The skater rig's 'board' bone uses the same frame.
"""
import math

import bpy
import bmesh
import numpy as np
from mathutils import Matrix, Vector

from lib import common as C

L = 0.80
W = 0.203
THICK = 0.012
WHEELBASE = 0.36
DECK_Z = 0.083          # deck centre height above ground (mid thickness)
WHEEL_R = 0.0265
WHEEL_W = 0.032
AXLE_Z = WHEEL_R
KICK_START = 0.255
KICK_H = 0.052


def deck_z(x, y):
    ax = abs(x)
    k = 0.0
    if ax > KICK_START:
        t = (ax - KICK_START) / (L / 2 - KICK_START)
        k = KICK_H * (t ** 1.7)
    concave = 0.004 * (y / (W / 2)) ** 2 * (1 - min(1, max(0, (ax - KICK_START) / 0.08)) * 0.5)
    return k + concave


def half_width(x):
    ax = abs(x)
    straight = L / 2 - W / 2
    if ax <= straight:
        return W / 2
    t = min(1.0, (ax - straight) / (W / 2))
    return W / 2 * math.sqrt(max(0.0, 1 - t * t))


def build_deck(coll):
    nx, ny = 96, 14
    bm = bmesh.new()
    uv = bm.loops.layers.uv.new("UVMap")
    top, bot = [], []
    xs = [(-L / 2 + 0.0005) + (L - 0.001) * (0.5 - 0.5 * math.cos(math.pi * i / nx)) for i in range(nx + 1)]
    for x in xs:
        hw = max(half_width(x), 0.004)
        rt, rb = [], []
        for j in range(ny + 1):
            y = -hw + 2 * hw * j / ny
            z = deck_z(x, y)
            rt.append(bm.verts.new((x, y, THICK / 2 + z)))
            rb.append(bm.verts.new((x, y, -THICK / 2 + z)))
        top.append(rt); bot.append(rb)
    faces_top, faces_bot, faces_side = [], [], []
    for i in range(nx):
        for j in range(ny):
            faces_top.append(bm.faces.new((top[i][j], top[i + 1][j], top[i + 1][j + 1], top[i][j + 1])))
            faces_bot.append(bm.faces.new((bot[i][j + 1], bot[i + 1][j + 1], bot[i + 1][j], bot[i][j])))
    # side walls around the outline
    ring_t = [top[i][0] for i in range(nx + 1)] + [top[nx][j] for j in range(1, ny + 1)] + \
             [top[i][ny] for i in range(nx - 1, -1, -1)] + [top[0][j] for j in range(ny - 1, 0, -1)]
    ring_b = [bot[i][0] for i in range(nx + 1)] + [bot[nx][j] for j in range(1, ny + 1)] + \
             [bot[i][ny] for i in range(nx - 1, -1, -1)] + [bot[0][j] for j in range(ny - 1, 0, -1)]
    n = len(ring_t)
    for k in range(n):
        a, b = k, (k + 1) % n
        try:
            faces_side.append(bm.faces.new((ring_t[a], ring_b[a], ring_b[b], ring_t[b])))
        except ValueError:
            pass
    bmesh.ops.remove_doubles(bm, verts=bm.verts, dist=0.0002)
    # materials + uvs
    for f in faces_top:
        if not f.is_valid:
            continue
        f.material_index = 0
        for l in f.loops:
            l[uv].uv = (l.vert.co.x / 0.2 + 2, l.vert.co.y / 0.2 + 0.5)
    for f in faces_bot:
        if not f.is_valid:
            continue
        f.material_index = 1
        for l in f.loops:
            # the graphic image is portrait: map deck length to image height
            l[uv].uv = (0.5 - l.vert.co.y / (W / 2) * 0.16, 0.5 + l.vert.co.x / (L / 2) * 0.48)
    per = 0.0
    for f in faces_side:
        if not f.is_valid:
            continue
        f.material_index = 2
        for l in f.loops:
            ang = math.atan2(l.vert.co.y, l.vert.co.x)
            l[uv].uv = (ang * 2.0, (l.vert.co.z - deck_z(l.vert.co.x, l.vert.co.y) + THICK / 2) / THICK)
    ob = C.bm_to_object(bm, "Deck", coll)
    for p in ob.data.polygons:
        p.use_smooth = p.material_index != 2 or True
    mod = ob.modifiers.new("ws", 'WEIGHTED_NORMAL')
    mod.keep_sharp = True
    return ob


def ply_texture():
    h, w = 64, 512
    y = np.linspace(0, 1, h)[:, None].repeat(w, 1)
    plies = 7
    idx = np.floor(y * plies).astype(int)
    base = np.array([[0.78, 0.62, 0.42], [0.72, 0.55, 0.36]])
    col = base[idx % 2]
    # one dyed ply (common on skate decks)
    col[idx == 3] = np.array([0.55, 0.12, 0.10])
    glue = np.abs((y * plies) % 1 - 0.5) > 0.46
    col[glue] *= 0.7
    grain = C.resize(C.value_noise(128, 16, 3, 3), w)[:h]
    col = col * (0.85 + 0.25 * grain[..., None])
    dirt = np.linspace(0, 1, w)[None, :] * 0
    return C.save_png(np.clip(col, 0, 1), "deck_ply")


def griptape_textures():
    g = C.make_seamless(C.src_array("griptape", 1024))
    lum = C.luminance(g)
    col = g * 0.55
    # bolt heads: 8 dark discs near the truck positions (in top UV space: u = x/0.2+2, v = y/0.2+0.5)
    return (C.save_png(col, "grip_albedo"),
            C.save_png(C.height_to_normal(C.highpass(lum, 3) * 6.0, 1.0), "grip_normal", 'Non-Color'))


def graphic_texture():
    g = C.src_array("deck_graphic", 1024)
    # the source shows the deck outline on white: tint the white background to a natural
    # maple so any part outside the printed area reads as bare wood
    white = (g.min(-1) > 0.9)[..., None]
    wood = np.array([0.8, 0.65, 0.45])
    g = np.where(white, wood, g)
    return C.save_png(g, "deck_graphic_tex")


def build_bolts(coll):
    objs = []
    for sx in (1, -1):
        for dx in (-0.027, 0.027):
            for dy in (-0.021, 0.021):
                x = sx * (WHEELBASE / 2) + dx
                bm = bmesh.new()
                bmesh.ops.create_cone(bm, cap_ends=True, segments=12, radius1=0.0048, radius2=0.004, depth=0.0015)
                bmesh.ops.translate(bm, vec=Vector((x, dy, THICK / 2 + deck_z(x, dy) + 0.0006)), verts=bm.verts)
                objs.append(C.bm_to_object(bm, "Bolt", coll, smooth=True))
    return C.join(objs, "Bolts")


def lathe(profile, segments, name, coll):
    """Revolve (r, y) profile points around the Y axis."""
    bm = bmesh.new()
    rings = []
    for (r, y) in profile:
        ring = []
        for k in range(segments):
            a = 2 * math.pi * k / segments
            ring.append(bm.verts.new((r * math.cos(a), y, r * math.sin(a))))
        rings.append(ring)
    for i in range(len(rings) - 1):
        for k in range(segments):
            a, b = k, (k + 1) % segments
            bm.faces.new((rings[i][a], rings[i][b], rings[i + 1][b], rings[i + 1][a]))
    for ring, flip in ((rings[0], True), (rings[-1], False)):
        if ring[0].co.xz.length > 1e-5:
            f = bm.faces.new(ring if not flip else list(reversed(ring)))
    return C.bm_to_object(bm, name, coll, smooth=True)


def build_truck(sx, coll):
    x = sx * WHEELBASE / 2
    parts = []
    deck_bottom = DECK_Z - THICK / 2 + deck_z(x, 0)
    # baseplate
    bm = bmesh.new()
    bmesh.ops.create_cube(bm, size=1)
    bmesh.ops.scale(bm, vec=(0.07, 0.056, 0.008), verts=bm.verts)
    bmesh.ops.translate(bm, vec=(x, 0, deck_bottom - 0.004), verts=bm.verts)
    bmesh.ops.bevel(bm, geom=bm.edges[:], offset=0.002, segments=2, affect='EDGES')
    parts.append(C.bm_to_object(bm, "Baseplate", coll))
    # kingpin housing block
    bm = bmesh.new()
    bmesh.ops.create_cone(bm, cap_ends=True, segments=16, radius1=0.014, radius2=0.011, depth=0.02)
    rot = Matrix.Rotation(math.radians(-sx * 35), 4, 'Y')
    bmesh.ops.transform(bm, matrix=rot, verts=bm.verts)
    bmesh.ops.translate(bm, vec=(x - sx * 0.012, 0, deck_bottom - 0.016), verts=bm.verts)
    parts.append(C.bm_to_object(bm, "KingpinBlock", coll, smooth=True))
    # hanger: tapered bar along Y with a triangular web
    bm = bmesh.new()
    bmesh.ops.create_cone(bm, cap_ends=True, segments=16, radius1=0.0085, radius2=0.0085, depth=0.13)
    bmesh.ops.rotate(bm, cent=(0, 0, 0), matrix=Matrix.Rotation(math.radians(90), 3, 'X'), verts=bm.verts)
    bmesh.ops.translate(bm, vec=(x, 0, AXLE_Z + 0.004), verts=bm.verts)
    parts.append(C.bm_to_object(bm, "HangerBar", coll, smooth=True))
    bm = bmesh.new()
    vs = [bm.verts.new(v) for v in ((x - 0.004, -0.045, AXLE_Z + 0.002), (x - 0.004, 0.045, AXLE_Z + 0.002),
                                   (x - sx * 0.01, 0.012, deck_bottom - 0.03), (x - sx * 0.01, -0.012, deck_bottom - 0.03))]
    vs2 = [bm.verts.new((v.co.x + 0.008, v.co.y, v.co.z)) for v in vs]
    bm.faces.new(vs); bm.faces.new(list(reversed(vs2)))
    for i in range(4):
        bm.faces.new((vs[i], vs[(i + 1) % 4], vs2[(i + 1) % 4], vs2[i]))
    parts.append(C.bm_to_object(bm, "HangerWeb", coll))
    # bushings
    for dz in (-0.022, -0.035):
        bm = bmesh.new()
        bmesh.ops.create_cone(bm, cap_ends=True, segments=14, radius1=0.0095, radius2=0.0085, depth=0.009)
        bmesh.ops.transform(bm, matrix=rot, verts=bm.verts)
        bmesh.ops.translate(bm, vec=(x - sx * 0.016, 0, deck_bottom + dz + 0.012), verts=bm.verts)
        parts.append(C.bm_to_object(bm, "Bushing", coll, smooth=True))
    # axle
    bm = bmesh.new()
    bmesh.ops.create_cone(bm, cap_ends=True, segments=10, radius1=0.004, radius2=0.004, depth=0.21)
    bmesh.ops.rotate(bm, cent=(0, 0, 0), matrix=Matrix.Rotation(math.radians(90), 3, 'X'), verts=bm.verts)
    bmesh.ops.translate(bm, vec=(x, 0, AXLE_Z), verts=bm.verts)
    parts.append(C.bm_to_object(bm, "Axle", coll, smooth=True))
    return parts


def build_wheel(name, x, y, coll):
    prof = [(0.0, -WHEEL_W / 2 + 0.002), (0.012, -WHEEL_W / 2), (WHEEL_R - 0.006, -WHEEL_W / 2), (WHEEL_R - 0.002, -WHEEL_W / 2 + 0.003),
            (WHEEL_R, -WHEEL_W / 2 + 0.008), (WHEEL_R, WHEEL_W / 2 - 0.008), (WHEEL_R - 0.002, WHEEL_W / 2 - 0.003),
            (WHEEL_R - 0.006, WHEEL_W / 2), (0.012, WHEEL_W / 2), (0.0, WHEEL_W / 2 - 0.002)]
    ob = lathe(prof, 32, name, coll)
    ob.location = (x, y, AXLE_Z)
    # bearing shield (dark disc) on the outer face
    s = 1 if y > 0 else -1
    bm = bmesh.new()
    bmesh.ops.create_cone(bm, cap_ends=True, segments=20, radius1=0.011, radius2=0.011, depth=0.002)
    bmesh.ops.rotate(bm, cent=(0, 0, 0), matrix=Matrix.Rotation(math.radians(90), 3, 'X'), verts=bm.verts)
    bmesh.ops.translate(bm, vec=(0, s * (WHEEL_W / 2 + 0.0005), 0), verts=bm.verts)
    br = C.bm_to_object(bm, name + "_bearing", coll, smooth=True)
    br.parent = ob
    return ob, br


def build(export=True):
    C.reset_scene()
    coll = C.collection("Board")
    root = build_parts(coll)
    C.show([o for o in coll.objects if o.type == 'MESH'], 'MATERIAL', azimuth=40, elevation=25, margin=1.0)
    if export:
        C.export_glb(C.os.path.join(C.ASSETS, "board.glb"))
        C.save_blend("board")
    return root


def build_parts(coll):
    """Build the board objects into the current scene; returns the 'Skateboard' root."""
    deck = build_deck(coll)
    grip_a, grip_n = griptape_textures()
    grip = C.pbr_material("Griptape", base=grip_a, normal=grip_n, roughness=0.95, normal_strength=1.0)
    graphic = C.pbr_material("DeckGraphic", base=graphic_texture(), roughness=0.35)
    ply = C.pbr_material("DeckPly", base=ply_texture(), roughness=0.55)
    deck.data.materials.append(grip)
    deck.data.materials.append(graphic)
    deck.data.materials.append(ply)
    bolts = build_bolts(coll)
    C.assign(bolts, C.pbr_material("Hardware", base_color=(0.62, 0.62, 0.6, 1), roughness=0.35, metallic=1.0))
    alu = C.pbr_material("TruckAlu", base_color=(0.78, 0.78, 0.8, 1), roughness=0.32, metallic=1.0)
    bush = C.pbr_material("Bushing", base_color=(0.85, 0.35, 0.05, 1), roughness=0.6)
    steel = C.pbr_material("Steel", base_color=(0.5, 0.5, 0.52, 1), roughness=0.3, metallic=1.0)
    trucks = []
    for sx in (1, -1):
        ps = build_truck(sx, coll)
        for p in ps:
            if p.name.startswith("Bushing"):
                C.assign(p, bush)
            elif p.name.startswith("Axle") or p.name.startswith("Kingpin"):
                C.assign(p, steel)
            else:
                C.assign(p, alu)
        trucks.append(C.join(ps, "Truck_" + ("F" if sx > 0 else "B")))
    urethane = C.pbr_material("Wheel", base_color=(0.92, 0.9, 0.82, 1), roughness=0.55)
    bearing = C.pbr_material("Bearing", base_color=(0.05, 0.05, 0.06, 1), roughness=0.4, metallic=0.5)
    wheels = []
    for sx, tag in ((1, "F"), (-1, "B")):
        for sy, side in ((1, "L"), (-1, "R")):
            w, b = build_wheel(f"Wheel_{tag}{side}", sx * WHEELBASE / 2, sy * (0.105 - WHEEL_W / 2 + 0.012), coll)
            C.assign(w, urethane)
            C.assign(b, bearing)
            wheels.append(w)
    # whole board: origin at the deck centre (mid thickness) -> shift everything down
    root = bpy.data.objects.new("Skateboard", None)
    C.link(root, coll)
    # deck and bolts are modelled around the deck centre; trucks and wheels in the ground
    # frame, so shift those down by the deck height to share the deck-centred origin
    for o in trucks:
        o.location.z -= DECK_Z
        o.parent = root
    for w in wheels:
        w.location.z -= DECK_Z
        w.parent = root
    for o in (deck, bolts):
        o.parent = root
    return root
