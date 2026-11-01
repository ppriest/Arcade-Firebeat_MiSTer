// SPDX-License-Identifier: GPL-3.0-or-later
//
// YMZ280B (0x7D000400-0x7D000401) from MAME's devices/sound/ymz280b.cpp: the register interface,
// the external memory readback (registers 84-86, offset 0 read) and the eight voices: 4-bit
// ADPCM, 8- and 16-bit PCM, loop, key on/off, level and pan, and the status register (bit v set
// when voice v reaches its stop address, cleared by reading it). No IRQ: firebeat's
// sound_irq_callback is empty. Register 87 writes nothing (ymz280b_map has no write,
// firebeat.cpp:804-808).
//
// MAME's stream runs at clock / 192 (88.2 kHz) and so does this. On each tick every voice in
// turn takes its next decoded sample if its 9-bit fraction has reached 512, outputs
// (prev * (512 - pos) + curr * pos) >> 9, and adds fnum + 1 to the fraction (at most 512, so at
// most one new sample a tick). Each voice adds interp * level / 2 per side, and the sums >> 8
// are MAME's 16-bit output (add_int with 32768 * 256 full scale). out_l/out_r are the chip's
// outputs 0 and 1. A sample is decoded when it is needed, where MAME decodes a stream update's
// worth ahead (docs/HACKS.md).
//
// The external memory is the two sound flash chips (fb_flash port y), shared by the voices and
// the readback. A host access waits while the voices run or a readback refill is open, so the
// voices change only between ticks.

module fb_ymz280b #(
    parameter int TICK_ADD = 1323,      // the sample tick is clk * TICK_ADD / TICK_MOD
    parameter int TICK_MOD = 1000000
) (
    input  logic        clk,            // 66.667 MHz
    input  logic        reset,

    input  logic        req,            // a byte access, held until ack
    input  logic        we,
    input  logic        a0,
    input  logic [7:0]  wdata,
    output logic        ack,
    output logic [7:0]  rdata,

    output logic        y_req,
    output logic [21:0] y_addr,
    input  logic        y_ack,
    input  logic [7:0]  y_rdata,

    output logic signed [15:0] out_l,   // MAME's outputs 0 and 1, new each tick
    output logic signed [15:0] out_r,
    output logic        tick,           // 88.2 kHz

    output logic [7:0]  reg_q,          // register reg_a as last written (the state dump)
    input  logic [7:0]  reg_a
);

// 88.2 kHz = 66.667 MHz * 1323 / 1,000,000
logic [19:0] t_acc;
always_ff @(posedge clk) begin
    tick <= 1'b0;
    if (t_acc >= 20'(TICK_MOD - TICK_ADD)) begin t_acc <= t_acc - 20'(TICK_MOD - TICK_ADD); tick <= 1'b1; end
    else t_acc <= t_acc + 20'(TICK_ADD);
    if (reset) t_acc <= '0;
end

logic [7:0]  regs [256];
always_ff @(posedge clk) reg_q <= regs[reg_a];

logic [7:0]  cur, status;
logic        keyon_en, ext_en;
logic [7:0]  ext_hi, ext_mid, latch;
logic [23:0] ea;
logic        rb_pend;                   // a readback refill is open on port y

// the voices (addresses in nibbles)
logic [8:0]  fnum     [8];
logic        looping  [8];
logic [1:0]  mode     [8];
logic        keyon    [8];
logic        playing  [8];
logic        decaying [8];              // past the stop address: ramping to 0
logic [7:0]  level    [8];
logic [3:0]  pan      [8];
logic [7:0]  vol_l    [8], vol_r [8];   // output_left/right
logic [24:0] start    [8], stop [8], lstart [8], lend [8], pos [8];
logic signed [15:0] sig [8], lsig [8];  // the ADPCM signal, and as saved at the loop start
logic [14:0] stp      [8], lstp [8];    // the ADPCM step
logic        looped   [8];              // loop_count != 0
logic [9:0]  frac     [8];              // output_pos
logic signed [15:0] prev [8], curr [8];
logic [7:0]  cache    [8];              // the ADPCM byte of the last even nibble
logic        cache_ok [8];

// level * n / 7 for n <= 7: x * 9363 >> 16 is x / 7 for x < 13,107
function automatic logic [7:0] div7(input logic [7:0] lv, input logic [2:0] n);
    logic [24:0] p;
    p = 25'({3'd0, lv} * n) * 25'd9363;
    return p[23:16];
endfunction

// update_volumes: {left, right}
function automatic logic [15:0] volumes(input logic [7:0] lv, input logic [3:0] pn);
    if (pn == 4'd8) return {lv, lv};
    if (pn < 4'd8) return {lv, (pn == 4'd0) ? 8'd0 : div7(lv, 3'(pn - 4'd1))};
    return {div7(lv, 3'(4'd15 - pn)), lv};
endfunction

function automatic logic [9:0] iscale(input logic [2:0] i);
    case (i)
    3'd4: return 10'h133;
    3'd5: return 10'h199;
    3'd6: return 10'h200;
    3'd7: return 10'h266;
    default: return 10'h0E6;
    endcase
endfunction

// C's x / 2 and x / 8, rounding toward zero
function automatic logic signed [26:0] half(input logic signed [26:0] x);
    return (x + (x[26] ? 27'sd1 : 27'sd0)) >>> 1;
endfunction
function automatic logic signed [21:0] eighth(input logic signed [21:0] x);
    return (x + (x[21] ? 22'sd7 : 22'sd0)) >>> 3;
endfunction

function automatic logic signed [15:0] sat16(input logic signed [26:0] x);
    if (x > 27'sd32767) return 16'sd32767;
    if (x < -27'sd32768) return -16'sd32768;
    return x[15:0];
endfunction

// ---- the engine
typedef enum logic [3:0] {
    E_IDLE, E_LOAD, E_DEC, E_FETCH, E_FETCH_HI, E_MUL, E_STEP, E_PUSH, E_INTERP, E_LERP, E_LEFT,
    E_RIGHT, E_ACC, E_OUT
} e_t;
e_t          e;
logic        t_pend;
logic [2:0]  v;
logic signed [26:0] acc_l, acc_r;
logic [7:0]  b0, b1;                    // fetched bytes (PCM16: low, high)
logic        hi;                        // the PCM16 high byte is being fetched
logic signed [15:0] smp;
logic signed [16:0] interp;
logic signed [26:0] m;
logic signed [21:0] dprod;              // step * diff
logic [24:0] sprod;                     // step * index_scale

// voice v's next sample, position and ADPCM state, from the fetched bytes and the products
wire  [3:0]  nib = pos[v][0] ? b0[3:0] : b0[7:4];
wire  signed [5:0] dif = nib[3] ? -$signed({2'b0, nib[2:0], 1'b1}) : $signed({2'b0, nib[2:0], 1'b1});
logic signed [21:0] ns;
logic signed [15:0] s_ad, n_sig, n_lsig, n_smp;
logic [14:0] st_ad, n_stp, n_lstp;
logic [24:0] np;
logic        n_looped, n_jump, n_end;
always_comb begin
    ns = 22'(sig[v]) + eighth(dprod);
    s_ad = (ns > 22'sd32767) ? 16'sd32767 : (ns < -22'sd32768) ? -16'sd32768 : ns[15:0];
    st_ad = (sprod[24:8] > 17'h6000) ? 15'h6000 : (sprod[24:8] < 17'h7F) ? 15'h7F : sprod[22:8];
    case (mode[v])
    2'd1: begin n_smp = s_ad; np = pos[v] + 25'd1; end
    2'd2: begin n_smp = {b0, 8'd0}; np = pos[v] + 25'd2; end
    default: begin n_smp = {b1, b0}; np = pos[v] + 25'd4; end
    endcase
    n_sig = s_ad; n_stp = st_ad; n_lsig = lsig[v]; n_lstp = lstp[v]; n_looped = looped[v];
    n_jump = 1'b0;
    if (looping[v]) begin
        if (mode[v] == 2'd1 && np == lstart[v] && !looped[v]) begin n_lsig = s_ad; n_lstp = st_ad; end
        if (np >= lend[v] && keyon[v]) begin
            np = lstart[v]; n_sig = n_lsig; n_stp = n_lstp; n_looped = 1'b1; n_jump = 1'b1;
        end
    end
    n_end = np >= stop[v];
end

// the decay after the stop address: t * 15 >> 4 on the magnitude (C's rounding toward zero)
wire signed [20:0] c21 = {{5{curr[v][15]}}, curr[v]};
wire        [20:0] c_mag = c21[20] ? 21'd0 - c21 : c21;
wire        [20:0] c_dec = (c_mag * 21'd15) >> 4;
wire signed [20:0] dec21 = c21[20] ? $signed(21'd0 - c_dec) : $signed(c_dec);
wire signed [15:0] dec_smp = dec21[15:0];

wire busy = e != E_IDLE;
wire [2:0]  wv = cur[4:2];
wire [15:0] w_vol = volumes(wdata, pan[wv]);
wire [15:0] p_vol = volumes(level[wv], wdata[3:0]);
wire        w_kon = wdata[7] && wdata[6:5] != 2'd0;     // mode 0 is written as key off

always_ff @(posedge clk) begin
    ack <= 1'b0;
    if (tick) t_pend <= 1'b1;

    if (y_req && y_ack) begin
        y_req <= 1'b0;
        if (rb_pend) begin latch <= y_rdata; rb_pend <= 1'b0; end
    end

    // ---- host accesses, between the voices' runs
    if (req && !ack && !busy && !t_pend && !y_req) begin
        ack <= 1'b1;
        if (we) begin
            if (!a0) cur <= wdata;
            else begin
                regs[cur] <= wdata;
                if (!cur[7]) case ({cur[6:5], cur[1:0]})
                4'b00_00: fnum[wv][7:0] <= wdata;
                4'b00_01: begin
                    fnum[wv][8] <= wdata[0];
                    looping[wv] <= wdata[4];
                    if (wdata[6:5] != 2'd0) mode[wv] <= wdata[6:5];
                    if (!keyon[wv] && w_kon && keyon_en) begin
                        playing[wv] <= 1'b1; decaying[wv] <= 1'b0;
                        pos[wv] <= start[wv];
                        sig[wv] <= '0; lsig[wv] <= '0;
                        stp[wv] <= 15'h7F; lstp[wv] <= 15'h7F;
                        looped[wv] <= 1'b0; cache_ok[wv] <= 1'b0;
                    end else if (keyon[wv] && !w_kon) begin
                        playing[wv] <= 1'b0; decaying[wv] <= 1'b0;
                    end
                    keyon[wv] <= w_kon;
                end
                4'b00_10: begin level[wv] <= wdata; {vol_l[wv], vol_r[wv]} <= w_vol; end
                4'b00_11: begin pan[wv] <= wdata[3:0]; {vol_l[wv], vol_r[wv]} <= p_vol; end
                4'b01_00: start[wv][24:17]  <= wdata;
                4'b01_01: lstart[wv][24:17] <= wdata;
                4'b01_10: lend[wv][24:17]   <= wdata;
                4'b01_11: stop[wv][24:17]   <= wdata;
                4'b10_00: start[wv][16:9]   <= wdata;
                4'b10_01: lstart[wv][16:9]  <= wdata;
                4'b10_10: lend[wv][16:9]    <= wdata;
                4'b10_11: stop[wv][16:9]    <= wdata;
                4'b11_00: start[wv][8:1]    <= wdata;
                4'b11_01: lstart[wv][8:1]   <= wdata;
                4'b11_10: lend[wv][8:1]     <= wdata;
                4'b11_11: stop[wv][8:1]     <= wdata;
                endcase
                else case (cur)
                8'h84: ext_hi <= wdata;
                8'h85: ext_mid <= wdata;
                8'h86: begin
                    ea <= {ext_hi, ext_mid, wdata};
                    if (ext_en) begin y_req <= 1'b1; rb_pend <= 1'b1; y_addr <= {ext_hi[5:0], ext_mid, wdata}; end
                end
                8'h87: if (ext_en) ea <= ea + 24'd1;
                8'hFF: begin
                    ext_en <= wdata[6];
                    for (int i = 0; i < 8; i++) begin
                        if (keyon_en && !wdata[7]) begin playing[i] <= 1'b0; decaying[i] <= 1'b0; end
                        if (!keyon_en && wdata[7] && keyon[i] && looping[i]) playing[i] <= 1'b1;
                    end
                    keyon_en <= wdata[7];
                end
                default: ;
                endcase
            end
        end else if (!a0) begin
            if (!ext_en) rdata <= 8'hFF;
            else begin
                rdata <= latch;
                y_req <= 1'b1; rb_pend <= 1'b1; y_addr <= ea[21:0]; ea <= ea + 24'd1;
            end
        end else begin
            rdata <= status;
            status <= 8'h00;
        end
    end

    // ---- the voices, once a tick
    case (e)
    E_IDLE:
        if (t_pend && !y_req) begin
            t_pend <= 1'b0; v <= 3'd0; acc_l <= '0; acc_r <= '0; e <= E_LOAD;
        end
    E_LOAD:
        if (!playing[v] && prev[v] == 16'sd0 && curr[v] == 16'sd0) begin
            frac[v] <= 10'd512; e <= (v == 3'd7) ? E_OUT : E_LOAD; v <= v + 3'd1;
        end else if (frac[v] >= 10'd512) begin
            frac[v] <= frac[v] - 10'd512; e <= E_DEC;
        end else e <= E_INTERP;
    E_DEC:
        if (!playing[v]) begin
            // after the stop address MAME ramps the last sample down by 15/16 a sample
            if (decaying[v]) smp <= dec_smp;
            else smp <= '0;
            e <= E_PUSH;
        end else if (mode[v] == 2'd1 && pos[v][0] && cache_ok[v]) begin
            b0 <= cache[v]; e <= E_MUL;
        end else begin
            hi <= 1'b0; y_req <= 1'b1; y_addr <= pos[v][22:1]; e <= E_FETCH;
        end
    E_FETCH:
        if (y_req && y_ack) begin
            if (hi) b1 <= y_rdata; else b0 <= y_rdata;
            e <= (mode[v] == 2'd3 && !hi) ? E_FETCH_HI : E_MUL;
        end
    E_FETCH_HI: begin
        hi <= 1'b1; y_req <= 1'b1; y_addr <= pos[v][22:1] + 22'd1; e <= E_FETCH;
    end
    E_MUL: begin
        dprod <= $signed({7'd0, stp[v]}) * 22'(dif);
        sprod <= 25'(stp[v]) * 25'(iscale(nib[2:0]));
        if (mode[v] == 2'd1 && !pos[v][0]) begin cache[v] <= b0; cache_ok[v] <= 1'b1; end
        e <= E_STEP;
    end
    E_STEP: begin
        pos[v] <= np;
        if (mode[v] == 2'd1) begin
            sig[v] <= n_sig; stp[v] <= n_stp; lsig[v] <= n_lsig; lstp[v] <= n_lstp;
        end
        looped[v] <= n_looped;
        if (n_jump) cache_ok[v] <= 1'b0;
        if (n_end) begin playing[v] <= 1'b0; decaying[v] <= 1'b1; status[v] <= 1'b1; end
        smp <= n_smp;
        e <= E_PUSH;
    end
    E_PUSH: begin
        prev[v] <= curr[v]; curr[v] <= smp; e <= E_INTERP;
    end
    E_INTERP: begin
        m <= (27'(curr[v]) - 27'(prev[v])) * $signed({17'd0, frac[v]});
        e <= E_LERP;
    end
    E_LERP: begin
        interp <= 17'(((27'(prev[v]) <<< 9) + m) >>> 9);
        frac[v] <= frac[v] + 10'(mode[v] == 2'd1 ? {1'b0, fnum[v][7:0]} : fnum[v]) + 10'd1;
        e <= E_LEFT;
    end
    E_LEFT: begin
        m <= 27'(interp) * $signed({19'd0, vol_l[v]});
        e <= E_RIGHT;
    end
    E_RIGHT: begin
        acc_l <= acc_l + half(m);
        m <= 27'(interp) * $signed({19'd0, vol_r[v]});
        e <= E_ACC;
    end
    E_ACC: begin
        acc_r <= acc_r + half(m);
        e <= (v == 3'd7) ? E_OUT : E_LOAD;
        v <= v + 3'd1;
    end
    E_OUT: begin
        out_l <= sat16(acc_l >>> 8);
        out_r <= sat16(acc_r >>> 8);
        e <= E_IDLE;
    end
    default: e <= E_IDLE;
    endcase

    if (reset) begin
        y_req <= 1'b0; rb_pend <= 1'b0; ext_en <= 1'b0; keyon_en <= 1'b0; ea <= '0; cur <= 8'h00;
        status <= 8'h00; e <= E_IDLE; t_pend <= 1'b0; out_l <= '0; out_r <= '0;
        for (int i = 0; i < 8; i++) begin
            fnum[i] <= '0; looping[i] <= 1'b0; mode[i] <= '0; keyon[i] <= 1'b0; playing[i] <= 1'b0;
            decaying[i] <= 1'b0; level[i] <= '0; pan[i] <= '0; vol_l[i] <= '0; vol_r[i] <= '0;
            start[i] <= '0; stop[i] <= '0; lstart[i] <= '0; lend[i] <= '0; pos[i] <= '0;
            sig[i] <= '0; lsig[i] <= '0; stp[i] <= 15'h7F; lstp[i] <= 15'h7F; looped[i] <= 1'b0;
            frac[i] <= 10'd512; prev[i] <= '0; curr[i] <= '0; cache_ok[i] <= 1'b0;
        end
    end
end

endmodule
