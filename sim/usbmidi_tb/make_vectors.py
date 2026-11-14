# SPDX-License-Identifier: GPL-3.0-or-later
"""kbm_usbmidi's vectors from a model of the parser, written independently of the RTL.

    python sim/usbmidi_tb/make_vectors.py      (writes sim/usbmidi_tb/vectors.txt)

keyboard61.txt is a capture of a 61-key keyboard (notes 36-96, channel 1, velocity 0x50, Note On
at 0 for off, clock and active sense) through a CH345 USB MIDI cable, from winmm's midiIn: whole
messages, so running status is rebuilt here for the second pass. Commands in vectors.txt, hex:
  E e        enable
  O o s      offset index (60, 72, 84, 96, 0, 12, 24, 36, 48) and split
  B bb       send a byte at 31250 baud
  C k0 k1    expect the keys
  W ms       idle (decimal)
"""
import pathlib
import random

HERE = pathlib.Path(__file__).parent
OFFS = [60, 72, 84, 96, 0, 12, 24, 36, 48]


class Model:
    def __init__(self):
        self.on = [0] * 128
        self.rs = 0
        self.second = False
        self.d1 = 0
        self.sensed = False
        self.off = 0
        self.split = 0

    def clear(self):
        self.on = [0] * 128

    def byte(self, b):
        if b >= 0xF8:
            if b == 0xFE:
                self.sensed = True
        elif b >= 0xF0:
            self.rs = 0
        elif b & 0x80:
            self.rs, self.second = b, False
        elif self.rs:
            hi = self.rs >> 4
            if hi in (0xC, 0xD):
                self.second = False
            elif not self.second:
                self.d1, self.second = b, True
            else:
                self.second = False
                if hi in (8, 9):
                    self.on[self.d1] = int(hi == 9 and b != 0)
                if hi == 0xB and self.d1 in (120, 123):
                    self.clear()

    def keys(self):
        base = OFFS[self.off]
        w = lambda s: sum(self.on[s + i] << i for i in range(24) if s + i < 128)
        w0 = w(base)
        return w0, (w(base + 24) if self.split else w0)


out = []
m = Model()


def cmd(*a):
    out.append(" ".join(a))


def send(bs, check=True):
    for b in bs:
        cmd("B", f"{b:02X}")
        m.byte(b)
    if check:
        k0, k1 = m.keys()
        cmd("C", f"{k0:06X}", f"{k1:06X}")


def enable(e):
    cmd("E", str(e))
    if not e:
        m.clear()
        m.rs, m.sensed = 0, False


def opts(o, s):
    cmd("O", f"{o:X}", str(s))
    m.off, m.split = o, s
    k0, k1 = m.keys()
    cmd("C", f"{k0:06X}", f"{k1:06X}")


msgs = []
for line in (HERE / "keyboard61.txt").read_text().split("\n"):
    f = line.split()
    if len(f) == 4:
        st, d1, d2 = (int(x, 16) for x in f[1:])
        msgs.append([st] if st >= 0xF8 else [st, d1, d2])

# 1: the capture as sent, clock left out, default options
enable(1)
opts(0, 0)
for msg in msgs:
    if msg[0] != 0xF8:
        send(msg, check=msg[0] < 0xF0)
send([0xB0, 123, 0])

# 2: running status, realtime bytes inside messages, split from note 36
random.seed(1)
opts(7, 1)
rs = 0
for msg in msgs:
    if msg[0] >= 0xF8:
        if random.random() < 0.1:
            send(msg, check=False)
        continue
    bs = msg[1:] if msg[0] == rs else msg
    rs = msg[0]
    if random.random() < 0.3:
        bs = bs[:1] + [0xF8] + bs[1:]
    send(bs)

# 3: every offset with split, Note Off, Cn, SysEx and CC 120
for o in range(9):
    opts(o, 1)
    base = OFFS[o]
    send([0x92, base, 0x40, base + 23, 0x40, base + 24, 0x40])
    send([0x82, base + 23, 0x00])
    send([0xC0, 5, 0x91, base + 1, 0x20])
    send([0xF0, 0x7E, 0x7F, 0xF7, base + 2, 0x30])       # SysEx cancels running status
    send([0xB0, 120, 0])
# Cn with running status: one data byte each
send([0xC3, 1, 2, 3, 0x90, 0x40, 0x10])
send([0xB0, 123, 0])

# 4: active sense: held notes stay without it, clear 300 ms after it stops
enable(0)
cmd("C", "000000", "000000")
enable(1)
opts(0, 0)
send([0x90, 60, 0x50, 70, 0x50])
cmd("W", "400")
cmd("C", "000401", "000401")
send([0xFE], check=False)
cmd("W", "250")
cmd("C", "000401", "000401")
cmd("W", "100")
m.clear()
cmd("C", "000000", "000000")

(HERE / "vectors.txt").write_text("\n".join(out) + "\n")
print(len(out), "commands")
