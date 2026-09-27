"""Cycles beauty renders of every major asset into renders/ (run by build_all.py last).

    renders/skater_portrait.png          close-up of the face (85 mm, softbox key + rim)
    renders/skater_tpose.png / _sheet.png / _turntable.mp4
    renders/skater_trick.png / _sheet.png / _turntable.mp4   (mid-kickflip, board flipping)
    renders/skater_female_portrait.png / _tpose* / _trick*   the same three for the female skater
    renders/outfits_sheet.png            both skaters in three outfits that use every clothing
                                         option, front and back (the character builder)
    renders/board.png / _sheet.png / _turntable.mp4
    renders/park.png / _sheet.png / _turntable.mp4          (high three-quarter cutaway)
    renders/<id>.png / _sheet.png / _turntable.mp4          (each kit-built level, render_level)

Each asset is loaded from the .blend its build step saved in blender/work/, so these are
the exact meshes, rig, clips and materials that were exported to assets/.
"""
import math
import os

import bpy
import numpy as np
from mathutils import Matrix, Vector

from lib import common as C
import skater_profiles as P

SHEET_VIEWS = 8
TURN_FRAMES = 24


# ------------------------------------------------------------------ scene helpers

def open_blend(name):
    bpy.ops.wm.open_mainfile(filepath=os.path.join(C.WORK, name + ".blend"))
    C.use_gpu()


def settings(samples, res, transparent=False):
    scn = C.cycles(samples)
    scn.cycles.samples = samples if not C.FAST else max(8, samples // 8)
    scn.cycles.use_denoising = True
    scn.render.resolution_x, scn.render.resolution_y = res
    scn.render.resolution_percentage = 100 if not C.FAST else 50
    scn.render.film_transparent = transparent
    scn.view_settings.view_transform = 'AgX'
    scn.view_settings.look = 'AgX - Medium High Contrast'
    scn.cycles.max_bounces = 8
    scn.cycles.transparent_max_bounces = 32   # hair cards and lashes are layered alpha
    return scn


def area(name, loc, target, size, energy, color=(1, 1, 1), size_y=None, coll=None):
    ld = bpy.data.lights.new(name, 'AREA')
    ld.shape = 'RECTANGLE' if size_y else 'SQUARE'
    ld.size = size
    if size_y:
        ld.size_y = size_y
    ld.energy = energy
    ld.color = color
    lo = bpy.data.objects.new(name, ld)
    C.link(lo, coll)
    lo.location = loc
    C.look_at(lo, target)
    return lo


def studio(center, scale=1.0, floor_z=0.0, backdrop=(0.16, 0.165, 0.18)):
    """Photo-studio cyclorama plus key / fill / two rim lights around `center`."""
    coll = C.collection("Studio")
    c = Vector(center)
    s = scale
    # infinity cove all the way round: a round floor that sweeps up into a circular wall,
    # so the orbiting camera sees a seamless backdrop from every side
    verts, faces = [(c.x, c.y, floor_z)], []
    RF, RC, H, SEG = 6.0 * s, 2.5 * s, 9.0 * s, 72
    prof = [(RF * k / 4, 0.0) for k in range(1, 5)]
    for k in range(1, 13):
        a = math.radians(90 * k / 12)
        prof.append((RF + RC * math.sin(a), RC * (1 - math.cos(a))))
    prof.append((RF + RC, H))
    for j in range(SEG):
        a = 2 * math.pi * j / SEG
        for (r, z) in prof:
            verts.append((c.x + r * math.cos(a), c.y + r * math.sin(a), floor_z + z))
    n = len(prof)
    for j in range(SEG):
        j2 = (j + 1) % SEG
        faces.append((0, 1 + j * n, 1 + j2 * n))          # wound so the floor faces up, the wall inward
        for i in range(n - 1):
            a0, a1 = 1 + j * n + i, 1 + j2 * n + i
            faces.append((a0, a0 + 1, a1 + 1, a1))
    cyc = C.mesh_object("Cyc", verts, faces, coll, smooth=True)
    m = C.new_material("CycMat")
    p = C.principled(m)
    p.inputs["Base Color"].default_value = (*backdrop, 1)
    p.inputs["Roughness"].default_value = 0.85
    C.assign(cyc, m)
    k = c + Vector((0, 0, 0))
    area("Key", k + Vector((-2.4, -3.0, 2.6)) * s, k, 2.2 * s, 900 * s * s, (1.0, 0.96, 0.9), coll=coll)
    area("Fill", k + Vector((3.2, -2.4, 1.2)) * s, k, 3.0 * s, 260 * s * s, (0.85, 0.9, 1.0), coll=coll)
    area("RimL", k + Vector((-2.2, 2.6, 2.2)) * s, k, 1.2 * s, 520 * s * s, (0.9, 0.95, 1.0), coll=coll)
    area("RimR", k + Vector((2.4, 2.4, 1.8)) * s, k, 1.2 * s, 420 * s * s, (1.0, 0.92, 0.85), coll=coll)
    w = bpy.context.scene.world or bpy.data.worlds.new("World")
    bpy.context.scene.world = w
    bg = w.node_tree.nodes.get("Background")
    bg.inputs[0].default_value = (0.05, 0.055, 0.065, 1)
    bg.inputs[1].default_value = 0.6
    return coll


def pivot(target):
    """An empty the turntable camera is parented to; rotating it orbits the camera."""
    e = bpy.data.objects.new("TurnPivot", None)
    C.link(e)
    e.location = target
    return e


def orbit_camera(target, dist, elev_deg, az_deg, lens):
    """Camera on a pivot at `target`. Studio lights ride along with it, like a classic
    turntable where the subject turns in front of a fixed camera and lights."""
    piv = pivot(target)
    a, el = math.radians(az_deg), math.radians(elev_deg)
    loc = Vector(target) + Vector((math.sin(a) * math.cos(el), -math.cos(a) * math.cos(el), math.sin(el))) * dist
    cam = C.camera("TurnCam", loc, target, lens=lens)
    riders = [cam]
    studio_coll = bpy.data.collections.get("Studio")
    if studio_coll:
        riders += [o for o in studio_coll.objects if o.type == 'LIGHT']
    inv = Matrix.Translation(-Vector(target))     # piv.matrix_world is not evaluated yet
    for o in riders:
        o.parent = piv
        o.matrix_parent_inverse = inv
    return cam, piv


def render_still(path, res=None):
    scn = bpy.context.scene
    if res:
        scn.render.resolution_x, scn.render.resolution_y = res
    if hasattr(scn.render.image_settings, "media_type"):
        scn.render.image_settings.media_type = 'IMAGE'
    scn.render.image_settings.file_format = 'PNG'
    scn.render.image_settings.color_mode = 'RGB'
    scn.render.filepath = path
    bpy.ops.render.render(write_still=True)
    print(f"[renders] {os.path.relpath(path, C.PROJECT_DIR)}")
    return path


def turntable(name, piv, hero_res=(1920, 1080), tile_res=(640, 720), mp4_res=(960, 540), start_az=0.0):
    """Hero still, an 8-view contact sheet and a 24-frame MP4 orbit."""
    os.makedirs(C.RENDERS, exist_ok=True)
    scn = bpy.context.scene
    base = piv.rotation_euler.z
    render_still(os.path.join(C.RENDERS, f"{name}.png"), hero_res)
    # sheet
    tiles = []
    tmp = os.path.join(C.WORK, "turn_tmp.png")
    for i in range(SHEET_VIEWS):
        piv.rotation_euler.z = base + math.radians(start_az + 360.0 * i / SHEET_VIEWS)
        render_still(tmp, tile_res)
        img = bpy.data.images.load(tmp, check_existing=False)
        a = np.array(img.pixels[:], dtype=np.float32).reshape(img.size[1], img.size[0], 4)
        bpy.data.images.remove(img)
        tiles.append(np.flipud(a))
    rows = [np.concatenate(tiles[r * 4:(r + 1) * 4], 1) for r in range(SHEET_VIEWS // 4)]
    sheet = np.concatenate(rows, 0)
    C.save_png(sheet, f"{name}_sheet", folder=C.RENDERS)
    print(f"[renders] renders/{name}_sheet.png")
    # mp4 orbit (Blender's built-in FFmpeg writer)
    piv.rotation_euler.z = base
    piv.keyframe_insert("rotation_euler", index=2, frame=1)
    piv.rotation_euler.z = base + math.radians(360.0 * (TURN_FRAMES - 1) / TURN_FRAMES)
    piv.keyframe_insert("rotation_euler", index=2, frame=TURN_FRAMES)
    _linear(piv)
    scn.frame_start, scn.frame_end = 1, TURN_FRAMES
    scn.render.fps = 12
    scn.render.resolution_x, scn.render.resolution_y = mp4_res
    if hasattr(scn.render.image_settings, "media_type"):
        scn.render.image_settings.media_type = 'VIDEO'      # Blender 5: video is its own media type
    scn.render.image_settings.file_format = 'FFMPEG'
    scn.render.ffmpeg.format = 'MPEG4'
    scn.render.ffmpeg.codec = 'H264'
    scn.render.ffmpeg.constant_rate_factor = 'HIGH'
    out = os.path.join(C.RENDERS, f"{name}_turntable")
    scn.render.filepath = out
    bpy.ops.render.render(animation=True)
    produced = [f for f in os.listdir(C.RENDERS) if f.startswith(f"{name}_turntable") and f.endswith(".mp4")]
    for f in produced:
        if f != f"{name}_turntable.mp4":
            os.replace(os.path.join(C.RENDERS, f), os.path.join(C.RENDERS, f"{name}_turntable.mp4"))
    print(f"[renders] renders/{name}_turntable.mp4")
    if piv.animation_data:
        piv.animation_data_clear()
    piv.rotation_euler.z = base
    if hasattr(scn.render.image_settings, "media_type"):
        scn.render.image_settings.media_type = 'IMAGE'
    scn.render.image_settings.file_format = 'PNG'


def _linear(ob):
    ad = ob.animation_data
    act = ad.action if ad else None
    if act is None:
        return
    try:
        curves = act.fcurves
    except AttributeError:
        curves = [fc for layer in act.layers for strip in layer.strips for bag in strip.channelbags for fc in bag.fcurves]
    for fc in curves:
        for kp in fc.keyframe_points:
            kp.interpolation = 'LINEAR'


# ------------------------------------------------------------------ skater

def _attach_board(rig):
    import anims
    import board as B
    root = B.build_parts(C.collection("Board"))
    root.parent = rig
    root.parent_type = 'BONE'
    root.parent_bone = "board"
    bpy.context.view_layer.update()
    root.matrix_world = Matrix.Translation(anims.BOARD_REST)
    return root


def _pose(rig, action_name=None, t=0.0):
    ad = rig.animation_data or rig.animation_data_create()
    if action_name is None:
        ad.action = None
        for pb in rig.pose.bones:
            pb.matrix_basis = Matrix.Identity(4)
        return
    act = bpy.data.actions[action_name]
    ad.action = act
    if hasattr(ad, "action_slot") and len(getattr(act, "slots", [])):
        ad.action_slot = act.slots[0]
    f0, f1 = act.frame_range
    bpy.context.scene.frame_set(int(round(f0 + (f1 - f0) * t)))


def _dress(outfit=None):
    """The work .blend holds every garment of the wardrobe: show one outfit (the default:
    today's skater's hoodie, jeans and grey suede shoes)."""
    import skater_outfit as O
    O.wear(outfit or O.DEFAULT)


def _pose_body(rig, prof, action_name, t):
    """A clip on this body as the game plays it: the male pose as authored; any other body
    the shared clip (appended from the male's .blend) with its re-solved tracks laid over
    it (an NLA strip on top replaces just the channels it animates)."""
    if prof["key"] == "male":
        _pose(rig, action_name, t)
        return
    over = bpy.data.actions[action_name]
    with bpy.data.libraries.load(os.path.join(C.WORK, P.MALE["blend"] + ".blend"), link=False) as (src, dst):
        dst.actions = [action_name]
    base = dst.actions[0]
    ad = rig.animation_data or rig.animation_data_create()
    ad.action = None
    for tr in list(ad.nla_tracks):
        ad.nla_tracks.remove(tr)
    f0, f1 = base.frame_range
    for act in (base, over):
        tr = ad.nla_tracks.new()
        st = tr.strips.new(act.name, int(f0), act)
        if hasattr(st, "action_slot") and len(getattr(act, "slots", [])):
            st.action_slot = act.slots[0]
        st.blend_type = 'REPLACE'
    bpy.context.scene.frame_set(int(round(f0 + (f1 - f0) * t)))


def _t_pose(rig):
    """Rest pose with the arms raised level to the sides (a T-pose)."""
    _pose(rig, None)
    bpy.context.view_layer.update()
    for side, sgn in (("l", 1), ("r", -1)):
        pb = rig.pose.bones[f"upperarm_{side}"]
        head = rig.matrix_world @ pb.head
        tail = rig.matrix_world @ rig.pose.bones[f"lowerarm_{side}"].tail
        cur = (tail - head).normalized()
        want = Vector((sgn, 0.0, 0.0))
        q = cur.rotation_difference(want)
        M = pb.matrix.copy()
        loc = M.to_translation()
        R = (rig.matrix_world.to_3x3().inverted() @ q.to_matrix() @ rig.matrix_world.to_3x3()) @ M.to_3x3()
        pb.matrix = Matrix.Translation(loc) @ R.to_4x4()
        bpy.context.view_layer.update()
        # straighten the elbow along the same line
        lo = rig.pose.bones[f"lowerarm_{side}"]
        h2 = rig.matrix_world @ lo.head
        t2 = rig.matrix_world @ lo.tail
        q2 = (t2 - h2).normalized().rotation_difference(want)
        M2 = lo.matrix.copy()
        R2 = (rig.matrix_world.to_3x3().inverted() @ q2.to_matrix() @ rig.matrix_world.to_3x3()) @ M2.to_3x3()
        lo.matrix = Matrix.Translation(M2.to_translation()) @ R2.to_4x4()
        bpy.context.view_layer.update()


def _bone_world(rig, name):
    pb = rig.pose.bones[name]
    return rig.matrix_world @ pb.head, rig.matrix_world @ pb.tail


def _cycles_hair():
    """Renders shade the hair cards with a card shader - diffuse with a little translucency
    and a highlight tinted by the fibre colour - instead of the exported PBR stand-in, whose
    untinted grazing (Fresnel) reflections turn edge-on cards grey-white. Colour and alpha
    still come from the strand atlas."""
    m = bpy.data.materials.get("Hair")
    if m is None or not m.use_nodes:
        return
    nt = m.node_tree
    tex = next((n for n in nt.nodes if n.type == 'TEX_IMAGE'), None)
    out = next((n for n in nt.nodes if n.type == 'OUTPUT_MATERIAL'), None)
    if tex is None or out is None:
        return

    def scaled(k):
        n = nt.nodes.new('ShaderNodeVectorMath')
        n.operation = 'SCALE'
        n.inputs["Scale"].default_value = k
        nt.links.new(tex.outputs["Color"], n.inputs[0])
        return n.outputs[0]

    dif = nt.nodes.new('ShaderNodeBsdfDiffuse')
    nt.links.new(tex.outputs["Color"], dif.inputs["Color"])
    tl = nt.nodes.new('ShaderNodeBsdfTranslucent')
    nt.links.new(scaled(1.6), tl.inputs["Color"])
    gl = nt.nodes.new('ShaderNodeBsdfGlossy')
    nt.links.new(scaled(5.0), gl.inputs["Color"])
    gl.inputs["Roughness"].default_value = 0.38
    m1 = nt.nodes.new('ShaderNodeMixShader'); m1.inputs[0].default_value = 0.22
    nt.links.new(dif.outputs[0], m1.inputs[1]); nt.links.new(tl.outputs[0], m1.inputs[2])
    m2 = nt.nodes.new('ShaderNodeMixShader'); m2.inputs[0].default_value = 0.14
    nt.links.new(m1.outputs[0], m2.inputs[1]); nt.links.new(gl.outputs[0], m2.inputs[2])
    tr = nt.nodes.new('ShaderNodeBsdfTransparent')
    mix = nt.nodes.new('ShaderNodeMixShader')
    nt.links.new(tex.outputs["Alpha"], mix.inputs[0])
    nt.links.new(tr.outputs[0], mix.inputs[1])
    nt.links.new(m2.outputs[0], mix.inputs[2])
    nt.links.new(mix.outputs[0], out.inputs["Surface"])


def render_portrait(prof=P.MALE):
    open_blend(prof["blend"])
    _dress()
    _cycles_hair()
    rig = bpy.data.objects["SkaterRig"]
    settings(256, (1080, 1350))
    _pose(rig, None)
    bpy.context.view_layer.update()
    hh, ht = _bone_world(rig, "head")
    face = hh + (ht - hh) * 0.35
    coll = C.collection("PortraitLights")
    area("PKey", face + Vector((-1.0, -0.95, 0.6)), face, 0.8, 80.0, (1.0, 0.94, 0.86), coll=coll)
    area("PFill", face + Vector((1.2, -0.9, 0.05)), face, 1.4, 7.0, (0.85, 0.9, 1.0), coll=coll)
    area("PRim", face + Vector((0.7, 0.9, 0.45)), face, 0.5, 45.0, (1.0, 0.93, 0.85), coll=coll)
    area("PHair", face + Vector((-0.4, 0.5, 1.0)), face, 0.6, 30.0, (1.0, 0.97, 0.92), coll=coll)
    w = bpy.context.scene.world
    bg = w.node_tree.nodes.get("Background")
    bg.inputs[0].default_value = (0.035, 0.038, 0.045, 1)
    bg.inputs[1].default_value = 1.0
    cam = C.camera("PortraitCam", face + Vector((0.16, -0.95, 0.02)), face + Vector((0, 0, -0.035)), lens=85)
    cam.data.dof.use_dof = True
    cam.data.dof.focus_distance = (cam.location - (face + Vector((0, -0.09, 0.02)))).length
    cam.data.dof.aperture_fstop = 4.0
    render_still(os.path.join(C.RENDERS, _name(prof, "portrait") + ".png"))


def _name(prof, what):
    return "skater_" + what if prof["key"] == "male" else f"skater_{prof['key']}_{what}"


def render_skater(prof=P.MALE):
    open_blend(prof["blend"])
    _dress()
    _cycles_hair()
    rig = bpy.data.objects["SkaterRig"]
    _attach_board(rig)
    settings(96, (1920, 1080))
    studio((0, 0, 0.95), 1.0)
    _t_pose(rig)
    cam, piv = orbit_camera((0, 0, 0.92), 5.2, 6.0, -25.0, 50)
    turntable(_name(prof, "tpose"), piv)
    bpy.data.objects.remove(cam)
    bpy.data.objects.remove(piv)
    # mid-trick: kickflip at the top of the pop, board mid-rotation
    _pose_body(rig, prof, "kickflip", 0.42)
    bpy.context.view_layer.update()
    pb = rig.pose.bones["pelvis"]
    ctr = rig.matrix_world @ pb.head
    cam, piv = orbit_camera((ctr.x, ctr.y, ctr.z - 0.1), 5.0, 10.0, -35.0, 50)
    turntable(_name(prof, "trick"), piv)


# the contact sheet's outfits: between them every top, bottom, pair of shoes and hat
SHEET_OUTFITS = [dict(top="hoodie", bottom="jeans", shoes="suede", hat="none"),
                 dict(top="tee", bottom="cargo", shoes="hitop", hat="cap"),
                 dict(top="flannel", bottom="shorts", shoes="suede_navy", hat="beanie")]


def render_outfits(tile=(560, 800)):
    """renders/outfits_sheet.png: rows male / female, each outfit front and back, in the
    studio the turntables use."""
    tiles = []
    tmp = os.path.join(C.WORK, "outfit_tmp.png")
    for prof in (P.MALE, P.FEMALE):
        row = []
        for of in SHEET_OUTFITS:
            open_blend(prof["blend"])
            _dress(of)
            _cycles_hair()
            rig = bpy.data.objects["SkaterRig"]
            _pose(rig, None)
            settings(96, tile)
            studio((0, 0, 0.95), 1.0)
            cam, piv = orbit_camera((0, 0, 0.9), 4.6, 6.0, -25.0, 50)
            bpy.context.scene.camera = cam
            for turn in (0.0, 180.0):           # front three-quarter, then the back (lights ride along)
                piv.rotation_euler.z = math.radians(turn)
                render_still(tmp, tile)
                img = bpy.data.images.load(tmp, check_existing=False)
                a = np.array(img.pixels[:], dtype=np.float32).reshape(img.size[1], img.size[0], 4)
                bpy.data.images.remove(img)
                row.append(np.flipud(a))
        tiles.append(np.concatenate(row, 1))
    C.save_png(np.concatenate(tiles, 0), "outfits_sheet", folder=C.RENDERS)
    print("[renders] renders/outfits_sheet.png")


def build_skaters():
    for prof in (P.MALE, P.FEMALE):
        render_portrait(prof)
        render_skater(prof)
    render_outfits()


# ------------------------------------------------------------------ board

def render_board():
    open_blend("board")
    root = bpy.data.objects.get("Skateboard")
    settings(128, (1920, 1080))
    studio((0, 0, 0.3), 0.45)
    # stand it on a slight tilt so the graphic and the grip both read over the orbit
    if root:
        root.location = (0, 0, 0.32)
        root.rotation_euler = (math.radians(58), 0, 0)
    cam, piv = orbit_camera((0, 0, 0.3), 1.9, 12.0, 0.0, 50)
    turntable("board", piv)


# ------------------------------------------------------------------ park

def _cutaway(mats, cut_z=None):
    """Camera rays pass through back faces (and, with cut_z, everything above that height:
    roof trusses, purlins, skylight wells), so the orbit sees into the closed hall while
    light, shadows and bounce stay exactly as in the lightmap bake."""
    for m in mats:
        if not m or not m.use_nodes:
            continue
        nt = m.node_tree
        out = next((n for n in nt.nodes if n.type == 'OUTPUT_MATERIAL' and n.is_active_output), None)
        if out is None or not out.inputs["Surface"].links:
            continue
        src = out.inputs["Surface"].links[0].from_socket
        geo = nt.nodes.new('ShaderNodeNewGeometry')
        lp = nt.nodes.new('ShaderNodeLightPath')
        mul = nt.nodes.new('ShaderNodeMath')
        mul.operation = 'MULTIPLY'
        cut = geo.outputs["Backfacing"]
        if cut_z is not None:
            sep = nt.nodes.new('ShaderNodeSeparateXYZ')
            nt.links.new(geo.outputs["Position"], sep.inputs[0])
            above = nt.nodes.new('ShaderNodeMath')
            above.operation = 'GREATER_THAN'
            above.inputs[1].default_value = cut_z
            nt.links.new(sep.outputs["Z"], above.inputs[0])
            either = nt.nodes.new('ShaderNodeMath')
            either.operation = 'MAXIMUM'
            nt.links.new(cut, either.inputs[0])
            nt.links.new(above.outputs[0], either.inputs[1])
            cut = either.outputs[0]
        nt.links.new(cut, mul.inputs[0])
        nt.links.new(lp.outputs["Is Camera Ray"], mul.inputs[1])
        tr = nt.nodes.new('ShaderNodeBsdfTransparent')
        mix = nt.nodes.new('ShaderNodeMixShader')
        nt.links.new(mul.outputs[0], mix.inputs[0])
        nt.links.new(src, mix.inputs[1])
        nt.links.new(tr.outputs[0], mix.inputs[2])
        nt.links.new(mix.outputs[0], out.inputs["Surface"])


def _studio_backdrop(world, color=(0.045, 0.048, 0.056)):
    """Camera rays see a dark studio backdrop; every other ray still sees the sky the bake
    was lit with, so the lighting is unchanged."""
    nt = world.node_tree
    out = next(n for n in nt.nodes if n.type == 'OUTPUT_WORLD' and n.is_active_output)
    src = out.inputs["Surface"].links[0].from_socket
    lp = nt.nodes.new('ShaderNodeLightPath')
    bg = nt.nodes.new('ShaderNodeBackground')
    bg.inputs[0].default_value = (*color, 1)
    mix = nt.nodes.new('ShaderNodeMixShader')
    nt.links.new(lp.outputs["Is Camera Ray"], mix.inputs[0])
    nt.links.new(src, mix.inputs[1])
    nt.links.new(bg.outputs[0], mix.inputs[2])
    nt.links.new(mix.outputs[0], out.inputs["Surface"])


def render_park():
    open_blend("park")
    scn = settings(160, (1920, 1080))
    scn.cycles.max_bounces = 6
    for o in bpy.data.objects:
        if o.name.startswith("COL_") or o.name == "Park_yard":
            o.hide_render = True        # collision proxies; the daylight yard outside the windows
    mats = {s.material for o in bpy.data.objects if o.type == 'MESH' for s in o.material_slots}
    _cutaway(mats, cut_z=9.3)
    _studio_backdrop(bpy.context.scene.world)
    target = (0.0, 17.0, 0.0)
    cam, piv = orbit_camera(target, 78.0, 42.0, -35.0, 30)
    cam.data.clip_end = 400
    turntable("park", piv, tile_res=(640, 360), mp4_res=(960, 540))


def render_level(level_id):
    """A kit-built level (levels/<id>/level.json "render": target, dist, elev, az, lens, cut_z,
    samples, exposure in stops): renders/<id>.png (high three-quarter cutaway), _sheet.png and _turntable.mp4,
    lit by the level's own lights and sky exactly as its lightmap bake."""
    import json
    with open(os.path.join(C.PROJECT_DIR, "levels", level_id, "level.json")) as f:
        rs = json.load(f)["build"].get("render", {})
    open_blend(level_id)
    scn = settings(rs.get("samples", 160), (1920, 1080))
    scn.cycles.max_bounces = 6
    scn.view_settings.exposure = rs.get("exposure", 0.0)
    for o in bpy.data.objects:
        if o.name.startswith("COL_"):
            o.hide_render = True
    mats = {s.material for o in bpy.data.objects if o.type == 'MESH' for s in o.material_slots}
    _cutaway(mats, cut_z=rs.get("cut_z"))
    _studio_backdrop(bpy.context.scene.world)
    cam, piv = orbit_camera(tuple(rs.get("target", (0.0, 0.0, 0.0))), rs.get("dist", 60.0), rs.get("elev", 42.0),
                            rs.get("az", -35.0), rs.get("lens", 30))
    cam.data.clip_end = 400
    turntable(level_id, piv, tile_res=(640, 360), mp4_res=(960, 540))


def build():
    build_skaters()
    render_board()
    render_park()
