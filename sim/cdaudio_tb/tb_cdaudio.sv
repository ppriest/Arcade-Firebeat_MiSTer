// SPDX-License-Identifier: GPL-3.0-or-later
// fb_cd_slot alone; main.cpp serves the image and plays it.
module tb_cdaudio (
    input  logic        clk, reset, mounted,
    input  logic [63:0] img_size,
    output logic [31:0] sd_lba,
    output logic [5:0]  sd_blk_cnt,
    output logic        sd_rd,
    input  logic        sd_ack, sd_buff_wr,
    input  logic [15:0] sd_buff_dout,
    output logic        have_disc,
    input  logic        rq,
    input  logic [31:0] rq_lba,
    output logic        rq_done, bw_we,
    output logic [9:0]  bw_a,
    output logic [15:0] bw_d,
    input  logic        play_on, play_tick,
    input  logic [31:0] play_lba,
    input  logic [9:0]  play_smp,
    input  logic [7:0]  vol0, vol1,
    output logic signed [15:0] cd_l, cd_r
);
fb_cd_slot u (
    .clk, .reset, .brd_reset(1'b0), .mounted, .img_size, .sd_lba, .sd_blk_cnt, .sd_rd, .sd_ack,
    .sd_buff_wr, .sd_buff_dout, .have_disc, .disc_new(), .ntrk(), .toc_a(7'd0), .toc_start(),
    .toc_audio(), .toc_ctl(), .rq, .rq_lba, .rq_done, .bw_we, .bw_a, .bw_d,
    .play_on, .play_lba, .play_smp, .play_tick, .vol0, .vol1, .cd_l, .cd_r
);
endmodule
