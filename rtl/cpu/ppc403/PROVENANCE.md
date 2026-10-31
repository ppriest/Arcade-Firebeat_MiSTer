# rtl/cpu/ppc403

| File | From | Licence | Local changes |
|---|---|---|---|
| `ppc403_core.sv` | `Arcade-KonamiHornet_MiSTer` `rtl/cpu/ppc403/ppc403_core.sv` at `a29b0c6` (same author; written from MAME's PowerPC model) | GPL-3.0-or-later (file header) | `PVR` parameter in place of the 403GA constant at the `mfspr` of SPR 0x11F; header line names the GCX; `[Firebeat]`: bit 31 of the fetch and data addresses out (`i_a31`, `d_a31`), the line cache instructions (dcbf, dcbst, dcbi, dccci, icbi, iccci) as one-access requests with `d_cop` instead of no-ops, DCWR (SPR 954) held, ICCR/DCCR/DCWR out to the caches and loadable (state codes 55-57); state codes 58-62 (PIT reload, SRR2, SRR3, ESR, DEAR) loadable and 37-62 readable on `dbg_val` (37 the executing PC), for the state dump; the next head's operands read for both the popped and the unpopped head (register-file ports 5-7) and chosen by the pop, so that the data cache's ack does not reach the read addresses (timing; cycle-identical on cpu_tb's two windows) |
| `ppc403_core_upstream_reference.sv` | the same file, unmodified | GPL-3.0-or-later | none: the diff base |
| `sharc2_lutram.sv` | `Arcade-KonamiHornet_MiSTer` `rtl/cpu/sharc2/sharc2_lutram.sv` at `115acab` | GPL-3.0-or-later | none |

Verification carried by the source: 2,000,000 instructions of gradius4 game code agree with MAME
in PC and 37 registers (Hornet `docs/ROADMAP.md`, "Progress"). Firebeat instantiates it with
`PVR = 32'h0020_1400`.
