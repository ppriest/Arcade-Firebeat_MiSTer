// SPDX-License-Identifier: GPL-3.0-or-later
// fb_spu68k with its bus brought out for main.cpp, and fx68k's interrupt mask for the trace's mask
// column (MAME's SR mask at each access).
module tb_spu (
    input  logic         clk,
    input  logic         rst,
    output logic         x_req,
    output logic         x_we,
    output logic [ 1:0]  x_be,
    output logic [ 2:0]  x_rgn,
    output logic [24:1]  x_addr,
    output logic [15:0]  x_wd,
    input  logic         x_ack,
    input  logic [15:0]  x_rd,
    input  logic         pp_cs,
    input  logic         pp_we,
    input  logic [ 9:0]  pp_addr,
    input  logic [ 7:0]  pp_wd,
    output logic [ 7:0]  pp_rd,
    output logic         ppc_irq,
    input  logic         ata_irq,
    output logic [ 7:0]  leds,
    output logic         tr_valid,
    output logic [26:0]  tr_info,
    output logic [15:0]  tr_data,
    output logic [ 2:0]  sr_mask
);
fb_spu68k dut (
    .clk, .rst,
    .x_req, .x_we, .x_be, .x_rgn, .x_addr, .x_wd, .x_ack, .x_rd,
    .pp_cs, .pp_we, .pp_addr, .pp_wd, .pp_rd, .ppc_irq,
    .ata_irq, .dsw(8'hFF), .leds, .dma_addr(), .dma_inc(1'b0), .wave_bank(),
    .tr_valid, .tr_info, .tr_data
);
assign sr_mask = dut.u_cpu.pswI;
endmodule
