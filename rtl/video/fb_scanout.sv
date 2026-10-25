// SPDX-License-Identifier: GPL-3.0-or-later
//
// Scan-out of one 512-pixel display context from VRAM in DDR3 (a wide hornet_ddr3 master): at
// the start of line v the next visible line is read, 256 words in one burst, into the half of a
// two-line buffer not being shown. VRAM pixels are RGB555, 1024 to a row (2048 bytes), pixel x
// at byte 2x, the even pixel in a word's low half. Phase 4 replaces this with the four composed
// contexts.
//
// The outputs are registered at ce_pix for the pixel h, v of fb_video_timing.

module fb_scanout #(
    parameter logic [31:0] BASE = 32'h3000_0000,
    parameter int          V_VIS = 384,
    parameter int          V_TOT = 416
) (
    input  logic        clk,
    input  logic        reset,
    input  logic        ce_pix,
    input  logic [9:0]  h,
    input  logic [9:0]  v,
    input  logic        line_start,
    input  logic        hs_in, vs_in, hb_in, vb_in,

    output logic        m_read,
    output logic [31:0] m_addr,
    output logic [10:0] m_burst,
    input  logic        m_waitn,
    input  logic        m_rvalid,
    input  logic [31:0] m_rdata,
    input  logic [31:0] m_rdata_hi,

    output logic [7:0]  r, g, b,
    output logic        hs, vs, hb, vb,
    output logic [15:0] late             // lines whose read had not finished when they began
);

// the line to read at the start of line v
wire [9:0] nxt = (v == 10'(V_TOT - 1)) ? 10'd0 : v + 10'd1;

logic [63:0] buf_mem [256];             // [line & 1][pixel / 4]
logic [7:0]  wa;
logic        busy;

always_ff @(posedge clk) begin
    if (m_read && m_waitn) m_read <= 1'b0;
    if (line_start) begin
        if (busy && late != 16'hFFFF) late <= late + 16'd1;
        if (nxt < 10'(V_VIS)) begin
            m_read <= 1'b1;
            m_addr <= BASE + {12'd0, nxt[8:0], 11'd0};
            m_burst <= 11'd256;
            busy <= 1'b1;
            wa <= {nxt[0], 7'd0};
        end
    end
    if (m_rvalid) begin
        buf_mem[wa] <= {m_rdata_hi, m_rdata};
        wa <= wa + 8'd1;
        if (wa[6:0] == 7'd127) busy <= 1'b0;
    end
    if (reset) begin m_read <= 1'b0; busy <= 1'b0; late <= 16'd0; end
end

logic [63:0] q;
always_ff @(posedge clk) q <= buf_mem[{v[0], h[8:2]}];

logic [15:0] px;
always_comb case (h[1:0])
    2'd0: px = q[15:0];
    2'd1: px = q[31:16];
    2'd2: px = q[47:32];
    default: px = q[63:48];
endcase

always_ff @(posedge clk) if (ce_pix) begin
    hs <= hs_in; vs <= vs_in; hb <= hb_in; vb <= vb_in;
    if (hb_in || vb_in) {r, g, b} <= 24'd0;
    else begin
        r <= {px[14:10], px[14:12]};
        g <= {px[9:5], px[9:7]};
        b <= {px[4:0], px[4:2]};
    end
end

endmodule
