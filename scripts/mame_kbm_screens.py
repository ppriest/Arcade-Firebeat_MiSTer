#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Keyboardmania's two screens from MAME, for sim/disp_tb (scripts/mame/kbmscreens.lua).

    python scripts/mame_kbm_screens.py --frame 4000
    -> debug/kbm-screens<frame>/
"""
import argparse
import os
import shutil
import subprocess
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO / "scripts"))
from coretools import NO_WINDOW, mame_paths, rompath  # noqa: E402


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--game", default="kbm")
    ap.add_argument("--frame", type=int, required=True)
    ap.add_argument("--nvram", default=str(REPO / "debug" / "nvram" / "kbm-installed"))
    ap.add_argument("--timeout", type=int, default=3600)
    a = ap.parse_args()

    mame_dir, exe = mame_paths()
    out = REPO / "debug" / f"{a.game}-screens{a.frame}"
    if out.exists():
        shutil.rmtree(out)
    (out / "cfg").mkdir(parents=True)
    shutil.copytree(Path(a.nvram), out / "nvram" / a.game)
    env = dict(os.environ, CORE_OUT=out.as_posix(), CORE_FRAME=str(a.frame),
               CORE_SCRIPT=str(REPO / "scripts" / "mame" / "kbmscreens.lua"))
    cmd = [str(exe), a.game, "-nodebug", "-nowindow", "-video", "none", "-sound", "none",
           "-skip_gameinfo", "-nothrottle", "-autoboot_delay", "0",
           "-autoboot_script", str(REPO / "scripts" / "mame" / "run.lua"),
           "-rompath", rompath(), "-nvram_directory", str(out / "nvram"),
           "-cfg_directory", str(out / "cfg")]
    p = subprocess.run(cmd, cwd=mame_dir, env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                       timeout=a.timeout, **NO_WINDOW)
    log = p.stdout.decode(errors="replace")
    (out / "mame_log.txt").write_text(log)
    if (out / "lua_error.txt").exists():
        sys.exit("Lua failed: " + (out / "lua_error.txt").read_text())
    if not (out / "manifest.txt").exists():
        sys.exit("no manifest written:\n" + log[-2000:])
    print((out / "manifest.txt").read_text(), end="")
    print(f"-> {out}")


if __name__ == "__main__":
    main()
