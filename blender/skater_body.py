"""Skater stage 1: the human body from MPFB2, shaped into an original character.

MPFB2 (the MakeHuman generator, CC0 output) supplies the anatomically correct base mesh,
its UV layout and the 'game_engine' skeleton with skin weights. This script chooses the
body macros and face targets that make the character original, bakes them into the mesh,
fits the rig, subdivides the mesh once for a smoother face and hands, and splits the helper
geometry (eye sockets, teeth, tongue, lash strips) into their own objects.
"""
import bpy
import bmesh
import numpy as np
from mathutils import Vector

from lib import common as C

from bl_ext.blender_org.mpfb.services.humanservice import HumanService
from bl_ext.blender_org.mpfb.services.targetservice import TargetService

MACRO = {"gender": 1.0, "age": 0.44, "muscle": 0.64, "weight": 0.36, "height": 0.58,
         "proportions": 0.80, "cupsize": 0.5, "firmness": 0.5,
         "race": {"asian": 0.07, "caucasian": 0.78, "african": 0.15}}

# Face and body targets (name, weight). Chosen to give a lean, angular, original face:
# an oval head with a defined jaw, lean cheeks, a long straight nose, open eyes and a
# medium mouth with a clear cupid's bow and philtrum.
TARGETS = [
    ("head-oval", 0.4), ("head-square", 0.12), ("head-age-decr", 0.2),
    ("head-fat-decr", 0.6), ("head-scale-horiz-decr", 0.22),
    ("chin-prominent-incr", 0.3), ("chin-width-decr", 0.25), ("chin-cleft-incr", 0.12),
    ("chin-bones-incr", 0.3), ("chin-height-incr", 0.2),
    ("nose-scale-horiz-decr", 0.18), ("nose-hump-incr", 0.15), ("nose-point-width-decr", 0.3),
    ("nose-nostrils-width-decr", 0.12), ("nose-scale-vert-incr", 0.2),
    ("mouth-scale-horiz-decr", 0.2), ("mouth-lowerlip-volume-decr", 0.05),
    ("mouth-cupidsbow-incr", 0.4), ("mouth-upperlip-volume-decr", 0.12),
    ("mouth-philtrum-volume-incr", 0.3),
    ("l-cheek-bones-incr", 0.3), ("r-cheek-bones-incr", 0.3),
    ("l-cheek-volume-decr", 0.6), ("r-cheek-volume-decr", 0.6),
    ("l-cheek-inner-decr", 0.15), ("r-cheek-inner-decr", 0.15),
    ("eyebrows-trans-down", 0.15), ("eyebrows-angle-up", 0.12), ("mouth-angles-up", 0.25),
    ("l-eye-height2-incr", 0.35), ("r-eye-height2-incr", 0.35),
    ("l-eye-scale-incr", 0.25), ("r-eye-scale-incr", 0.25),
    ("l-eye-trans-in", 0.15), ("r-eye-trans-in", 0.15),
    ("l-eye-bag-decr", 0.3), ("r-eye-bag-decr", 0.3),
    ("forehead-temple-decr", 0.2), ("forehead-scale-vert-incr", 0.15),
    ("neck-scale-horiz-incr", 0.2),
    ("torso-scale-horiz-incr", 0.1), ("torso-vshape-incr", 0.35),
    ("l-lowerarm-muscle-incr", 0.3), ("r-lowerarm-muscle-incr", 0.3),
    ("l-upperarm-muscle-incr", 0.2), ("r-upperarm-muscle-incr", 0.2),
    ("l-lowerleg-muscle-incr", 0.3), ("r-lowerleg-muscle-incr", 0.3),
]

HELPERS = {
    "EyeSocket_L": "helper-l-eye", "EyeSocket_R": "helper-r-eye",
    "TeethUpper": "helper-upper-teeth", "TeethLower": "helper-lower-teeth",
    "Tongue": "helper-tongue",
    "LashesTop_L": "helper-l-eyelashes-1", "LashesBot_L": "helper-l-eyelashes-2",
    "LashesTop_R": "helper-r-eyelashes-1", "LashesBot_R": "helper-r-eyelashes-2",
}


def load_targets(human):
    loaded = []
    for name, w in TARGETS:
        path = TargetService.target_full_path(name)
        if not path:
            print("target not found:", name)
            continue
        TargetService.load_target(human, path, weight=w)
        loaded.append(name)
    return loaded


def split_vertex_group(src, group, name, coll):
    """Duplicate the faces of one vertex group into a new object (keeps weights and UVs)."""
    gi = src.vertex_groups[group].index
    me = src.data.copy()
    ob = bpy.data.objects.new(name, me)
    C.link(ob, coll)
    ob.matrix_world = src.matrix_world
    bm = bmesh.new()
    bm.from_mesh(me)
    deform = bm.verts.layers.deform.active
    keep = set(v for v in bm.verts if deform and gi in v[deform] and v[deform][gi] > 0.5)
    bmesh.ops.delete(bm, geom=[v for v in bm.verts if v not in keep], context='VERTS')
    for f in bm.faces:
        f.material_index = 0
    bm.to_mesh(me)
    bm.free()
    me.materials.clear()
    for m in list(ob.modifiers):
        ob.modifiers.remove(m)
    return ob


def keep_only_group(obj, group):
    gi = obj.vertex_groups[group].index
    bm = bmesh.new()
    bm.from_mesh(obj.data)
    deform = bm.verts.layers.deform.active
    kill = [v for v in bm.verts if not (gi in v[deform] and v[deform][gi] > 0.5)]
    bmesh.ops.delete(bm, geom=kill, context='VERTS')
    bm.to_mesh(obj.data)
    bm.free()


def remove_unused_groups(obj, keep_prefixes=()):
    """Drop MakeHuman helper/joint groups, keep bone weight groups and named regions."""
    rig = obj.parent
    bones = set(b.name for b in rig.data.bones) if rig else set()
    for g in list(obj.vertex_groups):
        if g.name in bones or any(g.name.startswith(p) for p in keep_prefixes):
            continue
        obj.vertex_groups.remove(g)


def build(coll=None):
    coll = coll or C.collection("Skater")
    human = HumanService.create_human(macro_detail_dict=MACRO)
    human.name = "SkaterBody"
    load_targets(human)
    rig = HumanService.add_builtin_rig(human, "game_engine")
    rig.name = "SkaterRig"
    rig.data.name = "SkaterRig"
    TargetService.bake_targets(human)
    for o in (human, rig):
        for c in o.users_collection:
            c.objects.unlink(o)
        coll.objects.link(o)

    # helpers -> separate objects (eyes are rebuilt later, these give their placement)
    helpers = {}
    for name, grp in HELPERS.items():
        helpers[name] = split_vertex_group(human, grp, name, coll)
        helpers[name].parent = rig
    for m in list(human.modifiers):
        if m.type == 'MASK':
            human.modifiers.remove(m)
    keep_only_group(human, "body")

    # one level of Catmull-Clark for a smoother face and hands (weights interpolate)
    C.select_only(human)
    sub = human.modifiers.new("Subdiv", 'SUBSURF')
    sub.levels = 1
    sub.render_levels = 1
    sub.uv_smooth = 'PRESERVE_BOUNDARIES'
    bpy.ops.object.modifier_move_to_index(modifier="Subdiv", index=0)
    bpy.ops.object.modifier_apply(modifier="Subdiv")
    human.data.shade_smooth()
    remove_unused_groups(human, keep_prefixes=("lips", "fingernails", "toenails", "ears", "scalp"))
    for h in helpers.values():
        remove_unused_groups(h)
        h.data.shade_smooth()
    return rig, human, helpers
