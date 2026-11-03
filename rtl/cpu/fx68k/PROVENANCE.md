# fx68k provenance

Cycle-accurate 68000, Copyright (c) 2018, 2021 Jorge Cwik. GPLv3 (`LICENSE`).
Upstream: https://github.com/ijor/fx68k.

The Pop'n Music SPU board's 68000 (ROADMAP Phase 8, `Firebeat_popn`).

## Chain of custody

| Stage | What |
|-|-|
| Upstream | ijor/fx68k |
| Then | `Arcade-SegaXBoard_MiSTer-1.0.0/rtl/cpu/fx68k/` |
| Then | `Arcade-Seta_MiSTer/rtl/cpu/fx68k/` |
| Then | `Arcade-KonamiGX_MiSTer/rtl/cpu/fx68k/` at `8e0fec7` |
| Here | copied from that KonamiGX tree unchanged |

`microrom.mem` and `nanorom.mem` SHA-1s: 62036424b29dfd412e7091bd1e331b14e767caa0,
a1f291b6397c7907b64141429434aabda9a0d7dc, as KonamiGX and Seta record.

## Local changes (carried from the trees above; none here)

- Seta: the two `$readmemb` paths in `fx68k.sv` are relative to the project root
  (`rtl/cpu/fx68k/microrom.mem`, `nanorom.mem`).
- KonamiGX, for Verilator: the structs `s_clks`, `s_irdecod`, `s_nanod` declared `packed`
  (Verilator refuses `Nanod`, driven by both continuous assigns and an `always_ff`, unpacked).
  Marked `[GX]`.
- KonamiGX: `stop_out`, high while IRD holds STOP (`4E72`). No logic change. Marked `[GX]`.
