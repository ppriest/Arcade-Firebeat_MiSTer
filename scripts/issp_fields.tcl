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

# Firebeat_kbm_stp and Firebeat_bm3_stp (Firebeat.sv): K the last frame, X since source 0 of F; clocks are clk_sys's
set fields_K {
    {l_b0             0  20 dec}
    {l_b1            21  41 dec}
    {l_mw            42  62 dec}
    {l_f0            63  83 dec}
    {l_f1            84 104 dec}
    {l_h0           105 125 dec}
    {l_h1           126 146 dec}
    {l_d0           147 152 dec}
    {l_d1           153 158 dec}
    {busy_vbl       159 174 dec}
    {hold_vbl       175 190 dec}
}

set fields_X {
    {x_busy           0  20 dec}
    {x_hold          21  41 dec}
    {x_full          42  63 dec}
    {frames_held     64  79 dec}
    {y_lost          80  95 dec}
    {y_pass_max      96 107 dec}
    {y_fetch_max    108 117 dec}
    {rot_late       118 133 dec}
    {x_frames       134 149 dec}
    {scan_late      150 165 dec}
    {x_cmdw_max     166 181 dec}
    {x_cmdx         182 197 dec}
    {x_dmacmd       198 217 dec}
}

# V and E (bm3 stp, Firebeat.sv): the bottom third flashing black. v_/e_ bk0-2 black pixels in lines
# 1-160 / 161-320 / 321-480; late, lrow, runmax the display's late lines, the first late row (4095
# none), the longest run; bldmax a line build's longest clocks, rwmax its read's longest wait for the
# port; bzmax, bzn the longest DDRAM_BUSY run and its clocks; eon, eoff the rows at which the engine
# first started and last stopped (4095 none), evbl running at the frame's start; dwr the GCU's beats
# into the frame on screen, dwrow the row being built at the first, dwdst the row it wrote; base0
# context 0's base. V the last frame, then (m_) since K's source 0: frames with a late line, the most
# late lines, the longest build, wait and DDRAM_BUSY run, frames with a beat into the frame on screen.
# E the last frame whose bottom third had 16,384 black pixels more than the frame before; e_n the
# events, e_frame x_frames at it. Clocks are clk_sys's.
set fields_V {
    {v_bk2              0  16 dec}
    {v_bk1             17  33 dec}
    {v_bk0             34  50 dec}
    {v_base0           51  74 hex}
    {v_dwdst           75  84 dec}
    {v_dwrow           85  96 dec}
    {v_dwr             97 112 dec}
    {v_evbl           113 113 bit}
    {v_eoff           114 125 dec}
    {v_eon            126 137 dec}
    {v_bzn            138 158 dec}
    {v_bzmax          159 174 dec}
    {v_rwmax          175 186 dec}
    {v_bldmax         187 198 dec}
    {v_runmax         199 208 dec}
    {v_lrow           209 220 dec}
    {v_late           221 230 dec}
    {v_m_latefr       231 246 dec}
    {v_m_late         247 256 dec}
    {v_m_bld          257 268 dec}
    {v_m_rw           269 280 dec}
    {v_m_bz           281 296 dec}
    {v_m_dwrfr        297 312 dec}
}

set fields_E {
    {e_bk2              0  16 dec}
    {e_bk1             17  33 dec}
    {e_bk0             34  50 dec}
    {e_base0           51  74 hex}
    {e_dwdst           75  84 dec}
    {e_dwrow           85  96 dec}
    {e_dwr             97 112 dec}
    {e_evbl           113 113 bit}
    {e_eoff           114 125 dec}
    {e_eon            126 137 dec}
    {e_bzn            138 158 dec}
    {e_bzmax          159 174 dec}
    {e_rwmax          175 186 dec}
    {e_bldmax         187 198 dec}
    {e_runmax         199 208 dec}
    {e_lrow           209 220 dec}
    {e_late           221 230 dec}
    {e_n              231 246 dec}
    {e_frame          247 262 dec}
}

# L (bm3 stp): the floppy event log in fb_floppy; the source picks the entry, wp is the next write
set fields_L {
    {payload          0  15 hex}
    {time            16  27 dec}
    {type            28  31 dec}
    {wp              32  41 dec}
}

# W: the watchdog's last reset (fb_board wd_dbg), kept over board resets; vblanks saturate at 65535
set fields_W {
    {pc               0  31 hex}
    {tcr             32  63 hex}
    {vbl_since_wrc   64  79 dec}
    {vbl_since_clr   80  95 dec}
    {enw_clears      96 111 dec}
    {resets         112 119 dec}
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
