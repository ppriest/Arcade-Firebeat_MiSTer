# beatmania III controls

Research only; nothing here was run on the board. Sources: `F:` =
`E:/MAME-Checkouts/mame-firebeat/src/mame/konami/firebeat.cpp`, `D:` = `.../konami/djmain.cpp`,
`I:` = `src/emu/inpttype.ipp`, `P:` = `src/emu/ioport.cpp` (checkout commit `6d050b58d23`).
"Unverified" marks a point with no source line behind it.

## 1. Keys and panel buttons (`firebeat_bm3`)

The PPC reads 16-bit words at `7D000340-7D00035F` (F:1468, `sensor_r` F:1471-1492). Every word has
bit 8 set by MAME (`| 0x0100`); its meaning is unknown (unverified). Word offsets are
`(addr - 7D000340) / 2`.

| Word address | Port | Contents |
|---|---|---|
| `7D000340` | IO1 | P1 keys 1-5 bits 0-4, P1 Start bit 5 (F:2217-2223) |
| `7D000342` | IO2 | coin sensor bit 0 (F:2227-2228) |
| `7D000344` | IO3 | P2 keys 1-5 bits 0-4, P2 Start bit 5 (F:2230-2236) |
| `7D000346` | IO4 | unused (all `IPT_UNKNOWN`, F:2238-2239) |
| `7D000348` | | not handled, reads 0 (F:1491) |

Keys and Start are active low (F:2217-2236). Per player:

| Control | Port, bit | Level | MAME default key P1 / P2 (I:34-38, 151-155, 586-587) |
|---|---|---|---|
| Key 1 | IO1/IO3 bit 0 | low | LCtrl / A |
| Key 2 | bit 1 | low | LAlt / S |
| Key 3 | bit 2 | low | Space / Q |
| Key 4 | bit 3 | low | LShift / W |
| Key 5 | bit 4 | low | Z / E |
| Start | bit 5 | low | 1 / 2 |

Buttons outside the sensor block are on IN0, read as a byte at `7D000800` (F:785, 1021-1030):

| Control | IN0 bit | Level | MAME default key (I:625, 615-617, 34-39) |
|---|---|---|---|
| Test | 0 | low | F2 |
| Service | 1 | low | 9 |
| A | 2 | low | 0 (`IPT_SERVICE2`) |
| B | 3 | low | - (`IPT_SERVICE3`) |
| P1 Foot | 4 | **high** | X (`IPT_BUTTON6` P1) |
| P2 Foot | 5 | **high** | none (`IPT_BUTTON6` P2, I:156) |

IN2 (F:2216-2217) is all unknown; IN3 is the DIP switch (F:2017-2034).
A and B are named only "A" and "B" in the driver (F:2210-2213); their function in the game
(operator menu cursor?) is unverified.

**No Effect button.** The cabinet's effect controls are seven 5-bit dials, `EFFECT1-7`, read at
`7D000352-7D00035E`, one per word, bits 0-4 (F:1483-1489, 2247-2266; `IPT_DIAL`, sensitivity 10,
keydelta 1, 0..0x1f, wraps). What each dial is physically (the VEFX/EQ sliders or knobs) is
unverified.

**Key layout** (white/black alternation): unverified from a source. The beatmania panel is
usually described as five keys, 1, 3, 5 white and 2, 4 black; MAME's key numbers follow the
panel's left-to-right order (assumed, not stated in the driver).

### djmain (beatmania, 1997+) for comparison

Byte reads through `input_r` at `5C0000` (D:615-619, 800), ports named BTN1-3 (D:858-881), all
active low:

| Control | Port, bit |
|---|---|
| P1 keys 1-5 | BTN1 bits 4, 3, 2, 1, 0 (reversed order) |
| P2 keys 1-2 | BTN1 bits 6, 7 |
| P2 keys 3-5 | BTN2 bits 0, 1, 2 |
| Start 1 / Start 2 | BTN2 bits 4, 5 |
| Effect | BTN2 bit 6 (`IPT_START3`, key 3 by default; I has no START3 line quoted here, unverified) |
| Coin 1 | BTN2 bit 7 |
| Test / Reset / Service | BTN3 bits 0 / 1 / 2 |

So djmain has a single Effect button; Firebeat bm3 has seven dials and none.

## 2. Turntable

### Firebeat bm3

| Item | Value |
|---|---|
| Registers | P1 `7D00034A` (bits 9-8) and `7D00034C` (bits 7-0); P2 `7D00034E` and `7D000350` (F:1479-1482) |
| Width | 10 bits: `value >> 8` in the first word, `value & 0xff` in the second, each `| 0x0100` |
| Encoding | position counter, 0..1023 (`PORT_MINMAX(0x00,0x3ff)`, F:2242, 2245); MAME's model is a wrapping relative accumulator, so on the real board it is a free-running counter that wraps. Real-hardware encoder resolution and direction are unverified |
| MAME type | `IPT_TRACKBALL_X`, `PORT_SENSITIVITY(100)`, `PORT_KEYDELTA(15)`, no reverse |
| MAME wrapping | trackball is relative and wraps modulo the range (P:3627-3638, 3800-3809) |
| MAME defaults | mouse X (index 0 for P1, 1 for P2), keyboard Left/Right for P1 and D/G for P2 (I:761-762) |
| Game read pattern | **unverified**. No PPC trace was taken. A free-running counter implies the game differences successive reads, with direction from the signed difference (as djmain does, below); not checked |

For a MiSTer core: two 10-bit counters, incremented per tick clockwise and decremented
counter-clockwise, wrapping at 1024. The core must also keep the hi/lo word split above. The
sensitivity MAME applies is 100% of a mouse count = 1 counter step (`RELATIVE_PER_PIXEL` scale,
P:3681-3689); real counts per revolution are unknown, so the ticks-per-revolution should be taken
from a PPC trace or the service manual before tuning.

### djmain

Absolute 8-bit input `TT1/TT2` (`IPT_DIAL`, 0xff, sensitivity 30, keydelta 15; D:882-885)
is converted by the driver: per read of `5E0000` the select bit (D:643-647, bit 19) picks the
player; the driver takes `delta = pos - last` wrapped to +/-128 and adds `delta * 70` to a 16-bit
position that is returned in bits 8-15 (D:621-641). That is MAME's own filter, not necessarily
the hardware's; the point is that the game sees a wrapping counter and takes differences.

## 3. PlayStation controllers over SNAC

Wanted: a PS1 beatmania controller on the SNAC user port. What was found:

| Claim | Source | Status |
|---|---|---|
| The core's existing SNAC pad reader polls `01 42 00 00 00` and reads a digital pad (ID 0x41) reply; bit layout byte 4: Select L3 R3 Start Up Right Down Left, byte 5: L2 R2 L1 R1 Triangle Circle Cross Square, active low | `docs/HARDWARE_NOTES.md:349-355`; PSX_MiSTer `rtl/joypad_pad.vhd` | read |
| The PS1 beatmania controller's ID byte, reply length, key bits and turntable encoding | none found: psx-spx, PSX_MiSTer README and RTL, DuckStation `controller.cpp` (it has pop'n but no beatmania entry) | **not found, unverified** |
| usbemani-legacy emulates a PS2 pad for an IIDX controller as a plain digital pad (ID 0x41, 5Ah, two data bytes, FFh); its default key table starts SQUARE, L1, CROSS, R1, CIRCLE (keys 1-5, inferred), START and SELECT; its turntable is two d-pad directions per encoder (digital steps), not an analog axis | `github.com/progmem/usbemani-legacy` `PS2.c`, `PS2.h` | read; this is a converter's choice, not evidence of what Konami's controller sends |

Consequences for the core:

- A pad that answers as a digital pad (ID 0x41) needs no new transport: keys, Start and Select are
  button bits as above. A turntable on d-pad Up/Down (or Left/Right) is one step per poll at most;
  at the SNAC poll rate (once per frame, assumed from the pop'n reader, unverified) that caps the
  turntable at one counter step per frame, so the core should treat it as a direction/speed signal,
  not a position.
- If the original controller reports an analog axis (ID 0x73 with the turntable on a stick byte)
  that would be an 8-bit wrapping position; this is a guess, not found in any source, and needs a
  real controller on the board, read via the existing pad path, before the mapping is chosen.
- Other pad mappings (USB mouse X, a spinner, an analogue stick) feed the same 10-bit counter
  above; they are independent of the PS1 question.

## Open points

1. PS1 beatmania controller protocol (ID, bits, turntable): needs the psdevwiki Controllers page
   (403 to the fetcher) or a capture from a real controller.
2. Counts per revolution and direction of the turntable counter, and how the game reads it: needs
   a PPC trace of `7D00034A-7D000350` in the bm3 test mode (turntable check screen).
3. Meaning of bit 8 in each sensor word, the A/B buttons, and the seven effect dials.
4. White/black layout and the djmain `IPT_START3` default key: unconfirmed.
