#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""A blank 1.44 MB FAT12 floppy image, as a PC formats one: what bm3 needs in its drive. A disk
without a FAT (all zeros) the game reads and ignores (HARDWARE_NOTES "bm3's floppy in MAME").

    python scripts/make_floppy.py <out.img>
"""
import struct
import sys


def blank():
    img = bytearray(1474560)
    bs = bytearray(512)
    bs[0:3] = b"\xEB\x3C\x90"
    bs[3:11] = b"MSDOS5.0"
    # bytes/sector, sectors/cluster, reserved, FATs, root entries, sectors, media, sectors/FAT,
    # sectors/track, heads, hidden, large sectors
    struct.pack_into("<HBHBHHBHHHII", bs, 11, 512, 1, 1, 2, 224, 2880, 0xF0, 9, 18, 2, 0, 0)
    bs[38] = 0x29
    struct.pack_into("<I", bs, 39, 0x12345678)
    bs[43:54] = b"NO NAME    "
    bs[54:62] = b"FAT12   "
    bs[510:512] = b"\x55\xAA"
    img[0:512] = bs
    for fat in (1, 10):
        img[fat * 512:fat * 512 + 3] = b"\xF0\xFF\xFF"
    return img


if __name__ == "__main__":
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    with open(sys.argv[1], "wb") as f:
        f.write(blank())
