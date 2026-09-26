#!/usr/bin/env python3
"""Contact sheets from a tests/frames.gd capture: consecutive frames in a grid, each
labelled with its frame number, run time, state and the detector flags (red border).

  python3 tests/frames_sheet.py /tmp/skate-work/frames/windows --flagged        # a strip around every flagged frame
  python3 tests/frames_sheet.py /tmp/skate-work/frames/windows --from 24.7 --to 25.0
  python3 tests/frames_sheet.py DIR --from 24.7 --to 25.0 --crop 0.25,0.1,0.75,0.9 --cols 4
Sheets are written next to the frames (sheet_*.jpg) and their paths printed.
"""
import argparse
import json
import os

from PIL import Image, ImageDraw, ImageFont

ap = argparse.ArgumentParser()
ap.add_argument("dir")
ap.add_argument("--from", dest="t0", type=float)
ap.add_argument("--to", dest="t1", type=float)
ap.add_argument("--flagged", action="store_true", help="one strip of --around frames each side of every flagged frame")
ap.add_argument("--around", type=int, default=3)
ap.add_argument("--cols", type=int, default=4)
ap.add_argument("--width", type=int, default=640, help="tile width in px")
ap.add_argument("--crop", help="x0,y0,x1,y1 as fractions of the frame")
ap.add_argument("--max", type=int, default=24, help="tiles per sheet")
a = ap.parse_args()

rows = [r for r in (json.loads(line) for line in open(os.path.join(a.dir, "frames.jsonl"))) if "img" in r]
try:
    font = ImageFont.truetype("/usr/share/fonts/truetype/dejavu/DejaVuSansMono.ttf", 15)
except OSError:
    font = ImageFont.load_default()


def tile(r):
    im = Image.open(os.path.join(a.dir, r["img"])).convert("RGB")
    if a.crop:
        x0, y0, x1, y1 = (float(v) for v in a.crop.split(","))
        w, h = im.size
        im = im.crop((int(x0 * w), int(y0 * h), int(x1 * w), int(y1 * h)))
    im = im.resize((a.width, int(im.height * a.width / im.width)))
    d = ImageDraw.Draw(im)
    txt = "f%d t=%.3f st=%s %s d=%.2fm %.1fdeg" % (r["frame"], r["t"], r["state"], r["rail"], r["dpos"], r["drot"])
    d.rectangle((0, 0, im.width, 20), fill=(0, 0, 0))
    d.text((4, 2), txt, fill=(255, 255, 255), font=font)
    if r.get("flags"):
        d.rectangle((0, 0, im.width - 1, im.height - 1), outline=(255, 0, 0), width=4)
        d.rectangle((0, im.height - 20, im.width, im.height), fill=(120, 0, 0))
        d.text((4, im.height - 18), "; ".join(r["flags"])[:90], fill=(255, 255, 255), font=font)
    return im


def sheet(sel, name):
    sel = sel[: a.max]
    if not sel:
        return
    tiles = [tile(r) for r in sel]
    tw, th = tiles[0].size
    cols = min(a.cols, len(tiles))
    rows_n = (len(tiles) + cols - 1) // cols
    out = Image.new("RGB", (cols * tw, rows_n * th), (30, 30, 30))
    for i, t in enumerate(tiles):
        out.paste(t, ((i % cols) * tw, (i // cols) * th))
    p = os.path.join(a.dir, name)
    out.save(p, quality=88)
    print(p)


if a.flagged:
    idx = [i for i, r in enumerate(rows) if r.get("flags")]
    done = set()
    for i in idx:
        if i in done:
            continue
        lo, hi = max(0, i - a.around), min(len(rows), i + a.around + 1)
        done.update(range(lo, hi))
        sheet(rows[lo:hi], "sheet_f%05d.jpg" % rows[i]["frame"])
else:
    t0 = a.t0 if a.t0 is not None else rows[0]["t"]
    t1 = a.t1 if a.t1 is not None else rows[-1]["t"]
    sel = [r for r in rows if t0 <= r["t"] <= t1]
    sheet(sel, "sheet_%.2f-%.2f.jpg" % (t0, t1))
