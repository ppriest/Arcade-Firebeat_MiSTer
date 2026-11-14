# SPDX-License-Identifier: GPL-3.0-or-later
"""tb_midiout's output against its input: as MIDI messages, the output must be the input with
Local Control Off (B0 7A 00) put in between messages, and nothing else.

    python sim/midiout_tb/check.py
"""
import pathlib
import sys

HERE = pathlib.Path(__file__).parent
SEQ = [0x90, 0x3C, 0x40, 0x3E, 0x40, 0x40, 0x40, 0xB0, 0x07, 0x64, 0x0A, 0x40, 0xC0, 0x05, 0x06,
       0xF0, 0x43, 0x10, 0x4C, 0x00, 0x00, 0x7E, 0x00, 0xF7, 0x91, 0x3C, 0xF8, 0x00, 0x3E, 0x00,
       0xE0, 0x00, 0x40, 0x10, 0x40, 0xD0, 0x20, 0x21]


def messages(bs):
    """Complete messages as tuples, running status expanded; realtime bytes as their own."""
    out, rs, cur, sx = [], 0, [], None
    for b in bs:
        if b >= 0xF8:
            out.append((b,))
        elif b == 0xF0:
            sx, rs = [b], 0
        elif b == 0xF7:
            if sx is not None:
                out.append(tuple(sx + [b]))
            sx = None
        elif b & 0x80:
            sx, cur = None, []
            rs = b if b < 0xF0 else 0
            if b >= 0xF0:
                out.append((b,))
        elif sx is not None:
            sx.append(b)
        elif rs:
            cur.append(b)
            if len(cur) == (1 if (rs >> 5) == 6 else 2):
                out.append(tuple([rs] + cur))
                cur = []
    return out


game = [int(l, 16) for l in (HERE / "game_tx.txt").read_text().split()]
inp = messages(SEQ * 4 + game)
outb = [int(l, 16) for l in (HERE / "out.txt").read_text().split()]
outm = messages(outb)
lo = (0xB0, 0x7A, 0x00)
inserts = sum(1 for m in outm if m == lo)
rest = [m for m in outm if m != lo]
ok = rest == inp
if not ok:
    for i, (a, b) in enumerate(zip(rest, inp)):
        if a != b:
            print("first difference at message", i, "out", a, "in", b)
            break
    print(len(rest), "messages out,", len(inp), "in")
print(f"{'PASS' if ok and inserts > 10 else 'FAIL'}: {len(inp)} messages, {inserts} Local Off inserted, "
      f"{len(outb)} bytes out")
sys.exit(0 if ok and inserts > 10 else 1)
