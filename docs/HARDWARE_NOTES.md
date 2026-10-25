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
game's own install from the CD (below, "Flash").

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

Reference MAME `firebeat.exe` (`E:/mame-firebeat`, ROADMAP "Progress"); CHDs from
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
`E:/Main_MiSTer-firebeat`, commit `cd603ed` on upstream `8328d9f`): `support/firebeat` serves a
CD CHD mounted in a slot of a core named `Firebeat*` as the raw image `chdman extractcd` writes
(every track's 2352-byte frames back to back, CD audio byte-swapped into .bin order), through
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
row's fetch or adds to these figures, which Phase 4 measures.

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
word (`fb_ppc_dma` direct path).

| DMA | lat | Work clocks, frame 1 / frame 2 | of 1,128,205 |
|---|---|---|---|
| holding the CPU (MAME's order) | 12 | 1,366,379 / 1,341,260 | 121% / 119% |
| beside the CPU (the hardware core) | 12 | 1,059,381 / 1,035,878 | 94% / 92% |
| beside the CPU | 20 | 1,134,585 / 1,102,474 | 101% / 98% |

At latency 1 the work is 79.5% of the window's clocks per vblank: most of the cost is the core's
own CPI (2.40 at one-clock memory). The board's SDRAM fill latency on hardware is 13.2 clocks
average ("Phase 1 on the board").

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
