#!/usr/bin/env python3
"""Renders Assets.xcassets/AppIcon.appiconset/AppIcon.png.

    python3 tools/make_app_icon.py app/JTTY/Assets.xcassets/AppIcon.appiconset/AppIcon.png

Three message tiles on the dark slate shared with the other shack apps:
teal, sand and salmon, each carrying a short run of dots and dashes in the
slate, with the app's name under them in cream as on the FT8 icon.
Keyboard-to-keyboard on the air is a conversation, and this is the family's
picture of one.
"""

import math
import struct
import sys
import zlib

SIZE = 1024

BG_TOP = (0.141, 0.192, 0.231)
BG_BOTTOM = (0.098, 0.137, 0.169)
INK = (0.125, 0.172, 0.208)
TEAL = (0.388, 0.702, 0.651)
SAND = (0.918, 0.788, 0.435)
SALMON = (0.871, 0.506, 0.384)

CREAM = (0.949, 0.906, 0.827)

# Tiles as (left, top, right, bottom, colour, glyphs) in the coordinates of
# the original mark; glyph runs are strings of '.' and '-', centred in the
# tile. The whole group is scaled and placed by MARK_SCALE / MARK_TOP so the
# wordmark fits underneath, and the group is centred on the tile the way the
# wordmark is.
TILES = [
    (186, 212, 584, 392, TEAL, "-.-"),
    (390, 400, 776, 578, SAND, "..."),
    (204, 592, 450, 770, SALMON, "-"),
]
MARK_SCALE = 0.80
MARK_TOP = 128.0
TILE_RADIUS = 64.0
DOT = 46.0            # glyph height and dot diameter
DASH = 92.0           # dash length
GLYPH_GAP = 26.0

# Wordmark, as on the FT8 icon: stroked letters rather than a font, so the
# script has no dependencies and the weight matches the tiles' glyphs.
TEXT = "JTTY"
TEXT_TOP = 716.0
TEXT_HEIGHT = 166.0
TEXT_WIDTH = 46.0
TEXT_GAP = 58.0

SHADOW_PASSES = [(34.0, 0.05), (22.0, 0.06), (12.0, 0.07), (5.0, 0.08)]
SHADOW_OFFSET = 12.0


def clamp(v, lo=0.0, hi=1.0):
    return lo if v < lo else hi if v > hi else v


class Canvas:
    def __init__(self, size):
        self.size = size
        self.pixels = [0.0] * (size * size * 3)
        for y in range(size):
            t = (y + 0.5) / size
            row = [BG_TOP[i] + (BG_BOTTOM[i] - BG_TOP[i]) * t for i in range(3)]
            base = y * size * 3
            for x in range(size):
                o = base + x * 3
                self.pixels[o:o + 3] = row

    def blend(self, x, y, color, alpha):
        if alpha <= 0:
            return
        o = (y * self.size + x) * 3
        p = self.pixels
        p[o] += (color[0] - p[o]) * alpha
        p[o + 1] += (color[1] - p[o + 1]) * alpha
        p[o + 2] += (color[2] - p[o + 2]) * alpha

    def rounded_rect(self, x0, y0, x1, y1, radius, color, alpha=1.0, grow=0.0):
        """Filled rounded rectangle, antialiased over one pixel."""
        x0, y0, x1, y1 = x0 - grow, y0 - grow, x1 + grow, y1 + grow
        radius = radius + grow
        cx, cy = (x0 + x1) / 2, (y0 + y1) / 2
        hx, hy = (x1 - x0) / 2 - radius, (y1 - y0) / 2 - radius
        left, right = max(0, int(x0) - 1), min(self.size - 1, int(x1) + 1)
        top, bottom = max(0, int(y0) - 1), min(self.size - 1, int(y1) + 1)
        for y in range(top, bottom + 1):
            py = y + 0.5
            qy = abs(py - cy) - hy
            for x in range(left, right + 1):
                px = x + 0.5
                qx = abs(px - cx) - hx
                outside = math.hypot(max(qx, 0), max(qy, 0)) + min(max(qx, qy), 0) - radius
                c = clamp(0.5 - outside)
                if c > 0:
                    self.blend(x, y, color, c * alpha)

    def capsule(self, p0, p1, radius, color, alpha=1.0):
        """A line segment with round caps, antialiased over one pixel."""
        x0, y0 = p0
        x1, y1 = p1
        left = max(0, int(min(x0, x1) - radius - 2))
        right = min(self.size - 1, int(max(x0, x1) + radius + 2))
        top = max(0, int(min(y0, y1) - radius - 2))
        bottom = min(self.size - 1, int(max(y0, y1) + radius + 2))
        dx, dy = x1 - x0, y1 - y0
        l2 = dx * dx + dy * dy
        for y in range(top, bottom + 1):
            py = y + 0.5
            for x in range(left, right + 1):
                px = x + 0.5
                t = clamp(((px - x0) * dx + (py - y0) * dy) / l2) if l2 > 1e-9 else 0.0
                ox, oy = px - (x0 + t * dx), py - (y0 + t * dy)
                c = clamp(radius - math.hypot(ox, oy) + 0.5)
                if c > 0:
                    self.blend(x, y, color, c * alpha)

    def stroke(self, points, width, color, alpha=1.0):
        r = width / 2
        if len(points) == 1:
            self.capsule(points[0], points[0], r, color, alpha)
            return
        for i in range(len(points) - 1):
            self.capsule(points[i], points[i + 1], r, color, alpha)

    def write_png(self, path):
        rows = bytearray()
        for y in range(self.size):
            rows.append(0)
            base = y * self.size * 3
            for i in range(base, base + self.size * 3):
                rows.append(int(clamp(self.pixels[i]) * 255 + 0.5))

        def chunk(tag, data):
            payload = tag + data
            return struct.pack(">I", len(data)) + payload + struct.pack(">I", zlib.crc32(payload) & 0xFFFFFFFF)

        png = b"\x89PNG\r\n\x1a\n"
        png += chunk(b"IHDR", struct.pack(">IIBBBBB", self.size, self.size, 8, 2, 0, 0, 0))
        png += chunk(b"IDAT", zlib.compress(bytes(rows), 9))
        png += chunk(b"IEND", b"")
        with open(path, "wb") as f:
            f.write(png)
        return len(png)


def placed_tiles():
    """The tile group scaled and centred horizontally, top at MARK_TOP."""
    xs = [t[0] for t in TILES] + [t[2] for t in TILES]
    ys = [t[1] for t in TILES] + [t[3] for t in TILES]
    left, top, width = min(xs), min(ys), max(xs) - min(xs)
    dx = (SIZE - width * MARK_SCALE) / 2 - left * MARK_SCALE
    dy = MARK_TOP - top * MARK_SCALE
    return [
        (x0 * MARK_SCALE + dx, y0 * MARK_SCALE + dy, x1 * MARK_SCALE + dx, y1 * MARK_SCALE + dy, c, g)
        for x0, y0, x1, y1, c, g in TILES
    ]


def glyph_boxes(tile):
    x0, y0, x1, y1, _, run = tile
    dot, dash, gap = DOT * MARK_SCALE, DASH * MARK_SCALE, GLYPH_GAP * MARK_SCALE
    widths = [dash if g == "-" else dot for g in run]
    total = sum(widths) + gap * (len(run) - 1)
    cx, cy = (x0 + x1) / 2, (y0 + y1) / 2
    cursor = cx - total / 2
    boxes = []
    for w in widths:
        boxes.append((cursor, cy - dot / 2, cursor + w, cy + dot / 2))
        cursor += w + gap
    return boxes


def ellipse(c, sx, sy, steps=90, start=0.0, end=360.0):
    pts = []
    for i in range(steps + 1):
        a = math.radians(start + (end - start) * i / steps)
        pts.append((c[0] + sx * math.cos(a), c[1] - sy * math.sin(a)))
    return pts


def letter_j(x, top, h):
    """A stem with a hook: no top bar, which would crowd the T."""
    w = h * 0.52
    return [
        [(x + w, top), (x + w, top + h * 0.68)],
        ellipse((x + w * 0.5, top + h * 0.68), w * 0.5, h * 0.32, 60, 180, 360),
    ], w


def letter_t(x, top, h):
    w = h * 0.60
    return [[(x, top), (x + w, top)], [(x + w / 2, top), (x + w / 2, top + h)]], w


def letter_y(x, top, h):
    w = h * 0.62
    return [
        [(x, top), (x + w / 2, top + h * 0.5)],
        [(x + w, top), (x + w / 2, top + h * 0.5)],
        [(x + w / 2, top + h * 0.5), (x + w / 2, top + h)],
    ], w


LETTERS = {"J": letter_j, "T": letter_t, "Y": letter_y}


def wordmark(text, top, h, gap):
    """Letters on a baseline, centred on the tile like the mark above."""
    widths = [LETTERS[c](0.0, top, h)[1] for c in text]
    total = sum(widths) + gap * (len(text) - 1)
    cursor = (SIZE - total) / 2
    paths = []
    for c, w in zip(text, widths):
        shapes, _ = LETTERS[c](cursor, top, h)
        paths.extend(shapes)
        cursor += w + gap
    return paths


def main(path):
    canvas = Canvas(SIZE)
    tiles = placed_tiles()
    radius = TILE_RADIUS * MARK_SCALE
    letters = wordmark(TEXT, TEXT_TOP, TEXT_HEIGHT, TEXT_GAP)
    # Shadows first, so nothing casts one onto what is in front of it.
    for x0, y0, x1, y1, _, _ in tiles:
        for grow, a in SHADOW_PASSES:
            canvas.rounded_rect(x0, y0 + SHADOW_OFFSET, x1, y1 + SHADOW_OFFSET, radius, (0, 0, 0), a, grow)
    for pts in letters:
        for grow, a in SHADOW_PASSES:
            canvas.stroke([(x, y + SHADOW_OFFSET) for x, y in pts], TEXT_WIDTH + grow, (0, 0, 0), a)
    for tile in tiles:
        x0, y0, x1, y1, color, _ = tile
        canvas.rounded_rect(x0, y0, x1, y1, radius, color)
        for gx0, gy0, gx1, gy1 in glyph_boxes(tile):
            canvas.rounded_rect(gx0, gy0, gx1, gy1, (gy1 - gy0) / 2, INK)
    for pts in letters:
        canvas.stroke(pts, TEXT_WIDTH, CREAM)
    print(f"wrote {path} ({canvas.write_png(path)} bytes)")


if __name__ == "__main__":
    main(sys.argv[1] if len(sys.argv) > 1 else "AppIcon.png")
