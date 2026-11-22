// SPDX-License-Identifier: GPL-3.0-or-later
// fb_rot16, its video and master driven by main.cpp. CDC (bm3): the video on clk_v through fb_pix_cdc.
module tb_rot #(
    parameter int BANKS = 4,
    parameter bit CDC = 1'b0
) (
    input  logic        clk,
    input  logic        clk_v,
    output logic        cdc_on,
    input  logic        reset,
    input  logic        enable,
    input  logic        cw,
    input  logic        ce_pix,
    input  logic [7:0]  r, g, b,
    input  logic        vs,
    input  logic        de,
    output logic        FB_EN,
    output logic [4:0]  FB_FORMAT,
    output logic [11:0] FB_WIDTH,
    output logic [11:0] FB_HEIGHT,
    output logic [31:0] FB_BASE,
    output logic [13:0] FB_STRIDE,
    input  logic        FB_VBL,
    input  logic        FB_LL,
    output logic        m_write,
    output logic [31:0] m_addr,
    output logic [10:0] m_burst,
    output logic [31:0] m_wdata,
    output logic [31:0] m_wdata_hi,
    input  logic        m_waitn,
    output logic [15:0] late
);
logic       r_ce, r_vs, r_de;
logic [7:0] r_r, r_g, r_b;
assign cdc_on = CDC;
generate if (CDC) begin : g_cdc
    fb_pix_cdc u_cdc (.i_clk(clk_v), .i_ce(ce_pix), .i_vs(vs), .i_de(de), .i_r(r), .i_g(g), .i_b(b),
                      .clk, .o_ce(r_ce), .o_vs(r_vs), .o_de(r_de), .o_r(r_r), .o_g(r_g), .o_b(r_b));
end else begin : g_nocdc
    assign r_ce = ce_pix; assign r_vs = vs; assign r_de = de; assign r_r = r; assign r_g = g; assign r_b = b;
end endgenerate
fb_rot16 #(.BANKS(BANKS)) u_rot (.clk, .reset, .enable, .cw, .ce_pix(r_ce), .r(r_r), .g(r_g), .b(r_b),
    .vs(r_vs), .de(r_de), .FB_EN, .FB_FORMAT, .FB_WIDTH, .FB_HEIGHT, .FB_BASE, .FB_STRIDE, .FB_VBL, .FB_LL,
    .m_write, .m_addr, .m_burst, .m_wdata, .m_wdata_hi, .m_waitn, .late);
endmodule
