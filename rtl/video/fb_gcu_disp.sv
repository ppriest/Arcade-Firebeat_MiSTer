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
// Pixel clock: clk / 4 (16.667 MHz, the 24 kHz mode; HACKS for 31 kHz). VCLK (BM3, not with KBM):
// scan-out (the timing, the buffer's reads, the scaling and the outputs) runs on clk_v / 4 instead,
// clk_v 100.7 MHz for 25.175 MHz (ROADMAP Phase 10 decision B). The build stays on clk. Crossing:
// the buffer is dual-clock; each line start goes to clk as a toggle with that line's next row, the
// visible height and flip, held for the line; the factors are taken at line 0's start (as KBM's);
// vblank is synchronised. The CRTC registers, test and flip reach clk_v unsynchronised: they hold
// still while the game runs (bm3 writes no CRTC register), and a change shows at the frame's wrap.
//
// KBM: two GCUs on one output, the second's registers on b_* and its VRAM at BASE + 32 MB. screen
// 0 shows the first, 1 the second, 2 both stacked: twice the lines at clk / 2, the same frame, one
// screen's lines then the other's from the same engine, by the first GCU's CRTC (HACKS). Taken at
// the frame's wrap.
//
// flip: the picture turned 180 degrees, for HDMI and analog alike: lines are built bottom first and
// each is read out right to left. Stacked, the second screen then shows on top. Taken at the
// frame's wrap.

module fb_gcu_disp #(
    parameter logic [31:0] BASE = 32'h3000_0000,
    parameter bit          KBM = 1'b0,
    parameter bit          VCLK = 1'b0
) (
    input  logic             clk,
    input  logic             clk_v,          // VCLK: the scan-out clock
    input  logic             reset,
    input  logic             test,
    input  logic [1:0]       screen,
    input  logic             flip,

    input  logic [2:0][31:0] b_crtc,
    input  logic [15:0]      b_layer,
    input  logic [3:0][15:0] b_alpha,
    input  logic [3:0][15:0] b_x,
    input  logic [3:0][15:0] b_y,
    input  logic [3:0][15:0] b_w,
    input  logic [3:0][15:0] b_h,
    input  logic [3:0][31:0] b_base,
    input  logic [15:0]      b_6c,

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
    output logic [15:0]      late,           // lines whose build had not finished when they began
    // [Firebeat] the stp revision's probes, on clk: a visible line's build due (pr_lstart) for row
    // pr_row, the previous build not finished then (pr_late), a build running, its read waiting for
    // the port, and contexts 0 and 1's bases as latched for the frame
    output logic             pr_lstart,
    output logic [11:0]      pr_row,
    output logic             pr_late,
    output logic             pr_build,
    output logic             pr_rwait,
    output logic [1:0][23:0] pr_base
);

wire sclk = VCLK ? clk_v : clk;
logic s_reset;                               // reset, on sclk
generate if (VCLK) begin : g_srst
    logic [1:0] rq;
    always_ff @(posedge clk_v or posedge reset) if (reset) rq <= 2'b11; else rq <= {rq[0], 1'b0};
    assign s_reset = rq[1];
end else begin : g_nsrst
    assign s_reset = reset;
end endgenerate

// ------------------------------------------------------------------------------------------
// registers, or the test picture's
// ------------------------------------------------------------------------------------------

logic [2:0][31:0] c_crtc;
logic [15:0]      c_layer, c_6c;
logic [3:0][15:0] c_alpha, c_x, c_y, c_w, c_h;
logic [3:0][31:0] c_base;
logic [1:0]       scr;                       // screen, as of the frame's wrap
logic             fl;                        // flip, as of the frame's wrap
wire              stack = KBM && scr == 2'd2;
logic [11:0]      half;                      // stack: the second screen's first line
logic [11:0]      pn;                        // the next line to build, as shown
logic [11:0]      vvis;
logic [11:0]      b_vvis;                    // vvis and fl as the build sees them
logic             b_fl;
wire  [11:0]      pl = b_fl ? b_vvis - 12'd1 - pn : pn;   // ... its line in the unflipped picture
wire              use_b = KBM && (scr == 2'd1 || (stack && pl >= half));
always_comb begin
    c_crtc = (KBM && scr == 2'd1) ? b_crtc : crtc;
    c_layer = use_b ? b_layer : layer;
    c_6c = use_b ? b_6c : reg_6c;
    c_alpha = use_b ? b_alpha : fr_alpha;
    c_x = use_b ? b_x : fr_x;
    c_y = use_b ? b_y : fr_y;
    c_w = use_b ? b_w : fr_w;
    c_h = use_b ? b_h : fr_h;
    c_base = use_b ? b_base : fr_base;
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
wire        n_stack = KBM && screen == 2'd2;    // the next frame's
wire [11:0] n_vs0   = r_vvis + r_vfp;
wire [11:0] n_vs1   = n_vs0 + r_vsy;
wire [11:0] n_vt    = n_vs1 + r_vbp;

// ------------------------------------------------------------------------------------------
// timing: visible, front porch, sync, back porch; syncs active high
// ------------------------------------------------------------------------------------------

logic [11:0] hvis, hs0, hs1, hlast, vs0, vs1, vlast;
logic [11:0] h, v;
logic [1:0]  div;
logic        line_start;
always_ff @(posedge sclk) begin
    div <= div + 2'd1;
    ce_pix <= stack ? div[0] : div == 2'd3;
    line_start <= 1'b0;
    if (ce_pix) begin
        if (h == hlast) begin
            h <= 12'd0;
            line_start <= 1'b1;
            if (v == vlast) begin
                v <= 12'd0;
                hvis <= r_hvis; hs0 <= r_hvis + r_hfp; hs1 <= r_hvis + r_hfp + r_hsy;
                hlast <= r_hvis + r_hfp + r_hsy + r_hbp - 12'd1;
                scr <= screen;
                fl <= flip;
                half <= r_vvis;
                vvis <= n_stack ? r_vvis << 1 : r_vvis;
                vs0 <= n_stack ? n_vs0 << 1 : n_vs0;
                vs1 <= n_stack ? n_vs1 << 1 : n_vs1;
                vlast <= (n_stack ? n_vt << 1 : n_vt) - 12'd1;
            end else v <= v + 12'd1;
        end else h <= h + 12'd1;
    end
    if (s_reset) begin
        div <= 2'd0; h <= 12'd0; v <= 12'd0;
        hvis <= r_hvis; hs0 <= r_hvis + r_hfp; hs1 <= r_hvis + r_hfp + r_hsy;
        hlast <= r_hvis + r_hfp + r_hsy + r_hbp - 12'd1;
        vvis <= r_vvis; vs0 <= n_vs0; vs1 <= n_vs1;
        vlast <= n_vt - 12'd1;
        scr <= 2'd0; fl <= 1'b0; half <= r_vvis;
    end
end

wire t_hb = h >= hvis;
wire t_vb = v >= vvis;
wire t_hs = h >= hs0 && h < hs1;
wire t_vs = v >= vs0 && v < vs1;

// the line start as the build sees it: b_start with the next row b_nxt, b_vvis, b_fl
wire [11:0] nxt = (v == vlast) ? 12'd0 : v + 12'd1;
logic       b_start;
logic [11:0] b_nxt;
generate if (VCLK) begin : g_cross
    logic        ls_t, ls_fl;
    logic [11:0] ls_nxt, ls_vvis;
    logic [2:0]  ls_s;
    logic [1:0]  vb_s;
    always_ff @(posedge clk_v) if (line_start) begin
        ls_t <= !ls_t; ls_nxt <= nxt; ls_vvis <= vvis; ls_fl <= fl;
    end
    always_ff @(posedge clk) begin
        ls_s <= {ls_s[1:0], ls_t};
        b_start <= ls_s[2] != ls_s[1];
        if (ls_s[2] != ls_s[1]) begin b_nxt <= ls_nxt; b_vvis <= ls_vvis; b_fl <= ls_fl; end
        vb_s <= {vb_s[0], t_vb};
    end
    assign vblank = vb_s[1];
end else begin : g_ncross
    assign b_start = line_start;
    assign b_nxt = nxt;
    assign b_vvis = vvis;
    assign b_fl = fl;
    assign vblank = t_vb;
end endgenerate

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
    always_ff @(posedge clk) if (lb_we[gk]) mem[lb_wa[gk]] <= lb_wd[gk];
    always_ff @(posedge sclk) lb_q[gk] <= mem[lb_ra];
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
logic        w_v, w2_v;                      // a beat's pixels on their way to the buffer
logic [11:0] n;                              // the row being built, in its screen
logic        nb;                             // ... the line's half of the buffer
logic        l_b;                            // ... from the second GCU's VRAM
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

    if (b_start && b_nxt < b_vvis) begin
        if (fs != F_IDLE || pend) begin if (late != 16'hFFFF) late <= late + 16'd1; end
        pend <= 1'b1;
        pn <= b_nxt;
    end

    case (fs)
    F_IDLE: if (pend && !w_v && !w2_v) begin
        pend <= 1'b0;
        n <= (stack && pl >= half) ? pl - half : pl;
        nb <= pn[0];
        ci <= '0;
        if (pn == 12'd0 || (stack && pn == half)) begin
            l_b <= use_b;
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
        m_addr <= BASE + {6'd0, l_b, sb, 3'd0};
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
        l_layer <= '0; l_w <= '0; l_h <= '0; l_hvis <= 12'd512; l_vvis <= 12'd384; l_b <= 1'b0;
    end
end

assign pr_lstart = b_start && b_nxt < b_vvis;
assign pr_row    = b_nxt;
assign pr_late   = pr_lstart && (fs != F_IDLE || pend);
assign pr_build  = fs != F_IDLE;
assign pr_rwait  = m_read && !m_waitn;
assign pr_base   = {l_base[1][23:0], l_base[0][23:0]};

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
        for (int k = 0; k < 4; k++) lb_wa[k] = {nb, ci[7:0]};
    end else
        for (int q = 0; q < 4; q++)
            if (wok2[q]) begin
                lb_we[wx2[q][1:0]] = 1'b1;
                lb_wa[wx2[q][1:0]] = {nb, wx2[q][9:2]};
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

wire [11:0] hx = fl ? hvis - 12'd1 - h : h;   // the column shown at h
assign lb_ra = {v[0], hx[9:2]};

logic [17:0] px;
logic [1:0]  hq;
logic        hin;                            // hx within the buffer's 1024 columns
always_ff @(posedge sclk) begin
    hq <= hx[1:0];
    hin <= hx < 12'd1024;
    px <= hin ? lb_q[hq] : 18'd0;
end

// px is ready two clocks after h moves, the scaled channels three, the output takes them at the
// fourth: the next ce_pix, or at clk / 2 the one after, so the timing is a pixel later there.
// VCLK: the scaling takes three clocks (100.7 MHz), the channels are ready at the fifth, and the
// output takes them at the ce_pix after, the timing a pixel later as at clk / 2.
// KBM: a screen's factors take over as its first line is shown, its build having started a line
// before, while the other screen's last line was showing.
logic [8:0] fac;
logic [4:0] sr, sg, sbl;
logic       son;
logic [3:0][8:0] o_fac;
always_ff @(posedge sclk) if (line_start && (v == 12'd0 || (stack && v == half))) o_fac <= l_fac;
assign fac = (KBM || VCLK) ? o_fac[px[16:15]] : l_fac[px[16:15]];
function automatic logic [13:0] psum(input logic [4:0] c, input logic [8:0] a, input logic hi);
    logic [13:0] acc;
    acc = '0;
    for (int i = 0; i < 9; i++) if (a[i] && (i >= 5) == hi) acc = acc + (14'(c) << i);
    return acc;
endfunction
function automatic logic [4:0] sat(input logic [13:0] acc);
    return (acc[13:4] > 10'd31) ? 5'd31 : acc[8:4];
endfunction

generate if (VCLK) begin : g_scale3
    logic [2:0][4:0]  q_c;
    logic [8:0]       q_f;
    logic [2:0][13:0] q_lo, q_hi;
    logic [1:0]       q_on;
    always_ff @(posedge sclk) begin
        q_c <= {px[14:10], px[9:5], px[4:0]};
        q_f <= fac;
        for (int k = 0; k < 3; k++) begin
            q_lo[k] <= psum(q_c[k], q_f, 1'b0);
            q_hi[k] <= psum(q_c[k], q_f, 1'b1);
        end
        sr <= sat(q_lo[2] + q_hi[2]);
        sg <= sat(q_lo[1] + q_hi[1]);
        sbl <= sat(q_lo[0] + q_hi[0]);
        q_on <= {q_on[0], px[17]};
        son <= q_on[1];
    end
end else begin : g_scale1
    always_ff @(posedge sclk) begin
        sr <= scale(px[14:10], fac);
        sg <= scale(px[9:5], fac);
        sbl <= scale(px[4:0], fac);
        son <= px[17];
    end
end endgenerate

logic d_hs, d_vs, d_hb, d_vb;
always_ff @(posedge sclk) if (ce_pix) begin d_hs <= t_hs; d_vs <= t_vs; d_hb <= t_hb; d_vb <= t_vb; end
wire late_px = stack || VCLK;
wire o_hs = late_px ? d_hs : t_hs;
wire o_vs = late_px ? d_vs : t_vs;
wire o_hb = late_px ? d_hb : t_hb;
wire o_vb = late_px ? d_vb : t_vb;

always_ff @(posedge sclk) if (ce_pix) begin
    hs <= o_hs; vs <= o_vs; hb <= o_hb; vb <= o_vb;
    if (o_hb || o_vb || !son) {r, g, b} <= 24'd0;
    else begin
        r <= {sr, sr[4:2]};
        g <= {sg, sg[4:2]};
        b <= {sbl, sbl[4:2]};
    end
end

endmodule
