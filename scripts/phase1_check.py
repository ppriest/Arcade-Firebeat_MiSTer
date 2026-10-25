#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Phase 1's exit on the board, over the stp revision's probes F and M (Firebeat.sv).

    python scripts/phase1_check.py [--set ppp11] [--nvram FILE]

With the set loaded from its .mra: reads the frame length (CLK_50M clocks, against 58.4877 Hz)
and the late scan-out lines, runs a read-back pass over the BIOS (and the flash, when --nvram
names the NVRAM file the core was given) and compares the sums with the files: the BIOS from the
set's zip (halfwords swapped, as the .mra loads it), the flash part of the NVRAM file. The board is
held in reset for the passes (source 64) and restarts after. Prints the cache port's fill
latency. Holds the JTAG lock per read.
"""
import argparse
import sys
import time
import zipfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from cdtest import probe, control  # noqa: E402
from mame_capture import load_env  # noqa: E402
import gen_mra  # noqa: E402

FRAME_HZ = 66_666_666.67 / (685 * 416 * 4)


def be_sum32(b):
    return sum(int.from_bytes(b[i:i + 4], "big") for i in range(0, len(b), 4)) & 0xFFFFFFFF


def run_pass(sel):
    control(64 | (4 if sel else 0))
    time.sleep(0.1)
    control(64 | 2 | (4 if sel else 0))
    control(64 | (4 if sel else 0))
    while True:
        time.sleep(0.5)
        if probe("F")["chk_busy"] == "no":
            break
    control(0)
    return probe("M")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--set", default="ppp11")
    ap.add_argument("--nvram", type=Path)
    a = ap.parse_args()
    env = load_env()
    zp = gen_mra.find_zip(env["MAME_ROMPATH"].split(";"), a.set)
    s = gen_mra.SETS[a.set]
    with zipfile.ZipFile(zp) as z:
        bios = gen_mra.read_crc(z, gen_mra.BIOS[1])
    bios = b"".join(bios[i + 1:i + 2] + bios[i:i + 1] for i in range(0, len(bios), 2))
    ok = True

    f = probe("F")
    hz = 50e6 / f["frame_50m"] if f["frame_50m"] else 0
    print(f"frame: {f['frame_50m']} CLK_50M clocks, {hz:.4f} Hz (expected {FRAME_HZ:.4f}); "
          f"late scan-out lines {f['scan_late']}; picture written {f['pat_done']}")
    ok &= abs(hz - FRAME_HZ) < 0.01 and f["scan_late"] == 0

    m = run_pass(0)
    want = be_sum32(bios)
    print(f"BIOS: {m['chk_lines']} lines, sum 0x{m['chk_sum']:08X} (expected 0x{want:08X}); "
          f"fill latency {m['chk_lat_sum'] / max(m['chk_lines'], 1):.2f} average, {m['chk_lat_max']} worst")
    ok &= m["chk_sum"] == want and m["chk_lines"] == 0x8000
    if a.nvram:
        nv = a.nvram.read_bytes()
        m = run_pass(1)
        fwant = be_sum32(nv[:0x600000])
        print(f"flash: {m['chk_lines']} lines, sum 0x{m['chk_sum']:08X} (expected 0x{fwant:08X})")
        ok &= m["chk_sum"] == fwant
    print("PASS" if ok else "FAIL")
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
