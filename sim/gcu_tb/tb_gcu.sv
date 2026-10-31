// SPDX-License-Identifier: GPL-3.0-or-later
//
// The GCU (fb_gcu_shell with fb_gcu) on hornet_ddr3, its DDRAM port and register bus driven by
// main.cpp. Master 1, served first as in firebeat_sys, is fb_gcu_disp on the shell's registers,
// running when scan is set.

module tb_gcu (
    input  logic         clk,
    input  logic         reset,         // the GCU's
    input  logic         por,           // hornet_ddr3's: power-up only
    input  logic         scan,

    input  logic         req,
    input  logic         we,
    input  logic [7:0]   addr,
    input  logic [3:0]   be,
    input  logic [31:0]  wdata,
    output logic         ack,
    output logic [31:0]  rdata,
    output logic         gcu_idle,
    output logic         cmd_v,
    output logic [31:0]  dbg,               // the engine's state, for a bench that stalls
    output logic         ce_pix,
    output logic [7:0]   vid_r, vid_g, vid_b,
    output logic         vid_hs, vid_vs, vid_hb, vid_vb,
    output logic [15:0]  late,

    input  logic         DDRAM_BUSY,
    output logic [7:0]   DDRAM_BURSTCNT,
    output logic [28:0]  DDRAM_ADDR,
    input  logic [63:0]  DDRAM_DOUT,
    input  logic         DDRAM_DOUT_READY,
    output logic         DDRAM_RD,
    output logic [63:0]  DDRAM_DIN,
    output logic [7:0]   DDRAM_BE,
    output logic         DDRAM_WE
);

logic [1:0]       d_read, d_write, d_waitn, d_rvalid;
logic [1:0][31:0] d_maddr, d_wdata, d_wdata_hi;
logic [1:0][3:0]  d_be, d_be_hi;
logic [1:0][10:0] d_burst;
logic [31:0]      d_rdata, d_rdata_hi;

fb_gcu_shell u_gcu (
    .clk, .reset, .req, .we, .addr, .be, .wdata, .ack, .rdata,
    .dg_we(1'b0), .dg_port(1'b0), .dg_data(32'd0), .dg_ready(),
    .vblank(1'b0), .busy0(1'b0), .busy1(1'b0), .irq(),
    .cmd_v, .cmd_port(), .cmd(),
    .m_read(d_read[0]), .m_write(d_write[0]), .m_addr(d_maddr[0]), .m_burst(d_burst[0]),
    .m_be(d_be[0]), .m_wdata(d_wdata[0]), .m_be_hi(d_be_hi[0]), .m_wdata_hi(d_wdata_hi[0]),
    .m_waitn(d_waitn[0]), .m_rvalid(d_rvalid[0]), .m_rdata(d_rdata), .m_rdata_hi(d_rdata_hi),
    .gcu_idle,
    .crtc, .ctrl_lo(layer), .fr_alpha, .fr_x, .fr_y, .fr_w, .fr_h, .fr_base, .reg_6c
);

logic [2:0][31:0] crtc;
logic [15:0]      layer, reg_6c;
logic [3:0][15:0] fr_alpha, fr_x, fr_y, fr_w, fr_h;
logic [3:0][31:0] fr_base;

fb_gcu_disp u_disp (
    .clk, .reset(por || !scan), .test(1'b0),
    .crtc, .layer, .fr_alpha, .fr_x, .fr_y, .fr_w, .fr_h, .fr_base, .reg_6c,
    .m_read(d_read[1]), .m_addr(d_maddr[1]), .m_burst(d_burst[1]), .m_waitn(d_waitn[1]),
    .m_rvalid(d_rvalid[1]), .m_rdata(d_rdata), .m_rdata_hi(d_rdata_hi),
    .ce_pix, .r(vid_r), .g(vid_g), .b(vid_b), .hs(vid_hs), .vs(vid_vs), .hb(vid_hb), .vb(vid_vb),
    .vblank(), .late
);
assign d_write[1] = 1'b0;
assign d_be[1] = 4'hF; assign d_be_hi[1] = 4'hF;
assign d_wdata[1] = '0; assign d_wdata_hi[1] = '0;

hornet_ddr3 #(.N(2), .WIDE(2'b11), .PRI(0)) u_ddr3 (
    .clk, .reset(por), .drain(1'b0), .idle(),
    .m_read(d_read), .m_write(d_write), .m_addr(d_maddr), .m_burst(d_burst), .m_be(d_be),
    .m_wdata(d_wdata), .m_be_hi(d_be_hi), .m_wdata_hi(d_wdata_hi), .m_waitn(d_waitn),
    .m_rvalid(d_rvalid), .m_rready(2'b11), .m_rdata(d_rdata), .m_rdata_hi(d_rdata_hi),
    .DDRAM_BUSY, .DDRAM_BURSTCNT, .DDRAM_ADDR, .DDRAM_DOUT, .DDRAM_DOUT_READY, .DDRAM_RD,
    .DDRAM_DIN, .DDRAM_BE, .DDRAM_WE, .dbg(), .dbg_cmd()
);

assign dbg = {3'd0, 5'(u_gcu.u_eng.st), u_gcu.u_eng.rd_iss[7:0], u_gcu.u_eng.rd_rcv[7:0],
              u_gcu.u_eng.wr_on, u_gcu.u_eng.wr_kill, 2'(u_ddr3.as), 4'(u_gcu.u_eng.q_cnt)};

endmodule
