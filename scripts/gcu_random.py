#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""A synthetic GCU window of random commands, for what the captured windows do not exercise.

    python scripts/gcu_random.py debug/gcu-rand1 [--seed=1] [--n=400]
    scripts/run_verilator.sh gcu_tb +win=debug/gcu-rand1

Writes the files sim/gcu_tb reads (vram_in.raw, regs_in.txt, gcu_writes.txt, vram_out.raw), the
expected VRAM computed by scripts/gcu_model.py's Gcu. The commands cover x and y flip, scales from
1 to 2047 and the zero and negative ones, the four blend modes, both transparencies, characters
of both heights, the origin, nested display lists uploaded through a FIFO port, fills that cross
rows, and destinations across the 16 MB bound and above row 0 (y flip at y 0).

The model's object reads a source row whole before writing it, as the RTL does; MAME reads it a
pixel at a time, so a row whose destination overlaps its own source differs from MAME (HACKS).
"""

import argparse
import random
import sys
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).parent))
from gcu_model import Gcu, VRAM_WORDS, load_pixels, save_words   # noqa: E402

DL_BASE = 0x700000          # display lists, as word indices, out of the drawing's way


def rnd_obj(r):
    """cmd words of an object whose drawing stays small."""
    while True:
        ws = r.randint(1, 512)
        hs = r.randint(1, 64)
        xs = r.choice([r.randint(1, 2047), 64, 32, 128, r.randint(16, 200)])
        ys = r.choice([r.randint(1, 2047), 64, 16, 128, r.randint(16, 200)])
        if r.random() < 0.03:
            xs = 0
        if r.random() < 0.03:
            ys = 0
        xneg = r.random() < 0.03
        yneg = r.random() < 0.03
        wd = (ws * 65536 // xs * 64) // 65536 if xs else 0
        hd = (hs * 65536 // ys * 64) // 65536 if ys else 0
        if wd * hd <= 120_000:
            break
    ax, ay = r.randint(0, 1023), r.randint(0, 16383)
    x = r.randint(0, 1023)
    y = r.choice([r.randint(0, 2047), r.randint(8180, 8200), 0, r.randint(0, 16383)])
    rel = r.random() < 0.3
    if r.random() < 0.25:
        # the source on or beside the destination: rows drawn change rows still to be read
        rel = False
        y = r.randint(8, 2000)
        x = r.randint(0, 1023)
        ay = max(0, y + r.randint(-6, 6))
        ax = max(0, min(1023, x + r.randint(-40, 40)))
    xf, yf = r.random() < 0.5, r.random() < 0.5
    blend = r.randint(0, 3)
    tr = r.randint(0, 3)
    a = [r.randint(0, 31) for _ in range(4)]
    c0 = (5 << 29) | (rel << 28) | (ay << 10) | ax
    c1 = (tr << 30) | (blend << 28) | (yf << 27) | (xf << 26) | (y << 10) | x
    c2 = (a[0] << 27) | (a[1] << 22) | (xneg << 21) | ((xs & 0x7FF) << 10) | (ws - 1)
    c3 = (a[2] << 27) | (a[3] << 22) | (yneg << 21) | ((ys & 0x7FF) << 10) | (hs - 1)
    return [c0, c1, c2, c3]


def rnd_fill(r):
    w, h = r.randint(1, 1024), r.randint(1, 24)
    x, y = r.randint(0, 1023), r.randint(0, 16383)
    rel = r.random() < 0.3
    c0 = (4 << 29) | (rel << 28) | ((h - 1) << 10) | (w - 1)
    c1 = (y << 10) | x
    return [c0, c1, r.getrandbits(32), r.getrandbits(32)]


def rnd_char(r):
    addr = r.randint(0, 0xFFFFFF)
    x, y = r.randint(0, 1023), r.randint(0, 16383)
    rel = r.random() < 0.3
    dh, tr = r.random() < 0.5, r.random() < 0.5
    c0 = (r.choice([6, 7]) << 29) | (rel << 28) | addr
    c1 = (tr << 30) | (dh << 24) | (y << 10) | x
    return [c0, c1, r.getrandbits(32), r.getrandbits(32)]


def rnd_origin(r):
    return [3 << 29, 0, r.randint(0, 1023), r.randint(0, 16383)]


def rnd_cmd(r):
    k = r.random()
    if k < 0.5:
        return rnd_obj(r)
    if k < 0.7:
        return rnd_fill(r)
    if k < 0.9:
        return rnd_char(r)
    return rnd_origin(r)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("dir")
    ap.add_argument("--seed", type=int, default=1)
    ap.add_argument("--n", type=int, default=400)
    ap.add_argument("--upto", type=int, default=0, help="expected VRAM after the first N writes only")
    args = ap.parse_args()
    r = random.Random(args.seed)
    d = Path(args.dir)
    d.mkdir(parents=True, exist_ok=True)

    rng = np.random.default_rng(args.seed)
    pix = rng.integers(0, 65536, size=2 * VRAM_WORDS, dtype=np.uint16)
    save_words(pix).tofile(d / "vram_in.raw")

    # port 0 collects commands; port 1 writes VRAM words
    regs = {a: 0 for a in range(0, 0x100, 4)}
    regs[0x68] = 0x01000000
    with open(d / "regs_in.txt", "w") as f:
        for a, v in regs.items():
            f.write(f"{a:02X} {v:08X}\n")

    wr = []

    def w(a, v, m=0xFFFFFFFF):
        wr.append((0x7E800000 + a, m, v & 0xFFFFFFFF))

    def cmd(c):
        for x in c:
            w(0x70, x)

    dl = DL_BASE
    for _ in range(args.n):
        k = r.random()
        if k < 0.85:
            cmd(rnd_cmd(r))
        else:
            # a list of a few commands, sometimes calling a second list, uploaded through port 1
            inner = []
            if r.random() < 0.5:
                inner = [rnd_cmd(r) for _ in range(r.randint(1, 4))] + [[2 << 29, 0, 0, 0]]
            inner_at = dl
            dl += 4 * len(inner) + 4
            outer = [rnd_cmd(r) for _ in range(r.randint(1, 6))]
            if inner:
                outer.insert(r.randint(0, len(outer)), [(1 << 29) | (2 * inner_at), 0, 0, 0])
            outer.append([2 << 29, 0, 0, 0] if r.random() < 0.8 else [0, 0, 0, 0])
            outer_at = dl
            dl += 4 * len(outer) + 4
            if not outer[-1][0]:
                outer.append([2 << 29, 0, 0, 0])
                dl += 4
            for at, lst in ((inner_at, inner), (outer_at, outer)):
                if not lst:
                    continue
                w(0x64, 2 * at)
                for c in lst:
                    for x in c:
                        w(0x74, x)
            cmd([(1 << 29) | (2 * outer_at), 0, 0, 0])

    with open(d / "gcu_writes.txt", "w") as f:
        for a, m, v in wr:
            f.write(f"W {a:08X} {m:08X} {v:08X}\n")

    gcu = Gcu(pix.copy())
    for a, v in regs.items():
        if (a < 0x60 and a not in (0x54, 0x58)) or a in (0x60, 0x64, 0x68, 0x6C):
            gcu.write(a, v, 0xFFFFFFFF)
    for a, m, v in (wr[:args.upto] if args.upto else wr):
        gcu.write(a, v, m)
    save_words(gcu.vram).tofile(d / "vram_out.raw")
    print(f"{len(wr)} writes; stats {dict((k, v) for k, v in gcu.stats.items() if v)}")


if __name__ == "__main__":
    main()
