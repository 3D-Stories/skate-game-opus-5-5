"""Collectibles: the S-K-A-T-E letters and the secret VHS tape (assets/pickups.glb).

Letters are extruded, bevelled text in a polished gold finish (the game adds a glow);
the tape is a modelled VHS cassette (shell, window, reels, label) with a procedural label.
"""
import math
import os

import bpy
import bmesh
import numpy as np
from mathutils import Vector

from lib import common as C


def letter(ch, coll, gold, outline):
    cu = bpy.data.curves.new("Letter_" + ch, 'FONT')
    cu.body = ch
    cu.align_x = 'CENTER'
    cu.align_y = 'CENTER'
    cu.size = 0.9
    cu.extrude = 0.07
    cu.bevel_depth = 0.02
    cu.bevel_resolution = 3
    cu.resolution_u = 6
    ob = bpy.data.objects.new("Letter_" + ch, cu)
    C.link(ob, coll)
    ob.rotation_euler = (math.radians(90), 0, 0)
    C.select_only(ob)
    bpy.ops.object.convert(target='MESH')
    ob = bpy.context.object
    C.apply_transform(ob)
    ob.name = "Letter_" + ch
    C.box_uv(ob, 0.3)
    C.assign(ob, gold)
    return ob


def label_texture():
    w, h = 512, 256
    img = np.ones((h, w, 3)) * np.array([0.93, 0.9, 0.82])
    img[:40] = np.array([0.8, 0.12, 0.1])
    img[h - 40:] = np.array([0.1, 0.1, 0.12])
    y, x = np.mgrid[0:h, 0:w]
    stripe = ((x + y) // 18) % 2 == 0
    img[(y > 50) & (y < 70)] = np.where(stripe[(y > 50) & (y < 70)][..., None], np.array([0.95, 0.7, 0.1]), np.array([0.1, 0.1, 0.1]))
    # hand-written 'SECRET' scribble strokes
    r = C.rng(8)
    for k in range(6):
        cx = 90 + k * 60
        for t in np.linspace(0, 1, 60):
            px = int(cx + 20 * math.sin(t * 6 + k) + t * 30)
            py = int(150 + 30 * math.cos(t * 5 + k * 2))
            img[max(0, py - 2):py + 2, max(0, px - 2):px + 2] = np.array([0.05, 0.05, 0.2])
    return C.save_png(img, "tape_label")


def tape(coll):
    parts = []
    bm = bmesh.new()
    bmesh.ops.create_cube(bm, size=1)
    bmesh.ops.scale(bm, vec=(0.187, 0.025, 0.103), verts=bm.verts)
    bmesh.ops.bevel(bm, geom=bm.edges[:], offset=0.003, segments=2, affect='EDGES')
    shell = C.bm_to_object(bm, "TapeShell", coll, smooth=False)
    parts.append(shell)
    # window + reels
    for sx in (-0.045, 0.045):
        bm = bmesh.new()
        bmesh.ops.create_cone(bm, cap_ends=True, segments=24, radius1=0.022, radius2=0.022, depth=0.052)
        bmesh.ops.rotate(bm, cent=(0, 0, 0), matrix=__import__('mathutils').Matrix.Rotation(math.radians(90), 3, 'X'), verts=bm.verts)
        bmesh.ops.translate(bm, vec=(sx, 0, 0.012), verts=bm.verts)
        parts.append(C.bm_to_object(bm, "Reel", coll, smooth=True))
    bm = bmesh.new()
    bmesh.ops.create_cube(bm, size=1)
    bmesh.ops.scale(bm, vec=(0.12, 0.052, 0.04), verts=bm.verts)
    bmesh.ops.translate(bm, vec=(0, 0, 0.012), verts=bm.verts)
    win = C.bm_to_object(bm, "TapeWindow", coll)
    parts.append(win)
    # label plane on the front
    me = bpy.data.meshes.new("TapeLabel")
    me.from_pydata([(-0.08, -0.0131, -0.045), (0.08, -0.0131, -0.045), (0.08, -0.0131, -0.012), (-0.08, -0.0131, -0.012)], [], [(0, 1, 2, 3)])
    lab = bpy.data.objects.new("TapeLabel", me)
    C.link(lab, coll)
    uv = me.uv_layers.new(name="UVMap")
    for i, co in enumerate([(0, 0), (1, 0), (1, 1), (0, 1)]):
        uv.data[i].uv = co
    parts.append(lab)
    black = C.pbr_material("TapePlastic", base_color=(0.02, 0.02, 0.025, 1), roughness=0.35)
    reel = C.pbr_material("TapeReel", base_color=(0.85, 0.85, 0.85, 1), roughness=0.4)
    glass = C.pbr_material("TapeWindowMat", base_color=(0.15, 0.15, 0.18, 1), roughness=0.05)
    labm = C.pbr_material("TapeLabelMat", base=label_texture(), roughness=0.7)
    C.assign(shell, black)
    for p in parts:
        if p.name.startswith("Reel"):
            C.assign(p, reel)
    C.assign(win, glass)
    C.assign(lab, labm)
    ob = C.join(parts, "SecretTape")
    # scale up so it reads in the game (a 'hero' pickup, THPS style)
    ob.scale = (2.6, 2.6, 2.6)
    C.apply_transform(ob)
    return ob


def build(export=True):
    C.reset_scene()
    coll = C.collection("Pickups")
    gold = C.pbr_material("LetterGold", base_color=(1.0, 0.72, 0.18, 1), roughness=0.22, metallic=1.0)
    outline = C.pbr_material("LetterOutline", base_color=(0.05, 0.03, 0.02, 1), roughness=0.6)
    objs = []
    for i, ch in enumerate("SKATE"):
        ob = letter(ch, coll, gold, outline)
        ob.location.x = i * 1.2
        objs.append(ob)
    t = tape(coll)
    t.location.x = 7.0
    C.show(objs + [t], 'MATERIAL', azimuth=20, elevation=10, margin=0.8)
    if export:
        for ob in objs + [t]:
            ob.location.x = 0.0
        C.export_glb(os.path.join(C.ASSETS, "pickups.glb"))
    return objs, t
