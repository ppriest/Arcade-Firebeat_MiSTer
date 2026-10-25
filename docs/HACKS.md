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
| Pixel clock 16.667 MHz against the board's 16.6666 MHz crystal | `rtl/video/fb_video_timing.sv` (a pixel every fourth clk_sys) | clk_sys is 66.667 MHz (ROADMAP, Clocks); the exact crystal needs a fractional enable that breaks direct video | none wanted: 4 ppm, 58.4877 against 58.4875 Hz | arithmetic | visible (in principle) |
| CRTC fixed at mode 1 | `rtl/video/fb_video_timing.sv` parameters | Phase 1 stub; the GCU's registers 0x00-0x08 are not decoded yet | Phase 4: the CRTC registers | k057714.cpp device_reset table | visible for any other mode |
| PC16552D as registers only: nothing sent or received, LSR always 0x60, MSR 0 | `rtl/board/fb_pc16552.sv` | ppp uses the network UART only to set it up and read it back (MAME's boot capture); its interrupt lines are unconnected (F:773-775) | the NS16550 transmitter and receiver, if a set uses the network port | sim/boot_tb DUART streams | latent |
| YMZ280B status reads 0 and no voice plays | `rtl/board/fb_ymz_shell.sv` | Phase 2 shell | Phase 5, the YMZ280B | — | visible |
| GCU commands are collected, not drawn | `rtl/board/fb_gcu_shell.sv` (cmd_v) | Phase 2 shell | Phase 3, the GCU | — | visible |
| Intel-style flash commands (20 D0 block erase, 60 master lock) unsupported | `rtl/board/fb_flash.sv` (`bad`) | MAME's paths for this part go through Intel states it does not mean to support (intelfsh.cpp CLEARPART1) | — | — | latent |
| The ATAPI drive produces a transfer's data while showing BSY; MAME produces it inside the command write | `rtl/board/fb_atapi.sv` | the sectors come from an hps_io slot; responses are built a byte a clock | — (a real drive is busy too; the host waits on BSY/IRQ) | sim/boot_tb | latent |
| A READ transfers at most one 2048-byte sector a DRQ | `fb_atapi.sv` (`bad`) | a two-sector buffer; firebeat sets the byte count to 0x800 | a larger buffer if a set asks for more | boot capture: byte count 0x0800 | latent |
| READ SUB-CHANNEL's index field is 1 | `fb_atapi.sv` | MAME's comes from track-index data its CHD path leaves uninitialised | a MAME capture of the game's sub-channel reads | unverified | latent |
| A plain image (no TOC block) is one data track ending at size / 2048 | `rtl/board/fb_cd_slot.sv` | only MiSTer_Firebeat's CHD serving writes the TOC block | none needed for CHDs | — | latent |
| Discs with pregaps are served by physical frame, not MAME's logical frame | Main_MiSTer `support/firebeat/firebeat.cpp` | ppp's CHDs have no pregaps (chdman info: PREGAP 0, POSTGAP 0), where the two agree | MAME's logframeofs mapping in the serving code | chd_raw_check: frames and TOC as the .bin and .cue | latent |
| An uncached access costs about 19 clocks through the bus and SDRAM's word port | `rtl/board/fb_board.sv`, `fb_cache.sv` | MAME charges memory nothing; the BIOS RAM test runs uncached and takes about twice MAME's frames | a shorter bus path (fewer registered stages, the word port's single read) | sim/boot_tb: RAM test ends at frame ~1,600 against MAME's ~800 | visible (boot time) |
| DMA controller runs only software memory-to-memory word transfers without chaining | `rtl/board/fb_ppc_dma.sv` (`bad`) | the mode ppp uses (DMACR3 0x89C00100); MAME runs buffered mode by a timer and fatal-errors on the others | the other modes, if a set in scope uses them | sim/cpu_tb windows | latent |
| The GCU's status bits 1:0 / 3:2 read 0 while a DMA transfer feeds port 0 / 1; MAME always reads 0xFFFF0005 | `rtl/board/fb_gcu_shell.sv` (0x78), `fb_board.sv` (`dma_hold` low on hardware) | MAME runs a transfer inside the DMACR write; holding the CPU for it instead costs 28% of a play frame (sim/board_tb, play window) | the real GCU's status meaning, from a board | benches hold the CPU (`dma_hold` high) and match MAME's order; with the hold, the BIOS chose port 1 where MAME's takes port 0 when the bits read busy | latent |
| Test picture and read-back checker in place of the board | `rtl/firebeat_sys.sv`, `rtl/bringup/` | Phase 1 bring-up | Phase 2 replaces them with the PPC and the GCU | sim/sys_tb | visible |

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
