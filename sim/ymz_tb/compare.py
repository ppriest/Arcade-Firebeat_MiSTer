#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Compare ymz_tb's 88.2 kHz output with MAME's 44.1 kHz recording of the YMZ280B alone.

    python sim/ymz_tb/compare.py RAW FIRST_SAMPLE WAV

RAW is s16 (out_l, out_r) per sample from sample FIRST_SAMPLE; the WAV's left is the chip's output 1
(firebeat.cpp routes them crossed). Pairs of samples are averaged to 44.1 kHz and the lag giving the
least error is searched over +-64 output samples. Prints the error relative to the signal per
second of overlap.
"""
import sys
import wave
import numpy as np

raw, first, wp = sys.argv[1], int(sys.argv[2]), sys.argv[3]
r = np.fromfile(raw, dtype="<i2").reshape(-1, 2).astype(np.float64)
w = wave.open(wp)
m = np.frombuffer(w.readframes(w.getnframes()), dtype="<i2").reshape(-1, 2).astype(np.float64)
if first & 1:
    r, first = r[1:], first + 1
r = r[: len(r) // 2 * 2]
d = (r[0::2] + r[1::2]) / 2                    # 44.1 kHz
d = d[:, ::-1]                                 # speaker L = chip output 1
s0 = first // 2
n = min(len(d), len(m) - s0 - 64)
best = None
for lag in range(-64, 65):
    seg = m[s0 + lag: s0 + lag + n]
    e = np.sum((seg - d[:n]) ** 2)
    if best is None or e < best[0]:
        best = (e, lag)
lag = best[1]
seg = m[s0 + lag: s0 + lag + n]
err = seg - d[:n]
print(f"lag {lag} samples at 44.1 kHz; overall error/signal {np.sqrt(np.sum(err**2) / max(np.sum(seg**2), 1)):.4f}, "
      f"max |err| {np.abs(err).max():.0f}, signal rms {np.sqrt(np.mean(seg**2)):.0f}")
for sec in range(0, n // 44100):
    a, b = sec * 44100, (sec + 1) * 44100
    ps, pe = np.sum(seg[a:b] ** 2), np.sum(err[a:b] ** 2)
    if ps > 0 or pe > 0:
        print(f"  t={(s0 + lag + a) / 44100:7.1f}s  rms {np.sqrt(ps / 44100 / 2):7.0f}  err/sig {np.sqrt(pe / max(ps, 1)):.4f}")
