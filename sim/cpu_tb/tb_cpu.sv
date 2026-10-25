// SPDX-License-Identifier: GPL-3.0-or-later
// ppc403_core behind its caches (rtl/board/fb_ppc_mem.sv); main.cpp serves the line and word ports.
module tb_cpu (
    input  logic         clk,
    input  logic         reset,
    input  logic         ce,
    input  logic         tb_tick,
    output logic         c_req,
    output logic         c_we,
    output logic [26:4]  c_addr,
    output logic [127:0] c_wdata,
    input  logic         c_ack,
    input  logic [127:0] c_rdata,
    output logic         u_req,
    output logic         u_we,
    output logic [30:0]  u_addr,
    output logic [3:0]   u_be,
    output logic [31:0]  u_wdata,
    input  logic         u_ack,
    input  logic [31:0]  u_rdata,
    output logic         dcr_we,        // a DCR write the DMA controller does not hold
    output logic [9:0]   dcr_addr,
    output logic [31:0]  dcr_wdata,
    input  logic [31:0]  dcr_rdata,
    output logic         m_req,         // the DMA's block reads (firebeat_sdram's port m)
    output logic [26:5]  m_addr,
    input  logic         m_ack,
    input  logic [255:0] m_rdata,
    output logic         b_req,         // the DMA's bus port
    output logic         b_we,
    output logic [30:0]  b_addr,
    output logic [31:0]  b_wdata,
    input  logic         b_ack,
    input  logic [31:0]  b_rdata,
    output logic         dma_busy,
    output logic         g_we,          // the DMA's direct path to the GCU
    output logic         g_port,
    output logic [31:0]  g_data,
    output logic         dma_bad,
    input  logic [4:0]   ext_irq,
    output logic         dbg_exec,
    output logic [31:0]  dbg_pc,
    output logic [31:0]  dbg_ir,
    input  logic [5:0]   dbg_sel,
    output logic [31:0]  dbg_val,
    input  logic         dbg_we,
    input  logic [5:0]   dbg_wsel,
    input  logic [31:0]  dbg_wdata,
    output logic         d_req_o,        // the core's data request and its cache operation, for counts
    output logic [2:0]   d_cop_o,
    output logic         d_ack_o
);
    logic        i_req, i_ack, i_a31, d_req, d_we, d_ack, d_a31;
    logic [30:0] i_addr, d_addr;
    logic [31:0] i_rdata, d_rdata, d_wdata, iccr, dccr, dcwr;
    logic [3:0]  d_be;
    logic [2:0]  d_cop;
    ppc403_core #(.PVR(32'h0020_1400)) cpu (
        .clk, .reset, .ce, .tb_tick,
        .i_req, .i_addr, .i_a31, .i_ack, .i_rdata,
        .d_req, .d_we, .d_addr, .d_a31, .d_cop, .d_be, .d_wdata, .d_ack, .d_rdata,
        .iccr_o(iccr), .dccr_o(dccr), .dcwr_o(dcwr),
        .dcr_we(c_dcr_we), .dcr_re(), .dcr_addr, .dcr_wdata, .dcr_rdata(c_dcr_rdata),
        .ext_irq, .int_irq(9'h0),
        .dbg_exec, .dbg_pc, .dbg_ir, .dbg_sel, .dbg_val, .dbg_we, .dbg_wsel, .dbg_wdata
    );
    logic        c_dcr_we, dma_hit;
    logic [31:0] c_dcr_rdata, dma_rdata;
    fb_ppc_dma dma (
        .clk, .reset, .dcr_we(ce && c_dcr_we), .dcr_addr, .dcr_wdata, .dcr_hit(dma_hit), .dcr_rdata(dma_rdata),
        .busy(dma_busy), .irq(), .bad(dma_bad),
        .m_req, .m_addr, .m_ack, .m_rdata,
        .g_we, .g_port, .g_data, .g_ready(1'b1), .dport(),
        .b_req, .b_we, .b_addr, .b_be(), .b_wdata, .b_ack, .b_rdata
    );
    assign c_dcr_rdata = dma_hit ? dma_rdata : dcr_rdata;
    assign dcr_we = ce && c_dcr_we && !dma_hit;
    fb_ppc_mem mem (
        .clk, .reset, .ce,
        .i_req, .i_addr, .i_a31, .i_ack, .i_rdata,
        .d_req, .d_we, .d_addr, .d_a31, .d_be, .d_wdata, .d_cop, .d_ack, .d_rdata,
        .iccr, .dccr, .dcwr,
        .c_req, .c_we, .c_addr, .c_wdata, .c_ack, .c_rdata,
        .u_req, .u_we, .u_addr, .u_be, .u_wdata, .u_ack, .u_rdata
    );
    assign d_req_o = d_req;
    assign d_cop_o = d_cop;
    assign d_ack_o = d_ack;
endmodule
