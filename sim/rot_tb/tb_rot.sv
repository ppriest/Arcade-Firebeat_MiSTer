// SPDX-License-Identifier: GPL-3.0-or-later
// fb_rot16, its video and master driven by main.cpp.
module tb_rot (
    input  logic        clk,
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
fb_rot16 u_rot (.*);
endmodule
