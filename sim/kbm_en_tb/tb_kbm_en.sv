// SPDX-License-Identifier: GPL-3.0-or-later
// fb_kbm_en alone; main.cpp feeds a disc's frames through it.
module tb_kbm_en (
    input  logic        clk,
    input  logic        reset,
    input  logic        en,
    input  logic [31:0] rq_lba,
    input  logic        bw_we,
    input  logic [9:0]  bw_a,
    input  logic [15:0] bw_d,
    output logic [15:0] bw_q
);
fb_kbm_en u (.*);
endmodule
