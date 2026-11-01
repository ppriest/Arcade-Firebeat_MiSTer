# `sdram.sv` — provenance

From `Arcade-KonamiHornet_MiSTer/rtl/mister/sdram/sdram.sv` at `54cc676`, kept unmodified as
`sdram_hornet_reference.sv` beside it; `sdram_upstream_reference.sv` is Sorgelig's original as
Hornet kept it. The chain (Hornet's PROVENANCE): Sorgelig's `sdram.v` (GPL-3.0-or-later), burst-4
reads in Psikyo, 26-bit addresses in Fuuki, the 128 MB module's second chip and port 0's double
read in KonamiGX, CAS latency 3 / tRCD 3 room and port 1's two-halfword write in Hornet.

Edits here are marked `[Firebeat]`: tRCD, CAS latency and the refresh interval are module
parameters (defaults 3, 3, 500 clocks) for the controller at 133.33 MHz; port 0's quad read
(`quad0`: READs at +0, +4, +8, +12 to one open row, the last precharging; 16 halfwords in
`dout0`..`dout0d`, 32 bytes) for the DMA's block reads; two more data registers, `dq_in2` and
`dq_in3`, between the I/O cell's `dq_in` and the read lanes, for setup at 133.33 MHz (reads two
clocks longer). `dq_out` loads every clock through one mux on a registered select, and the command
(`cmd_nx`) is decoded a clock early, so the paths to the I/O cells carry no state decode. Hornet's interval, 335
clocks a refresh alternating between the two chips (670 a chip), was set for KonamiGX's 96 MHz.

`sim/common/sdram_chip_model_128.sv` and `sdram_chip_model_wide.sv` are Hornet's command-decoding
chip models at `8ce6257`, unmodified.
