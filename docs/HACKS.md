# Hacks, approximations and workarounds in this core

Everything in this core's own RTL, scripts or `.mra` layout that is known not to be what the
hardware does: a stand-in, a shortcut, a value chosen to make something work, a workaround for a
tool. Each entry is added in the commit that introduces the hack and removed in the commit that
removes it.

This is not `MAME_KLUDGES.md`. That file lists MAME's own guesses that the core reproduces on
purpose because MAME is the reference. This file lists what is ours.

Rules:

- An entry cites `file:line` (or a module and signal name if the line moves often), and the
  evidence column says what was measured, or "unverified".
- "What would make it correct" names the work, not "fix later".
- A hack whose entry is missing is a bug. A hack whose entry is stale is worse: update it in the
  same commit as the code.
- Severity is what a player or a verifier would see: **visible** (wrong pixels, wrong sound, wrong
  timing a game can hit), **latent** (wrong only for input no in-scope set produces), **tooling**
  (affects the build or the bench, not the bitstream).

| What | Where | Why it is a hack | What would make it correct | Evidence | Severity |
|---|---|---|---|---|---|
| Pixel clock 16.667 MHz against the board's 16.6666 MHz crystal | `rtl/video/fb_gcu_disp.sv` (a pixel every fourth clk_sys) | clk_sys is 66.667 MHz (ROADMAP, Clocks); the exact crystal needs a fractional enable that breaks direct video | none wanted: 4 ppm, 58.4877 against 58.4875 Hz | arithmetic | visible (in principle) |
| The 31 kHz clock (25.175 MHz, control bit 0 clear, F:1046) is not followed: the pixel clock stays clk_sys / 4 | `rtl/video/fb_gcu_disp.sv` (`div`) | 25.175 MHz is no integer division of 66.667 MHz; ppp runs in the 24 kHz mode (HARDWARE_NOTES). Until the game writes the CRTC, device_reset's mode 0 (800 x 525) runs at 39.7 Hz where MAME's runs at 59.94 Hz | a second video clock for the 31 kHz sets (bm3) | k057714.cpp device_reset table; firebeat.cpp control_w | latent |
| PC16552D as registers only: nothing sent or received, LSR always 0x60, MSR 0 | `rtl/board/fb_pc16552.sv` | ppp uses the network UART only to set it up and read it back (MAME's boot capture); its interrupt lines are unconnected (F:773-775) | the NS16550 transmitter and receiver, if a set uses the network port | sim/boot_tb DUART streams | latent |
| A YMZ280B voice decodes each sample when it is needed; MAME decodes a stream update's worth ahead, so its status bit is set a sample or more before the output reaches the stop address, and its zero-delay timer makes the bit readable from the next read on | `rtl/board/fb_ymz280b.sv` | no stream updates in hardware | none planned: the game polls once a frame | sim/ymz_tb: 28 of MAME's 38 nonzero status reads match; the other 10 read the bit one poll (a frame) before MAME | visible (status a frame early) |
| After a YMZ280B voice reaches its stop address its last sample ramps by 15/16 a sample until 0; MAME ramps only to the end of that stream update and gives zeros after | `rtl/board/fb_ymz280b.sv` (`decaying`) | MAME's ramp length depends on its update chunk | none planned: the ramp is under 2 ms | arithmetic: 32767 * (15/16)^n < 1 at n = 161 (1.8 ms at 88.2 kHz) | visible (in principle) |
| CD audio is silent until a frame reaches the slot's ring; MAME's cdda reads the CHD with no delay | `rtl/board/fb_cd_slot.sv` (`tag_ok`) | the frames come from the HPS through hps_io | a prefetch on PLAY AUDIO's command phase, if the start is audibly late | sim/cdaudio_tb: 4 silent samples with its server; on the board unmeasured | visible (start latency) |
| CD audio volume is sample * vol >>> 9; MAME's is sample * 0.5 * vol / 255 | `rtl/board/fb_cd_slot.sv` | a shift for / 510 | none planned: 0.4% low | arithmetic | visible (in principle) |
| Audio is muted while the core is paused; the YMZ280B and the CD keep running | `Firebeat.sv` (`AUDIO_L`) | Pause holds the CPU only | none planned | — | latent |
| GCU commands run behind a 32-entry queue, in DDR3 time; MAME runs each inside its register write | `rtl/board/fb_gcu.sv` (`qm`), `fb_gcu_shell.sv` (a port write waits while the queue is full; a VRAM read waits for it to drain) | the real blitter's speed and FIFO depth are not in MAME | the GCU's FIFO depth and blit rate from a board | sim/gcu_tb play window: 47.8% of its 8 frames, 49.8% with scan-out, 57.7% at DDR3 latency 40 and 20% busy; sim/board_tb stage2 work per frame unchanged (1,068,772 / 1,044,196 clocks at lat 13) | latent |
| An object reads each source row whole before writing that row; MAME reads it a pixel at a time | `rtl/board/fb_gcu.sv` (SB) | four pixels a clock from a row buffer | none planned: differs only where a row's destination overlaps its own source row | unverified whether any in-scope set blits a row onto itself; scripts/gcu_random.py models the core's order | latent |
| The display latches the contexts, layer select and 0x6C as line 0 is built, and reads VRAM live through the frame; MAME composes the whole screen from VRAM and registers at vblank's start | `rtl/video/fb_gcu_disp.sv` (`F_IDLE`, `pn == 0`) | no frame buffer copy; latching at vblank's start would scan a buffer the game draws into after its vblank IRQ swaps the bases (ppp writes 0x40/0x44 first in each frame's writes, debug/ppp11-vram21400/gcu_writes.txt) | none planned: the core shows a frame one frame before MAME does, and the same frames | unverified on the board; sim/disp_tb matches MAME's screens for static registers | visible (one frame earlier than MAME) |
| VRAM is not cleared at reset; MAME's device_reset clears it (G:128) | `rtl/firebeat_sys.sv` | 32 MB of DDR3 writes | a clearing pass after reset, if a set shows what an earlier core left there | unverified | latent |
| Display lists nested more than 8 deep below the first are skipped; MAME recurses without a bound | `rtl/board/fb_gcu.sv` (`STK`) | a fixed stack | a deeper stack, if a set nests further | ppp's play window nests 1 deep (HARDWARE_NOTES) | latent |
| Intel-style flash commands (20 D0 block erase, 60 master lock) unsupported | `rtl/board/fb_flash.sv` (`bad`) | MAME's paths for this part go through Intel states it does not mean to support (intelfsh.cpp CLEARPART1) | — | — | latent |
| The ATAPI drive produces a transfer's data while showing BSY; MAME produces it inside the command write | `rtl/board/fb_atapi.sv` | the sectors come from an hps_io slot; responses are built a byte a clock | — (a real drive is busy too; the host waits on BSY/IRQ) | sim/boot_tb | latent |
| A READ transfers at most one 2048-byte sector a DRQ | `fb_atapi.sv` (`bad`) | a two-sector buffer; firebeat sets the byte count to 0x800 | a larger buffer if a set asks for more | boot capture: byte count 0x0800 | latent |
| READ SUB-CHANNEL's index field is 1 | `fb_atapi.sv` | MAME's comes from track-index data its CHD path leaves uninitialised | a MAME capture of the game's sub-channel reads | unverified | latent |
| A plain image (no TOC block) is one data track ending at size / 2048 | `rtl/board/fb_cd_slot.sv` | only MiSTer_Firebeat's CHD serving writes the TOC block | none needed for CHDs | — | latent |
| Discs with pregaps are served by physical frame, not MAME's logical frame | Main_MiSTer `support/firebeat/firebeat.cpp` | ppp's CHDs have no pregaps (chdman info: PREGAP 0, POSTGAP 0), where the two agree | MAME's logframeofs mapping in the serving code | chd_raw_check: frames and TOC as the .bin and .cue | latent |
| An uncached access costs about 19 clocks through the bus and SDRAM's word port | `rtl/board/fb_board.sv`, `fb_cache.sv` | MAME charges memory nothing; the BIOS RAM test runs uncached and takes about twice MAME's frames | a shorter bus path (fewer registered stages, the word port's single read) | sim/boot_tb: RAM test ends at frame ~1,600 against MAME's ~800 | visible (boot time) |
| DMA controller runs only software memory-to-memory word transfers without chaining | `rtl/board/fb_ppc_dma.sv` (`bad`) | the mode ppp uses (DMACR3 0x89C00100); MAME runs buffered mode by a timer and fatal-errors on the others | the other modes, if a set in scope uses them | sim/cpu_tb windows | latent |
| A DMA transfer runs beside the CPU, which waits for its end only at a DMA register access (mtdcr/mfdcr); meanwhile the GCU's status bits 1:0 / 3:2 read 0 for the port it feeds. MAME runs the transfer inside the DMACR write and always reads status 0xFFFF0005 | `rtl/board/fb_board.sv` (`dma_wait`, `dma_hold` low on hardware), `fb_gcu_shell.sv` (0x78) | the CPU's work beside the transfer (the play window does nearly none: HARDWARE_NOTES "DMA beside the CPU") | the real GCU's status meaning and the 403's channel timing, from a board | without the wait, the status sent the BIOS to port 1 and it rewrote the running channel, failing its VRAM test (E121); with it, `sys_tb`'s BIOS uses port 0 only, as MAME's. A CPU store to the transfer's source in work RAM while it runs reaches the GCU, where MAME's would not | latent |
| The state dump is diagnostic only: no restore on the board; left out are the ATAPI transfer buffers (a dump during a sector transfer cannot resume), the GCU engine's origin, the display's counters, the YMZ280B's voices (a shell); the devices keep running while the CPU is stopped, so their timers move during the copy | `rtl/board/fb_dump.sv`, `fb_board` `st_d`, `scripts/st_lists.py` | the dump exists to put a board state into `sim/boot_tb` (ROADMAP decision, for E202) | the missing state above; a board-wide clock enable for the freeze; a savestate path for the restore | sim/boot_tb `+dump` | tooling |
| The Debug OSD page shows in every build | `Firebeat.sv` (`debug_hidden`, `FB_RELEASE`) | no release revision defines `FB_RELEASE` yet | define it in the release build | — | tooling |
| Test picture and read-back checker beside the board | `rtl/firebeat_sys.sv`, `rtl/bringup/` | Phase 1 bring-up, kept: with `test_pic` (the stp revision's probe F source 7) the display shows one 512 x 384 context at VRAM 0 in mode 1 instead of the registers, and the picture is written there after reset | none wanted; off in the release revision | sim/sys_tb steps 4-5 | tooling |

<!-- Examples of the shape, from sibling cores:
| Sound mailbox is a stub that answers the power-on test | `rtl/gx_snd_stub.sv` | No sound CPU yet; the stub returns the reply the test expects and a heartbeat | Phase 3: the real sound board | The game's RAM check passes with it; nothing else is exercised | visible |
| Sound-command spin of 800 CPU clocks after a latch write | `rtl/cpu/…_bus.sv:NNN` | Copies MAME's 40 us wait; the real board's mechanism is unknown | A measurement of the latch on hardware | Without it the second byte overwrote the first (commit) | latent |
| Sound CPU reset held 1,024 clocks | `rtl/….sv:NNN` | MAME's pulse is zero-length; the T80 needs to see it | The measured reset length | A PCB measurement says about one second | latent |
| Screen timing from one game used for every game | `rtl/video/…crtc.sv` | MAME declares 60 Hz with no comment; the one PCB-verified rate is used for all | Per-game timing from PCB measurement | 0.043% from the verified rate | visible |
-->

## Removed

Entries move here when the hack is gone, with the commit that removed it, so a later reader can
tell "never had it" from "had it and fixed it". Delete a row once nothing else refers to it.

| What | Removed by | Replaced with |
|---|---|---|
