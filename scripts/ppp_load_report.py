#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Summarise a scripts/mame/ppp_load.lua run directory.

    python scripts/ppp_load_report.py <dir> --phase attract:2700:8999 --phase play:9400:28000
        [--idle 0xLO-0xHI ...] [--top 25]

Without --idle it prints the PPC PC histogram per phase so the idle loop can be named; with it,
PPC busy % per frame (samples outside every idle range). For ppp11 (HARDWARE_NOTES, "Play"):
    --idle 0x80044C00-0x80046DFF --idle 0x80000B00-0x80000EFF
    --idle 0x80051350-0x80051450 --idle 0x80051E80-0x80051FFF Also: GCU counters, VRAM traffic, ATA
commands and data rate, YMZ280B key-ons by sample format, control_w values, the work RAM scans.
MAME runs the PPC with no cache or bus-wait model and samples come from its DRC at scheduler
boundaries, so busy figures are lower bounds.
"""
import argparse
import collections
import csv
import statistics
from pathlib import Path


def pct(v, q):
    s = sorted(v)
    return s[min(len(s) - 1, int(len(s) * q))] if s else 0


def row5(name, v, fmt="{:>10.0f}"):
    if not v:
        return f"{name:36s} (none)"
    cells = [min(v), statistics.median(v), pct(v, 0.95), pct(v, 0.99), max(v)]
    return f"{name:36s}" + "".join(fmt.format(c) for c in cells)


def swap16(x):
    return ((x & 0xff) << 8) | ((x >> 8) & 0xff)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("dir")
    ap.add_argument("--phase", action="append", default=[], help="name:first:last frame")
    ap.add_argument("--idle", action="append", default=[], help="0xLO-0xHI PC range, inclusive")
    ap.add_argument("--top", type=int, default=25)
    a = ap.parse_args()
    d = Path(a.dir)
    phases = []
    for p in a.phase:
        n, f0, f1 = p.split(":")
        phases.append((n, int(f0), int(f1)))
    idle = [tuple(int(x, 16) for x in r.split("-")) for r in a.idle]

    def phase_of(fr):
        for n, f0, f1 in phases:
            if f0 <= fr <= f1:
                return n
        return None

    # PPC
    hist = {n: collections.Counter() for n, _, _ in phases}
    busy = {n: [] for n, _, _ in phases}
    for line in open(d / "pc.txt"):
        parts = line.split()
        fr, ns = int(parts[0]), int(parts[1])
        ph = phase_of(fr)
        if not ph or ns == 0:
            continue
        idle_n = 0
        for kv in parts[2:]:
            pc, n = kv.split(":")
            pc, n = int(pc, 16), int(n)
            hist[ph][pc] += n
            if any(lo <= pc <= hi for lo, hi in idle):
                idle_n += n
        busy[ph].append(100.0 * (ns - idle_n) / ns)
    hdr = f"{'':36s}" + "".join(f"{h:>10s}" for h in ("min", "median", "p95", "p99", "max"))
    print("== PPC")
    for n, _, _ in phases:
        tot = sum(hist[n].values())
        print(f"-- {n}: {len(busy[n])} frames, {tot} samples")
        if idle:
            print(hdr)
            print(row5("busy %", busy[n], "{:>10.1f}"))
        for pc, c in hist[n].most_common(a.top):
            print(f"   {pc:08X} {100.0 * c / tot:6.2f}%")

    # GCU
    rows = list(csv.DictReader(open(d / "gcu.csv")))
    print("\n== GCU per frame")
    for n, f0, f1 in phases:
        seg = [r for r in rows if f0 <= int(r["frame"]) <= f1]
        print(f"-- {n}: {len(seg)} frames")
        print(hdr)
        for c in ("obj_cmds", "obj_src_px", "obj_dst_px", "obj_blend_px", "fill_px", "chr_px",
                  "dl_entries", "fifo_words", "rd_words", "disp_px", "vram_rd_max", "vram_wr_max"):
            print(row5(c, [int(r[c]) for r in seg]))
        acc = [int(r["obj_src_px"]) + int(r["obj_dst_px"]) + int(r["obj_blend_px"]) +
               int(r["fill_px"]) + int(r["chr_px"]) + int(r["disp_px"]) + 2 * int(r["fifo_words"]) +
               2 * int(r["rd_words"]) for r in seg]
        print(row5("16-bit VRAM accesses", acc))

    # ATA
    print("\n== ATA")
    words = list(csv.DictReader(open(d / "ata_words.csv")))
    for n, f0, f1 in phases:
        seg = [int(r["data_rd"]) for r in words if f0 <= int(r["frame"]) <= f1]
        if seg:
            print(f"-- {n}: data-register reads, 16-bit words per frame")
            print(hdr)
            print(row5("words", seg))
            print(f"   total {sum(seg) * 2} bytes over {len(seg)} frames")
    cmds = collections.Counter()
    pkts = collections.Counter()
    pkt_by_phase = collections.defaultdict(collections.Counter)
    drv = 0
    pkt = []
    in_pkt = False
    first = {}
    reads = collections.defaultdict(list)
    for line in open(d / "ata.txt"):
        if line.startswith("#"):
            continue
        fr, rw, cs, reg, data, mask = line.split()
        fr, cs, reg, data, mask = int(fr), int(cs), int(reg), int(data, 16), int(mask, 16)
        v = swap16(data >> 16 if mask == 0xFFFF0000 else data & 0xffff)
        if rw == "W" and cs == 0 and reg == 6:
            drv = (v >> 4) & 1
        if rw == "W" and cs == 0 and reg == 7:
            cmds[(drv, v & 0xff)] += 1
            in_pkt = (v & 0xff) == 0xA0
            pkt = []
        elif rw == "W" and cs == 0 and reg == 0 and in_pkt:
            pkt += [v & 0xff, v >> 8]          # ATAPI packets go low byte first
            if len(pkt) >= 12:
                op = pkt[0]
                pkts[(drv, op)] += 1
                pkt_by_phase[phase_of(fr)][(drv, op)] += 1
                first.setdefault((drv, op), (fr, " ".join(f"{b:02X}" for b in pkt[:12])))
                if op in (0x28, 0xA8):
                    lba = int.from_bytes(bytes(pkt[2:6]), "big")
                    cnt = int.from_bytes(bytes(pkt[7:9] if op == 0x28 else pkt[6:10]), "big")
                    reads[phase_of(fr)].append((fr, drv, lba, cnt))
                in_pkt = False
    print("ATA commands (drive, command): count")
    for k, c in sorted(cmds.items()):
        print(f"   drive {k[0]} cmd {k[1]:02X}: {c}")
    print("ATAPI packets (drive, opcode): count, first frame and CDB")
    for k, c in sorted(pkts.items()):
        fr, cdb = first[k]
        print(f"   drive {k[0]} op {k[1]:02X}: {c:6d}  first {fr}  {cdb}")
    for ph, cnt in pkt_by_phase.items():
        print(f"   phase {ph}: " + ", ".join(f"d{k[0]} {k[1]:02X} x{c}" for k, c in sorted(cnt.items())))

    for ph, rl in reads.items():
        blocks = sum(c for _, _, _, c in rl)
        print(f"   READ in {ph}: {len(rl)} commands, {blocks} blocks of 2048 = {blocks * 2048} bytes,"
              f" largest {max(c for *_, c in rl)} blocks, LBAs {min(l for _, _, l, _ in rl)}-"
              f"{max(l + c for _, _, l, c in rl)}")

    # YMZ280B
    print("\n== YMZ280B")
    reg = None
    writes = collections.Counter()
    keyon_mode = collections.Counter()
    keyon_by_phase = collections.defaultdict(collections.Counter)
    regs_seen = collections.Counter()
    for line in open(d / "ymz.txt"):
        if line.startswith("#"):
            continue
        fr, off, data, mask = line.split()
        fr, data, mask = int(fr), int(data, 16), int(mask, 16)
        if mask & 0xFF000000:
            reg = (data >> 24) & 0xff
        if mask & 0x00FF0000 and reg is not None:
            v = (data >> 16) & 0xff
            writes[phase_of(fr)] += 1
            regs_seen[reg] += 1
            if reg < 0x80 and (reg & 0xe3) == 0x01 and v & 0x80:
                mode = ("?", "ADPCM", "PCM8", "PCM16")[(v >> 5) & 3]
                keyon_mode[mode] += 1
                keyon_by_phase[phase_of(fr)][mode] += 1
    print("register writes by phase:", dict(writes))
    print("key-ons by sample format:", dict(keyon_mode))
    for ph, c in keyon_by_phase.items():
        print(f"   {ph}: {dict(c)}")
    print("registers written:", " ".join(f"{r:02X}" for r in sorted(regs_seen)))

    print("\n== control_w")
    vals = collections.Counter()
    for line in open(d / "control.txt"):
        fr, off, data, mask = line.split()
        vals[int(data, 16) >> 24] += 1
    print("   " + ", ".join(f"{v:02X} x{c}" for v, c in sorted(vals.items())))

    print("\n== work RAM scans")
    for line in open(d / "wram.txt"):
        print("   " + line.strip())


if __name__ == "__main__":
    main()
