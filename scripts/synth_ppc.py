#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Phase 0 item 3: fit the PPC403GCX core alone (rtl/synth_ppc) at given clocks and seeds.

    python scripts/synth_ppc.py --mhz 66 --mhz 50.35 --seed 1 --seed 2 --seed 3

Each run is a copy of rtl/synth_ppc in build/synth_ppc/<mhz>_s<seed>/ with the period and seed
set; the table goes to build/synth_ppc/summary.txt. Refuses to start while a JTAG session holds
or wants the Blaster (scripts/hwlock.py).
"""
import argparse
import re
import shutil
import subprocess
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO / "scripts"))
from coretools import quartus_bin  # noqa: E402
from hwlock import require_no_jtag  # noqa: E402

SRC = REPO / "rtl" / "synth_ppc"
OUT = REPO / "build" / "synth_ppc"


def one(mhz, seed):
    d = OUT / f"{mhz:g}_s{seed}"
    if d.exists():
        shutil.rmtree(d)
    d.mkdir(parents=True)
    for f in ("synth_top.sv", "synth_ppc.qpf"):
        shutil.copy2(SRC / f, d / f)
    cpu = (REPO / "rtl" / "cpu" / "ppc403").as_posix()
    qsf = (SRC / "synth_ppc.qsf").read_text().replace("../cpu/ppc403", cpu)
    qsf = re.sub(r"SEED \d+", f"SEED {seed}", qsf)
    (d / "synth_ppc.qsf").write_text(qsf)
    sdc = (SRC / "synth_ppc.sdc").read_text()
    sdc = re.sub(r"-period [\d.]+", f"-period {1000.0 / mhz:.3f}", sdc)
    (d / "synth_ppc.sdc").write_text(sdc)
    require_no_jtag(f"synth_ppc {mhz:g} MHz seed {seed}")
    log = open(d / "compile.log", "w")
    r = subprocess.run([str(quartus_bin() / "quartus_sh.exe"), "--flow", "compile", "synth_ppc"],
                       cwd=d, stdout=log, stderr=subprocess.STDOUT)
    log.close()
    res = {"mhz": mhz, "seed": seed, "ok": r.returncode == 0}
    fit = d / "output_files" / "synth_ppc.fit.summary"
    if fit.exists():
        t = fit.read_text()
        m = re.search(r"Logic utilization \(in ALMs\) : ([\d,]+)", t)
        res["alms"] = m.group(1) if m else "?"
        m = re.search(r"Total registers : ([\d,]+)", t)
        res["regs"] = m.group(1) if m else "?"
        m = re.search(r"Total DSP Blocks : ([\d,]+)", t)
        res["dsp"] = m.group(1) if m else "?"
        m = re.search(r"Total RAM Blocks : ([\d,]+)", t)
        res["m10k"] = m.group(1) if m else "?"
    sta = d / "output_files" / "synth_ppc.sta.rpt"
    if sta.exists():
        t = sta.read_text(errors="replace")
        # worst setup slack over the corners, and the slowest corner's Fmax
        slacks = [float(x) for x in re.findall(r";\s*clk\s*;\s*(-?[\d.]+)\s*;\s*-?[\d.]+\s*;\s*\n", t)]
        setup = re.findall(r"Setup Summary.*?\n(?:.*\n){3}; clk\s*;\s*(-?[\d.]+)", t)
        res["setup"] = min(float(x) for x in setup) if setup else None
        fmax = re.findall(r";\s*([\d.]+) MHz\s*;\s*[\d.]+ MHz\s*;\s*clk", t)
        res["fmax"] = min(float(x) for x in fmax) if fmax else None
    return res


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--mhz", type=float, action="append", required=True)
    ap.add_argument("--seed", type=int, action="append", required=True)
    a = ap.parse_args()
    OUT.mkdir(parents=True, exist_ok=True)
    rows = []
    for mhz in a.mhz:
        for seed in a.seed:
            print(f"fitting {mhz:g} MHz seed {seed} ...", flush=True)
            r = one(mhz, seed)
            print(r, flush=True)
            rows.append(r)
    with open(OUT / "summary.txt", "w") as f:
        f.write("mhz seed ok alms regs m10k dsp worst_setup_ns slow_fmax_mhz\n")
        for r in rows:
            f.write(" ".join(str(r.get(k)) for k in
                             ("mhz", "seed", "ok", "alms", "regs", "m10k", "dsp", "setup", "fmax")) + "\n")
    print((OUT / "summary.txt").read_text())


if __name__ == "__main__":
    main()
