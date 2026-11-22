#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""bm3's FDC accesses (scripts/mame/bm3_fdc.lua's fdc.txt) as a script for sim/floppy_tb: what the
game did, by phase, so the bench can follow the controller's own timing (MSR polls dropped).

    python sim/floppy_tb/fdc_script.py <fdc.txt> <out.txt>

Lines:  W p d       a write to 0x3F0+p (not the FIFO)
        R p d       a read of 0x3F0+p, expected d (DOR, DIR, configuration)
        C b...      a command, each byte when the MSR asks for one
        A command or result byte written bb/mm: the MSR MAME read last before it was mm, which the
        bench checks in full (the seek bits included); bb alone where MAME did not read the MSR.
        I           wait for the interrupt (before a SENSE INTERRUPT that follows a seek)
        D n b...    n data bytes read, expected b... (one line)
        E n b...    n data bytes written
        S n b...    n result bytes read, expected b...; "S* ..." where MAME's transfer ended short
"""
import sys

LEN = {0x03: 3, 0x04: 2, 0x07: 2, 0x08: 1, 0x0F: 3, 0x13: 4, 0x0A: 2, 0x0D: 6, 0x05: 9, 0x06: 9,
       0x10: 1, 0x0E: 1, 0x12: 2, 0x14: 1, 0x0C: 9, 0x09: 9, 0x02: 9, 0x11: 9, 0x19: 9, 0x1D: 9}


def main():
    rows = [l.split() for l in open(sys.argv[1])]
    out = []
    msr = 0
    fresh = False         # the MSR was read since the last FIFO access

    def tag(d):
        nonlocal fresh
        t = f"{d:02X}/{msr:02X}" if fresh else f"{d:02X}"
        fresh = False
        return t
    need = 0
    cmd = []
    run = None            # ("D"|"E", [bytes]) or ("S", [bytes])
    last_cmd = None
    short = False

    def flush():
        nonlocal run
        if run:
            kind, b = run
            out.append(f"{kind} {len(b)} " + " ".join(x if isinstance(x, str) else f"{x:02X}" for x in b))
            run = None

    for f, t, rw, r, d in rows:
        p = int(r, 16) & 7
        d = int(d, 16)
        if rw == "R" and p == 4:
            msr = d
            fresh = True
            continue
        if p == 5 and (msr & 0x20):
            fresh = False
            kind = "E" if rw == "W" else "D"
            if not run or run[0] != kind:
                flush()
                run = (kind, [])
            run[1].append(d)
            continue
        if p == 5 and rw == "R":
            if not run or run[0] not in ("S", "S*"):
                if run and run[0] == "D" and last_cmd in (0x46, 0xC6, 0x06) and len(run[1]) % 18432:
                    short = True
                flush()
                run = ("S*" if short else "S", [])
                short = False
            run[1].append(tag(d))
            continue
        flush()
        if p == 5:
            if need == 0:
                if d == 0x08 and last_cmd in (0x07, 0x0F):
                    out.append("I")
                need = LEN.get(d & 0x1F, 1)
                cmd = []
            cmd.append(tag(d))
            need -= 1
            if need == 0:
                out.append("C " + " ".join(cmd))
                last_cmd = int(cmd[0][:2], 16)
            continue
        out.append(f"{rw} {p} {d:02X}")
    flush()
    with open(sys.argv[2], "w") as o:
        o.write("\n".join(out) + "\n")


if __name__ == "__main__":
    main()
