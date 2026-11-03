// SPDX-License-Identifier: GPL-3.0-or-later
// fb_rf5c400 with a sample every 700 clocks; main.cpp drives the 68000's side and the memory.
module tb_rf5c (
    input  logic        clk, reset, req, we,
    input  logic [10:0] addr,
    input  logic [15:0] wd,
    output logic        ack,
    output logic [15:0] rd,
    output logic        m_req, m_we,
    output logic [23:0] m_addr,
    output logic [15:0] m_wd,
    input  logic        m_ack,
    input  logic [15:0] m_rd,
    output logic signed [15:0] out_l, out_r,
    output logic        sample
);
fb_rf5c400 #(.TICK_ADD(1), .TICK_MOD(700)) u (.*);
endmodule
