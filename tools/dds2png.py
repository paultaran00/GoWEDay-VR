"""Convert an uncompressed DDS (as written by DirectXTK SaveDDSTextureToFile) to a downscaled PNG.

usage: python -I dds2png.py <in.dds> <out.png> [scale=4]
Handles B8G8R8A8 / R8G8B8A8 / R10G10B10A2 / R16G16B16A16_FLOAT. Prints the format and a brightness summary.
"""
import struct
import sys
import zlib

import array

src, dst = sys.argv[1], sys.argv[2]
scale = int(sys.argv[3]) if len(sys.argv) > 3 else 4
d = open(src, 'rb').read()
assert d[:4] == b'DDS ', 'not a DDS file'
h, w = struct.unpack_from('<II', d, 12)
pitch = struct.unpack_from('<I', d, 20)[0]
fourcc = d[84:88]
off = 128
fmt = None
if fourcc == b'DX10':
    fmt = struct.unpack_from('<I', d, 128)[0]
    off = 148
else:
    rmask = struct.unpack_from('<I', d, 92)[0]
    fmt = 87 if rmask == 0x00ff0000 else 28
bpp = {87: 4, 88: 4, 90: 4, 91: 4, 28: 4, 29: 4, 27: 4, 24: 4, 23: 4, 10: 8, 2: 16}[fmt]
row = w * bpp
print(f'{w}x{h} DXGI format {fmt}')


def half(v):
    s, e, m = v >> 15, (v >> 10) & 0x1f, v & 0x3ff
    if e == 0:
        f = m / 1024 * 2 ** -14
    elif e == 31:
        f = 65504.0
    else:
        f = (1 + m / 1024) * 2 ** (e - 15)
    return -f if s else f


def pixel(x, y):
    o = off + y * row + x * bpp
    if fmt in (87, 88, 90, 91):
        b, g, r = d[o], d[o + 1], d[o + 2]
    elif fmt in (28, 29, 27):
        r, g, b = d[o], d[o + 1], d[o + 2]
    elif fmt in (24, 23):
        v = struct.unpack_from('<I', d, o)[0]
        r, g, b = (v & 1023) >> 2, ((v >> 10) & 1023) >> 2, ((v >> 20) & 1023) >> 2
    else:
        hr, hg, hb = struct.unpack_from('<3H', d, o)
        r, g, b = (max(0, min(255, int((half(c) / (1 + half(c))) ** (1 / 2.2) * 255))) if half(c) > 0 else 0 for c in (hr, hg, hb))
    return r, g, b


W, H = w // scale, h // scale
raw = bytearray()
white = black = 0
for y in range(H):
    raw.append(0)
    for x in range(W):
        r, g, b = pixel(x * scale, y * scale)
        raw += bytes((r, g, b))
        lum = (r + g + b) // 3
        white += lum > 240
        black += lum < 10
png = b'\x89PNG\r\n\x1a\n'
for tag, body in ((b'IHDR', struct.pack('>IIBBBBB', W, H, 8, 2, 0, 0, 0)), (b'IDAT', zlib.compress(bytes(raw), 6)), (b'IEND', b'')):
    png += struct.pack('>I', len(body)) + tag + body + struct.pack('>I', zlib.crc32(tag + body) & 0xffffffff)
open(dst, 'wb').write(png)
n = W * H
print(f'saved {dst} {W}x{H}  white={100 * white // n}%  black={100 * black // n}%')
