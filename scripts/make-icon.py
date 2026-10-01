#!/usr/bin/env python3
"""Generate the app icon (icon/ClaudeUsage.icns and icon/ClaudeUsage-1024.png)
from the vector master icon/ClaudeUsage.svg (smiley in a usage ring on a macOS
tile: 412 pt body on a 512 pt canvas, i.e. the 824-on-1024 grid).

macOS only: the SVG is rendered by Quick Look (WebKit, so filters and shadows
come out right). Quick Look always paints an opaque white background, so the
SVG is rendered twice, on white and on black, and the transparency is recovered
from the difference. Needs Pillow, numpy and iconutil.

    /usr/bin/python3 scripts/make-icon.py
"""

import os
import shutil
import subprocess
import tempfile

import numpy as np
from PIL import Image

HERE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SVG = os.path.join(HERE, "icon", "ClaudeUsage.svg")
OUT = os.path.join(HERE, "icon", "ClaudeUsage.icns")
PNG = os.path.join(HERE, "icon", "ClaudeUsage-1024.png")
SIZE = 1024


def _quicklook(svg_text: str, workdir: str, name: str) -> Image.Image:
    path = os.path.join(workdir, name + ".svg")
    with open(path, "w", encoding="utf-8") as f:
        f.write(svg_text)
    subprocess.run(["qlmanage", "-t", "-s", str(SIZE), "-o", workdir, path],
                   capture_output=True, check=True)
    return Image.open(path + ".png").convert("RGB")


def render() -> Image.Image:
    with open(SVG, encoding="utf-8") as f:
        svg = f.read()
    if "</defs>" not in svg:
        raise SystemExit("icon/ClaudeUsage.svg has no <defs>; cannot add the black backdrop")
    workdir = tempfile.mkdtemp()
    try:
        on_white = _quicklook(svg, workdir, "white")
        black_svg = svg.replace(
            "</defs>", "</defs>\n<rect width='100%' height='100%' fill='#000'/>", 1)
        on_black = _quicklook(black_svg, workdir, "black")
    finally:
        shutil.rmtree(workdir, ignore_errors=True)

    w = np.asarray(on_white, dtype=np.float64)
    b = np.asarray(on_black, dtype=np.float64)
    # white backdrop: c*a + 255*(1-a); black backdrop: c*a  =>  a = 1 - (w-b)/255
    alpha = np.clip(1 - (w - b).mean(axis=2) / 255, 0, 1)
    color = np.where(alpha[..., None] > 1e-3, b / np.maximum(alpha[..., None], 1e-3), 0)
    rgba = np.dstack([np.clip(color, 0, 255), alpha * 255]).astype(np.uint8)
    return Image.fromarray(rgba)


def main():
    master = render()
    os.makedirs(os.path.dirname(OUT), exist_ok=True)
    master.save(PNG)

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
