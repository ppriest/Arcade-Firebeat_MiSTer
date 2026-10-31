// SPDX-License-Identifier: GPL-3.0-or-later
//
// The GCU's display as k057714.cpp's draw() and draw_frame() compose it (G:485-624), a line at a
// time from VRAM in DDR3 (a wide hornet_ddr3 master), and its CRTC from registers 0x00-0x08.
//
// Composition: four slots in layer-select order (bits 9:8 first, 15:14 last) each name a context;
// a context with width or height 0 is skipped. Context f covers rows y .. y+h+1 and columns
// x .. x+w+1, clipped to the visible area (draw_frame's off-by-one sizes), and its pixel (i, j) is
// VRAM pixel (base + j*1024 + i) & 0xFFFFFF. A pixel is drawn when bit 15 differs from the
// transparent value (bit 15 clear, or set when register 0x6C selects inverse transparency, G:616);
// a later slot overwrites an earlier one and undrawn pixels are 0. A drawn pixel's channels are
// scaled by the context's factor, min(31, c * a >> 4): a = alpha1, or 16 * alpha2 / alpha1 in
// blend mode 2.
//
// Per line: at the start of line v the next visible line is built in the half of a two-line
// buffer not being shown: cleared, then each slot's row read in 128-beat bursts and its drawn
// pixels written with the context that drew them. Scan-out scales the pixel as it leaves.
//
// When registers take effect: the CRTC at the frame's wrap; the contexts, layer select, register
// 0x6C and the visible area used for clipping as line 0 is fetched, at the start of the last line
// (HACKS: MAME composes at vblank's start).
//
// test: the Phase 1 test picture instead of the registers: mode 1, one 512 x 384 context at VRAM 0.
//
// Pixel clock: clk / 4 (16.667 MHz, the 24 kHz mode; HACKS for 31 kHz).

module fb_gcu_disp #(
    parameter logic [31:0] BASE = 32'h3000_0000
) (
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

    output logic             m_read,
    output logic [31:0]      m_addr,
    output logic [10:0]      m_burst,
    input  logic             m_waitn,
    input  logic             m_rvalid,
    input  logic [31:0]      m_rdata,
    input  logic [31:0]      m_rdata_hi,

    output logic             ce_pix,
    output logic [7:0]       r, g, b,
    output logic             hs, vs, hb, vb,
    output logic             vblank,         // the timing's, for the GCU's IRQ
    output logic [15:0]      late            // lines whose build had not finished when they began
);

// ------------------------------------------------------------------------------------------
// registers, or the test picture's
// ------------------------------------------------------------------------------------------

logic [2:0][31:0] c_crtc;
logic [15:0]      c_layer, c_6c;
logic [3:0][15:0] c_alpha, c_x, c_y, c_w, c_h;
logic [3:0][31:0] c_base;
always_comb begin
    c_crtc = crtc; c_layer = layer; c_6c = reg_6c;
    c_alpha = fr_alpha; c_x = fr_x; c_y = fr_y; c_w = fr_w; c_h = fr_h; c_base = fr_base;
    if (test) begin
        c_crtc = {32'h5F03_0064, 32'h017F_0515, 32'h01FF_0447};
        c_layer = 16'h0000; c_6c = 16'h0000;
        c_alpha = {4{16'h0841}}; c_x = '0; c_y = '0; c_w = {4{16'h01FF}}; c_h = {4{16'h017F}};
        c_base = '0;
    end
end

// the CRTC's fields: visible, front porch, back porch, sync, each the register value + 1 (G:205-232)
wire [11:0] r_hvis = 12'(c_crtc[0][31:16]) + 12'd1;
wire [11:0] r_hfp  = 12'(c_crtc[0][15:8]) + 12'd1;
wire [11:0] r_hbp  = 12'(c_crtc[0][7:0]) + 12'd1;
wire [11:0] r_vvis = 12'(c_crtc[1][31:16]) + 12'd1;
wire [11:0] r_vfp  = 12'(c_crtc[1][15:8]) + 12'd1;
wire [11:0] r_vbp  = 12'(c_crtc[1][7:0]) + 12'd1;
wire [11:0] r_hsy  = 12'(c_crtc[2][31:24]) + 12'd1;
wire [11:0] r_vsy  = 12'(c_crtc[2][23:16]) + 12'd1;

// ------------------------------------------------------------------------------------------
// timing: visible, front porch, sync, back porch; syncs active high
// ------------------------------------------------------------------------------------------

logic [11:0] hvis, hs0, hs1, hlast, vvis, vs0, vs1, vlast;
logic [11:0] h, v;
logic [1:0]  div;
logic        line_start;
always_ff @(posedge clk) begin
    div <= div + 2'd1;
    ce_pix <= div == 2'd3;
    line_start <= 1'b0;
    if (ce_pix) begin
        if (h == hlast) begin
            h <= 12'd0;
            line_start <= 1'b1;
            if (v == vlast) begin
                v <= 12'd0;
                hvis <= r_hvis; hs0 <= r_hvis + r_hfp; hs1 <= r_hvis + r_hfp + r_hsy;
                hlast <= r_hvis + r_hfp + r_hsy + r_hbp - 12'd1;
                vvis <= r_vvis; vs0 <= r_vvis + r_vfp; vs1 <= r_vvis + r_vfp + r_vsy;
                vlast <= r_vvis + r_vfp + r_vsy + r_vbp - 12'd1;
            end else v <= v + 12'd1;
        end else h <= h + 12'd1;
    end
    if (reset) begin
        div <= 2'd0; h <= 12'd0; v <= 12'd0;
        hvis <= r_hvis; hs0 <= r_hvis + r_hfp; hs1 <= r_hvis + r_hfp + r_hsy;
        hlast <= r_hvis + r_hfp + r_hsy + r_hbp - 12'd1;
        vvis <= r_vvis; vs0 <= r_vvis + r_vfp; vs1 <= r_vvis + r_vfp + r_vsy;
        vlast <= r_vvis + r_vfp + r_vsy + r_vbp - 12'd1;
    end
end

wire t_hb = h >= hvis;
wire t_vb = v >= vvis;
wire t_hs = h >= hs0 && h < hs1;
wire t_vs = v >= vs0 && v < vs1;
assign vblank = t_vb;

// ------------------------------------------------------------------------------------------
// the line buffer: 4 banks by x & 3, each [half][x >> 2] of {drawn, context, pixel[14:0]}
// ------------------------------------------------------------------------------------------

logic [3:0]       lb_we;
logic [3:0][8:0]  lb_wa;
logic [3:0][17:0] lb_wd;
logic [8:0]       lb_ra;
logic [3:0][17:0] lb_q;

genvar gk;
generate
for (gk = 0; gk < 4; gk++) begin : g_lb
    logic [17:0] mem [512];
    always_ff @(posedge clk) begin
        if (lb_we[gk]) mem[lb_wa[gk]] <= lb_wd[gk];
        lb_q[gk] <= mem[lb_ra];
    end
end
endgenerate

// ------------------------------------------------------------------------------------------
// building a line
// ------------------------------------------------------------------------------------------

// latched as line 0 is built
logic [15:0]      l_layer;
logic             l_tv;                      // bit 15 of a transparent pixel
logic [3:0][15:0] l_x, l_y, l_w, l_h;
logic [3:0][31:0] l_base;
logic [3:0][1:0]  l_mode;
logic [3:0][4:0]  l_a1, l_a2;
logic [3:0][8:0]  l_fac;                     // the scale factors
logic [11:0]      l_hvis, l_vvis;

typedef enum logic [3:0] { F_IDLE, F_DIV, F_CLR, F_SLOT, F_SL1, F_SL2, F_SL3, F_REQ, F_RCV } fst_t;
fst_t        fs;
logic        pend;                           // a line's build waits for the previous one
logic [11:0] pn;                             // ... that line
logic        w_v, w2_v;                      // a beat's pixels on their way to the buffer
logic [11:0] n;                              // the line being built
logic [1:0]  s;                              // its slot
logic [8:0]  ci;                             // clear row, divider step
logic [8:0]  dq;                             // divider: quotient, remainder
logic [4:0]  dr;
logic [1:0]  df;                             // ... its context

// the slot's span
logic [1:0]  sf;                             // its context
logic [11:0] sx;                             // first column
logic [10:0] snp;                            // pixels
logic [1:0]  soff;                           // first pixel's place in its beat
logic [21:0] sb;                             // next beat to request
logic [8:0]  sleft;                          // beats still to request
logic [7:0]  sch;                            // beats of the burst in flight still to arrive
logic [10:0] sk;                             // the arriving beat's first pixel index + soff

wire [11:0] nxt = (v == vlast) ? 12'd0 : v + 12'd1;

// slot setup over F_SLOT .. F_SL3: the slot's context, then its rows and columns, then its span
wire [1:0]  u_f   = l_layer[8 + 2 * s +: 2];
logic [1:0]  p_f;
logic [15:0] p_x, p_y, p_w, p_h;
logic [31:0] p_base;
logic [16:0] p_x1, p_y1;                     // last column and row, unclipped
logic [11:0] p_j;                            // the context's row
logic        p_on0, p_on;
logic [10:0] p_np;                           // pixels, clipped and kept to the buffer's 1024 columns
logic [23:0] p_sp;                           // the first pixel's VRAM address
wire [16:0] u_xr  = 17'(l_hvis) - 17'd1;                        // the clip
wire [16:0] u_xe0 = (p_x1 > u_xr) ? u_xr : p_x1;
wire [16:0] u_xe  = (u_xe0 > 17'd1023) ? 17'd1023 : u_xe0;
wire [12:0] u_nb0 = (13'(p_sp[1:0]) + 13'(p_np) + 13'd3) >> 2;
wire [22:0] u_top = 23'h40_0000 - 23'(p_sp[23:2]);                // beats to the top of VRAM
wire [8:0]  u_nb  = 9'((23'(u_nb0) > u_top) ? u_top : 23'(u_nb0));

wire [7:0]  chunk = (sleft > 9'd128) ? 8'd128 : 8'(sleft);

// a step of the divider: the numerator 16 * a2's next bit into the remainder
wire [8:0]  d_num = {l_a2[df], 4'd0};
wire [5:0]  d_t   = {dr, d_num[4'd8 - ci[3:0]]};
wire        d_ge  = d_t >= {1'b0, l_a1[df]};

always_ff @(posedge clk) begin
    if (m_read && m_waitn) m_read <= 1'b0;

    if (line_start && nxt < vvis) begin
        if (fs != F_IDLE || pend) begin if (late != 16'hFFFF) late <= late + 16'd1; end
        pend <= 1'b1;
        pn <= nxt;
    end

    case (fs)
    F_IDLE: if (pend && !w_v && !w2_v) begin
        pend <= 1'b0;
        n <= pn;
        ci <= '0;
        if (pn == 12'd0) begin
            l_layer <= c_layer;
            l_tv <= (c_6c[3:0] != 4'd0) && c_6c != 16'h0FFF;
            l_x <= c_x; l_y <= c_y; l_w <= c_w; l_h <= c_h; l_base <= c_base;
            for (int f = 0; f < 4; f++) begin
                l_mode[f] <= c_alpha[f][1:0];
                l_a1[f] <= c_alpha[f][11:7];
                l_a2[f] <= c_alpha[f][6:2];
            end
            l_hvis <= r_hvis; l_vvis <= r_vvis;
            df <= 2'd0; dq <= '0; dr <= '0;
            fs <= F_DIV;
        end else fs <= F_CLR;
    end

    // the factors: a1, or (16 * a2) / a1 by restoring division in mode 2 (0 when a1 is 0)
    F_DIV: begin
        if (ci == 9'd9) begin
            l_fac[df] <= (l_mode[df] != 2'd2) ? 9'(l_a1[df]) : (l_a1[df] == 5'd0) ? 9'd0 : dq;
            ci <= '0; dq <= '0; dr <= '0;
            df <= df + 2'd1;
            if (df == 2'd3) fs <= F_CLR;
        end else begin
            if (d_ge) begin dr <= 5'(d_t - {1'b0, l_a1[df]}); dq <= {dq[7:0], 1'b1}; end
            else begin dr <= d_t[4:0]; dq <= {dq[7:0], 1'b0}; end
            ci <= ci + 9'd1;
        end
    end

    F_CLR: begin
        ci <= ci + 9'd1;
        if (ci == 9'd255) begin s <= 2'd0; fs <= F_SLOT; end
    end

    F_SLOT: begin
        p_f <= u_f; p_x <= l_x[u_f]; p_y <= l_y[u_f]; p_w <= l_w[u_f]; p_h <= l_h[u_f];
        p_base <= l_base[u_f];
        fs <= F_SL1;
    end

    F_SL1: begin
        p_x1 <= 17'(p_x) + 17'(p_w) + 17'd1;
        p_y1 <= 17'(p_y) + 17'(p_h) + 17'd1;
        p_j <= n - 12'(p_y);
        p_on0 <= p_w != 16'd0 && p_h != 16'd0 && 17'(n) >= 17'(p_y) && 17'(p_x) <= u_xr && p_x < 16'd1024;
        fs <= F_SL2;
    end

    F_SL2: begin
        p_on <= p_on0 && 17'(n) <= p_y1;
        p_np <= 11'(u_xe - 17'(p_x) + 17'd1);
        p_sp <= 24'(p_base + {10'd0, p_j, 10'd0});
        fs <= F_SL3;
    end

    F_SL3:
        if (p_on && u_nb != 9'd0) begin
            sf <= p_f; sx <= 12'(p_x); snp <= p_np; soff <= p_sp[1:0];
            sb <= p_sp[23:2]; sleft <= u_nb; sk <= '0;
            fs <= F_REQ;
        end else begin
            s <= s + 2'd1;
            fs <= (s == 2'd3) ? F_IDLE : F_SLOT;
        end

    F_REQ: if (!m_read) begin
        m_read <= 1'b1;
        m_addr <= BASE + {7'd0, sb, 3'd0};
        m_burst <= {2'd0, chunk, 1'b0};
        sch <= chunk;
        sb <= sb + 22'(chunk);
        sleft <= sleft - 9'(chunk);
        fs <= F_RCV;
    end

    F_RCV: if (m_rvalid) begin
        sk <= sk + 11'd4;
        sch <= sch - 8'd1;
        if (sch == 8'd1) begin
            if (sleft != 9'd0) fs <= F_REQ;
            else begin
                s <= s + 2'd1;
                fs <= (s == 2'd3) ? F_IDLE : F_SLOT;
            end
        end
    end

    default: fs <= F_IDLE;
    endcase

    if (reset) begin
        fs <= F_IDLE; pend <= 1'b0; m_read <= 1'b0; late <= '0;
        l_layer <= '0; l_w <= '0; l_h <= '0; l_hvis <= 12'd512; l_vvis <= 12'd384;
    end
end

// the buffer's writes: a clear row, or a beat's drawn pixels, two clocks after the beat arrives
// (F_IDLE waits for them before the next line's clear)
logic [63:0] w_d;
logic [10:0] w_k;
always_ff @(posedge clk) begin
    w_v <= fs == F_RCV && m_rvalid;
    w_d <= {m_rdata_hi, m_rdata};
    w_k <= sk;
end

// beat pixel q: its index in the row, its column, its value (VRAM pixel q is field q ^ 1), drawn
logic [3:0][11:0] wp, wx, wx2;
logic [3:0][15:0] wpix, wpix2;
logic [3:0]       wok, wok2;
logic [1:0]       sf2;
always_comb for (int q = 0; q < 4; q++) begin
    wp[q] = 12'(w_k) + 12'(q) - 12'(soff);
    wx[q] = sx + wp[q];
    wpix[q] = w_d[16 * (q ^ 1) +: 16];
    wok[q] = w_v && 12'(w_k) + 12'(q) >= 12'(soff) && wp[q] < 12'(snp) && wpix[q][15] != l_tv;
end
always_ff @(posedge clk) begin
    w2_v <= w_v;
    wok2 <= wok; wx2 <= wx; wpix2 <= wpix; sf2 <= sf;
end

// the four pixels of a beat have consecutive columns, so each bank takes at most one
always_comb begin
    lb_we = '0;
    lb_wa = '0;
    lb_wd = '0;
    if (fs == F_CLR) begin
        lb_we = 4'hF;
        for (int k = 0; k < 4; k++) lb_wa[k] = {n[0], ci[7:0]};
    end else
        for (int q = 0; q < 4; q++)
            if (wok2[q]) begin
                lb_we[wx2[q][1:0]] = 1'b1;
                lb_wa[wx2[q][1:0]] = {n[0], wx2[q][9:2]};
                lb_wd[wx2[q][1:0]] = {1'b1, sf2, wpix2[q][14:0]};
            end
end

// ------------------------------------------------------------------------------------------
// scan-out: the pixel at (h, v), scaled
// ------------------------------------------------------------------------------------------

function automatic logic [4:0] scale(input logic [4:0] c, input logic [8:0] a);
    logic [13:0] acc;
    acc = '0;
    for (int i = 0; i < 9; i++) if (a[i]) acc = acc + (14'(c) << i);
    return (acc[13:4] > 10'd31) ? 5'd31 : acc[8:4];
endfunction

assign lb_ra = {v[0], h[9:2]};

logic [17:0] px;
logic [1:0]  hq;
logic        hin;                            // h within the buffer's 1024 columns
always_ff @(posedge clk) begin
    hq <= h[1:0];
    hin <= h < 12'd1024;
    px <= hin ? lb_q[hq] : 18'd0;
end

// px is ready two clocks after h moves, the scaled channels three, the output takes them at the
// fourth (the next ce_pix)
logic [8:0] fac;
logic [4:0] sr, sg, sbl;
logic       son;
assign fac = l_fac[px[16:15]];
always_ff @(posedge clk) begin
    sr <= scale(px[14:10], fac);
    sg <= scale(px[9:5], fac);
    sbl <= scale(px[4:0], fac);
    son <= px[17];
end

always_ff @(posedge clk) if (ce_pix) begin
    hs <= t_hs; vs <= t_vs; hb <= t_hb; vb <= t_vb;
    if (t_hb || t_vb || !son) {r, g, b} <= 24'd0;
    else begin
        r <= {sr, sr[4:2]};
        g <= {sg, sg[4:2]};
        b <= {sbl, sbl[4:2]};
    end
end

endmodule
