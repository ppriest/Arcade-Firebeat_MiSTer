#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Replay a captured GCU window through k057714's command path, and check it.

    python scripts/gcu_model.py debug/ppp11-vram3000 [--dump]
    python scripts/gcu_model.py debug/ppp11-vram21400 [--dump] [--limit=N]

Reads vram_in.raw (the GCU's m_vram as MAME holds it, host-order 32-bit words) and
gcu_writes.txt (every write to 7E800000-7E8000FF in the window), applies them with the
register and port semantics of k057714.cpp, executes the commands the write ports collect,
and compares the result with vram_out.raw. With the command FIFO writes in the log the replay
must reach MAME's VRAM exactly; `debug/replay_writes.py` (log-only) does not.

Then composes each end with draw()/draw_frame() and compares against MAME's screens
(screen_in.bin/screen_out.bin, 0xFFRRGGBB), which checks the register decode as well.

--dump prints the workload: every command with its fields, and a summary of what the frame
does. The sim/gcu_tb bench replays the same window through the RTL.

VRAM is held here as 16-bit display pixels (pixel address = index), as captured: word k of
m_vram holds pixels 2k and 2k+1, the even pixel in the high half (k057714.cpp:407,521).
"""

import argparse
import sys
from pathlib import Path

import numpy as np

VRAM_WORDS = 8_388_608              # 32 MB of 32-bit words (k057714.cpp:41)
VRAM_PIXELS = 2 * VRAM_WORDS
VRAM_SIZE_HALF = 0x800000           # draw_object's destination bound, in pixels (G:667)
FB_PITCH = 1024


def cdiv(a, b):
    """C integer division: truncates toward zero, unlike Python's //."""
    q = abs(a) // abs(b)
    return q if (a < 0) == (b < 0) else -q


def load_pixels(raw):
    """m_vram's 32-bit words as display pixels: pixel 2k is word k's high half."""
    words = np.fromfile(raw, dtype="<u4")
    if words.size != VRAM_WORDS:
        sys.exit(f"{raw}: {words.size} words, expected {VRAM_WORDS}")
    h = words.view("<u2")
    pix = np.empty(VRAM_PIXELS, dtype="<u2")
    pix[0::2] = h[1::2]
    pix[1::2] = h[0::2]
    return pix


def save_words(pix):
    """Display pixels back to m_vram's 32-bit words (host order)."""
    h = np.empty(VRAM_PIXELS, dtype="<u2")
    h[0::2] = pix[1::2]
    h[1::2] = pix[0::2]
    return h.view("<u4")


class Gcu:
    """k057714's registers, ports and command engine, as k057714.cpp implements them."""

    def __init__(self, pix, h_vis=512, v_vis=384):
        self.vram = pix                  # 16-bit display pixels
        self.h_vis, self.v_vis = h_vis, v_vis
        # m_frame[4]
        self.base = [0] * 4
        self.width = [0] * 4
        self.height = [0] * 4
        self.fx = [0] * 4
        self.fy = [0] * 4
        self.alpha = [(16 << 7) | (16 << 2)] * 4
        self.origin_x = self.origin_y = 0
        self.layer_select = 0
        self.reg_6c = 0
        self.rd_addr = 0
        self.p_addr = [0, 0]
        self.p_mode = [0, 0]
        self.cmd_fifo = [[0, 0, 0, 0], [0, 0, 0, 0]]
        self.cmd_ptr = [0, 0]
        self.crtc = [0] * 3             # registers 0x00/0x04/0x08 as written
        self.stats = dict.fromkeys(
            ("imm_cmds", "dl_calls", "dl_entries", "dl_depth_max", "obj_cmds", "obj_src_px",
             "obj_dst_px", "obj_blend_px", "obj_clip_px", "fill_px", "chr_px", "fifo_words",
             "cmd_words"), 0)
        self.depth = 0
        self.log = []                   # commands, for --dump
        self.unknown = {}

    # ------------------------------------------------------------------ registers
    def write(self, addr, data, mask):
        addr &= 0xFF
        data &= 0xFFFFFFFF
        hi = (mask >> 16) & 0xFFFF      # ACCESSING_BITS_16_31
        lo = mask & 0xFFFF

        if addr <= 0x08:
            r = self.crtc[addr >> 2]
            self.crtc[addr >> 2] = (r & ~mask & 0xFFFFFFFF) | (data & mask)
            if addr <= 0x04 and hi:
                if addr == 0x00:
                    self.h_vis = ((data >> 16) & 0xFFFF) + 1
                else:
                    self.v_vis = ((data >> 16) & 0xFFFF) + 1
        elif addr == 0x10:
            if lo:
                self.layer_select = data & 0xFFFF
        elif addr == 0x14 or addr == 0x18:
            f0 = 0 if addr == 0x14 else 2
            if hi:
                self.alpha[f0] = (data >> 16) & 0xFFFF
            if lo:
                self.alpha[f0 + 1] = data & 0xFFFF
        elif addr == 0x1C:
            pass                        # media bus; not mapped by firebeat
        elif 0x20 <= addr <= 0x2C:
            f = (addr - 0x20) >> 2
            if hi:
                self.fy[f] = (data >> 16) & 0xFFFF
            if lo:
                self.fx[f] = data & 0xFFFF
        elif 0x30 <= addr <= 0x3C:
            f = (addr - 0x30) >> 2
            if hi:
                self.height[f] = (data >> 16) & 0xFFFF
            if lo:
                self.width[f] = data & 0xFFFF
        elif 0x40 <= addr <= 0x4C:
            self.base[(addr - 0x40) >> 2] = data
        elif addr in (0x54, 0x58):
            pass                        # external FIFO; not mapped by firebeat
        elif addr == 0x5C:
            self.rd_addr = (data & 0xFFFFFF) // 2
        elif addr == 0x60 or addr == 0x64:
            self.p_addr[(addr - 0x60) >> 2] = (data & 0xFFFFFF) // 2
        elif addr == 0x68:
            if hi:
                self.p_mode[0] = (data >> 16) & 0xFFFF
            if lo:
                self.p_mode[1] = data & 0xFFFF
        elif addr == 0x6C:
            if lo:
                self.reg_6c = data & 0xFFFF
        elif addr == 0x70 or addr == 0x74:
            p = (addr - 0x70) >> 2
            if self.p_mode[p] & 0x100:
                self.stats["cmd_words"] += 1
                self.cmd_fifo[p][self.cmd_ptr[p]] = data
                self.cmd_ptr[p] += 1
                if self.cmd_ptr[p] >= 4:
                    self.execute_command(self.cmd_fifo[p])
                    self.cmd_ptr[p] = 0
            else:
                self.stats["fifo_words"] += 1
                w = 2 * self.p_addr[p]              # a port address is a 32-bit word index
                self.vram[w] = (data >> 16) & 0xFFFF
                self.vram[w + 1] = data & 0xFFFF
                self.p_addr[p] += 1
        else:
            self.unknown[addr] = self.unknown.get(addr, 0) + 1

    # ------------------------------------------------------------------ commands
    def execute_command(self, cmd):
        self.stats["imm_cmds"] += 1
        self._exec(cmd, 0)

    def execute_display_list(self, addr):
        self.stats["dl_calls"] += 1
        self.depth += 1
        self.stats["dl_depth_max"] = max(self.stats["dl_depth_max"], self.depth)
        addr //= 2
        counter = 0
        while counter < 0x1000 and addr < VRAM_WORDS:          # VRAM_SIZE / 4 (G:953)
            cmd = [int(self.vram[2 * (addr + k)]) << 16 | int(self.vram[2 * (addr + k) + 1])
                   for k in range(4)]
            addr += 4
            self.stats["dl_entries"] += 1
            if self._exec(cmd, counter):
                break
            counter += 1
        self.depth -= 1

    def _exec(self, cmd, counter):
        command = (cmd[0] >> 29) & 7
        if command == 0:
            pass
        elif command == 1:
            self.execute_display_list(cmd[0] & 0xFFFFFF)
        elif command == 2:
            return True
        elif command == 3:
            self.origin_x = cmd[2] & 0x3FF
            self.origin_y = cmd[3] & 0x3FFF
            self.log.append(("fb_config", self.origin_x, self.origin_y))
        elif command == 4:
            self.fill_rect(cmd)
        elif command == 5:
            self.draw_object(cmd)
        else:
            self.draw_character(cmd)
        return False

    def fill_rect(self, cmd):
        x = cmd[1] & 0x3FF
        y = (cmd[1] >> 10) & 0x3FFF
        width = (cmd[0] & 0x3FF) + 1
        height = ((cmd[0] >> 10) & 0x3FF) + 1
        if cmd[0] & 0x10000000:
            x += self.origin_x
            y += self.origin_y
        colour = np.array([(cmd[2] >> 16) & 0xFFFF, cmd[2] & 0xFFFF,
                           (cmd[3] >> 16) & 0xFFFF, cmd[3] & 0xFFFF], dtype="<u2")
        # absolute x sets the pattern phase (k057714.cpp:853)
        row = colour[(x + np.arange(width)) & 3]
        addr = ((y + np.arange(height))[:, None] * FB_PITCH
                + (x + np.arange(width))[None, :]) & 0xFFFFFF
        self.vram[addr] = row[None, :]
        self.stats["fill_px"] += width * height
        self.log.append(("fill", x, y, width, height, [int(c) for c in colour]))

    def draw_object(self, cmd):
        self.stats["obj_cmds"] += 1
        address_x = cmd[0] & 0x3FF
        address_y = (cmd[0] >> 10) & 0x3FFF
        x = cmd[1] & 0x3FF
        y = (cmd[1] >> 10) & 0x3FFF
        xflip = bool(cmd[1] & 0x04000000)
        yflip = bool(cmd[1] & 0x08000000)
        blend = (cmd[1] >> 28) & 3
        trans_enable = bool(cmd[1] & 0xC0000000)
        trans_value = 0x0000 if cmd[1] & 0x80000000 else 0x8000
        width = (cmd[2] & 0x1FF) + 1
        xscale = ((cmd[2] >> 10) & 0x7FF) * (-1 if cmd[2] & 0x200000 else 1)
        a1_1 = (cmd[2] >> 22) & 0x1F
        a1_2 = (cmd[2] >> 27) & 0x1F
        height = (cmd[3] & 0x3FF) + 1
        yscale = ((cmd[3] >> 10) & 0x7FF) * (-1 if cmd[3] & 0x200000 else 1)
        a2_1 = (cmd[3] >> 22) & 0x1F
        a2_2 = (cmd[3] >> 27) & 0x1F

        if xscale == 0 or yscale == 0:
            return
        if xflip and (4 - ((width - 1) % 4)) <= (address_x % 4):
            address_x -= 4               # uint32 in MAME: can wrap (G:682)
        if yflip:
            y -= cdiv(height * 64 - 1, yscale) - cdiv((height - 1) * 64, yscale)
        if cmd[0] & 0x10000000:
            x += self.origin_x
            y += self.origin_y
        address = ((address_y << 10) | (address_x & 0xFFFFFFFF)) & 0xFFFFFFFF

        orig_height = height
        width = cdiv(cdiv(width * 65536, xscale) * 64, 65536)
        height = cdiv(cdiv(height * 65536, yscale) * 64, 65536)
        if height <= 0 or width <= 0:
            return

        self.log.append(("object", x, y, width, height, xscale, yscale, blend, trans_enable,
                         trans_value, address & 0xFFFFFF))

        u = np.arange(width, dtype=np.int64) * xscale
        src_col = u >> 6                              # arithmetic shift: negative walks back
        dst_col = np.arange(width, dtype=np.int64)
        if xflip:
            dst_col = width - 1 - dst_col
        dst_col = x + dst_col                         # ascending, whatever the flip
        src_base = address & 0xFFFFFF
        v = 0
        for j in range(height):
            py = orig_height - 1 - (v >> 6) if yflip else (v >> 6)
            v += yscale
            src = (src_base + py * FB_PITCH + src_col) & 0xFFFFFF
            pix = self.vram[src]
            fbaddr = (j + y) * FB_PITCH + dst_col
            self.stats["obj_src_px"] += width
            draw = np.ones(width, dtype=bool)
            if trans_enable:
                draw = (pix & 0x8000) == trans_value
            inb = (fbaddr >= 0) & (fbaddr < VRAM_SIZE_HALF)   # uint32 in MAME (G:723)
            self.stats["obj_clip_px"] += int((~inb).sum())
            draw &= inb
            if not draw.any():
                continue
            self.stats["obj_dst_px"] += int(draw.sum())
            fb = fbaddr[draw]
            p = pix[draw].astype(np.uint32)
            if blend:
                self.stats["obj_blend_px"] += int(draw.sum())
                d = self.vram[fb].astype(np.uint32)
                dr, dg, db = (d >> 10) & 0x1F, (d >> 5) & 0x1F, d & 0x1F
                r, g, b = (p >> 10) & 0x1F, (p >> 5) & 0x1F, p & 0x1F
                if blend == 1:
                    dr, dg, db = ((dr * a2_2 + r * a1_2) >> 4, (dg * a2_2 + g * a1_2) >> 4,
                                  (db * a2_2 + b * a1_2) >> 4)
                elif blend == 2:
                    dr, dg, db = ((dr * a2_1 + r * a1_1) >> 4, (dg * a2_1 + g * a1_1) >> 4,
                                  (db * a2_1 + b * a1_1) >> 4)
                dr, dg, db = np.minimum(dr, 31), np.minimum(dg, 31), np.minimum(db, 31)
                p = (dr << 10) | (dg << 5) | db | (p & 0x8000)
            self.vram[fb] = p.astype(np.uint16)

    def draw_character(self, cmd):
        x = cmd[1] & 0x3FF
        y = (cmd[1] >> 10) & 0x3FFF
        address = cmd[0] & 0xFFFFFF
        colour = [(cmd[2] >> 16) & 0xFFFF, cmd[2] & 0xFFFF,
                  (cmd[3] >> 16) & 0xFFFF, cmd[3] & 0xFFFF]
        if cmd[0] & 0x10000000:
            x += self.origin_x
            y += self.origin_y
        double_height = bool(cmd[1] & 0x01000000)
        trans_enable = bool(cmd[1] & 0x40000000)
        rows = 16 if double_height else 8
        self.log.append(("char", x, y, rows, address, colour, trans_enable))
        dst = [(y + j) * FB_PITCH + x for j in range(rows)]
        for j, dy in enumerate(dst):
            line = int(self.vram[address & 0xFFFFFF])
            address += 4
            for i in range(8):
                p = (line >> ((7 - i) * 2)) & 3
                if not trans_enable or (colour[p] & 0x8000):
                    self.vram[(dy + i) & 0xFFFFFF] = colour[p]
                    self.stats["chr_px"] += 1

    # ------------------------------------------------------------------ display
    def compose(self):
        """k057714's draw(): four contexts in layer order, each scaled and overwritten."""
        w, h = self.h_vis, self.v_vis
        out = np.zeros((h, w), dtype="<u2")
        inverse = (self.reg_6c & 0xF) != 0 and self.reg_6c != 0xFFF
        trans = 0x8000 if inverse else 0x0000
        for sh in (8, 10, 12, 14):
            f = (self.layer_select >> sh) & 3
            if self.height[f] == 0 or self.width[f] == 0:
                continue
            height = self.height[f] + 1
            width = self.width[f] + 1
            alpha = self.alpha[f]
            a1 = (alpha >> 7) & 0x1F
            a2 = (alpha >> 2) & 0x1F
            if (alpha & 3) == 2 and a1:
                a1 = (a2 * 16) // a1
            if self.fy[f] + height > h - 1:
                height = h - 1 - self.fy[f]
            if self.fx[f] + width > w - 1:
                width = w - 1 - self.fx[f]
            if height < 0 or width < 0:
                continue
            addr = (self.base[f] + np.arange(height + 1)[:, None] * FB_PITCH
                    + np.arange(width + 1)[None, :]) & 0xFFFFFF
            p = self.vram[addr].astype(np.uint32)
            keep = (p & 0x8000) != trans
            r = np.minimum(((p >> 10) & 0x1F) * a1 >> 4, 31)
            g = np.minimum(((p >> 5) & 0x1F) * a1 >> 4, 31)
            b = np.minimum((p & 0x1F) * a1 >> 4, 31)
            rgb = (r << 10) | (g << 5) | b
            dst = out[self.fy[f]:self.fy[f] + height + 1, self.fx[f]:self.fx[f] + width + 1]
            dst[keep] = rgb[keep].astype("<u2")
        return out


def to32(p):
    """RGB555 to MAME's 0xFFRRGGBB palette expansion (MAME's rgb_t 5->8 bits)."""
    p = p.astype(np.uint32)
    def e(v):
        return (v << 3) | (v >> 2)
    return (0xFF000000 | (e((p >> 10) & 0x1F) << 16) | (e((p >> 5) & 0x1F) << 8)
            | e(p & 0x1F)).astype("<u4")


def load_writes(path):
    wr = []
    for ln in open(path):
        if ln.strip():
            _, a, m, d = ln.split()
            wr.append((int(a, 16), int(d, 16), int(m, 16)))
    return wr


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("dir")
    ap.add_argument("--dump", action="store_true")
    ap.add_argument("--limit", type=int, default=0)
    args = ap.parse_args()
    d = Path(args.dir)

    pix = load_pixels(d / "vram_in.raw")
    gcu = Gcu(pix)
    # the register file as captured, before the window's writes
    for ln in open(d / "regs_in.txt"):
        a, v = ln.split()
        a = int(a, 16)
        if a < 0x60 and a not in (0x54, 0x58, 0x5C):
            gcu.write(a, int(v, 16), 0xFFFFFFFF)
        elif a in (0x5C, 0x60, 0x64, 0x68, 0x6C):
            gcu.write(a, int(v, 16), 0xFFFFFFFF)
    gcu.stats.update(dict.fromkeys(gcu.stats, 0))

    # the screen the captured end was drawn at, for compose()
    gcu.h_vis = ((gcu.crtc[0] >> 16) & 0xFFFF) + 1 if gcu.crtc[0] else 512
    gcu.v_vis = ((gcu.crtc[1] >> 16) & 0xFFFF) + 1 if gcu.crtc[1] else 384

    frame_in = gcu.compose()
    writes = load_writes(d / "gcu_writes.txt")
    if args.limit:
        writes = writes[:args.limit]
    for a, data, mask in writes:
        gcu.write(a, data, mask)

    ref = load_pixels(d / "vram_out.raw")
    bad = int((gcu.vram != ref).sum())
    print(f"writes {len(writes)}, commands {len(gcu.log)}, unknown registers "
          f"{sorted('%02X' % k for k in gcu.unknown)}")
    print("stats:", {k: v for k, v in gcu.stats.items() if v})
    print(f"VRAM diff: {bad} of {VRAM_PIXELS} pixels")
    if bad:
        idx = np.nonzero(gcu.vram != ref)[0][:12]
        print("  first", [(hex(int(i)), hex(int(gcu.vram[i])), hex(int(ref[i])))
                          for i in idx])

    for tag, p, screen in (("in", frame_in, d / "screen_in.bin"),
                           ("out", gcu.compose(), d / "screen_out.bin")):
        if not screen.exists():
            continue
        ref32 = np.fromfile(screen, dtype="<u4").reshape(gcu.v_vis, gcu.h_vis)
        diff = int((to32(p) != ref32).sum())
        print(f"screen {tag} diff: {diff} of {ref32.size} pixels")

    if args.dump:
        dump(gcu)


def dump(gcu):
    """The window's workload, for the RTL's design and bench."""
    fills, objs, chars = [], [], []
    for e in gcu.log:
        if e[0] == "fill":
            fills.append(e)
        elif e[0] == "object":
            objs.append(e)
        elif e[0] == "char":
            chars.append(e)
    print(f"\ncommands: {len(fills)} fill, {len(objs)} object, {len(chars)} char")
    for e in fills[:20]:
        print(f"  fill x {e[1]} y {e[2]} w {e[3]} h {e[4]} colours "
              + " ".join(f"{c:04X}" for c in e[5]))
    if objs:
        w = np.array([e[3] for e in objs])
        h = np.array([e[4] for e in objs])
        sx = np.array([e[5] for e in objs])
        sy = np.array([e[6] for e in objs])
        print(f"  object dest w: min {w.min()} max {w.max()} median {int(np.median(w))}"
              f"; h: min {h.min()} max {h.max()} median {int(np.median(h))}")
        print(f"  object xscale: {sorted(set(sx.tolist()))}")
        print(f"  object yscale: {sorted(set(sy.tolist()))}")
        print(f"  object blend: {sorted(set(e[7] for e in objs))},"
              f" transparency {sorted(set(bool(e[8]) for e in objs))}")
        for e in objs[:12]:
            print(f"  obj x {e[1]} y {e[2]} w {e[3]} h {e[4]} sx {e[5]} sy {e[6]}"
                  f" blend {e[7]} trans {e[8]} addr {e[10]:06X}")
    for e in chars[:8]:
        print(f"  char x {e[1]} y {e[2]} rows {e[3]} addr {e[4]:06X} colours "
              + " ".join(f"{c:04X}" for c in e[5]))


if __name__ == "__main__":
    main()
