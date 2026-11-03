# Firebeat core for MiSTer

A MiSTer FPGA core for Konami's Firebeat arcade hardware (MAME's `konami/firebeat.cpp`), built
with Quartus Prime 17.0.2 Lite for the DE10-nano.

**Status: ParaParaParadise and Pop'n Music boot and play on the board. Released:
`Arcade-Firebeat_20261101.rbf` (ParaParaParadise), `Arcade-Firebeat_popn_20261103.rbf` (Pop'n Music).**

## Contents

- [History](#history)
- [Games](#games)
  - [Requirements](#requirements)
  - [ParaParaParadise](#paraparaparadise)
  - [Pop'n Music](#popn-music)
  - [Not yet](#not-yet)
- [Peripherals](#peripherals)
- [Hardware](#hardware)
  - [Video timing](#video-timing)
  - [Floorplan](#floorplan)
- [Screenshots](#screenshots)
- [Status](#status)
  - [Todo](#todo)
  - [Resource usage](#resource-usage)
- [AI Attestation](#ai-attestation)
- [Verification](#verification)
- [Acknowledgements](#acknowledgements)
- [Layout](#layout)
- [License](#license)

## History

**20261103**
* Pop'n Music: `Arcade-Firebeat_popn_20261103.rbf`, popn4-8, Animelo, Animelo 2, Mickey Tunes and clones
* `Firebeat_disc_slots.zip`: every set's discs mounted ahead of time

**20261101**
* First release - ParaParaParadise and clones only
* **READ the docs**


## Games

ParaParaParadise and Pop'n Music run on two revisions of the core: `Firebeat` (the main board) and
`Firebeat_popn` (the main board plus Pop'n Music's SPU board: a 68000, an RF5C400 and a DVD drive).
Each `.mra` names its revision.

### Requirements

A 128 MB SDRAM module is required.

MAME's CHDs need `MiSTer_Firebeat`, a Main_MiSTer build with the Firebeat CHD service (branch
`firebeat-chd`). Put it at `/media/fat/MiSTer_Firebeat` and add to `MiSTer.ini`:

```
[Firebeat*]
main=MiSTer_Firebeat
```

Raw `.bin` images (from `chdman extractcd`) should work with the standard Main.

`releases/Firebeat_disc_slots.zip`, unzipped at `/media/fat`, puts every set's two discs in its OSD
slots ahead of time (`config/<set>.s0` and `.s1`, Main's remembered mounts, pointing at the folders
below), so a set boots without mounting anything. `scripts/gen_slots.py` writes it.

Every file the `.mra` names must be in the ROM zip: with one missing the core stays on a black
screen, the board held in reset, rather than boot on whatever BIOS the last set left in memory.

### ParaParaParadise

#### 1. Core and .mra

* Take the latest `Arcade-Firebeat_*.rbf` from `releases/` and put it in `_Arcade/cores`, renamed
  to drop the `Arcade-` prefix (`Arcade-Firebeat_YYYYMMDD.rbf` becomes `Firebeat_YYYYMMDD.rbf`).
  MiSTer launches the highest-sorting match for `<rbf>Firebeat</rbf>`, and a `Firebeat_*.rbf` sorts
  above every `Arcade-Firebeat_*.rbf`
* Take the `*.mra` files and the `_alternatives` folder from `releases/` and put them in `_Arcade`
  (or a subdirectory starting with an underscore, e.g. `_Arcade/_Firebeat`)

#### 2. ROMs

The MAME sets (`ppp.zip`, `ppp11.zip`, ...; merged or split) in `games/mame`.

#### 3. Discs

Each set's two discs go in a folder named after the set, under `games/`, with MAME's file names:

| Game | Folder | Program CD | Audio CD |
|-|-|-|-|
| ParaParaParadise v1.1 | `games/ppp11/` | `gc977jaa01.chd` | `gc977jaa02.chd` |
| ParaParaParadise 1st Mix Plus | `games/ppp1mp/` | `a11jaa01.chd` | `a11jaa02.chd` |
| ParaParaParadise | `games/ppp/` | `977jaa01.chd` | `977jaa02.chd` |
| ParaParaDancing | `games/ppd/` | `977kaa01.chd` | `977kaa02.chd` |

Mount both from the OSD after loading the game: **Program CD** the `...01` disc, **Audio CD** the
`...02` disc.

**ATAPI: NG, ERROR 140: ATAPI INIT ERROR** at the BIOS's check means no Program CD was
mounted: mount it, then reset (OSD, "Reset and close OSD").

e.g. for ParaParaParadise

![PXL_20261101_223430733.jpg](docs/setup/PXL_20261101_223430733.jpg)

#### 4. First boot: install from Test mode

On first boot it will stop at **E160 BACKUPRAM ERROR** and **E124 FLASH DATA ERROR**
![20261101_223513-screen.png](docs/setup/20261101_223513-screen.png)

Once, per game:


1. Press **Test** to enter Test mode.
2. **SOUND FLASH INIT** (seventh entry; Left/Right to move, Start to select)

![20261101_224003-screen.png](docs/setup/20261101_224003-screen.png)
![20261101_224009-screen.png](docs/setup/20261101_224009-screen.png)

3. **ALL FACTORY SETTINGS** (thirteenth entry), then YES.

![20261101_224022-screen.png](docs/setup/20261101_224022-screen.png)
![20261101_224027-screen.png](docs/setup/20261101_224027-screen.png)
![20261101_224032-screen.png](docs/setup/20261101_224032-screen.png)


4. Open the OSD so the NVRAM is saved ("Saving..." shows briefly; the OSD's Autosave option, on by
   default), then reset (OSD, "Reset and close OSD").

The game then boots to its warning screen and attract mode.

#### 5. Sets

Parents in `releases/`, ppp1mp (a clone of ppp) in `releases/_alternatives/_ParaParaParadise`.
ppp11 and ppp1mp have run on the board.

| Name | Year | Manufacturer | Discs | Notes |
|-|-|-|-|-|
| ParaParaParadise v1.1 (`ppp11`) | 2000 | Konami | `gc977jaa01`, `gc977jaa02` | the reference set |
| ParaParaParadise 1st Mix Plus (`ppp1mp`) | 2000 | Konami | `a11jaa01`, `a11jaa02` | dongle a bad dump in MAME |
| ParaParaParadise (`ppp`) | 2000 | Konami | `977jaa01`, `977jaa02` | program CD a bad dump in MAME |
| ParaParaDancing (`ppd`) | 2000 | Konami | `977kaa01`, `977kaa02` | program CD a bad dump in MAME; sensor bars 6-8 not mapped |

#### 6. Controls

| Input | Use |
|-|-|
| D-pad or stick left, right | menu select |
| Sensor 1-5 | the five sensor bars (hands over the bars) |
| Start | Start / OK |
| Coin, Test, Service | cabinet switches |
| Pause | suspends the CPU |

Keyboard, MAME's default keys: Left and Right on the arrows, sensors 1-5 on LCtrl LAlt Space
LShift Z, Start 1, Coin 5; F2 Test, P pause. Controllers: [Peripherals](#peripherals).

### Pop'n Music

#### 1. Core and .mra

* Take the latest `Arcade-Firebeat_popn_*.rbf` from `releases/` and put it in `_Arcade/cores`,
  renamed to drop the `Arcade-` prefix (`Arcade-Firebeat_popn_YYYYMMDD.rbf` becomes
  `Firebeat_popn_YYYYMMDD.rbf`). MiSTer launches the highest-sorting match for
  `<rbf>Firebeat_popn</rbf>`
* Take the `*.mra` files and the `_alternatives` folder from `releases/` and put them in `_Arcade`
  (or a subdirectory starting with an underscore, e.g. `_Arcade/_Firebeat`)

#### 2. ROMs

The MAME sets (`popn4.zip`, `popn8.zip`, ...; merged or split) in `games/mame`. Each set's `.mra`
also loads its RTC preset from the zip (MAME's "default unlocked RTC").

#### 3. Discs

Each set's two discs go in a folder named after the set, under `games/`, with MAME's file names:

| Game | Folder | Program CD | Data DVD |
|-|-|-|-|
| Pop'n Music 4 | `games/popn4/` | `gq986jaa01.chd` | `gq986jaa02.chd` |
| Pop'n Music 5 | `games/popn5/` | `a04jaa01.chd` | `a04jaa02.chd` |
| Pop'n Music 6 | `games/popn6/` | `gqa16jaa01.chd` | `gqa16jaa02.chd` |
| Pop'n Music 7 | `games/popn7/` | `b00jab01.chd` | `b00jaa02.chd` |
| Pop'n Music 8 | `games/popn8/` | `gqb30jaa01.chd` | `gqb30jaa02.chd` |
| Pop'n Music Animelo | `games/popnanm/` | `gq987jaa01.chd` | `gq987jaa02.chd` |
| Pop'n Music Animelo 2 (JAC) | `games/popnanm2/` | `a02jac01.chd` | `gea02jaa02.chd` |
| Pop'n Music Animelo 2 (JAA) | `games/popnanm2ja/` | `a02jaa01.chd` | `gea02jaa02.chd` |
| Pop'n Music Mickey Tunes | `games/popnmt/` | `976jaa01.chd` | `976jaa02.chd` |
| Pop'n Music Mickey Tunes! | `games/popnmt2/` | `976jba01.chd` | `976jaa02.chd` |

The license-expired clones use the folder of the set with the same discs: `popnanma` popnanm's,
`popnanm2a` popnanm2's, `popnanm2jaa` popnanm2ja's.

Mount both from the OSD after loading the game: **Program CD** the `...01` disc, **Data DVD** the
`...02` disc.

**ATAPI: NG, ERROR 140: ATAPI INIT ERROR** at the BIOS's check means no Program CD was
mounted: mount it, then reset (OSD, "Reset and close OSD").

#### 4. First boot

No install step: with the RTC preset loaded the game passes its boot check (SECURITY to FLUSH),
loads the music data from the DVD and goes to attract mode.

**RTC errors** (E165 RTC DATA ERROR, then a "system recovery mode" asking for a password): the
saved NVRAM's RTC is bad, and the NVRAM file loads after the preset and replaces it. An RTC that
was never started is ignored on load. Otherwise delete `/media/fat/config/nvram/<game>.nvm`; that
also clears the game's settings. A recovery password can be computed from the RTC's contents with
https://987123879113.github.io/firebeatrtc/.

#### 5. Sets

popn4 and popn8 have run on the board.

| Name | Year | Manufacturer | Discs | Notes |
|-|-|-|-|-|
| Pop'n Music 4 (`popn4`) | 2000 | Konami | `gq986jaa01`, `gq986jaa02` | |
| Pop'n Music 5 (`popn5`) | 2000 | Konami | `a04jaa01`, `a04jaa02` | |
| Pop'n Music 6 (`popn6`) | 2001 | Konami | `gqa16jaa01`, `gqa16jaa02` | dongle a bad dump in MAME (192 bytes) |
| Pop'n Music 7 (`popn7`) | 2001 | Konami | `b00jab01`, `b00jaa02` | |
| Pop'n Music 8 (`popn8`) | 2002 | Konami | `gqb30jaa01`, `gqb30jaa02` | |
| Pop'n Music Animelo (`popnanm`) | 2000 | Konami | `gq987jaa01`, `gq987jaa02` | |
| Pop'n Music Animelo (license expired) (`popnanma`) | 2000 | Konami | `gq987jaa01`, `gq987jaa02` | clone of popnanm |
| Pop'n Music Animelo 2 (JAC) (`popnanm2`) | 2001 | Konami | `a02jac01`, `gea02jaa02` | |
| Pop'n Music Animelo 2 (JAC, license expired) (`popnanm2a`) | 2001 | Konami | `a02jac01`, `gea02jaa02` | clone of popnanm2 |
| Pop'n Music Animelo 2 (JAA) (`popnanm2ja`) | 2001 | Konami | `a02jaa01`, `gea02jaa02` | clone of popnanm2 |
| Pop'n Music Animelo 2 (JAA, license expired) (`popnanm2jaa`) | 2001 | Konami | `a02jaa01`, `gea02jaa02` | clone of popnanm2 |
| Pop'n Music Mickey Tunes (`popnmt`) | 2000 | Konami | `976jaa01`, `976jaa02` | rental cabinet (nibble 6, init_popn_rental) |
| Pop'n Music Mickey Tunes! (`popnmt2`) | 2000 | Konami | `976jba01`, `976jaa02` | clone of popnmt; rental cabinet |

#### 6. Controls

| Input | Use |
|-|-|
| Button 1-9 | the nine buttons, left to right: White 1, Yellow 1, Green 1, Blue 1, Red, Blue 2, Green 2, Yellow 2, White 2 |
| Coin, Test, Service | cabinet switches |
| Pause | suspends the CPU |

Keyboard, MAME's default keys: buttons 1-9 on LCtrl LAlt Space LShift Z X C V B, Coin 5; F2 Test,
P pause. Controllers: [Peripherals](#peripherals).

### Not yet

| Name | Why |
|-|-|
| beatmania III and its updates | SPU board plus a hard disk and floppy |
| Keyboardmania and its updates | two GCUs on two screens, an XT446 synth |

## Peripherals

| Controller | Game | Connection | Set-up |
|-|-|-|-|
| USB pad, keyboard | both | USB | map from the OSD as for any core |
| ParaParaParadise controller (PS2) | ParaParaParadise | USB | a USB HID device, not a controller-port pad. Needs `MiSTer_Firebeat` (above), which switches it on; map its sensors to Sensor 1-5 |
| Pop'n Music controller (PlayStation) | Pop'n Music | USB adapter | map like any pad |
| Pop'n Music controller (PlayStation) | Pop'n Music | user port, SNAC adapter (PSX core wiring) | OSD **Pop'n controller** to SNAC (Firebeat_popn only). Fixed map below; Select is Coin |

The SNAC button map, from one published source and not yet checked on the board
(`docs/HARDWARE_NOTES.md`, "Home controllers"); the game's Test mode input screen is the check:

| Button | 1 | 2 | 3 | 4 | 5 | 6 | 7 | 8 | 9 |
|-|-|-|-|-|-|-|-|-|-|
| Colour | White | Yellow | Green | Blue | Red | Blue | Green | Yellow | White |
| Pad button | Triangle | Circle | R1 | Cross | L1 | Square | R2 | Up | L2 |

## Hardware

| Chip | Function | Status |
|-|-|-|
| PPC403GCX, 66 MHz | main CPU | Hornet core's `ppc403_core`, vendored; caches (I 16 KB, D 8 KB write-back) and DMA channel 3 written here; matches MAME over 2,000,000 instructions (`sim/cpu_tb`) |
| K057714 GCU | blitter, display lists, four display contexts, CRTC; 32 MB VRAM in DDR3 | written from MAME's model; VRAM and frames equal to MAME's on the captured windows (`sim/gcu_tb`, `sim/disp_tb`) |
| YMZ280B | 8-voice ADPCM/PCM from the sound flash | written from MAME's model; bench against a MAME capture |
| ATA, two CD-ROM drives | program CD and audio CD with CD audio | ATAPI written from MAME's model, over hps_io's image slots |
| 3 x 29F016A flash | program and samples, written by the game's install | written from MAME's model; SOUND FLASH INIT equal to MAME's (`sim/boot_tb`) |
| RTC65271 | clock and 4 KB NVRAM | written from MAME's model |
| PC16552D | network UART, unused by these sets | registers only (`docs/HACKS.md`) |
| DS1991 dongle | serial, mode, licence | written from `firebeat.cpp` |

### Video timing

These run at 24kHz - so don't expect an output on your 15kHz display...

512 x 384 visible of 685 x 416, pixel clock 16.667 MHz (`clk_sys` / 4): 24.33 kHz lines, 58.49 Hz
frames. The game switches the GCU to this mode (`firebeat.cpp` `control_w`); before that the
power-on mode is 640 x 480 of 800 x 525. MAME's `set_raw` declares 640 x 480 at 25.175 MHz,
59.94 Hz, which ParaParaParadise does not use. The board's 16.6666 MHz crystal is approximated by
`clk_sys` / 4, 4 ppm off (`docs/HACKS.md`).

### Floorplan

Where the logic sits on the Cyclone V, read from the compiled design with
`scripts/floorplan.py` (blocks defined in `scripts/floorplan.json`). One cell per LAB, M10K or DSP
site, coloured by the block owning most of it, brighter when fuller. The thin columns are M10K and
DSP; the empty area at the top right is the HPS; grey is the MiSTer framework. LUT counts are
combinational cells, two per ALM.

Not generated yet; it comes with the first release.

## Screenshots

### ParaParaParadise v1.1

![ppp11 title](docs/screenshots/phase3_ppp11_title.png)

### Development builds

`python scripts/build_staged.py`, then `python scripts/deploy.py` with a `mister.env` (see
`scripts/deploy.py`).

## Status

Known issues:

* **No 15 kHz output** (24 kHz analog only).
* ppd's sensor bars 6-8 are not mapped.

`docs/MAME_KLUDGES.md` lists what is taken from MAME as behaviour and what is known not to be
right. `docs/HACKS.md` lists this core's own approximations. `docs/ROADMAP.md` is the plan and its
progress; `docs/LESSONS_LEARNED.md` is what it cost.

### Todo

- [ ] Phase 6 standard features: DIPs, CRT Adjust, flip screen, audio mix
- [x] Pop'n Music release (`Firebeat_popn`)
- [ ] Release: floorplan, Downloader database

### Resource usage

`Firebeat` revision at `a928331` (the 20261101 release), fitter seed 2, on the DE10-nano's Cyclone V
5CSEBA6, speed grade 7, every clock positive (`clk_sys` +0.499 ns, SDRAM +0.617 ns, HDMI +0.269 ns):

| resource | used | available |
| --- | --- | --- |
| Logic (ALMs) | 36,769 | 41,910 |
| Block memory bits | 1,170,720 | 5,662,720 |
| RAM blocks | 184 | 553 |
| DSP blocks | 66 | 112 |
| PLLs | 3 | 6 |

Logic is the one to watch: 88% of ALMs; the build before it missed timing at four seeds.

`Firebeat_popn` revision at `f10aed3` (the 20261103 release), fitter seed 7, every clock positive
(`clk_sys` +0.848 ns, SDRAM +0.069 ns, HDMI +0.249 ns; hold +0.205 ns at worst):

| resource | used | available |
| --- | --- | --- |
| Logic (ALMs) | 37,736 | 41,910 |
| Block memory bits | 3,162,080 | 5,662,720 |
| RAM blocks | 440 | 553 |
| DSP blocks | 54 | 112 |
| PLLs | 3 | 6 |

90% of ALMs; placement is seed-sensitive at this fill (bd672b8 at seed 5 missed HDMI by
0.146 ns).

## AI Attestation

This core is being developed with heavy use of a frontier coding assistant.

## Verification

Not PCB-validated. MAME is the accuracy reference, with its own acknowledged uncertainties noted
where they matter.

* CPU and caches: 2,000,000 instructions of ppp11's play loop and 1,777,257 of its loading loop
  equal to MAME's (`sim/cpu_tb`).
* Board bus: 302,908 device accesses in MAME's order (`sim/board_tb`).
* Boot from power-on: 6,000 MAME frames, every ATA data word (7,098,647) equal to MAME's
  (`sim/boot_tb`).
* Flash install: 15,244,959 flash writes in MAME's order, the three chips equal at the end.
* GCU: VRAM 0 pixels differing on the attract and play windows (`sim/gcu_tb`); the shown frame
  equal to MAME's `screen_out` (`sim/disp_tb`).

## Acknowledgements

- **Sorgelig** and the **MiSTer-devel team** for the
  [Template_MiSTer](https://github.com/MiSTer-devel/Template_MiSTer) framework.
- The **MAMEdev team** — Ville Linde and the contributors to `firebeat.cpp`, `k057714.cpp` and the
  device files — for the emulation that is this core's specification.
- The Konami Hornet core's PPC403 (`rtl/cpu/ppc403/PROVENANCE.md`).

## Layout

Standard [Template_MiSTer](https://github.com/MiSTer-devel/Template_MiSTer) structure:

| path | contents |
| - | - |
| `sys` | MiSTer framework, vendored from the template, never edited |
| `rtl` | core source; vendored modules carry a `PROVENANCE.md` |
| `releases` | `.rbf` and `.mra` files; clones in `_alternatives`, work in progress in `_dev` |
| `docs` | roadmap, workflow, release process, kludges, hacks, lessons |
| `sim` | ModelSim and Verilator testbenches |
| `scripts` | build, deploy, capture and verification tooling |
| `debug` | reference captures from MAME used as ground truth (gitignored) |
| `roms` | your own MAME sets (gitignored, never committed) |

## License

GPL-3.0 (see `LICENSE`). Imported components keep their own licences; every modified vendored
file states the change in its header.

Game ROMs contain copyrighted material and are not included. Obtaining them is your
responsibility.
