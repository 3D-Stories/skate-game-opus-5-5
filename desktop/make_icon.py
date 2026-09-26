#!/usr/bin/env python3
"""Makes the Windows application icon from the game's own deck graphic.

    python3 desktop/make_icon.py        -> desktop/icon.png (256 px), desktop/icon.ico

The tiger face is cut from blender/textures_src/deck_graphic.png (the board's graphic, one of
the project's 17 generated images; no new image is made), set on a black rounded square with a
gold rim like the game's HUD colour, and saved as a PNG and a multi-size ICO (16-256 px).
"""
import os
from PIL import Image, ImageDraw, ImageFilter

HERE = os.path.dirname(os.path.abspath(__file__))
SRC = os.path.join(HERE, "..", "blender", "textures_src", "deck_graphic.png")
GOLD = (255, 210, 31, 255)          # menus.gd title colour (1, 0.82, 0.12)
S = 1024                            # work at 4x, scale down at the end


def rounded_mask(size, radius, inset=0):
    m = Image.new("L", (size, size), 0)
    ImageDraw.Draw(m).rounded_rectangle((inset, inset, size - 1 - inset, size - 1 - inset), radius, fill=255)
    return m


def main():
    deck = Image.open(SRC).convert("RGB")
    # the deck spans x 281..741; the face (ears to chin) sits in y 60..800
    face = deck.crop((282, 58, 740, 516)).resize((S, S), Image.LANCZOS)
    icon = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    icon.paste((12, 12, 14, 255), (0, 0, S, S), rounded_mask(S, 200))
    icon.paste(GOLD, (0, 0, S, S), rounded_mask(S, 200, 22))
    icon.paste((12, 12, 14, 255), (0, 0, S, S), rounded_mask(S, 176, 54))
    inner = rounded_mask(S, 150, 78).filter(ImageFilter.GaussianBlur(2))
    icon.paste(face, (0, 0), inner)
    png = icon.resize((256, 256), Image.LANCZOS)
    png.save(os.path.join(HERE, "icon.png"), optimize=True)
    png.save(os.path.join(HERE, "icon.ico"), sizes=[(16, 16), (24, 24), (32, 32), (48, 48), (64, 64), (128, 128), (256, 256)])
    print("icon:", os.path.join(HERE, "icon.png"), os.path.join(HERE, "icon.ico"))


if __name__ == "__main__":
    main()
