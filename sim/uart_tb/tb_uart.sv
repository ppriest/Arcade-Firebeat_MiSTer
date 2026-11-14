// SPDX-License-Identifier: GPL-3.0-or-later
// One fb_ns16550 with fb_board's 24 MHz enable (9 clocks in 25), and fb_midibridge on its transmit
// side writing to main.cpp's DDR3, for main.cpp.
module tb_uart (
    input  logic        clk,
    input  logic        rst,
    input  logic        req,
    input  logic        we,
    input  logic [2:0]  addr,
    input  logic [7:0]  wdata,
    output logic [7:0]  rdata,
    input  logic        rxd,
    output logic        tx_v,
    output logic [7:0]  tx_byte,
    output logic        int_upd,
    output logic        int_hi,
    output logic        int_q,
    input  logic        st_hold,
    input  logic [6:0]  st_a,
    output logic [31:0] st_d,
    input  logic        st_we,
    input  logic [31:0] st_wd,
    input  logic        held,
    output logic        m_write,
    output logic [31:0] m_addr,
    output logic [31:0] m_wdata,
    output logic [31:0] m_wdata_hi,
    input  logic        m_waitn
);
logic [4:0] c24;
logic       ce24;
always_ff @(posedge clk) begin
    ce24 <= c24 >= 5'd16;
    c24 <= (c24 >= 5'd16) ? c24 - 5'd16 : c24 + 5'd9;
    if (rst) begin c24 <= 5'd0; ce24 <= 1'b0; end
end
fb_ns16550 u_ch (
    .clk, .reset(rst), .ce24(ce24 && !st_hold), .req, .we, .addr, .wdata, .rdata, .rxd, .txd(), .tx_v, .tx_byte,
    .int_upd, .int_hi, .int_q,
    .st_hold, .st_a, .st_d, .st_we, .st_wd
);
fb_midibridge u_br (
    .clk, .reset(rst), .brd_reset(rst), .held, .mute(1'b0), .tx_v, .tx_byte,
    .m_write, .m_addr, .m_burst(), .m_wdata, .m_wdata_hi, .m_waitn
);
endmodule
