#!/usr/bin/env bash
# Screenshots of the Windows build running natively on this PC, with both renderers:
#
#   bash desktop/shots_windows.sh      -> evidence/windows_*.jpg, tests/results/windows/shots.txt
#
# For OpenGL 3.3 and for ANGLE on Direct3D 11: the start screen (the game's own frame,
# --shots), and the scripted run with a frame every 15 run seconds and the end screen. The
# run is the same on both (fixed physics steps), so the frames at a given run second match up;
# evidence/windows_gl_vs_angle.jpg puts pairs side by side and shots.txt gives the mean pixel
# difference of each pair (0-255 per channel).
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
RES="$ROOT/tests/results/windows"
EV="$ROOT/evidence"
W=/mnt/c/Temp/ProSkater/out
for d in opengl3 opengl3_angle; do
	tag=$([ $d = opengl3 ] && echo gl || echo angle)
	rm -rf "$W/shots_$tag"
	bash desktop/run_windows.sh "look_$tag" --rendering-driver $d --quit-after 900 -- "--shots={out}/shots_$tag"
	bash desktop/run_windows.sh "run_$tag" --rendering-driver $d -- --autopilot --quit-at-end "--shots={out}/shots_$tag" --shot-every=15
done
python3 - "$W" "$EV" <<'EOF' | tee "$RES/shots.txt"
import os, sys
from PIL import Image, ImageChops, ImageDraw, ImageStat
w, ev = sys.argv[1:]
gl, an = os.path.join(w, "shots_gl"), os.path.join(w, "shots_angle")
names = sorted(set(os.listdir(gl)) & set(os.listdir(an)))
print("screenshots of the Windows build (1920x1080 window), OpenGL 3.3 vs ANGLE on Direct3D 11:")
for n in names:
    a = Image.open(os.path.join(gl, n)).convert("RGB")
    b = Image.open(os.path.join(an, n)).convert("RGB")
    diff = ImageStat.Stat(ImageChops.difference(a, b)).mean if a.size == b.size else None
    print("  %-18s %s  %s  mean difference %s" % (n, "x".join(map(str, a.size)), "x".join(map(str, b.size)),
          "%.1f / %.1f / %.1f" % tuple(diff) if diff else "(sizes differ)"))
keep = ["start_screen.png", "run_015s.png", "run_030s.png", "run_060s.png", "run_105s.png", "end_screen.png"]
for n in keep:
    if os.path.exists(os.path.join(gl, n)):
        Image.open(os.path.join(gl, n)).convert("RGB").save(os.path.join(ev, "windows_" + n.replace(".png", ".jpg")), quality=88)
pairs = [n for n in ["start_screen.png", "run_030s.png", "run_060s.png"] if n in names]
tw, th = 960, 540
sheet = Image.new("RGB", (tw * 2 + 30, (th + 40) * len(pairs) + 10), (20, 20, 22))
d = ImageDraw.Draw(sheet)
for i, n in enumerate(pairs):
    y = 10 + i * (th + 40)
    for j, (src, label) in enumerate([(gl, "OpenGL 3.3"), (an, "ANGLE, Direct3D 11")]):
        sheet.paste(Image.open(os.path.join(src, n)).convert("RGB").resize((tw, th), Image.LANCZOS), (10 + j * (tw + 10), y + 30))
        d.text((10 + j * (tw + 10), y + 8), "%s  -  %s" % (label, n.replace(".png", "")), fill=(255, 210, 31))
sheet.save(os.path.join(ev, "windows_gl_vs_angle.jpg"), quality=88)
print("evidence: " + ", ".join(sorted(f for f in os.listdir(ev) if f.startswith("windows_"))))
EOF
