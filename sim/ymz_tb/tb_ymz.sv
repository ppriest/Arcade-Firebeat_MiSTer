// SPDX-License-Identifier: GPL-3.0-or-later
// fb_ymz280b with a tick every 400 clocks; main.cpp drives the host and port y.
module tb_ymz (
    input  logic        clk, reset, req, we, a0,
    input  logic [7:0]  wdata,
    output logic        ack,
    output logic [7:0]  rdata,
    output logic        y_req,
    output logic [21:0] y_addr,
    input  logic        y_ack,
    input  logic [7:0]  y_rdata,
    output logic signed [15:0] out_l, out_r,
    output logic        tick
);
fb_ymz280b #(.TICK_ADD(1), .TICK_MOD(400)) u (
    .clk, .reset, .req, .we, .a0, .wdata, .ack, .rdata, .y_req, .y_addr, .y_ack, .y_rdata,
    .out_l, .out_r, .tick, .reg_q(), .reg_a(8'd0)
);
endmodule
