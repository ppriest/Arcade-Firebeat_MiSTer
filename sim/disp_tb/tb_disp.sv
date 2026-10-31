// SPDX-License-Identifier: GPL-3.0-or-later
//
// fb_gcu_disp on hornet_ddr3, its registers and DDRAM port driven by main.cpp.

module tb_disp (
    input  logic             clk,
    input  logic             reset,
    input  logic             test,
    input  logic [2:0][31:0] crtc,
    input  logic [15:0]      layer,
    input  logic [3:0][15:0] fr_alpha,
    input  logic [3:0][15:0] fr_x,
    input  logic [3:0][15:0] fr_y,
    input  logic [3:0][15:0] fr_w,
    input  logic [3:0][15:0] fr_h,
    input  logic [3:0][31:0] fr_base,
    input  logic [15:0]      reg_6c,

    output logic             ce_pix,
    output logic [7:0]       vid_r, vid_g, vid_b,
    output logic             vid_hs, vid_vs, vid_hb, vid_vb,
    output logic [15:0]      late,

    input  logic             DDRAM_BUSY,
    output logic [7:0]       DDRAM_BURSTCNT,
    output logic [28:0]      DDRAM_ADDR,
    input  logic [63:0]      DDRAM_DOUT,
    input  logic             DDRAM_DOUT_READY,
    output logic             DDRAM_RD,
    output logic [63:0]      DDRAM_DIN,
    output logic [7:0]       DDRAM_BE,
    output logic             DDRAM_WE
);

logic        d_read, d_waitn, d_rvalid;
logic [31:0] d_addr, d_rdata, d_rdata_hi;
logic [10:0] d_burst;
logic [1:0]  waitn, rvalid;

fb_gcu_disp u_disp (
    .clk, .reset, .test, .crtc, .layer, .fr_alpha, .fr_x, .fr_y, .fr_w, .fr_h, .fr_base, .reg_6c,
    .m_read(d_read), .m_addr(d_addr), .m_burst(d_burst), .m_waitn(d_waitn), .m_rvalid(d_rvalid),
    .m_rdata(d_rdata), .m_rdata_hi(d_rdata_hi),
    .ce_pix, .r(vid_r), .g(vid_g), .b(vid_b), .hs(vid_hs), .vs(vid_vs), .hb(vid_hb), .vb(vid_vb),
    .vblank(), .late
);

// master 1, as scan-out is the last master in firebeat_sys; master 0 idle
hornet_ddr3 #(.N(2), .WIDE(2'b11)) u_ddr3 (
    .clk, .reset, .drain(1'b0), .idle(),
    .m_read({d_read, 1'b0}), .m_write(2'b00), .m_addr({d_addr, 32'd0}), .m_burst({d_burst, 11'd0}),
    .m_be(8'hFF), .m_wdata(64'd0), .m_be_hi(8'hFF), .m_wdata_hi(64'd0), .m_waitn(waitn),
    .m_rvalid(rvalid), .m_rready(2'b11), .m_rdata(d_rdata), .m_rdata_hi(d_rdata_hi),
    .DDRAM_BUSY, .DDRAM_BURSTCNT, .DDRAM_ADDR, .DDRAM_DOUT, .DDRAM_DOUT_READY, .DDRAM_RD,
    .DDRAM_DIN, .DDRAM_BE, .DDRAM_WE, .dbg(), .dbg_cmd()
);
assign d_waitn = waitn[1];
assign d_rvalid = rvalid[1];

endmodule
