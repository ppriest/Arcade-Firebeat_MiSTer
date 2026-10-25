# MAME kludges this core reproduces

This project follows MAME, including where MAME is wrong (ROADMAP, "Design decisions"), so the
software model and the RTL reproduce MAME's guesses on purpose. This file lists each one that
touches an in-scope set: where it is in MAME, what the core does, and what would settle the real
behaviour.

It also records where a vendored, silicon-derived module disagrees with MAME and the module was
kept (ROADMAP, "Where a vendored module and MAME disagree").

This core's own approximations are not here; they are in `HACKS.md`.

Source references are to `{{MAME_DRIVER_DIR}}/{{DRIVER_FILE}}` unless named. MAME commit:
`{{MAME_COMMIT}}`.

**Core column:** *copies* MAME; *differs* (and why); *n/a* (not in the core's scope);
*not checked*.

{{MAME_MACHINE_FLAGS_ONE_LINE}}
<!-- e.g. "Every set is MACHINE_IMPERFECT_GRAPHICS." -->

## {{SUBSYSTEM}}

<!-- One section per subsystem: CPU and timing, Video, Sound, Protection, Inputs. -->

| Kludge | MAME | Core | Would settle it |
|---|---|---|---|
| No caches: the 403GCX's I 16 KB / D 8 KB caches are not modelled and the cache instructions are no-ops | `ppccom.cpp` (no cache state); `ppcdrc.cpp` dcbf/dcbst/dcbi/icbi/dccci/iccci generate nothing | differs: the caches exist and the instructions act on them, `rtl/board/fb_cache.sv`; MAME's memory is the core's with every cache empty, which is how the benches start | — (the game's own flushes make the two agree: sim/cpu_tb matches MAME on both windows, and fails with dcbf disabled) |
| dcbz clears 32 bytes (`m_cache_line_size = 32`) | `ppccom.cpp:715` | copies, `ppc403_core.sv` M_DCBZ (the 403GCX's line is 16 bytes) | — (ppp executes no dcbz in either window) |
| The serial port's interrupt lines change only when `ppc4xx_spu_update_irq_states` runs (each character period, a line-status or command write), not when the buffer is read or written: after the receive handler reads the byte, the BIOS's EXISR clear brings SPUR back and the handler runs again, clearing the line status | `ppccom.cpp:3150-3175, 3289, 3304-3335` | copies, `rtl/board/fb_spu.sv` (`upd`); without it the board's dongle check fails (boot_tb, SPU_W entry 45, MAME frame 2020) | The 403GCX's SPU interrupt on hardware: a probe of EXISR after a buffer read |

<!-- Examples of the shape, from sibling cores:
| "Tokkae shadow masking (INACCURATE)" | `konamigx_v.cpp`, primodes 4 and 5: a shadow's priority is raised to the highest priority of a layer that SHD_ON excludes | copies, `mixer_shadow_setup` | The K055555 SHD_ON behaviour on hardware (MAME calls it a HACK) |
| Unhandled priority mask 0xc0: MAME draws `machine().rand()` pixels and pops a message | `ms32_v.cpp:522-526` | differs: not reproduced | — |
| Watchdog not implemented | `jaleco_ms32_sysctrl.cpp:104` | copies (ignored) | — |
| Equal z-code tie-break | No silicon source found; MAME draws back to front and skips when the stored z is lower | copies: the line buffer writes when (z, priority) is strictly lower, in RAM order | A PCB capture of two overlapping equal-z sprites |
-->

## Vendored modules that disagree with MAME

| Module | MAME says | The module does | Kept because | Would settle it |
|---|---|---|---|---|
| `{{module}}` | {{MAME behaviour, file:line}} | {{module behaviour, file:line}} | {{silicon-derived / upstream bench / measured}} | {{what would show which describes the chip}} |
