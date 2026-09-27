"""Builds a complete skater character in the current scene (no export).

Order: MPFB body -> face parts -> skin -> wardrobe (every garment, body cover masks) ->
hair (hat masks) -> clothing textures. anims.py then adds the control rig and authors
the clips (the male) or re-solves the clips' legs and arms for this body (the female),
and exports the body, the shared clip library and the garments.
"""
import os

import bpy

from lib import common as C
import skater_body
import skater_face
import skater_skin
import skater_outfit
import skater_hair
import skater_profiles as P


def build(prof=None):
    prof = prof or P.MALE
    male = prof["key"] == "male"
    # the female is cut from the male's masks: measure them on his body first
    ref = None if male else skater_outfit.reference(P.MALE)
    C.reset_scene()
    coll = C.collection("Skater")
    rig, body, helpers = skater_body.build(coll, prof)
    if ref is not None:
        import anims
        anims.align_rest(rig, ref["rest_rot"])
    C.show([body], 'MATERIAL', azimuth=30, elevation=8)
    face = skater_face.build(rig, body, helpers, coll, prof)
    skater_skin.build(body, face, prof=prof)
    C.show([body], 'MATERIAL', azimuth=30, elevation=8)
    G, oinfo = skater_outfit.build(body, rig, face, coll, prof, ref)
    C.show([body], 'MATERIAL', azimuth=30, elevation=8)
    # the hair is grown on the skin the default outfit leaves (as on the original trimmed body)
    trimmed = skater_outfit.trimmed_copy(body, oinfo["kill"])
    hair = skater_hair.build(trimmed, rig, coll, prof)
    bpy.data.objects.remove(trimmed, do_unlink=True)
    skater_outfit.hair_cells(hair, oinfo["hats"])
    skater_outfit.texture(G, oinfo, prof)
    if os.environ.get("OUTFIT_FIT", "1") != "0":
        skater_outfit.fit_in_motion(G, body, oinfo["kill"], reference=male)
    else:
        # (diagnostic: the wardrobe without the fit-in-motion pass, as the rest-pose layering
        # left it - what tests/results/outfits_without_fit_pass.txt measures)
        print("[outfit] OUTFIT_FIT=0: fit in motion skipped")
    parts = oinfo["parts"]
    C.show([parts["hoodie"], parts["jeans"], hair], 'MATERIAL', azimuth=30, elevation=8)
    oinfo["ankle_h"] = float(rig.data.bones["foot_l"].head_local.z)
    info = dict(rig=rig, body=body, face=face, parts=parts, hair=hair, G=G, outfit=oinfo, prof=prof, ref=ref)
    return info
