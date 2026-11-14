// SPDX-License-Identifier: GPL-3.0-or-later
//
// HDMI rotation, 90 degrees counter-clockwise (ROT270) or, with cw, clockwise, by the HPS framebuffer
// (MISTER_FB): a tap on the core's video, as sys' screen_rotate, but a master that can wait. Source
// pixel (x, y) of a W x H raster goes to framebuffer column y, row W-1-x; with cw to column H-1-y,
// row x (the same picture turned 180 degrees). H must be a multiple of 16, which every kbm mode is
// (480, 384, 768); it is taken at each slice.
//
// Sixteen consecutive source lines are held in one of four banks of sixteen line RAMs, then written
// as a burst of four beats per source column, sixteen pixels side by side in the framebuffer, while
// later slices fill the other banks: up to three slices wait behind the one being written. A beat a
// command cost the port too much for both screens stacked (512 x 768), where slices were lost.
// RGB555 loses nothing: the display's channels are 5 bits (fb_gcu_disp). A slice that finds every
// bank taken is lost, counted in late.
//
// Pixels are little-endian {0, b, g, r}, format 1555 RGB (sys/ascal.vhd, shift_opix). Three buffers
// of 8 MB from BASE, or two in low-latency mode, as screen_rotate.

module fb_rot16 #(
    parameter logic [31:0] BASE = 32'h2400_0000
) (
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

logic [11:0] w, h;                          // the last frame's width and height
wire  [8:0]  stride16 = 9'((h + 12'd7) >> 3);   // the stride, in 16-byte units: 8 pixels

assign FB_FORMAT = 5'b01100;
assign FB_WIDTH  = h;
assign FB_HEIGHT = w;
assign FB_STRIDE = {1'b0, stride16, 4'd0};

// the buffers
logic [1:0] i_fb, o_fb;
assign FB_BASE = BASE + {7'd0, o_fb, 23'd0};

function automatic logic [1:0] buf_next(input logic [1:0] a, input logic [1:0] c);
    if ((a == 2'd0 && c == 2'd1) || (a == 2'd1 && c == 2'd0)) return 2'd2;
    if ((a == 2'd1 && c == 2'd2) || (a == 2'd2 && c == 2'd1)) return 2'd0;
    return 2'd1;
endfunction

logic vbl_q, vs_ce_q, de_q;
wire  vs_rise = ce_pix && vs && !vs_ce_q;
always_ff @(posedge clk) begin
    vbl_q <= FB_VBL;
    if (FB_LL) begin
        if (FB_VBL && !vbl_q) o_fb <= {1'b0, ~i_fb[0]};
        if (vs_rise) i_fb <= {1'b0, ~i_fb[0]};
    end else begin
        if (FB_VBL && !vbl_q) o_fb <= buf_next(o_fb, i_fb);
        if (vs_rise) i_fb <= buf_next(i_fb, o_fb);
    end
    if (reset) begin i_fb <= 2'd0; o_fb <= 2'd1; end
end

// ------------------------------------------------------------------------------------------
// the input: a frame's size, and the lines into the half not being written out
// ------------------------------------------------------------------------------------------

logic [11:0] x, y;
logic [2:0]  en_sr;                         // on after three frames of a known size
logic [1:0]  bank;                          // the bank filling
logic [1:0]  rbank;                         // the oldest slice's, being written out
logic [2:0]  cnt;                           // slices waiting or being written
logic        done;                          // the writer finished rbank's slice
logic [7:0]  s_col [4];                     // each bank's slice: its first framebuffer column / 16,
logic [1:0]  s_fb [4];                      // its buffer,
logic [11:0] s_h [4];                       // and its frame's height
assign FB_EN = en_sr[2] && enable;

wire line_end = ce_pix && de_q && !de;
wire slice_end = line_end ? y[3:0] == 4'd15 : (vs_rise && y[3:0] != 4'd0);

always_ff @(posedge clk) begin
    if (ce_pix) begin
        de_q <= de;
        vs_ce_q <= vs;
        if (de) x <= x + 12'd1;
        if (line_end) begin
            w <= x;
            x <= 12'd0;
            y <= y + 12'd1;
        end
        if (vs_rise) begin
            h <= y;
            y <= 12'd0;
            x <= 12'd0;
            en_sr <= {en_sr[1:0], enable};
        end
    end
    if (done) begin rbank <= rbank + 2'd1; cnt <= cnt - 3'd1; end
    if (slice_end && FB_EN) begin
        if (cnt - 3'(done) == 3'd3) begin
            if (late != 16'hFFFF) late <= late + 16'd1;
        end else begin
            s_col[bank] <= y[11:4];
            s_fb[bank] <= i_fb;
            s_h[bank] <= vs_rise ? y : h;
            bank <= bank + 2'd1;
            cnt <= cnt - 3'(done) + 3'd1;
        end
    end
    if (reset) begin
        en_sr <= 3'd0; x <= 12'd0; y <= 12'd0; w <= 12'd512; h <= 12'd384;
        de_q <= 1'b0; vs_ce_q <= 1'b0; bank <= 2'd0; rbank <= 2'd0; cnt <= 3'd0; late <= '0;
    end
end

// ------------------------------------------------------------------------------------------
// the line RAMs, one per line of a slice: [bank][source column]
// ------------------------------------------------------------------------------------------

logic [9:0]        rx;
logic [15:0][14:0] rq;
genvar gk;
generate
for (gk = 0; gk < 16; gk++) begin : g_l
    logic [14:0] mem [4096];
    always_ff @(posedge clk) begin
        if (ce_pix && de && y[3:0] == 4'(gk)) mem[{bank, x[9:0]}] <= {b[7:3], g[7:3], r[7:3]};
        rq[gk] <= mem[{rbank, rx}];
    end
end
endgenerate

// ------------------------------------------------------------------------------------------
// the output: framebuffer row 0 first, source column W-1 (cw: 0), a burst a row
// ------------------------------------------------------------------------------------------

typedef enum logic [1:0] { R_IDLE, R_RD, R_Q, R_WR } rst_t;
rst_t             rs;
logic [24:0]      ra;                       // the burst's address within the buffers
logic             rcw;                      // the slice's direction
logic             rlast;                    // the burst in R_WR is the slice's last
logic [1:0]       rk;                       // the beat in R_WR
logic [3:0][63:0] bt;                       // the burst's beats, left to right in the framebuffer
assign m_burst = 11'd8;

// beat k of a column's sixteen pixels: lines 4k..4k+3 left to right, or with cw lines 15-4k down
function automatic logic [63:0] beat(input logic [15:0][14:0] q, input logic c, input int k);
    if (c) return {1'b0, q[12 - 4 * k], 1'b0, q[13 - 4 * k], 1'b0, q[14 - 4 * k], 1'b0, q[15 - 4 * k]};
    return {1'b0, q[4 * k + 3], 1'b0, q[4 * k + 2], 1'b0, q[4 * k + 1], 1'b0, q[4 * k]};
endfunction

// rx moves to the next column as a burst is loaded, so its pixels are at rq two clocks later, before
// the burst's last beat goes. The next burst is loaded with that beat and m_write stays high: hornet_ddr3
// picks the next master as a write's last beat leaves, and a clock without the request gave the port to
// the GCU's bursts of up to 128 beats, a slice's writes falling behind with both screens stacked
task automatic load;
    for (int k = 0; k < 4; k++) bt[k] <= beat(rq, rcw, k);
    m_write <= 1'b1;
    m_addr <= BASE + {7'd0, ra};
    {m_wdata_hi, m_wdata} <= beat(rq, rcw, 0);
    rk <= 2'd0;
    ra <= ra + {12'd0, stride16, 4'd0};
    rx <= rcw ? rx + 10'd1 : rx - 10'd1;
    rlast <= rcw ? rx == 10'(w - 12'd1) : rx == 10'd0;
    rs <= R_WR;
endtask

always_ff @(posedge clk) begin
    done <= 1'b0;
    case (rs)
    R_IDLE: if (cnt != 3'd0 && !done) begin
        // cw: the slice's sixteen columns are H-16-16k .. H-1-16k, line 16k+15 first
        ra <= {s_fb[rbank], 23'd0} + (cw ? {12'd0, 8'((s_h[rbank] - 12'd16) >> 4) - s_col[rbank], 5'd0}
                                         : {12'd0, s_col[rbank], 5'd0});
        rx <= cw ? 10'd0 : 10'(w - 12'd1);
        rcw <= cw;
        rs <= R_RD;
    end
    R_RD: rs <= R_Q;                        // the address is at the RAMs
    R_Q: load();
    R_WR: if (m_waitn) begin
        rk <= rk + 2'd1;
        {m_wdata_hi, m_wdata} <= bt[rk + 2'd1];
        if (rk == 2'd3) begin
            if (rlast) begin m_write <= 1'b0; done <= 1'b1; rs <= R_IDLE; end
            else load();
        end
    end
    default: rs <= R_IDLE;
    endcase
    if (reset) begin rs <= R_IDLE; m_write <= 1'b0; done <= 1'b0; end
end

endmodule
