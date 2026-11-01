# SPDX-License-Identifier: GPL-3.0-or-later
"""Summarise a scripts/mame/popn_spu.lua capture: traffic per SPU register block, the SPU ATA
commands, DMA destinations, wave-bank values, RF5C400 write rate and how much wave RAM is used.

    python scripts/popn_spu_stats.py debug/popn4-spu
"""
import collections
import sys
from pathlib import Path

BLOCKS = [  # firebeat.cpp spu_map
    (0x200000, 0x200001, "DSW"), (0x220000, 0x220001, "LED"), (0x230000, 0x230001, "IRQ ack"),
    (0x240000, 0x240003, "DMA low"), (0x250000, 0x250003, "DMA high"),
    (0x260000, 0x260001, "wave bank"), (0x280000, 0x2807ff, "DPRAM"),
    (0x300000, 0x30000f, "ATA cs0"), (0x340000, 0x34000f, "ATA cs1"),
]


def block(addr):
    for lo, hi, name in BLOCKS:
        if lo <= addr <= hi:
            return name
    return f"other {addr:06X}"


def main(d):
    d = Path(d)
    count = collections.Counter()
    first = {}
    banks, dma_hi, dma_lo, cmds = collections.Counter(), [], [], []
    ppc_frames = collections.Counter()
    last_frame = 0
    for line in open(d / "spu.txt"):
        if line[0] == "#":
            continue
        t, fr, side, rw, addr, data, mask = line.split()
        addr, data, fr = int(addr, 16), int(data, 16), int(fr)
        last_frame = fr
        key = ("PPC DPRAM" if side == "P" else block(addr)) + " " + rw
        count[key] += 1
        first.setdefault(key, fr)
        if side == "P":
            ppc_frames[fr] += 1
            continue
        if rw == "W" and key.startswith("wave bank"):
            banks[data & 0xffff] += 1
        if rw == "W" and key.startswith("DMA high"):
            dma_hi.append((fr, data & 0xffff))
        if rw == "W" and key.startswith("DMA low"):
            dma_lo.append((fr, data & 0xffff))
        # ATA command register: cs0 register 7, the word at 30000E
        if rw == "W" and 0x300000 <= addr <= 0x30000f and (addr & 0xe) == 0xe:
            cmds.append((fr, data & 0xffff))
    print(f"frames 0..{last_frame}")
    print("\naccesses (first frame):")
    for k in sorted(count):
        print(f"  {k:16s} {count[k]:9d}  ({first[k]})")
    busiest = max(ppc_frames.values()) if ppc_frames else 0
    print(f"\nPPC DPRAM accesses, busiest frame: {busiest}")
    print(f"\nwave bank writes by value: {dict(sorted(banks.items()))}")
    print(f"DMA address writes: {len(dma_lo)} low, {len(dma_hi)} high; "
          f"high values {sorted(set(v for _, v in dma_hi))[:16]}")
    print(f"\nATA commands ({len(cmds)}):")
    by = collections.Counter(c for _, c in cmds)
    for c, n in sorted(by.items()):
        print(f"  {c:04X} x{n}  first frame {next(f for f, x in cmds if x == c)}")

    rf = collections.Counter()
    nrf, t0, t1 = 0, None, None
    for line in open(d / "rf5c.txt"):
        if line[0] == "#":
            continue
        t, fr, rw, off, data, mask = line.split()
        nrf += 1
        rf[rw] += 1
        t = float(t)
        t0 = t if t0 is None else t0
        t1 = t
    if nrf:
        print(f"\nRF5C400: {nrf} accesses ({dict(rf)}), {nrf / max(t1 - t0, 1e-9):.0f}/s "
              f"from {t0:.2f}s to {t1:.2f}s")

    w = (d / "waveram.bin").read_bytes()
    used = sum(1 for i in range(0, len(w), 0x10000) if any(w[i:i + 0x10000]))
    top = max((i for i in range(0, len(w), 0x10000) if any(w[i:i + 0x10000])), default=-1)
    print(f"\nwave RAM: {used} of {len(w) // 0x10000} 64 KB blocks non-zero, "
          f"highest at {top:#x} ({(top + 0x10000) / 2**20:.1f} MB)")


if __name__ == "__main__":
    main(sys.argv[1])
