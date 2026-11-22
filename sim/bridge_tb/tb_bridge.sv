// SPDX-License-Identifier: GPL-3.0-or-later
// fb_midibridge with the ST-224's send ring and heartbeat; main.cpp is the DDR3 port and the server.
module tb_bridge (
    input  logic        clk, reset, brd_reset, held, mute,
    input  logic        tx_v,
    input  logic [7:0]  tx_byte,
    input  logic        send_v,
    input  logic [15:0] send_l, send_r,
    output logic        server_on,
    output logic        m_read, m_write,
    output logic [31:0] m_addr,
    output logic [10:0] m_burst,
    output logic [31:0] m_wdata, m_wdata_hi,
    input  logic        m_waitn, m_rvalid,
    input  logic [31:0] m_rdata
);
fb_midibridge #(.ST224(1)) u (.*);
endmodule
