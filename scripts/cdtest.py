#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Phase 0 item 2: measure image reads on the FirebeatCD test core (rtl/cdtest) over its probes.

    python scripts/cdtest.py [--seconds 20]

With images mounted in S0 and S1 from the OSD, for each slot and for sequential then random
16 KB requests: clear the counters, run for --seconds, stop, read the slot's probe. Prints
throughput, request rate, latency to the first word, and the checksum of the image's first 4 KB
(compare with the .bin: HARDWARE_NOTES, "CD path on the board"). Holds the JTAG lock per read.
"""
import argparse
import re
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from read_issp import read  # noqa: E402

CLK_BY_PROBE = {20: 20e6, 67: 200e6 / 3}   # probe F clk_mhz -> clk_sys of the FirebeatCD build


def probe(inst):
    out = read(inst, capture=True).stdout
    v = {}
    for line in out.splitlines():
        # read() returns the Tcl output without the core|build|set| prefix read_issp.py adds
        m = re.search(r"^(?:.*\|)?\s+(\w+)\s+(0x[0-9A-Fa-f]+|\d+|yes|no)\s*$", line)
        if m:
            s = m.group(2)
            v[m.group(1)] = s if s in ("yes", "no") else int(s, 0)
    return v


def control(value):
    read("F", "set", str(value), capture=True)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--seconds", type=float, default=20)
    a = ap.parse_args()
    global CLK
    CLK = CLK_BY_PROBE[probe("F")["clk_mhz"]]
    rows = []
    for slot, inst, run_bit in ((0, "A", 2), (1, "B", 4)):
        st = probe(inst)
        if st.get("have_image") != "yes":
            print(f"slot {slot}: no image mounted")
            continue
        for mode, rnd in (("sequential", 0), ("random", 8)):
            control(1)                      # clear
            control(0)
            control(run_bit | rnd)
            time.sleep(a.seconds)
            control(0)
            v = probe(inst)
            secs = v["run_clocks"] / CLK
            mb = v["words"] * 2 / 1e6
            req = v["requests"]
            lat_avg = v["latency_sum"] / req / CLK * 1e3 if req else 0
            rows.append((slot, mode, v["image_blocks"], secs, mb / secs if secs else 0, req / secs if secs else 0,
                         lat_avg, v["latency_max"] / CLK * 1e3, v["checksum"]))
    print("slot mode        blocks     seconds  MB/s   req/s  first-word ms (avg, max)  checksum")
    for r in rows:
        print(f"{r[0]:4d} {r[1]:11s} {r[2]:9d} {r[3]:8.1f} {r[4]:6.2f} {r[5]:7.1f}  {r[6]:7.2f} {r[7]:7.2f}"
              f"            {r[8]:08X}")


if __name__ == "__main__":
    main()
