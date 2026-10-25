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
| I-cache data, tags | `rtl/board/fb_cache.sv` (SB 9) `dmem`, `tmem` | 2 x 4 lanes x 32 x 512; 2 x 18 x 512 | 16 KB + 2.3 KB | yes, or flush: a dump taken with the caches written back and invalidated needs none of it |
| D-cache data, tags | `fb_cache.sv` (SB 8) | 2 x 4 lanes x 32 x 256; 2 x 19 x 256 | 8 KB + 1.2 KB | yes (dirty lines), or written back before the dump |
| RTC registers and extended RAM | `rtl/board/fb_rtc65271.sv` `regs`, `xmem` | 8 x 64; 8 x 4096 | 4.1 KB | yes; the persistent part also in the NVRAM file (MAME's .nv format) |
| DS1991 image | `rtl/board/fb_spu.sv` `dongle` | 8 x 256 | 256 | skip: the `.mra` |
| SPU registers, receive queue | `fb_spu.sv` `regs`, `rq` | 8 x 9; 8 x 16 | 25 | yes |
| DCR store | `rtl/board/fb_board.sv` `dcr_mem` | 32 x 256 | 1 KB | yes |
| GCU VRAM write queue | `rtl/board/fb_gcu_shell.sv` `q` | 55 x 64 | 440 | yes, or drained before the dump |
| YMZ280B registers | `rtl/board/fb_ymz_shell.sv` `regs` | 8 x 256 | 256 | yes |
| ATAPI drive buffers | `rtl/board/fb_atapi.sv` `b_e`, `b_o` (x 2 drives) | 8 x 2048 x 2 | 4 KB a drive | yes while a transfer is under way, else skip |
| ATAPI packet and data-out bytes | `fb_atapi.sv` `cmd`, `dout` | 8 x 12; 8 x 64 | 76 a drive | yes |
| disc TOC | `rtl/board/fb_cd_slot.sv` `t_lo`, `t_hi`, `t_fl`, `t_ct` | 48 x 128 | 768 a drive | skip: read from the slot again at mount |
| DMA source blocks | `rtl/board/fb_ppc_dma.sv` `blk`, `fb` | 256 x 3 | 96 | skip if the dump waits for the DMA to be idle |
| scan-out line buffer | `rtl/video/fb_scanout.sv` `buf_mem` | 64 x 256 | 2 KB | skip: refilled every line |

## Registers and FSMs

| What | RTL | Bits | Save? | MAME `save_item` equivalent |
|---|---|---|---|---|
| cache valid, dirty, LRU | `fb_cache.sv` `v`, `dt`, `lru` | I 1,536, D 768 | with the cache contents | none (MAME has no cache) |
| ATAPI task file, timers, sense, media change, play position | `fb_atapi.sv` (status ... a_smp) | ~400 a drive | yes | atahle/atapihle/t10mmc/cdda save_items |
| SPU registers, timer counters | `fb_spu.sv` | ~120 | yes | ppccom `m_spu` |
| flash modes, status, erase timers, the background erase | `rtl/board/fb_flash.sv` | ~180 | yes | intelfsh save_items |
| RTC index, page, update and periodic timers | `fb_rtc65271.sv` | ~110 | yes | rtc65271 save_items |
| PC16552D registers, THR-empty pending | `rtl/board/fb_pc16552.sv` | ~100 | yes | ins8250 save_items |
| GCU shell registers, ports, IRQ | `rtl/board/fb_gcu_shell.sv` | ~250 | yes | k057714 save_items |
| PPC architectural state | `ppc403_core.sv`, its dbg read and state-load ports (0-57) | | yes | `ppccom.cpp` state entries |

## Chip state

| Chip | Module | Addressable? | Tier | Note |
|---|---|---|---|---|
| | | | | |

## Deliberately skipped

| What | Why it need not be saved |
|---|---|
| | |

## Frame alignment

Restore point (normally `frame_start`), and anything whose phase must be saved with it: sprite or
tile double-buffer selection, snapshot ownership bits.
