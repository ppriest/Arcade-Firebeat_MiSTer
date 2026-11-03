# Firebeat state inventory

What a savestate or a state dump has to carry, kept current as RTL lands (the skill's
`savestates.md`). "Skip" needs a reason: a ROM table from the `.mra`, or something re-derived
every frame.

## RAMs

| Region | RTL | Width x depth | Bytes | Save? |
|---|---|---|---|---|
| work RAM | SDRAM 0x0000000 (`rtl/mister/firebeat_sdram.sv`, word and cache ports) | 16 x 16M | 32 MB | yes: the running game |
| flash x 3 | SDRAM 0x2000000 | 16 x 3M | 6 MB | in the NVRAM file; a state carries it too, the YMZ280B's samples live there |
| BIOS | SDRAM 0x2800000 | 16 x 256K | 512 KB | skip: the `.mra` |
| VRAM | DDR3 0x30000000 (`rtl/mister/hornet_ddr3.sv`) | 64 x 4M | 32 MB | yes, the frame buffers and display lists; size makes it the dump's largest part |
| I-cache data, tags | `rtl/board/fb_cache.sv` (SB 9) `dmem`, `tmem` | 2 x 16 bytes x 8 x 512; 2 x 19 x 512 | 16 KB + 2.3 KB | yes, or flush: a dump taken with the caches written back and invalidated needs none of it |
| D-cache data, tags | `fb_cache.sv` (SB 8) | 2 x 16 bytes x 8 x 256; 2 x 20 x 256 | 8 KB + 1.2 KB | yes (dirty lines), or written back before the dump |
| RTC registers and extended RAM | `rtl/board/fb_rtc65271.sv` `regs`, `xmem` | 8 x 64; 8 x 4096 | 4.1 KB | yes; the persistent part also in the NVRAM file (MAME's .nv format) |
| DS1991 image | `rtl/board/fb_spu.sv` `dongle` | 8 x 256 | 256 | skip: the `.mra` |
| SPU registers, receive queue | `fb_spu.sv` `regs`, `rq` | 8 x 9; 8 x 16 | 25 | yes |
| DCR store | `rtl/board/fb_board.sv` `u_dcr` (MLAB) | 32 x 256 | 1 KB | yes |
| GCU queue (VRAM words and commands, in order) | `rtl/board/fb_gcu.sv` `qm` | 130 x 32 | 520 | yes, or drained before the dump |
| GCU row buffers | `fb_gcu.sv` `g_sb` (4 copies), `g_dbf`, `db_be` | 64 x 256 x 4; 16 x 128 x 4; 4 x 128 | 9 KB | skip: hold one command's row; a dump waits for the engine to be idle |
| YMZ280B registers | `rtl/board/fb_ymz280b.sv` `regs` | 8 x 256 | 256 | yes |
| CD audio ring | `rtl/board/fb_cd_slot.sv` `ring`, `tag` (x 2 drives) | 16 x 8192; 4 x 33 | 16 KB a drive | skip: refilled from the slot |
| ATAPI drive buffers | `rtl/board/fb_atapi.sv` `b_e`, `b_o` (x 2 drives) | 8 x 2048 x 2 | 4 KB a drive | yes while a transfer is under way, else skip |
| ATAPI packet and data-out bytes | `fb_atapi.sv` `cmd`, `dout` | 8 x 12; 8 x 64 | 76 a drive | yes |
| disc TOC | `rtl/board/fb_cd_slot.sv` `t_lo`, `t_hi`, `t_fl`, `t_ct` | 48 x 128 | 768 a drive | skip: read from the slot again at mount |
| DMA source blocks | `rtl/board/fb_ppc_dma.sv` `blk`, `fb` | 256 x 3 | 96 | skip if the dump waits for the DMA to be idle |
| SPU RAM | `rtl/spu/fb_spu68k.sv` `ram_h`, `ram_l` | 8 x 128K x 2 | 256 KB | yes; not yet reachable from the dump |
| SPU dual-port RAM | `fb_spu68k.sv` `dp` | 8 x 1024 | 1 KB | yes; not yet reachable |
| SPU program ROM | SDRAM 0x2880000 | 16 x 256K | 512 KB | skip: the `.mra` |
| SPU wave RAM | SDRAM 0x4000000 | 16 x 16M | 32 MB | yes: loaded from the DVD by the game |
| RF5C400 channel registers and state | `rtl/spu/fb_rf5c400.sv` `r_*`, `s_mem`, `offs` | 32 x (11 x 16 + 22); 32 x 106; 32 x 16 | ~1.5 KB | yes; not yet reachable |
| display line buffer | `rtl/video/fb_gcu_disp.sv` `g_lb` | 18 x 512 x 4 | 4.5 KB | skip: rebuilt every line |

## Registers and FSMs

| What | RTL | Bits | Save? | MAME `save_item` equivalent |
|---|---|---|---|---|
| cache dirty, LRU | `fb_cache.sv` `dt`, `lru` (valid bits: in the tag RAMs, `tmem`'s top bit) | I 1,024, D 512 | with the cache contents | none (MAME has no cache) |
| ATAPI task file, timers, sense, media change, play position | `fb_atapi.sv` (status ... a_smp) | ~400 a drive | yes | atahle/atapihle/t10mmc/cdda save_items |
| SPU registers, timer counters | `fb_spu.sv` | ~120 | yes | ppccom `m_spu` |
| SPU 68000 (fx68k), mailboxes, IRQ2/6, timer, DMA address, wave bank; the SPU drive | `fb_spu68k.sv`, `firebeat_sys.sv` `g_spu` | fx68k's internal state | yes; fx68k has no state port, the dump does not reach them yet | m68000, firebeat_spu_state save_items |
| flash modes, status, erase timers, the background erase | `rtl/board/fb_flash.sv` | ~180 | yes | intelfsh save_items |
| RTC index, page, update and periodic timers | `fb_rtc65271.sv` | ~110 | yes | rtc65271 save_items |
| PC16552D registers, THR-empty pending | `rtl/board/fb_pc16552.sv` | ~100 | yes | ins8250 save_items |
| GCU shell registers, ports, IRQ; the display registers (CRTC, contexts, layer select, 0x6C) | `rtl/board/fb_gcu_shell.sv` | ~250; 640 | yes | k057714 save_items (`m_frame`, `m_display_*`, `m_layer_select`, `m_reg_6c`) |
| display timing and the frame's latched contexts | `rtl/video/fb_gcu_disp.sv` (`h`, `v`, `hlast` ... `l_fac`) | ~600 | the counters yes; the latched set is re-taken at the next frame, from the shell's registers | the screen's position (MAME's screen device) |
| GCU origin; display-list position and stack | `rtl/board/fb_gcu.sv` `org_x`, `org_y`; `depth`, `dl_wa`, `dl_cnt`, `stk_wa`, `stk_cnt` | 24; 41 + 8 x 37 | the origin yes (`m_fb_origin_x/y`, G:65-66); the list state is empty when the engine is idle | k057714 save_items |
| PPC architectural state | `ppc403_core.sv`, its dbg read and state-load ports (0-62) | | yes | `ppccom.cpp` state entries |

## Chip state

Chips with state of their own, outside the board's RAMs and register files above. Tier 1 restores
the registers and lets the game replay; Tier 2 continues bit-exactly.

| Chip | Module | Addressable? | Tier | Note |
|---|---|---|---|---|
| PPC403GCX | `rtl/cpu/ppc403/ppc403_core.sv` | yes, `dbg_sel` / `dbg_wsel` 0-62 | 2 | GPRs, CR, LR, CTR, XER, MSR, PC, SRR0/1, SPRG0-3, EXIER, EVPR, TB, TCR, TSR, EXISR, IOCR, PIT (value, reload, count), the external line state, ICCR/DCCR/DCWR, SRR2/3, ESR, DEAR. Read 37 is the executing instruction's PC, write 37 the fetch address. MAME saves the same set (`ppccom.cpp:796-826`) plus its DCR array, which is `fb_board`'s `u_dcr`. The fetch queue, the multiply/divide steppers and `xstate` are not addressable: a dump is taken with the CPU halted at an instruction boundary, PC writable only then |
| GCU (K057714) | `rtl/board/fb_gcu_shell.sv`, `rtl/board/fb_gcu.sv` | the shell's registers, both command FIFOs (4 words each), the engine's queue and origin | 1 | MAME's `save_pointer(m_vram)` is the DDR3 VRAM section; its remaining `save_item`s (`k057714.cpp:44-77`) are the shell's registers, the origin, plus the four frame descriptors, which the display adds. A dump waits for the engine to be idle (`gcu_idle`): MAME has no state inside a command. The display's line FIFO goes here when it lands |
| YMZ280B | `rtl/board/fb_ymz280b.sv` | registers only (`reg_a`) | 1 | The voices' state (`fnum` .. `cache_ok`, per voice) is in flops, not yet readable: MAME saves it (`ymz280b.cpp:565-600`, 24 fields a voice), and a restore without it re-attacks notes. Needs a read port over the voice arrays before savestates |
| ATAPI drives (x 2) | `rtl/board/fb_atapi.sv` | yes | 2 | The task file, the packet, the response and buffer pointers, the timers, the sense and the play position; MAME's `t10mmc` / `atapihle` / `cdda` save lists are the checklist |
| SDRAM controller, DDR3, scan-out, video timing | `rtl/mister/firebeat_sdram.sv`, `hornet_ddr3.sv`, `rtl/video/` | no | - | Stateless per request; the DDR3's in-flight reads (`rf`, `d_ts`, `d_bt`) carry no data a restore needs, and a dump is taken with the queues empty |

## Deliberately skipped

| What | Why it need not be saved |
|---|---|
| BIOS, dongle image | the `.mra` loads them |
| disc TOC (both drives' copies and the slot's) | re-read from the image slot at mount |
| caches and their line-fill and write-back queues (`fb_cache`) | a dump writes the data cache's dirty lines back (lines kept valid, now clean); every line is then a copy of SDRAM, and a restore starts both caches empty |
| scan-out line buffer | refilled every line from VRAM |
| DMA source blocks, the GCU's queue and row buffers, DDR3 read FIFO, SDRAM request pipeline | a dump waits for idle; nothing in them is state the next request does not re-derive |
| ATAPI transfer buffers while no transfer is under way | refilled from the slot per read |
| SNAC pad poller (`rtl/mister/psx_pad_snac.sv`) | the host's controller, not the board's; re-read at the next poll (2 ms) |
| YMZ280B sample cache (`debug/ymz_ref` is the reference) | the samples are in the flash, which is saved |

## The state dump

`rtl/board/fb_dump.sv`, from the OSD's Debug page ("Dump state / release", or "Dump on slave error":
the slave drive's first CHECK CONDITION other than UNIT ATTENTION). The board stops (`fb_board`
`halt`: the CPU at an instruction boundary, the timebase stopped, the data cache written back, the
DMA and the GCU engine idle, no slot request open), the dump is copied, and the board stays stopped
until the next press or a reset. `sim/boot_tb` `+dump=FRAME` runs the same RTL; `+state=FILE` starts
from a dump.

DDR3, little-endian 32-bit words (the HPS reads `/dev/mem` from 0x34000000 and 0x30000000):

| Offset from 0x34000000 | Size | What |
|---|---|---|
| 0x0000000 | 32 bytes | header: "FBSD" (0x46425344), the dump count since reset, VRAM's address and size, the register block's offset and size, the SDRAM block's offset and size; written last |
| 0x0001000 | 64 KB | the register block, word k at +4k (below) |
| 0x0020000 | 38 MB | SDRAM 0x0000000-0x25FFFFF (work RAM, flash), each 32-bit word as the CPU reads it |
| (0x30000000) | 32 MB | VRAM, in place |

`boot_tb` writes and reads a file of the two areas back to back: 0x34000000-0x3661FFFF, then VRAM.

Register block (`fb_board` `st_a`/`st_d`):

| Words | What |
|---|---|
| 0x0000-0x003F | `ppc403_core` state codes 0-63 (above; 63 unused) |
| 0x0100-0x01FF | ATAPI drives, drive 1 from 0x0180: `fb_atapi`'s two lists (protocol 0x00-0x3F, engine 0x40-0x7F) |
| 0x0200-0x027F | `fb_spu` |
| 0x0280-0x02BF | `fb_rtc65271`'s counters, page and index (its registers are in the NVRAM image) |
| 0x0300-0x033F | `fb_flash` |
| 0x0340-0x035F | `fb_pc16552` |
| 0x0380-0x03BF | `fb_gcu_shell` (the engine's origin is not in it) |
| 0x0400-0x04FF | `fb_ppc_dma` |
| 0x0500-0x05FF | the DCR store (`u_dcr`) |
| 0x0600-0x06FF | the YMZ280B shell's registers, read only |
| 0x1000-0x17FF | the slave drive's access log (`fb_ata`), 1024 entries of two words, a ring from power-on: word 0 [31] write, [30] cs1, [29:27] register, [25:16] repeats - 1 (saturating), [15:0] data as `fb_ata` takes it (the bus halfword byte-swapped); word 1 the time in microseconds. An access equal to the one before counts a repeat |
| 0x1800 | the number of log entries made since power-on |
| 0x2000-0x3037 | the RTC's NVRAM image (MAME's .nv format), a byte a word |

Each device's list is generated into its module by `scripts/st_lists.py` (`--check` in review):
a word a register, in the order of its always_ff block, so a dump is read with the RTL of the
same commit. The bench writes the lists back through Verilator-only write cases; the hardware
only reads them.

## Frame alignment

Restore point: the frame boundary, `frame_start` on the board and `vblank`'s rise in `sim/boot_tb`
and `sim/sys_tb`. The phase that must be saved with it:

- `control_w` bit 0 (the GCU's video mode): it selects the vblank period the board and the benches
  time their frame from, so a restore with the wrong bit lands half a frame away.
- The RTC's update-cycle divider (`fb_rtc65271` timers) and the three flash chips' erase timers
  (`fb_flash` `tmr`): a guest polling them counts real time from the restore.
- An ATAPI transfer in progress: the drive's phase, buffer pointers and the slot request in flight
  (`sd_lba`, `sd_blk_cnt`, `sd_rd`).
- The DMA's state: a transfer is a few words, and MAME runs one inside its DMACR write, so the
  benches hold the CPU (`dma_hold`) and take a dump with no transfer under way.
- The GCU's command FIFOs when a command is mid-write; the engine is drained (`gcu_idle`) first.
- The HPS time and the NVRAM upload: `firebeat_sys` takes them from `hps_io` at load, not from the
  dump.
