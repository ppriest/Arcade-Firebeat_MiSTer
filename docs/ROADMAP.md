# Konami Firebeat — MiSTer Core Roadmap

**Scope: ParaParaParadise, first set `ppp11` (user decisions). Phase 0 closed; phases 1-7
approved by the user; Phase 1's exit met on the board; Phase 2's exit met in simulation, awaiting acceptance; the Phase 5 timing gate met.** A phase whose scope changes goes back for approval.

## Context

Goal: a DE10-nano MiSTer core for Konami's Firebeat board, emulated by MAME's
`konami/firebeat.cpp` and `konami/k057714.cpp` and the devices they instantiate — a Quartus 17.0.2
Verilog/SystemVerilog project producing one `.rbf` and a `.mra` per supported set.

What shapes it: a 66 MHz PowerPC that needs caches and its on-chip DMA, a frame-buffer blitter
over 32 MB of VRAM, and both discs read from MAME's CHDs. Open RTL covers the PowerPC (the
Hornet core's, verified on ppp11 code). New work, in the order it gates the rest:

1. The memory system: SDRAM at 133.3 MHz for work RAM, flash and BIOS; DDR3 for the GCU's VRAM.
2. The PPC's caches (I 16 KB, D 8 KB write-back) and its DMA controller (channel 3).
3. The K057714 GCU, from MAME's model: display lists, blits with scale and blend, fills,
   characters, four composed display contexts, CRTC.
4. Two ATAPI drives over hps_io's image slots, the CHDs served by `MiSTer_Firebeat`.
5. The YMZ280B and CD audio.

Every number behind this is in [`HARDWARE_NOTES.md`](HARDWARE_NOTES.md). Cross-cutting findings
from the previous cores are in [`LESSONS_LEARNED.md`](LESSONS_LEARNED.md); working practice in
[`WORKFLOW.md`](WORKFLOW.md).

## Progress

**Phase 0 closed on ppp11; phases 1-7 approved; Phase 1's exit met on the board; Phase 2's exit met in simulation, awaiting acceptance; the Phase 5 timing gate met (seed 2, every clock positive).**

Phase 1 so far, each with its evidence:

| Item | State | Evidence |
|---|---|---|
| SDRAM at 133.3 MHz, cache, DMA, word and download ports | sim passes | `sim/sdram_tb`; HARDWARE_NOTES "Memory system benches" |
| DDR3 for VRAM, worst play frame beside scan-out | sim passes | `sim/vram_tb`; same section |
| top level, download, NVRAM file, test picture, read-back | sim passes | `sim/sys_tb` (commit 9b0ad9e) |
| MRA generator | done, ppp11 / ppp / ppd in `releases/_dev` | `scripts/gen_mra.py`, `validate_mra.py` clean |
| board exit | **met** on Firebeat_30000004 (commit 06ffbb2, fitter seed 3) | HARDWARE_NOTES "Phase 1 on the board" |

Fast DDR3 ROM loading is not used: the image is 512 KB.

Phase 2 so far:

| Item | State | Evidence |
|---|---|---|
| PPC caches (I 16 KB, D 8 KB, write-back) and the cache instructions | sim matches MAME | `sim/cpu_tb`: play window 2,000,000 and loading window 1,777,257 instructions; dcbf disabled fails |
| DMA controller | sim matches MAME | `sim/cpu_tb`, `sim/board_tb`: 295,756 DMA words to the GCU as MAME's |
| board: bus, serial port and DS1991, RTC65271, flash x 3, GCU and YMZ280B shells | sim matches MAME on the windows | `sim/board_tb`: 302,908 device accesses in order |
| PC16552D, registers only | written | `sim/boot_tb`: the DUART streams match MAME's; HACKS |
| ATAPI drives x 2 on the image slots, TOC block from MiSTer_Firebeat | written; serve the BIOS's disc load | `sim/boot_tb`; `chd_raw_check`: frames and TOC as .bin and .cue |
| the board in `firebeat_sys`: inputs, HPS time, NVRAM file (6 MB flash + the RTC's 4,152 bytes), VRAM on DDR3 | sim passes | `sim/sys_tb` step 6 boots the real BIOS; the NVRAM upload while running matches the flash |
| boot from power-on against MAME, installed NVRAM | startup check passes; through the game's load | `sim/boot_tb` on `debug/ppp11-boot` (6,000 MAME frames): every ATA access (7,098,647 data words), the serial port, RTC and flash streams equal to MAME's; the board then runs the game's code. Two fixes on the way: the serial port's interrupts only where MAME updates them (`fb_spu`, MAME_KLUDGES), the bench's RTC loaded after power-on (boot_tb `por`). Still differing: GCU data (not drawn until Phase 3) and lamp timing |
| SOUND FLASH INIT from blank NVRAM, with MAME's Test-mode presses | flash equal to MAME's | `sim/boot_tb` on `debug/ppp11-flashinit` (6,800 MAME frames, 70 min): all 15,244,959 flash writes in MAME's order, the three chips equal to MAME's at the end (`scripts/flash_compare.py`). The erase-status reads differ in count only: the 1 s sector erase is polled fewer times by the board's slower loop |
| stage2 frames within frame time | **not met** | the 94.7% / 92.6% measured a run that dropped half the GCU's DMA words; every transfer done, 143.1% of a frame with one DDR3 write per VRAM word, 101.3% with them gathered into bursts (HARDWARE_NOTES "DMA beside the CPU") |
| `docs/STATE.md` | every RAM and register file listed | STATE.md |
| rbf with the board | built, timing met | fits at 69% of ALMs (28,947) and 35,888 registers; fitter seed 2 closes `clk_sys` at +0.036 ns and the SDRAM 133 MHz clock at +0.607 ns (`debug/build_HEAD_s2_rerun.log`, `build/BUILT_COMMIT`); the same commit fails the SDRAM clock at seeds 5-8 (HARDWARE_NOTES "Timing closure for the full design") |

**Phase 2's exit is met in simulation**, for the user's acceptance. The BIOS's "EXEC: OK" is
inferred, not seen: nothing is drawn before Phase 3; the board gets through the whole disc load
as MAME does and runs the game's code after it.

Phase 3 so far:

| Item | State | Evidence |
|---|---|---|
| command engine: FIFOs, display lists, fill, object blit (scale, flip, blend, transparency), characters, origin | sim matches MAME | `sim/gcu_tb`: attract and play windows, VRAM 0 pixels differing; 8 random windows; 23 mid-command resets (HARDWARE_NOTES "GCU command engine"); `sim/boot_tb` with the engine in: every ATA data word (7,098,647) equal to MAME's and the same first divergences as without it (`debug/ppp11-boot/rtl_run_gcu.log` against `rtl_run.log`) |
| play window's commands against frame time | 47.8% of 8 frames at lat 20; 56.1% at lat 40 with 20% busy beside the display | same section |
| display: four contexts, CRTC, scan-out | sim matches MAME | `sim/disp_tb`: both windows' screens, 24 random register sets; `sim/gcu_tb +scan=1`: the shown frame equals `screen_out` after the replay (HARDWARE_NOTES "GCU display") |
| rbf with the engine and display | built, timing met; on the board: E121 at the BIOS's GCU RAM test, reproduced in `sim/sys_tb` and fixed there (HARDWARE_NOTES "DMA beside the CPU"); not rebuilt | commit `798a5df`, fitter seed 5: every clock positive (`clk_sys` +0.457, SDRAM +0.276, HDMI +0.165 ns), 32,029 ALMs (76%); seeds 1-4 miss (HARDWARE_NOTES "Timing closure for the full design") |

Phase 0's results, each with its section in HARDWARE_NOTES:

| Item | Result | Section |
|---|---|---|
| 0, reference MAME | `firebeat.exe` from `E:/MAME-Checkouts/mame-firebeat` (branch `firebeat-meas`: per-frame GCU counters as outputs, a CD-audio mute switch); `mister.env` points at it | ROADMAP history, `mister.env` |
| 1, workload | install from Test mode; 512x384 at 58.6 Hz in the 24 kHz mode; VRAM the whole 32 MB, 196-236 MB/s in play; work RAM to the top of 32 MB; game loop 5-15% of 66 MHz median, 44% peak; loading (LZSS) 86-99% in runs; program CD READ(10) ≤256 KB, 102 KB/s in play; music as CD audio | "Measured in MAME: ppp11", "Play" |
| 2, CD path | two image slots from an `.mra`; raw images 4.66 MB/s one slot, 2.25 each both; CHDs through `MiSTer_Firebeat` byte-identical to the .bin, 1.42 MB/s each both, worst first word 43 ms | "CD path on the board" |
| 3, PPC | 4.3k ALMs, 77 MHz Fmax alone; agrees with MAME over 2 M stage2 instructions; with GCX-sized caches 84-93% of 66 MHz in the heaviest game-loop frames; the game feeds the GCU by on-chip DMA | "PPC core on ppp11" |
| 4, YMZ280B | ADPCM, 16-bit PCM, centre pan, flash readback; the Cave module lacks PCM and readback; a YMZ-only MAME reference captured | "YMZ280B on ppp11" |
| 5, memory | ~1.26 MB of work RAM traffic a peak frame (74 MB/s), ~84% of a 16-bit SDRAM at 66.67 MHz | "Memory plan inputs" |
| 6, area | ~20-28k ALMs of 41,910, ~170 M10K of 553; framework and PPC measured, the GCU least known | "Area" |

## Game scope

| Family | Config | Sets | SPU | Media | MAME status |
|---|---|---|---|---|---|
| ParaParaParadise | `firebeat_ppp` | ppp, ppp11, ppd, ppp1mp | no | 2 CD-ROMs | imperfect sound; ppp, ppd program CD BAD_DUMP |
| Pop'n Music | `firebeat_popn` | popn4-8, popnmt (+1), popnanm (+1), popnanm2 (+3) | 68000 + RF5C400 | CD-ROM + DVD-ROM | imperfect sound |
| Beatmania III | `firebeat_bm3` | bm3, bm3core, bm36th, bm37th, bm3final | 68000 + RF5C400 | CD-ROM + HDD, floppy | imperfect sound |
| Keyboardmania | `firebeat_kbm` | kbm, kbh, kbm2nd, kbm3rd | no; XT446 synth | 2 CD-ROMs; two GCUs, two screens | imperfect sound |

### Scope decision

- **In scope:** the ParaParaParadise family: PPC, one GCU, YMZ280B, two CD-ROM drives, no SPU
  board. One memory map (`firebeat_ppp_map`, F:1652-1660), one screen.
- **Out of this scope:** Pop'n Music and Beatmania III (a second processor board with an RF5C400
  and 32 MB of wave RAM, a DVD or HDD); Keyboardmania (two GCUs on two screens, an MU100-class
  synth). Pop'n Music is next: Phase 8, scoped by the user.
- **First target `ppp11`**, the only set of the family with both CDs and the dongle dumped good,
  and the one Phase 0 measured. Then `ppp`, `ppp1mp`, and `ppd` (the Korean cabinet's sensor bars
  6-8, F:2062-2082, `init_ppp_overseas`).

## Hardware reality

[`HARDWARE_NOTES.md`](HARDWARE_NOTES.md) holds every value with its file and line. The ppp board:

| Part | Clock | Role | Source |
|---|---|---|---|
| PPC403GCX | 66 MHz | main CPU; I 16 KB / D 8 KB caches, DMA channel 3 feeds the GCU; the dongle on its serial port | F:735, 729; "PPC core on ppp11" |
| K057714 GCU | pixel 16.6666 MHz (ppp), 25.175 MHz (others) | blitter, display lists, four display contexts, CRTC, 32 MB VRAM | F:752, 757, 1032-1055; G: |
| YMZ280B | 16.9344 MHz | 8 voices from the two 2 MB sound flash chips | F:763, 800-805 |
| 3 x 29F016A | | program (blank on ppp) and samples, written by the install | F:740-742 |
| RTC65271 | | RTC and 4 KB NVRAM (the backup settings) | F:738, 791-792 |
| ATA, two CD-ROM drives | | program CD (`ata:0`), audio CD with CD audio (`ata:1`) | F:744-746, 390-394 |
| PC16552D | 19.6608 MHz | network UART, unused by ppp | F:769-771 |
| DS1991 dongle | | serial, mode, licence | F:820-985 |

ppp's screen: 512 x 384 of 685 x 416 at 16.6666 MHz, 58.49 Hz (GCU mode 1, `control_w` bit 0
set). Display aspect 4:3.

### Clocks (decided)

| Clock | Rate | From clk_sys | Note |
|---|---|---|---|
| clk_sys | 66.667 MHz | | 50 MHz x 4/3, exact; the video clock |
| SDRAM | 133.333 MHz | x 2 | 50 MHz x 8/3, exact; Hornet's controller ran 128 MHz CL3 |
| PPC | 66.667 MHz | enable 1 | 1.01% faster than the board's 66 MHz (HACKS when written) |
| PPC timebase, PIT, FIT | 66 MHz | enable 99/100, exact | keeps the RTOS's timers at the board's rate |
| pixel | 16.667 MHz | enable 1/4 | the board's crystal is 16.6666 MHz: 4 ppm slower, 58.4877 against 58.4875 Hz (HACKS) |
| YMZ280B | 16.9344 MHz | enable 3969/15625, exact | Bresenham |
| DDR3 | the HPS's port, clocked at clk_sys | | as Hornet |

The 25.175 MHz mode (31 kHz, 640x480) is not used by ppp; it needs a second pixel cadence and is
left to the family that uses it.

## Phase 0 — closed

The gate's proposal and its measurements are in git history and in HARDWARE_NOTES (sections in
the Progress table). Its tools stay in use: `scripts/mame/ppp_load.lua` and
`scripts/ppp_load_report.py` (workload), `scripts/mame_ppc_window.py` and `sim/ppc_tb` (CPU windows
replayed against MAME), `scripts/mame/ymz_capture.lua` (YMZ280B reference), `rtl/cdtest` (the CD path, read with
the MCP's `probe_sequence`), `scripts/main_mister/` (`MiSTer_Firebeat` build and its host
check).

## Phases 1-7 (proposed)

Each phase ends with a commit, a bench fed from MAME, and its exit check run.

### Phase 1 — Skeleton and memory system

- **Top level** from the template: PLL per the clock table; video timing from a CRTC stub at
  512x384 / 685x416 and enable 1/4; HDMI and analogue out through `sys/`; `Firebeat_stp` with
  ISSP probes and the OSD's hidden debug page.
- **SDRAM at 133.3 MHz**, Hornet's `hornet_sdram.sv` (Sorgelig's controller, port A cache, read
  ahead) as the start: ports for PPC line fills and write-backs (16-byte bursts), DMA source reads
  (64-byte bursts), the YMZ280B's sample reads, and the loader. Fixed priority with a starvation
  check (LESSONS: Hornet's posted-write starvation).
- **DDR3**, Hornet's `hornet_ddr3.sv` / Psikyo's backend as the start: VRAM 32 MB with ports for
  the GCU's blit reads and writes and for scan-out (bursts of a line).
- **Loading** from the `.mra`: BIOS 512 KB, dongle image, RTC preset; the MRA generator with
  `<mameversion>`, `validate_mra.py` clean.
- **Persistence** of the installed state, 4 MB of sound flash + 2 MB main flash + 4 KB of RTC
  NVRAM, as the core's NVRAM files through hps_io (decided).
- **Discs**: `S0` and `S1` slots offering CHD, served by `MiSTer_Firebeat`.
- **Benches**: the SDRAM and DDR3 front ends replaying the measured traffic of the stage2 window
  (`sim/ppc_tb` with the cache model counts it) at the peak rate; per-request latency histogram.
- **Exit**: on the board, the test picture at 58.49 Hz measured on a probe, the BIOS and dongle
  loaded and read back, the memory benches meeting the latencies the CPI figures assumed (10-20
  clocks at clk_sys for a line fill).

### Phase 2 — CPU and system in simulation

- **PPC** behind a bus wrapper with the **I 16 KB / D 8 KB write-back caches** and the **DMA
  controller** (software memory-to-memory, the mode ppp uses; anything else trapped on a probe),
  external interrupts IRQ0-4 as `firebeat.cpp` routes them, the timebase at 99/100.
- **System devices** from the device files: RTC65271, three 29F016A flash with their command state
  machine, the extend-board IRQ registers, inputs and DIPs, lamps (dropped), `control_w`, the
  DS1991 dongle on the PPC's serial port, the PC16552D as registers only.
- **ATAPI drive model x 2**, from `atapihle.cpp` / `atapicdr.cpp`: the commands ppp sends (TEST
  UNIT READY, READ TOC, SET CD SPEED, READ(10), MODE SELECT(10), PLAY AUDIO(12), READ SUB-CHANNEL,
  STOP), sectors from the slots, PIO data and the IRQ4 line. Verilator serves the CHD-equivalent
  `.bin` from a file.
- **GCU register shell**: vblank IRQ, status, the write ports and the FIFO; commands logged, not
  drawn (Phase 3 draws them).
- **YMZ280B register shell** with the flash readback (the startup check reads it).
- **Benches**: the boot trace equal to MAME's access for access (`mame_boot_trace.py`, ported to
  the PPC); the stage2 and loading windows in the whole system rather than the CPU bench; the
  install run from MAME's state.
- **Exit**: in Verilator, the BIOS through "EXEC: OK", the startup check passing from installed
  NVRAM, and SOUND FLASH INIT writing flash equal to MAME's; the stage2 window's frames finishing
  within their frame time at the memory model's measured latency; `docs/STATE.md` listing every
  RAM and register file reachable.

### Phase 3 — Video: the GCU

- **Command engine** from `k057714.cpp`: the two write ports and command FIFOs, display lists
  (nesting, 0x1000-entry limit), fill (4-pixel pattern), object blit (6.6 scale, x/y flip, three
  blend modes, bit-15 transparency, the 16 MB destination bound), 2-bpp characters, the origin.
  Blits as row bursts against DDR3, a read stream and a write stream.
- **Display**: four contexts composed in register 0x10's order with their alpha and blend
  modes, the CRTC from registers 0x00-0x08, a line FIFO from DDR3 ahead of the scan.
- **MAME is followed where it is the only model**: no busy status and instantaneous commands in
  MAME (HARDWARE_NOTES, Video); the core takes time, which the game must tolerate (checked in
  the exit, logged in MAME_KLUDGES / HACKS as it lands).
- **Benches**: commands and VRAM from MAME savestates (`k057714.cpp` saves VRAM), the core's VRAM
  and frame compared with MAME's after each command batch; the per-frame counters
  (`gcu:stat*`) as the throughput target: 2.0 M 16-bit accesses in the worst play frame.
- **Exit**: frames bit-exact with MAME for captured attract and play scenes; the worst measured
  frame's command list completed within a frame at the DDR3 latency measured in Phase 1.

### Phase 4 — Sound

- **YMZ280B** written from `ymz280b.cpp`: 8 voices, ADPCM, 8- and 16-bit PCM, 9-bit pitch, pan,
  loop, key-on/off, IRQ, the readback; samples from the sound flash in SDRAM. The Cave decoder as
  a cross-check of the ADPCM path.
- **CD audio** from `S1`: PLAY AUDIO(12) streamed from the slot at 176.4 KB/s through two 16 KB
  buffers, READ SUB-CHANNEL's position kept in step; mixed with the YMZ280B.
- **Benches**: the YMZ280B against `debug/ymz_ref` (register accesses with their times, the chip's
  output alone), compared as audio; CD audio against the .bin.
- **Exit**: the bench output matches MAME's within the interpolation's rounding; on the board,
  judged by ear against MAME for the attract and the first stage.

### Phase 5 — On the board

- `build_staged.py` and `deploy.py` (timing met on every clock, no feature on a failing build);
  `ppp11` installs from Test mode, boots, plays attract and a stage. The timing gate is met:
  `clk_sys` +0.036 ns, SDRAM +0.607 ns, seed 2 (HARDWARE_NOTES "Timing closure for the full
  design").
- **Probes**: per-frame PPC busy and memory latency, DDR3 and SDRAM queue depths, GCU frame
  overruns, CD request waits. A state dump to a file the Phase 2 bench loads.
- **Exit**: `ppp11` plays through a stage with the sensors, the frame rate held, the probes
  within the Phase 0 budgets; then `ppp`, `ppp1mp`, `ppd` boot and play.

### Phase 6 — Standard features

- **Inputs**: Left, Right, Start/OK, Test, Service, Coin; the sensor bars 1-5 as buttons (ppd
  6-8), with MAME's keyboard keys beside the pads; IN3's DIP switches on the OSD.
- **Pause** suspending the PPC (and its DMA and the GCU's command engine with it); hiscore does
  not apply (the RTC NVRAM holds the settings).
- **CRT Adjust**, HDMI scaling and crop, flip screen (ppp has no flip DIP: a fake one); audio
  stereo only, no mono or mix option (`AUDIO_MIX = 0`);
  the OSD shows only what applies.
- **Exit**: the README's feature list checked on the board, flip against the unflipped frame
  rotated 180 degrees.

### Phase 7 — Release

- README (sets, controls, the `MiSTer_Firebeat` requirement and its `MiSTer.ini` line, where the
  CHDs go, the AI statement), HACKS, MAME_KLUDGES, STATE current; one `.mra` per set; floorplan;
  the Downloader database.
- The Main_MiSTer change's route out (see "Open decisions").

## Phase 8 — Pop'n Music (approved)

The `firebeat_popn` sets (F:2760-2772): the PPC board as built, one program CD on the main ATA bus,
and the SPU board (F:1183-1231, F:1519-1539):

| SPU part | MAME | Plan |
|---|---|---|
| 68000 at 16 MHz, 512 KB program ROM, 256 KB RAM | `spu_map` F:1211-1226 | fx68k, vendored with `PROVENANCE.md`; ROM in SDRAM, RAM in block RAM (HARDWARE_NOTES, "Pop'n SPU in MAME") |
| CY7C131 dual-port RAM, 1 KB, IRQs at 0x3FE/0x3FF | F:1193-1195, PPC at 0x74000000 | block RAM, two ports |
| RF5C400, 32 voices, 16.9344 MHz | `rf5c400.cpp` | written from MAME's model (no RTL in the reuse map); bench from a MAME capture, as the YMZ280B's |
| wave RAM 32 MB, banked into the 68000 at 0x800000 (4M words a bank) | F:1228-1231, 1333-1346 | SDRAM: Pop'n needs a 128 MB module |
| SPU ATA bus, DVD-ROM, DMA into wave RAM | F:1525-1529 | `fb_atapi` on a second bus, 2048-byte sectors; the CHD service extended for DVD CHDs |
| 500 Hz SPU timer | F:1531-1534, a value MAME chose by ear | `docs/MAME_KLUDGES.md` |
| inputs: 9 buttons, coin, test, service | `popn` ports F:2173-2198 | the J1 line rebuilt per family |

Shape: a separate revision, `Firebeat_popn`, chosen by the `.mra`'s `<rbf>`. It leaves out the
YMZ280B and the sensor bars, and the second CD drive's disc slot and CD audio; the drive stays,
empty, as MAME's `ata:1` (firebeat() F:748, kept by firebeat_popn). hps_io slot 1 is the SPU's DVD.

Status: steps 2 to 4 in RTL (`25df768` and after); step 3's bench not run (the user's call, to
wire first). Step 4's bench, `sim/rf5c_tb`: a Python port of MAME's RF5C400 matches MAME's
44.1 kHz .wav exactly on popn4's three attract tunes, and the RTL matches the port on 3 x 132,300
samples. The DVD CHD service checked on the host against `chdman extractraw` (two ranges of
gq986jaa02, 0 bytes differ).

Steps, each with its bench before hardware:

1. MAME captures for popn4: PPC-side boot trace, the 68000's trace, the dual-port RAM traffic, the
   SPU ATA commands, RF5C400 register writes and output. Area and memory budgets from them.
2. The revision and the SPU skeleton: fx68k, its ROM and RAM, dual-port RAM, IRQs; the 68000's
   trace against MAME's.
3. The SPU ATA bus and the DVD slot; the wave RAM load against MAME's.
4. RF5C400; output against MAME's.
5. On the board: popn4 to its attract mode, then the other sets.

Sets: popn4 first (`gq986jaa01`, `gq986jaa02` on hand), then popn5-8, popnanm, popnanm2, popnmt.

`.mra`s for all of them in `releases/_dev/`, written by `scripts/gen_mra.py`; all are
`firebeat_popn` with the same BIOS (`a02jaa03.21e`) and SPU program (`a02jaa04.3q`).

| Set | Program CD | Data DVD | Status |
|-|-|-|-|
| popn4 | `gq986jaa01` | `gq986jaa02` | boots and plays on the board |
| popn5 | `a04jaa01` | `a04jaa02` | untested |
| popn6 | `gqa16jaa01` | `gqa16jaa02` | untested; dongle a bad dump in MAME (192 bytes) |
| popn7 | `b00jab01` | `b00jaa02` | untested |
| popn8 | `gqb30jaa01` | `gqb30jaa02` | untested |
| popnanm | `gq987jaa01` | `gq987jaa02` | untested |
| popnanma | `gq987jaa01` | `gq987jaa02` | untested; clone of popnanm |
| popnanm2 | `a02jac01` | `gea02jaa02` | untested |
| popnanm2a | `a02jac01` | `gea02jaa02` | untested; clone of popnanm2 |
| popnanm2ja | `a02jaa01` | `gea02jaa02` | untested; clone of popnanm2 |
| popnanm2jaa | `a02jaa01` | `gea02jaa02` | untested; clone of popnanm2 |
| popnmt | `976jaa01` | `976jaa02` | untested; rental cabinet (nibble 6, init_popn_rental) |
| popnmt2 | `976jba01` | `976jaa02` | untested; clone of popnmt; rental cabinet |

## Phase 9 — Keyboardmania (approved)

The `firebeat_kbm` sets (F:1805-1880): the ParaParaParadise board (PPC, YMZ280B and its flash,
RTC, two CD-ROM drives with CD audio) plus:

| Part | MAME | Plan |
|---|---|---|
| second K057714, `gcu_sub` at `7E800100-7E8001FF` | F:1834-1840, 1875 | a second `fb_gcu_shell`, its own VRAM in DDR3; one `fb_gcu` and one `fb_gcu_disp` serve both |
| two screens, both ROT270: 640 x 480 at 25.175 MHz in the BIOS, then 512 x 384 at 16.6666 MHz, 58.32 Hz, in the game (HARDWARE_NOTES, "Keyboardmania in MAME") | F:1821-1832, 2755-2758 | the GCU's existing modes; OSD: left, right, or both side by side (decision A) |
| PC16552D `duart_midi`, 24 MHz, top byte lane, `offset>>6` | F:1852-1864, 1876 | a second `fb_pc16552`; IRQ1 through the extend-board enable bits 0 and 1 (F:1903, 1914) |
| two MIDI keyboards, 24 keys, 31250 baud, chan1 left, chan0 right | F:1855-1864, `midikbd.cpp` | note-on/off bytes generated into each RX from the MiSTer inputs (24 keys a player from the keyboard and pad buttons) |
| modulation wheels at `70008000` (0 = P1, 8 = P2) | F:1877, 1882-1891 | paddle or analogue axis |
| lamps at `7D000804` | F:1999 | written and ignored, as ppp's |
| XT446 synth: H8S/2655 16 MHz, SWP30, 24 MB wave ROM, fed from chan1's TX | F:1866-1869, `xt446.cpp` | OSD: chan1's TX to an MT32-pi on the user port, or the XT446 ported from MAME (decision B) |
| inputs: Start P1/P2, Test, Service, Coin | `kbm` F:2096-2110 | the J1 line rebuilt per family |

Shape: a separate revision, `Firebeat_kbm`, chosen by the `.mra`'s `<rbf>`, one `.rbf` per family
(Decisions taken). No SPU, no sensor bars.

Budgets, from the fit reports in `build/output_files/`:

| | ALMs | Source |
|---|---|---|
| `Firebeat` revision (ppp) | 36,769 (88%) | `Firebeat.fit.rpt` |
| second GCU: shell + engine 2,627, display 823 | ~3,450 | `Firebeat.fit.rpt`, `Firebeat_popn.fit.rpt` |
| second PC16552 87, key generator and wheels | ~300, estimated | `Firebeat_popn.fit.rpt` (`u_uart`) |
| sum | ~40,500 of 41,910 (97%) | |
| `Firebeat_kbm` measured, without the second display: 42,119 (100%), fit failed. Second GCU 2,601, MIDI UART channels 500 + 504 (the estimate was 87 a channel: their 16-byte FIFOs are registers) | 42,119 | `Firebeat_kbm.fit.summary`, build of `142aab3` |
| `Firebeat_kbm` with one engine for both GCUs: 41,028 (98%), fits, timing not met (HDMI setup −0.471, clk_sys setup −0.162, clk_mem hold −0.542). The GCUs 3,655 (shells 805 + 722, engine 2,129) against 5,445; the second display (~900) not yet in | 41,028 | `Firebeat_kbm.fit.summary`, build of `49b59d6` |
| `Firebeat_kbm` with the MIDI UART FIFOs in MLABs: 40,370 (96%), fits, timing not met (HDMI setup −0.048; clk_sys +0.175, hold met). UART channels 347 + 360 against 519 + 527; the second display (823-906) would take it to about 41,250 (98%) | 40,370 | `Firebeat_kbm.fit.summary`, `.sta.summary`, build of `38441e9` |
| `Firebeat_kbm` with one display for both GCUs: 40,690 (97%), 320 more; clk_sys setup −0.002, everything else met. No HDMI rotation | 40,690 | `Firebeat_kbm.fit.summary`, `.sta.summary`, build of `87b10de` |
| `Firebeat_kbm` with HDMI rotation, in place of the test picture's writer: 40,693 (97%), 3 more, 200 RAM blocks (12 more); timing not met: clk_mem setup −0.243 (TNS −0.517), the rest met. Seed 2: 40,997 (98%), HDMI setup −0.211, clk_mem −0.076, clk_sys setup −0.025 and hold −0.618; seeds 3 and 4 fail too. Seed 5 meets timing: 41,042 (98%), HDMI setup +0.059, clk_mem +0.130, clk_sys +0.529 | 41,042 | build logs of `f0a5b3e` and `55eb661` (same RTL); `build_seed5` |
| `Firebeat_kbm` with the RTC preset (`323c6fd`): seeds 5-14 all fail timing at 96-97%, in the SDRAM pin registers (clk_mem, `dq_in` -> `dq_in2` up to -0.788), `ascal`'s adaptive filter (HDMI, -0.368) and `fb_ymz280b` (clk_sys, -0.034). Without the adaptive scanline filter and YC output (`4274ab2`): 38,306 (91%), seed 5 meets timing (HDMI setup +0.087, clk_mem +0.189, clk_sys +0.605) | 38,306 | `build_worst_paths` on `build_seed8`, `10`, `13`, `14`; `build_seed5` of `4274ab2` |

That does not fit with timing closed (Firebeat_popn at 90% was seed-sensitive). Ways back, each to
be measured by a build: one drawing engine time-shared by both GCUs (two register files and
display contexts, one `fb_gcu`, ~1,900 back); leaving out what kbm does not use (the network
UART, ppp's sensor path). For a shared engine, both GCUs' work a frame together is at most
about 1.4 M source and 1.4 M destination pixels in attract, 0.5 M each in play (HARDWARE_NOTES);
whether `fb_gcu`'s rate covers that inside a frame is checked in step 3.

VRAM traffic, measured (HARDWARE_NOTES, "Keyboardmania in MAME"): both GCUs together 252 MB/s
median and 310 MB/s worst in play, 500 MB/s in the worst attract frame, against ppp's 236 MB/s,
on one DDR3 port at clk_sys (533 MB/s at 64 bits a clock, before overheads). VRAM is 64 MB, each
GCU reading to the top of its 32 MB. The port's sustained rate is measured on the board before
step 3; if it falls short of 500 MB/s, the worst attract frames finish late (MAME draws every
command at once, so this is work, not timing).

Steps, each with its bench before hardware:

1. MAME captures for kbm: PPC boot trace, both GCUs' register and FIFO traffic, VRAM traffic per
   frame per GCU, the MIDI UART traffic both ways, YMZ280B writes. The area and bandwidth numbers
   above replaced by measured ones; the plan revised before step 2. Done except the area (a build,
   step 2): HARDWARE_NOTES, "Keyboardmania in MAME"; the install (BACKUP CLEAR) and the screen
   mode found on the way.
2. The revision: second UART, key generator, wheels, inputs, and the second GCU's registers and
   VRAM (no display: the BIOS tests its VRAM before it reaches the MIDI setup); the PPC trace
   against MAME's through the MIDI setup. Bench done (`sim/boot_tb -GKBM=1` to frame 4300): ATA, RTC,
   MIDI and wheel streams match MAME's; the boot screen's GCU words and the extend board's IRQ acks
   differ in order or value with timing (the BIOS's draw, the two keyboards' relative phase). The
   area build remains.
3. The second GCU's display and the screen output (decisions A, C); each screen's frame against MAME's
   `lscreen` and `rscreen`. Bench done (`sim/disp_tb -GKBM=1 +kbm=debug/kbm-screens4000`): left, right
   and stacked, 0 pixels differing, no late line at DDR3 latency 60 and 30% busy. One `fb_gcu_disp`
   serves both: only one screen is on the raster at a time. HDMI rotation: `rtl/video/fb_rot16.sv`,
   on the DDR3's master 1 (the test picture's writer, which KBM does not build). Bench done
   (`sim/rot_tb +kbm=debug/kbm-screens4000`, 5 s): left, right and stacked rotated, 0 pixels differing.
   With writes stalled a uniform 0..N clocks, stacked loses no slice at N=8 and loses 362 at N=16;
   single loses none at N=24. Its rate on the board is not measured, and `late` reaches no probe.
   On the board (`Firebeat_kbm_30000013`, kbm3rd attract, both screens rotated) probe X read
   `rot_late=65535` in 2,547 frames: a beat a command is too slow stacked. Since then 16-line slices,
   a 4-beat burst a framebuffer row: the bench (stall per command) loses nothing stacked at N=72 and
   loses 29 slices at N=96, CCW and CW. `Firebeat_kbm_30000014` still read `rot_late=19208` in 4,171
   frames stacked: between bursts the rotator dropped its request for a clock, and hornet_ddr3 gave the
   port to the GCU's bursts of up to 128 beats. With the request held (f27c5a4), `Firebeat_kbm_30000015`,
   kbm3rd attract, both screens rotated: `rot_late=0 x_frames=3340 scan_late=2`
   (`debug/hw/shot-20261113-212831.png`).
4. MIDI out to the MT32-pi; its byte stream against MAME's chan1 TX capture, then by ear on the board.
5. On the board: kbm to its attract mode, then kbm2nd, kbm3rd, kbh. kbm reaches attract from the
   RTC preset (`debug/hw/shot-20261108-014828.png`); the user reports noisy sound effects and draw
   time not met. Plan (user): (a) probes in a `Firebeat_kbm_stp` revision, per frame: the GCU
   engine's busy clocks and the CPU's queue-full hold per GCU, the deepest queue, a list running at
   vblank, `fb_gcu_disp`'s late lines, `fb_rot16`'s dropped slices, the YMZ280B's lost ticks, longest
   pass and slowest sample read; (b) the sound flash 0xFF when no NVRAM file loads (it is otherwise
   the SDRAM's old contents, and kbm keys ADPCM voices from it; where a cabinet's samples come from
   is open); (c) HDMI rotation CW and flipped as well as CCW; (d) optimise from the readings.
   (a)-(c) in `d31f8f2`; F and M are left out of `Firebeat_kbm_stp` to fit (98% ALMs, seed 9 met;
   `Firebeat_kbm` seed 5 met at 97%). kbm attract, `Firebeat_kbm_30000003.rbf`, clk_sys 66.667 MHz
   (1.14 M clocks a frame), X cleared at boot: the YMZ280B lost no tick, longest pass 103 clocks and
   longest read 60 of 756; fb_rot16 dropped slices past the counter's 65535; frames with a CPU write
   to a GCU queue held 4,764 of 6,188; frames starting with the engine running 5,032; the most engine
   clocks in a frame 1,143,166 (all of it). The last frame (K): engine 273 k for GCU 0, 300 k for
   GCU 1, 50 k of it waiting on DDR3; GCU 1's queue full and the CPU held 386 k; deepest queue 2 and
   30 of 32. The engine's own rate, not DDR3, holds the CPU.
   The board's `Keyboardmania.nvm`, autosaved before (b), held SDRAM leftovers in all three flash
   chips (sound flash 2: 383,856 of 2 MB 0xFF; MAME's kbm flash stays all 0xFF through boot and
   attract) and loaded them at each launch: replaced on the board by 0xFF flash with its own RTC,
   the old file kept as `Keyboardmania.nvm.garbage-flash`.
   Profile (`sim/gcu_tb +prof`, lat 20, busy 10%) of attract frames 9201-9208, the heaviest scene
   (1,141 of 14,027 attract frames; 16 objects, 526 k pixels drawn and 310 k blended a frame per
   GCU): each GCU alone takes 62% of the frames (`debug/kbm-vram9200`, `-sub`; 0 pixels differ),
   so the shared engine needs 124%. Of a GCU's clocks: the source row read 30%, the destination
   read before blending 22%, the pixels a beat a clock 20%, the chunk's write 24%, each waiting for
   the last. DDR3 moved 2.63 M beats in 5.64 M clocks; DDRAM_CLK is clk_sys. Drawing behind the
   reads (DR apart from DB): 49.8% and 49.4%, 99% for the pair; 39.7% at lat 5 busy 0. The regression
   windows, random windows and six resets unchanged (0 pixels differ). The next row's source read
   before the row's write: 39.4% and 39.1%, 79% for the pair; 32.4% at lat 5 busy 0. The DDR3 model
   now returns a read's data as of its command: without the overlap check gcu-rand5-8 differ by
   2,820-7,398 pixels, with it 0.
   On the board (probe K, `Firebeat_kbm_stp` 30000007, attract): the shared engine ran 363 k and
   366 k clocks for the two GCUs in a frame, GCU 1's queue was full and the CPU's writes to it held
   for 630 k, and 13,076 of 15,742 frames began with the engine still drawing (the second screen
   drawn incompletely, user); scan-out had no late line and the rotator dropped nothing (probe X).
   An engine per GCU (`521e2c4`, the second on its own DDR3 master): 2,143 ALMs more, 89-90%, and
   timing failed on seeds 5, 7, 9 and 10 (HDMI and clk_mem). Reverted for the read-ahead below:
   the engine is near DDR3-bound, so two engines on one DDR3 gain little over one.
   Read-ahead in `fb_gcu` (`sim/gcu_tb +prof`, `kbm-vram9200`, lat 20 busy 10%, one GCU): a second
   read queued behind the first (the blend's destination read no longer waits for the source row to
   land) 3,596,720 -> 3,405,110 clocks; the destination read issued ahead of the previous row's held
   write, the chunk built once that write has read DB out (and the write first when the two meet:
   an object wider than a VRAM row) 3,004,197 (32.9% of 8 frames; 66% for both GCUs on one engine),
   of which 2.63 M clocks are the window's DDR3 beats.
   Every window that matched still matches (gcu-one and gcu-sub differ by 26,948 and 34,634 pixels
   with or without it). A reset mid-window leaves pixels 0-1 of gcu-rand5 wrong at some reset clocks,
   with or without it (2 of 51 points before, 5 of 51 after): not found yet.
   On the board with read-ahead (`c1aa14e`, `Firebeat_kbm_stp` 30000009, attract, counters cleared
   in the how-to-play demo, 11,367 frames): the last frame's engine time 194 k and 210 k clocks
   (was 363 k and 366 k), GCU 1's writes held 209 k (was 630 k); the worst frame 918 k busy and
   882 k held; 10,457 frames began with the engine drawing and 11,353 had a write held; no late
   scan-out line, nothing dropped by the rotator. Release build: `Firebeat_kbm` 30000008, seed 10.
   `Firebeat_kbm_stp` 30000017, one screen (user: lines on that screen lag or are not drawn, then
   tear): probe X `x_busy=1143166 frames_held=63576` of 65,535 frames, `rot_late=0 scan_late=0`.
   With one screen shown, the hidden GCU's draw commands are skipped (`fb_gcu` skip, HACKS);
   `sim/gcu_tb +skip` on `kbm-vram9200`: 10,787 clocks, without it 3,004,197 and 0 pixels differ.
6. The XT446 in the core: the H8S/2655 against a MAME trace of the firmware from reset; the SWP30
   against MAME's output for a captured MIDI stream; then the area build, and the OSD choice.
7. English instructions for MAME users (to do): a C/C++ tool that writes a patched copy of kbm's or
   kbh's program CHD with the six root-directory records `fb_kbm_en` rewrites in the core
   (`scripts/gen_kbm_en.py` finds them), reading the CHD through libchdr and writing a new CHD, never
   the original. The copy's SHA1 differs from the set's, so MAME warns of wrong checksums. Done when MAME
   boots the copy and shows the English Information boxes.

Sets: all `firebeat_kbm`, BIOS `974a03.21e`; CHDs for every set on hand
(`F:/Emulation/roms/MAME CHDs/kbm`, `kbm2nd`, `kbm3rd`; kbh's in `kbm`).

| Set | Program CD | Audio CD | Init | Status |
|-|-|-|-|-|
| kbm | `gq974-ja c01` | `gq974-ja a02` | `init_kbm_jp` | |
| kbh | `gu974-ka a01` | `gu974-ka a02` | `init_kbm_overseas` | clone of kbm |
| kbm2nd | `a01 ja a01` | `a01 ja a02` | `init_kbm_jp` | |
| kbm3rd | `a12jaa01` | `a12jaa02` | `init_kbm_jp` | |

Decisions (user):

- **A. Two screens on one output (decided, user).** An OSD option: left screen, right screen, or
  both side by side once rotated. Both is stacked in the raster (512 x 768 in the game), so that the
  rotation puts them side by side (two 3:4 portraits, 3:2 overall; the driver's two screens are
  the evidence for the aspect), at twice the line rate. One screen is 3:4.
  Both is out of the OSD for now (user): one engine cannot draw both GCUs in time (step 5); the
  OSD is Left (default) or Right, on status bit 81.
- **B. The XT446 (decided, user): an OSD choice of two paths.**
  - **MT32-pi.** chan1's TX, the bytes MAME sends to `xt446 midi_w` (F:1866), goes out of the user
    port as 31250-baud MIDI to an MT32-pi, on the pin the MiSTer cores with MT32-pi support use
    (read from one of them before wiring). Its SoundFont approximates an MU100-class XG instrument
    (`docs/HACKS.md`). Step 1's MIDI capture shows what the game sends (program changes, bank
    selects, XG SysEx). The user port is free: this revision has no SNAC controller.
  - **XT446 in the core**, ported from MAME: the H8S/2655 (`h8s2655.cpp` on MAME's H8 core) running
    the 2 MB firmware `xu50710-m27c160.bin`, and the SWP30 (`swp30.cpp`, 4,158 lines: AWM2
    voices and the MEG effects DSP) on 24 MB of wave ROM (`xt446.cpp` ROM list). No RTL exists for
    either. Wave ROM and firmware (26 MB) go in SDRAM, so this path needs a 128 MB module. Area is
    the blocking unknown: the revision is at ~97% before it (Budgets), so the XT446 either fits
    after the reclaim, or is a second build of the revision with it in place of something else;
    measured by a build before it is promised. MAME flags every kbm set `MACHINE_IMPERFECT_SOUND`
    (F:2755-2758), so its output is the reference with that caveat.
- **C. Clocks (decided, user): no separate clock.** The game runs 512 x 384 in the 16.6666 MHz
  mode, as ppp (step 1); only the BIOS screens are 640 x 480 at 25.175 MHz. clk_sys 66.667 MHz
  stays the video clock: one screen clk_sys/4, both side by side (512 x 768, twice the line rate)
  clk_sys/2. The BIOS screens run at clk_sys/4 as ppp's do (`docs/HACKS.md`, the 31 kHz entry).
- **D. A MIDI keyboard and an external XG synth (approved, user).** OSD UART mode MIDI, MidiLink
  USB: the USB MIDI device's notes become key presses (`rtl/kbm_usbmidi.sv`: any channel, a
  24-note window from note 0-96 in 12s, default 60, the game's own first note; one player, or
  split with P2 the 24 notes above), and chan1's TX goes out of `UART_TXD` to the same device, for a
  keyboard with XG voices, with Local Control Off (B0 7A 00) put in between messages at the start
  and every 2 s (`rtl/kbm_midiout.sv`, bench `sim/midiout_tb`). OSD Notes to: the port (the bridge's mute bit silences arcsnd), both, or
  arcsnd only. Bench `sim/usbmidi_tb` (a 61-key keyboard's capture through a CH345
  cable: channel 1, notes 36-96, velocity 0x50, Note On 0 for off, clock and active sense).

## Memory plan (decided)

| What | Size | Where | Traffic (Phase 0) |
|---|---|---|---|
| work RAM | 32 MB | SDRAM, 133.3 MHz | PPC fills and write-backs ~0.7 MB a peak frame |
| DMA source (in work RAM) | | SDRAM | ~0.56 MB a peak frame |
| sound flash, main flash | 4 + 2 MB | SDRAM | YMZ280B reads ≤ 0.7 MB/s |
| BIOS | 512 KB | SDRAM | boot only |
| GCU VRAM | 32 MB | DDR3, during play | 196 MB/s median, 236 MB/s worst frame in play |
| RTC NVRAM, dongle | 4 KB, 200 B | block RAM | |
| caches, I 16 KB + D 8 KB | 24 KB | block RAM | |
| CD request buffers | 2 x 2 x 16 KB | block RAM | |
| line FIFO for scan-out | a few lines | block RAM | |
| state dump (diagnostic) | ~38 MB + 64 KB | DDR3 0x34000000, written only while the board is frozen for a dump | none in play |

DDR3 during play carries VRAM because no SDRAM clock the board can reach carries 236 MB/s beside
the CPU (HARDWARE_NOTES, "Memory plan inputs"). An SDRAM module of 64 MB or more is required.

## Component reuse map

| Block | Plan | Source |
|---|---|---|
| PPC403GCX | Hornet `ppc403_core.sv`, PVR parameter, vendored (`rtl/cpu/ppc403/PROVENANCE.md`) | `E:/Arcade-KonamiHornet_MiSTer` at `a29b0c6` |
| PPC caches, DMA controller | new RTL; Hornet's `hornet_icache.sv` as a start for the instruction side | `ppccom.cpp` `ppc4xx_dma_exec` |
| SDRAM, DDR3 front ends | Hornet `hornet_sdram.sv`, `hornet_ddr3.sv`; Seta's SDRAM controller copy | siblings |
| K057714 GCU | written from MAME's model | `src/mame/konami/k057714.cpp` |
| YMZ280B | written from MAME's model; the Cave ADPCM decoder as a cross-check | `src/devices/sound/ymz280b.cpp`; `MiSTer-devel/Arcade-Cave_MiSTer` `rtl/cave/` at `ee191ea` |
| ATAPI drives | written from MAME's model over hps_io's image slots | `atapihle.cpp`, `atapicdr.cpp` |
| CHD service | Main_MiSTer `support/firebeat`, run as `MiSTer_Firebeat` | `E:/Main_MiSTer-firebeat`, branch `firebeat-chd` |
| RTC65271, 29F016A, PC16552D, dongle | written from the device files and F:820-985 | `src/devices/machine/` |
| Framework | Template `sys/` | MiSTer-devel |
| Out of scope | fx68k or Musashi on the HPS, RF5C400 | the SPU families |

## Pitfalls that already bind decisions here

| Entry (LESSONS_LEARNED) | What it binds here |
|---|---|
| [KonamiHornet] posted-write queue starving another port | the SDRAM arbiter is checked by a run long enough to saturate the high-priority side |
| [KonamiHornet] a snapshot bench cannot see writes that never land | every snapshot run ends by comparing each writable memory with MAME's at a later snapshot |
| [Firebeat] pokes go between cycles | Phase 2's system bench injects state only between evaluated cycles |
| [Firebeat] MAME's trace can repeat an instruction | the comparers fold identical lines |
| Read the Fmax summary first; same commit, other seed | every build of Phase 5 |

## Open decisions (for the user)

1. **The Main_MiSTer change.** In use now as `MiSTer_Firebeat` beside the stock binary. Whether to
   offer it upstream (a pull request to MiSTer-devel/Main_MiSTer) and in what form is the user's
   call; nothing is pushed. Left for later (user).

## Decisions taken

- **ParaParaParadise first, `ppp11` the first set** (user, at research).
- **Discs are read as the console cores read them, from CHDs** (user, at research), served by a
  Main_MiSTer change used in place for this core: `MiSTer_Firebeat` beside the stock binary,
  chosen by `[Firebeat*]` / `main=MiSTer_Firebeat` in `MiSTer.ini` (user, item 2).
- **clk_sys 66.67 MHz, the PPC at enable 1** (user, after item 3).
- **Memory**: an SDRAM module of 64 MB or more at 2 x clk_sys for work RAM, flash and BIOS; the
  GCU's VRAM in DDR3 during play (user, after item 5).
- **YMZ280B written from MAME's model** (user, after item 4).
- **Phases 1-7 approved as written** (user, after Phase 0).
- **Pop'n Music next, as its own revision** (user, at the Phase 8 proposal): the 68000 as fx68k
  in the FPGA, the wave RAM in SDRAM, so Pop'n needs a 128 MB SDRAM module. ppp1mp added on the
  current revision.
- **Phase 8 approved as written** (user).
- **One .rbf per game family** (user): `Firebeat` (ParaParaParadise), `Firebeat_popn`, and a
  revision each for Beatmania III and Keyboardmania, each with only its family's boards.
  ParaParaParadise is released as `Firebeat_ppp` (user): Main takes `<rbf>X</rbf>` as any
  `Arcade-X_*.rbf`, the greatest name winning, so `<rbf>Firebeat</rbf>` loaded
  `Arcade-Firebeat_popn_*.rbf`. No released name may be another followed by `_`.
- **Board state dump for the benches** (user, for E202): from the OSD's hidden page, by hand or on
  a drive's first CHECK CONDITION. The board freezes (CPU at an instruction boundary, GCU, DMA and
  slots idle, D-cache written back), copies work RAM and flash to DDR3 0x34000000 with every
  register block in `docs/STATE.md`, and stays paused; the HPS copies that and the VRAM to a file.
  `sim/boot_tb +state=FILE` loads it. No restore on the board; restore ports exist in simulation
  only.
- **The installed flash (6 MB) and RTC NVRAM (4 KB) persist as the core's NVRAM files** through
  hps_io, so the Test-mode install runs once per set (user, with the phase approval).
- **No default NVRAM in the `.mra`** (user): the sound flash is copied from the disc by SOUND
  FLASH INIT and MAME's sets carry no NVRAM, so only the RTC's 4 KB could be embedded and the
  install would still be needed. The README documents the Test-mode install; the save on OSD
  open (`e8840bb`) keeps it to once per set.

## Standing rules

Follow MAME, including where MAME is wrong, and write down every place that is
(`docs/MAME_KLUDGES.md`). Every approximation of this core's own goes in `docs/HACKS.md` in the
commit it lands. The GCU draws into a frame buffer because the board has one (k057714.cpp:532-550).
