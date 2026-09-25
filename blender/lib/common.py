"""Shared helpers for the Pro Skater asset scripts.

Every build script imports this module. Nothing here downloads anything: textures are
either procedural (numpy, generated here) or read from blender/textures_src, which holds
the photos made with the shared imagegen tool.
"""
import math
import os
import sys

import bpy
import bmesh
import numpy as np
from mathutils import Matrix, Vector

BLENDER_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PROJECT_DIR = os.path.dirname(BLENDER_DIR)
SRC_TEX = os.path.join(BLENDER_DIR, "textures_src")
WORK = os.path.join(BLENDER_DIR, "work")
TEX_OUT = os.path.join(WORK, "tex")
ASSETS = os.path.join(PROJECT_DIR, "assets")
RENDERS = os.path.join(PROJECT_DIR, "renders")
for _d in (WORK, TEX_OUT, ASSETS, RENDERS):
    os.makedirs(_d, exist_ok=True)

# Set by build_all.py --fast: fewer bake/render samples, same geometry.
FAST = False


def rng(seed):
    return np.random.default_rng(seed)


# ---------------------------------------------------------------- scene

def reset_scene():
    """Empty the scene and orphan data so every build starts from nothing."""
    if bpy.context.object and bpy.context.object.mode != 'OBJECT':
        bpy.ops.object.mode_set(mode='OBJECT')
    for o in list(bpy.data.objects):
        bpy.data.objects.remove(o, do_unlink=True)
    for coll in (bpy.data.meshes, bpy.data.armatures, bpy.data.materials, bpy.data.images,
                 bpy.data.actions, bpy.data.curves, bpy.data.cameras, bpy.data.lights,
                 bpy.data.node_groups, bpy.data.textures):
        for block in list(coll):
            if block.users == 0 or coll in (bpy.data.meshes, bpy.data.armatures, bpy.data.actions):
                try:
                    coll.remove(block)
                except Exception:
                    pass
    for c in list(bpy.data.collections):
        bpy.data.collections.remove(c)
    scn = bpy.context.scene
    scn.frame_start, scn.frame_end = 1, 250
    scn.render.fps = 30
    scn.unit_settings.system = 'METRIC'
    return scn


def collection(name, parent=None):
    c = bpy.data.collections.get(name)
    if c is None:
        c = bpy.data.collections.new(name)
        (parent or bpy.context.scene.collection).children.link(c)
    return c


def link(obj, coll=None):
    (coll or bpy.context.scene.collection).objects.link(obj)
    return obj


def mesh_object(name, verts, faces, coll=None, smooth=False):
    me = bpy.data.meshes.new(name)
    me.from_pydata([tuple(v) for v in verts], [], [tuple(f) for f in faces])
    me.validate()
    me.update()
    if smooth:
        me.shade_smooth()
    ob = bpy.data.objects.new(name, me)
    link(ob, coll)
    return ob


def bm_to_object(bm, name, coll=None, smooth=False):
    me = bpy.data.meshes.new(name)
    bm.to_mesh(me)
    bm.free()
    if smooth:
        me.shade_smooth()
    ob = bpy.data.objects.new(name, me)
    link(ob, coll)
    return ob


def deselect_all():
    for o in bpy.context.scene.objects:
        if o is not None:
            try:
                o.select_set(False)
            except RuntimeError:
                pass


def select_only(obj):
    deselect_all()
    obj.select_set(True)
    bpy.context.view_layer.objects.active = obj


def apply_modifiers(obj):
    select_only(obj)
    for m in list(obj.modifiers):
        try:
            bpy.ops.object.modifier_apply(modifier=m.name)
        except RuntimeError:
            obj.modifiers.remove(m)


def apply_transform(obj):
    select_only(obj)
    bpy.ops.object.transform_apply(location=True, rotation=True, scale=True)


def join(objs, name):
    objs = [o for o in objs if o is not None]
    deselect_all()
    for o in objs:
        o.select_set(True)
    bpy.context.view_layer.objects.active = objs[0]
    bpy.ops.object.join()
    objs[0].name = name
    objs[0].data.name = name
    return objs[0]


def set_origin(obj, point):
    """Move an object's origin to a world-space point without moving its geometry."""
    point = Vector(point)
    local = obj.matrix_world.inverted() @ point
    obj.data.transform(Matrix.Translation(-local))
    obj.matrix_world = obj.matrix_world @ Matrix.Translation(local)


# ---------------------------------------------------------------- images / numpy textures

def save_png(arr, name, colorspace='sRGB', folder=None):
    """arr: HxWx{1,3,4} float in 0..1. Writes blender/work/tex/<name>.png and returns the image."""
    arr = np.asarray(arr, dtype=np.float32)
    if arr.ndim == 2:
        arr = arr[..., None]
    h, w, c = arr.shape
    if c == 1:
        arr = np.concatenate([arr, arr, arr, np.ones_like(arr)], -1)
    elif c == 3:
        arr = np.concatenate([arr, np.ones((h, w, 1), np.float32)], -1)
    arr = np.clip(arr, 0, 1)
    path = os.path.join(folder or TEX_OUT, name + ".png")
    img = bpy.data.images.get(name)
    if img is not None:
        bpy.data.images.remove(img)
    img = bpy.data.images.new(name, w, h, alpha=True)
    img.pixels.foreach_set(np.flipud(arr).ravel())
    img.filepath_raw = path
    img.file_format = 'PNG'
    img.save()
    img.colorspace_settings.name = colorspace
    return img


def load_png(path, name=None, colorspace='sRGB'):
    name = name or os.path.splitext(os.path.basename(path))[0]
    img = bpy.data.images.load(path, check_existing=False)
    img.name = name
    img.colorspace_settings.name = colorspace
    return img


def image_array(img):
    w, h = img.size
    a = np.empty(w * h * 4, np.float32)
    img.pixels.foreach_get(a)
    return np.flipud(a.reshape(h, w, 4))


def src_array(name, size=None):
    """Load one of the imagegen photos from textures_src as a float array (top row first)."""
    path = os.path.join(SRC_TEX, name + ".png")
    img = bpy.data.images.load(path, check_existing=False)
    if size and tuple(img.size) != (size, size):
        img.scale(size, size)
    a = image_array(img)[..., :3].copy()
    bpy.data.images.remove(img)
    return a


def resize(arr, size):
    """Nearest/bilinear resample of an HxWxC array to size x size."""
    h, w = arr.shape[:2]
    ys = np.linspace(0, h - 1, size)
    xs = np.linspace(0, w - 1, size)
    y0 = np.floor(ys).astype(int); x0 = np.floor(xs).astype(int)
    y1 = np.minimum(y0 + 1, h - 1); x1 = np.minimum(x0 + 1, w - 1)
    fy = (ys - y0)[:, None, None]; fx = (xs - x0)[None, :, None]
    a = arr if arr.ndim == 3 else arr[..., None]
    top = a[y0][:, x0] * (1 - fx) + a[y0][:, x1] * fx
    bot = a[y1][:, x0] * (1 - fx) + a[y1][:, x1] * fx
    out = top * (1 - fy) + bot * fy
    return out if arr.ndim == 3 else out[..., 0]


def make_seamless(arr, softness=1.0):
    """Offset-and-blend tiling: the half-rolled copy is continuous across the wrap, the
    original hides the rolled copy's centre seams. The weight favours the rolled copy near
    the borders and the original near the centre cross."""
    h, w = arr.shape[:2]
    rolled = np.roll(np.roll(arr, h // 2, 0), w // 2, 1)
    y = np.arange(h, dtype=np.float32)[:, None] / h
    x = np.arange(w, dtype=np.float32)[None, :] / w
    db = np.minimum(np.minimum(x, 1 - x), np.minimum(y, 1 - y))
    dc = np.minimum(np.abs(x - 0.5), np.abs(y - 0.5))
    wa = db ** softness / (db ** softness + dc ** softness + 1e-6)
    wa = wa * wa * (3 - 2 * wa)
    if arr.ndim == 3:
        wa = wa[..., None]
    return arr * wa + rolled * (1 - wa)


def luminance(a):
    return a[..., 0] * 0.2126 + a[..., 1] * 0.7152 + a[..., 2] * 0.0722


def highpass(gray, radius=24):
    return gray - blur(gray, radius)


def blur(img, radius):
    """Separable box blur (3 passes ~ gaussian), wraps around (tileable)."""
    out = img.astype(np.float32)
    r = max(1, int(radius))
    for _ in range(3):
        for axis in (0, 1):
            c = np.cumsum(np.concatenate([out.take(range(-r - 1, 0), axis=axis), out,
                                          out.take(range(0, r), axis=axis)], axis=axis), axis=axis)
            n = out.shape[axis]
            hi = c.take(range(2 * r + 1, 2 * r + 1 + n), axis=axis)
            lo = c.take(range(0, n), axis=axis)
            out = (hi - lo) / (2 * r + 1)
    return out


def height_to_normal(height, strength=2.0):
    """Tangent-space normal map (OpenGL convention, +Y up) from a tileable height field."""
    dx = (np.roll(height, -1, 1) - np.roll(height, 1, 1)) * 0.5 * strength
    dy = (np.roll(height, -1, 0) - np.roll(height, 1, 0)) * 0.5 * strength
    n = np.stack([-dx, dy, np.ones_like(height)], -1)
    n /= np.linalg.norm(n, axis=-1, keepdims=True)
    return n * 0.5 + 0.5


def value_noise(size, cells, seed, octaves=1, persistence=0.5):
    """Tileable fractal value noise in 0..1 (size x size)."""
    r = rng(seed)
    out = np.zeros((size, size), np.float32)
    amp, total = 1.0, 0.0
    for o in range(octaves):
        c = cells * (2 ** o)
        grid = r.random((c, c)).astype(np.float32)
        t = np.linspace(0, c, size, endpoint=False)
        i0 = np.floor(t).astype(int) % c
        i1 = (i0 + 1) % c
        f = t - np.floor(t)
        f = f * f * (3 - 2 * f)
        a = grid[i0][:, i0] * (1 - f)[None, :] + grid[i0][:, i1] * f[None, :]
        b = grid[i1][:, i0] * (1 - f)[None, :] + grid[i1][:, i1] * f[None, :]
        out += (a * (1 - f)[:, None] + b * f[:, None]) * amp
        total += amp
        amp *= persistence
    return out / total


def worley(size, points, seed):
    """Tileable Worley (cellular) distance field, normalised 0..1."""
    r = rng(seed)
    p = r.random((points, 2)) * size
    yy, xx = np.mgrid[0:size, 0:size].astype(np.float32)
    d = np.full((size, size), 1e9, np.float32)
    for (px, py) in p:
        dx = np.abs(xx - px); dx = np.minimum(dx, size - dx)
        dy = np.abs(yy - py); dy = np.minimum(dy, size - dy)
        d = np.minimum(d, dx * dx + dy * dy)
    d = np.sqrt(d)
    return d / d.max()


# ---------------------------------------------------------------- materials

def new_material(name):
    m = bpy.data.materials.get(name)
    if m:
        bpy.data.materials.remove(m)
    m = bpy.data.materials.new(name)
    try:
        m.use_nodes = True
    except Exception:
        pass
    return m


def principled(m):
    return next(n for n in m.node_tree.nodes if n.type == 'BSDF_PRINCIPLED')


def tex_node(m, img, colorspace=None, loc=(-600, 0), uv='UVMap', interpolation='Linear'):
    nt = m.node_tree
    t = nt.nodes.new('ShaderNodeTexImage')
    t.image = img
    t.location = loc
    t.interpolation = interpolation
    if colorspace:
        img.colorspace_settings.name = colorspace
    if uv:
        u = nt.nodes.new('ShaderNodeUVMap')
        u.uv_map = uv
        u.location = (loc[0] - 250, loc[1])
        nt.links.new(u.outputs[0], t.inputs[0])
    return t


def pbr_material(name, base=None, normal=None, rough=None, metal=None, ao=None,
                 base_color=(0.8, 0.8, 0.8, 1), roughness=0.6, metallic=0.0, normal_strength=1.0,
                 uv='UVMap', alpha=None, emission=None, emission_strength=1.0):
    """Principled material wired so the glTF exporter picks up every map."""
    m = new_material(name)
    nt = m.node_tree
    p = principled(m)
    p.inputs['Base Color'].default_value = base_color
    p.inputs['Roughness'].default_value = roughness
    p.inputs['Metallic'].default_value = metallic
    y = 300
    if base is not None:
        t = tex_node(m, base, 'sRGB', (-700, y), uv)
        nt.links.new(t.outputs['Color'], p.inputs['Base Color'])
        if alpha == 'texture':
            nt.links.new(t.outputs['Alpha'], p.inputs['Alpha'])
            m.blend_method = 'HASHED' if hasattr(m, 'blend_method') else None
    y -= 300
    if rough is not None or metal is not None:
        # glTF wants roughness in G and metallic in B of one image
        if rough is not None:
            t = tex_node(m, rough, 'Non-Color', (-900, y), uv)
            sep = nt.nodes.new('ShaderNodeSeparateColor')
            sep.location = (-550, y)
            nt.links.new(t.outputs['Color'], sep.inputs[0])
            nt.links.new(sep.outputs['Green'], p.inputs['Roughness'])
            if metal is not None:
                nt.links.new(sep.outputs['Blue'], p.inputs['Metallic'])
    y -= 300
    if normal is not None:
        t = tex_node(m, normal, 'Non-Color', (-900, y), uv)
        nm = nt.nodes.new('ShaderNodeNormalMap')
        nm.location = (-400, y)
        nm.uv_map = uv
        nm.inputs['Strength'].default_value = normal_strength
        nt.links.new(t.outputs['Color'], nm.inputs['Color'])
        nt.links.new(nm.outputs['Normal'], p.inputs['Normal'])
    if emission is not None:
        p.inputs['Emission Color'].default_value = emission
        p.inputs['Emission Strength'].default_value = emission_strength
    if ao is not None:
        gltf_occlusion(m, ao, uv)
    return m


def gltf_occlusion(m, img, uv='UVMap'):
    """Adds the 'glTF Material Output' group the exporter reads the occlusion map from."""
    grp = bpy.data.node_groups.get('glTF Material Output')
    if grp is None:
        grp = bpy.data.node_groups.new('glTF Material Output', 'ShaderNodeTree')
        grp.interface.new_socket('Occlusion', in_out='INPUT', socket_type='NodeSocketFloat')
        grp.interface.new_socket('Thickness', in_out='INPUT', socket_type='NodeSocketFloat')
    nt = m.node_tree
    g = nt.nodes.new('ShaderNodeGroup')
    g.node_tree = grp
    g.location = (300, -400)
    t = tex_node(m, img, 'Non-Color', (-300, -700), uv)
    sep = nt.nodes.new('ShaderNodeSeparateColor')
    sep.location = (0, -700)
    nt.links.new(t.outputs['Color'], sep.inputs[0])
    nt.links.new(sep.outputs['Red'], g.inputs['Occlusion'])


def assign(obj, mat):
    obj.data.materials.clear()
    obj.data.materials.append(mat)


# ---------------------------------------------------------------- UVs

def box_uv(obj, scale=1.0, uv_name='UVMap'):
    """World-scale triplanar-style box projection written straight into a UV layer."""
    me = obj.data
    if uv_name not in me.uv_layers:
        me.uv_layers.new(name=uv_name)
    uv = me.uv_layers[uv_name]
    mw = obj.matrix_world
    nmat = mw.to_3x3().inverted().transposed()
    for poly in me.polygons:
        n = (nmat @ poly.normal).normalized()
        ax = max(range(3), key=lambda i: abs(n[i]))
        for li in poly.loop_indices:
            co = mw @ me.vertices[me.loops[li].vertex_index].co
            if ax == 0:
                u, v = co.y * (1 if n.x > 0 else -1), co.z
            elif ax == 1:
                u, v = co.x * (-1 if n.y > 0 else 1), co.z
            else:
                u, v = co.x, co.y * (1 if n.z > 0 else -1)
            uv.data[li].uv = (u / scale, v / scale)


def lightmap_uv(objs, name='Lightmap', margin=0.004):
    """Second UV set for baked lighting: smart-projected and packed across all objects."""
    for o in objs:
        me = o.data
        if name not in me.uv_layers:
            me.uv_layers.new(name=name)
        me.uv_layers.active = me.uv_layers[name]
    deselect_all()
    for o in objs:
        o.select_set(True)
    bpy.context.view_layer.objects.active = objs[0]
    bpy.ops.object.mode_set(mode='EDIT')
    bpy.ops.mesh.select_all(action='SELECT')
    bpy.ops.uv.smart_project(angle_limit=math.radians(50), island_margin=margin, area_weight=0.0,
                             correct_aspect=True, scale_to_bounds=False)
    bpy.ops.uv.average_islands_scale()
    bpy.ops.uv.pack_islands(margin=margin, rotate=True, shape_method='CONCAVE')
    bpy.ops.object.mode_set(mode='OBJECT')
    for o in objs:
        o.data.uv_layers.active = o.data.uv_layers[0]


# ---------------------------------------------------------------- render / preview

def use_gpu():
    try:
        prefs = bpy.context.preferences.addons['cycles'].preferences
        for t in ('OPTIX', 'CUDA'):
            try:
                prefs.compute_device_type = t
                prefs.refresh_devices()
                if any(d.type != 'CPU' for d in prefs.devices):
                    break
            except Exception:
                continue
        for d in prefs.devices:
            d.use = d.type != 'CPU'
        bpy.context.scene.cycles.device = 'GPU'
    except Exception as e:
        print("GPU setup failed, using CPU:", e)


def cycles(samples=128, denoise=True):
    scn = bpy.context.scene
    scn.render.engine = 'CYCLES'
    use_gpu()
    scn.cycles.samples = samples if not FAST else max(16, samples // 8)
    scn.cycles.use_denoising = denoise
    scn.view_settings.view_transform = 'AgX'
    scn.view_settings.look = 'None'
    return scn


def camera(name, loc, target, lens=50, coll=None):
    cam = bpy.data.cameras.new(name)
    cam.lens = lens
    ob = bpy.data.objects.new(name, cam)
    link(ob, coll)
    ob.location = loc
    look_at(ob, target)
    bpy.context.scene.camera = ob
    return ob


def look_at(ob, target):
    d = Vector(target) - ob.location
    ob.rotation_euler = d.to_track_quat('-Z', 'Y').to_euler()


def render_to(path, res=(1280, 720), samples=None):
    scn = bpy.context.scene
    scn.render.resolution_x, scn.render.resolution_y = res
    scn.render.resolution_percentage = 100
    if samples and scn.render.engine == 'CYCLES':
        scn.cycles.samples = samples
    scn.render.image_settings.file_format = 'PNG'
    scn.render.filepath = path
    bpy.ops.render.render(write_still=True)
    return path


def frame_view(obj_names=None):
    """Frame the live viewport on objects so the viewer can watch the build (no-op headless)."""
    if bpy.app.background:
        return
    try:
        wm = bpy.context.window_manager
        for win in wm.windows:
            for area in win.screen.areas:
                if area.type != 'VIEW_3D':
                    continue
                for space in area.spaces:
                    if space.type == 'VIEW_3D':
                        space.shading.type = 'MATERIAL' if space.shading.type == 'RENDERED' else space.shading.type
                region = next(r for r in area.regions if r.type == 'WINDOW')
                with bpy.context.temp_override(window=win, area=area, region=region):
                    if obj_names:
                        for o in bpy.context.view_layer.objects:
                            o.select_set(o.name in obj_names)
                        bpy.ops.view3d.view_selected()
                    else:
                        bpy.ops.view3d.view_all()
    except Exception as e:
        print("frame_view:", e)


def set_shading(kind='SOLID'):
    if bpy.app.background:
        return
    for win in bpy.context.window_manager.windows:
        for area in win.screen.areas:
            if area.type == 'VIEW_3D':
                for space in area.spaces:
                    if space.type == 'VIEW_3D':
                        space.shading.type = kind


def redraw():
    if bpy.app.background:
        return
    try:
        bpy.ops.wm.redraw_timer(type='DRAW_WIN_SWAP', iterations=1)
    except Exception:
        pass


# ---------------------------------------------------------------- export

def export_glb(path, objects=None, animations=False, extra=None):
    deselect_all()
    if objects:
        for o in objects:
            o.select_set(True)
    kw = dict(filepath=path, export_format='GLB', use_selection=bool(objects),
              export_apply=True, export_texcoords=True, export_normals=True,
              export_tangents=False, export_materials='EXPORT', export_yup=True,
              export_animations=animations, export_image_format='AUTO')
    if extra:
        kw.update(extra)
    bpy.ops.export_scene.gltf(**kw)
    print("exported", path, os.path.getsize(path) // 1024, "KB")
    return path


def save_blend(name):
    path = os.path.join(WORK, name + ".blend")
    bpy.ops.wm.save_as_mainfile(filepath=path, check_existing=False, copy=True)
    return path


def preview(path, loc, target, lens=50, res=(800, 800), engine='BLENDER_EEVEE', samples=16,
            light=True, world=0.35):
    """Quick look render with a temporary camera (+ key light) used while developing."""
    scn = bpy.context.scene
    old_cam, old_engine = scn.camera, scn.render.engine
    cam = camera("_preview_cam", loc, target, lens)
    tmp = [cam]
    if light:
        for i, (l, e, s) in enumerate((((2.5, -3.0, 3.0), 600, 2.0), ((-3, -1.5, 2.2), 250, 3.0), ((0.5, 3.5, 2.8), 400, 1.5))):
            ld = bpy.data.lights.new(f"_prev_light{i}", 'AREA')
            ld.energy = e
            ld.size = s
            lo = bpy.data.objects.new(f"_prev_light{i}", ld)
            link(lo)
            lo.location = Vector(target) + Vector(l)
            look_at(lo, target)
            tmp.append(lo)
    if scn.world is None:
        scn.world = bpy.data.worlds.new("World")
    try:
        scn.world.use_nodes = True
    except Exception:
        pass
    bg = scn.world.node_tree.nodes.get("Background")
    if bg:
        bg.inputs[0].default_value = (world, world, world, 1)
        bg.inputs[1].default_value = 1.0
    scn.render.engine = engine
    if engine == 'CYCLES':
        use_gpu()
        scn.cycles.samples = samples
        scn.cycles.use_denoising = True
    else:
        try:
            scn.eevee.taa_render_samples = samples
        except Exception:
            pass
    scn.view_settings.view_transform = 'AgX'
    render_to(path, res)
    for o in tmp:
        bpy.data.objects.remove(o, do_unlink=True)
    scn.camera, scn.render.engine = old_cam, old_engine
    return path


# ---------------------------------------------------------------- baking

def float_image(name, size, alpha=True):
    img = bpy.data.images.get(name)
    if img:
        bpy.data.images.remove(img)
    img = bpy.data.images.new(name, size, size, alpha=alpha, float_buffer=True)
    img.colorspace_settings.name = 'Non-Color'
    return img


def bake(obj, img, build_shader, bake_type='EMIT', samples=1, margin=16, uv='UVMap',
         pass_filter=None, keep_materials=False, selected_to_active=None):
    """Bake into img. build_shader(nodetree) must return the socket to emit (EMIT bakes) or
    None when the tree already has its surface wired (NORMAL/DIFFUSE/AO bakes).
    When keep_materials is True the object's own materials are used and only an image
    node is added to each of them."""
    scn = bpy.context.scene
    scn.render.engine = 'CYCLES'
    use_gpu()
    scn.cycles.samples = samples
    scn.cycles.use_denoising = False
    scn.render.bake.margin = margin
    scn.render.bake.margin_type = 'EXTEND'
    scn.render.bake.use_clear = True
    scn.render.bake.target = 'IMAGE_TEXTURES'
    saved = [s.material for s in obj.material_slots]
    added = []
    if not keep_materials:
        m = new_material("_bake_" + obj.name)
        nt = m.node_tree
        for n in list(nt.nodes):
            nt.nodes.remove(n)
        out = nt.nodes.new('ShaderNodeOutputMaterial')
        sock = build_shader(nt)
        if sock is not None:
            em = nt.nodes.new('ShaderNodeEmission')
            nt.links.new(sock, em.inputs['Color'])
            nt.links.new(em.outputs[0], out.inputs['Surface'])
        if len(obj.material_slots) == 0:
            obj.data.materials.append(m)
        for s in obj.material_slots:
            s.material = m
        mats = [m]
    else:
        mats = list({s.material for s in obj.material_slots if s.material})
    for m in mats:
        t = m.node_tree.nodes.new('ShaderNodeTexImage')
        t.image = img
        t.name = "_bake_target"
        m.node_tree.nodes.active = t
        added.append((m, t))
    obj.data.uv_layers.active = obj.data.uv_layers[uv]
    deselect_all()
    if selected_to_active:
        for o in selected_to_active:
            o.select_set(True)
    obj.select_set(True)
    bpy.context.view_layer.objects.active = obj
    kw = dict(type=bake_type, margin=margin, use_clear=True)
    if pass_filter:
        kw['pass_filter'] = pass_filter
    if selected_to_active:
        kw.update(use_selected_to_active=True, cage_extrusion=0.02, max_ray_distance=0.05)
    bpy.ops.object.bake(**kw)
    for m, t in added:
        m.node_tree.nodes.remove(t)
    if not keep_materials:
        for s, old in zip(obj.material_slots, saved + [None] * len(obj.material_slots)):
            s.material = old
        if not saved:
            obj.data.materials.clear()
        bpy.data.materials.remove(mats[0])
    obj.data.uv_layers.active = obj.data.uv_layers[0]
    return img


def attr_node(nt, name, loc=(-400, 0)):
    a = nt.nodes.new('ShaderNodeAttribute')
    a.attribute_name = name
    a.location = loc
    return a


def encode_vec(nt, sock, offset, scale):
    """(v + offset) * scale via a Vector Math chain, for baking signed data into 0..1."""
    add = nt.nodes.new('ShaderNodeVectorMath'); add.operation = 'ADD'
    add.inputs[1].default_value = offset
    nt.links.new(sock, add.inputs[0])
    mul = nt.nodes.new('ShaderNodeVectorMath'); mul.operation = 'MULTIPLY'
    mul.inputs[1].default_value = scale
    nt.links.new(add.outputs[0], mul.inputs[0])
    return mul.outputs[0]


def show(objects=None, shading='MATERIAL', azimuth=35.0, elevation=12.0, margin=1.25,
         focus=None, distance=None):
    """Point the live viewport at what is being built: Material Preview shading, a three-
    quarter view, framed on the objects' bounds. Does nothing in background builds."""
    if bpy.app.background:
        return
    objs = [o for o in (objects or bpy.context.scene.objects) if o and o.type in ('MESH', 'CURVE', 'ARMATURE', 'EMPTY')]
    if not objs and focus is None:
        return
    if focus is None:
        pts = []
        for o in objs:
            if o.type == 'MESH' or o.type == 'CURVE':
                pts += [o.matrix_world @ Vector(c) for c in o.bound_box]
            else:
                pts.append(o.matrix_world.translation)
        lo = Vector((min(p.x for p in pts), min(p.y for p in pts), min(p.z for p in pts)))
        hi = Vector((max(p.x for p in pts), max(p.y for p in pts), max(p.z for p in pts)))
        focus = (lo + hi) / 2
        radius = (hi - lo).length / 2
    else:
        focus = Vector(focus)
        radius = distance or 2.0
    from mathutils import Euler
    rot = Euler((math.radians(90 - elevation), 0, math.radians(azimuth)), 'XYZ').to_quaternion()
    for win in bpy.context.window_manager.windows:
        for area in win.screen.areas:
            if area.type != 'VIEW_3D':
                continue
            for space in area.spaces:
                if space.type != 'VIEW_3D':
                    continue
                space.shading.type = shading
                if shading == 'SOLID':
                    space.shading.color_type = 'MATERIAL'
                space.overlay.show_relationship_lines = False
                space.overlay.show_extras = False
                space.overlay.show_bones = False
                r3d = space.region_3d
                if r3d.view_perspective == 'CAMERA':
                    r3d.view_perspective = 'PERSP'
                r3d.view_location = focus
                r3d.view_rotation = rot
                r3d.view_distance = distance or max(0.3, radius * margin * 2.2)
                space.lens = 50
            area.tag_redraw()
    deselect_all()
    redraw()
