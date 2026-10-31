#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Compare the flash after a sim/boot_tb run with the NVRAM the run started from and MAME's.

    python scripts/flash_compare.py debug/ppp11-flashinit [--set ppp11]

boot_tb writes <boot>/rtl_flash.bin at the end: the three 2 MB chips as SDRAM holds them (flash_main,
flash_snd1, flash_snd2). The MAME capture keeps the NVRAM its run started from in
<boot>/nvram_start/ and MAME's own after the run in <boot>/nvram/<set>/. Prints, per chip, how many
bytes differ from each, and the first one. The exit status is about MAME's: 0 when the board's
flash is MAME's byte for byte.

A chip the board has erased and reprogrammed ends up equal to the NVRAM only when MAME's run did the
same to the same bytes, so read the two columns together: RTL vs MAME's is the check; RTL vs the
start state says how much of the flash the run rewrote.
"""
import argparse
import sys
from pathlib import Path

CHIPS = ("flash_main", "flash_snd1", "flash_snd2")
SIZE = 0x200000


def load(p):
    try:
        return p.read_bytes()
    except FileNotFoundError:
        return None


def first_diff(a, b):
    n = min(len(a), len(b))
    for i in range(n):
        if a[i] != b[i]:
            return i
    return None if len(a) == len(b) else n


def compare(name, rtl, ref):
    if ref is None:
        print(f"  {name:10s} no reference file")
        return 0
    d = first_diff(rtl, ref)
    if d is None:
        print(f"  {name:10s} equal, {len(rtl)} bytes")
        return 0
    n = sum(1 for i in range(min(len(rtl), len(ref))) if rtl[i] != ref[i])
    print(f"  {name:10s} {n} of {len(ref)} bytes differ, first at 0x{d:06X}: "
          f"{rtl[d]:02X}, not {ref[d]:02X}")
    return n


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("boot", type=Path, help="the bench's directory, e.g. debug/ppp11-flashinit")
    ap.add_argument("--set", default=None, help="MAME's NVRAM directory name (default: the last part of boot)")
    a = ap.parse_args()
    setname = a.set or a.boot.name.split("-")[0]

    rtl = load(a.boot / "rtl_flash.bin")
    if rtl is None:
        sys.exit(f"no {a.boot / 'rtl_flash.bin'}: did the run finish?")
    if len(rtl) != 3 * SIZE:
        sys.exit(f"{a.boot / 'rtl_flash.bin'} is {len(rtl)} bytes, expected {3 * SIZE}")

    start = a.boot / "nvram_start"
    mame = a.boot / "nvram" / setname
    print(f"start: {start}   MAME's after the run: {mame}")
    print("against the start state")
    for k, name in enumerate(CHIPS):
        compare(name, rtl[k * SIZE:(k + 1) * SIZE], load(start / name))
    print("against MAME's")
    bad = 0
    for k, name in enumerate(CHIPS):
        bad += compare(name, rtl[k * SIZE:(k + 1) * SIZE], load(mame / name))
    print("PASS" if bad == 0 else "FAIL")
    sys.exit(0 if bad == 0 else 1)


if __name__ == "__main__":
    main()
