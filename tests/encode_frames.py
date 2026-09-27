"""Encode a folder of PNG or JPEG frames (Godot's --write-movie, tests/frames.gd) as an H.264 MP4 with
Blender's own FFmpeg (there is no ffmpeg binary on this machine), same settings as the
turntables in blender/renders.py:

    blender --background --python tests/encode_frames.py -- <frames_dir> <out.mp4> [fps] [scale]
"""
import os
import sys

import bpy

argv = sys.argv[sys.argv.index("--") + 1:]
src, dst = argv[0], os.path.abspath(argv[1])
fps = int(argv[2]) if len(argv) > 2 else 30
scale = float(argv[3]) if len(argv) > 3 else 1.0
files = sorted(f for f in os.listdir(src) if f.lower().endswith((".png", ".jpg")))
if not files:
    raise SystemExit(f"no PNG or JPEG frames in {src}")
scn = bpy.context.scene
ed = scn.sequence_editor_create()
strips = ed.strips if hasattr(ed, "strips") else ed.sequences
st = strips.new_image("frames", os.path.join(src, files[0]), 1, 1)
for f in files[1:]:
    st.elements.append(f)
img = bpy.data.images.load(os.path.join(src, files[0]))
w, h = img.size
scn.render.resolution_x = int(w * scale) // 2 * 2
scn.render.resolution_y = int(h * scale) // 2 * 2
scn.render.resolution_percentage = 100
scn.render.fps = fps
scn.frame_start = 1
scn.frame_end = len(files)
if hasattr(scn.render.image_settings, "media_type"):
    scn.render.image_settings.media_type = 'VIDEO'      # Blender 5: video is its own media type
scn.render.image_settings.file_format = 'FFMPEG'
scn.render.ffmpeg.format = 'MPEG4'
scn.render.ffmpeg.codec = 'H264'
scn.render.ffmpeg.constant_rate_factor = 'HIGH'
stem = os.path.splitext(dst)[0]
scn.render.filepath = stem
bpy.ops.render.render(animation=True)
# (Blender names the file <stem><first>-<last>.mp4)
made = f"{stem}{scn.frame_start:04d}-{scn.frame_end:04d}.mp4"
if os.path.exists(made):
    os.replace(made, dst)
print(f"[encode] {len(files)} frames at {fps} fps -> {dst}")
