// SPDX-License-Identifier: GPL-3.0-or-later
//
// K057714 GCU command engine, from MAME's k057714.cpp (G:): the VRAM words and commands the
// register file (fb_gcu_shell) collects, executed in order against VRAM on DDR3.
//
//   queue     entries pushed by the shell, in the order the game wrote them: {2'd0, addr, word} a
//             VRAM word from a write port, {2'd1, cmd} a command's four words (cmd0 in [127:96]).
//   commands  0 nop, 1 display list (nested on a stack of STK, 0x1000 entries a list, ending at the
//             top of VRAM), 2 end of list, 3 origin, 4 fill, 5 object, 6/7 2-bpp character; the
//             fields, rounding and bounds as G:552-901.
//   memory    a wide hornet_ddr3 master: 64-bit beats of four pixels. VRAM word k is MAME's
//             m_vram[k], {pixel 2k, pixel 2k+1}, at byte 4k; so pixel q of a beat is in field q ^ 1
//             (bits 16(q^1)+15:16(q^1)). Bursts are split at 254 beats and at the top of VRAM.
//
// A fill writes each row as bursts of one constant beat (the pattern follows the pixel address).
// An object reads a source row (at most 512 pixels) into SB, four copies so that four scaled
// columns are read a clock, and builds the destination a beat (four pixels) a clock in chunks of
// 128 beats in DB, reading the destination first only when it blends; transparent and clipped
// pixels are written with byte enables off, and only the beats from the first to the last drawn
// one. A source row is read again only when it changes or when the rows drawn since overlapped it.
// A character builds its 8 pixels a row in DB, a pixel a clock. Queued VRAM words are gathered in
// DB a word a clock while they fall in its 128 beats from the first one's, and written as one burst
// when a command or a word outside comes, or the queue stays empty for 32 clocks.
//
// MAME executes a command within the register write; here the queue absorbs them and the shell
// holds the bus only when the queue is full or a VRAM read must wait for it (HACKS).

module fb_gcu #(
    parameter logic [31:0] VBASE = 32'h3000_0000,
    parameter int          QW    = 5,               // the queue holds 2^QW entries
    parameter int          STK   = 8                // display lists nested below the first
) (
    input  logic         clk,
    input  logic         reset,

    input  logic         push,
    input  logic [129:0] push_d,
    output logic         ready,             // room for two more entries
    output logic         idle,              // nothing queued, nothing running

    // a VRAM word for the read window, taken only when idle
    input  logic         rw_req,
    input  logic [22:0]  rw_addr,
    output logic         rw_ack,
    output logic [31:0]  rw_data,

    output logic         m_read,
    output logic         m_write,
    output logic [31:0]  m_addr,
    output logic [10:0]  m_burst,
    output logic [3:0]   m_be,
    output logic [31:0]  m_wdata,
    output logic [3:0]   m_be_hi,
    output logic [31:0]  m_wdata_hi,
    input  logic         m_waitn,
    input  logic         m_rvalid,
    input  logic [31:0]  m_rdata,
    input  logic [31:0]  m_rdata_hi
);

// ------------------------------------------------------------------------------------------
// queue
// ------------------------------------------------------------------------------------------

logic [129:0] qm [1 << QW];
logic [QW:0]  q_wp, q_rp;
logic [129:0] q_q;
logic         q_rd;
always_ff @(posedge clk) begin
    if (push) qm[q_wp[QW-1:0]] <= push_d;
    q_q <= qm[q_rp[QW-1:0]];
    if (push) q_wp <= q_wp + 1'd1;
    if (q_rd) q_rp <= q_rp + 1'd1;
    if (reset) begin q_wp <= '0; q_rp <= '0; end
end
wire [QW:0] q_cnt = q_wp - q_rp;
assign ready = q_cnt < (QW+1)'((1 << QW) - 2);

// ------------------------------------------------------------------------------------------
// buffers: SB a source row of beats (four copies, one a pixel of the beat built); DB the
// destination chunk, one RAM a field, and its enables
// ------------------------------------------------------------------------------------------

logic        sb_we;
logic [7:0]  sb_wa;
logic [63:0] sb_wd;
logic [7:0]  sb_ra [4];
logic [63:0] sbq [4];
genvar gs;
generate
for (gs = 0; gs < 4; gs++) begin : g_sb
    logic [63:0] mem [256];
    always_ff @(posedge clk) begin
        if (sb_we) mem[sb_wa] <= sb_wd;
        sbq[gs] <= mem[sb_ra[gs]];
    end
end
endgenerate

logic [3:0]  dbf_we;
logic [6:0]  dbf_wa;
logic [15:0] dbf_wd [4];
logic [6:0]  db_ra;
logic [15:0] dbq [4];
genvar gf;
generate
for (gf = 0; gf < 4; gf++) begin : g_dbf
    logic [15:0] mem [128];
    always_ff @(posedge clk) begin
        if (dbf_we[gf]) mem[dbf_wa] <= dbf_wd[gf];
        dbq[gf] <= mem[db_ra];
    end
end
endgenerate

logic [3:0]  db_be [128];               // fields written this chunk
logic        tr_any;                    // a field written: tr_lo..tr_hi the beats holding them
logic [6:0]  tr_lo, tr_hi;

// a beat's four pixel enables (pixel q) as the byte enables of its fields (field q ^ 1)
function automatic logic [7:0] pm2be(input logic [3:0] m);
    return {m[2], m[2], m[3], m[3], m[0], m[0], m[1], m[1]};
endfunction

// pixels q >= o of a beat; pixels q <= e
function automatic logic [3:0] from_q(input logic [1:0] o);
    return 4'b1111 << o;
endfunction
function automatic logic [3:0] upto_q(input logic [1:0] e);
    return (e == 2'd0) ? 4'b0001 : (e == 2'd1) ? 4'b0011 : (e == 2'd2) ? 4'b0111 : 4'b1111;
endfunction

// ------------------------------------------------------------------------------------------
// reader: rd_n beats from beat rd_b0 into SB, DB or rb
// ------------------------------------------------------------------------------------------

localparam logic [1:0] D_SB = 2'd0, D_DB = 2'd1, D_RB = 2'd2;

logic        rd_go;
logic [21:0] rd_b0;
logic [8:0]  rd_n;
logic [1:0]  rd_dst;

logic [21:0] rd_b;
logic [8:0]  rd_iss, rd_rcv;
logic [7:0]  rd_wi;
logic [1:0]  rd_d;
logic [63:0] rb [3];

function automatic logic [8:0] burst_of(input logic [8:0] left, input logic [21:0] b);
    logic [22:0] room;
    logic [8:0]  n;
    room = 23'h40_0000 - {1'b0, b};
    n = (left > 9'd254) ? 9'd254 : left;
    if ({14'd0, n} > room) n = room[8:0];
    return n;
endfunction

wire [8:0] rd_cb = burst_of(rd_iss, rd_b);
wire rd_busy = rd_iss != 9'd0 || rd_rcv != 9'd0;

always_ff @(posedge clk) begin
    if (m_read && m_waitn) begin rd_b <= rd_b + {13'd0, rd_cb}; rd_iss <= rd_iss - rd_cb; end
    if (m_rvalid) begin
        rd_wi <= rd_wi + 8'd1;
        rd_rcv <= rd_rcv - 9'd1;
        if (rd_d == D_RB) rb[rd_wi[1:0]] <= {m_rdata_hi, m_rdata};
    end
    if (rd_go) begin rd_b <= rd_b0; rd_iss <= rd_n; rd_rcv <= rd_n; rd_wi <= 8'd0; rd_d <= rd_dst; end
    // reset: no more bursts, but the beats of those on the port are still taken (hornet_ddr3 has
    // no way to cancel them)
    if (reset) begin
        rd_iss <= '0;
        rd_rcv <= rd_rcv - rd_iss + ((m_read && m_waitn) ? rd_cb : 9'd0) - (m_rvalid ? 9'd1 : 9'd0);
    end
end

// ------------------------------------------------------------------------------------------
// writer: wr_n beats from beat wr_b0, a constant beat (wr_pat, enables wr_bf first and wr_bl last)
// or DB from offset wr_o0 with its field enables
// ------------------------------------------------------------------------------------------

logic        wr_go;
logic [21:0] wr_b0;
logic [8:0]  wr_n;
logic        wr_db;
logic [6:0]  wr_o0;
logic [63:0] wr_pat;
logic [7:0]  wr_bf, wr_bl;

logic        wr_on, wr_prime, wr_src, wr_kill;
logic [21:0] wr_b;
logic [8:0]  wr_left, wr_t, wr_cb, wr_n_m1;
logic [7:0]  wr_bl_left;
logic [6:0]  wr_o;
logic [63:0] wr_pq;
logic [7:0]  wr_pf, wr_pl;

wire wr_acc = m_write && m_waitn;
wire wr_busy = wr_on;

always_ff @(posedge clk) begin
    wr_prime <= 1'b0;
    if (wr_acc) begin
        wr_t <= wr_t + 9'd1;
        wr_o <= wr_o + 7'd1;
        wr_bl_left <= wr_bl_left - 8'd1;
        if (wr_bl_left == 8'd1) begin
            logic [21:0] nb;
            logic [8:0]  nl, cb;
            nb = wr_b + {13'd0, wr_cb};
            nl = wr_left - wr_cb;
            cb = burst_of(nl, nb);
            wr_b <= nb;
            wr_left <= nl;
            wr_cb <= cb;
            wr_bl_left <= cb[7:0];
            if (nl == 9'd0) wr_on <= 1'b0;
        end
    end
    if (wr_go) begin
        logic [8:0] cb;
        cb = burst_of(wr_n, wr_b0);
        wr_on <= 1'b1; wr_prime <= 1'b1; wr_src <= wr_db;
        wr_b <= wr_b0; wr_left <= wr_n; wr_t <= 9'd0; wr_o <= wr_o0; wr_n_m1 <= wr_n - 9'd1;
        wr_cb <= cb;
        wr_bl_left <= cb[7:0];
        wr_pq <= wr_pat; wr_pf <= wr_bf; wr_pl <= wr_bl;
        wr_kill <= 1'b0;
    end
    // reset: a burst offered to hornet_ddr3 may have been granted, so it is finished, writing
    // nothing; none follows it
    if (reset) begin
        if (!wr_on || wr_prime || (wr_acc && wr_bl_left == 8'd1)) wr_on <= 1'b0;
        else begin wr_kill <= 1'b1; wr_left <= wr_cb; end
    end
end

logic [7:0] wr_be;
always_comb begin
    if (wr_kill) wr_be = 8'h00;
    else if (wr_src) wr_be = pm2be({db_be[wr_o][2], db_be[wr_o][3], db_be[wr_o][0], db_be[wr_o][1]});
    else begin
        wr_be = 8'hFF;
        if (wr_t == 9'd0) wr_be = wr_be & wr_pf;
        if (wr_t == wr_n_m1) wr_be = wr_be & wr_pl;
    end
end

wire [63:0] wr_data = wr_src ? {dbq[3], dbq[2], dbq[1], dbq[0]} : wr_pq;

assign m_read     = rd_iss != 9'd0;
assign m_write    = wr_on && !wr_prime;
assign m_addr     = VBASE + {7'd0, (m_read ? rd_b : wr_b), 3'd0};
assign m_burst    = {1'b0, (m_read ? rd_cb : wr_cb), 1'b0};
assign m_wdata    = wr_data[31:0];
assign m_wdata_hi = wr_data[63:32];
assign m_be       = wr_be[3:0];
assign m_be_hi    = wr_be[7:4];

// ------------------------------------------------------------------------------------------
// divider: dv_q = dv_n / dv_d, unsigned, 27 clocks
// ------------------------------------------------------------------------------------------

logic        dv_go, dv_on;
logic [26:0] dv_n, dv_q;
logic [10:0] dv_d, dv_r;
logic [4:0]  dv_i;
always_ff @(posedge clk) begin
    if (dv_on) begin
        logic [11:0] t;
        t = {dv_r, dv_q[26]};
        if (t >= {1'b0, dv_d}) begin dv_r <= 11'(t - {1'b0, dv_d}); dv_q <= {dv_q[25:0], 1'b1}; end
        else begin dv_r <= t[10:0]; dv_q <= {dv_q[25:0], 1'b0}; end
        dv_i <= dv_i - 5'd1;
        if (dv_i == 5'd0) dv_on <= 1'b0;
    end
    if (dv_go) begin dv_on <= 1'b1; dv_q <= dv_n; dv_r <= '0; dv_i <= 5'd26; end
    if (reset) dv_on <= 1'b0;
end

// ------------------------------------------------------------------------------------------
// the command engine
// ------------------------------------------------------------------------------------------

typedef enum logic [4:0] {
    S_IDLE, S_POP, S_DEC, S_WAIT, S_CMD, S_NEXT, S_DLX, S_DLF, S_DLEND, S_VGET, S_VPOP, S_VDEC, S_VFL,
    S_FROW, S_FNXT,
    S_OD1, S_OD2, S_OD3, S_OD4, S_OSET, S_OROW, S_OCH, S_OPX, S_ODRN, S_OCHN,
    S_CROW, S_CPX, S_CDRN, S_CNXT, S_RWIN
} st_t;
st_t st, ret;

logic [31:0] c0, c1, c2, c3;
logic [9:0]  org_x;
logic [13:0] org_y;

// display lists
logic [3:0]  depth;                     // 0: an immediate command; 1: the first list
logic [23:0] dl_wa;                     // word index (reaching 8M ends the list)
logic [12:0] dl_cnt;
logic [23:0] stk_wa [STK];
logic [12:0] stk_cnt [STK];

// fill
logic [23:0] f_d;
logic [10:0] f_w, f_h, f_j;

// object
logic        o_xf, o_yf, o_te, o_tv;
logic [1:0]  o_bl;
logic [4:0]  o_as, o_ad;                // the blend's source and destination alphas
logic [9:0]  o_ws;
logic [10:0] o_hs, o_xs, o_ys;
logic [12:0] o_xs2, o_xs3, o_xs4;       // 2, 3 and 4 times the x scale
logic [14:0] o_wd;                      // destination width and height
logic [16:0] o_hd, o_j;
logic [26:0] o_q1;
logic [16:0] o_d3;
logic [31:0] o_addr, o_fbr, o_y;
logic [31:0] o_v;
logic [25:0] o_umax;
logic [31:0] o_ub;                      // u of pixel 0 of the beat being built (signed)
logic [31:0] o_d;                       // the chunk's first destination pixel
logic [23:0] o_s;                       // the source row's first pixel
logic [9:0]  o_ns;                      // its pixels
logic [31:0] o_si;
logic        o_sbok;                    // SB holds source row o_si unchanged in VRAM since
logic [14:0] o_k0;
logic [9:0]  o_n;                       // the chunk's pixels
logic [7:0]  o_nb;                      // and beats
logic [6:0]  o_ob;
logic [3:0]  o_fm, o_lm;
logic [29:0] o_b0;                      // the chunk's first beat

// character
logic [23:0] ch_a, ch_d;
logic [4:0]  ch_j;
logic [3:0]  ch_i;
logic [15:0] ch_line;
logic [15:0] ch_col [4];
logic        ch_v;                      // a pixel for the pipeline's last stage
logic [3:0]  ch_we;
logic [15:0] ch_px;
logic [6:0]  ch_db;

// VRAM words gathered in DB: the run's first beat, a word for the pipeline's last stage, the clocks
// the queue has been empty, and an entry popped after the run, decoded once it is written
logic [21:0] wv_b0;
logic        wv_v, wv_odd;
logic [6:0]  wv_db;
logic [31:0] wv_d;
logic [4:0]  wv_t;
logic        hq_v;
logic [129:0] hq;
wire  [129:0] dq = hq_v ? hq : q_q;

// the read window
logic [22:0] rw_a;

// the pixel pipeline, a beat a clock: stage 1 the RAMs read, 2 the pixels picked, 3 blended, then
// written. Indexed by pixel q in stages 1-2, by field in 3
logic        p1_v, p2_v, p3_v;
logic [3:0]  p1_m, p2_draw;
logic [1:0]  p1_sf [4];
logic [6:0]  p1_db, p2_db, p3_db;
logic [15:0] p2_s [4], p2_d [4], p3_px [4];
logic [3:0]  p3_we;

wire [15:0] c1w_x = 16'(c1[9:0]) + (c0[28] ? 16'(org_x) : 16'd0);
wire [15:0] c1w_y = 16'(c1[23:10]) + (c0[28] ? 16'(org_y) : 16'd0);

wire [2:0] op = c0[31:29];

// object stage 0: the source pixels of the beat's four destination pixels
logic [9:0] px_p [4];
always_comb begin
    for (int q = 0; q < 4; q++) begin
        logic [31:0] u, k;
        k = (q == 0) ? 32'd0 : (q == 1) ? 32'(o_xs) : (q == 2) ? 32'(o_xs2) : 32'(o_xs3);
        u = o_xf ? o_ub - k : o_ub + k;
        px_p[q] = 10'(o_s[1:0]) + 10'(u[14:6]);
        sb_ra[q] = px_p[q][9:2];
    end
    db_ra = wr_on ? (wr_acc ? wr_o + 7'd1 : wr_o) : o_ob;
end

// the DB and SB write ports: the reader's beats, or the pipeline's
always_comb begin
    sb_we = m_rvalid && rd_d == D_SB;
    sb_wa = rd_wi;
    sb_wd = {m_rdata_hi, m_rdata};
    if (m_rvalid && rd_d == D_DB) begin
        dbf_we = 4'b1111; dbf_wa = rd_wi[6:0];
        dbf_wd[0] = m_rdata[15:0]; dbf_wd[1] = m_rdata[31:16];
        dbf_wd[2] = m_rdata_hi[15:0]; dbf_wd[3] = m_rdata_hi[31:16];
    end else begin
        dbf_we = p3_v ? p3_we : 4'b0000; dbf_wa = p3_db;
        dbf_wd = p3_px;
    end
end

function automatic logic [4:0] sat5(input logic [10:0] v);
    return (v[10:4] > 7'd31) ? 5'd31 : v[8:4];
endfunction

function automatic logic [15:0] blend(input logic [1:0] mode, input logic [15:0] s, input logic [15:0] d,
                                      input logic [4:0] as, input logic [4:0] ad);
    if (mode == 2'd0) return s;
    if (mode == 2'd3) return {s[15], d[14:0]};
    return {s[15], sat5(11'(d[14:10]) * 11'(ad) + 11'(s[14:10]) * 11'(as)),
                   sat5(11'(d[9:5])   * 11'(ad) + 11'(s[9:5])   * 11'(as)),
                   sat5(11'(d[4:0])   * 11'(ad) + 11'(s[4:0])   * 11'(as))};
endfunction

logic be_clr;

always_ff @(posedge clk) begin
    // stage 1 -> 2: each pixel picked from its beat; the destination's pixel q is field q ^ 1
    p2_v <= p1_v; p2_db <= p1_db;
    for (int q = 0; q < 4; q++) begin
        logic [15:0] s;
        s = sbq[q][16*p1_sf[q] +: 16];
        p2_s[q] <= s;
        p2_d[q] <= dbq[q ^ 1];
        p2_draw[q] <= p1_m[q] && (!o_te || s[15] == o_tv);
    end

    // stage 2 -> 3: the blend (G:752-779); mode 3 keeps the destination's colour. A character's
    // pixels come in here instead
    p3_v <= p2_v || ch_v || wv_v; p3_db <= p2_db;
    for (int q = 0; q < 4; q++) begin
        p3_we[q ^ 1] <= p2_draw[q];
        p3_px[q ^ 1] <= blend(o_bl, p2_s[q], p2_d[q], o_as, o_ad);
    end
    if (ch_v) begin
        p3_db <= ch_db; p3_we <= ch_we;
        for (int f = 0; f < 4; f++) p3_px[f] <= ch_px;
    end
    // a VRAM word: an even word is fields 1:0 of its beat, an odd one 3:2, the high half the odd field
    if (wv_v) begin
        p3_db <= wv_db; p3_we <= wv_odd ? 4'b1100 : 4'b0011;
        for (int f = 0; f < 4; f++) p3_px[f] <= (f % 2 == 1) ? wv_d[31:16] : wv_d[15:0];
    end

    // stage 3: the write (the field RAMs above), its enables and the beats written
    if (p3_v && p3_we != 4'd0) begin
        db_be[p3_db] <= db_be[p3_db] | p3_we;
        if (!tr_any || p3_db < tr_lo) tr_lo <= p3_db;
        if (!tr_any || p3_db > tr_hi) tr_hi <= p3_db;
        tr_any <= 1'b1;
    end
    if (be_clr) begin
        for (int i = 0; i < 128; i++) db_be[i] <= 4'd0;
        tr_any <= 1'b0;
    end
    if (reset) begin p2_v <= 1'b0; p3_v <= 1'b0; end
end

wire pipe_empty = !p1_v && !p2_v && !p3_v;

always_ff @(posedge clk) begin
    rd_go <= 1'b0;
    wr_go <= 1'b0;
    dv_go <= 1'b0;
    q_rd <= 1'b0;
    rw_ack <= 1'b0;
    p1_v <= 1'b0;
    ch_v <= 1'b0;
    wv_v <= 1'b0;
    be_clr <= 1'b0;

    case (st)
    S_IDLE:
        if (rd_busy || wr_busy) ;       // a reset's bursts still finishing
        else if (q_cnt != '0) begin q_rd <= 1'b1; st <= S_POP; end
        else if (rw_req && !rw_ack) begin
            rw_a <= rw_addr;
            rd_go <= 1'b1; rd_b0 <= rw_addr[22:1]; rd_n <= 9'd1; rd_dst <= D_RB;
            ret <= S_RWIN; st <= S_WAIT;
        end
    S_POP: st <= S_DEC;                 // q_q holds the entry next clock
    S_DEC: begin
        hq_v <= 1'b0;
        if (dq[129:128] == 2'd0) begin
            // a VRAM word at word index dq[54:32]: a run starts at its beat
            wv_b0 <= dq[54:33];
            wv_v <= 1'b1; wv_db <= '0; wv_odd <= dq[32]; wv_d <= dq[31:0];
            be_clr <= 1'b1;
            wv_t <= '0;
            st <= S_VGET;
        end else begin
            {c0, c1, c2, c3} <= dq[127:0];
            depth <= 4'd0;
            st <= S_CMD;
        end
    end
    S_VGET:
        if (q_cnt != '0) begin q_rd <= 1'b1; st <= S_VPOP; end
        else if (rw_req || wv_t == 5'd31) st <= S_VFL;
        else wv_t <= wv_t + 5'd1;
    S_VPOP: st <= S_VDEC;
    S_VDEC: begin
        logic [21:0] off;
        off = q_q[54:33] - wv_b0;
        if (q_q[129:128] == 2'd0 && off < 22'd128) begin
            wv_v <= 1'b1; wv_db <= off[6:0]; wv_odd <= q_q[32]; wv_d <= q_q[31:0];
            wv_t <= '0;
            // the next one popped now, decoded two clocks on
            if (q_cnt != '0) begin q_rd <= 1'b1; st <= S_VPOP; end
            else st <= S_VGET;
        end else begin
            hq <= q_q; hq_v <= 1'b1;
            st <= S_VFL;
        end
    end
    S_VFL:
        if (!wv_v && !p3_v) begin
            wr_go <= 1'b1; wr_b0 <= wv_b0 + 22'(tr_lo); wr_n <= 9'(tr_hi - tr_lo) + 9'd1;
            wr_db <= 1'b1; wr_o0 <= tr_lo;
            ret <= hq_v ? S_DEC : S_IDLE; st <= S_WAIT;
        end
    S_WAIT: if (!rd_go && !wr_go && !rd_busy && !wr_busy) st <= ret;

    S_CMD:
        case (op)
        3'd1:                           // G:965: a display list, at the word (cmd0 & 0xFFFFFF) / 2
            if (depth == 4'd0) begin
                depth <= 4'd1; dl_wa <= {1'b0, c0[23:1]}; dl_cnt <= '0; st <= S_DLX;
            end else if (depth <= 4'(STK)) begin
                stk_wa[depth - 4'd1] <= dl_wa; stk_cnt[depth - 4'd1] <= dl_cnt + 13'd1;
                depth <= depth + 4'd1; dl_wa <= {1'b0, c0[23:1]}; dl_cnt <= '0; st <= S_DLX;
            end else st <= S_NEXT;      // deeper than the stack: skipped (HACKS)
        3'd2: st <= (depth == 4'd0) ? S_NEXT : S_DLEND;
        3'd3: begin org_x <= c2[9:0]; org_y <= c3[13:0]; st <= S_NEXT; end
        3'd4: begin                     // G:713: fill
            f_d <= {c1w_y[13:0], 10'd0} + 24'(c1w_x);
            f_w <= 11'(c0[9:0]) + 11'd1;
            f_h <= 11'(c0[19:10]) + 11'd1;
            f_j <= '0;
            st <= S_FROW;
        end
        3'd5: begin                     // G:552: object
            o_xf <= c1[26]; o_yf <= c1[27]; o_bl <= c1[29:28];
            o_te <= c1[31] || c1[30]; o_tv <= !c1[31];
            o_ws <= 10'(c2[8:0]) + 10'd1;
            o_hs <= 11'(c3[9:0]) + 11'd1;
            o_xs <= c2[20:10]; o_ys <= c3[20:10];
            o_xs2 <= {1'b0, c2[20:10], 1'b0};
            o_xs3 <= {2'b0, c2[20:10]} + {1'b0, c2[20:10], 1'b0};
            o_xs4 <= {c2[20:10], 2'b0};
            o_as <= (c1[29:28] == 2'd1) ? c2[31:27] : c2[26:22];
            o_ad <= (c1[29:28] == 2'd1) ? c3[31:27] : c3[26:22];
            o_sbok <= 1'b0;
            // a zero or negative scale draws nothing (G:620, and the width or height below 1)
            if (c2[20:10] == 11'd0 || c3[20:10] == 11'd0 || c2[21] || c3[21]) st <= S_NEXT;
            else begin
                dv_go <= 1'b1; dv_n <= {1'b0, 10'(c2[8:0]) + 10'd1, 16'd0}; dv_d <= c2[20:10];
                st <= S_OD1;
            end
        end
        3'd6, 3'd7: begin               // G:771: character
            ch_a <= c0[23:0];
            ch_d <= {c1w_y[13:0], 10'd0} + 24'(c1w_x);
            ch_col[0] <= c2[31:16]; ch_col[1] <= c2[15:0]; ch_col[2] <= c3[31:16]; ch_col[3] <= c3[15:0];
            ch_j <= '0;
            st <= S_CROW;
        end
        default: st <= S_NEXT;
        endcase

    S_NEXT:
        if (depth == 4'd0) st <= S_IDLE;
        else begin dl_cnt <= dl_cnt + 13'd1; st <= S_DLX; end

    // the next entry of the list at dl_wa: two beats, three when it starts on an odd word
    S_DLX:
        if (dl_cnt < 13'h1000 && !dl_wa[23]) begin
            rd_go <= 1'b1; rd_b0 <= dl_wa[22:1]; rd_n <= dl_wa[0] ? 9'd3 : 9'd2; rd_dst <= D_RB;
            ret <= S_DLF; st <= S_WAIT;
        end else st <= S_DLEND;
    S_DLF: begin
        if (!dl_wa[0]) begin
            c0 <= rb[0][31:0]; c1 <= rb[0][63:32]; c2 <= rb[1][31:0]; c3 <= rb[1][63:32];
        end else begin
            c0 <= rb[0][63:32]; c1 <= rb[1][31:0]; c2 <= rb[1][63:32]; c3 <= rb[2][31:0];
        end
        dl_wa <= dl_wa + 24'd4;
        st <= S_CMD;
    end
    S_DLEND:
        if (depth == 4'd1) begin depth <= 4'd0; st <= S_IDLE; end
        else begin
            dl_wa <= stk_wa[depth - 4'd2]; dl_cnt <= stk_cnt[depth - 4'd2];
            depth <= depth - 4'd1;
            st <= S_DLX;
        end

    // fill: a row is a burst of the pattern beat {cmd3, cmd2} from pixel f_d
    S_FROW: begin
        logic [11:0] e;
        e = 12'(f_d[1:0]) + 12'(f_w) - 12'd1;
        wr_go <= 1'b1; wr_b0 <= f_d[23:2]; wr_n <= 9'(e[11:2] + 10'd1); wr_db <= 1'b0;
        wr_pat <= {c3, c2};
        wr_bf <= pm2be(from_q(f_d[1:0])); wr_bl <= pm2be(upto_q(e[1:0]));
        ret <= S_FNXT; st <= S_WAIT;
    end
    S_FNXT: begin
        f_d <= f_d + 24'd1024;
        f_j <= f_j + 11'd1;
        st <= (f_j + 11'd1 == f_h) ? S_NEXT : S_FROW;
    end

    // object: the destination size and the y flip's adjustment (G:668-697)
    S_OD1: if (!dv_go && !dv_on) begin
        o_q1 <= dv_q;
        dv_go <= 1'b1; dv_n <= {o_hs, 16'd0}; dv_d <= o_ys;
        st <= S_OD2;
    end
    S_OD2: if (!dv_go && !dv_on) begin
        // (q * 64) / 65536 in 32-bit int: a quotient of 2^25 or more wraps negative, and draws nothing
        if (o_q1[26:25] != 2'd0 || dv_q[26:25] != 2'd0 || o_q1[24:10] == 15'd0 || dv_q[24:10] == 15'd0)
            st <= S_NEXT;
        else begin
            o_wd <= o_q1[24:10];
            o_hd <= {2'd0, dv_q[24:10]};
            o_y <= 32'(c1[23:10]);
            if (o_yf) begin
                dv_go <= 1'b1; dv_n <= 27'({o_hs, 6'd0} - 17'd1); dv_d <= o_ys;
                st <= S_OD3;
            end else st <= S_OSET;
        end
    end
    S_OD3: if (!dv_go && !dv_on) begin
        o_d3 <= dv_q[16:0];
        dv_go <= 1'b1; dv_n <= 27'({o_hs - 11'd1, 6'd0}); dv_d <= o_ys;
        st <= S_OD4;
    end
    S_OD4: if (!dv_go && !dv_on) begin
        o_y <= o_y - 32'(o_d3) + 32'(dv_q[16:0]);
        st <= S_OSET;
    end
    S_OSET: begin
        logic [31:0] ax, x, y;
        ax = 32'(c0[9:0]);
        // G:683: the x flip's source column correction (an unsigned wrap below 0)
        if (o_xf && (3'd4 - 3'(c2[1:0])) <= 3'(c0[1:0])) ax = ax - 32'd4;
        x = 32'(c1[9:0]) + (c0[28] ? 32'(org_x) : 32'd0);
        y = o_y + (c0[28] ? 32'(org_y) : 32'd0);
        o_addr <= {8'd0, c0[23:10], 10'd0} | ax;
        o_fbr <= {y[21:0], 10'd0} + x;
        o_umax <= 26'(o_wd - 15'd1) * 26'(o_xs);
        o_j <= '0;
        o_v <= '0;
        st <= S_OROW;
    end
    // a destination row: its source row into SB, unless SB holds it already
    S_OROW: begin
        logic [31:0] py, si, off;
        logic [9:0]  ns;
        py = o_yf ? 32'(o_hs) - 32'd1 - 32'(o_v[31:6]) : 32'(o_v[31:6]);
        si = o_addr + {py[21:0], 10'd0};
        ns = 10'(o_umax[25:6]) + 10'd1;
        o_si <= si; o_s <= si[23:0]; o_ns <= ns;
        o_k0 <= '0;
        o_d <= o_fbr;
        // u of pixel 0 of the row's first beat, off pixels before the row's first
        off = (o_fbr[1:0] == 2'd0) ? 32'd0 : (o_fbr[1:0] == 2'd1) ? 32'(o_xs) :
              (o_fbr[1:0] == 2'd2) ? 32'(o_xs2) : 32'(o_xs3);
        o_ub <= o_xf ? 32'(o_umax) + off : 32'd0 - off;
        if (o_sbok && si == o_si) st <= S_OCH;
        else begin
            o_sbok <= 1'b1;
            rd_go <= 1'b1; rd_b0 <= si[23:2]; rd_n <= 9'((11'(si[1:0]) + 11'(ns) + 11'd3) >> 2); rd_dst <= D_SB;
            ret <= S_OCH; st <= S_WAIT;
        end
    end
    // a chunk: up to 128 beats of the row from o_d; the destination read first when blending
    S_OCH: begin
        logic [15:0] rem;
        logic [9:0]  n, e;
        rem = 16'(o_wd) - 16'(o_k0);
        n = 10'd512 - 10'(o_d[1:0]);
        if (rem < 16'(n)) n = rem[9:0];
        e = 10'(o_d[1:0]) + n - 10'd1;
        o_n <= n;
        o_nb <= 8'(e[9:2]) + 8'd1;
        o_ob <= '0;
        o_fm <= from_q(o_d[1:0]);
        o_lm <= upto_q(e[1:0]);
        o_b0 <= o_d[31:2];
        be_clr <= 1'b1;
        if (o_bl != 2'd0) begin
            rd_go <= 1'b1; rd_b0 <= o_d[23:2]; rd_n <= 9'(e[9:2]) + 9'd1; rd_dst <= D_DB;
            ret <= S_OPX; st <= S_WAIT;
        end else st <= S_OPX;
    end
    S_OPX: begin
        logic [29:0] b;
        b = o_b0 + 30'(o_ob);
        p1_v <= 1'b1;
        for (int q = 0; q < 4; q++) p1_sf[q] <= px_p[q][1:0] ^ 2'd1;
        // the beat's pixels in the chunk, below the destination bound (G:748)
        p1_m <= ((o_ob == 7'd0) ? o_fm : 4'b1111) & ((8'(o_ob) == o_nb - 8'd1) ? o_lm : 4'b1111) &
                {4{b[29:21] == 9'd0}};
        p1_db <= o_ob;
        o_ub <= o_xf ? o_ub - 32'(o_xs4) : o_ub + 32'(o_xs4);
        o_ob <= o_ob + 7'd1;
        if (8'(o_ob) == o_nb - 8'd1) st <= S_ODRN;
    end
    S_ODRN:
        if (pipe_empty) begin
            if (tr_any) begin
                wr_go <= 1'b1; wr_b0 <= 22'(o_b0 + 30'(tr_lo)); wr_n <= 9'(tr_hi - tr_lo) + 9'd1;
                wr_db <= 1'b1; wr_o0 <= tr_lo;
                ret <= S_OCHN; st <= S_WAIT;
            end else st <= S_OCHN;
        end
    S_OCHN:
        if (o_k0 + 15'(o_n) != o_wd) begin
            o_k0 <= o_k0 + 15'(o_n);
            o_d <= o_d + 32'(o_n);
            st <= S_OCH;
        end else begin
            logic [31:0] dhi;
            logic [24:0] shi;
            // the row written, o_fbr..dhi, against the source row in SB
            dhi = o_fbr + 32'(o_wd);
            shi = 25'(o_s) + 25'(o_ns);
            if (shi[24] || ($signed(o_fbr) < $signed({7'd0, shi}) && $signed({8'd0, o_s}) < $signed(dhi)))
                o_sbok <= 1'b0;
            o_j <= o_j + 17'd1;
            o_v <= o_v + 32'(o_ys);
            o_fbr <= o_fbr + 32'd1024;
            st <= (o_j + 17'd1 == o_hd) ? S_NEXT : S_OROW;
        end

    // character: a row's 2-bpp line is the pixel at ch_a (G:812-828)
    S_CROW: begin
        rd_go <= 1'b1; rd_b0 <= ch_a[23:2]; rd_n <= 9'd1; rd_dst <= D_RB;
        o_b0 <= {8'd0, ch_d[23:2]};
        be_clr <= 1'b1;
        ch_i <= '0;
        ret <= S_CPX; st <= S_WAIT;
    end
    S_CPX: begin
        logic [15:0] ln, col;
        logic [23:0] d;
        logic [1:0]  p;
        ln = (ch_i == 4'd0) ? rb[0][16*(ch_a[1:0] ^ 2'd1) +: 16] : ch_line;
        if (ch_i == 4'd0) ch_line <= ln;
        p = ln[2*(7 - ch_i[2:0]) +: 2];
        col = ch_col[p];
        d = ch_d + 24'(ch_i);
        ch_v <= 1'b1;
        ch_we <= (!c1[30] || col[15]) ? (4'b0001 << (d[1:0] ^ 2'd1)) : 4'b0000;
        ch_px <= col;
        ch_db <= d[8:2] - ch_d[8:2];
        ch_i <= ch_i + 4'd1;
        if (ch_i == 4'd7) st <= S_CDRN;
    end
    S_CDRN:
        if (ch_v || p3_v) ;
        else if (tr_any) begin
            wr_go <= 1'b1; wr_b0 <= 22'(o_b0 + 30'(tr_lo)); wr_n <= 9'(tr_hi - tr_lo) + 9'd1;
            wr_db <= 1'b1; wr_o0 <= tr_lo;
            ret <= S_CNXT; st <= S_WAIT;
        end else st <= S_CNXT;
    S_CNXT: begin
        ch_a <= ch_a + 24'd4;
        ch_d <= ch_d + 24'd1024;
        ch_j <= ch_j + 5'd1;
        st <= (ch_j + 5'd1 == (c1[24] ? 5'd16 : 5'd8)) ? S_NEXT : S_CROW;
    end

    S_RWIN: begin
        rw_data <= rw_a[0] ? rb[0][63:32] : rb[0][31:0];
        rw_ack <= 1'b1;
        st <= S_IDLE;
    end

    default: st <= S_IDLE;
    endcase

    if (reset) begin st <= S_IDLE; depth <= '0; org_x <= '0; org_y <= '0; hq_v <= 1'b0; end
end

assign idle = st == S_IDLE && q_cnt == '0 && !push && !rd_busy && !wr_busy;

// synthesis translate_off
// benches: a state held 100,000 clocks without the engine idle is reported once
int unsigned sim_same = 0;
st_t sim_st;
always_ff @(posedge clk) begin
    sim_st <= st;
    sim_same <= (st != sim_st || idle) ? 0 : sim_same + 1;
    if (sim_same == 100000)
        $display("fb_gcu: stuck in %s (ret %s): q_cnt %0d rd_iss %0d rd_rcv %0d wr_on %0d",
                 st.name(), ret.name(), q_cnt, rd_iss, rd_rcv, wr_on);
end
// synthesis translate_on
endmodule
