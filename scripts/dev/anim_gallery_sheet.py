#!/usr/bin/env python3
"""Contact sheet for the animation gallery recording (scenes/dev/anim_gallery.tscn).

For every required clip: the start, middle and end frame of its first play, taken from the
Movie Maker AVI by frame number (gallery_timeline.json, written by the gallery, maps every
rendered frame to clip / clip time / ankle-vs-deck readout / on-screen box of the skater).
Each clip's three frames share one crop around the skater and board.

  python3 scripts/dev/anim_gallery_sheet.py /tmp/gallery/gallery.avi /tmp/gallery/gallery_timeline.json \
      evidence/anim_gallery_sheet.jpg [ffmpeg]
"""
import json
import os
import subprocess
import sys
import tempfile

from PIL import Image, ImageDraw, ImageFont

REQUIRED = ["idle", "push", "ride", "crouch", "ollie", "kickflip", "heelflip", "shoveit", "treflip",
            "indy", "melon", "nosegrab", "tailgrab", "grind_5050", "boardslide", "manual", "nose_manual",
            "vert_air", "air", "land", "bail", "special"]
TW, TH = 330, 380            # thumbnail
GAP = 12
PAIR_GAP = 34
HEAD_H = 34                  # clip name line above a triple
CAP_H = 46                   # two caption lines under a thumbnail
PER_ROW = 2                  # clips per row
FLIPS = {"kickflip", "heelflip", "shoveit", "treflip", "special"}   # feet may leave the deck mid-flip
FONT = "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf"
FONT_B = "/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf"


def pick(frames, clip):
    rep1 = [e for e in frames if e["kind"] == "clip" and e["clip"] == clip and e["rep"] == 1]
    if not rep1:
        return None
    length = rep1[0]["len"]
    mid = min(rep1, key=lambda e: abs(e["pos"] - length / 2.0))
    return [("start", rep1[0]), ("middle", mid), ("end", rep1[-1])]


def contact(frames, clip):
    """Max ankle-vs-deck error over every recorded frame of the clip (both plays): in the
    contact phase, and (flip clips) the hover while the board flips (u in 0.06..0.9)."""
    c_max, hover = 0.0, 0.0
    for e in frames:
        if e["kind"] != "clip" or e["clip"] != clip:
            continue
        a = max(abs(e["ankle_l_cm"]), abs(e["ankle_r_cm"]))
        u = e["pos"] / e["len"]
        if clip in FLIPS and 0.06 <= u <= 0.9:
            hover = max(hover, a)
        else:
            c_max = max(c_max, a)
    return c_max, hover


def main():
    avi, tl_path, out = sys.argv[1], sys.argv[2], sys.argv[3]
    ffmpeg = sys.argv[4] if len(sys.argv) > 4 else "ffmpeg"
    tl = json.load(open(tl_path))
    frames = tl["frames"]
    rows = []
    wanted = set()
    for c in REQUIRED:
        p = pick(frames, c)
        if p is None:
            print("missing clip in timeline:", c)
            continue
        rows.append((c, p))
        wanted.update(e["frame"] for _, e in p)
    wanted = sorted(wanted)
    tmp = tempfile.mkdtemp(prefix="gallery_sheet_")
    sel = "+".join("eq(n\\,%d)" % n for n in wanted)
    subprocess.run([ffmpeg, "-hide_banner", "-loglevel", "error", "-y", "-i", avi, "-vf", "select='%s'" % sel,
                    "-vsync", "0", os.path.join(tmp, "f_%04d.png")], check=True)
    files = sorted(f for f in os.listdir(tmp) if f.startswith("f_"))
    if len(files) != len(wanted):
        sys.exit("extracted %d frames, wanted %d" % (len(files), len(wanted)))
    img_of = {n: os.path.join(tmp, f) for n, f in zip(wanted, files)}

    font = ImageFont.truetype(FONT, 15)
    font_s = ImageFont.truetype(FONT, 13)
    font_b = ImageFont.truetype(FONT_B, 19)
    font_t = ImageFont.truetype(FONT_B, 26)
    triple_w = 3 * TW + 2 * GAP
    W = PER_ROW * triple_w + (PER_ROW - 1) * PAIR_GAP + 2 * GAP
    n_rows = (len(rows) + PER_ROW - 1) // PER_ROW
    row_h = HEAD_H + TH + CAP_H + GAP
    top = 92
    H = top + n_rows * row_h + GAP
    sheet = Image.new("RGB", (W, H), (24, 25, 28))
    d = ImageDraw.Draw(sheet)
    d.text((GAP, 14), "Animation gallery - contact sheet (start / middle / end of each clip's first play)", font=font_t,
           fill=(240, 240, 240))
    d.text((GAP, 52), "Godot %s Movie Maker recording of scenes/dev/anim_gallery.tscn: the game's skater_model.gd "
           "(skater.glb + board.glb on the board bone), authored speed. '#' = movie frame. "
           "Ankle = ankle height vs. its on-deck position in the board's frame (cm)." % "4.7.2", font=font, fill=(190, 190, 190))
    for i, (clip, picks) in enumerate(rows):
        r, k = divmod(i, PER_ROW)
        x0 = GAP + k * (triple_w + PAIR_GAP)
        y0 = top + r * row_h
        e0 = picks[0][1]
        kind = "one-shot" if e0["pos"] == 0 and picks[2][1]["pos"] >= e0["len"] - 1e-3 else "looping"
        d.text((x0, y0 + 6), "%d. %s" % (REQUIRED.index(clip) + 1, clip), font=font_b, fill=(255, 214, 120))
        c_max, hover = contact(frames, clip)
        feet = "feet vs deck max %.1f cm" % c_max
        if clip in FLIPS:
            feet += " outside the flip (mid-flip %.0f cm)" % hover
        if clip == "push":
            feet += " (pushing foot on the ground)"
        if clip == "bail":
            feet += " (falls off by design)"
        d.text((x0 + 200, y0 + 10), "%.2f s, %s%s  |  %s" % (e0["len"], kind, ", 2x in video" if e0["reps"] > 1 else "", feet),
               font=font_s, fill=(200, 200, 200))
        # one crop for the three frames: union of the skater's on-screen boxes, padded, at the thumb aspect
        first = Image.open(img_of[e0["frame"]])
        fw, fh = first.size
        bx = [min(e["bbox"][0] for _, e in picks), min(e["bbox"][1] for _, e in picks),
              max(e["bbox"][2] for _, e in picks), max(e["bbox"][3] for _, e in picks)]
        cx, cy = (bx[0] + bx[2]) / 2 * fw, (bx[1] + bx[3]) / 2 * fh
        w, h = (bx[2] - bx[0]) * fw * 1.14 + 30, (bx[3] - bx[1]) * fh * 1.1 + 30
        if w / h > TW / TH:
            h = w * TH / TW
        else:
            w = h * TW / TH
        w, h = min(w, fw), min(h, fh)
        l = min(max(cx - w / 2, 0), fw - w)
        t = min(max(cy - h / 2, 0), fh - h)
        # stay inside the part of the picture below the burned-in labels (top quarter) and above
        # the footer line; a crop that is then too flat for the thumbnail gets letterboxed
        lo, hi = 0.245 * fh, fh - 50
        if (bx[1] * fh) >= lo and (bx[3] * fh) <= hi:
            h = min(h, hi - lo)
            t = min(max(t, lo), hi - h)
        for j, (label, e) in enumerate(picks):
            src = Image.open(img_of[e["frame"]]).crop((int(l), int(t), int(l + w), int(t + h)))
            sc = min(TW / src.width, TH / src.height)
            src = src.resize((max(1, int(src.width * sc)), max(1, int(src.height * sc))), Image.LANCZOS)
            im = Image.new("RGB", (TW, TH), (46, 48, 53))
            im.paste(src, ((TW - src.width) // 2, (TH - src.height) // 2))
            tx = x0 + j * (TW + GAP)
            ty = y0 + HEAD_H
            sheet.paste(im, (tx, ty))
            d.rectangle((tx, ty, tx + TW - 1, ty + TH - 1), outline=(70, 72, 78))
            d.text((tx + 2, ty + TH + 4), "%s  t = %.2f s   #%d" % (label, e["pos"], e["frame"]), font=font, fill=(235, 235, 235))
            d.text((tx + 2, ty + TH + 24), "ankle L %+.1f  R %+.1f cm" % (e["ankle_l_cm"], e["ankle_r_cm"]), font=font_s,
                   fill=(170, 200, 170) if max(abs(e["ankle_l_cm"]), abs(e["ankle_r_cm"])) < 2.0 else (230, 190, 120))
    os.makedirs(os.path.dirname(os.path.abspath(out)), exist_ok=True)
    sheet.save(out, quality=88)
    print("contact sheet -> %s  (%dx%d, %d clips, %d frames)" % (out, W, H, len(rows), len(wanted)))


if __name__ == "__main__":
    main()
