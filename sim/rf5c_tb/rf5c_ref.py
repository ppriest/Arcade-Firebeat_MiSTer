#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""The RF5C400 bench's reference: MAME's rf5c400.cpp sample loop in doubles, as firebeat_popn
mixes it, from a scripts/mame/popn_rf5c.lua capture. Writes the bench's stimulus and the
expected output for a window, and checks the model against MAME's own -samplerate 44100 .wav.

    python sim/rf5c_tb/rf5c_ref.py <capture dir> <out dir> <from s> <to s>

Stimulus, by output sample index k (44.1 kHz from time 0):
    regs.bin  "<IHH" k, word offset, data: register writes, the memory window's excepted
    mem.bin   "<IIH" k, word address, data: wave RAM as the window writes it and, from the
              read log, as the chip found it when read (MAME's DMA writes are invisible to
              taps). A read's value is applied LEAD seconds before its time stamp, which is
              the stream update that read it, not the sample's own time.
    ref.bin   "<hh" per sample of the window: the model's left and right, 0.5 x the sums
              toward zero, as MAME's .wav has them
MAME applies a write at its stream's next update, not at the write's time; the .wav check
searches for that offset, for each side.
"""
import math
import sys
from array import array
from pathlib import Path

import numpy as np

FS = 44100
CLOCK = 16934400
LEAD = 0.025
PH_NONE, PH_ATTACK, PH_DECAY, PH_RELEASE = 0, 1, 2, 3


def tables():
    vol, mx = [], 255.0
    for _ in range(256):
        vol.append(int(mx) & 0xFFFF)
        mx /= math.pow(10.0, (4.5 / (256.0 / 16.0)) / 20)
    pan = [math.sqrt(0x47 - i) / math.sqrt(0x47) if i < 0x48 else 0.0 for i in range(256)]
    rate = CLOCK // 384

    def env(speed, lo, hi, sign):
        r = sign / (speed * rate)
        return [(1.0 if sign > 0 else r) if i < lo else r * (hi - i) / (hi - lo) if i < hi else 0.0
                for i in range(0x9F)]
    return vol, pan, env(0.1, 0x02, 0x80, 1.0), env(2.0, 0x20, 0x73, -5.0), env(0.7, 0x20, 0x54, -5.0)


VOL, PAN, AR, DR, RR = tables()


def d80(v):
    return (v & 0x7F) + 0x1F if v & 0x80 else v


def i32(x):
    return int(x)          # C's double-to-int: toward zero


def s16(v):
    return v - 0x10000 if v & 0x8000 else v


class Chan:
    def __init__(self):
        self.r = [0] * 32
        self.step = 0
        self.pos = 0
        self.phase = PH_NONE
        self.level = 0.0
        self.estep = 0.0


class Model:
    def __init__(self, mem):
        self.mem = mem
        self.ch = [Chan() for _ in range(32)]

    def write(self, off, d):
        if off >= 0x400:
            c = self.ch[(off >> 5) & 0x1F]
            c.r[off & 0x1F] = d
            if off & 0x1F == 2:
                c.step = ((d & 0x1FFF) << (d >> 13)) * 4
        elif off == 1:
            c = self.ch[d & 0x1F]
            if d & 0x60 == 0x60:
                c.pos = (((c.r[0] & 0xFF00) << 8) | c.r[1]) << 16
                c.phase, c.level, c.estep = PH_ATTACK, 0.0, AR[d80(c.r[9] >> 8)]
            elif d & 0x60 == 0x40:
                if c.phase != PH_NONE:
                    c.phase = PH_RELEASE
                    c.estep = 0.0 if c.r[0xE] & 0x80 else RR[d80(c.r[0xE] >> 8)]
            else:
                c.phase, c.level, c.estep = PH_NONE, 0.0, 0.0

    def sample(self):
        l = r = 0
        for c in self.ch:
            if c.phase == PH_NONE:
                continue
            start = ((c.r[0] & 0xFF00) << 8) | c.r[1]
            end = ((c.r[4] & 0xFF) << 16) | c.r[3]
            loop = ((c.r[4] & 0xFF00) << 8) | c.r[5]
            if start == end:
                continue
            tmp = s16(self.mem[(c.pos >> 16) & 0xFFFFFF])
            typ = (c.r[8] >> 8) & 0xC0
            s = tmp if typ == 0 else s16((tmp << 8) & 0xFFFF) if typ == 0x40 else \
                s16(tmp & 0xFF00) if typ == 0x80 else 0
            if s & 0x8000:
                s ^= 0x7FFF
            c.level += c.estep
            if c.phase == PH_ATTACK and c.level >= 1.0:
                c.phase, c.level = PH_DECAY, 1.0
                c.estep = 0.0 if (c.r[0xC] & 0x80) or c.r[0xC] == 0x100 else DR[d80(c.r[0xC] >> 8)]
            elif c.phase in (PH_DECAY, PH_RELEASE) and c.level <= 0.0:
                c.phase, c.level, c.estep = PH_NONE, 0.0, 0.0
            s *= VOL[c.r[8] & 0xFF]
            s = i32((s >> 9) * c.level)
            l += i32(s * PAN[c.r[6] & 0xFF])
            r += i32(s * PAN[c.r[6] >> 8])
            c.pos += c.step
            if (c.pos >> 16) > end:
                c.pos = (c.pos - (loop << 16)) & 0xFFFFFF0000
                if c.pos < start << 16:
                    c.pos = start << 16
        return l, r            # x 0.5 / 32768 is MAME's float output


def load(cap):
    regs, mem = [], []
    ext_a = ext_d = 0
    for line in open(cap / "rf5c.txt"):
        if line.startswith("#"):
            continue
        t, _, rw, off, d, _ = line.split()
        if rw != "W":
            continue
        k, off, d = math.ceil(float(t) * FS), (int(off, 16) - 0x400000) >> 1, int(d, 16)
        if off in (0x09, 0x11):
            ext_a = (ext_a & ~0xFFFF) | d
        elif off == 0x12:
            ext_a = (ext_a & 0xFFFF) | (d << 16)
        elif off == 0x13:
            ext_d = d
        elif off == 0x14:
            if d & 3 == 3:
                mem.append((k, ext_a & 0xFFFFFF, ext_d))
        else:
            regs.append((k, off, d))
    rd = np.fromfile(cap / "rf5c_rd.bin", dtype=np.dtype([("t", "<f8"), ("a", "<u4"), ("d", "<u2")]))
    kr = np.floor((rd["t"] - LEAD) * FS).astype(np.int64)
    mem_k = np.concatenate([np.array([m[0] for m in mem], np.int64), kr])
    mem_a = np.concatenate([np.array([m[1] for m in mem], np.int64), (rd["a"] >> 1).astype(np.int64)])
    mem_d = np.concatenate([np.array([m[2] for m in mem], np.int64), rd["d"].astype(np.int64)])
    o = np.argsort(mem_k, kind="stable")
    return regs, mem_k[o], mem_a[o], mem_d[o]


def main():
    cap, out, t0, t1 = Path(sys.argv[1]), Path(sys.argv[2]), float(sys.argv[3]), float(sys.argv[4])
    out.mkdir(parents=True, exist_ok=True)
    k0, k1 = int(t0 * FS), int(t1 * FS)
    regs, mk, ma, md = load(cap)
    mem = np.fromfile(cap / "waveram0.bin", dtype="<u2").astype(np.int64)

    # the bench's stimulus: everything before the window is state, written at k0
    with open(out / "regs.bin", "wb") as f:
        for k, off, d in regs:
            if k < k1:
                f.write(np.array([(max(k, k0), off, d)], dtype="<u4,<u2,<u2").tobytes())
    sel = mk < k1
    np.rec.fromarrays([np.maximum(mk[sel], k0).astype("<u4"), ma[sel].astype("<u4"),
                       md[sel].astype("<u2")]).tofile(out / "mem.bin")

    m = Model(mem)
    ri, mi = 0, 0
    ref = array("h")
    raw = []
    for k in range(k0, k1):
        while mi < len(mk) and mk[mi] <= k:
            mem[ma[mi]] = md[mi]
            mi += 1
        while ri < len(regs) and max(regs[ri][0], k0) <= k:
            m.write(regs[ri][1], regs[ri][2])
            ri += 1
        l, r = m.sample()
        raw.append((l, r))
        ref.extend((max(-32768, min(32767, int(l / 2))), max(-32768, min(32767, int(r / 2)))))
    (out / "ref.bin").write_bytes(ref.tobytes())

    # against MAME's .wav, each side at its own offset: a stream update between two channels'
    # key-ons starts one a sample after the other in MAME
    wav = cap / "out44.wav"
    if wav.exists():
        import wave
        w = wave.open(str(wav))
        assert w.getframerate() == FS
        w.setpos(max(0, k0 - 4096))
        mw = np.frombuffer(w.readframes(k1 - k0 + 8192), "<i2").reshape(-1, 2).astype(np.int64)
        ours = np.trunc(np.array(raw, np.int64).reshape(-1, 2) / 2.0)
        for side in (0, 1):
            n, off = min((int((mw[o:o + len(ours), side] != ours[:, side]).sum()), o)
                         for o in range(0, min(8192, len(mw) - len(ours))))
            print(f"vs MAME's wav, {'LR'[side]}: offset {off - min(4096, k0)} samples, "
                  f"{n} of {len(ours)} differ")
    print(f"window {k0}..{k1}: {len(ref) // 2} samples, peak {max(abs(x) for x in ref)}")


if __name__ == "__main__":
    main()
