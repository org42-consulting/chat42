#!/usr/bin/env python3
"""Regenerates every derived app-icon asset from the geometry defined here.

    python3 design/AppIcon/generate.py

Writes:
  design/AppIcon/A-answer/*.svg          editable component layers (reference)
  design/AppIcon/B-dialogue/*.svg        the alternate direction (reference)
  Chat42/Resources/AppIcon.icon/         the Icon Composer bundle that ships
  Chat42/Resources/Assets.xcassets/AppIcon.appiconset/*.png
                                         flat raster fallback for the CLT-only build

Why the shipping layer is a single composed SVG
-----------------------------------------------
The design started as two groups (bubble, numerals). Compiling that with actool and
looking at the result showed the numerals almost vanishing: a second Liquid Glass
group stacked on a dark one picks up what is beneath it and loses nearly all
contrast. Turning off specular and translucency did not recover it, and putting both
layers in one group merged them into a single object and dropped the numerals
entirely. Painting the numerals inside one layer renders exactly as designed, so that
is what ships. The component files are kept because they are easier to edit.
"""
import json
import math
import os
import shutil
import subprocess
import sys

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
DESIGN = os.path.join(ROOT, "design", "AppIcon")
ICON_BUNDLE = os.path.join(ROOT, "Chat42", "Resources", "AppIcon.icon")
ICONSET = os.path.join(
    ROOT, "Chat42", "Resources", "Assets.xcassets", "AppIcon.appiconset")

INK, CRIMSON, CREAM = "#002D3C", "#990000", "#F4F7F5"
MIST, MIST_DEEP = "#DCEFF3", "#A9CFD9"

# ---------------------------------------------------------------- geometry

BUBBLE = ("M 140 388 A 192 192 0 0 1 332 196 L 692 196 A 192 192 0 0 1 884 388 "
          "L 884 544 A 192 192 0 0 1 692 736 L 486 736 C 470 806 400 856 292 872 "
          "C 262 866 260 846 282 830 C 334 800 350 772 346 736 "
          "A 192 192 0 0 1 140 544 Z")

BACK_B = ("M 148 356 A 160 160 0 0 1 308 196 L 628 196 A 160 160 0 0 1 788 356 "
          "L 788 468 A 160 160 0 0 1 628 628 L 404 628 C 392 700 326 750 232 766 "
          "C 296 706 314 666 306 628 A 160 160 0 0 1 148 468 Z")

FRONT_B = ("M 402 570 A 148 148 0 0 1 550 422 L 724 422 A 148 148 0 0 1 872 570 "
           "L 872 654 A 148 148 0 0 1 724 802 L 690 802 C 700 842 730 866 782 878 "
           "C 700 884 638 850 612 802 L 550 802 A 148 148 0 0 1 402 654 Z")

SW, TOP, BOT = 48, 330, 594
H = SW / 2
AX, BAR_Y, DIA_X0, R, CX = 468, 500, 292, 76, 664


def _p(cx, cy, r, a):
    t = math.radians(a)
    return cx + r * math.cos(t), cy - r * math.sin(t)


def numeral_paths():
    """The 42 as three stroked centrelines. Never type — Icon Composer rejects
    SVGs containing text elements, and a font would also have to be licensed."""
    s = _p(CX, TOP + H + R, R, 202)
    e = _p(CX, TOP + H + R, R, -28)
    return [
        f"M {DIA_X0} {BAR_Y} L {AX} {TOP + H} L {AX} {BOT - H}",
        f"M {DIA_X0 - 4} {BAR_Y} L {AX + 42} {BAR_Y}",
        f"M {s[0]:.1f} {s[1]:.1f} A {R} {R} 0 1 1 {e[0]:.1f} {e[1]:.1f} "
        f"L {CX - R + 6} {BOT - H} L {CX + R} {BOT - H}",
    ]


def numerals_group(color):
    dx = 512 - ((DIA_X0 - H) + (CX + R + H)) / 2
    paths = "".join(f'\n      <path d="{d}"/>' for d in numeral_paths())
    return (f'  <g transform="translate({dx:.1f},0)" fill="none" stroke="{color}"\n'
            f'     stroke-width="{SW}" stroke-linecap="round" '
            f'stroke-linejoin="round">{paths}\n  </g>')


def svg(body, note):
    return ('<svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024"\n'
            f'     viewBox="0 0 1024 1024">\n  <!-- {note} -->\n{body}\n</svg>\n')


def squircle(n=4.6, size=1024):
    """Apple's icon silhouette is a continuous-curvature squircle, not a
    border-radius. Only used for the flat raster fallback, which must bake the
    crop in; the .icon never carries a mask — the system applies it."""
    a = size / 2
    pts = []
    for i in range(241):
        t = i / 240 * math.tau
        c, s = math.cos(t), math.sin(t)
        x = a + a * math.copysign(abs(c) ** (2 / n), c)
        y = a + a * math.copysign(abs(s) ** (2 / n), s)
        pts.append(f"{x:.2f} {y:.2f}")
    return "M " + " L ".join(pts) + " Z"


# ---------------------------------------------------------------- writers

def write(path, text):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as fh:
        fh.write(text)


def build_sources():
    shipping = (f'  <path d="{BUBBLE}" fill="{CRIMSON}"/>\n'
                + numerals_group(CREAM))
    write(f"{DESIGN}/A-answer/icon.svg",
          svg(shipping, "SHIPPING LAYER - bubble and numerals composed"))
    write(f"{DESIGN}/A-answer/01-bubble.svg",
          svg(f'  <path d="{BUBBLE}" fill="{CRIMSON}"/>', "component - bubble"))
    write(f"{DESIGN}/A-answer/02-numerals.svg",
          svg(numerals_group(CREAM), "component - 42"))
    write(f"{DESIGN}/B-dialogue/01-back-bubble.svg",
          svg(f'  <path d="{BACK_B}" fill="{INK}"/>', "alternate - first speaker"))
    write(f"{DESIGN}/B-dialogue/02-front-bubble.svg",
          svg(f'  <path d="{FRONT_B}" fill="{CRIMSON}"/>', "alternate - the reply"))
    return shipping


def build_icon_bundle(shipping):
    """The Icon Composer document. Schema verified by compiling with actool and
    inspecting the render, not by guesswork."""
    shutil.rmtree(ICON_BUNDLE, ignore_errors=True)
    os.makedirs(f"{ICON_BUNDLE}/Assets")
    write(f"{ICON_BUNDLE}/Assets/icon.svg",
          svg(shipping, "Chat42 app icon - single Liquid Glass layer"))
    r, g, b = (int(MIST_DEEP[i:i + 2], 16) / 255 for i in (1, 3, 5))
    doc = {
        "fill": {"automatic-gradient":
                 f"extended-srgb:{r:.5f},{g:.5f},{b:.5f},1.00000"},
        "groups": [{"layers": [{"image-name": "icon.svg", "name": "Bubble"}]}],
        "supported-platforms": {"circles": ["watchOS"], "squares": "shared"},
    }
    write(f"{ICON_BUNDLE}/icon.json", json.dumps(doc, indent=2) + "\n")


# The flat fallback has to bake in what the system would otherwise apply.
FLAT_SIZES = [16, 20, 29, 32, 40, 58, 60, 64, 80, 87, 120, 128, 152, 167, 180,
              256, 512, 1024]


def build_raster(shipping):
    flat = (f'  <defs>\n'
            f'    <linearGradient id="bg" x1="0" y1="0" x2="0.55" y2="1">\n'
            f'      <stop offset="0" stop-color="{MIST}"/>\n'
            f'      <stop offset="1" stop-color="{MIST_DEEP}"/>\n'
            f'    </linearGradient>\n'
            f'    <clipPath id="mask"><path d="{squircle()}"/></clipPath>\n'
            f'  </defs>\n'
            f'  <g clip-path="url(#mask)">\n'
            f'    <rect width="1024" height="1024" fill="url(#bg)"/>\n'
            f'{shipping}\n  </g>')
    tmp = "/tmp/chat42-appicon-flat"
    shutil.rmtree(tmp, ignore_errors=True)
    os.makedirs(tmp)
    src = f"{tmp}/flat.svg"
    write(src, svg(flat, "flat raster master"))

    subprocess.run(["qlmanage", "-t", "-s", "1024", "-o", tmp, src],
                   capture_output=True)
    master = f"{tmp}/flat.svg.png"
    if not os.path.exists(master):
        sys.exit("could not rasterise the icon master (qlmanage produced nothing)")

    os.makedirs(ICONSET, exist_ok=True)
    for size in FLAT_SIZES:
        out = f"{ICONSET}/{size}.png"
        subprocess.run(["sips", "-z", str(size), str(size), master, "--out", out],
                       capture_output=True)
    return master


if __name__ == "__main__":
    art = build_sources()
    build_icon_bundle(art)
    build_raster(art)
    print(f"sources   -> {DESIGN}")
    print(f"icon      -> {ICON_BUNDLE}")
    print(f"fallback  -> {ICONSET} ({len(FLAT_SIZES)} sizes)")
