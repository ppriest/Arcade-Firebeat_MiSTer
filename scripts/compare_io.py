#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Compare a bench's device-access log with MAME's io.txt, stream by stream.

    python scripts/compare_io.py debug/ppp11-boot/io.txt debug/sys_io.txt [--stream GCU_W70]

Both files hold "R|W addr mask data" lines and "F frame PC" frame markers. The streams and the
rules are sim/boot_tb's (stream_of): a stream per device, per GCU register, per I/O register; polled
status reads are not compared; runs of identical reads count once. For each stream: the entries
compared, and the first difference with its frame and line in each file.
"""

import argparse


def stream_of(rw, a, m):
    r = rw == "R"
    if a & 0xFFFFFFF0 == 0x40000000:
        return "" if (r and a == 0x40000000 and m & 0xFF000000) else ("SPU_R" if r else "SPU_W")
    if a & 0xFFFFFF00 == 0x7E800000:
        if r and a == 0x7E800078:
            return ""
        if r:
            return "GCU_VRAM_R" if a >= 0x7E800080 else "GCU_R"
        if a == 0x7E800010:
            return "GCU_W10" + ("H" if m & 0xFFFF0000 else "L")
        return "GCU_W%02X" % (a & 0xFF)
    if a & 0xFFFFFFF0 in (0x7FE00000, 0x7FE80000):
        cs1 = a & 0xFFFFFFF0 == 0x7FE80000
        if r and ((not cs1 and a == 0x7FE0000C and m & 0xFFFF) or (cs1 and a == 0x7FE8000C and m & 0xFFFF0000)):
            return ""
        if r and not cs1 and a == 0x7FE00000 and m & 0xFFFF0000:
            return "ATA_DATA"
        return "ATA_R" if r else "ATA_W"
    if a & 0xFFFFFFC0 == 0x7E000000:
        return "" if r else "RTC_W"
    if a & 0xFFFFFFC0 == 0x7E000100:
        return "RTC_XR" if r else "RTC_W"
    if 0x7D400000 <= a < 0x7DC00000:
        return "FLASH_R" if r else "FLASH_W"
    if a & 0xFFFFFFFE == 0x7D000400:
        return "YMZ_R" if r else "YMZ_W"
    if a & 0xFFFFFFF0 == 0x7DC00000:
        return ("DUART_R" if r else "DUART_W") + ("1" if a & 8 else "0")
    if 0x7D000000 <= a < 0x7D001000:
        return "IO_%s%03X" % ("R" if r else "W", a & 0xFFC)
    if a & 0xFFFF0000 == 0x70000000:
        return "XIRQ_R" if r else "XIRQ_W"
    return "OTHER_R" if r else "OTHER_W"


def load(path):
    streams = {}
    frame = 0
    with open(path) as f:
        for n, line in enumerate(f, 1):
            p = line.split()
            if not p:
                continue
            if p[0] == "F":
                frame = int(p[1])
                continue
            if p[0] not in ("R", "W") or len(p) < 4:
                continue
            a, m, d = int(p[1], 16), int(p[2], 16), int(p[3], 16)
            s = stream_of(p[0], a, m)
            if not s:
                continue
            e = (p[0], a, m, d)
            lst = streams.setdefault(s, [])
            if p[0] == "R" and lst and lst[-1][0] == e:
                continue
            lst.append((e, frame, n))
    return streams


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("mame")
    ap.add_argument("bench")
    ap.add_argument("--stream", action="append", default=[], help="only these streams")
    a = ap.parse_args()
    ms, bs = load(a.mame), load(a.bench)
    for s in sorted(set(ms) | set(bs)):
        if a.stream and s not in a.stream:
            continue
        m, b = ms.get(s, []), bs.get(s, [])
        k = next((i for i in range(min(len(m), len(b))) if m[i][0] != b[i][0]), None)
        n = min(len(m), len(b)) if k is None else k
        line = "%-12s %9d of %9d MAME, %9d bench compared" % (s, n, len(m), len(b))
        if k is not None:
            (me, mf, mn), (be, bf, bn) = m[k], b[k]
            line += "\n    DIVERGES at entry %d: MAME frame %d line %d %s %08X %08X %08X, bench frame %d line %d %s %08X %08X %08X" % (
                k, mf, mn, *me, bf, bn, *be)
        print(line)


if __name__ == "__main__":
    main()
