#!/usr/bin/env python3
"""Renders Assets.xcassets/AppIcon.appiconset/AppIcon.png.

    python3 tools/make_app_icon.py app/JTTY/Assets.xcassets/AppIcon.appiconset/AppIcon.png

Three message tiles on the dark slate shared with the other shack apps:
teal, sand and salmon, each carrying a short run of dots and dashes in the
slate. Keyboard-to-keyboard on the air is a conversation, and this is the
family's picture of one.
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

# Tiles as (left, top, right, bottom, colour, glyphs). Glyph runs are strings
# of '.' and '-', centred in the tile.
TILES = [
    (186, 212, 584, 392, TEAL, "-.-"),
    (390, 400, 776, 578, SAND, "..."),
    (204, 592, 450, 770, SALMON, "-"),
]
TILE_RADIUS = 64.0
DOT = 46.0            # glyph height and dot diameter
DASH = 92.0           # dash length
GLYPH_GAP = 26.0

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


def glyph_boxes(tile):
    x0, y0, x1, y1, _, run = tile
    widths = [DASH if g == "-" else DOT for g in run]
    total = sum(widths) + GLYPH_GAP * (len(run) - 1)
    cx, cy = (x0 + x1) / 2, (y0 + y1) / 2
    cursor = cx - total / 2
    boxes = []
    for w in widths:
        boxes.append((cursor, cy - DOT / 2, cursor + w, cy + DOT / 2))
        cursor += w + GLYPH_GAP
    return boxes


def main(path):
    canvas = Canvas(SIZE)
    for tile in TILES:
        x0, y0, x1, y1, _, _ = tile
        for grow, a in SHADOW_PASSES:
            canvas.rounded_rect(x0, y0 + SHADOW_OFFSET, x1, y1 + SHADOW_OFFSET, TILE_RADIUS, (0, 0, 0), a, grow)
    for tile in TILES:
        x0, y0, x1, y1, color, _ = tile
        canvas.rounded_rect(x0, y0, x1, y1, TILE_RADIUS, color)
        for gx0, gy0, gx1, gy1 in glyph_boxes(tile):
            canvas.rounded_rect(gx0, gy0, gx1, gy1, DOT / 2, INK)
    print(f"wrote {path} ({canvas.write_png(path)} bytes)")


if __name__ == "__main__":
    main(sys.argv[1] if len(sys.argv) > 1 else "AppIcon.png")
