#!/usr/bin/env python3
"""Pack PNG images into a Windows .ico (PNG-compressed entries, Vista+).

Usage: python3 make-ico.py <out.ico> <image.png>...
Each PNG must be square; its size is read from the IHDR chunk.
"""
import struct
import sys


def png_size(data):
    if data[:8] != b"\x89PNG\r\n\x1a\n":
        raise SystemExit("not a PNG")
    width, height = struct.unpack(">II", data[16:24])
    return width, height


def main():
    if len(sys.argv) < 3:
        raise SystemExit(__doc__)
    images = []
    for path in sys.argv[2:]:
        with open(path, "rb") as f:
            data = f.read()
        w, h = png_size(data)
        images.append((w, h, data))
    images.sort(key=lambda item: item[0])
    header = struct.pack("<HHH", 0, 1, len(images))
    offset = 6 + 16 * len(images)
    entries = b""
    blobs = b""
    for w, h, data in images:
        entries += struct.pack("<BBBBHHII", w if w < 256 else 0, h if h < 256 else 0, 0, 0, 1, 32,
                               len(data), offset)
        blobs += data
        offset += len(data)
    with open(sys.argv[1], "wb") as f:
        f.write(header + entries + blobs)


main()
