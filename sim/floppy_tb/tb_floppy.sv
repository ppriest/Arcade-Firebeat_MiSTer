// SPDX-License-Identifier: GPL-3.0-or-later
// fb_floppy for sim/floppy_tb/main.cpp, which drives the clock, the bus and the hps_io drive.
module tb_floppy (
    input  logic        clk,
    input  logic        reset,
    input  logic        req,
    input  logic        we,
    input  logic [2:0]  port,
    input  logic [7:0]  wdata,
    output logic [7:0]  rdata,
    output logic        irq,
    input  logic        img_mounted,
    input  logic        img_readonly,
    input  logic [63:0] img_size,
    output logic [31:0] sd_lba,
    output logic        sd_rd,
    output logic        sd_wr,
    input  logic        sd_ack,
    input  logic [8:0]  sd_buff_addr,
    input  logic [15:0] sd_buff_dout,
    input  logic        sd_buff_wr,
    output logic [15:0] sd_buff_din
);
fb_floppy u_dut (.*);
endmodule
