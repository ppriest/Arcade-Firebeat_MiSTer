# MAME kludges this core reproduces

This project follows MAME, including where MAME is wrong (ROADMAP, "Design decisions"), so the
software model and the RTL reproduce MAME's guesses on purpose. This file lists each one that
touches an in-scope set: where it is in MAME, what the core does, and what would settle the real
behaviour.

It also records where a vendored, silicon-derived module disagrees with MAME and the module was
kept.

This core's own approximations are not here; they are in `HACKS.md`.

Source references are to `E:/MAME-Checkouts/mame-firebeat/src/mame/konami/firebeat.cpp` unless named, in the
`firebeat-meas` worktree of upstream `64475499d46` (mame0289-1524; `mister.env`).

**Core column:** *copies* MAME; *differs* (and why); *n/a* (not in the core's scope);
*not checked*.

Every ParaParaParadise set (ppp, ppd, ppp11, ppp1mp) is MACHINE_IMPERFECT_SOUND, so MAME's sound is
not a reference for the sound path's fidelity, only for its interface and timing.

## CPU and timing

| Kludge | MAME | Core | Would settle it |
|---|---|---|---|
| No caches: the 403GCX's I 16 KB / D 8 KB caches are not modelled and the cache instructions are no-ops | `ppccom.cpp` (no cache state); `ppcdrc.cpp` dcbf/dcbst/dcbi/icbi/dccci/iccci generate nothing | differs: the caches exist and the instructions act on them, `rtl/board/fb_cache.sv`; MAME's memory is the core's with every cache empty, which is how the benches start | — (the game's own flushes make the two agree: sim/cpu_tb matches MAME on both windows, and fails with dcbf disabled) |
| dcbz clears 32 bytes (`m_cache_line_size = 32`) | `ppccom.cpp:715` | copies, `ppc403_core.sv` M_DCBZ (the 403GCX's line is 16 bytes) | — (ppp executes no dcbz in either window) |
| No watchdog: TCR WRC never resets the CPU | `ppccom.cpp` (TCR WRC kept, nothing acts on it) | differs: `ppc403_core.sv` sets TSR ENW, then WIS, then resets the board (WRC != 0) on the watchdog period's rising edges, as the 403GCX manual, for the short periods only (WP 0, 1; HACKS.md); `firebeat_sys.sv` holds the board in reset 32 clocks. Keyboardmania leaves Test by setting WRC=3 and spinning (game code 0x800BB0B0, 0x800BB128); MAME hangs there | — |
| The serial port's interrupt lines change only when `ppc4xx_spu_update_irq_states` runs (each character period, a line-status or command write), not when the buffer is read or written: after the receive handler reads the byte, the BIOS's EXISR clear brings SPUR back and the handler runs again, clearing the line status | `ppccom.cpp:3150-3175, 3289, 3304-3335` | copies, `rtl/board/fb_spu.sv` (`upd`); without it the board's dongle check fails (boot_tb, SPU_W entry 45, MAME frame 2020) | The 403GCX's SPU interrupt on hardware: a probe of EXISR after a buffer read |

## Inputs

| Kludge | MAME | Core | Would settle it |
|---|---|---|---|
| The MIDI keyboards' ring buffer advances its index before writing and sends before advancing, so each byte goes out one push late, the first a stale 0x00 | `konami/midikbd.cpp` push_tx, tra_complete | copies, `rtl/board/fb_midi_kbd.sv` | A real keyboard's MIDI output on a logic analyser |
| The NS16550's FIFO timeout fires 1/(32 x baud) after a byte arrives or is read (1 us at 31250 baud), not after four character times | `machine/ins8250.h:129` set_timer | copies, `rtl/board/fb_ns16550.sv` (`tmo`, dl/2 24 MHz clocks) | The PC16552D datasheet's four-character timeout |
| The NS16550's transmit FIFO indices are 4 bits, so 16 bytes queued behind a busy shift register read as an empty FIFO: they are lost and THRE never returns | `machine/ins8250.cpp:754` push_tx, `:549` tra_complete | differs: `rtl/board/fb_ns16550.sv` `thead`/`ttail` have a fifth bit. kbm queues 16 on the board and its MIDI out stopped at byte 315 (state dump `debug/midi/kbm-stall-regs.bin`: FIFO "empty", LSR 40, all 16 bytes still in it); MAME's run never queues 16 | � (the datasheet's FIFO holds 16) |
| Each channel's interrupt callback acts on every update, not on changes: an update with the line low clears IRQ1 even while the other channel's interrupt is pending, and one that asserts and clears inside a register read latches an edge-mode EXISR bit | firebeat.cpp:1903-1925, `ins8250.cpp` update_interrupt | copies, `rtl/board/fb_board.sv` (`xirq1`, `xirq1_rise`), `ext_rise` into `ppc403_core.sv` | The extend board's IRQ1 logic on the board (a probe of EXISR across a MIDI burst) |

Sound and Protection: no entries yet.

<!-- Examples of the shape, from sibling cores:
| "Tokkae shadow masking (INACCURATE)" | `konamigx_v.cpp`, primodes 4 and 5: a shadow's priority is raised to the highest priority of a layer that SHD_ON excludes | copies, `mixer_shadow_setup` | The K055555 SHD_ON behaviour on hardware (MAME calls it a HACK) |
| Unhandled priority mask 0xc0: MAME draws `machine().rand()` pixels and pops a message | `ms32_v.cpp:522-526` | differs: not reproduced | — |
| Watchdog not implemented | `jaleco_ms32_sysctrl.cpp:104` | copies (ignored) | — |
| Equal z-code tie-break | No silicon source found; MAME draws back to front and skips when the stored z is lower | copies: the line buffer writes when (z, priority) is strictly lower, in RAM order | A PCB capture of two overlapping equal-z sprites |
-->

## Video (K057714 GCU)

Source references are `k057714.cpp` unless another file is named.

| Kludge | MAME | Core | Would settle it |
|---|---|---|---|
| `draw_frame()` clips a context with `if (y + height > cliprect.bottom()) height = cliprect.bottom() - y;` and then draws `j <= height` rows, so a context at y = 0 draws all `height + 1` rows while one at y > 0 loses its last row | G:508-519 | copies: `fb_gcu_disp` draws rows y .. min(y + h + 1, bottom) and the same for columns (sim/disp_tb random cases against `gcu_model.py`; no in-scope game offsets a context yet) | An RGB capture of a set that offsets a context, or of the last row of a partly off-screen one |
| Inverse transparency is inferred, not modelled: `(m_reg_6c & 0xf) != 0 && m_reg_6c != 0xfff`, with the comment "most likely wrong, inverse transparency is only used by kbm" | G:612-617 | copies | kbm's use of register 0x6C on hardware (the register is in no set's documentation) |
| The display composition never blends: `draw_frame()` scales each pixel by alpha1 and overwrites the destination, whatever the blend mode, and blend mode 3 is not special-cased (alpha1 stays `(alpha >> 7) & 0x1f`) | G:493-537 | copies: `fb_gcu_disp` composes the four contexts in layer order with the same per-context scaling |
| Blend mode 2's factor is `(alpha2 * 16) / alpha1`, a division by zero when alpha1 is 0 | G:497-500 | differs: the factor is 0 (the context draws black), as `gcu_model.py` | A mode 2 context with alpha1 0 on hardware | A capture of a mode 3 or mode 1 context over another one, which would show whether the hardware blends |
| Commands complete inside the write: no blitter time, no busy bit, and status 0x78 always reads `FFFF0005` | G:377-440, 185-187 | differs: the core's command engine takes DDR3 time behind a queue, and a port write waits while the queue is full (HACKS.md); the status reads as MAME's, with no busy bit | The GCU's status register on hardware while a large blit runs |
| kbm's second GCU gets no vblank: upstream wires `rscreen`'s vblank to nothing (the measurement branch adds `stats_vblank_w`, counters only), so `gcu_sub` never raises its IRQ | F:1836-1841 | copies: `u_gcu2`'s vblank is 0 (`fb_board.sv`) | Whether the board's second GCU interrupts at all, and on which line |
| Both GCUs' IRQ callbacks drive IRQ0 through `gcu_interrupt`, so the last event wins: `gcu_sub`'s IRQ-control write with bit 16 clear (kbm's boot writes 0x110 `00000000`) clears an IRQ0 the main GCU raised | F:1157, 1832, 1841 | copies: `u_gcu2`'s `irq_drop` clears `u_gcu`'s `irq` | The board's IRQ0 wiring for two GCUs (an OR would not drop it) |
| The VRAM read window does not advance: reading 0x80-0xFC returns `m_vram[m_vram_read_addr + offset - 0x20]` every time, so the CPU must rewrite 0x5C per address | G:171-181 | copies | The read pointer's increment on hardware (two reads of 0x80 without a 0x5C write) |
| An object's destination size is `(((w * 65536) / scale) * 64) / 65536` in `int`: a quotient of 2^25 or more (a 512-pixel width at x scale 1, or a 512-row height at y scale 1 or 1024 rows at 2) overflows negative, and the object draws nothing | G:699-700 | copies (`fb_gcu` S_OD2) | A blit at scale 64x or more on hardware |
| `draw()` composes from VRAM at screen update, so a frame's content is whatever the CPU left at the start of that frame: there is no blitter/scan-out overlap to model | G:532-550 | differs: the core scans VRAM out a line at a time, with the contexts latched before line 0 (HACKS.md), so the image matches when the frame's commands have finished | - (HARDWARE_NOTES "GCU reference capture": both captured ends are bit-exact) |

## Vendored modules that disagree with MAME

None yet. The vendored parts (Hornet's `ppc403_core.sv`, `hornet_sdram.sv` and `hornet_ddr3.sv`;
ROADMAP, "Component reuse map") agree with MAME where the benches compare them. Where this core's
own RTL goes beyond MAME's model, that difference is the caches' row above or in `HACKS.md` (the
DMA controller, the GCU's status bits).
