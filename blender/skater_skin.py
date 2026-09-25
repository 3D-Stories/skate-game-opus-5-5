"""Skater stage 3: physically based skin.

1. Face landmarks and soft region masks (lips, redness, stubble, brows, scalp, nails, under-
   eye) are computed per vertex and stored as colour attributes.
2. Cycles bakes object-space position, normal and the masks into the MakeHuman UV layout.
3. numpy composes the final albedo, roughness and a tangent-space normal map with pores:
   the imagegen skin macro photo is projected triplanar in 3D so pores keep real scale.
4. The render material is a Principled BSDF with random-walk subsurface scattering; the
   game shader (Godot) fakes the SSS with wrapped red-shifted diffuse.
"""
import math

import bpy
import numpy as np
from mathutils import Vector

from lib import common as C


def _vertex_array(obj):
    co = np.empty(len(obj.data.vertices) * 3, np.float32)
    obj.data.vertices.foreach_get('co', co)
    return co.reshape(-1, 3)


def _group_weights(obj, name):
    w = np.zeros(len(obj.data.vertices), np.float32)
    g = obj.vertex_groups.get(name)
    if g is None:
        return w
    gi = g.index
    for v in obj.data.vertices:
        for e in v.groups:
            if e.group == gi:
                w[v.index] = e.weight
    return w


def _neighbours(obj):
    me = obj.data
    e = np.empty(len(me.edges) * 2, np.int32)
    me.edges.foreach_get('vertices', e)
    return e.reshape(-1, 2)


def smooth_field(field, edges, iterations=6):
    f = field.astype(np.float32).copy()
    n = len(f)
    for _ in range(iterations):
        acc = np.zeros_like(f)
        cnt = np.zeros(n, np.float32)
        np.add.at(acc, edges[:, 0], f[edges[:, 1]])
        np.add.at(acc, edges[:, 1], f[edges[:, 0]])
        np.add.at(cnt, edges[:, 0], 1)
        np.add.at(cnt, edges[:, 1], 1)
        f = 0.5 * f + 0.5 * acc / np.maximum(cnt, 1)[:, None] if f.ndim == 2 else 0.5 * f + 0.5 * acc / np.maximum(cnt, 1)
    return f


def sstep(e0, e1, x):
    t = np.clip((x - e0) / (e1 - e0), 0, 1)
    return t * t * (3 - 2 * t)


def landmarks(body, face):
    co = _vertex_array(body)
    el = np.array(face['eye_L'][0]); er = np.array(face['eye_R'][0])
    lips = _group_weights(body, 'lips') > 0.5
    mouth = co[lips].mean(0)
    front = co[(np.abs(co[:, 0]) < 0.01) & (co[:, 2] > mouth[2]) & (co[:, 2] < el[2])]
    nose_tip = front[np.argmin(front[:, 1])]
    chin_pts = co[(np.abs(co[:, 0]) < 0.01) & (co[:, 2] < mouth[2] - 0.028) & (co[:, 2] > mouth[2] - 0.06)]
    chin = chin_pts[np.argmin(chin_pts[:, 1])]
    return dict(eye_l=el, eye_r=er, mouth=mouth, nose=nose_tip, chin=chin,
                eye_mid=(el + er) / 2)


def vertex_masks(body, lm):
    co = _vertex_array(body)
    edges = _neighbours(body)
    x, y, z = co[:, 0], co[:, 1], co[:, 2]
    ax = np.abs(x)
    eye_z = lm['eye_l'][2]
    eye_x = abs(lm['eye_l'][0])
    head = _group_weights(body, 'head')
    neck = _group_weights(body, 'neck_01')
    frontness = sstep(0.0, -0.08, y - lm['eye_mid'][1] + 0.09)  # 1 on the face plane

    lips = smooth_field(_group_weights(body, 'lips'), edges, 4)

    def blob(c, r):
        d = np.linalg.norm(co - np.array(c), axis=1)
        return np.exp(-(d / r) ** 2)

    cheek_l = lm['eye_l'] + np.array([0.012, -0.012, -0.035])
    cheek_r = lm['eye_r'] + np.array([-0.012, -0.012, -0.035])
    red = 0.55 * blob(cheek_l, 0.025) + 0.55 * blob(cheek_r, 0.025) + 0.6 * blob(lm['nose'], 0.016)
    red += 0.5 * smooth_field(_group_weights(body, 'ears'), edges, 3)
    red += 0.25 * blob(lm['chin'], 0.02)
    red += 0.25 * (blob(lm['eye_l'], 0.02) + blob(lm['eye_r'], 0.02))  # lids
    red = np.clip(red, 0, 1)

    # stubble: lower face and upper lip, sideburns in front of the ears, fading under the jaw
    mz = lm['mouth'][2]
    stub = sstep(eye_z - 0.035, eye_z - 0.055, z) * sstep(0.075, 0.062, ax)
    stub *= np.maximum(head, neck * 0.9)
    under_jaw = sstep(mz - 0.11, mz - 0.075, z)
    stub *= under_jaw
    side = sstep(eye_x + 0.045, eye_x + 0.055, ax) * sstep(eye_z + 0.02, eye_z - 0.0, z) * sstep(mz - 0.03, mz - 0.01, z)
    stub = np.maximum(stub, side * head)
    # cheeks above the beard line stay clean
    cheek_clear = 1 - sstep(mz + 0.004, mz + 0.03, z) * sstep(0.022, 0.03, ax)
    stub *= cheek_clear
    stub *= (1 - np.clip(lips * 1.6, 0, 1))
    stub = smooth_field(stub, edges, 3)

    # brows: same arc the brow cards use
    brow = np.zeros(len(co), np.float32)
    for s, e in ((1, lm['eye_l']), (-1, lm['eye_r'])):
        t = (s * (x - e[0]) + 0.013) / 0.041
        arc = 0.0165 + 0.0055 * np.sin(np.pi * np.clip(t * 1.25, 0, 1)) - 0.004 * t
        thick = 0.0085 * (1 - 0.6 * np.clip(t, 0, 1))
        d = np.abs(z - (e[2] + arc)) / (thick * 0.6)
        brow = np.maximum(brow, np.exp(-d * d) * sstep(-0.1, 0.05, t) * sstep(1.1, 0.9, t) * frontness)

    scalp = smooth_field(_group_weights(body, 'scalp'), edges, 8)
    scalp = np.clip(scalp * 1.4, 0, 1)
    nails = np.maximum(_group_weights(body, 'fingernails'), _group_weights(body, 'toenails'))
    under_eye = sum(np.exp(-((co[:, 0] - e[0]) ** 2 / 0.013 ** 2 + (co[:, 2] - (e[2] - 0.014)) ** 2 / 0.006 ** 2))
                    for e in (lm['eye_l'], lm['eye_r'])) * frontness
    tzone = (sstep(eye_z + 0.02, eye_z + 0.035, z) * (1 - scalp) + sstep(0.02, 0.0, ax) * sstep(lm['nose'][2] - 0.02, lm['nose'][2], z) * sstep(eye_z + 0.02, eye_z, z)) * frontness * head

    for name, data in (("skin_m1", np.stack([lips, red, stub, brow], 1)),
                       ("skin_m2", np.stack([scalp, nails, np.clip(under_eye, 0, 1), np.clip(tzone, 0, 1)], 1))):
        a = body.data.color_attributes.get(name)
        if a:
            body.data.color_attributes.remove(a)
        a = body.data.color_attributes.new(name, 'FLOAT_COLOR', 'POINT')
        a.data.foreach_set('color', np.clip(data, 0, 1).astype(np.float32).ravel())
    return dict(lips=lips, red=red, stub=stub, brow=brow, scalp=scalp)


def bake_maps(body, size):
    """Bake position / normal / masks (floats) into the body UV layout."""
    maps = {}

    def pos_shader(nt):
        g = nt.nodes.new('ShaderNodeNewGeometry')
        return C.encode_vec(nt, g.outputs['Position'], (1.0, 1.0, 0.0), (0.5, 0.5, 0.5))

    def nrm_shader(nt):
        g = nt.nodes.new('ShaderNodeNewGeometry')
        return C.encode_vec(nt, g.outputs['Normal'], (1.0, 1.0, 1.0), (0.5, 0.5, 0.5))

    def attr_shader(name):
        def f(nt):
            return C.attr_node(nt, name).outputs['Color']
        return f

    for key, fn in (("pos", pos_shader), ("nrm", nrm_shader),
                    ("m1", attr_shader("skin_m1")), ("m2", attr_shader("skin_m2"))):
        img = C.float_image("_bake_" + key, size)
        C.bake(body, img, fn, samples=1, margin=24)
        maps[key] = C.image_array(img)
        bpy.data.images.remove(img)
    # coverage: texels inside any UV island (margin texels are extended copies)
    return maps


def triplanar(tile, pos, nrm, scale, sharp=4.0):
    """Sample a tileable HxWxC image in 3D. pos/nrm: (N,3). scale: metres per tile."""
    th, tw = tile.shape[:2]
    w = np.abs(nrm) ** sharp
    w /= w.sum(1, keepdims=True) + 1e-8
    out = 0
    for ax, (a, b) in enumerate(((1, 2), (0, 2), (0, 1))):
        u = (pos[:, a] / scale) % 1.0
        v = (pos[:, b] / scale) % 1.0
        s = tile[(v * th).astype(np.int32) % th, (u * tw).astype(np.int32) % tw]
        out = out + s * (w[:, ax:ax + 1] if s.ndim == 2 else w[:, ax])
    return out


def compose(maps, size, lm):
    pos = maps['pos'][..., :3].reshape(-1, 3) * 2 - np.array([1.0, 1.0, 0.0])
    nrm = maps['nrm'][..., :3].reshape(-1, 3) * 2 - 1
    m1 = maps['m1'].reshape(-1, 4)
    m2 = maps['m2'].reshape(-1, 4)
    lips, red, stub, brow = m1.T
    scalp, nails, under_eye, tzone = m2.T

    pores_rgb = C.src_array("skin_pores", 1024)
    pores_rgb = C.make_seamless(pores_rgb)
    lum = C.luminance(pores_rgb)
    pore_h = C.highpass(lum, 10)
    pore_h = (pore_h - pore_h.mean()) / (pore_h.std() + 1e-6)
    chroma = pores_rgb / (lum[..., None] + 1e-4)
    chroma = C.blur(chroma, 6)
    chroma = chroma / chroma.reshape(-1, 3).mean(0)

    n_lo = C.value_noise(512, 4, 21, 4)
    n_mid = C.value_noise(512, 16, 22, 3)
    dots = C.rng(23).random((512, 512)).astype(np.float32)
    stub_dots = (dots > 0.82).astype(np.float32)
    stub_dots = np.maximum(stub_dots, np.roll(stub_dots, 1, 0) * 0.6)
    moles = (C.rng(24).random((1024, 1024)) > 0.99994).astype(np.float32)
    moles = np.clip(C.blur(moles, 2) * 60, 0, 1)

    p_scale = 0.035
    ph = triplanar(pore_h, pos, nrm, p_scale)
    pc = triplanar(chroma, pos, nrm, p_scale * 3.1)
    lo = triplanar(n_lo, pos, nrm, 0.35)
    mid = triplanar(n_mid, pos, nrm, 0.12)
    sd = triplanar(stub_dots, pos, nrm, 0.02, sharp=8)
    ml = triplanar(moles, pos, nrm, 0.5)

    base = np.array([0.56, 0.31, 0.21], np.float32)  # linear, warm light-medium tone
    col = np.tile(base, (len(pos), 1))
    col *= (0.93 + 0.14 * lo)[:, None]
    col *= (0.97 + 0.06 * mid)[:, None]
    col = col * (0.85 + 0.15 * np.clip(pc, 0.6, 1.4))
    col = col * (1 - red[:, None] * 0.28) + np.array([0.58, 0.20, 0.15]) * red[:, None] * 0.28
    col = col * (1 - under_eye[:, None] * 0.3) + np.array([0.28, 0.16, 0.17]) * under_eye[:, None] * 0.3
    # eye sockets and upper-lid creases sit slightly darker and cooler than the cheeks
    orbit = sum(np.exp(-((pos[:, 0] - e[0]) ** 2 / 0.022 ** 2 + (pos[:, 2] - (e[2] + 0.004)) ** 2 / 0.016 ** 2))
                for e in (lm['eye_l'], lm['eye_r']))
    orbit = np.clip(orbit, 0, 1) * (pos[:, 1] < lm['eye_mid'][1] + 0.03)
    col = col * (1 - orbit[:, None] * 0.16) + np.array([0.33, 0.19, 0.18]) * orbit[:, None] * 0.16
    lip_col = np.array([0.15, 0.048, 0.05])
    col = col * (1 - lips[:, None] * 0.8) + lip_col * lips[:, None] * 0.8
    col *= (1 - 0.035 * np.clip(ph, -2, 2) * (1 - lips))[:, None]
    hair = np.array([0.035, 0.024, 0.018])
    col = col * (1 - stub[:, None] * 0.2) + np.array([0.26, 0.22, 0.22]) * stub[:, None] * 0.2
    col = col * (1 - (stub * sd * 0.65)[:, None]) + hair * (stub * sd * 0.65)[:, None]
    bn = brow * (0.55 + 0.45 * triplanar(dots, pos, nrm, 0.01))
    col = col * (1 - bn[:, None] * 0.7) + hair * bn[:, None] * 0.7
    col = col * (1 - scalp[:, None] * 0.9) + hair * scalp[:, None] * 0.9
    col = col * (1 - nails[:, None] * 0.5) + np.array([0.70, 0.52, 0.48]) * nails[:, None] * 0.5
    col = col * (1 - ml[:, None] * 0.6) + np.array([0.16, 0.08, 0.06]) * ml[:, None] * 0.6

    rough = 0.6 - 0.08 * tzone + 0.1 * stub + 0.15 * scalp - 0.1 * nails + 0.03 * np.clip(ph, -1, 2)
    # height: pores everywhere (weaker on lips), lip creases, forehead lines
    height = ph * (1 - 0.7 * lips) * 0.45
    lip_crease = np.sin(pos[:, 0] * 2 * np.pi / 0.0016) * lips * 0.6
    fore = tzone * np.sin(pos[:, 2] * 2 * np.pi / 0.011) * 0.35 * (1 - scalp)
    height = height + lip_crease + fore + stub * sd * 0.8

    albedo = np.clip(col, 0, 1).reshape(size, size, 3)
    albedo_srgb = np.where(albedo <= 0.0031308, albedo * 12.92, 1.055 * np.power(albedo, 1 / 2.4) - 0.055)
    rough = np.clip(rough, 0.05, 1).reshape(size, size)
    height = height.reshape(size, size)
    return albedo_srgb, rough, height


def build(body, face, size=None):
    size = size or (2048 if C.FAST else 4096)
    lm = landmarks(body, face)
    vertex_masks(body, lm)
    maps = bake_maps(body, size)
    alb, rough, height = compose(maps, size, lm)
    normal = C.height_to_normal(height, strength=0.38 * size / 4096)
    img_a = C.save_png(alb, "skin_albedo")
    img_r = C.save_png(np.stack([np.ones_like(rough), rough, np.zeros_like(rough)], -1), "skin_rough", 'Non-Color')
    img_n = C.save_png(normal, "skin_normal", 'Non-Color')
    m = C.pbr_material("Skin", base=img_a, rough=img_r, normal=img_n, normal_strength=1.0)
    p = C.principled(m)
    p.inputs['Subsurface Weight'].default_value = 1.0
    p.inputs['Subsurface Radius'].default_value = (1.0, 0.4, 0.25)
    # mean free path ~4 mm red / 1.6 mm green / 1 mm blue (measured skin), not a waxy glow
    p.inputs['Subsurface Scale'].default_value = 0.0042
    p.inputs['Specular IOR Level'].default_value = 0.42
    p.inputs['IOR'].default_value = 1.4
    try:
        p.subsurface_method = 'RANDOM_WALK_SKIN'
    except Exception:
        pass
    p.inputs['Sheen Weight'].default_value = 0.05
    C.assign(body, m)
    return m, lm
