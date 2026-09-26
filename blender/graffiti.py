"""Original graffiti and signage, drawn in code (no downloaded art or fonts).

The module-level CELLS / PIECES / PLACEMENTS / SIGN are the Warehouse's; other levels pass
their own (from their level definition) to build() - see levelkit/level.py.

Every piece is laid out from Blender text curves (Blender's built-in font) with per-letter
jitter, stacked outline layers, a 3D block shadow, disc "clouds" behind throw-ups, stars
and swooshes, rendered flat (emission shaders, Standard view transform) through an
orthographic camera in a scratch scene. numpy then "sprays" the result: overspray halo,
mist speckle, paint drips and chipped, weathered wear. All pieces share one 2048 atlas
(material park_graffiti), placed as decal quads on the walls, the deck, the halfpipe and
the boarded-up secret wall.
"""
import math
import os

import bpy
import bmesh
import numpy as np
from mathutils import Vector, Matrix

from lib import common as C

ATLAS = 2048
# key: (x, y, w, h) in atlas pixels, origin top-left
CELLS = {
    "shred": (0, 0, 1024, 512),
    "grind": (1024, 0, 1024, 512),
    "zap": (0, 512, 1024, 512),
    "pop": (1024, 512, 1024, 512),
    "keepout": (0, 1024, 1024, 256),
    "tag_razr": (1024, 1024, 512, 256),
    "tag_noiz": (1536, 1024, 512, 256),
    "ollie": (0, 1280, 1024, 512),
    "smiley": (1024, 1280, 512, 512),
    "tag_ko": (1536, 1280, 512, 256),
    "tag_brkn": (1536, 1536, 512, 256),
    "banner": (0, 1792, 2048, 256),
}


def srgb(c):
    c = np.asarray(c, np.float32)
    return tuple(np.where(c <= 0.04045, c / 12.92, ((c + 0.055) / 1.055) ** 2.4))


PIECES = {
    "shred": dict(style="piece", text="SHRED", fill=((1.0, 0.18, 0.52), (1.0, 0.78, 0.12)), inner=(1, 1, 1),
                  outline=(0.03, 0.03, 0.05), block=(0.1, 0.22, 0.62), seed=1),
    "grind": dict(style="piece", text="GRIND", fill=((0.15, 0.95, 0.95), (0.12, 0.3, 1.0)), inner=(1.0, 0.92, 0.2),
                  outline=(0.02, 0.02, 0.03), block=(0.62, 0.1, 0.55), seed=2),
    "ollie": dict(style="piece", text="OLLIE", fill=((1.0, 0.96, 0.25), (1.0, 0.42, 0.05)), inner=(1, 1, 1),
                  outline=(0.04, 0.04, 0.22), block=(0.85, 0.12, 0.1), seed=3),
    "zap": dict(style="throwup", text="ZAP", fill=((0.96, 0.97, 0.98), (0.58, 0.6, 0.66)), outline=(0.02, 0.02, 0.02),
                cloud=(0.95, 0.16, 0.2), seed=4),
    "pop": dict(style="throwup", text="POP!", fill=((0.96, 0.97, 0.98), (0.58, 0.6, 0.66)), outline=(0.02, 0.02, 0.02),
                cloud=(0.16, 0.45, 1.0), seed=5),
    "keepout": dict(style="stencil", text="KEEP OUT", color=(0.82, 0.07, 0.05), seed=6),
    "tag_razr": dict(style="tag", text="Razr", color=(0.02, 0.02, 0.02), seed=7),
    "tag_noiz": dict(style="tag", text="NOIZ", color=(0.85, 0.08, 0.1), seed=8),
    "tag_ko": dict(style="tag", text="K.O.", color=(0.15, 0.35, 0.95), seed=9),
    "tag_brkn": dict(style="tag", text="brkn", color=(0.95, 0.95, 0.95), seed=10),
    "smiley": dict(style="smiley", color=(1.0, 0.84, 0.08), seed=11),
    "banner": dict(style="banner", text="WAREHOUSE", fill=((1, 1, 1), (0.86, 0.88, 0.92)), outline=(0.02, 0.02, 0.03),
                   block=(0.9, 0.1, 0.12), seed=12),
}

# decals in Blender park coordinates: key, centre, wall normal (into the room), width, roll
PLACEMENTS = [
    ("shred", (0.0, 49.985, 7.4), (0, -1, 0), 13.0, 0.0),
    ("grind", (-19.985, 16.0, 2.35), (1, 0, 0), 6.4, 0.0),
    ("ollie", (-19.985, 30.6, 2.35), (1, 0, 0), 5.6, 0.0),
    ("zap", (8.015, -9.9, 2.4), (1, 0, 0), 5.2, 0.0),
    ("pop", (-8.015, -9.9, 2.4), (-1, 0, 0), 5.2, 0.0),
    ("tag_razr", (-19.985, -1.0, 1.35), (1, 0, 0), 2.8, 4.0),
    ("tag_noiz", (13.5, 49.985, 1.5), (0, -1, 0), 3.0, -3.0),
    ("smiley", (-13.0, 49.985, 2.0), (0, -1, 0), 2.2, 6.0),
    ("tag_ko", (-14.0, -15.985, 1.4), (0, 1, 0), 2.4, -2.0),
    ("tag_brkn", (-29.985, 40.5, 3.6), (1, 0, 0), 2.2, 3.0),
    ("banner", (19.985, 17.0, 8.6), (-1, 0, 0), 22.0, 0.0),
    ("tag_ko", (-6.45, 36.985, 1.7), (0, -1, 0), 1.3, 5.0),
    ("tag_razr", (6.45, 36.985, 1.5), (0, -1, 0), 1.3, -4.0),
]
# on the breakable boards: hidden with them when the wall is smashed
SIGN = ("keepout", (-20.008, 36.5, 1.6), (1, 0, 0), 4.0, -2.0)


# ------------------------------------------------------------------ drawing

class Canvas:
    """A scratch scene the pieces are laid out in (z = layer order toward the camera)."""

    def __init__(self):
        self.scn = bpy.data.scenes.new("GraffitiStudio")
        self.objs = []
        self.mats = {}
        self.ref = bpy.data.objects.new("GradRef", None)
        self.scn.collection.objects.link(self.ref)
        self.objs.append(self.ref)

    def link(self, ob):
        self.scn.collection.objects.link(ob)
        self.objs.append(ob)
        return ob

    def flat(self, color, grad=None):
        """Emission material; grad = (c_top, c_bottom, y_top, y_bottom) gradient in world y."""
        key = (tuple(np.round(color, 3)), None if grad is None else tuple(np.round(np.array(grad[:2]).ravel(), 3)) + tuple(grad[2:]))
        if key in self.mats:
            return self.mats[key]
        m = bpy.data.materials.new("gfx_%d" % len(self.mats))
        m.use_nodes = True
        nt = m.node_tree
        nt.nodes.clear()
        out = nt.nodes.new('ShaderNodeOutputMaterial')
        em = nt.nodes.new('ShaderNodeEmission')
        nt.links.new(em.outputs[0], out.inputs[0])
        if grad is None:
            em.inputs[0].default_value = (*srgb(color), 1)
        else:
            tc = nt.nodes.new('ShaderNodeTexCoord')
            tc.object = self.ref
            sx = nt.nodes.new('ShaderNodeSeparateXYZ')
            nt.links.new(tc.outputs['Object'], sx.inputs[0])
            mr = nt.nodes.new('ShaderNodeMapRange')
            mr.inputs['From Min'].default_value = grad[3]
            mr.inputs['From Max'].default_value = grad[2]
            nt.links.new(sx.outputs['Y'], mr.inputs['Value'])
            mix = nt.nodes.new('ShaderNodeMix')
            mix.data_type = 'RGBA'
            mix.inputs[6].default_value = (*srgb(grad[1]), 1)
            mix.inputs[7].default_value = (*srgb(grad[0]), 1)
            nt.links.new(mr.outputs['Result'], mix.inputs[0])
            # a thin bright "shine" band across the upper third of the fill
            mr2 = nt.nodes.new('ShaderNodeMapRange')
            h = grad[2] - grad[3]
            mr2.inputs['From Min'].default_value = grad[3] + h * 0.62
            mr2.inputs['From Max'].default_value = grad[3] + h * 0.66
            mr2.interpolation_type = 'SMOOTHSTEP'
            mr3 = nt.nodes.new('ShaderNodeMapRange')
            mr3.inputs['From Min'].default_value = grad[3] + h * 0.72
            mr3.inputs['From Max'].default_value = grad[3] + h * 0.68
            mr3.interpolation_type = 'SMOOTHSTEP'
            nt.links.new(sx.outputs['Y'], mr2.inputs['Value'])
            nt.links.new(sx.outputs['Y'], mr3.inputs['Value'])
            band = nt.nodes.new('ShaderNodeMath')
            band.operation = 'MINIMUM'
            nt.links.new(mr2.outputs['Result'], band.inputs[0])
            nt.links.new(mr3.outputs['Result'], band.inputs[1])
            sc = nt.nodes.new('ShaderNodeMath')
            sc.operation = 'MULTIPLY'
            sc.inputs[1].default_value = 0.55
            nt.links.new(band.outputs[0], sc.inputs[0])
            mix2 = nt.nodes.new('ShaderNodeMix')
            mix2.data_type = 'RGBA'
            nt.links.new(sc.outputs[0], mix2.inputs[0])
            nt.links.new(mix.outputs[2], mix2.inputs[6])
            mix2.inputs[7].default_value = (1, 1, 1, 1)
            nt.links.new(mix2.outputs[2], em.inputs[0])
        self.mats[key] = m
        return m

    def text(self, ch, size, shear=0.0, offset=0.0, color=(1, 1, 1), grad=None, loc=(0, 0, 0), rot=0.0, scale=1.0):
        cu = bpy.data.curves.new("gfx_txt", 'FONT')
        cu.body = ch
        cu.size = size
        cu.shear = shear
        cu.offset = offset
        cu.align_x = 'CENTER'
        cu.align_y = 'CENTER'
        cu.resolution_u = 6
        cu.fill_mode = 'BOTH'
        ob = bpy.data.objects.new("gfx_txt", cu)
        ob.location = loc
        ob.rotation_euler = (0, 0, rot)
        ob.scale = (scale, scale, 1)
        cu.materials.append(self.flat(color, grad))
        return self.link(ob)

    def disc(self, center, r, color, z):
        bm = bmesh.new()
        bmesh.ops.create_circle(bm, cap_ends=True, radius=r, segments=40)
        me = bpy.data.meshes.new("gfx_disc")
        bm.to_mesh(me)
        bm.free()
        ob = bpy.data.objects.new("gfx_disc", me)
        ob.location = (center[0], center[1], z)
        me.materials.append(self.flat(color))
        return self.link(ob)

    def poly(self, pts, color, z):
        me = bpy.data.meshes.new("gfx_poly")
        me.from_pydata([(p[0], p[1], 0) for p in pts], [], [list(range(len(pts)))])
        ob = bpy.data.objects.new("gfx_poly", me)
        ob.location.z = z
        me.materials.append(self.flat(color))
        return self.link(ob)

    def stroke(self, pts, width, color, z):
        """A painted line along a polyline (quads with round-ish caps)."""
        verts, faces = [], []
        P = [Vector((p[0], p[1], 0)) for p in pts]
        for i, p in enumerate(P):
            d = (P[min(i + 1, len(P) - 1)] - P[max(i - 1, 0)]).normalized()
            nrm = Vector((-d.y, d.x, 0))
            w = width * (0.35 + 0.65 * math.sin(math.pi * (0.08 + 0.84 * i / max(1, len(P) - 1))))
            verts += [tuple(p + nrm * w / 2), tuple(p - nrm * w / 2)]
        for i in range(len(P) - 1):
            faces.append((2 * i, 2 * i + 1, 2 * i + 3, 2 * i + 2))
        me = bpy.data.meshes.new("gfx_stroke")
        me.from_pydata(verts, [], faces)
        ob = bpy.data.objects.new("gfx_stroke", me)
        ob.location.z = z
        me.materials.append(self.flat(color))
        return self.link(ob)

    def star(self, c, r, z, color=(1, 1, 1)):
        pts = []
        for k in range(8):
            a = k * math.pi / 4
            rr = r if k % 2 == 0 else r * 0.18
            pts.append((c[0] + math.cos(a) * rr, c[1] + math.sin(a) * rr))
        return self.poly(pts, color, z)

    def bounds(self):
        self.scn.view_layers[0].update()
        lo = Vector((1e9, 1e9)); hi = Vector((-1e9, -1e9))
        for ob in self.objs:
            if ob.type not in ('MESH', 'FONT'):
                continue
            for c in ob.bound_box:
                w = ob.matrix_world @ Vector(c)
                lo.x, lo.y = min(lo.x, w.x), min(lo.y, w.y)
                hi.x, hi.y = max(hi.x, w.x), max(hi.y, w.y)
        return lo, hi

    def render(self, w, h, path, margin=1.08):
        lo, hi = self.bounds()
        cx, cy = (lo.x + hi.x) / 2, (lo.y + hi.y) / 2
        bw, bh = hi.x - lo.x, hi.y - lo.y
        cam_d = bpy.data.cameras.new("gfx_cam")
        cam_d.type = 'ORTHO'
        cam_d.ortho_scale = max(bw, bh * w / h) * margin
        cam = bpy.data.objects.new("gfx_cam", cam_d)
        cam.location = (cx, cy, 50)
        self.link(cam)
        scn = self.scn
        scn.camera = cam
        scn.render.engine = 'CYCLES'
        # CPU: flat emission shapes render in moments, and exactly the same every build (the
        # GPU's float accumulation order varies, which changed a few pixels run to run)
        scn.cycles.device = 'CPU'
        scn.cycles.seed = 0
        scn.cycles.use_animated_seed = False
        scn.render.threads_mode = 'FIXED'
        scn.render.threads = 1
        scn.cycles.samples = 16
        scn.cycles.use_denoising = False
        scn.cycles.max_bounces = 0
        scn.render.film_transparent = True
        scn.render.resolution_x, scn.render.resolution_y = w, h
        scn.render.resolution_percentage = 100
        scn.view_settings.view_transform = 'Standard'
        scn.view_settings.look = 'None'
        scn.render.image_settings.file_format = 'PNG'
        scn.render.image_settings.color_mode = 'RGBA'
        scn.render.filepath = path
        bpy.ops.render.render(write_still=True, scene=scn.name)
        img = bpy.data.images.load(path, check_existing=False)
        a = np.array(img.pixels[:], np.float32).reshape(h, w, 4)
        bpy.data.images.remove(img)
        return np.flipud(a).copy()

    def clear(self):
        for ob in self.objs:
            data = ob.data
            bpy.data.objects.remove(ob)
            if data is not None and data.users == 0:
                if isinstance(data, bpy.types.Mesh):
                    bpy.data.meshes.remove(data)
                elif isinstance(data, bpy.types.Curve):
                    bpy.data.curves.remove(data)
                elif isinstance(data, bpy.types.Camera):
                    bpy.data.cameras.remove(data)
        self.objs = []
        self.ref = bpy.data.objects.new("GradRef", None)
        self.scn.collection.objects.link(self.ref)
        self.objs.append(self.ref)

    def free(self):
        self.clear()
        for m in self.mats.values():
            bpy.data.materials.remove(m)
        bpy.data.scenes.remove(self.scn)


def _word_layout(cv, text, size, r, overlap=0.1, shear=0.18, rot_j=7.0, y_j=0.07, s_j=0.08):
    """Letter centres and transforms for a jittered, overlapping word."""
    widths = []
    for ch in text:
        ob = cv.text(ch, size, shear)
        cv.scn.view_layers[0].update()
        widths.append(max(ob.dimensions.x, size * 0.3))
        bpy.data.objects.remove(ob)
        cv.objs.pop()
    x = 0.0
    out = []
    for ch, wdt in zip(text, widths):
        s = 1.0 + r.uniform(-s_j, s_j)
        out.append(dict(ch=ch, x=x + wdt * s / 2, y=r.uniform(-y_j, y_j) * size,
                        rot=math.radians(r.uniform(-rot_j, rot_j)), s=s))
        x += wdt * s * (1 - overlap)
    mid = x / 2
    for L in out:
        L["x"] -= mid
    return out


def draw_piece(cv, P, banner=False):
    r = C.rng(P["seed"])
    size = 1.0
    lay = _word_layout(cv, P["text"], size, r, overlap=0.02 if banner else 0.1,
                       rot_j=3.0 if banner else 8.0, y_j=0.03 if banner else 0.08)
    ot, it = (0.1, 0.05)
    grad = (P["fill"][0], P["fill"][1], 0.45 * size, -0.45 * size)
    sh = Vector((0.1, -0.12)) * size
    n = len(lay)
    for i, L in enumerate(lay):
        loc = (L["x"], L["y"], 0)
        # 3D block shadow toward the lower right, with its own dark far edge
        steps = 10
        cv.text(L["ch"], size, 0.18, ot + 0.03, P["outline"], loc=(loc[0] + sh.x, loc[1] + sh.y, 0.001 * i),
                rot=L["rot"], scale=L["s"])
        for k in range(steps):
            f = (k + 1) / steps
            cv.text(L["ch"], size, 0.18, ot, P["block"], loc=(loc[0] + sh.x * f, loc[1] + sh.y * f, 0.2 + 0.001 * (i * steps + k)),
                    rot=L["rot"], scale=L["s"])
    for i, L in enumerate(lay):
        z = 1.0 + i * 0.1
        loc = (L["x"], L["y"])
        cv.text(L["ch"], size, 0.18, ot, P["outline"], loc=(loc[0], loc[1], z), rot=L["rot"], scale=L["s"])
        if not banner:
            cv.text(L["ch"], size, 0.18, it, P["inner"], loc=(loc[0], loc[1], z + 0.01), rot=L["rot"], scale=L["s"])
        cv.text(L["ch"], size, 0.18, 0.0, (1, 1, 1), grad=grad, loc=(loc[0], loc[1], z + 0.02), rot=L["rot"], scale=L["s"])
    if not banner:
        # shines and arrows
        for _ in range(3):
            L = lay[int(r.integers(0, n))]
            cv.star((L["x"] + r.uniform(-0.2, 0.25), L["y"] + r.uniform(0.25, 0.42)), r.uniform(0.12, 0.2), 5.0)
        tail = lay[-1]
        x0 = tail["x"] + 0.35
        pts = [(x0, 0.35), (x0 + 0.22, 0.52), (x0 + 0.36, 0.6)]
        cv.stroke(pts, 0.1, P["outline"], 4.0)
        cv.poly([(x0 + 0.3, 0.72), (x0 + 0.52, 0.64), (x0 + 0.3, 0.5)], P["outline"], 4.0)


def draw_throwup(cv, P):
    r = C.rng(P["seed"])
    size = 1.0
    lay = _word_layout(cv, P["text"], size, r, overlap=0.05, shear=0.0, rot_j=6.0, y_j=0.05)
    left, right = lay[0]["x"] - 0.35, lay[-1]["x"] + 0.35
    # cloud: discs along the top and bottom and filling the middle
    discs = []
    x = left
    while x <= right + 1e-3:
        discs.append(((x, 0.28 + r.uniform(-0.05, 0.05)), r.uniform(0.3, 0.42)))
        discs.append(((x + 0.18, -0.26 + r.uniform(-0.05, 0.05)), r.uniform(0.3, 0.4)))
        x += 0.36
    for (c, rad) in discs:
        cv.disc(c, rad + 0.07, P["outline"], 0.0)
    for (c, rad) in discs:
        cv.disc(c, rad, P["cloud"], 0.1)
    grad = (P["fill"][0], P["fill"][1], 0.45, -0.45)
    for i, L in enumerate(lay):
        z = 1.0 + i * 0.1
        cv.text(L["ch"], size * 1.05, 0.0, 0.11, P["outline"], loc=(L["x"], L["y"], z), rot=L["rot"], scale=L["s"])
        cv.text(L["ch"], size * 1.05, 0.0, 0.06, (1, 1, 1), grad=grad, loc=(L["x"], L["y"], z + 0.02), rot=L["rot"], scale=L["s"])
    for _ in range(2):
        cv.star((r.uniform(left, right), r.uniform(0.35, 0.5)), 0.16, 5.0)


def draw_tag(cv, P):
    r = C.rng(P["seed"])
    lay = _word_layout(cv, P["text"], 1.0, r, overlap=-0.02, shear=0.42, rot_j=9.0, y_j=0.1, s_j=0.15)
    for i, L in enumerate(lay):
        cv.text(L["ch"], 1.0, 0.42, 0.012, P["color"], loc=(L["x"], L["y"], 1.0 + i * 0.1), rot=L["rot"], scale=L["s"])
    # underline swoosh and a crown flourish
    left, right = lay[0]["x"] - 0.3, lay[-1]["x"] + 0.4
    pts = [(left + (right - left) * t, -0.5 - 0.12 * math.sin(math.pi * t) + 0.18 * t * t) for t in np.linspace(0, 1, 24)]
    cv.stroke(pts, 0.07, P["color"], 3.0)
    cx = lay[0]["x"]
    cv.stroke([(cx - 0.18, 0.55), (cx - 0.1, 0.78), (cx, 0.6), (cx + 0.1, 0.82), (cx + 0.2, 0.58)], 0.05, P["color"], 3.0)


def draw_stencil(cv, P):
    # one evenly spaced line of block capitals; spray() cuts the stencil bridges
    ob = cv.text(P["text"], 1.0, 0.0, 0.03, P["color"], loc=(0, 0, 1.0))
    ob.data.space_character = 1.12


def draw_sign(cv, P):
    """Painted signage (not graffiti): a panel with a border and one or more centred lines of
    capitals, e.g. a baths' name board or a NO DIVING plate. P: lines, color (text), panel,
    border, size (text height, panel units), aspect (panel width / height)."""
    lines = P["text"].split("\n")
    n = len(lines)
    size = P.get("size", 0.8)
    H = size * 1.35 * n + size * 0.7
    W = H * P.get("aspect", 3.0)
    b = P.get("border_w", 0.08) * H
    if P.get("panel") is not None:
        cv.poly([(-W / 2, -H / 2), (W / 2, -H / 2), (W / 2, H / 2), (-W / 2, H / 2)], P.get("border", P["color"]), 0.0)
        cv.poly([(-W / 2 + b, -H / 2 + b), (W / 2 - b, -H / 2 + b), (W / 2 - b, H / 2 - b), (-W / 2 + b, H / 2 - b)],
                P["panel"], 0.1)
    for i, line in enumerate(lines):
        y = (n - 1) * size * 0.675 - i * size * 1.35
        ob = cv.text(line, size * P.get("scale", [1.0] * n)[i] if isinstance(P.get("scale"), list) else size, 0.0,
                     P.get("bold", 0.02), P["color"], loc=(0, y, 1.0 + 0.01 * i))
        ob.data.space_character = P.get("spacing", 1.05)


def draw_smiley(cv, P):
    cv.disc((0, 0), 1.0, (0.02, 0.02, 0.02), 0.0)
    cv.disc((0, 0), 0.9, P["color"], 0.1)
    for sx in (-0.34, 0.34):
        for a in (1, -1):
            cv.stroke([(sx - 0.16, 0.34 - 0.16 * a), (sx + 0.16, 0.34 + 0.16 * a)], 0.1, (0.02, 0.02, 0.02), 1.0)
    pts = [(math.cos(t) * 0.55, math.sin(t) * 0.5 - 0.12) for t in np.linspace(math.pi * 1.15, math.pi * 1.85, 20)]
    cv.stroke(pts, 0.12, (0.02, 0.02, 0.02), 1.0)
    cv.stroke([(0.3, -0.55), (0.34, -0.72), (0.4, -0.62)], 0.07, (0.85, 0.1, 0.15), 1.1)   # tongue


# ------------------------------------------------------------------ spray post-process

def _blur(a, r):
    return C.blur(a, max(1, int(r)))


def spray(img, seed, drips=True, wear=0.3, stencil=False):
    h, w = img.shape[:2]
    rgb, a = img[..., :3].copy(), img[..., 3].copy()
    r = C.rng(seed)
    s = h / 512.0
    if stencil:
        # stencil bridges: horizontal gaps through the letters
        rows = np.arange(h)[:, None]
        cols = np.arange(w)[None, :]
        gap = (np.abs(rows - h * 0.5) < 3 * s) & (np.sin(cols / (w / 18.0)) > 0.2)
        a = np.where(gap, 0.0, a)
    # colour bleeding outward for the halo
    prem = rgb * a[..., None]
    ab = _blur(a, 5 * s)
    cb = np.stack([_blur(prem[..., k], 5 * s) for k in range(3)], -1) / np.maximum(ab[..., None], 1e-4)
    rgb = np.where(a[..., None] > 0.5, rgb, cb)
    # overspray halo + mist speckle
    halo = _blur(a, 3 * s) * 0.55
    mist = (r.random((h, w)) > 0.975).astype(np.float32) * _blur(a, 12 * s) * 0.8
    a = np.maximum(a, np.maximum(halo, mist))
    # drips from the lower edges
    if drips:
        solid = a > 0.6
        n = int(10 * w / 1024)
        for _ in range(n * 3):
            x = int(r.integers(0, w))
            col_idx = np.nonzero(solid[:, x])[0]
            if len(col_idx) == 0:
                continue
            y0 = int(col_idx.max())
            L = int(r.uniform(12, 70) * s)
            wd = max(1, int(r.uniform(1.5, 3.5) * s))
            c = rgb[max(0, y0 - 2), x]
            for yy in range(y0, min(h, y0 + L)):
                t = (yy - y0) / L
                ww = max(1, int(round(wd * (1 - 0.5 * t))))
                a[yy, max(0, x - ww):x + ww] = np.maximum(a[yy, max(0, x - ww):x + ww], 0.95 * (1 - t ** 3))
                rgb[yy, max(0, x - ww):x + ww] = c
            yb = min(h - 1, y0 + L)
            a[max(0, yb - wd):yb + wd, max(0, x - wd - 1):x + wd + 1] = 0.9
            rgb[max(0, yb - wd):yb + wd, max(0, x - wd - 1):x + wd + 1] = c
            n -= 1
            if n <= 0:
                break
    # weathering: large faded patches + fine chips, paint sinking into the wall texture
    lo = C.resize(C.value_noise(256, 6, seed + 100, 3)[..., None], max(w, h))[:h, :w, 0]
    fine = C.resize(C.value_noise(512, 60, seed + 200, 2)[..., None], max(w, h))[:h, :w, 0]
    a *= np.clip(1.0 - wear * np.clip(lo - 0.35, 0, 1) * 1.6, 0, 1)
    a *= np.where(fine > 0.82, 0.25, 1.0)
    a *= 0.9 + 0.1 * fine
    return np.concatenate([np.clip(rgb, 0, 1), np.clip(a, 0, 1)[..., None]], -1)


# ------------------------------------------------------------------ grime (numpy, no text)

GRIME_STYLES = ("stain", "ring", "streaks", "leaves")


def _smooth(e0, e1, x):
    t = np.clip((x - e0) / (e1 - e0), 0, 1)
    return t * t * (3 - 2 * t)


def draw_grime(w, h, P):
    """Dirt for abandoned places, straight into an RGBA array: "stain" (a soft irregular
    blotch), "ring" (a ring stain round a drain), "streaks" (rust / dirt runs down from the
    top edge), "leaves" (scattered dead leaves, clustered)."""
    st, seed = P["style"], P["seed"]
    r = C.rng(seed)
    n = max(w, h)
    yy, xx = np.mgrid[0:h, 0:w].astype(np.float32)
    u, v = (xx + 0.5) / w * 2 - 1, (yy + 0.5) / h * 2 - 1
    col = np.array(P.get("color", (0.2, 0.16, 0.12)), np.float32)
    nz = C.resize(C.value_noise(256, 5, seed, 4)[..., None], n)[:h, :w, 0]
    fine = C.resize(C.value_noise(256, 24, seed + 7, 2)[..., None], n)[:h, :w, 0]
    rgb = np.broadcast_to(col, (h, w, 3)).copy()
    if st == "stain":
        d = np.sqrt(u * u + v * v) + (nz - 0.5) * 0.9
        a = (1 - _smooth(0.35, 0.95, d)) * (0.55 + 0.45 * fine)
        a *= P.get("alpha", 0.6)
        rgb *= (0.7 + 0.6 * nz)[..., None]
    elif st == "ring":
        d = np.sqrt(u * u + v * v) + (nz - 0.5) * 0.25
        a = np.exp(-((d - 0.55) / 0.16) ** 2) * 0.8 + (1 - _smooth(0.0, 0.45, d)) * 0.35
        a *= (0.6 + 0.4 * fine) * P.get("alpha", 0.65)
        rgb *= (0.75 + 0.5 * fine)[..., None]
    elif st == "streaks":
        a = np.zeros((h, w), np.float32)
        for _ in range(int(P.get("count", 14))):
            x0 = r.uniform(0.05, 0.95) * w
            wd = r.uniform(0.006, 0.03) * w
            ln = r.uniform(0.3, 1.0) * h
            prof = np.exp(-((xx - x0 - (nz - 0.5) * wd * 3) / wd) ** 2)
            fall = np.clip(1 - yy / ln, 0, 1) ** 0.8
            a = np.maximum(a, prof * fall * r.uniform(0.5, 1.0))
        a *= (0.6 + 0.4 * fine) * P.get("alpha", 0.7)
        rgb *= (0.8 + 0.4 * nz)[..., None]
    elif st == "leaves":
        a = np.zeros((h, w), np.float32)
        palette = np.array(P.get("palette", [(0.42, 0.28, 0.12), (0.55, 0.4, 0.16), (0.3, 0.2, 0.1), (0.5, 0.33, 0.18)]), np.float32)
        dens = nz
        for _ in range(int(P.get("count", 260))):
            cx, cy = r.uniform(0, w), r.uniform(0, h)
            if r.random() > dens[int(cy) % h, int(cx) % w] ** 1.5 * 1.8:
                continue
            L = r.uniform(0.012, 0.03) * n
            W = L * r.uniform(0.35, 0.55)
            t = r.uniform(0, np.pi)
            dx, dy = xx - cx, yy - cy
            pu = dx * np.cos(t) + dy * np.sin(t)
            pv = -dx * np.sin(t) + dy * np.cos(t)
            m = np.clip(1.4 - np.sqrt((pu / L) ** 2 + (pv / W) ** 2) * 1.4, 0, 1)
            m = np.clip(m * 3, 0, 1)
            sel = m > a
            c = palette[int(r.integers(0, len(palette)))] * r.uniform(0.75, 1.15)
            # a darker midrib
            rib = np.exp(-(pv / (W * 0.12)) ** 2) * (np.abs(pu) < L * 0.9)
            rgb[sel] = (c[None, :] * (1 - 0.35 * rib[sel][:, None]))
            a = np.maximum(a, m)
        a *= P.get("alpha", 0.95)
    a *= 1 - _smooth(0.92, 1.0, np.maximum(np.abs(u), np.abs(v)))   # nothing at the cell edges
    return np.concatenate([np.clip(rgb, 0, 1), np.clip(a, 0, 1)[..., None]], -1)


# ------------------------------------------------------------------ atlas + decals

def build_atlas(cells=None, pieces=None, name="park_graffiti", atlas_px=None):
    cells = CELLS if cells is None else cells
    pieces = PIECES if pieces is None else pieces
    atlas_px = ATLAS if atlas_px is None else atlas_px
    cv = Canvas()
    atlas = np.zeros((atlas_px, atlas_px, 4), np.float32)
    tmp = os.path.join(C.WORK, "gfx_tmp.png")
    for key, (x, y, w, h) in cells.items():
        P = pieces[key]
        st = P["style"]
        if st in GRIME_STYLES:
            atlas[y:y + h, x:x + w] = draw_grime(w, h, P)
            print(f"[graffiti] {key}")
            continue
        if st == "piece":
            draw_piece(cv, P)
        elif st == "banner":
            draw_piece(cv, P, banner=True)
        elif st == "throwup":
            draw_throwup(cv, P)
        elif st == "tag":
            draw_tag(cv, P)
        elif st == "stencil":
            draw_stencil(cv, P)
        elif st == "smiley":
            draw_smiley(cv, P)
        elif st == "sign":
            draw_sign(cv, P)
        img = cv.render(w, h, tmp, margin=P.get("margin", 1.12 if st != "banner" else 1.04))
        img = spray(img, P["seed"], drips=P.get("drips", st not in ("smiley", "sign")),
                    wear=P.get("wear", 0.35 if st != "stencil" else 0.5), stencil=st == "stencil")
        atlas[y:y + h, x:x + w] = img
        cv.clear()
        print(f"[graffiti] {key}")
    cv.free()
    if os.path.exists(tmp):
        os.remove(tmp)
    img = C.save_png(atlas, name)
    m = C.pbr_material(name, base=img, roughness=0.72, alpha='texture')
    return m


def _quad(key, center, normal, width, roll, cells=None, atlas_px=None):
    cells = CELLS if cells is None else cells
    A = ATLAS if atlas_px is None else atlas_px
    x, y, w, h = cells[key]
    n = Vector(normal).normalized()
    up = Vector((0, 0, 1))
    right = (-n).cross(up).normalized()
    rm = Matrix.Rotation(math.radians(roll), 3, n)
    right, up = rm @ right, rm @ up
    hh = width * h / w
    c = Vector(center)
    pts = [c - right * width / 2 - up * hh / 2, c + right * width / 2 - up * hh / 2,
           c + right * width / 2 + up * hh / 2, c - right * width / 2 + up * hh / 2]
    u0, u1 = x / A, (x + w) / A
    v1, v0 = 1 - y / A, 1 - (y + h) / A
    uvs = [(u0, v0), (u1, v0), (u1, v1), (u0, v1)]
    return pts, uvs


def _decal_object(name, quads, mat, coll):
    verts, faces, uvs = [], [], []
    for pts, uv in quads:
        i = len(verts)
        verts += [tuple(p) for p in pts]
        faces.append((i, i + 1, i + 2, i + 3))
        uvs += uv
    me = bpy.data.meshes.new(name)
    me.from_pydata(verts, [], faces)
    layer = me.uv_layers.new(name="UVMap")
    for li, loop in enumerate(me.loops):
        layer.data[li].uv = uvs[loop.vertex_index]
    ob = bpy.data.objects.new(name, me)
    C.link(ob, coll)
    C.assign(ob, mat)
    return ob


def build(coll, cells=None, pieces=None, placements=None, sign=None, name="park_graffiti",
          object_name="Park_graffiti", sign_name="BreakWall_sign", atlas_px=None):
    """Returns (walls_decal_object, breakable_sign_object or None). With no arguments it
    builds the Warehouse's atlas and decals."""
    if cells is None:
        cells, pieces, placements, sign = CELLS, PIECES, PLACEMENTS, SIGN
    mat = build_atlas(cells, pieces, name, atlas_px)
    decals = _decal_object(object_name, [_quad(*p, cells=cells, atlas_px=atlas_px) for p in placements], mat, coll)
    so = _decal_object(sign_name, [_quad(*sign, cells=cells, atlas_px=atlas_px)], mat, coll) if sign else None
    return decals, so
