// SPDX-License-Identifier: GPL-3.0-or-later
//
// The board's SDRAM clients on the 128 MB module through Sorgelig's controller (rtl/mister/sdram)
// at clk_mem = 2 x clk (133.33 MHz from the same PLL; the controller's timing parameters are set
// for that clock).
//
//   c  the PPC's caches: a 16-byte line read (a fill) or written (a write-back)
//   m  the PPC's DMA controller: a 32-byte block read (the controller's quad read, 16 halfwords
//      from one row activation; the game's transfers run tens of words)
//   w  one 32-bit word with byte enables: the flash model, the YMZ280B's samples, the NVRAM save
//   d  the download, a halfword at a time (load time), on the controller's port 2
//
// One transaction is in the controller at a time, chosen w, then c, then m: the controller works
// on one at a time anyway, and a read can then never overtake a write to the same line. A line
// read is one double read (8 halfwords from one row activation) on the controller's port 0, a
// block read one quad read (16); a line write four two-halfword writes on port 1; a word read
// the double read of its line.
//
// Data: a 32-bit word is big-endian, as the PPC and the ROM images: its high halfword at the lower
// address, each halfword's high byte on DQ[15:8]. Line data carry word k (byte address + 4k) in
// bits 32k+31:32k (a block, word k of 8 likewise). be[3] is the word's byte at the lowest
// address (bits 31:24).
//
// Requests are held until acknowledged; the acknowledge is one clock with the read data, and the
// request may drop that clock. The controller's inputs are clk registers held from a request
// until its acknowledge, which is taken into clk with the data (Hornet's arrangement, clk_mem
// a multiple of clk from one PLL).

module firebeat_sdram (
    input  logic         clk,
    input  logic         clk_mem,
    input  logic         init,           // ~pll_locked: the chip's initialisation
    input  logic         reset,          // not the core's reset: the download needs this side

    output logic [12:0]  SDRAM_A,
    inout  wire  [15:0]  SDRAM_DQ,
    output logic         SDRAM_DQML,
    output logic         SDRAM_DQMH,
    output logic [1:0]   SDRAM_BA,
    output logic         SDRAM_nCS,
    output logic         SDRAM_nWE,
    output logic         SDRAM_nRAS,
    output logic         SDRAM_nCAS,
    output logic         SDRAM_CKE,

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
    output logic         d_ready
);

// ------------------------------------------------------------------------------------------
// the controller
// ------------------------------------------------------------------------------------------

logic [26:1] m_addr0, m_addr1, m_addr2;
logic        m_req0 = 1'b0, m_req1 = 1'b0, m_req2 = 1'b0;
logic        m_ack0, m_ack1, m_ack2;
logic        m_wrl1, m_wrh1, m_w2, m_wrl1b, m_wrh1b;
logic [15:0] m_din1, m_din1b, m_din2;
logic [63:0] m_dout, m_doutb, m_doutc, m_doutd;
logic        m_quad0 = 1'b0;

sdram #(.RASCAS_DELAY(3'd3), .CAS_LATENCY(3'd3), .RFS_PERIOD(10'd500)) u_sdram (
    .SDRAM_DQ, .SDRAM_A, .SDRAM_DQML, .SDRAM_DQMH, .SDRAM_BA, .SDRAM_nCS, .SDRAM_nWE,
    .SDRAM_nRAS, .SDRAM_nCAS, .SDRAM_CLK(), .SDRAM_CKE,
    .init, .clk(clk_mem),
    .addr0(m_addr0), .wrl0(1'b0), .wrh0(1'b0), .din0(16'h0), .dout0(m_dout), .req0(m_req0),
    .ack0(m_ack0), .dbl0(1'b1), .dout0b(m_doutb), .quad0(m_quad0), .dout0c(m_doutc), .dout0d(m_doutd),
    .addr1(m_addr1), .wrl1(m_wrl1), .wrh1(m_wrh1), .din1(m_din1), .dout1(), .req1(m_req1),
    .w2_1(m_w2), .din1b(m_din1b), .wrl1b(m_wrl1b), .wrh1b(m_wrh1b),
    .ack1(m_ack1),
    .addr2(m_addr2), .wrl2(1'b1), .wrh2(1'b1), .din2(m_din2), .dout2(), .req2(m_req2),
    .ack2(m_ack2)
);

// acknowledges and data into clk; a port is idle when its acknowledge has caught up
logic        k_ack0, k_ack1, k_ack2;
logic [63:0] k_dout, k_doutb, k_doutc, k_doutd;
always_ff @(posedge clk) begin
    k_ack0 <= m_ack0; k_ack1 <= m_ack1; k_ack2 <= m_ack2;
    k_dout <= m_dout; k_doutb <= m_doutb; k_doutc <= m_doutc; k_doutd <= m_doutd;
end
wire p0_idle = k_ack0 == m_req0;
wire p1_idle = k_ack1 == m_req1;
wire p2_idle = k_ack2 == m_req2;

// word k (0..3) of a double read: the high halfword at the lower address
function automatic logic [31:0] gw(input logic [63:0] g, input logic k);
    return k ? {g[47:32], g[63:48]} : {g[15:0], g[31:16]};
endfunction
wire [127:0] line_rd = {gw(k_doutb, 1), gw(k_doutb, 0), gw(k_dout, 1), gw(k_dout, 0)};
wire [255:0] block_rd = {gw(k_doutd, 1), gw(k_doutd, 0), gw(k_doutc, 1), gw(k_doutc, 0), line_rd};

// ------------------------------------------------------------------------------------------
// port 2: the download
// ------------------------------------------------------------------------------------------

assign d_ready = p2_idle;
always_ff @(posedge clk) begin
    if (d_we && p2_idle) begin m_addr2 <= d_addr; m_din2 <= d_din; m_req2 <= !m_req2; end
    if (reset) m_req2 <= k_ack2;
end

// ------------------------------------------------------------------------------------------
// ports 0 and 1: the sequencer
// ------------------------------------------------------------------------------------------

typedef enum logic [2:0] { S_IDLE, S_READ, S_WRITE, S_WWORD, S_DONE } s_t;
s_t          st;
logic [1:0]  who;                       // 0 w, 1 c, 2 m
logic [26:4] line;                      // for m, the block's first line
logic [1:0]  wk;                        // the word of the line being written / read for w
logic [127:0] wbuf;
logic [3:0]  wbe;

// a two-halfword write of word k of wbuf, its byte enables wbe (all four for a line write)
task automatic issue_word(input logic [1:0] k, input logic [31:0] d, input logic [3:0] be);
    // the high halfword first; a word with no byte in its high half writes the low half alone
    if (be[3:2] != 2'b00) begin
        m_addr1 <= {line, k, 1'b0};
        m_din1 <= d[31:16]; m_wrh1 <= be[3]; m_wrl1 <= be[2];
        m_din1b <= d[15:0]; m_wrh1b <= be[1]; m_wrl1b <= be[0];
        m_w2 <= be[1:0] != 2'b00;
    end else begin
        m_addr1 <= {line, k, 1'b1};
        m_din1 <= d[15:0]; m_wrh1 <= be[1]; m_wrl1 <= be[0];
        m_w2 <= 1'b0;
    end
    m_req1 <= !m_req1;
endtask

always_ff @(posedge clk) begin
    c_ack <= 1'b0; m_ack <= 1'b0; w_ack <= 1'b0;
    case (st)
    S_IDLE:
        if (w_req) begin
            who <= 2'd0; line <= w_addr[26:4]; wk <= w_addr[3:2];
            if (w_we) begin
                wbuf <= {4{w_wdata}}; wbe <= w_be; st <= S_WWORD;
            end else begin
                m_addr0 <= {w_addr[26:4], 3'b000}; m_quad0 <= 1'b0; m_req0 <= !m_req0; st <= S_READ;
            end
        end else if (c_req) begin
            who <= 2'd1; line <= c_addr;
            if (c_we) begin
                wbuf <= c_wdata; wbe <= 4'hf; wk <= 2'd0; st <= S_WRITE;
            end else begin
                m_addr0 <= {c_addr, 3'b000}; m_quad0 <= 1'b0; m_req0 <= !m_req0; st <= S_READ;
            end
        end else if (m_req) begin
            who <= 2'd2; line <= {m_addr, 1'b0};
            m_addr0 <= {m_addr, 4'b0000}; m_quad0 <= 1'b1; m_req0 <= !m_req0; st <= S_READ;
        end
    S_READ:
        if (p0_idle) begin
            case (who)
            2'd0: begin w_ack <= 1'b1; w_rdata <= line_rd[32 * wk +: 32]; end
            2'd1: begin c_ack <= 1'b1; c_rdata <= line_rd; end
            default: begin m_ack <= 1'b1; m_rdata <= block_rd; end
            endcase
            st <= S_DONE;
        end
    S_WRITE:                            // a line: words 0..3, one two-halfword write each
        if (p1_idle) begin
            issue_word(wk, wbuf[32 * wk +: 32], 4'hf);
            if (wk == 2'd3) st <= S_WWORD;   // S_WWORD waits for the last and acknowledges
            wk <= wk + 2'd1;
            if (wk == 2'd3) wbe <= 4'h0;
        end
    S_WWORD:                            // w: issue the word; c: the line's last write is out
        if (p1_idle) begin
            if (wbe != 4'h0) begin
                issue_word(wk, wbuf[31:0], wbe);
                wbe <= 4'h0;
            end else begin
                if (who == 2'd0) w_ack <= 1'b1; else c_ack <= 1'b1;
                st <= S_DONE;
            end
        end
    S_DONE:                             // the acknowledged request drops this clock
        st <= S_IDLE;
    default: st <= S_IDLE;
    endcase
    if (reset) begin
        st <= S_IDLE; m_req0 <= k_ack0; m_req1 <= k_ack1;
    end
end

initial begin
    st = S_IDLE; c_ack = 1'b0; m_ack = 1'b0; w_ack = 1'b0;
end

endmodule
