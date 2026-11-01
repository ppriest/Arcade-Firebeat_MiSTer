# The field tables for this core's ISSP probes, read by the MCP's read_issp.tcl and
# probe_sequence; moved from scripts/read_issp.tcl. Keep them in step with the probe
# bus the top-level .sv builds.
set fields_F {
    {frames           0  15 dec}
    {frame_50m       16  39 dec}
    {dl_kb           40  55 dec}
    {scan_late       56  71 dec}
    {ioctl_download  72  72 bit}
    {chk_busy        73  73 bit}
    {pat_done        74  74 bit}
    {pll_locked      75  75 bit}
    {cabinet         76  79 hex}
    {idx1_wr         80  87 dec}
    {dl_idx          88  91 dec}
}

set fields_M {
    {chk_sum          0  31 hex}
    {chk_lines       32  54 dec}
    {chk_lat_sum     55  86 dec}
    {chk_lat_max     87  94 dec}
    {brd_pc          95 126 hex}
    {brd_bad        127 127 bit}
    {brd_reset      128 128 bit}
}

set fields_F_cd {
    {frames           0  15 dec}
    {clk_mhz         16  23 dec}
}

set fields_slot {
    {requests         0  31 dec}
    {words           32  63 dec}
    {run_clocks      64  95 dec}
    {latency_sum     96 127 dec}
    {latency_max    128 159 dec}
    {checksum       160 191 hex}
    {image_blocks   192 223 dec}
    {have_image     224 224 bit}
}

# Instances A and B share the slot table.
set fields_A $fields_slot
set fields_B $fields_slot

# Instance F on a build with the 24-bit probe bus.
set fields_F_w24 $fields_F_cd
