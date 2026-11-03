// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (c) Paul Priest
//
// The Ricoh RF5C400 as MAME models it (sound/rf5c400.cpp): 32 PCM channels at 44.1 kHz (16.9344
// MHz / 384) from the wave RAM, MAME's envelopes, volume and pan tables (fb_rf5c400_tables.svh,
// scripts/gen_rf5c400_tables.py, in fixed point where MAME uses doubles), its clean outputs at
// the 0.5 firebeat_popn routes them with (firebeat.cpp); the effect sends (outputs 2 and 3, the
// effect register) reach the speaker only on beatmania III and are left out.
//
// Registers (the 68000's 400000-400FFF, word offset addr): below 0x400 the globals rf5c400_r/w
// handle (status 0x00, channel control 0x01, the polled channel 0x08 and its position 0x09, the
// memory window 0x11-0x14; a write of 0x09 sets the address's low half, as MAME's fall-through
// does), above it the channels' (channel addr[9:5], register addr[4:0]).
//
// Each 44.1 kHz tick the channels are worked in turn: a channel-control write is held for its
// channel and applied before its next sample, where MAME applies it at the write; the 0x09
// read gives the position after the channel's last sample. Both are within a sample of MAME's.
//
// Memory (m_*): one 16-bit word of wave RAM at a time, by word address, held until m_ack, the
// samples and the 0x13/0x14 window both.

module fb_rf5c400 #(
    parameter int TICK_ADD = 1323,            // 44.1 kHz: 1323 in 2,000,000 clocks of 66.667 MHz
    parameter int TICK_MOD = 2000000
) (
    input  logic               clk,          // clk_sys, 66.667 MHz
    input  logic               reset,

    input  logic               req,          // held until ack
    input  logic               we,
    input  logic [10:0]        addr,
    input  logic [15:0]        wd,
    output logic               ack,
    output logic [15:0]        rd,

    output logic               m_req,
    output logic               m_we,
    output logic [23:0]        m_addr,
    output logic [15:0]        m_wd,
    input  logic               m_ack,
    input  logic [15:0]        m_rd,

    output logic signed [15:0] out_l, out_r,
    output logic               sample        // a clock: out_l/out_r are the new sample
);

`include "fb_rf5c400_tables.svh"

localparam logic [1:0] PH_NONE = 2'd0, PH_ATTACK = 2'd1, PH_DECAY = 2'd2, PH_RELEASE = 2'd3;
localparam logic signed [31:0] ONE = 32'sd1073741824;       // 1.0, Q2.30

function automatic logic [7:0] decode80(input logic [7:0] v);
    return v[7] ? {1'b0, v[6:0]} + 8'h1F : v;
endfunction

// x / 2^n toward zero, as MAME's double-to-int conversions
function automatic logic signed [23:0] trunc_shr(input logic signed [63:0] x, input int n);
    logic signed [63:0] y;
    y = (x < 0) ? x + ((64'sd1 <<< n) - 64'sd1) : x;
    return 24'(y >>> n);
endfunction

function automatic logic signed [15:0] sat16(input logic signed [23:0] x);
    return (x > 24'sd32767) ? 16'sd32767 : (x < -24'sd32768) ? -16'sd32768 : x[15:0];
endfunction

logic [20:0] t_acc;
logic        tick;
always_ff @(posedge clk) begin
    tick <= 1'b0;
    if (t_acc >= 21'(TICK_MOD - TICK_ADD)) begin t_acc <= t_acc - 21'(TICK_MOD - TICK_ADD); tick <= 1'b1; end
    else t_acc <= t_acc + 21'(TICK_ADD);
    if (reset) t_acc <= '0;
end

// ---------------------------------------------------------------- the 68000's side
logic        c_busy;                      // a memory-window access waiting for the port
logic        c_mreq, c_mwe;
logic        m_own_e;                     // the port's request in hand is the engine's
logic [23:0] m_addr_e;
logic [15:0] status;
logic [23:0] ext_a;
logic [15:0] ext_d;
logic [4:0]  req_ch;
logic [15:0] offs_q;

wire       c_take = req && !ack && !c_busy;
wire       c_ch   = addr[10];
wire [4:0] c_chn  = addr[9:5];
wire [4:0] c_reg  = addr[4:0];
wire       c_glob = !c_ch && c_chn == 5'd0;

always_ff @(posedge clk) begin
    ack <= 1'b0;
    if (c_take) begin
        if (!we) begin
            rd <= 16'h0000;
            if (c_glob && c_reg == 5'h00) begin rd <= status; ack <= 1'b1; end
            else if (c_glob && c_reg == 5'h09) begin rd <= offs_q; ack <= 1'b1; end
            else if (c_glob && c_reg == 5'h13) begin c_busy <= 1'b1; c_mreq <= 1'b1; c_mwe <= 1'b0; end
            else ack <= 1'b1;
        end else begin
            ack <= 1'b1;
            if (c_glob)
                case (c_reg)
                5'h00: status <= wd;
                5'h08: req_ch <= wd[4:0];
                5'h09, 5'h11: ext_a[15:0] <= wd;
                5'h12: ext_a[23:16] <= wd[7:0];
                5'h13: ext_d <= wd;
                5'h14: if (wd[1:0] == 2'b11) begin ack <= 1'b0; c_busy <= 1'b1; c_mreq <= 1'b1; c_mwe <= 1'b1; end
                default: ;
                endcase
        end
    end
    if (c_mreq && m_req && m_ack && !m_own_e) begin
        c_mreq <= 1'b0; c_busy <= 1'b0; ack <= 1'b1;
        if (!c_mwe) rd <= m_rd;
    end
    if (reset) begin c_busy <= 1'b0; c_mreq <= 1'b0; status <= '0; req_ch <= '0; end
end

// ---------------------------------------------------------------- channel registers
// written by the 68000, read by the engine at its channel (a clock late)
(* ramstyle = "M10K" *) logic [15:0] r_starth [32], r_startl [32], r_endl [32], r_endh [32],
                                     r_loopl [32], r_pan [32], r_vol [32],
                                     r_att [32], r_dec [32], r_rel [32];
(* ramstyle = "M10K" *) logic [21:0] r_step [32];
logic [4:0]  ech;
logic [15:0] q_starth, q_startl, q_endl, q_endh, q_loopl, q_pan, q_vol, q_att, q_dec, q_rel;
logic [21:0] q_step;

wire c_cw = c_take && we && c_ch;
always_ff @(posedge clk) begin if (c_cw && c_reg == 5'h00) r_starth[c_chn] <= wd; q_starth <= r_starth[ech]; end
always_ff @(posedge clk) begin if (c_cw && c_reg == 5'h01) r_startl[c_chn] <= wd; q_startl <= r_startl[ech]; end
always_ff @(posedge clk) begin if (c_cw && c_reg == 5'h02) r_step[c_chn] <= 22'({wd[12:0], 2'b00}) << wd[15:13]; q_step <= r_step[ech]; end
always_ff @(posedge clk) begin if (c_cw && c_reg == 5'h03) r_endl[c_chn]   <= wd; q_endl   <= r_endl[ech];   end
always_ff @(posedge clk) begin if (c_cw && c_reg == 5'h04) r_endh[c_chn]   <= wd; q_endh   <= r_endh[ech];   end
always_ff @(posedge clk) begin if (c_cw && c_reg == 5'h05) r_loopl[c_chn]  <= wd; q_loopl  <= r_loopl[ech];  end
always_ff @(posedge clk) begin if (c_cw && c_reg == 5'h06) r_pan[c_chn]    <= wd; q_pan    <= r_pan[ech];    end
always_ff @(posedge clk) begin if (c_cw && c_reg == 5'h08) r_vol[c_chn]    <= wd; q_vol    <= r_vol[ech];    end
always_ff @(posedge clk) begin if (c_cw && c_reg == 5'h09) r_att[c_chn]    <= wd; q_att    <= r_att[ech];    end
always_ff @(posedge clk) begin if (c_cw && c_reg == 5'h0C) r_dec[c_chn]    <= wd; q_dec    <= r_dec[ech];    end
always_ff @(posedge clk) begin if (c_cw && c_reg == 5'h0E) r_rel[c_chn]    <= wd; q_rel    <= r_rel[ech];    end

// ---------------------------------------------------------------- channel state
// { pos 24.16, phase, level Q2.30, step Q2.30 }, the engine's alone
(* ramstyle = "M10K" *) logic [105:0] s_mem [32];
(* ramstyle = "M10K" *) logic [15:0]  offs [32];          // the 0x09 read of each channel
logic [105:0] s_q, s_wd;
logic         s_we;
logic [4:0]   s_wa;
logic [15:0]  o_wd;
always_ff @(posedge clk) begin
    if (s_we) s_mem[s_wa] <= s_wd;
    s_q <= s_mem[ech];
end
always_ff @(posedge clk) begin
    if (s_we) offs[s_wa] <= o_wd;
    offs_q <= offs[req_ch];
end

// channel control writes, held for the engine: 3 key on, 2 release, 1 off
logic [1:0] pend [32];

// ---------------------------------------------------------------- the engine
typedef enum logic [3:0] { E_IDLE, E_RD, E_CMD, E_MEM, E_ENV, E_VOL, E_LVL, E_LVT, E_PAN, E_ACC, E_WB } e_t;
e_t                 e;
logic               tick_pend;
logic [39:0]        pos;
logic [1:0]         ph;
logic signed [31:0] lvl, est;
logic               e_mreq;
logic [15:0]        tmp;
logic signed [15:0] smp, s2;
logic signed [23:0] s3;
logic signed [47:0] p3;                     // s2 * lvl, rounded in E_LVT
logic signed [48:0] p_l, p_r;               // s3 * pan, rounded in E_ACC
logic signed [23:0] acc_l, acc_r;

wire [23:0] st_start = {q_starth[15:8], q_startl};
wire [23:0] st_end   = {q_endh[7:0], q_endl};
wire [23:0] st_loop  = {q_endh[15:8], q_loopl};

always_ff @(posedge clk) begin
    s_we <= 1'b0;
    sample <= 1'b0;
    if (tick) tick_pend <= 1'b1;

    case (e)
    E_IDLE:
        if (tick_pend) begin
            tick_pend <= 1'b0;
            ech <= 5'd0; acc_l <= '0; acc_r <= '0;
            e <= E_RD;
        end
    E_RD: e <= E_CMD;                       // the RAMs at ech
    E_CMD: begin
        logic [39:0]        p;
        logic [1:0]         f;
        logic signed [31:0] l, t;
        {p, f, l, t} = s_q;
        case (pend[ech])                    // rf5c400_w 0x01
        2'd3: begin
            p = {st_start, 16'd0}; f = PH_ATTACK; l = '0; t = ar_t(decode80(q_att[15:8]));
        end
        2'd2: if (f != PH_NONE) begin
            f = PH_RELEASE; t = q_rel[7] ? 32'sd0 : rr_t(decode80(q_rel[15:8]));
        end
        2'd1: begin f = PH_NONE; l = '0; t = '0; end
        default: ;
        endcase
        pend[ech] <= 2'd0;
        pos <= p; ph <= f; lvl <= l; est <= t;
        if (f == PH_NONE || st_start == st_end) e <= E_WB;
        else begin e_mreq <= 1'b1; m_addr_e <= p[39:16]; e <= E_MEM; end
    end
    E_MEM:
        if (m_req && m_ack && m_own_e) begin
            e_mreq <= 1'b0; tmp <= m_rd; e <= E_ENV;
        end
    E_ENV: begin
        // the sample as its type reads it, sign and magnitude to two's complement
        logic signed [15:0] v;
        logic signed [31:0] l;
        logic [39:0]        p;
        case (q_vol[15:14])
        2'b00: v = tmp;
        2'b01: v = {tmp[7:0], 8'h00};
        2'b10: v = {tmp[15:8], 8'h00};
        default: v = '0;
        endcase
        smp <= v[15] ? v ^ 16'h7FFF : v;
        // the envelope: the step, then the phase's limit
        l = lvl + est;
        case (ph)
        PH_ATTACK: if (l >= ONE) begin
            ph <= PH_DECAY; l = ONE;
            est <= (q_dec[7] || q_dec == 16'h0100) ? 32'sd0 : dr_t(decode80(q_dec[15:8]));
        end
        PH_DECAY, PH_RELEASE: if (l <= 32'sd0) begin ph <= PH_NONE; l = '0; est <= '0; end
        default: ;
        endcase
        lvl <= l;
        // the next position, the loop past the end
        p = pos + {18'd0, q_step};
        if (p[39:16] > st_end) begin
            p = {p[39:16] - st_loop, 16'd0};
            if (p < {st_start, 16'd0}) p = {st_start, 16'd0};
        end
        pos <= p;
        e <= E_VOL;
    end
    E_VOL: begin                            // sample *= volume_table[vol]; >> 9
        logic signed [24:0] x;
        x = smp * $signed({1'b0, vol_t(q_vol[7:0])});
        s2 <= 16'(x >>> 9);
        e <= E_LVL;
    end
    E_LVL: begin                            // * env_level, to an integer toward zero
        p3 <= s2 * lvl;
        e <= E_LVT;
    end
    E_LVT: begin
        s3 <= trunc_shr(64'(p3), 30);
        e <= E_PAN;
    end
    E_PAN: begin                            // outputs 0 and 1, each toward zero
        p_l <= s3 * $signed({1'b0, pan_t(q_pan[7:0])});
        p_r <= s3 * $signed({1'b0, pan_t(q_pan[15:8])});
        e <= E_ACC;
    end
    E_ACC: begin
        acc_l <= acc_l + trunc_shr(64'(p_l), 24);
        acc_r <= acc_r + trunc_shr(64'(p_r), 24);
        e <= E_WB;
    end
    E_WB: begin
        logic [23:0] d;
        s_we <= 1'b1; s_wa <= ech;
        s_wd <= {pos, ph, lvl, est};
        d = pos[39:16] - st_start;
        o_wd <= (ph == PH_NONE) ? 16'd0 : d[21:6];
        if (ech == 5'd31) begin
            out_l <= sat16($signed(acc_l + {23'd0, acc_l[23]}) >>> 1);    // 0.5, toward zero as MAME's .wav
            out_r <= sat16($signed(acc_r + {23'd0, acc_r[23]}) >>> 1);
            sample <= 1'b1;
            e <= E_IDLE;
        end else begin
            ech <= ech + 5'd1;
            e <= E_RD;
        end
    end
    default: e <= E_IDLE;
    endcase

    if (c_take && we && c_glob && c_reg == 5'h01)
        pend[wd[4:0]] <= (wd[6:5] == 2'b11) ? 2'd3 : (wd[6:5] == 2'b10) ? 2'd2 : 2'd1;

    if (reset) begin
        e <= E_IDLE; tick_pend <= 1'b0; e_mreq <= 1'b0; out_l <= '0; out_r <= '0;
        for (int k = 0; k < 32; k++) pend[k] <= 2'd1;
    end
end

// the memory port: a request at a time, the engine's first
always_ff @(posedge clk) begin
    if (!m_req) begin
        if (e_mreq && e == E_MEM) begin m_req <= 1'b1; m_own_e <= 1'b1; end
        else if (c_mreq)          begin m_req <= 1'b1; m_own_e <= 1'b0; end
    end else if (m_ack) m_req <= 1'b0;
    if (reset) m_req <= 1'b0;
end
assign m_we   = !m_own_e && c_mwe;
assign m_addr = m_own_e ? m_addr_e : ext_a;
assign m_wd   = ext_d;

endmodule
