# SPDX-License-Identifier: GPL-3.0-or-later
"""The SPU program ROM for sim/spu_tb: a02jaa04.3q from popn4.zip, its words swapped
(ROM_LOAD16_WORD_SWAP) to the 68000's big-endian order.

    python sim/spu_tb/prep.py [--zip PATH] [--out debug/popn4-68k/spu_rom.bin]
"""
import argparse
import zipfile
from pathlib import Path

ap = argparse.ArgumentParser()
ap.add_argument("--zip", default="F:/Emulation/roms/MAME ROMs/popn4.zip")
ap.add_argument("--out", default="debug/popn4-68k/spu_rom.bin")
a = ap.parse_args()
d = zipfile.ZipFile(a.zip).read("a02jaa04.3q")
sw = bytes(b for i in range(0, len(d), 2) for b in (d[i + 1], d[i]))
Path(a.out).parent.mkdir(parents=True, exist_ok=True)
Path(a.out).write_bytes(sw)
print(f"{a.out}: SSP {int.from_bytes(sw[0:4], 'big'):08X} PC {int.from_bytes(sw[4:8], 'big'):08X}")
