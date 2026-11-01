// SPDX-License-Identifier: GPL-3.0-or-later
// fb_ata with no discs mounted; main.cpp replays a register-access log and reads the slave's
// access log back.
module tb_ata (
    input  logic        clk, reset, por,
    input  logic        req, we, cs1,
    input  logic [2:0]  off,
    input  logic [15:0] wdata,
    output logic        ack,
    output logic [15:0] rdata,
    input  logic [11:0] lg_a,
    output logic [31:0] lg_d
);
    logic [31:0] sd_lba [2], play_lba [2], st_d;
    logic [5:0]  sd_blk_cnt [2];
    logic [3:0]  check_key [2];
    fb_ata u (
        .clk, .reset, .por, .req, .we, .cs1, .off, .wdata, .ack, .rdata, .irq(),
        .img_mounted(2'b00), .img_size(64'd0), .sd_lba, .sd_blk_cnt, .sd_rd(), .sd_ack(2'b00),
        .sd_buff_wr(1'b0), .sd_buff_dout(16'd0), .play_on(), .play_lba, .check(), .check_key,
        .st_a(8'd0), .st_d, .st_we(1'b0), .st_wd(32'd0), .lg_a, .lg_d, .bad()
    );
endmodule
