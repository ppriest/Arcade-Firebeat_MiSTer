// SPDX-License-Identifier: GPL-3.0-or-later
// fb_atapi CSEL 1 (empty) and fb_atapi_absent side by side for sim/atapi_absent_tb/main.cpp.
module tb_atapi_absent (
    input  logic        clk,
    input  logic        reset,
    input  logic        tick_us,
    input  logic        acc,
    input  logic        we,
    input  logic        cs1,
    input  logic [2:0]  off,
    input  logic [15:0] wd,
    output logic        f_resp,
    output logic        f_irq,
    output logic        f_dasp,
    output logic        f_pdiag,
    output logic        s_dasp,
    output logic        s_pdiag,
    output logic        s_bad
);
fb_atapi #(.CSEL(1'b1)) u_full (
    .clk, .reset, .tick_us, .acc, .we, .cs1, .off, .wd, .resp(f_resp), .rd(), .dma_acc(1'b0), .dmarq(),
    .irq_o(f_irq), .dasp_o(f_dasp), .pdiag_o(f_pdiag), .dasp_i(1'b0), .pdiag_i(1'b0),
    .have_disc(1'b0), .disc_new(1'b0), .ntrk(7'd0), .toc_a(), .toc_start(32'd0), .toc_audio(1'b0),
    .toc_ctl(4'd0), .rq(), .rq_lba(), .rq_half(), .rq_done(1'b0), .bw_we(1'b0), .bw_a(10'd0),
    .bw_d(16'd0), .play_on(), .play_lba(), .play_smp(), .play_tick(), .vol0(), .vol1(),
    .check(), .check_key(), .st_a(7'd0), .st_d(), .st_we(1'b0), .st_wd(32'd0), .bad()
);
fb_atapi_absent u_stub (
    .clk, .reset, .tick_us, .acc, .we, .cs1, .off, .wd,
    .dasp_o(s_dasp), .pdiag_o(s_pdiag), .bad(s_bad)
);
endmodule
