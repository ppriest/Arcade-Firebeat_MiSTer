// SPDX-License-Identifier: GPL-3.0-or-later
// rtl/mister/firebeat_sdram.sv on the 128 MB module's command-decoding model; main.cpp drives the
// clients and keeps the reference memory.
module tb_sdram (
    input  logic         clk,
    input  logic         clk_mem,
    input  logic         init,
    input  logic         reset,

    input  logic         c_req,
    input  logic         c_we,
    input  logic [26:4]  c_addr,
    input  logic [127:0] c_wdata,
    output logic         c_ack,
    output logic [127:0] c_rdata,

    input  logic         m_req,
    input  logic [26:5]  m_addr,
    output logic         m_ack,
    output logic [255:0] m_rdata,

    input  logic         w_req,
    input  logic         w_we,
    input  logic [26:2]  w_addr,
    input  logic [3:0]   w_be,
    input  logic [31:0]  w_wdata,
    output logic         w_ack,
    output logic [31:0]  w_rdata,

    input  logic         d_we,
    input  logic [26:1]  d_addr,
    input  logic [15:0]  d_din,
    output logic         d_ready,

    output logic         mem_busy          // the controller is in a transaction or a refresh
);
    wire  [15:0] SDRAM_DQ;
    logic [12:0] SDRAM_A;
    logic [1:0]  SDRAM_BA;
    logic        SDRAM_DQML, SDRAM_DQMH, SDRAM_nCS, SDRAM_nWE, SDRAM_nRAS, SDRAM_nCAS, SDRAM_CKE;

    firebeat_sdram u (.*);

    sdram_chip_model_128 u_chip (
        .clk(clk_mem), .SDRAM_DQ, .SDRAM_A, .SDRAM_BA, .SDRAM_nCS, .SDRAM_nWE, .SDRAM_nRAS,
        .SDRAM_nCAS
    );

    assign mem_busy = u.u_sdram.state != 5'd0;
endmodule
