"""Development helper (not part of the build): contact sheets of animation clips."""
import bpy
from mathutils import Matrix, Vector
from lib import common as C
import anims
import board as B


def attach_board(rig):
    root = bpy.data.objects.get("Skateboard")
    if root is None:
        root = B.build_parts(C.collection("Board"))
    root.parent = rig
    root.parent_type = 'BONE'
    root.parent_bone = "board"
    bpy.context.view_layer.update()
    root.matrix_world = Matrix.Translation(anims.BOARD_REST)
    return root


def sheet(clip_names, times=(0, 0.2, 0.4, 0.6, 0.8, 1.0), path="/tmp/anim_sheet.png", cam=(1.1, -2.6, 1.3), res=320):
    rig = bpy.data.objects["SkaterRig"]
    poser = anims.Poser(rig)
    allc = {c.name: c for c in anims.clips()}
    tiles = []
    for name in clip_names:
        clip = allc[name]
        for t in times:
            poser.apply(clip, t)
            bpy.context.view_layer.update()
            p = f"/tmp/_tile_{name}_{int(t*100)}.png"
            C.preview(p, cam, (0, 0, 0.75), lens=35, res=(res, res), engine='BLENDER_EEVEE', samples=4)
            tiles.append(p)
    return tiles
