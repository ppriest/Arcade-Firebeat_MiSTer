// SPDX-License-Identifier: GPL-3.0-or-later
// cd_reader alone; main.cpp is hps_io's side of the reads.
module tb_cdtest (
    input  logic        clk, clear, run, rnd, mounted,
    input  logic [63:0] img_size,
    output logic [31:0] sd_lba,
    output logic [5:0]  sd_blk_cnt,
    output logic        sd_rd,
    input  logic        sd_ack, sd_buff_wr,
    input  logic [15:0] sd_buff_dout,
    output logic        have_image,
    output logic [31:0] image_blocks, requests, words, run_clocks, latency_sum, latency_max, checksum
);
    cd_reader u (.*);
endmodule
