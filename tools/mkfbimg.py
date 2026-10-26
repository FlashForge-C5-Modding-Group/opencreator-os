#!/usr/bin/env python3
"""Render text into a raw Creator 5 Pro framebuffer image.

    mkfbimg.py [--color RRGGBB] [--png PREVIEW.png] TEXT OUT.raw

TEXT may contain "\\n" for line breaks; long lines are wrapped. The output is
what stock firmware writes with `cat img > /dev/fb0`: 480x800 pixels, 32 bpp,
bytes B, G, R, A per pixel (XRGB8888 little-endian), 1,536,000 bytes.

The panel is mounted landscape (800x480 as seen by the user) while the
framebuffer scans portrait, so stock images hold their content rotated
90 degrees counter-clockwise. We draw on an 800x480 canvas and rotate the
same way. --png also writes the landscape canvas for a quick visual check.
"""

import argparse
import sys

from PIL import Image, ImageDraw, ImageFont

FB_W, FB_H = 480, 800          # framebuffer geometry (portrait scan order)
VIEW_W, VIEW_H = FB_H, FB_W    # what the user sees (landscape)
BACKGROUND = (0, 0, 0)            # stock screens use pure black
FONT_CANDIDATES = (
    "DejaVuSans-Bold.ttf",
    "/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf",
    "DejaVuSans.ttf",
    "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf",
)


def load_font(size):
    for name in FONT_CANDIDATES:
        try:
            return ImageFont.truetype(name, size)
        except OSError:
            continue
    try:
        return ImageFont.load_default(size=size)
    except TypeError:  # Pillow < 10.1 has no scalable default font
        return ImageFont.load_default()


def wrap(draw, text, font, width):
    lines = []
    for para in text.split("\n"):
        words = para.split()
        if not words:
            lines.append("")
            continue
        cur = words[0]
        for word in words[1:]:
            trial = cur + " " + word
            if draw.textlength(trial, font=font) <= width:
                cur = trial
            else:
                lines.append(cur)
                cur = word
        lines.append(cur)
    return lines


def render(text, color):
    canvas = Image.new("RGB", (VIEW_W, VIEW_H), BACKGROUND)
    draw = ImageDraw.Draw(canvas)
    margin = 40
    # First line is the title, drawn larger; shrink until everything fits.
    for size in range(64, 15, -2):
        title_font, body_font = load_font(size), load_font(size * 2 // 3)
        paras = text.split("\n")
        title = wrap(draw, paras[0], title_font, VIEW_W - 2 * margin)
        body = wrap(draw, "\n".join(paras[1:]), body_font, VIEW_W - 2 * margin) if len(paras) > 1 else []
        rows = [(line, title_font, color) for line in title] + \
               [(line, body_font, (230, 230, 230)) for line in body]
        heights = [f.getbbox("Ag")[3] - f.getbbox("Ag")[1] for _, f, _ in rows]
        gap = size // 3
        total = sum(heights) + gap * (len(rows) - 1)
        widest = max(draw.textlength(line, font=f) for line, f, _ in rows)
        if total <= VIEW_H - 2 * margin and widest <= VIEW_W - 2 * margin:
            break
    y = (VIEW_H - total) // 2
    for (line, font, fill), h in zip(rows, heights):
        x = (VIEW_W - draw.textlength(line, font=font)) // 2
        draw.text((x, y - font.getbbox("Ag")[1]), line, font=font, fill=fill)
        y += h + gap
    return canvas


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("text")
    ap.add_argument("out")
    ap.add_argument("--color", default="ffffff", help="title colour RRGGBB")
    ap.add_argument("--png", help="also write the landscape view as PNG")
    args = ap.parse_args()

    color = tuple(int(args.color[i:i + 2], 16) for i in (0, 2, 4))
    text = args.text.replace("\\n", "\n")
    canvas = render(text, color)
    if args.png:
        canvas.save(args.png)
    fb = canvas.rotate(90, expand=True).convert("RGBA")
    assert fb.size == (FB_W, FB_H)
    raw = fb.tobytes("raw", "BGRA")
    assert len(raw) == FB_W * FB_H * 4
    with open(args.out, "wb") as f:
        f.write(raw)
    return 0


if __name__ == "__main__":
    sys.exit(main())
