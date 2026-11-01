#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Decode the board's state dump (rtl/board/fb_dump.sv, docs/STATE.md) fetched through the mister MCP.

    python scripts/fetch_dump.py FILE [--id "<core>|<build>|<set>"]

FILE is mister_memdump of the dump's area (0x34000000, 0x2620000 bytes) then VRAM (0x30000000,
32 MB), brought over with mister_get: sim/boot_tb's +state format. Writes FILE.txt (the header,
CPU and slave-drive registers) and FILE.ata.txt (the slave's access log). --id labels them with the
core that made the dump (mister_state). A dump is read back with the RTL of the build that made
it: the register block's layout is generated from that commit (scripts/st_lists.py).
"""
import argparse, struct, sys
from pathlib import Path

DUMP_SIZE = 0x2620000
VRAM_SIZE = 0x2000000


def main():
    ap = argparse.ArgumentParser(description=__doc__.split(chr(10))[0])
    ap.add_argument("file")
    ap.add_argument("--id", default="", help="the dumping core, <core>|<build>|<set>")
    a = ap.parse_args()
    decode(Path(a.file), a.id + "|" if a.id else "")


def decode(out, pre):
    d = out.read_bytes()
    if len(d) != DUMP_SIZE + VRAM_SIZE or struct.unpack_from("<I", d, 0)[0] != 0x46425344:
        sys.exit("%s: %d bytes or a bad header; fetch again" % (out, len(d)))
    r = lambda k: struct.unpack_from("<I", d, 0x1000 + 4 * k)[0]
    count = struct.unpack_from("<I", d, 4)[0]
    summary = ("%sdump %d\nPC %08X LR %08X MSR %08X SRR0 %08X\n"
               "slave drive: status %02X error %02X command %02X, sense key %X ASC %02X ASCQ %02X, packet %08X %08X %08X\n"
               % (pre, count, r(37), r(33), r(36), r(38),
                  r(0x180), r(0x181), r(0x188), r(0x1C1), r(0x1C2), r(0x1C3),
                  r(0x180 + 25), r(0x180 + 26), r(0x180 + 27)))
    (out.parent / (out.name + ".txt")).write_text(summary)
    # the slave's access log, oldest first, in bus halfwords as scripts/mame/atatap.lua writes MAME's
    n = r(0x1800)
    with open(out.parent / (out.name + ".ata.txt"), "w") as f:
        f.write("# entry us R|W cs reg data repeats (%d entries made)\n" % n)
        for i in range(max(0, n - 1024), n):
            w0, w1 = r(0x1000 + 2 * (i % 1024)), r(0x1000 + 2 * (i % 1024) + 1)
            v = w0 & 0xFFFF
            f.write("%d %d %s %d %d %04X %d\n" % (i, w1, "W" if w0 >> 31 else "R", (w0 >> 30) & 1,
                                                (w0 >> 27) & 7, ((v & 0xFF) << 8) | (v >> 8), ((w0 >> 16) & 0x3FF) + 1))
    print(summary + "wrote %s, .txt and .ata.txt (%d log entries)" % (out, n))


if __name__ == "__main__":
    main()
