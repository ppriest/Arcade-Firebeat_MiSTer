# Firebeat: hardware notes

What the board is, from MAME, each fact with where it came from. Written before the roadmap
(the skill's SKILL.md, phase 1); the roadmap waits on the Feasibility section at the end.

Source: MAME `src/mame/konami/firebeat.cpp` (`F:` below), `src/mame/konami/k057714.cpp` (`G:`)
and the devices they instantiate, checkout `E:/mame` at `dedb5227403`
(`mame0289-1527-gdedb5227403`, branch `konamigx-esc`). `mame -listxml` and set names from the
installed vanilla MAME 0.289 (`C:/Emulation/Emulators/MAME`). The source is 1,527 commits past
the binary's tag; `git log mame0289..HEAD -- src/devices/cpu/powerpc` lists commits to the
PowerPC core (timebase read charging, `retry_access` in the DRC) that are to be diffed before a
divergence between a capture and the source is blamed on either. Everything here is MAME's model
unless marked otherwise.

## Board

GQ972 main board: PPC403GCX at 66 MHz, two Konami 0000057714 GCUs, YMZ280B, RTC65271,
PC16552D dual UART, 25.175 and 16.6666 MHz oscillators near the GCUs (F:10-18). GQ974 extend
board: FDC37C665GT, PC16552D, ADC0808 (F:20-25). GQ971 SPU: 68000 at 16 MHz, XC9572 CPLD,
RF5C400 (F:27-31). Backplane with two or three slots and one 40-pin ATA connector per slot
(F:33-41). Which boards each game has: F:49-80.

## Sets

Four families, one `machine_config` each (F:2745-2775). All 26 sets are `MACHINE_IMPERFECT_SOUND`
and nothing else; `-listxml` says `status=imperfect emulation=good sound=imperfect` for every one.

| Family | Config | Sets | BIOS (user1, 512 KB) | SPU 68k program | Media |
|---|---|---|---|---|---|
| ParaParaParadise | `firebeat_ppp` | ppp, ppp11, ppd, ppp1mp (clone of ppp) | `977jaa03.21e` | none | program CD `ata:0`, audio CD `ata:1`; ppp and ppd program CDs are BAD_DUMP |
| Keyboardmania | `firebeat_kbm` | kbm, kbh (clone), kbm2nd, kbm3rd | `974a03.21e` | none | program CD `ata:0`, audio CD `ata:1` |
| Pop'n Music | `firebeat_popn` | popn4, popn5, popn6, popn7, popn8, popnmt (+popnmt2), popnanm (+popnanma), popnanm2 (+3 clones) | `a02jaa03.21e` | `a02jaa04.3q` | program CD `ata:0`, data DVD `spu_ata:0` |
| Beatmania III | `firebeat_bm3` | bm3, bm3core, bm36th, bm37th, bm3final | `972maina01.21e` | `972spua01.3q` (bm3, bm3core), `a21jca03.3q` (the other three) | program CD `ata:0`, HDD `spu_ata:0` |

Every set also loads a 0xC8-byte dongle image (`user2`; 0xC0 and BAD_DUMP for bm36th, bm37th,
popn6, ppd, ppp1mp) and, where there is an SPU, a 0x1038-byte RTC preset (`rtc`, "default unlocked
RTC", one per set). The flash chips are not in any ROM list: their contents are written by the
game's own install from the CD (below, "Flash"). The popn revision loads the preset with the ROMs
(`053283b`); before that a first boot had an empty RTC, E165 RTC DATA ERROR, then a "system recovery
mode" asking for a password (on the board, reported by the user). A recovery password can be
computed from the RTC's contents with https://987123879113.github.io/firebeatrtc/ (not used yet).

Region CRCs across sets: four BIOS images, three SPU programs, one dongle and one RTC preset per
set. Nothing to share beyond the family.

Media per set (`-listxml` `<disk>`): one CHD per drive. **No CHD is present locally**:
`F:/Emulation/roms/MAME ROMs` has the zips (34-78 KB each) and no CHD for any firebeat set, so
nothing below is measured in MAME yet, and the sizes of the images are unknown here.

## CPUs and chips

| Tag | Part | Clock | Role | Existing RTL |
|---|---|---|---|---|
| `maincpu` | IBM PPC403GCX | 66 MHz (F:735, 1804) | main CPU. MAME runs it as a 403GA with a different PVR and aborts if the MMU is enabled (`ppccom.cpp:1353-1355`), so no set enables address translation. On-chip serial port carries the dongle (F:729, 982) | Konami Hornet `rtl/cpu/ppc403/ppc403_core.sv` (403GA from MAME's model, GPL-3.0-or-later): agrees with MAME over 2,000,000 instructions of game code; 5,896 ALMs, Fmax 64.2 MHz at a 64 MHz constraint (Hornet `docs/HARDWARE_NOTES.md`, "Feasibility" table). Same file copied into the M2 core |
| `audiocpu` | MC68000 | 16 MHz (F:1186) | SPU board CPU (popn, bm3) | fx68k (Seta, KonamiGX; 3,232-4,001 LUTs in their floorplans), or Musashi on the HPS as Hornet does (`sw/arcsnd`) |
| `gcu`, `gcu_sub` | Konami 0000057714 GCU | pixel clock 25.175 or 16.6666 MHz (F:1032-1055) | 2D blitter, display-list processor and CRTC drawing into its own VRAM; two on kbm (F:1827, 1835) | none found (GitHub code search `057714`, sibling cores). Written from `k057714.cpp`, 941 lines |
| `ymz` | Yamaha YMZ280B | 16.9344 MHz (F:763) | 8 voices, ADPCM/8/16-bit PCM, samples read from the two sound flash chips (F:800-805) | `MiSTer-devel/Arcade-Cave_MiSTer` `rtl/cave/YMZ280B.sv` (SystemVerilog, GPL-3.0; also the Chisel original in `nullobject/arcadia`). To check: 16-bit PCM and the external read path, which in MAME only firebeat uses (`ymz280b.cpp:21-24`) |
| `rf5c400` | Ricoh RF5C400 | 16.9344 MHz (F:1193) | 32-channel PCM with envelopes, 32 MB of wave RAM (F:1224-1227, `rf5c400.h:94`) | none (GitHub code search, Verilog and VHDL). MAME's model runs on the HPS in Hornet (`sw/arcsnd/hornet/rf5c400.cpp`) |
| `rtc` | Epson RTC65271 | | RTC and 4 KB NVRAM (F:791-792); per-set preset image | none |
| `flash_main`, `flash_snd1`, `flash_snd2` | Fujitsu 29F016A, 3 x 2 MB | | game program and sound samples, written at install (F:740-742, 787-789) | none; the command state machine is `intelfsh.cpp` |
| `duart_com` | PC16552D (2 x NS16550) | 19.6608 MHz (F:769-771) | network UART; MAME's handlers are commented out (F:1072-1115) | |
| `duart_midi` | PC16552D | 24 MHz (F:1431-1433, 1853-1859) | bm3: MIDI to the ST-224 effects unit; kbm: two MIDI keyboards in | |
| `spuram` | CY7C131, 1K x 8 dual-port | | PPC-68k mailbox; a write to 0x3FE interrupts the 68k, to 0x3FF the PPC (F:1189-1191) | |
| `ata` | ATA, two slots | | program CD-ROM and (ppp, kbm) audio CD-ROM; PIO through byte-swapped CS0/CS1 (F:744, 795-796) | the console cores' CD path: see Feasibility 2 |
| `spu_ata` | ATA, one slot | | bm3: HDD; popn: DVD-ROM in UDMA mode (F:397, 1416, 1521). The 68k reads it by DMA into wave RAM, one 16-bit word per 350 ns (F:1358-1375) | same |
| `fdc` | FDC37C665GT + 3.5" HD floppy | 24 MHz (F:1426-1429) | bm3 player data | none |
| `spectrum_analyzer` | 4 x NJU7507 on the extend board | | bm3: six-band level meter of the RF5C400 output, read as bytes (F:181-333) | |
| `xt446` | Yamaha XT446 (MU100-class synth: H8S/2655 + SWP30 per `-listxml`) | | kbm keyboard sounds (F:1863-1866) | none; out of reach |
| `kbd0`, `kbd1` | MIDI keyboards, 24 keys + modulation wheel | 31250 baud (F:1855-1859) | kbm | |
| dongle | DS1991 iButton through a DS2480B on the PPC's serial port | | game serial, licence period, mode switch (F:820-985) | written from F:900-985 |

## Clocks

| Clock | Used by | Source |
|---|---|---|
| 66.000 MHz | PPC403GCX | F:735 |
| 25.175 MHz | pixel, 31 kHz mode | F:752, 1041 |
| 16.6666 MHz | pixel, 24 kHz mode | F:1049 |
| 16.9344 MHz | YMZ280B, RF5C400 | F:763, 1193 |
| 16 MHz | 68000 | F:1186 |
| 19.6608 MHz | duart_com | F:770 |
| 24 MHz | duart_midi, FDC | F:1426, 1432 |
| 500 Hz | SPU 68k IRQ2/IRQ6 timer (MAME's rate, chosen by ear: F:1420-1423, 1526-1529) | F:1424, 1530 |

The plan is open; it is a Feasibility item (1) because the skill's rule (clk_sys at least every
board clock and an integer multiple of at least 4x the pixel clock) gives 4 x 25.175 = 100.7 MHz,
above the Hornet PPC core's measured 64.2 MHz. Candidates, each needing a measurement:

| clk_sys | Pixel | PPC | Cost |
|---|---|---|---|
| 50.35 MHz (2 x 25.175) | enable 1/2 | own 66 MHz domain, as Hornet runs its SHARC on `clk_dsp` through `hornet_cdc` | pixel enable at 2x, below the 4x rule: the GCU scans a frame buffer, so a line FIFO decouples the output; needs the user's agreement |
| 66 MHz | separate 25.175 MHz PLL output, line buffer crossing | enable 1 | the PPC core must close 66 MHz; Hornet's closed 64.2 at seed 0 |
| 50.35 MHz | enable 1/2 | enable 1, 24% slow | only if the measured load leaves that headroom |

The 24 kHz mode (16.6666 MHz; `control_w` bit 0, F:1032-1055) is a second pixel clock not in a
small ratio to the first (1.5105). Which sets ever select it is a measurement: log `control_w`
bit 0 and GCU registers 0x00-0x08 per set.

## Video

`screen.set_raw(25.175 MHz, 800, 0, 640, 525, 0, 480)` (F:752; kbm F:1822, 1831): 640 x 480,
31.47 kHz, 59.94 Hz, 4:3 with square pixels on a VGA-class monitor. The GCU's CRTC is programmable
(registers 0x00, 0x04, 0x08: visible, front porch, back porch, sync; G:193-226) and the games'
mode table has five modes, 640x480 of 800x525 the default and the only one beatmania III uses
(G:81-103). kbm has two screens, both `ROT270` (F:2751-2754).

The GCU (G:) is a frame-buffer chip, so the frame-buffer rule is met by the board itself:

- **VRAM**: 32 MB address space per GCU (`VRAM_SIZE` 0x2000000, G:41), 16-bit RGB555 pixels, a
  fixed pitch of 1024 pixels (G:489, 637, 759, 812), rows addressed by 14 bits; draw destinations
  are bounded at 16 MB (`VRAM_SIZE_HALF`, G:667). The populated size on the PCB is not in MAME
  (Feasibility 4). The CPU does not address VRAM: it reaches it through two write ports
  (address 0x60/0x64, mode 0x68, FIFO 0x70/0x74; G:366-425) and a read window (address 0x5C,
  data at 0x80-0xFC; G:171-174, 362-364).
- **Commands**: a write port in mode bit 8 collects four dwords and executes them (G:377-398,
  404-425): 0 nop, 1 call a display list in VRAM (nested, 0x1000 entries at most, G:848-901),
  2 end, 3 frame-buffer origin (G:832-846), 4 fill rectangle with a 4-pixel pattern (G:713-769),
  5 draw object: a VRAM-to-VRAM copy with x/y flip, 6.6 fixed-point scale (64/scale), three blend
  modes and bit-15 transparency (G:552-711), 6 and 7 draw an 8x8 2-bpp character, optionally
  double height (G:771-830). Coordinates absolute or relative to the origin.
- **Display**: four display contexts (base 0x40-0x4C, size 0x30-0x3C, origin 0x20-0x2C, alpha
  0x14-0x18; G:249-349), composed in the order register 0x10's low half selects (G:242-247,
  532-550), each with its own alpha and blend mode, transparency on bit 15 (inverse for kbm by
  register 0x6C, G:539-543). No palette: pixels are RGB555.
- **Interrupt**: vblank, enabled by register 0x10 bit 16, cleared by writing it 0 (G:228-240,
  525-531). Status register 0x78 always reads 0xFFFF0005 (G:176-179).
- **External FIFO** ("media bus", registers 0x1C, 0x54, 0x58, `fifo_w`; G:263-269, 351-360,
  440-468): not mapped by firebeat.

Not in MAME's model: blitter timing (every command completes in the write), a busy status, and
any relation between drawing and scan-out (MAME draws the whole frame from VRAM at screen
update, G:532-550). MAME saves VRAM in its state (G:43), so a MAME savestate is the way to a
reference VRAM image; `-debug` memory dumps cannot reach it.

## GCU reference capture (Phase 3)

The bench's reference is a window of GCU activity, not a savestate: `scripts/mame_vram_window.py`
(`scripts/mame/vramwin.lua`) dumps the GCU's VRAM (save item 250), a shadow of the register file
0x00-0xFF and the save items that mirror it, logs every write to `7E800000-7E8000FF` for eight
frames, then dumps VRAM again, then MAME's screens for both ends. Two windows are kept:
`debug/ppp11-vram3000` (attract, the BEMANI logo) and `debug/ppp11-vram21400` (play, stage 2,
after `meas1`'s two coins and Start).

Frame correspondence: MAME draws a frame's screen at the start of that frame, from the state the
previous frame left (Video), so the screen belonging to the VRAM dumped at the end of frame N is
frame N+1's; the capture runs one frame past the window for that reason. Checked both ways, in
both windows: composing `vram_in` with the register file through k057714's `draw()` reproduces
`screen_in.bin` bit-exactly (0 of 196,608 pixels differ), and the same for `vram_out` and
`screen_out.bin`. Replaying the write log over `vram_in.bin` reaches `vram_out.bin` exactly once
the commands are executed as well (a log-only replay misses every pixel the blits write).

VRAM layout: a 32-bit word k holds pixels 2k and 2k+1 with the even pixel in the high half, so a
word is `{pixel 2k, pixel 2k+1}` and the core's DDR3 word can be the game's port data unchanged.
MAME reads `vram16[addr ^ 1]` on a little-endian host in both the display and the blitter
(G:521, 741, 756, 787) because of that layout; the captured `.bin` files are big-endian 16-bit
pixels indexed by pixel address, which is the same thing without the `^ 1`. A 1024-pixel pitch,
14-bit rows, destinations bounded at 16 MB.

Captured workload, per frame (the counters of G:547-566): attract 3 immediate commands, 2
display-list calls, 5 entries, 1 object of 12,032 pixels; play 3, 2, 67 and 61 objects (474,965
source pixels, 367,076 written, 40,503 blended), one full-screen fill (393,216 pixels), 264 FIFO
words, 12 command words, and no characters yet (ppp does not use them; bm3 and kbm do).

ppp's display state, the same in both windows, is the mode table's mode 1: registers 0x00
`01FF0447` (512 visible, 5 front porch, 72 back porch), 0x04 `017F0515` (384, 6, 22), 0x08
`5F030064` (96 hsync, 4 vsync): 685 x 416 total, 16.6666 MHz pixel clock, 24.3 kHz, 58.4875 Hz
(measured: MAME reports 58.487507). Two 512x384 contexts are shown, bases 0x68400 and 0x68600
(the game keeps a second pair at 0x8400 and 0x8600 and alternates them per frame), layer select
`0041870F` (slots draw contexts 3, 1, 0, 2), alphas `0841` for the two contexts shown and `0843`
for the two empty ones (blend 1 and 3, every alpha 16), and register 0x6C `0020`, which leaves
inverse transparency off: bit 15 set is drawn.

## GCU command engine (Phase 3)

`rtl/board/fb_gcu.sv` behind `fb_gcu_shell`, on `hornet_ddr3`'s master 0 as a wide (64-bit,
per-beat byte enable) master. `sim/gcu_tb` replays a captured window's register writes as fast as
the GCU takes them over `sim/common/ddr3_model.h` (first read beat `lat` clocks after the command,
`DDRAM_BUSY` `busy`% of clocks) and compares all of VRAM with MAME's `vram_out`.

| Window | Settings | Clocks, % of 8 frames | VRAM pixels differing |
|---|---|---|---|
| attract (`ppp11-vram3000`) | lat 20, busy 10% | 1.0 | 0 of 16,777,216 |
| play (`ppp11-vram21400`) | lat 20, busy 10% | 47.8 | 0 |
| play | + the display (`fb_gcu_disp`, served first) | 48.7 | 0 |
| play | + the display, lat 40, busy 20% | 56.1 | 0 |

The clock count is the engine's time alone: the CPU's time between writes is not in the log, so
the eight frames' commands are issued back to back. The object loop draws 4 pixels a clock;
before it drew one, the same play rows were 81.1%, 84.2% and 92.3%.

Random windows (`scripts/gcu_random.py --seed 1..8`, expected VRAM from `scripts/gcu_model.py`):
0 differences each. A quarter of their objects read from on or near their own destination; with
the source-row reuse check disabled, seeds 5 and 6 fail, so the check is covered.

Reset in mid-command (`+rst=N`, 23 points from clock 7,001 to 4,187,815 of the play window, step
190,037): the engine goes idle 9-153 clocks after the reset, with every burst `hornet_ddr3` took
completed, and the replay from `vram_in` ends at 0 pixels differing each time.

`sim/board_tb` on the play window with the engine in: the 302,908 device accesses still match
MAME's. With the DMA beside the CPU (`+hold=0 +lat=13`) the stage-2 frames are 1,068,772 and
1,044,196 clocks, as before the engine.

## GCU display (Phase 3)

`rtl/video/fb_gcu_disp.sv`: the CRTC from registers 0x00-0x08 and the four contexts composed a line
ahead into a two-line buffer from DDR3 (hornet_ddr3's last master, served first). A line's build
clears the buffer and reads each visible slot's row in 128-beat bursts; scan-out scales the pixel by
its context's factor as it leaves.

| Check | Result |
|---|---|
| `sim/disp_tb` on both captured windows, both ends (registers set directly) | 0 of 196,608 pixels differ from MAME's screen, each; also at lat 60, busy 30% |
| `sim/disp_tb` on 24 random register sets (`scripts/disp_random.py`: modes 0-2, repeated slots, edges, unaligned bases, blend modes, 0x6C) over a random VRAM | 0 differ each; 21 of the 24 expected screens are not black |
| mutations, 24 seeds each: mode 2 as mode 0; the beat offset ignored; one row fewer; 0xFFF as inverse | 7, 13, 11 and 4 seeds fail |
| `sim/gcu_tb +scan=1`: the engine replays the window while the display runs on the shell's registers | play and attract: VRAM 0 differ and the frame shown 0 of 196,608 from `screen_out`, no late line |
| `sim/sys_tb` steps 4-5, the test picture through the display | 0 wrong, frame 1,139,840 clocks, no late line |
| `Firebeat_30000006.rbf` (`798a5df`, seed 5) on the board, `hw.py launch` ppp11 | 640 x 480 black at 1 s and 16 s; at 48 s mode 1 (512 x 384) and the startup check drawn with **E121: VRAM ERROR** in red, much of the text missing or replaced by vertical bars (`docs/screenshots/phase3_e121_vram_error.png`, identity `Firebeat|Firebeat|ppp11|`). MAME on a blank board stops at E160 and E124, not E121 |
| `Firebeat_30000007.rbf` (`20d7e03`, seed 5) on the board, `hw.py launch` ppp11, identity `Firebeat|Firebeat|ppp11|` | at 50 s and 90 s the startup check with MAIN ROM to UART OK and RTC PASS, the ATAPI lines blank and the counter running (1806, 4144), as `sys_tb` without discs shows (`docs/screenshots/phase3_bursts_atapi_wait.png`); no E121 |
| the same, both CHDs mounted from the OSD, then its "Reset and close OSD" | **E140: ATAPI INIT ERROR** again: `fb_cd_slot` read a disc's TOC only at the mount and the board reset cleared it, so the drives were empty |
| the same, the core reloaded and the CHDs mounted before the BIOS's ATAPI check | ATAPI passes; **E160 BACKUPRAM ERROR** and **E124 FLASH DATA ERROR**: the device's NVRAM file was Phase 1's random one, and its `.mra` declared 6,295,552 bytes, 56 short of the RTC's 4,152 |
| the same, after the user ran the sound-NVRAM init and the settings reset | the game's title screen (`docs/screenshots/phase3_ppp11_title.png`) |

## DMA beside the CPU: E121 on the board

The board's E121 (above) is the BIOS's GCU RAM test, reproduced by `sim/sys_tb` step 6 (the real
BIOS on `firebeat_sys`, `+frames=2250 +shot=`): the same ERROR line, E121 and broken glyphs
(`docs/screenshots/sys_tb_e121_repro.png`). `sim/boot_tb` passes the test because it holds the CPU during DMA
(`dma_hold`), which the hardware core does not.

Every transfer is DMA channel 3 (DCR 0xD8-0xDB) to a GCU port. With the DMA beside the CPU the
GCU's status showed the fed port busy, so the BIOS took the other port and rewrote channel 3's
DA, SA and CT while it still ran (`sys_tb +io`, `D` lines with the busy flag set); `fb_ppc_dma`
read them live, so the running transfer ended at its 72nd of 128 words, its remaining words went
to the other port, and the new DMACR start was dropped. The bench's VRAM reads all equal what its
own logged port writes put there (286 of 286): the words were never sent, not lost on the way.

Fix (`fb_board`, `dma_wait`): the CPU waits for the transfer's end at a DMA register access.
`board_tb` on the play window (`+lat=13 +hold=0 +nocheck`, sim-only counters in `fb_ppc_dma`):

| RTL | words to the GCU | starts dropped | writes to the running channel | clocks, 2,000,000 instructions |
|---|---|---|---|---|
| before (`80c65cd`) | 147,763 | 1,729 | 6,916 | 5,158,101 |
| `dma_wait` | 295,756 | 0 | 0 | 9,443,215 |
| CPU held for every transfer (`+hold=1`) | 295,756 | 0 | 0 | 9,443,215 |

MAME's capture of the window has 297,836 port writes, nearly all in mode `00FF` (VRAM words).
So "The board on the play window" measured a run that dropped half the game's GCU data. With every
transfer done, the DMA waited mostly for the GCU's queue: `fb_gcu` wrote each queued VRAM word as its
own one-beat DDR3 write.

These runs, and those in "The board on the play window", had a bench fault: `board_tb`'s register pokes clocked the board without the DDR3
model, so `hornet_ddr3` took a read beat twice (LESSONS_LEARNED, "Every path that clocks the DUT").
With the bench fixed, `+idle` as in "The board on the play window":

| `fb_gcu` VRAM words | clocks, 2,000,000 instructions | DMA waiting for the GCU | work a frame | of 1,128,205 |
|---|---|---|---|---|
| one DDR3 write each (`9da5663`) | 7,703,312 | 2,160,595 | 1,614,983 | 143.1% |
| gathered into bursts of up to 128 beats | 6,286,715 | 743,998 | 1,142,784 | 101.3% |

The burst runs: `+hold=1` compares 302,908 of 304,999 device accesses, as before; `sim/gcu_tb` on
both windows (`+lat=40 +busy=20 +gap=30 +scan=1`) and the 8 random windows: VRAM 0 pixels differ,
screen 0. `sys_tb` step 6 to frame 2250: the frame equals `sys_tb_boot_dma_wait.png` pixel for pixel;
the 8,192 VRAM reads equal MAME's and the first port-0 difference is again entry 106,512.

`sys_tb` step 6 with the fix (`+lat=40 +busy=20 +frames=2250`): MAME's boot screen, every test up to
UART OK (`docs/screenshots/sys_tb_boot_dma_wait.png`; no discs in this bench, so the ATAPI lines stay
blank); `scripts/compare_io.py` against `debug/ppp11-boot/io.txt`: the BIOS's 8,192 VRAM reads equal
MAME's, port 1 unused as in MAME, the first port-0 difference at entry 106,512 (MAME frame 1071), the
on-screen counter, where `boot_tb` differs too.

## Memory map

PPC403GCX, 31-bit physical address, big-endian (F:774-797; DRC fast RAM covers all 32 MB, F:704):

| Address | Contents |
|---|---|
| `00000000-01FFFFFF` | work RAM, 32 MB |
| `70000000-70000FFF` | MIDI UART, top byte lane (bm3 F:1460, kbm F:1872) |
| `70001000-70001FFF` | FDC37C665GT, top byte lane (bm3, F:1461) |
| `70006000` / `7000A000` | extend-board IRQ enable (write) / active (read) (F:777-778, 1000-1017) |
| `70008000-7000800F` | kbm keyboard wheels (F:1873); bm3 spectrum analyser at `70008000-7000807F` (F:1462) |
| `74000000-740003FF` | SPU dual-port RAM, right side (F:1204; absent on ppp and kbm, F:779) |
| `7D000200-7D00021F` | cabinet info, bits 28-31 (F:780, 808-822) |
| `7D000320-7D000327` | lamps 2 and 3 (F:781-782) |
| `7D000330-7D00035F` | bm3 and ppp sensors, 16-bit (F:1463-1464, 1658) |
| `7D000400-7D000401` | YMZ280B (F:783) |
| `7D000500-7D000501` | control: pixel clock select, mirroring (F:784, 1032-1055) |
| `7D000800-7D000803` | inputs IN0-IN3 as bytes (F:785, 1021-1030) |
| `7D000804-7D000807` | lamps and status LEDs, per family (F:786, 1563, 1659, 1874) |
| `7D400000-7D5FFFFF` | flash_main, 2 MB (F:787) |
| `7D800000-7DBFFFFF` | flash_snd1, flash_snd2, 2 MB each (F:788-789) |
| `7DC00000-7DC0000F` | duart_com (F:790) |
| `7E000000-7E00003F`, `7E000100-7E00013F` | RTC65271 registers, NVRAM (F:791-792) |
| `7E800000-7E8000FF` | GCU (F:793) |
| `7E800100-7E8001FF` | second GCU (kbm F:1875; other games write it during boot, F:794) |
| `7FE00000-7FE0000F`, `7FE80000-7FE8000F` | ATA CS0, CS1, byte-swapped 16-bit (F:795-796) |
| `7FF80000-7FFFFFFF` | BIOS, 512 KB; reset vector at the top (F:797) |

PPC interrupts: IRQ0 GCU vblank (F:1153-1156), IRQ1 extend board (MIDI, FDD; F:1400-1407,
1490-1499, 1900-1919), IRQ2 main UART (unused), IRQ3 SPU mailbox (F:1191), IRQ4 ATA (F:1148-1151);
the comment at F:136-141.

SPU 68000 (F:1207-1222): ROM `000000-07FFFF`, RAM `100000-13FFFF` (256 KB), DIP switches `200000`,
status LEDs `220000`, IRQ ack `230000`, ATA DMA address `240000`/`250000`, wave bank `260000`
(8 MB per bank, F:1331), dual-port RAM `280000-2807FF` on the low byte, ATA CS0/CS1 `300000`/`340000`,
RF5C400 `400000-400FFF`, wave RAM window `800000-FFFFFF`. 68k interrupts: IRQ2 at 500 Hz runs one
queued command (volume and frequency animation, channel stop), IRQ4 mailbox, IRQ6 ATA (F:1234-1280,
1377-1391). RF5C400 sample space: the 32 MB wave RAM (F:1224-1227). YMZ280B sample space: the two
sound flash chips, 4 MB (F:800-805).

### Memory and storage sums

| What | Size | Source |
|---|---|---|
| work RAM | 32 MB | F:776 |
| GCU VRAM | up to 32 MB per GCU in MAME's model, destinations within 16 MB; two GCUs on kbm | G:41, 667 |
| RF5C400 wave RAM | 32 MB (popn, bm3) | F:1226 |
| flash | 3 x 2 MB, writable, filled by the install | F:740-742 |
| BIOS, SPU program, dongle, RTC | 512 KB, 512 KB, 200 B, 4 KB | `-listxml` |
| SPU RAM, dual-port RAM | 256 KB, 1 KB | F:1210, 1189 |
| CD / DVD / HDD images | unknown locally (no CHDs); DVD images up to 4.7 GB by format | |

Sum without the media: 71 MB (ppp), 103 MB (popn, bm3), 103 MB (kbm, two GCUs at 32 MB). The
32 MB module is out; a 128 MB module or DDR3 during play is the memory plan's first decision.

### Flash

The install writes the game's program and samples from the CD into the three 29F016A chips; MAME
keeps them in its NVRAM directory. A core either saves 6 MB across power cycles or reinstalls at
every boot. The install's length per set is a measurement (frames until the last flash write).

## Inputs

IN3 is an 8-way DIP switch on every family, all `DIPUNKNOWN` (F:2017-2034; auto-play and debug
bits noted there). Per family:

| Family | Controls (source) |
|---|---|
| ppp | Left, Right, Start/OK, Test, Service, Coin (F:2048-2057); eight sensor bars of three sensors, as buttons 3-10 over SENSOR1-4 (F:2062-2082); bars 6-8 only on the Korean ppd |
| kbm | Start P1/P2, Test, Service, Coin (F:2088-2094); two 24-key MIDI keyboards (`midikbd.cpp`, from the host keyboard) and two modulation wheels as paddles (F:2101-2105); e-Amusement bits on IN2 |
| popn | nine buttons (IN0 bits 0-7, IN2 bit 0), Coin, Test, Service (`popn` ports); SPU DIP switches (F:2037-2046) |
| bm3 | Test, Service, A, B, P1/P2 foot pedals (IN0); five keys and Start per player (IO1, IO3); coin sensor (IO2); two 10-bit turntables as trackball X; seven 5-bit effect dials (`bm3` ports) |

Outputs (status LEDs, button LEDs, pillar lamps, stage LEDs) are decoded per family
(F:1120-1146, 1566-1612, 1663-1736, 1960-1975); MiSTer has nowhere to show them.

## Home controllers

**Pop'n Music (PlayStation).** A controller-port pad: it answers the standard poll (`01 42 00 00
00`) with a digital pad's reply and holds Left, Down and Right pressed, which games take as the
Pop'n controller (PSX_MiSTer `rtl/joypad_pad.vhd` around line 699, its "Pop'n" pad type, forces
those three bits; commit `cd17b5a`). `rtl/mister/psx_pad_snac.sv` polls it on the user port in the
Firebeat_popn revision. Its buttons in the reply, bytes counted from 1 (byte 4: Select L3 R3 Start
Up Right Down Left, byte 5: L2 R2 L1 R1 Triangle Circle Cross Square, bits 0-7, active low;
`joypad_pad.vhd` lines 690-697, 746-753):

| Button | 1 | 2 | 3 | 4 | 5 | 6 | 7 | 8 | 9 |
|---|---|---|---|---|---|---|---|---|---|
| Pad button | Triangle | Circle | R1 | Cross | L1 | Square | R2 | Up | L2 |
| Byte, bit | 5, 4 | 5, 5 | 5, 3 | 5, 6 | 5, 2 | 5, 7 | 5, 1 | 4, 4 | 5, 0 |

Source: the README of `Curfewshino/PicoPS2PopN` (a PS2 Pop'n controller to USB converter), read
only as a search excerpt. `popn.ecxol.net` (a home-made controller) agrees on 4 (left blue, Cross)
and 6 (right blue, Square). Unverified: the other seven, Start and Select, and whether the PS1 and
PS2 controllers report alike. The check on the board is the game's test-mode input screen, one
button at a time, with OSD "Pop'n controller" on SNAC.

**ParaParaParadise (PS2).** A USB HID device, VID 0507 PID 0011, not a controller-port pad, so SNAC
cannot reach it. It reports nothing until it is sent output report `00 03`
(`Tatsh/pppps2pc` `kernel/hid-konami-ppp.c` and `pppps2pc/constants.py`, commit `6d912b5`; the game
disc's `DRIVER/USBKB.IRX`, decompiled there, probes 1287/17 and reads it with
`sceUsbdInterruptTransfer`). The Firebeat Main (`ppriest/Main_MiSTer` branch `firebeat-chd`,
`be2d2c3`) sends it on attach; the sensors then map to Sensor 1-5 like any pad. Unverified on the
board with the controller.

## Existing RTL, searched

| Chip | Looked at | Result |
|---|---|---|
| PPC403 | sibling cores | Hornet `rtl/cpu/ppc403/ppc403_core.sv`, M2 copy; verified against MAME, fitted |
| 68000 | sibling cores | fx68k (Seta, KonamiGX); Musashi on the HPS (Hornet) |
| YMZ280B | GitHub code search, jtcores, siblings | `MiSTer-devel/Arcade-Cave_MiSTer` `rtl/cave/YMZ280B.sv` (GPL-3.0); M2's notes recorded none, before this search |
| RF5C400 | GitHub code search (Verilog, VHDL), siblings | none in RTL; MAME's model on the HPS in Hornet |
| K057714 | GitHub code search | none |
| CD-ROM, ATA/ATAPI | Main_MiSTer, console cores, siblings | the console cores' CD path (Feasibility 2); `ide.cpp`/`ide_cdrom.cpp` for x86-class cores; M2 planned hps_io's SD block interface, unverified |
| RTC65271, 29F016A, PC16552D, FDC37C665GT, CY7C131 | | none; small, from the device files |

## CD path

User decision at research: read the discs as the console cores do, from MAME's CHDs as they are.
How those cores do it (Main_MiSTer at `E:/Main_MiSTer`):

- The core declares an image slot in its config string (`Saturn.sv:138`: `S0,CUECHD,Insert
  Disc;`; PSX uses slot 1) and `hps_io` gives it `img_mounted`, `img_size` and the SD block
  interface, `sd_lba`/`sd_rd`/`sd_buff_*`, 16 KB per request at most (`hps_io.sv:128-143`).
- The drive is RTL in the core (Saturn: `rtl/Saturn/CD`, `hps2cdd.sv`). The HPS answers a sector
  request by LBA: a plain image is read at `lba * block size` for any core
  (`user_io.cpp:3574-3583`); a CHD is decoded through libchdr (`support/chd/mister_chd.cpp`) only
  in code keyed on the core's name: `psx_read_cd` for PSX with 2352-byte blocks, `cdi_read_cd` for
  CD-i (`user_io.cpp:3540-3571`), and Saturn's whole drive model on the HPS
  (`support/saturn/saturncdd.cpp`, CUE and CHD) exchanging six-word command and status packets
  over `UIO_CD_GET`/`UIO_CD_SET` (`saturn.cpp:53-71`). The gates are `is_psx()`, `is_saturn()`
  and the like on the core name (`user_io.cpp:286-429`).
- Mounting: the OSD's slot entry, or at boot `boot.vhd` or `<core>.vhd` beside the `.rbf`
  (`user_io.cpp:1710-1738`).

For this core, launched from an `.mra`: the slot, the mounting and raw-image sector reads are
generic and available now; CHD decoding is not. It needs Main_MiSTer code for this core (a
`support/` module keyed on the core name as PSX and Saturn have, or a generic CHD decode for `S`
slots), an upstream change. The drive model is RTL written from `atapihle.cpp` and
`atapicdr.cpp`: ATA registers, PACKET commands (IDENTIFY, READ TOC, READ 10/12, PLAY for the
CD-DA audio discs of ppp and kbm, F:390-394), with sectors streamed through the slot. The DVD
(popn, 2048-byte sectors) and the HDD (bm3, 512-byte sectors, a hard-disk CHD) take the same
slot mechanism; libchdr reads both kinds.

## Measured in MAME: ppp11

Reference MAME `firebeat.exe` (`E:/MAME-Checkouts/mame-firebeat`, ROADMAP "Progress"); CHDs from
`F:/Emulation/roms/MAME CHDs/ppp11`; headless, `scripts/mame/gcu_stats.lua` writing the GCU
counters per frame and pressing inputs at given frames. Per-frame figures are MAME's model: the
GCU does every command in the register write, so they are work per frame, not timing.

**Boot and install.** A blank board stops at the startup check with E160 BACKUPRAM ERROR and
E124 FLASH DATA ERROR after the BIOS loads the game from the program CD (screen settles at about
frame 2640). The operator fixes both from Test mode: SOUND FLASH INIT (menu entry 7, then its own
entry and OK) writes 2,072,519 + 1,713,296 non-0xFF bytes into `flash_snd1` and `flash_snd2` in
about 2,100 frames, leaving `flash_main` blank; ALL FACTORY SETTINGS (entry 13, then YES)
clears the backup error, stored in the RTC NVRAM. From the resulting NVRAM the game boots to the
warning screen and attract. Press sequence (frames, from power-on): Test 3000; Right x6 at 60-frame
spacing from 3400, Start 3850, Right 4000, Start 4100 (flash); Right x12 from 3400, Start 4160,
Right 4300, Start 4400, Right 4550, Start 4650 (factory settings). Installed NVRAM kept in
`debug/nvram/ppp11-installed/` (not committed). A core either keeps these 4 MB + 4 KB across
power cycles or makes the operator repeat this at every boot.

**Video mode.** 512 x 384, mode 1 of the GCU table (685 x 416 total). 14,063 frames in 240
emulated seconds = 58.60 Hz, which is the 16.6666 MHz pixel clock (58.49 Hz), not 25.175 MHz
(88.3 Hz): ppp runs in the 24 kHz mode (`control_w` bit 0). 4 x 16.6666 = 66.67 MHz.

**GCU workload, attract** (frames 2401-14063 of the run from installed NVRAM, 11,663 frames):

| Per frame | min | median | p95 | max |
|---|---|---|---|---|
| draw-object commands | 0 | 47 | 143 | 336 |
| object source pixels read | 0 | 233,467 | 490,915 | 549,153 |
| object destination pixels written | 0 | 233,467 | 460,337 | 517,317 |
| of which blended (destination read too) | 0 | 5,682 | 214,237 | 263,109 |
| fill pixels | 0 | 51,840 | 393,216 | 786,432 |
| character pixels | 0 | 0 | 0 | 0 |
| display-list entries (depth 1 at most) | 0 | 53 | 165 | 340 |
| write-port words to VRAM | 0 | 212 | 716 | 164,864 |
| display pixels scanned | 393,216 | 393,216 | 393,216 | 393,216 |
| highest VRAM pixel address read | | 7,826,852 | 15,623,714 | 15,669,493 |
| highest VRAM pixel address written | | 820,223 | 843,919 | 15,670,271 |

- **VRAM extent: the whole 32 MB.** Reads reach pixel 15,669,493 (byte 31.3 MB): graphics
  uploaded high in VRAM, frame buffers low. Feasibility 4 closed for ppp: VRAM is 32 MB.
- Two display contexts of 512 x 384 are composed every frame (393,216 = 2 x 196,608).
- No object pixel is clipped by the 16 MB destination bound; no character draws; the VRAM read
  window is not used in attract.
- Traffic at p95, in 16-bit VRAM accesses per frame: 490,915 source reads + 460,337 writes +
  214,237 blend reads + 393,216 fill writes + 393,216 scan-out reads = 1.95 M, 3.9 MB, 229 MB/s at
  58.6 Hz; median 0.92 M, 108 MB/s. Against one 16-bit SDRAM: 96 MB/s peak at 48 MHz, 133 MB/s at
  66.67 MHz, before the PPC's work-RAM traffic. Play is not measured yet.

### Play (run `meas1`)

From the installed NVRAM, 480 emulated seconds: attract to frame 8999, two coins at 9000/9060
(the factory setting is 2 coins a credit), Start at 9200; mode and music select time out on their
own. `scripts/mame/ppp_load.lua` records, `scripts/ppp_load_report.py` summarises. Phases from
snapshots every 300 frames:

| Phase | Frames | Screen |
|---|---|---|
| attract | 2700-8999 | demo loop |
| select | 9300-13100 | warning, play mode, music select |
| stage1 | 14300-19100 | "TRY ME", dancing; stage clear at 20100 |
| stage2 | 21300-27100 | practice stage; failed at 27300 (no sensor input) |

**PPC.** The game runs on an RTOS. Its idle task (`80051F5C`) loops for ever: it checks a work
queue (`800513E8`; a handler from the table at `80369770` when there is work), scans 16 entries
(`80051E80`), and otherwise yields through a system call (`8004671C`, `sc` at `80044D4C`). The
yield enters the dispatcher (`80046CA8`, called on the way out of the `sc` exception at
`80000D60`), which scans the 8-entry task table at `8014D298` (`800460A0`, `80046288`) and runs a
ready task, or returns to the idle task.

A debugger trace of attract frames 5000-5002 (1.84 M instructions) splits as: kernel time in the
idle task's yields 85.8%, the idle task's polling 3.4%, kernel time in other tasks' system calls
0.4%, work 10.4%. Kernel time is therefore idle, and busy is measured by counting PC samples in
the kernel (`80044C00-80046DFF`, `80000B00-80000EFF`) and the idle task's polling
(`80051350-80051450`, `80051E80-80051FFF`) as idle. The sampled figure for frames 5001-5002 is
10.2%, the trace's 10.8%.

Sampled at 20 kHz (`CURPC` under MAME's DRC, at scheduler boundaries). MAME charges about one
cycle an instruction and models no cache or bus wait, so these are lower bounds for a core:

| Busy % of 66 MHz | min | median | p95 | p99 | max |
|---|---|---|---|---|---|
| attract | 3.2 | 14.6 | 22.2 | 26.3 | 32.5 |
| select | 2.3 | 5.3 | 6.7 | 86.2 | 90.1 |
| stage1 | 5.3 | 10.2 | 13.2 | 84.5 | 91.5 |
| stage2 | 5.8 | 12.6 | 43.0 | 86.8 | 90.1 |

The frames above 80% are loading, not the game loop. 2,770 frames of the run are above 80%,
208 of them within 3 frames of a CD read: they come in runs of 7-21 frames after reads. In them
83% of the time is `8005B5F4`, an LZSS decompressor (4,096-byte window starting at `FEE`, the
Okumura layout) that yields to the scheduler every 4 KB of output. Without it:

| Busy % of 66 MHz, LZSS excluded | median | p95 | p99 | max |
|---|---|---|---|---|
| attract | 14.6 | 22.2 | 26.3 | 32.5 |
| select | 5.3 | 6.4 | 7.3 | 88.0 |
| stage1 | 10.2 | 12.9 | 14.3 | 86.0 |
| stage2 | 12.6 | 14.9 | 42.1 | 86.3 |

The remaining 86-88% frames are other loading work beside reads; the game loop itself peaks at
about 44% (stage2 frames 21357-21358, no read or decompression within 6 frames). Decompression
and loading stretch on a slower CPU rather than missing a frame; whether a song can start late
without effect is open. At the Hornet core's 1.75-1.94 clocks an instruction, the game-loop peak
of 44% is 77-85% of 66 MHz before SDRAM latency; item 3 measures the core on this code.

**GCU per frame, play** (stage2; stage1 lower):

| | min | median | p95 | max |
|---|---|---|---|---|
| object source pixels | 260,516 | 475,673 | 497,291 | 504,881 |
| object destination pixels | 231,601 | 367,271 | 388,451 | 395,284 |
| blended | 1,027 | 41,007 | 67,933 | 94,765 |
| fill pixels | 393,216 | 393,216 | 393,216 | 393,216 |
| 16-bit VRAM accesses, all | 1,279,832 | 1,670,885 | 1,713,679 | 2,017,184 |

Every frame of play clears both 512x384 buffers (393,216 fill pixels) and scans two contexts. The
median play frame is 1.67 M accesses, 3.3 MB, 196 MB/s at 58.6 Hz; the maximum frame 236 MB/s.
In stage2 reads reach VRAM pixel 16,215,295 and writes 16,221,183: the whole 32 MB.

**Work RAM.** Non-zero 64 KB blocks at frames 8900 / 14000 / 20000 / 27000: 167 / 176 / 177 /
223 of 512 (10.4 to 13.9 MB), in two ranges, `0000000-037FFFF` and from `14A0000` to the top,
`1FFFFFF` (stack and heaps at the top). Non-zero is a lower bound on what is used, but the top
of the 32 MB is in use, so the core maps the whole 32 MB.

**ATA.** Two drives, ATAPI, PIO with 16-bit data-register reads.

- Drive 0, program CD: READ(10) only, after TEST UNIT READY, READ TOC and SET CD SPEED (`BB`) at
  boot. 596 READs (44.2 MB) up to the end of the startup check, then 19 / 17 / 51 READs in
  select / stage1 / stage2, 3.4 / 3.1 / 10.1 MB, at most 128 blocks (256 KB) a command, LBAs to
  157,368 (307 MB into the disc). Stage2 averages 10.1 MB over 99 s, 102 KB/s; MAME delivers each
  command within a frame (up to 674 KB in one frame), so the drive's rate is not in the model.
- Drive 1, audio CD: no data reads. MODE SELECT(10) (`55`, volume), PLAY AUDIO(12) (`A5`, e.g.
  LBA 164,868 for 7,744 blocks, 103 s), STOP (`4E`) and READ SUB-CHANNEL (`42`, current position,
  78 in stage1) to follow the song. The music is CD audio from the second disc: the core plays
  2,352-byte sectors at 176.4 KB/s from the second image and mixes them.

**YMZ280B.** 4,814 register writes over the run, most at boot. 72 key-ons: 70 ADPCM, 2 16-bit
PCM, none 8-bit PCM. The 16-bit PCM path that only firebeat uses in MAME is used. Registers
written: all voice registers, `84-86` (the YMZ's external memory address, to read the flash
back), `FE`, `FF`.

**control_w.** Values `05` and `85` only (1,027 and 1,025 writes): bit 0 set, the 16.6666 MHz
pixel clock, throughout.

## PPC core on ppp11 (Phase 0 item 3)

**Fit, the core alone** (`rtl/synth_ppc`, `scripts/synth_ppc.py`; Quartus 17.0.2, 5CSEBA6U23I7,
inputs from an LFSR; `build/synth_ppc/summary.txt`):

| Constraint | Seeds | ALMs | Registers | DSP | Worst setup slack | Slow-corner Fmax |
|---|---|---|---|---|---|---|
| 66 MHz | 1, 2, 3 | 4,305-4,349 | 2,180-2,188 | 3 | +2.160 to +2.244 ns | 76.97-77.47 MHz |
| 50.35 MHz | 1, 2, 3 | 4,258-4,295 | 2,174-2,182 | 3 | +5.681 to +6.990 ns | 70.52-77.69 MHz |

**Agreement with MAME** (`sim/ppc_tb` replaying `scripts/mame_ppc_window.py` captures,
`scripts/compare_insn_trace.py`): stage2 window at frame 21357, 2,000,000 of 2,000,000
instructions agree in PC and 37 registers; stage1 window at frame 15018, 1,777,257 agree, the end
of MAME's device log (the capture stops MAME mid-line). The bench models what the core lacks:

- **The 403's DMA controller.** The game feeds the GCU's write-port FIFO (`7E800070`) by
  software memory-to-memory DMA on channel 3: DMACR3 `89C00100` (32-bit, source incrementing,
  destination fixed, terminal count, no interrupt, no chaining), 16 words a transfer, 2,332
  transfers and 295,756 words in the stage2 window. MAME runs each transfer to completion inside
  the `mtdcr` (ppccom.cpp:2497-2505). The core has no DMA controller: one is needed.
- Timebase reads, PIT and FIT interrupts and the vblank interrupt are taken from MAME's trace.

**Clocks per instruction.** "Work" is everything outside the idle ranges (HARDWARE_NOTES, "Play");
the stage2 window spans about 2.1 frames (930,144 work instructions at MAME's ~1 cycle each,
against 44% of 1.128 M cycles a frame).

| Window | Memory | Caches | CPI, all | CPI, work | Work clocks a frame |
|---|---|---|---|---|---|
| stage2 21357 | 1 clock | none | 1.86 | 1.92 | ~0.85 M |
| stage2 21357 | 10 clocks | none | 11.09 | 11.44 | ~5.1 M |
| stage2 21357 | 10 clocks | I 16 KB, D 8 KB | 2.25 | 2.14 | ~0.95 M |
| stage2 21357 | 20 clocks | I 16 KB, D 8 KB | 2.63 | 2.38 | ~1.05 M |
| stage1 15018 (LZSS) | 1 clock | none | 1.69 | 1.68 | |
| stage1 15018 (LZSS) | 10 clocks | I 16 KB, D 8 KB | 1.86 | 1.81 | |
| stage1 15018 (LZSS) | 20 clocks | I 16 KB, D 8 KB | 2.03 | 1.93 | |

The cache sizes are the 403GCX's; the model is two-way, 16-byte lines, a miss costing the
latency plus a clock a further word, writes write-through and posted (`sim/ppc_tb/main.cpp`).
Without caches the core is unusable at any SDRAM latency.

**What it means.** The heaviest game-loop frames found (stage2 21357-21358) need about 0.95-1.05 M
core clocks with GCX-sized caches at 10-20 clocks of memory latency. A frame is 1.128 M clocks at
66 MHz (84-93%) and 0.861 M at 50.35 MHz (110-122%). The DMA's 141,000 words a frame (read from
work RAM, written to the GCU) are not charged in these figures and share the memory with the CPU.
So: the PPC at 66 MHz or more, an instruction and a data cache of about the 403GCX's size, and the
DMA controller in RTL. 66.67 MHz is 4 x the 16.6666 MHz pixel clock ppp uses (Video mode, above).

## YMZ280B on ppp11 (Phase 0 item 4)

**What ppp11 uses** (run `meas1`, 4,814 register writes): 72 key-ons, 70 ADPCM and 2 16-bit PCM
(attract frames 4992 and 8312); none with the ninth pitch bit (register `01` bit 0); pan always 8
(centre); the loop flag on 8; 114 distinct levels; and a readback of the first 1,024 bytes of the
sound flash through registers `84-86` at frame 2448, during the startup check.

**The Cave core's module** (`MiSTer-devel/Arcade-Cave_MiSTer` at `ee191ea`, `rtl/cave/YMZ280B.sv`,
`ChannelController.sv`, `AudioPipeline.sv`, `CaveYMZ280BHelpers.sv`, 1,184 lines, GPL-3.0), read
against `ymz280b.cpp`:

| | MAME | Cave module |
|---|---|---|
| ADPCM | yes | yes |
| 8-bit and 16-bit PCM (register `01` bits 6:5) | yes | no: the pipeline decodes 4-bit nibbles only |
| ninth pitch bit (register `01` bit 0) | yes | no: pitch is register `00` |
| stereo pan | yes | mono out (`io_audio_bits_left`); pan attenuates |
| external-memory readback, registers `84-87` | yes (ymz280b.cpp:776-797) | no |
| savestate | MAME's | tied to Cave's `cave_ssbus_if` |

For ppp11 it lacks 16-bit PCM and the readback; the other families may use the rest. 16-bit PCM
is a change of the pipeline's shape, not a field. Recommendation: write the YMZ280B from
`ymz280b.cpp`, with the Cave decoder as a cross-check of the ADPCM path.

**Reference for its bench** (`debug/ymz_ref/`, not committed; `scripts/mame/ymz_capture.lua`): 155 s
from the installed NVRAM with `FIREBEAT_MUTE_CDDA=1` (a switch on the measurement branch that
routes the CD audio at gain 0), `-samplerate 44100 -wavwrite`: every chip access with its emulated
time (7,940 writes, 8,687 reads) and the chip's output alone. L and R are equal in every sample
(centre pan); sound at the key-ons, and the attract music at 81-143 s is the chip's own looped
ADPCM.

## Memory plan inputs (Phase 0 item 5)

**PPC traffic with the 403GCX's caches.** The game writes DCWR = 0 (`80002108`): the data cache is
write-back everywhere. With the bench's model (I 16 KB, D 8 KB, two-way, 16-byte lines,
write-back with write-allocate), the stage2 window (about 2.1 frames) reads and writes work RAM:

| | Bytes in the window | Per frame |
|---|---|---|
| line fills (I 52,811 + D 20,997 misses) | 1,180,928 | ~562 KB |
| dirty write-backs (17,969) | 287,504 | ~137 KB |
| DMA source reads (295,756 words) | 1,183,024 | ~563 KB |
| total | 2,651,456 | ~1.26 MB, 74 MB/s |

CPI of the work at 10 / 20 clocks of latency: 2.18 / 2.43 (write-back), against 2.14 / 2.38 with
the earlier write-through model that charged no write traffic.

**One 16-bit SDRAM at 66.67 MHz** moves at most 2 bytes a clock, 133 MB/s. As transactions: about
92,000 16-byte line transfers and 18,500 64-byte DMA bursts in the window. At 8 or 32 words each
plus about 6 clocks of activate, CAS and precharge (an estimate, no controller measured), that
is about 0.95 M clocks a frame of 1.128 M: about 84% occupancy in the peak game-loop frames,
before the YMZ280B's reads, refresh and the BIOS. At 2 x clk_sys (133.3 MHz) the same traffic
is about 42%.

**GCU VRAM**: 32 MB, 196 MB/s median and 236 MB/s worst frame in play ("Play" above), more than one
16-bit SDRAM delivers at any clock the board can reach. Its accesses are runs: blit source and
destination rows, fills, and scan-out of two contexts.

**Sizes**: work RAM 32 MB, VRAM 32 MB, sound flash 4 MB (+ 2 MB main flash, blank on ppp), BIOS
512 KB, RTC NVRAM 4 KB.

## Area (Phase 0 item 6)

| Block | ALMs | M10K | Source |
|---|---|---|---|
| framework (`sys/`, hps_io, video out) | ~6,400-7,100 | 56-61 | Seta 14,131 LUT, HyperNG64 12,790 LUT floorplans, two LUTs an ALM |
| PPC403GCX | 4,305-4,349 | 0 | fit (item 3) |
| caches, I 16 KB + D 8 KB | ~1,000 (estimate) | ~24 data + tags | 24 KB of data |
| 403 DMA controller, channel 3 mode | ~300 (estimate) | 0 | |
| GCU | ~3,000-7,000 (estimate) | ~20 (line FIFOs) | by comparison: Hornet's `vraster` 6,688 ALMs, 81 M10K |
| YMZ280B | ~1,500-3,000 (estimate) | ~4 | not fitted |
| ATAPI x 2, CD audio | ~1,000-2,000 (estimate) | ~26 (two 16 KB sector buffers) | |
| SDRAM and DDR3 controllers | ~1,500-2,500 (estimate) | ~10 | sibling cores |
| I/O, RTC, flash, UART, dongle | ~1,000 (estimate) | ~2 | |
| sum | ~20,000-28,000 of 41,910 (48-67%) | ~165-175 of 553 | |

Only the framework and the PPC are measured; the rest are estimates until written. The sum leaves
room on paper; the GCU is the block whose size is least known.

## CD path on the board (Phase 0 item 2)

**Test core**: revision `FirebeatCD` (`rtl/cdtest`, commit `02e9d63`, built by `build_staged.py`:
8,139 ALMs, 59 M10K, clk_sys 20 MHz, +37.9 ns setup slack), deployed as `Firebeat_30000001.rbf`
with `releases/_dev/Firebeat CD path test.mra`. Two hps_io image slots (`S0`, `S1`, 16-bit
`WIDE` mode, 512-byte blocks); a reader per slot issues 16 KB requests; counters on ISSP probes A
and B, controls on F (`scripts/cdtest.py`).

**Images**: `chdman extractcd` of the ppp11 CHDs (MAME 0.289's chdman): `gc977jaa01` one
MODE1/2352 track, 370,482,336 bytes; `gc977jaa02` audio tracks, 540,092,112 bytes; in
`/media/fat/games/firebeatcd/`, mounted by the user from the OSD.

**Launch**: `load_core` of the `.mra` through `/dev/MiSTer_cmd` ran the core (`/tmp/CORENAME`
`firebeatcd`, probes identify `FirebeatCD`). The Remote API launch of the same path (`hw.py
launch`) left the menu running; not investigated (the path has spaces).

**Mount**: the OSD offers both slots for the `.mra`-launched core; at mount the slots report
723,598 and 1,054,867 blocks, the sizes of the two `.bin` files. The first 4 KB of the program
image sum to `00153D43` as 16-bit words low byte first, equal to the file's: hps_io's 16-bit words
arrive low byte first.

**Throughput** (`scripts/cdtest.py`, 20 s a run, 16 KB requests):

| Slots reading | Mode | MB/s a slot | Requests/s a slot | First word, avg | First word, max |
|---|---|---|---|---|---|
| S0 alone | sequential | 4.66 | 284.6 | 0.20 ms | 5.98 ms |
| S0 alone | random | 3.24 | 197.6 | 1.73 ms | 14.19 ms |
| S1 alone | sequential | 4.72 | 288.0 | 0.16 ms | 2.39 ms |
| S1 alone | random | 2.27 | 138.3 | 3.91 ms | 12.42 ms |
| both | sequential | 2.25 | 137.2-137.3 | 3.97-3.98 ms | 14.37-16.80 ms |
| both | random | 1.25 | 76.5 | 9.76 ms | 25.68-25.91 ms |

**Against ppp11's needs** ("Play" above): the audio disc's CD audio is 176.4 KB/s; the program
disc averages 102 KB/s in play, with READs of up to 256 KB (114 ms at 2.25 MB/s, about 7 frames;
MAME delivers each within one frame) and 44 MB at boot (about 9-10 s at 4.66 MB/s). The CD audio
needs a buffer covering the worst first-word latency seen with both slots busy, 26 ms (4.6 KB):
two 16 KB request buffers. Measured with the test core at 20 MHz; the HPS side sets the rate.

**CHDs, through a Main_MiSTer change.** Branch `firebeat-chd` of Main_MiSTer (worktree
`E:/Main_MiSTer-firebeat`, commits `6e1b948`, `eee2495` on upstream `8328d9f`): `support/firebeat` serves a
CD CHD mounted in a slot of a core named `Firebeat*` as the raw image `chdman extractcd` writes
(every track's 2352-byte frames back to back, CD audio byte-swapped into .bin order; a
MODE1/2048 track, as ppp1mp's `a11jaa01`, gets each frame's sync and header rebuilt and zero
EDC/ECC, since `fb_cd_slot` reads only bytes 16-2063), through
the same mount and read hooks the Sun support uses (`user_io.cpp`). Built in WSL with ARM GCC
10.2 (`scripts/main_mister/build_main.sh`); on the MiSTer as `/media/fat/MiSTer_Firebeat`, chosen
for these cores only by a `[Firebeat*]` / `main=MiSTer_Firebeat` section in `MiSTer.ini` (the
previous file kept as `MiSTer.ini.before-firebeat`); loading FirebeatCD runs that binary.

- Host check (`scripts/main_mister/chd_raw_check.sh`: the same `firebeat.cpp` and libchdr in WSL,
  Main's I/O stubbed, every 16 KB request compared with the extracted .bin): program disc
  370,482,176 bytes, audio disc 540,091,904 bytes, 0 differ. The trailing partial 512-byte block
  of each .bin (160 and 208 bytes) is not reached by whole-block reads.
- On the board, CHDs mounted from the OSD (`Firebeat_30000002.rbf`, slots offering CHD): the
  slots report the .bin sizes, the program disc's first 4 KB sum to `00153D43` as from the .bin.
- That binary (md5 `34d614dd…`) predates the TOC block, so `fb_cd_slot` fell back to one data
  track. The audio drive's READ TOC gave tracks 1-1 and lead-out 0x40624, which is the .bin's size
  over 2048 (slave access log, `debug/dumps/30000010_e202b.bin.ata.txt`, entries 38-46). The game
  then refused every "play cd N/1 track" before touching the drive and raised **E202 ATAPI SLAVE
  ERROR** after Start (the "CDDA error" path, e.g. 0x80021754 on 0x80056710's -1).
  Rebuilt from the current `firebeat.cpp` (md5 `f873ae5d…`): the host check serves `FBTC` with 34
  tracks (track 2 at frame 6691, the .cue's 01:29:16). Installed with the MCP's
  `mister_install_main`; ppp11 then passed Start with no E202 (user, `Firebeat_30000010.rbf`).

| Slots reading | Mode | Raw image, MB/s a slot | CHD, MB/s a slot | CHD first word, avg | CHD first word, max |
|---|---|---|---|---|---|
| S0 alone | sequential | 4.66 | 2.73 | 2.69 ms | 10.13 ms |
| S0 alone | random | 3.24 | 1.52 | 7.44 ms | 27.48 ms |
| S1 alone | sequential | 4.72 | 3.24 | 1.74 ms | 4.66 ms |
| S1 alone | random | 2.27 | 1.83 | 5.64 ms | 16.56 ms |
| both | sequential | 2.25 | 1.42 | 8.23-8.24 ms | 17.33-18.25 ms |
| both | random | 1.25 | 0.82 | 16.65-16.66 ms | 37.38-43.47 ms |

The decompression on the ARM costs about 40% of the raw-image rate. Against ppp11's 176.4 KB/s of
CD audio and ~102 KB/s of program reads the slowest case leaves a margin of about 3x; the worst
first word, 43 ms, is 7.6 KB of CD audio, inside two 16 KB request buffers. A 256 KB READ takes
about 180 ms with both discs busy (about 11 frames).

## Memory system benches (Phase 1)

**SDRAM** (`sim/sdram_tb`, `rtl/mister/firebeat_sdram.sv` at 133.33 MHz on the 128 MB module's
command-decoding model): download, 20,000 random operations and the stage 2 replay, 0 errors.
The replay streams each DMA transfer beside the CPU as the game does.

| Stage 2 replay | Value |
|---|---|
| work clocks, % of a 66.667 MHz frame | 89.2 (87.6 before the second data register, 94.8 with 16-byte DMA reads) |
| line fill latency, clk_sys clocks | 12.7 average, 30 worst |
| CPU clocks waiting for a running DMA transfer | 0 |
| SDRAM busy | 33.3% |

**DDR3 VRAM** (`sim/vram_tb`, `rtl/mister/hornet_ddr3.sv` with four wide masters on Hornet's DDR3
model): the worst play frame's GCU work from "Play" (fills, object source, destination and
blend rows, uploads) issued one row at a time, each waiting for the last, beside scan-out of two
512-pixel contexts per line on a 2,740-clock line.

| DDR3 latency, BUSY | Blitter clocks, % of a frame | Scan-out lines late | Worst line, clocks of 2,740 |
|---|---|---|---|
| 15, 10% | 53.3 | 0 | 581 |
| 20, 10% | 55.7 | 0 | 586 |
| 40, 20% | 67.6 | 0 | 661 |

The blitter here does nothing between rows; the GCU's own per-pixel work overlaps the next
row's fetch or adds to these figures, which Phase 3 measures.

## Phase 1 on the board

Firebeat_stp as `Firebeat_30000004.rbf` (commit 06ffbb2, fitter seed 3), ppp11 from
`releases/_dev`, a random 6,295,552-byte NVRAM file in place; `scripts/phase1_check.py` over
probes F and M (readings prefixed `Firebeat|Firebeat|ppp11|`):

| Check | Measured | Expected |
|---|---|---|
| frame length | 854,880 CLK_50M clocks, 58.4877 Hz | 854,881, 58.4877 Hz |
| scan-out lines late | 0 | 0 |
| test picture, native screenshot | 0 of 196,608 pixels differ | `docs/screenshots/phase1_test_picture.png` |
| BIOS read-back, 32,768 lines | 0xBAE582F8 | 0xBAE582F8 (ppp11.zip, halfwords swapped) |
| dongle | 0xBBEC | 0xBBEC |
| flash read-back, 393,216 lines | 0xDE234547 | 0xDE234547 (the NVRAM file) |
| RTC NVRAM | 0x03FC6630 | 0x03FC6630 |
| cache-port fill latency, clk_sys | 13.20 average, 15 worst | 10-20 (the CPI figures) |
| NVRAM save (probe request, then the OSD) | file md5 d1e8b4e5... | the test file's |

Timing: the SDRAM controller's clock (133.33 MHz) met at +0.094 ns with seed 3; the same commit
missed by 0.039 ns with seed 1, on the state-to-DQ8/DQ11 output paths. The margin there is under
0.1 ns; Phase 2's added logic may move it.

## The board on the play window (Phase 2)

`sim/board_tb` on the stage2 window (frame 21357, 2,000,000 instructions): the board's clocks
between MAME's vblank interrupts, split by the RTOS's idle task (`+idle`, HARDWARE_NOTES "Play").
SDRAM answered +lat clocks after a request; the DMA writes the GCU directly at about 2.2 clocks a
word (`fb_ppc_dma` direct path). The runs:

    scripts/run_verilator.sh board_tb +win=debug/ppp11-win21357 +n=2000000 +lat=N +hold=0 +nocheck \
        "+idle=80044C00-80046DFF,80000B00-80000EFF,80051350-80051450,80051E80-80051FFF"

with `+hold=1` (MAME's order, and device accesses compared) for the first row.

| DMA | lat | Work clocks, frame 1 / frame 2 | of 1,128,205 |
|---|---|---|---|
| holding the CPU (MAME's order) | 12 | 1,366,379 / 1,341,260 | 121% / 119% |
| beside the CPU (the hardware core) | 12 | 1,059,381 / 1,035,878 | 94% / 92% |
| beside the CPU (the board's measured fill latency) | 13 | 1,068,773 / 1,044,197 | 94.7% / 92.6% |
| beside the CPU | 20 | 1,134,585 / 1,102,474 | 101% / 98% |

At the board's 13.2-clock average fill latency (`+lat=13`) the stage2 window's two frames take
94.7% and 92.6% of their frame time: they finish inside it, which is Phase 2's exit for this
window. The DMA in MAME's order does not fit; the hardware core's setting does.

At latency 1 the work is 79.5% of the window's clocks per vblank: most of the cost is the core's
own CPI (2.40 at one-clock memory). The board's SDRAM fill latency on hardware is 13.2 clocks
average ("Phase 1 on the board").

## Timing closure for the full design (Phase 2 to Phase 5)

`build_staged.py` compiles the whole board (framework, DDR3 video path, PPC with caches, GCU, ATAPI,
SDRAM controller) and gates on every clock in the STA summary. The design is 28,681-28,923 ALMs
(68-69% of 41,910), 35,887-36,140 registers, 127 M10Ks, 36/112 DSPs, three PLLs.

Two clocks decide it: `clk_sys` at 66.67 MHz (emu PLL output 0, 15.000 ns) and the SDRAM domain at
133.33 MHz (output 1, 7.500 ns).

**`clk_sys` was structural.** At commit `096c157` it missed at seeds 1, 3 and 5 (-0.074, -0.074,
-0.023 ns), always on the same path: the instruction cache's read address
(`fb_cache:u_ic|ra[4]`, `[5]`) through its line mux to `i_rdata`, then the CPU's fetch bypass
(`nh`), the GPR read and `o_v[2][25]`. The mux forwards the last write's data and tag into a lookup
of the same set in the same clock; the data cache needs that, the instruction cache cannot reach it
(`we` tied low, and a fill ends in C_DONE before the next request is taken, so the RAM has seen the
write an edge before the lookup's read address). `fb_cache` took an `FWD` parameter, 0 on `u_ic`
(commit `bc6f934`); same seed 5, `clk_sys` went from -0.023 to +0.268 ns.

**The SDRAM domain is a placement lottery.** Its failing paths are all
`sdram:u_sdram|state[*]`/`mode[0]`/`we` to `dq_out[6]/[8]/[11]`: the write-data load mux against a
DDIO output register. Seeds move it by more than a nanosecond in either direction on the same
commit. It is closed with the fitter seed, as the standing rule requires:

| Seed | `clk_sys` | SDRAM 133 MHz | Result |
|---|---|---|---|
| 2 | +0.036 | +0.607 | **met** -- the artifact |
| 5 | +0.268 | -0.634 | SDRAM fails |
| 6 | +0.330 | -0.625 | SDRAM fails |
| 7 | +0.469 | -0.374 | SDRAM fails |
| 8 | +0.378 | -0.224 | SDRAM fails |

Five seeds tried; one passes. The SDRAM domain's spread (from +0.607 to -0.634) is the whole
decision, and the seed is chosen for it, not for `clk_sys`: seed 2 has the least `clk_sys` margin
of the five and the only positive SDRAM one.

`build/BUILT_COMMIT` records the seed with the commit, so every `.rbf` names its placement.

**With the GCU engine and display (Phase 3).** 31,441-31,691 ALMs (75-76%), 40,204-40,616
registers, 143 M10Ks, 49 DSPs.

| Commit | Seed | `clk_sys` | SDRAM 133 MHz | Worst `clk_sys` path |
|---|---|---|---|---|
| `9380597` | 2 | -5.590 | +0.375 | `fb_gcu_disp` slot setup in one clock (fixed in `9bd66f9`) |
| `9bd66f9` | 2 | -0.631 | -0.141 | `fb_cache:u_dc\|r_addr[28]` to `ppc403_core\|o_v[0][*]` (the ack through the next head's register reads; fixed in `d8f1deb`) |
| `d8f1deb` | 2 | +0.207 | -0.308 | met; the HDMI PLL's domain (`sys/`) also fails, -0.258 |
| `798a5df` (RTL of `d8f1deb`) | 1 | -0.142 | -0.356 | |
| | 3 | +0.213 | -0.079 | |
| | 4 | +0.429 | -0.249 | |
| | 5 | +0.457 | +0.276 | **met on every clock** (HDMI +0.165); 32,029 ALMs (76%), 40,601 registers |
| `20d7e03` (VRAM bursts) | 5 | +0.096 | +0.137 | **met on every clock** (HDMI +0.241) -- the artifact; 32,091 ALMs (77%), 40,772 registers |
| `81ebc34` (disc slots survive a reset) | 2, 3, 4, 5 | +0.445, -0.234, +0.271, +0.022 | -0.607, -0.719, -1.109, -0.366 | every SDRAM failure `sdram` state/mode/active -> 3 LUTs -> ~4.9 ns route -> `dq_out`'s I/O cell (seed 4 also HDMI -0.221) |
| `16748b6` (`dq_out` through one mux) | 2-6 | -1.171 to +0.481 | -0.432 to -0.077 | now `state` -> 3 LUTs -> ~4 ns route -> `SDRAM_nWE`/`nCAS` |
| `6052243` (command decoded a clock early) | 2 | +0.481 | +0.025 | setup met on every clock (HDMI +0.538); 32,334 ALMs (77%). **Hold -0.418** at the SDRAM clock, one path: `firebeat_sdram` `m_addr2[15]` (`clk_sys`) -> `sdram` `a[15]`, 0.53 ns of data against 0.77 ns of skew. `m_addr2` changes only with `m_req2` and while port 2 is idle, and `a` loads `addr2` only on `ack2 != req2`, so the edge that might catch the change does not load it. Deployed with `--force` as `Firebeat_30000008.rbf` |
| `5c88cbb` (state dump) | 2, 3 | +0.130 (seed 3) | +0.483 (seed 3) | seed 2 misses the SDRAM clock by 0.193 ns on one route, `sdram` `dq_in[8]` -> `dq_in2[8]` (the DQ8 I/O cell); seed 3 meets setup on every clock (HDMI +0.504). **Hold -0.614** at the SDRAM clock, one path: `firebeat_sdram` `m_addr1[20]` -> `sdram` `a[20]`, the same case as `m_addr2` above: `m_addr1` changes only in the clock `m_req1` toggles, `req1` meets hold, and `a` loads `addr1` only on `ack1 != req1`. Deployed with `--allow-timing-miss` as `Firebeat_30000009.rbf` |
| `b13d252` (sensors, YMZ280B, CD audio) | 7 | -0.045 | -0.091 | HDMI -0.086; 38,198 ALMs (91%). Worst `clk_sys`: `fb_cache:u_ic\|ra[4]` -> the valid bits' 512-way register mux -> `nh0` -> GPR read -> `o_v[0][*]` |
| `0202c3d` (valid bits in the tag RAMs) | 7 | +0.075 | -0.069 | HDMI +0.208; 36,891 ALMs (88%). boot_tb's 6,000 frames: the five divergences of `debug/ppp11-boot/rtl_run_bc6f934.log` at the same entries, 15,486,566 accesses compared |
| | 2 | +0.423 | +0.026 | **met on every clock** (HDMI +0.166); 36,763 ALMs (88%). Deployed as `Firebeat_30000011.rbf` |
| `862bb2a` (NVRAM autosave, D-pad Left/Right, cabinet byte) | 2, 3, 4, 5 | +0.250, -0.284, +0.670, +0.250 | -0.118, +0.198, -0.263, -0.610 | none meets; HDMI -0.027 to -0.215 at seeds 3-5; hold -0.318 (SDRAM, seed 2), -0.606 (`clk_sys`, seed 3). Worst SDRAM path at seed 5 `sdram` `dq_in[11]` -> `dq_in2[11]` (DQ11's I/O cell to `dq_in2`, placed by its 256-bit fan-out); `clk_sys` at seed 3 inside `fb_ymz280b` (`cur` -> `vol_l`) |
| `a928331` (`dq_in3`, reads one SDRAM clock longer) | 2 | +0.499 | +0.617 | **met on every clock** (HDMI +0.269); 36,769 ALMs (88%). sdram_tb 20,000 random operations 0 errors, sys_tb passes. Deployed as `Firebeat_30000013.rbf` |

Logs `debug/build_d8f1_s{1,3,4,5}.log`, `debug/build_0bb8_s5.log`, `debug/build_81eb_s{2,3,4,5}.log`,
`debug/build_1674_s{2..6}.log`, `debug/build_6052_s2.log`; `build/BUILT_COMMIT` names `6052243` at seed 2.

Logs: `debug/build_disp_s2.log`, `debug/build_disp2_s2.log`; paths from
`scripts/report_worst_paths.tcl` (`build/output_files/worst_paths_Firebeat.rpt`).

## The seed 2 artifact on the board (Phase 5's first step)

`deploy.py --rbf-only` put it at `/media/fat/_Arcade/cores/Firebeat_30000005.rbf` (the Phase 1
artifact was `30000004`). It is the `Firebeat` revision at `5c83569` (HEAD `e0d79b7` at build
time), fitter seed 2, every clock positive. `hw.py launch` on
`/media/fat/_Arcade/_Firebeat/_dev/ParaParaParadise v1.1.mra` -- through `menu.rbf`, so the FPGA
really reloads -- gets `{"core":"ppp11","gameName":"ParaParaParadise v1.1"}` back from the Remote
API: the `.mra` is accepted and the framework runs. The flash was blank (no `.nv` file for it yet),
so this is the state the Test-mode install starts from.

The screen shows the core's built-in test picture, and it should: the GCU is Phase 3, so nothing
the game draws reaches the video path yet (ROADMAP, Phase 2's exit note). Its native screenshot
differs from `docs/screenshots/phase1_test_picture.png` in 7,416 of 196,608 pixels, all of them
inside the top 17 rows (the OSD band); the frame below is identical, so the video path through the
Phase 2 design is unchanged.

Two things this run settled about the probe route:

- The `Firebeat` revision carries no ISSP instance (`DEBUG_ISSP` is off): `scripts/read_issp.py`
  reports "No In-System Sources and Probes instance was found". Hardware evidence needs
  `Firebeat_stp`, a separate revision and therefore a separate timing gate.
- `Firebeat_stp` does not close, at either seed tried: seed 2 gives `clk_sys` -0.572 ns with TNS
  -33.2 and the SDRAM domain -0.874 ns; seed 3 gives -0.707 with TNS -15.9 and -0.585. Against
  +0.036 / +0.607 for `Firebeat`, and with tens of nanoseconds of TNS at both seeds, this is not
  placement: the probe bus itself costs the fit. The failing `clk_sys` paths are the same
  icache-to-`o_v` family, i.e. the 32-bit fetch address `brd_pc` tapped for probe M is loaded onto
  the address cone that has almost no margin to spare. The instrumented revision needs its probe
  fields registered next to the ISSP instance (a snapshot), not a seed, before its numbers mean
  anything; Phase 1's probe build closed because the design was smaller.

## Pop'n SPU in MAME: popn4 (Phase 8 step 1)

`scripts/mame/popn_spu.lua` to frame 9,000 (attract demo playing), summarised by
`scripts/popn_spu_stats.py`; output in `debug/popn4-spu/` (gitignored), with `out.wav`
(153.5 s at 48 kHz).

| What | Count over 9,000 frames | First frame |
|---|---|---|
| 68000 writes to the dual-port RAM | 671,991 (a block at 280600-28060F every frame) | 0 |
| 68000 reads of it | 27,359 | 2928 |
| PPC reads / writes of it | 393,572 / 6,565 (busiest frame 2,572) | 2928 |
| IRQ acks | 293,008 | 0 |
| SPU ATA commands | 610: A0 (PACKET) x600, E2 x5, E3 x2, E5 x2, EF x1 | 1093 |
| DMA address writes | 512 (high word 0-15) | 3820 |
| wave-bank writes | 1,036 (banks 0-3, all four) | 363 |
| RF5C400 accesses | 524,606, 3,615/s, six of them reads | 3.36 s |

Wave RAM at frame 9,000: 360 of 512 64 KB blocks non-zero, the highest at 0x1FB0000, so the
attract load already spans the full 32 MB.

Block RAM at `0202c3d`: 184 of 553 M10Ks, 1.17 of 5.66 Mbit; 369 blocks (4.49 Mbit) free. The
68000's 256 KB RAM (2 Mbit) fits there; its 512 KB ROM does not fit beside it and goes to SDRAM.

### The two CPUs' traces, popn4 to frame 4,500

`scripts/mame/systrace.lua` through `mame_run_lua`, fresh NVRAM, in `debug/popn4-68k/` and
`debug/popn4-ppc/` (gitignored). `mame_sys_trace` cannot run popn4: MAME refuses the DVD CHD
without a diff directory (`gq986jaa02.chd DIFF CHD ERROR`), which `mame_run_lua` gives it.

68000 (`CORE_CPU=:audiocpu`): every write, reads of 200000-34000F, 400000-400FFF and
800000-FFFFFF, autovector reads with SR's mask; 583 MB.

| 68000 access | Count | First frame |
|---|---|---|
| RAM writes (100000-13FFFF) | 16,351,068 | |
| wave RAM writes, then reads (via bank) | 786,432 each | 364, 419 |
| RF5C400 writes / reads | 524,510 / 2 | 201 / 3912 |
| dual-port RAM writes / reads | 278,522 / 10,448 | / 2929 |
| IRQ acks | 146,468 | |
| SPU ATA cs0 reads / writes | 212,759 / 1,420 | 1167 / 1094 |
| LED writes | 9,044 | 200 |
| wave-bank writes | 140 | 364 |
| DMA address writes (low, high) | 64, 64 | 3821 |
| DSW reads | 2 | 364 |

Interrupts taken (autovector reads at the new mask): level 2 35,343 times (the 500 Hz timer,
F:1394, or the ATA interrupt), level 4 271 (the dual-port RAM's 0x3FE, F:1194), level 6 354 (the
timer while an ATA interrupt is pending, F:1392). Each vector 0x60-0x7F is also read twice at mask
0. The wave RAM is written and read back over 786,432 words before the first ATA command: a RAM
test, so the wave RAM path is exercised before the disc is.

PPC (`CORE_WIO=70000000:7fffffff`: I/O writes only; work RAM writes are 8.1 million in the first
600 frames): first ATA access at frame 1850, first dual-port RAM access at 2929. Its 35 million GCU
writes were dropped from the kept file (`popn4_ppc_nogcu.trace`, 231 MB).

### spu_tb: fb_spu's 68000 against the trace (Phase 8 step 2)

`sim/spu_tb` at `9df2e50` and after: fx68k from reset with the ROM, RAM, the dual-port RAM, the
500 Hz timer and the registers, MAME's accesses compared a stream per SR mask. RAM writes to the
three stacks interrupts are taken on are left out (where an interrupt lands sets their PC, SR and
depth).

The first 508,574 compared accesses match, through the RAM test to MAME's first interrupt (frame
202, 3.38 s of 68000 time). They then differ in a value the program computes from that timing:
the level-2 handler stores the interrupted stack pointer into a task block at 10C65A (RTL 10DDCC,
MAME 10DDB4) and switches to the stack at 13F7xx. The SPU program is a task-switching kernel, so
its RAM follows where each timer interrupt lands, and an in-order comparison needs the interrupts
taken at MAME's instruction: the bench driving IPL itself, from the PC and SR MAME pushed at each
interrupt (in the trace), instead of the RTL's own timer.

## Feasibility

Open. Each item names what would close it. ppp11 measurements are in "Measured in MAME: ppp11" above; the other families are not measured.

1. **PPC403GCX at 66 MHz.** Measured for ppp11 in "PPC core on ppp11": the core alone closes
   66 MHz (77 MHz Fmax) and agrees with MAME over 2 M game instructions; with 403GCX-sized
   caches the peak game-loop frames need 84-93% of a 66 MHz frame, so 50.35 MHz does not fit.
   New RTL: the caches and the DMA controller. The text below is the research-time statement.
   The Hornet core is a 403GA at 1.75-1.94 clocks per instruction with
   one-clock memory and 64.2 MHz Fmax; the GCX differs in PVR, its 16 KB / 8 KB caches (not in
   MAME) and an MMU no set uses. Closed by: MAME's PPC busy fraction per frame in attract and play
   for each family (Hornet's `hornet_load.py` method), the core's CPI on firebeat code against a
   32 MB work RAM in SDRAM (latency-bound, as Hornet's was at port A latency 10 before its
   instruction cache), and a standalone fit at 66 MHz. The clock plan follows (Clocks).
2. **Storage.** Closed for ppp11 in "CD path on the board": raw images and, through the
   Main_MiSTer change (`MiSTer_Firebeat`), MAME's CHDs, byte-identical to the extracted .bin,
   1.42 MB/s each with both discs busy, worst first word 43 ms. The research-time text follows. Every set boots from a CD and the SPU sets stream a DVD or HDD. The path is the
   console cores' ("CD path" above): the slot and raw-image reads are generic; CHD decoding for
   this core is a Main_MiSTer change. Main_MiSTer's IDE/ATAPI (`ide.cpp`, `ide_cdrom.cpp`) also
   reads CHDs but is wired for x86, PCXT and uneon cores (`user_io.cpp:1009, 1628-1650`). The M2
   core carries the same open item (its Phase 0, item 7). Closed by: a test build with an image
   slot, launched from an `.mra`, reading sectors of a raw image at the drive rate, then of a CHD
   once the Main_MiSTer support exists; shared with M2. The install (Flash) adds a 6 MB
   persistence decision.
3. **Memory.** 71-103 MB without the media (sums above): a 128 MB module and/or DDR3 during play.
   Bandwidth: scan-out of one 640x480 RGB555 context is 36.8 MB/s, up to four contexts composed
   per pixel; blitter traffic is a read, a write and a blend read per pixel at an unknown rate.
   Closed by: per-frame counts of draw-object pixels, fill pixels and FIFO words from a MAME hook
   (`LOG_DRAW`/`LOG_CMDEXEC` in `k057714.cpp` or a Lua tap on the GCU registers), then the memory
   plan with each client's fetch arithmetic.
4. **VRAM size.** MAME gives the GCU a 32 MB address space and bounds destinations at 16 MB; the
   populated RAM is not in MAME. Closed by: the highest VRAM address any set reads or writes
   (from the same hook), and PCB photographs of the GQ972 if available.
5. **Sound.** RF5C400 (32 channels, envelopes, 32 MB wave RAM filled by the 68k's ATA DMA) has no
   RTL; the whole SPU board on the HPS as Hornet runs its sound board keeps the DVD and HDD on the
   ARM side entirely, so the FPGA sees only the PPC's CD. The alternative is fx68k + an RF5C400
   written from MAME + 32 MB more in SDRAM or DDR3 + the ATA DMA. The YMZ280B has the Cave RTL to
   check. MAME's 500 Hz SPU timer is a tuning, not the board (F:1420-1423): sound is judged by ear.
   Decision for the user.
6. **Keyboardmania.** Two GCUs and two portrait screens on one output (one selectable, or both
   side by side), plus the XT446 synth for the keyboard sounds, which is an MU100-class
   instrument with no RTL. kbm without keyboard sounds, or out of scope: the user's call.
7. **Area.** Before the GCU: PPC 5,896 ALMs (Hornet fit), fx68k 3,232-4,001 LUTs if on the FPGA
   (sibling floorplans), framework `sys/` 12,790-17,871 LUTs (Seta and HyperNG64 floorplans), YMZ280B and the CD path not measured. The GCU is a 2D blitter with scaling and
   blending; the nearest measured block is Hornet's `vraster` at 6,688 ALMs. Within 41,910 on
   paper; closed by the first fit.
8. **Reference quality.** All sets `MACHINE_IMPERFECT_SOUND`; ppp and ppd program CDs BAD_DUMP;
   the installed 0.289 binary and the source read differ by 1,527 commits (header).

Scope choices these put to the user, smallest first: ppp (PPC, one GCU, YMZ280B, two CD-ROMs, no
SPU); popn (adds the SPU board and the DVD; the most sets); bm3 (adds the HDD, floppy, MIDI
effects and the spectrum analyser); kbm (item 6).
