// SPDX-License-Identifier: GPL-3.0-or-later
// rtl/spu/fb_atahdd.sv for sim/hdd_tb/main.cpp, which plays the slot.
module tb_hdd (
    input  logic        clk, reset,
    input  logic        acc, we, cs1,
    input  logic [2:0]  off,
    input  logic [15:0] wd,
    output logic        resp,
    output logic [15:0] rd,
    input  logic        dma_acc,
    output logic        dmarq, irq_o,
    input  logic        have_disk,
    input  logic [31:0] total,
    input  logic [15:0] cyls,
    input  logic [4:0]  heads,
    input  logic [7:0]  spt,
    output logic        rq,
    output logic [31:0] rq_lba,
    output logic [3:0]  rq_n,
    input  logic        rq_done, bw_we,
    input  logic [10:0] bw_a,
    input  logic [15:0] bw_d,
    output logic        bad,
    output logic        busy
);
    fb_atahdd u (.clk, .reset, .acc, .we, .cs1, .off, .wd, .resp, .rd, .dma_acc, .dmarq, .irq_o,
                 .have_disk, .total, .cyls, .heads, .spt, .rq, .rq_lba, .rq_n, .rq_done, .bw_we,
                 .bw_a, .bw_d, .bad, .st_a(6'd0), .st_d(), .st_we(1'b0), .st_wd(32'd0));
    assign busy = u.status[7];
endmodule
