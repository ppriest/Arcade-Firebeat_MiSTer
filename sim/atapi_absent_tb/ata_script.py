#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""The main ATA bus's accesses in a PPC capture (io.txt: "R|W address mask data", "F frame"), as
fb_board hands them to fb_ata: "A we cs1 off wd" (off {addr[3:2], lane[1]}, wd byte-swapped as
ata_wd), and "F" at each new frame.

    python sim/atapi_absent_tb/ata_script.py debug/bm3-boot/io.txt debug/bm3-boot/ata_script.txt
"""
import sys


def main():
    out = []
    for line in open(sys.argv[1]):
        p = line.split()
        if p and p[0] == "F":
            out.append("F")
            continue
        if len(p) != 4:
            continue
        a = int(p[1], 16)
        if a & 0xFFF00000 != 0x7FE00000 or (a >> 4) & 0xFFFF not in (0x0000, 0x8000):
            continue
        cs1 = (a >> 19) & 1
        m = int(p[2], 16)
        v = int(p[3], 16)
        for lane, lm in ((0, 0xFFFF0000), (2, 0x0000FFFF)):
            if not m & lm:
                continue
            if lane == 0:
                wd = ((v >> 16) & 0xFF) << 8 | (v >> 24) & 0xFF
            else:
                wd = (v & 0xFF) << 8 | (v >> 8) & 0xFF
            off = ((a >> 2) & 3) << 1 | (lane >> 1)
            out.append("A %d %d %d %04X" % (p[0] == "W", cs1, off, wd))
    open(sys.argv[2], "w").write("\n".join(out) + "\n")
    print("%d accesses" % sum(1 for o in out if o[0] == "A"))


if __name__ == "__main__":
    main()
