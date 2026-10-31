// SPDX-License-Identifier: GPL-3.0-or-later
//
// [Firebeat] The board state dump (diagnostic; docs/STATE.md has the format, HACKS what it leaves
// out). start stops the board (fb_board halt, then frozen), copies the register block and the
// SDRAM's work RAM and flash into DDR3, writes the header last, and keeps the board stopped until
// the next start. The HPS reads the dump from /dev/mem; VRAM is already in DDR3 at 0x30000000.
//
// DDR3 at BASE:
//   +0x00000  header: "FBSD", version, dump count, then the blocks' offsets and sizes
//   +0x01000  register block: st_a's 16K words, word k of the block at +4k
//   +0x20000  SDRAM 0x0000000-0x25FFFFF (work RAM, flash), 16-byte lines as the cache port reads
//             them (word k of a line at +4k)
//
// st_a/st_d: the board's register block, read with 7 clocks' settling time a word (the RTC's
// NVRAM answers a clock late, then fb_board registers it). c_*: the
// SDRAM's cache port, taken only once the board's own request has ended. m_*: a wide
// hornet_ddr3 master writing a line (two 64-bit beats) a burst.

module fb_dump #(
    parameter logic [31:0] BASE = 32'h3400_0000
) (
    input  logic         clk,
    input  logic         reset,
    input  logic         abort,         // the board's reset: releases it unless a copy is running
    input  logic         start,         // a pulse: dump, or release a dumped board
    output logic         halt,
    input  logic         frozen,
    input  logic         port_free,     // the board's cache-port request has ended
    output logic         busy,          // copying
    output logic         own,           // the cache port is the dump's

    output logic [13:0]  st_a,
    input  logic [31:0]  st_d,

    output logic         c_req,
    output logic [26:4]  c_addr,
    input  logic         c_ack,
    input  logic [127:0] c_rdata,

    output logic         m_write,
    output logic [31:0]  m_addr,
    output logic [10:0]  m_burst,
    output logic [31:0]  m_wdata,
    output logic [31:0]  m_wdata_hi,
    input  logic         m_waitn
);

localparam logic [31:0] REG_OFF = 32'h0000_1000, REG_SIZE = 32'h0001_0000;
localparam logic [31:0] SD_OFF  = 32'h0002_0000, SD_SIZE  = 32'h0260_0000;
localparam logic [22:0] SD_LINES = 23'h26_0000;     // SD_SIZE / 16

typedef enum logic [2:0] { D_IDLE, D_FREEZE, D_REG, D_SD, D_HDR, D_WRITE, D_HELD } d_t;
d_t d, d_next;                          // d_next: where D_WRITE returns

logic [31:0]  count;                    // dumps taken since reset
logic [22:0]  line;                     // the block's line being copied
logic [22:0]  line_n;                   // the line after D_WRITE
logic [1:0]   wk;                       // D_REG: the word of the line
logic [2:0]   wt;                       // D_REG: settling clocks
logic [127:0] buf_l;                    // the line to write, word k in bits 32k+31:32k
logic         beat;                     // D_WRITE: the second beat
logic         hdr1;                     // D_HDR: the header's second line

assign busy = d != D_IDLE && d != D_HELD;
assign st_a = {line[11:0], wk};

function automatic logic [127:0] header(input logic second, input logic [31:0] n);
    return second ? {SD_SIZE, SD_OFF, REG_SIZE, REG_OFF}
                  : {32'h0200_0000, 32'h3000_0000, n, 32'h4642_5344};   // VRAM size, VRAM, count, "FBSD"
endfunction

always_ff @(posedge clk) begin
    case (d)
    D_IDLE: if (start) begin halt <= 1'b1; hdr1 <= 1'b0; d <= D_FREEZE; end
    D_FREEZE:
        if (frozen && port_free) begin
            own <= 1'b1; line <= '0; wk <= 2'd0; wt <= 3'd0; d <= D_REG;
        end
    D_REG: begin
        wt <= wt + 3'd1;
        if (wt == 3'd7) begin
            buf_l[32*wk +: 32] <= st_d;
            wk <= wk + 2'd1;
            if (wk == 2'd3) begin
                m_addr <= BASE + REG_OFF + {5'd0, line, 4'd0};
                d_next <= (line == 23'd4095) ? D_SD : D_REG;
                line_n <= (line == 23'd4095) ? 23'd0 : line + 23'd1;
                d <= D_WRITE;
            end
        end
    end
    D_SD:
        if (!c_req) c_req <= 1'b1;
        else if (c_ack) begin
            c_req <= 1'b0;
            buf_l <= c_rdata;
            m_addr <= BASE + SD_OFF + {5'd0, line, 4'd0};
            d_next <= (line == SD_LINES - 23'd1) ? D_HDR : D_SD;
            line_n <= line + 23'd1;
            d <= D_WRITE;
        end
    D_HDR: begin
        buf_l <= header(hdr1, count + 32'd1);
        m_addr <= BASE + {27'd0, hdr1, 4'd0};
        d_next <= hdr1 ? D_HELD : D_HDR;
        hdr1 <= 1'b1;
        d <= D_WRITE;
    end
    D_WRITE:
        if (!m_write) begin
            m_write <= 1'b1; m_burst <= 11'd4; beat <= 1'b0;
            m_wdata <= buf_l[31:0]; m_wdata_hi <= buf_l[63:32];
        end else if (m_waitn) begin
            if (!beat) begin
                beat <= 1'b1; m_wdata <= buf_l[95:64]; m_wdata_hi <= buf_l[127:96];
            end else begin
                m_write <= 1'b0;
                d <= d_next;
                line <= line_n;
                if (d_next == D_HELD) begin own <= 1'b0; count <= count + 32'd1; end
            end
        end
    D_HELD: if (start) begin halt <= 1'b0; d <= D_IDLE; end
    default: d <= D_IDLE;
    endcase
    if (abort && (d == D_FREEZE || d == D_HELD)) begin halt <= 1'b0; own <= 1'b0; d <= D_IDLE; end
    if (reset) begin
        d <= D_IDLE; halt <= 1'b0; own <= 1'b0; c_req <= 1'b0; m_write <= 1'b0; count <= '0;
    end
end

assign c_addr = line;

endmodule
