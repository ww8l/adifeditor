"""Regenerate AppIcon.svg and AppIcon-1024.png from scratch.

This is the icon's provenance, not a build step. Nothing in Scripts/ calls it, and it
does not run on the development machine as-is: it needs `cairosvg` and `Pillow`, neither
of which is installed here (the icon was authored elsewhere). Scripts/bundle.sh consumes
the committed AppIcon-1024.png and never invokes this file.

It is committed because the repository is going public under MIT and the icon has to be
demonstrably original rather than borrowed — DESIGN.md §4 forbids deriving anything from
ADIF Master's icons, and a generator that draws every shape from arithmetic is the
clearest possible evidence of that. There are no fonts, no traced paths and no stock art
in it, which is also what keeps the icon redistributable under the project's license.

    pip install cairosvg Pillow && python3 build_icon.py

Design notes worth keeping: the body is a superellipse (n=5) occupying 80% of the canvas
width, which is macOS's own app-icon proportion — Apple's grid puts the rounded rect at
824/1024 and this lands at 820. The padding is baked into the art on purpose; macOS does
not mask app icons the way iOS does, so what is in the PNG is what appears in the Dock.
"""

import math
import os

import cairosvg
from PIL import Image

HERE = os.path.dirname(os.path.abspath(__file__))

BG      = "#1F3A5F"
PAGE    = "#F5F3EC"
FIELD   = "#A8B4C4"
VALUE   = "#6E819A"
ACCENT  = "#D97706"

CX = CY = 90.0
A = 72.0          # half-width of the icon body: 144/180 = 80% of canvas
N = 5.0           # superellipse exponent - continuous corner, near-flat sides


def squircle(cx, cy, a, n, steps=720):
    pts = []
    for i in range(steps):
        t = 2.0 * math.pi * i / steps
        ct, st = math.cos(t), math.sin(t)
        x = cx + a * math.copysign(abs(ct) ** (2.0 / n), ct)
        y = cy + a * math.copysign(abs(st) ** (2.0 / n), st)
        pts.append((x, y))
    d = "M{:.4f} {:.4f}".format(*pts[0])
    for p in pts[1:]:
        d += "L{:.4f} {:.4f}".format(*p)
    return d + "Z"


def chev(x_tip, x_arm, cy, half):
    return "M{} {}L{} {}L{} {}".format(
        x_arm, cy - half, x_tip, cy, x_arm, cy + half
    )


rows = [
    (68.0, 30.0, VALUE),
    (90.0, 36.0, ACCENT),
    (112.0, 26.0, VALUE),
]

parts = [
    '<path d="{}" fill="{}"/>'.format(squircle(CX, CY, A, N), BG),
    '<rect x="36" y="50" width="108" height="80" rx="7" fill="{}"/>'.format(PAGE),
]

for cy, vw, vcol in rows:
    bar_y = cy - 3.25
    parts.append(
        '<path d="{}" fill="none" stroke="{}" stroke-width="4" '
        'stroke-linecap="round" stroke-linejoin="round"/>'.format(
            chev(48, 54, cy, 6), FIELD)
    )
    parts.append(
        '<rect x="60" y="{}" width="20" height="6.5" rx="3" fill="{}"/>'.format(bar_y, FIELD)
    )
    parts.append(
        '<path d="{}" fill="none" stroke="{}" stroke-width="4" '
        'stroke-linecap="round" stroke-linejoin="round"/>'.format(
            chev(90, 84, cy, 6), FIELD)
    )
    parts.append(
        '<rect x="98" y="{}" width="{}" height="6.5" rx="3" fill="{}"/>'.format(bar_y, vw, vcol)
    )

svg = (
    '<svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" '
    'viewBox="0 0 180 180">' + "".join(parts) + "</svg>"
)

svg_path = os.path.join(HERE, "AppIcon.svg")
png_path = os.path.join(HERE, "AppIcon-1024.png")

with open(svg_path, "w") as f:
    f.write(svg)

cairosvg.svg2png(
    bytestring=svg.encode(),
    write_to=png_path,
    output_width=1024,
    output_height=1024,
    background_color=None,
)

im = Image.open(png_path)
print("size:", im.size, "mode:", im.mode)
alpha = im.getchannel("A")
print("corner alpha:", alpha.getpixel((0, 0)), alpha.getpixel((1023, 0)))
bbox = alpha.getbbox()
w = bbox[2] - bbox[0]
h = bbox[3] - bbox[1]
print("opaque bbox:", bbox, "->", w, "x", h)
print("occupies {:.1f}% of width, margins L{} R{} T{} B{}".format(
    100.0 * w / 1024, bbox[0], 1024 - bbox[2], bbox[1], 1024 - bbox[3]))
