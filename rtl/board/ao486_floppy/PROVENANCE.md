# ao486 floppy controller provenance

`floppy.v`, an 82077-class floppy disk controller: Copyright (c) 2014 Aleksander Osman,
(c) 2020 Alexey Melnikov. BSD licence (`LICENSE`, ao486_MiSTer's; `floppy.v` is under `rtl/`).
Upstream: https://github.com/MiSTer-devel/ao486_MiSTer, `rtl/soc/floppy.v`.

bm3's FDC37C665GT floppy controller (ROADMAP Phase 10 step 9, decision H).

## Chain of custody

| Stage | What |
|-|-|
| Upstream | MiSTer-devel/ao486_MiSTer at `628ddbcb101f836812981b06367b5080161fad4f` |
| Here | copied unchanged; `floppy.v` SHA-1 1833927d6f9ead95e56306f0e3ccf7bbe99d1c59 |
| Here | `simple_fifo.v` (upstream `rtl/common/simple_fifo.v`, same commit), unchanged; SHA-1 f849fe2ea93d1bff432b5ba0bb135da4c7e09eb8 |
| Here | `floppy.v`'s local changes below |

## Interface notes

- Sectors move through `mgmt_*` and `request`, which ao486's own HPS code serves (Main_MiSTer's
  x86 support), not `hps_io`'s SD port. This core serves them from the SD port in its wrapper.
- DMA (`dma_*`) is unused here: MAME leaves the FDC37C665GT's DMA request unconnected on bm3
  (firebeat.cpp `firebeat_bm3`), so transfers are programmed I/O (`execute_ndma`).

## Local changes

Each marked `[Firebeat]`, to answer as MAME's upd765 does (MAME is the reference; the trace in
HARDWARE_NOTES "bm3's floppy in MAME", the bench `sim/floppy_tb`):

- DIR (3F7) reads the disk-change bit alone, and only with the drive's motor on (`do_dir_r`);
  upstream sets bits 6-0.
- A write to the FIFO clears the interrupt (`fifo_w`); upstream clears it only on a FIFO read, so
  the interrupt from leaving reset stayed up and the next seek's raised no new edge.
- A software reset (DOR bit 2 low, DSR bit 7) ends a command in progress: `state`,
  `execute_ndma` and `command_left` clear with it. Upstream keeps them, so a reset in the middle of
  a read leaves the controller in the read; bm3 does exactly that (HARDWARE_NOTES, "bm3's floppy in
  MAME").
- A drive's seek bit in the MSR clears once SENSE INTERRUPT's ST0 is read (MAME's MSR D1, D0, then
  80). Upstream keeps it until reset; bm3's startup check then failed with E950 on the board.
- A seek's ST0 is SE | drive without the head bit, as MAME's (upstream ORs in the head the SEEK
  named).
- A programmed-I/O transfer that runs to EOT on the last head ends as MAME's: ST0 0x40 | head |
  drive, ST1 0x80 (end of cylinder), ST2 0, C as given, H 0, R 1, N 2 (`cmd_read_write_c` holds
  the command's C). Upstream reports a normal ending at the next track.
- READ DELETED DATA (0C) without SK reads the one sector named and ends with ST0 normal, ST1 0,
  ST2 0x40 (control mark), C H R N as given: an image's sectors all carry a normal data mark, and
  that is MAME's upd765 ending. bm3 issues `CC` on cylinder 0 before saving to a disk that already
  holds its file; upstream answers it as an invalid command (ST0 0x80) and the game reports a disk
  change error.
- A read or write waits out the head load before its first data request, as MAME's upd765
  (`HEAD_LOAD`): 2 x HLT ms at 500 kbit/s (`S_HEAD_LOAD`). Upstream asks for a write's first byte at
  once; bm3 sets its transfer pointer only after sending the command, so its ISR filled the first
  sector from the previous transfer's pointer and every sector landed one LBA late.
