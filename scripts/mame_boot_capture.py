#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Capture a game's device accesses from power-on in MAME, for sim/board_tb's boot run.

    python scripts/mame_boot_capture.py ppp11 --frames 1800 [--nvram DIR] [--events ...]
    -> debug/<set>-boot/{io.txt, bios.bin(copy), nvram/<set>/, mame_log.txt}

io.txt is every access to the ranges scripts/mame/ppcwin.lua taps, in bus order, with a line
"F frame pc" at the end of each frame (scripts/mame/boottap.lua). The NVRAM files the run starts
from are copied in (default the installed ppp11 of debug/nvram/ppp11-installed); MAME writes its
own back into the run's directory when it exits, which is not the copy kept as nvram_start/.
No debugger: MAME runs at full speed.
"""
import argparse
import os
import shutil
import subprocess
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO / "scripts"))
from mame_capture import NO_WINDOW, mame_paths, rompath  # noqa: E402


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("game")
    ap.add_argument("--frames", type=int, default=1800)
    ap.add_argument("--nvram", default=str(REPO / "debug" / "nvram" / "ppp11-installed"))
    ap.add_argument("--events", default="")
    ap.add_argument("--out", default=None)
    ap.add_argument("--timeout", type=int, default=3600)
    a = ap.parse_args()

    mame_dir, exe = mame_paths()
    out = (Path(a.out) if a.out else REPO / "debug" / f"{a.game}-boot").resolve()
    if out.exists():
        shutil.rmtree(out)
    (out / "cfg").mkdir(parents=True)
    if a.nvram and Path(a.nvram).exists():
        shutil.copytree(Path(a.nvram), out / "nvram" / a.game)
        shutil.copytree(Path(a.nvram), out / "nvram_start")
    env = dict(os.environ, CORE_OUT=out.as_posix(), CORE_FRAMES=str(a.frames), CORE_EVENTS=a.events,
               CORE_SCRIPT=str(REPO / "scripts" / "mame" / "boottap.lua"))
    cmd = [str(exe), a.game, "-nodebug", "-nowindow", "-video", "none", "-sound", "none", "-skip_gameinfo",
           "-nothrottle", "-autoboot_delay", "0", "-autoboot_script", str(REPO / "scripts" / "mame" / "run.lua"),
           "-rompath", rompath(mame_dir), "-nvram_directory", str(out / "nvram"), "-cfg_directory", str(out / "cfg")]
    r = subprocess.run(cmd, cwd=mame_dir, env=env, capture_output=True, text=True, timeout=a.timeout, **NO_WINDOW)
    (out / "mame_log.txt").write_text(r.stdout + r.stderr)
    if (out / "lua_error.txt").exists():
        sys.exit("Lua failed: " + (out / "lua_error.txt").read_text())
    io = out / "io.txt"
    if not io.exists():
        sys.exit("no io.txt:\n" + (r.stdout + r.stderr)[-2000:])
    n = sum(1 for _ in open(io))
    print(f"{n} lines -> {io}")


if __name__ == "__main__":
    main()
