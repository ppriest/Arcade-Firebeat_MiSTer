#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Random display registers over a captured VRAM, for what ppp's two contexts do not exercise.

    python scripts/disp_random.py debug/disp-rand1 [--seed=1]
    scripts/run_verilator.sh disp_tb +vram=debug/disp-vram.raw +regs=debug/disp-rand1/regs.txt         +screen=debug/disp-rand1/screen.bin

Writes regs.txt (the register file, as regs_in.txt) and screen.bin (the expected screen, from
scripts/gcu_model.py's compose()) over a VRAM of random pixels, half with bit 15 set, written to
--vram once (seed 0) if it is missing. Covers the table's modes 0-2, repeated contexts in the layer
select, origins and sizes past the screen's edges and empty ones, unaligned bases, the four blend
modes with alpha1 0 in mode 2, and register 0x6C's inverse transparency.
"""

import argparse
import random
import sys
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).parent))
from gcu_model import Gcu, VRAM_WORDS, load_pixels, to32   # noqa: E402

# the games' mode table (k057714.cpp device_reset): visible, front porch, sync, back porch
MODES = [((640, 16, 96, 48), (480, 10, 2, 33)),
         ((512, 5, 96, 72), (384, 6, 4, 22)),
         ((800, 40, 128, 88), (600, 1, 4, 23))]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("out")
    ap.add_argument("--seed", type=int, default=1)
    ap.add_argument("--vram", default="debug/disp-vram.raw")
    a = ap.parse_args()
    if not Path(a.vram).exists():
        np.random.default_rng(0).integers(0, 1 << 32, VRAM_WORDS, dtype="<u4").tofile(a.vram)
    rnd = random.Random(a.seed)
    (hv, hf, hs, hb), (vv, vf, vs, vb) = MODES[rnd.choice((1, 1, 0, 2))]
    gcu = Gcu(load_pixels(a.vram), h_vis=hv, v_vis=vv)

    regs = {0x00: (hv - 1) << 16 | (hf - 1) << 8 | (hb - 1),
            0x04: (vv - 1) << 16 | (vf - 1) << 8 | (vb - 1),
            0x08: (hs - 1) << 24 | (vs - 1) << 16}
    gcu.layer_select = rnd.getrandbits(8) << 8 | 0x0F
    gcu.reg_6c = rnd.choice((0, 0x20, 0xFFF, 0x1, 0x10F, 0x8))
    for f in range(4):
        gcu.fx[f] = rnd.choice((0, rnd.randrange(hv), rnd.randrange(hv), rnd.randrange(1200), 0xFFFF))
        gcu.fy[f] = rnd.choice((0, rnd.randrange(vv), rnd.randrange(vv), rnd.randrange(vv), rnd.randrange(800)))
        gcu.width[f] = rnd.choice((0, hv - 1, rnd.randrange(1, hv), rnd.randrange(1, 1100), 0xFFFF))
        gcu.height[f] = rnd.choice((0, vv - 1, rnd.randrange(1, vv), rnd.randrange(1, 700), 0xFFFF))
        gcu.base[f] = rnd.choice((rnd.getrandbits(24), rnd.getrandbits(24) & ~3, rnd.getrandbits(32)))
        mode = rnd.randrange(4)
        a1 = rnd.choice((16, 16, 0, 1, rnd.randrange(32), rnd.randrange(32)))
        a2 = rnd.choice((16, 31, rnd.randrange(32)))
        gcu.alpha[f] = a1 << 7 | a2 << 2 | mode | rnd.getrandbits(1) << 15
    regs[0x10] = gcu.layer_select
    regs[0x14] = gcu.alpha[0] << 16 | gcu.alpha[1]
    regs[0x18] = gcu.alpha[2] << 16 | gcu.alpha[3]
    for f in range(4):
        regs[0x20 + 4 * f] = gcu.fy[f] << 16 | gcu.fx[f]
        regs[0x30 + 4 * f] = gcu.height[f] << 16 | gcu.width[f]
        regs[0x40 + 4 * f] = gcu.base[f]
    regs[0x6C] = gcu.reg_6c

    out = Path(a.out)
    out.mkdir(parents=True, exist_ok=True)
    with open(out / "regs.txt", "w") as f:
        for k in sorted(regs):
            f.write(f"{k:02X} {regs[k]:08X}\n")
    to32(gcu.compose()).tofile(out / "screen.bin")
    print(f"seed {a.seed}: {hv}x{vv}, layer {gcu.layer_select:04X}, 6C {gcu.reg_6c:03X}, alphas "
          + " ".join(f"{x:04X}" for x in gcu.alpha))


if __name__ == "__main__":
    main()
