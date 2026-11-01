#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Capture a window of K057714 (GCU) activity from MAME for sim/gcu_tb.

    python scripts/mame_vram_window.py ppp11 --frame 3000 --frames 8
    python scripts/mame_vram_window.py ppp11 --frame 21400 --frames 8 \
        --events 9000:IN0:10:10,9060:IN0:10:10,9200:IN0:20:10
    -> debug/<game>-vram<frame>/

MAME draws a frame's screen at the start of the frame from the state the previous one left, so the
screen belonging to the VRAM dumped at the end of frame N is frame N+1's, and the capture runs one
frame past the window:

  at the end of frame N:      vram_in, regs_in, items_in, start logging writes
  at the end of frame N+1:    screen_in (drawn from vram_in)
  at the end of frame N+F:    stop logging, vram_out, regs_out, items_out
  at the end of frame N+F+1:  screen_out (drawn from vram_out), manifest

The bench replays the write log from the first VRAM image and must reach the second, execute its
commands, and compose each end into MAME's screen.

Files:
  vram_in.raw, vram_out.raw   32 MB, the GCU's m_vram as MAME holds it (host-order 32-bit words)
  vram_in.bin, vram_out.bin   the same as 16-bit display pixels, big-endian, index = pixel
                              address (word k is {pixel 2k, pixel 2k+1}: the even pixel in a
                              word's high half, k057714.cpp:407,521)
  regs_in.txt, regs_out.txt   the 64 registers as last written, "NN XXXXXXXX" (big-endian value)
  items_in.txt, items_out.txt the GCU's save items around m_vram, which mirror those registers
  gcu_writes.txt              "W addr mask data", every register/port write in the window
  snap_in.png, snap_out.png   MAME's screenshots, and screen_in.bin/screen_out.bin as 0xFFRRGGBB
  manifest.txt                frames, save-item index, write count, per-frame GCU stats

The register file is a shadow of the writes from machine start, excluding the data ports
0x70/0x74 (a tap there would run for every VRAM word the game uploads); the display only reads
registers the game rewrites. The VRAM item is the first 32-bit save item of 8,388,608 entries
(k057714.cpp:44); a second one, if present, is Keyboardmania's unused second GCU.
"""
import argparse
import array
import os
import shutil
import subprocess
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO / "scripts"))
from coretools import NO_WINDOW, mame_paths, rompath  # noqa: E402

CHUNK = 8 << 20                      # bytes converted at a time, a multiple of 4


def be16(raw, out):
    """Rewrite host-order 32-bit VRAM words as big-endian 16-bit display pixels.

    VRAM word k holds display pixels 2k and 2k+1, the even pixel in the high half: the port
    writes whole words (k057714.cpp:407) and draw_frame() reads vram16[addr ^ 1] on a
    little-endian host (k057714.cpp:521). Written big-endian, a >u2 read of the result is
    indexed by pixel address, so pixel a is entry a and word k is {entry 2k, entry 2k+1}.
    """
    if sys.byteorder != "little":
        sys.exit("the VRAM dump is host-order; this conversion assumes a little-endian host")
    words = array.array("I")
    if words.itemsize != 4:
        sys.exit("array('I') is not 32 bits")
    with open(raw, "rb") as f, open(out, "wb") as g:
        while True:
            b = f.read(CHUNK)
            if not b:
                break
            if len(b) % 4:
                sys.exit(f"{raw}: size is not a multiple of 4")
            words.frombytes(b)
            words.byteswap()
            g.write(words.tobytes())
            del words[:]


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("game")
    ap.add_argument("--frame", type=int, required=True, help="last frame before the window")
    ap.add_argument("--frames", type=int, default=8, help="frames recorded (default 8)")
    ap.add_argument("--nvram", default=str(REPO / "debug" / "nvram" / "ppp11-installed"),
                    help="the set's NVRAM files (copied to <out>/nvram/<set>/)")
    ap.add_argument("--events", default="", help="frame:port:mask:len,... presses before the window")
    ap.add_argument("--item", type=int, default=-1, help="VRAM save-item index, if the search errs")
    ap.add_argument("--timeout", type=int, default=3600)
    a = ap.parse_args()

    mame_dir, exe = mame_paths()
    out = REPO / "debug" / f"{a.game}-vram{a.frame}"
    if out.exists():
        shutil.rmtree(out)
    (out / "cfg").mkdir(parents=True)
    if a.nvram and Path(a.nvram).exists():
        shutil.copytree(Path(a.nvram), out / "nvram" / a.game)
    env = dict(os.environ, CORE_OUT=out.as_posix(), CORE_GAME=a.game, CORE_FRAME=str(a.frame),
               CORE_FRAMES=str(a.frames), CORE_EVENTS=a.events,
               CORE_VRAM_ITEM=str(a.item),
               CORE_SCRIPT=str(REPO / "scripts" / "mame" / "vramwin.lua"))
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
    mf = out / "manifest.txt"
    if not mf.exists():
        sys.exit("no manifest written:\n" + log[-2000:])
    for name in ("vram_in.raw", "vram_out.raw"):
        if not (out / name).exists():
            sys.exit(f"{name} missing:\n" + log[-2000:])
        be16(out / name, out / name.replace(".raw", ".bin"))
    print(mf.read_text(), end="")
    for n in ("vram_in.bin", "vram_out.bin", "gcu_writes.txt"):
        print(f"  {n}: {(out / n).stat().st_size:,} bytes")
    print(f"-> {out}")


if __name__ == "__main__":
    main()
