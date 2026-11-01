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
- **CRT Adjust**, HDMI scaling and crop, flip screen (ppp has no flip DIP: a fake one), audio mix;
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
YMZ280B, the second CD drive and CD audio, and the sensor bars (~6,400 ALMs at `0202c3d`:
`fb_ymz280b` 1,824, the second `fb_atapi` and `fb_cd_slot` ~4,600) and adds the SPU.

Steps, each with its bench before hardware:

1. MAME captures for popn4: PPC-side boot trace, the 68000's trace, the dual-port RAM traffic, the
   SPU ATA commands, RF5C400 register writes and output. Area and memory budgets from them.
2. The revision and the SPU skeleton: fx68k, its ROM and RAM, dual-port RAM, IRQs; the 68000's
   trace against MAME's.
3. The SPU ATA bus and the DVD slot; the wave RAM load against MAME's.
4. RF5C400; output against MAME's.
5. On the board: popn4 to its attract mode, then the other sets.

Sets: popn4 first (`gq986jaa01`, `gq986jaa02` on hand), then popn5-8, popnanm, popnanm2, popnmt.

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
