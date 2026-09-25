"""Builds the complete skater character in the current scene (no export).

Order: MPFB body -> face parts -> skin -> clothes -> hair -> clothing textures.
anims.py then adds the control rig, authors the clips and exports assets/skater.glb.
"""
import bpy

from lib import common as C
import skater_body
import skater_face
import skater_skin
import skater_clothes
import skater_hair


def build():
    C.reset_scene()
    coll = C.collection("Skater")
    rig, body, helpers = skater_body.build(coll)
    C.show([body], 'MATERIAL', azimuth=30, elevation=8)
    face = skater_face.build(rig, body, helpers, coll)
    skater_skin.build(body, face)
    C.show([body], 'MATERIAL', azimuth=30, elevation=8)
    parts = skater_clothes.build(body, rig, coll)
    C.show([body], 'MATERIAL', azimuth=30, elevation=8)
    hair = skater_hair.build(body, rig, coll)
    skater_clothes.texture(parts)
    C.show([parts["hoodie"], parts["jeans"], hair], 'MATERIAL', azimuth=30, elevation=8)
    info = dict(rig=rig, body=body, face=face, parts=parts, hair=hair)
    return info
