#!/usr/bin/env python3
"""Generate the app icon (icon/ClaudeUsage.icns): the popover's usage donut
on a macOS-style rounded tile. Rerun after tweaking; needs Pillow + iconutil.

    /usr/bin/python3 scripts/make-icon.py
"""

import colorsys
import math
import os
import shutil
import subprocess
import tempfile

from PIL import Image, ImageDraw, ImageFilter

HERE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(HERE, "icon", "ClaudeUsage.icns")

SS = 4                      # supersampling factor for smooth edges
S = 1024 * SS               # canvas
TILE = 824 * SS             # macOS icon grid: 824pt body on a 1024 canvas
RADIUS = 185 * SS
FILL_FRACTION = 1.0         # how much of the ring is "used" (1.0 = full circle)

BG_TOP = (252, 250, 246)
BG_BOTTOM = (236, 231, 224)
TRACK = (221, 236, 222)
GREEN = (47, 168, 74)       # same stops as colorForPct() in dashboard.html
ORANGE = (255, 149, 0)
RED = (255, 59, 48)
INK = (26, 26, 26)


def lerp(a, b, t):
    return tuple(round(x + (y - x) * t) for x, y in zip(a, b))


def lerp_hsv(a, b, t):
    # Interpolate in HSV so green -> orange passes through yellow, not olive
    ha, sa, va = colorsys.rgb_to_hsv(*(x / 255 for x in a))
    hb, sb, vb = colorsys.rgb_to_hsv(*(x / 255 for x in b))
    rgb = colorsys.hsv_to_rgb(ha + (hb - ha) * t, sa + (sb - sa) * t, va + (vb - va) * t)
    return tuple(round(x * 255) for x in rgb)


def arc_color(t):
    # t in 0..1 along the used part of the ring: green -> orange -> red
    return lerp_hsv(GREEN, ORANGE, t * 2) if t < 0.5 else lerp_hsv(ORANGE, RED, (t - 0.5) * 2)


def render() -> Image.Image:
    img = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    off = (S - TILE) // 2

    # Soft drop shadow under the tile
    shadow = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    ImageDraw.Draw(shadow).rounded_rectangle(
        (off, off + 12 * SS, off + TILE, off + TILE + 12 * SS), RADIUS, fill=(0, 0, 0, 70))
    img.alpha_composite(shadow.filter(ImageFilter.GaussianBlur(18 * SS)))

    # Tile with vertical gradient
    grad = Image.new("RGBA", (1, TILE))
    for y in range(TILE):
        grad.putpixel((0, y), lerp(BG_TOP, BG_BOTTOM, y / TILE) + (255,))
    grad = grad.resize((TILE, TILE))
    mask = Image.new("L", (TILE, TILE), 0)
    ImageDraw.Draw(mask).rounded_rectangle((0, 0, TILE - 1, TILE - 1), RADIUS, fill=255)
    img.paste(grad, (off, off), mask)

    # Donut
    d = ImageDraw.Draw(img)
    cx = cy = S // 2
    r = 270 * SS
    w = 92 * SS
    box = (cx - r, cy - r, cx + r, cy + r)
    d.ellipse(box, outline=TRACK, width=w)

    start = -90.0
    sweep = 360 * FILL_FRACTION
    steps = 720
    for i in range(steps):
        a0 = start + sweep * i / steps
        a1 = min(start + sweep * (i + 1) / steps + 0.4, start + sweep)  # overlap to avoid seams
        d.arc(box, a0, a1, fill=arc_color(i / steps), width=w)

    # Round caps at both ends of the arc (a full ring has no ends)
    ring_r = r - w / 2
    for ang, col in () if FILL_FRACTION >= 1 else ((start, arc_color(0)), (start + sweep, arc_color(1))):
        x = cx + ring_r * math.cos(math.radians(ang))
        y = cy + ring_r * math.sin(math.radians(ang))
        d.ellipse((x - w / 2, y - w / 2, x + w / 2, y + w / 2), fill=col)

    # Centre diamond — the app's original menu bar mark
    k = 78 * SS
    d.polygon([(cx, cy - k), (cx + k * 0.78, cy), (cx, cy + k), (cx - k * 0.78, cy)], fill=INK)

    return img.resize((1024, 1024), Image.LANCZOS)


def main():
    master = render()
    os.makedirs(os.path.dirname(OUT), exist_ok=True)
    master.save(os.path.join(HERE, "icon", "ClaudeUsage-1024.png"))

    iconset = os.path.join(tempfile.mkdtemp(), "ClaudeUsage.iconset")
    os.makedirs(iconset)
    for size in (16, 32, 128, 256, 512):
        for scale in (1, 2):
            px = size * scale
            name = f"icon_{size}x{size}{'@2x' if scale == 2 else ''}.png"
            master.resize((px, px), Image.LANCZOS).save(os.path.join(iconset, name))
    subprocess.run(["iconutil", "-c", "icns", iconset, "-o", OUT], check=True)
    shutil.rmtree(os.path.dirname(iconset))
    print(f"✓ {OUT}")


if __name__ == "__main__":
    main()
