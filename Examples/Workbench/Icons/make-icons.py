#!/usr/bin/env python3
# The Workbench's icon, drawn: a blue tile, a table of rows (what a query
# brings back) and an orange dot (the live service). No image library is
# needed; run it to redraw the PNGs, which are committed.
#
#   python3 Examples/Workbench/Icons/make-icons.py
import math, os, struct, zlib

HERE = os.path.dirname(os.path.abspath(__file__))

def png(path, size, pixels):
    raw = b''.join(b'\x00' + bytes(pixels[y * size * 4:(y + 1) * size * 4]) for y in range(size))
    def chunk(kind, data):
        return struct.pack('>I', len(data)) + kind + data + struct.pack('>I', zlib.crc32(kind + data) & 0xffffffff)
    with open(path, 'wb') as f:
        f.write(b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', size, size, 8, 6, 0, 0, 0))
                + chunk(b'IDAT', zlib.compress(raw, 9)) + chunk(b'IEND', b''))

def rounded(x, y, x0, y0, x1, y1, r):
    cx = min(max(x, x0 + r), x1 - r)
    cy = min(max(y, y0 + r), y1 - r)
    return (x - cx) ** 2 + (y - cy) ** 2 <= r * r and x0 <= x <= x1 and y0 <= y <= y1

def colour(x, y):
    """The colour at (x, y) in the unit square, y down; None outside."""
    if not rounded(x, y, 0.06, 0.06, 0.94, 0.94, 0.2):
        return None
    top, bottom = (54, 110, 214), (22, 58, 140)
    t = (y - 0.06) / 0.88
    tile = tuple(round(top[i] + (bottom[i] - top[i]) * t) for i in range(3))
    if (x - 0.74) ** 2 + (y - 0.74) ** 2 <= 0.15 ** 2:
        return (255, 255, 255) if (x - 0.74) ** 2 + (y - 0.74) ** 2 > 0.12 ** 2 else (243, 156, 18)
    if rounded(x, y, 0.2, 0.22, 0.8, 0.76, 0.05):
        if y < 0.34:
            return (170, 200, 245)
        for line in (0.45, 0.56, 0.67):
            if abs(y - line) < 0.012 and 0.25 < x < 0.75:
                return (120, 150, 200)
        if abs(x - 0.42) < 0.01 and y > 0.34:
            return (200, 212, 232)
        return (255, 255, 255)
    return tile

def draw(size):
    n = 4  # samples per side, for smooth edges
    pixels = []
    for py in range(size):
        for px in range(size):
            acc = [0, 0, 0, 0]
            for sy in range(n):
                for sx in range(n):
                    c = colour((px + (sx + 0.5) / n) / size, (py + (sy + 0.5) / n) / size)
                    if c:
                        for i in range(3):
                            acc[i] += c[i]
                        acc[3] += 1
            k = acc[3]
            pixels += [acc[0] // k, acc[1] // k, acc[2] // k, 255 * k // (n * n)] if k else [0, 0, 0, 0]
    return pixels

png(os.path.join(HERE, '..', 'Workbench.png'), 256, draw(256))
appicon = os.path.join(HERE, '..', 'Assets.xcassets', 'AppIcon.appiconset')
os.makedirs(appicon, exist_ok=True)
images = []
for points in (16, 32, 128, 256, 512):
    for scale in (1, 2):
        pixels = points * scale
        name = 'icon_%dx%d%s.png' % (points, points, '@2x' if scale == 2 else '')
        png(os.path.join(appicon, name), pixels, draw(pixels))
        images.append('    { "idiom" : "mac", "size" : "%dx%d", "scale" : "%dx", "filename" : "%s" }' % (points, points, scale, name))
with open(os.path.join(appicon, 'Contents.json'), 'w') as f:
    f.write('{\n  "images" : [\n' + ',\n'.join(images) + '\n  ],\n  "info" : { "version" : 1, "author" : "xcode" }\n}\n')
with open(os.path.join(HERE, '..', 'Assets.xcassets', 'Contents.json'), 'w') as f:
    f.write('{\n  "info" : { "version" : 1, "author" : "xcode" }\n}\n')
