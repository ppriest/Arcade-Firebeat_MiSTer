// SPDX-License-Identifier: GPL-3.0-or-later
//
// The PPC403's DMA controller as MAME runs it (ppccom.cpp:2497-2505 ppc4xx DCR writes, 2769-2818
// ppc4xx_dma_decrement_count, 2980-3085 ppc4xx_dma_exec): four channels of DMACR, DMACT, DMADA,
// DMASA, DMACC at DCR 0xC0 + 8 x channel, and DMASR at 0xE0 (a write clears the bits it sets of
// 0xFFF80070).
//
// A DMACR write with CE set starts the channel. Software memory-to-memory transfers (TM 2) of words
// (PW 2) are run, which is what ppp uses (DMACR3 0x89C00100: word, source incrementing, the GCU's
// FIFO as destination): a word from DMASA to DMADA, the addresses stepped by DAI/SAI, DMACT
// decremented, until its low half is 0; then DMASR's terminal-count bit for the channel (bit
// 31 - channel). MAME runs the transfer inside the DCR write;
// here it runs beside the CPU, busy until it ends (the GCU's status register reports it: the game
// waits for that before the next transfer). Any other mode or width, or chaining (CH), sets `bad`
// and ends at once with the terminal-count bit set (HACKS).
//
// Sources in work RAM (physical 0x00000000-0x01FFFFFF) come through firebeat_sdram's block port, a
// 32-byte block at a time; anything else through the bus port, as the destinations do. Addresses
// are physical (31 bits).
//
// The direct path (ppp's transfers): a work-RAM source, incrementing, to a GCU write port (FIFO
// 0x7E800070 or 0x7E800074) not incrementing. The words go to the GCU on g_* at up to one a clock
// while it is ready, and the next source block is fetched into a second buffer while the current
// one is used.

module fb_ppc_dma (
    input  logic         clk,
    input  logic         reset,

    input  logic         dcr_we,
    input  logic [9:0]   dcr_addr,
    input  logic [31:0]  dcr_wdata,
    output logic         dcr_hit,       // dcr_addr is one of these registers
    output logic [31:0]  dcr_rdata,

    output logic         busy,
    output logic         dport,         // the GCU port a direct-path transfer feeds
    output logic [3:0]   irq,           // channel interrupts: CIE and the channel's terminal count
    output logic         bad,           // a mode this controller does not run was started

    output logic         m_req,
    output logic [26:5]  m_addr,
    input  logic         m_ack,
    input  logic [255:0] m_rdata,

    output logic         g_we,          // the direct path: a word for GCU port g_port
    output logic         g_port,
    output logic [31:0]  g_data,
    input  logic         g_ready,

    output logic         b_req,
    output logic         b_we,
    output logic [30:0]  b_addr,
    output logic [3:0]   b_be,
    output logic [31:0]  b_wdata,
    input  logic         b_ack,
    input  logic [31:0]  b_rdata,
    input  logic [7:0]  st_a,           // [Firebeat] the state dump's register block (end of file)
    output logic [31:0] st_d,
    input  logic        st_we,
    input  logic [31:0] st_wd
);

logic [31:0] cr [4], ct [4], da [4], sa [4], cc [4];
logic [31:0] sr;

assign dcr_hit = (dcr_addr >= 10'h0C0 && dcr_addr <= 10'h0DF && dcr_addr[2:0] <= 3'd4) || dcr_addr == 10'h0E0;
always_comb begin
    logic [1:0] ch;
    ch = dcr_addr[4:3];
    dcr_rdata = 32'h0;
    if (dcr_addr == 10'h0E0) dcr_rdata = sr;
    else case (dcr_addr[2:0])
        3'd0: dcr_rdata = cr[ch];
        3'd1: dcr_rdata = ct[ch];
        3'd2: dcr_rdata = da[ch];
        3'd3: dcr_rdata = sa[ch];
        3'd4: dcr_rdata = cc[ch];
        default: ;
    endcase
end

always_comb for (int c = 0; c < 4; c++) irq[c] = cr[c][30] && (sr[31 - c] || sr[27 - c]);

// the engine
typedef enum logic [2:0] { E_IDLE, E_SRC, E_BLK, E_RD, E_WR, E_FAST } e_t;
e_t          e;
logic [1:0]  ch;
logic        blk_v;
logic [26:5] blk_a;
logic [255:0] blk;
logic [31:0] word;

wire [31:0] cur_sa = sa[ch];
wire        src_ram = cur_sa[30:25] == 6'd0;
assign busy = e != E_IDLE;

// the direct path's two block buffers and its fetch
logic [255:0] fb [2];
logic [26:5]  fa [2];
logic [1:0]   fv;
logic         f_on, f_dst;
logic [26:5]  f_addr;
wire  [26:5]  cur_blk = cur_sa[26:5];
wire  [26:5]  nxt_blk = cur_sa[26:5] + 22'd1;
wire          h0 = fv[0] && fa[0] == cur_blk, h1 = fv[1] && fa[1] == cur_blk;
wire          have_cur = h0 || h1;
wire          have_nxt = (fv[0] && fa[0] == nxt_blk) || (fv[1] && fa[1] == nxt_blk);
// words of the transfer after this block's: is the next block needed
wire  [15:0]  in_blk = 16'd8 - {13'd0, cur_sa[4:2]};
wire          need_nxt = ct[ch][15:0] > in_blk;
wire  [31:0]  fword = h0 ? fb[0][32 * cur_sa[4:2] +: 32] : fb[1][32 * cur_sa[4:2] +: 32];

assign g_we   = e == E_FAST && have_cur && g_ready;
assign g_port = da[ch][2];
assign dport  = da[ch][2];
assign g_data = fword;

assign m_req  = e == E_BLK || f_on;
assign m_addr = f_on ? f_addr : cur_sa[26:5];
assign b_req  = e == E_RD || e == E_WR;
assign b_we   = e == E_WR;
assign b_addr = (e == E_WR) ? da[ch][30:0] : cur_sa[30:0];
assign b_be   = 4'hF;
assign b_wdata = word;

always_ff @(posedge clk) begin
    case (e)
    E_IDLE: ;
    E_FAST: begin
        // fetch the current block, or the next one, into a buffer that does not hold the current
        if (!f_on) begin
            if (!have_cur) begin
                f_on <= 1'b1; f_addr <= cur_blk; f_dst <= fv[0] ? (fa[0] == nxt_blk ? 1'b1 : 1'b0) : 1'b0;
            end else if (need_nxt && !have_nxt) begin
                f_on <= 1'b1; f_addr <= nxt_blk; f_dst <= h0 ? 1'b1 : 1'b0;
            end
        end else if (m_ack) begin
            f_on <= 1'b0; fb[f_dst] <= m_rdata; fa[f_dst] <= f_addr; fv[f_dst] <= 1'b1;
        end
        if (g_we) begin
            logic [31:0] n;
            sa[ch] <= sa[ch] + 32'd4;
            n = ct[ch] - 32'd1;
            ct[ch] <= n;
            if (n[15:0] == 16'd0) begin sr[31 - ch] <= 1'b1; e <= E_IDLE; end
        end
    end
    E_SRC:
        if (!src_ram) e <= E_RD;
        else if (blk_v && blk_a == cur_sa[26:5]) begin word <= blk[32 * cur_sa[4:2] +: 32]; e <= E_WR; end
        else e <= E_BLK;
    E_BLK:
        if (m_ack) begin blk <= m_rdata; blk_a <= cur_sa[26:5]; blk_v <= 1'b1; e <= E_SRC; end
    E_RD:
        if (b_ack) begin word <= b_rdata; e <= E_WR; end
    E_WR:
        if (b_ack) begin
            logic [31:0] n;
            if (cr[ch][24]) sa[ch] <= sa[ch] + 32'd4;
            if (cr[ch][25]) da[ch] <= da[ch] + 32'd4;
            n = ct[ch] - 32'd1;
            ct[ch] <= n;
            e <= E_SRC;
            if (n[15:0] == 16'd0) begin
                sr[31 - ch] <= 1'b1;
                e <= E_IDLE;
            end
        end
    default: e <= E_IDLE;
    endcase

    if (dcr_we && dcr_hit) begin
        if (dcr_addr == 10'h0E0) sr <= sr & ~(dcr_wdata & 32'hFFF8_0070);
        else case (dcr_addr[2:0])
            3'd0: begin
                cr[dcr_addr[4:3]] <= dcr_wdata;
                if (dcr_wdata[31] && e == E_IDLE) begin
                    ch <= dcr_addr[4:3];
                    blk_v <= 1'b0;              // the source may have changed since the last transfer
                    // TM 2 (software memory-to-memory), PW 2 (word), TCE, no chaining (CH)
                    if (dcr_wdata[22:21] == 2'd2 && dcr_wdata[27:26] == 2'd2 && dcr_wdata[8] && !dcr_wdata[7]) begin
                        logic [30:0] d, sr0;
                        d = da[dcr_addr[4:3]][30:0]; sr0 = sa[dcr_addr[4:3]][30:0];
                        fv <= 2'b00; f_on <= 1'b0;
                        if (sr0[30:25] == 6'd0 && dcr_wdata[24] && !dcr_wdata[25] &&
                            (d == 31'h7E80_0070 || d == 31'h7E80_0074) && ct[dcr_addr[4:3]][15:0] != 16'd0)
                            e <= E_FAST;
                        else e <= E_SRC;
                    end
                    else begin bad <= 1'b1; sr[31 - dcr_addr[4:3]] <= 1'b1; end
                end
            end
            3'd1: ct[dcr_addr[4:3]] <= dcr_wdata;
            3'd2: da[dcr_addr[4:3]] <= dcr_wdata;
            3'd3: sa[dcr_addr[4:3]] <= dcr_wdata;
            3'd4: cc[dcr_addr[4:3]] <= dcr_wdata;
            default: ;
        endcase
    end

    if (reset) begin
        e <= E_IDLE; sr <= 32'h0; bad <= 1'b0; blk_v <= 1'b0; fv <= 2'b00; f_on <= 1'b0;
        for (int c = 0; c < 4; c++) begin cr[c] <= 32'h0; ct[c] <= 32'h0; da[c] <= 32'h0; sa[c] <= 32'h0; cc[c] <= 32'h0; end
    end
`ifdef VERILATOR  // st_lists: write
    if (st_we) case (st_a)
    8'h0: f_on <= ($bits(f_on))'(st_wd);
    8'h1: f_addr <= ($bits(f_addr))'(st_wd);
    8'h2: f_dst <= ($bits(f_dst))'(st_wd);
    8'h3: fb[0][31:0] <= ($bits(fb[0][31:0]))'(st_wd);
    8'h4: fb[0][63:32] <= ($bits(fb[0][63:32]))'(st_wd);
    8'h5: fb[0][95:64] <= ($bits(fb[0][95:64]))'(st_wd);
    8'h6: fb[0][127:96] <= ($bits(fb[0][127:96]))'(st_wd);
    8'h7: fb[0][159:128] <= ($bits(fb[0][159:128]))'(st_wd);
    8'h8: fb[0][191:160] <= ($bits(fb[0][191:160]))'(st_wd);
    8'h9: fb[0][223:192] <= ($bits(fb[0][223:192]))'(st_wd);
    8'hA: fb[0][255:224] <= ($bits(fb[0][255:224]))'(st_wd);
    8'hB: fb[1][31:0] <= ($bits(fb[1][31:0]))'(st_wd);
    8'hC: fb[1][63:32] <= ($bits(fb[1][63:32]))'(st_wd);
    8'hD: fb[1][95:64] <= ($bits(fb[1][95:64]))'(st_wd);
    8'hE: fb[1][127:96] <= ($bits(fb[1][127:96]))'(st_wd);
    8'hF: fb[1][159:128] <= ($bits(fb[1][159:128]))'(st_wd);
    8'h10: fb[1][191:160] <= ($bits(fb[1][191:160]))'(st_wd);
    8'h11: fb[1][223:192] <= ($bits(fb[1][223:192]))'(st_wd);
    8'h12: fb[1][255:224] <= ($bits(fb[1][255:224]))'(st_wd);
    8'h13: fa[0] <= ($bits(fa[0]))'(st_wd);
    8'h14: fa[1] <= ($bits(fa[1]))'(st_wd);
    8'h15: fv <= ($bits(fv))'(st_wd);
    8'h16: sa[0] <= ($bits(sa[0]))'(st_wd);
    8'h17: sa[1] <= ($bits(sa[1]))'(st_wd);
    8'h18: sa[2] <= ($bits(sa[2]))'(st_wd);
    8'h19: sa[3] <= ($bits(sa[3]))'(st_wd);
    8'h1A: ct[0] <= ($bits(ct[0]))'(st_wd);
    8'h1B: ct[1] <= ($bits(ct[1]))'(st_wd);
    8'h1C: ct[2] <= ($bits(ct[2]))'(st_wd);
    8'h1D: ct[3] <= ($bits(ct[3]))'(st_wd);
    8'h1E: sr <= ($bits(sr))'(st_wd);
    8'h1F: e <= e_t'(st_wd[3:0]);
    8'h20: word <= ($bits(word))'(st_wd);
    8'h21: blk[31:0] <= ($bits(blk[31:0]))'(st_wd);
    8'h22: blk[63:32] <= ($bits(blk[63:32]))'(st_wd);
    8'h23: blk[95:64] <= ($bits(blk[95:64]))'(st_wd);
    8'h24: blk[127:96] <= ($bits(blk[127:96]))'(st_wd);
    8'h25: blk[159:128] <= ($bits(blk[159:128]))'(st_wd);
    8'h26: blk[191:160] <= ($bits(blk[191:160]))'(st_wd);
    8'h27: blk[223:192] <= ($bits(blk[223:192]))'(st_wd);
    8'h28: blk[255:224] <= ($bits(blk[255:224]))'(st_wd);
    8'h29: blk_a <= ($bits(blk_a))'(st_wd);
    8'h2A: blk_v <= ($bits(blk_v))'(st_wd);
    8'h2B: da[0] <= ($bits(da[0]))'(st_wd);
    8'h2C: da[1] <= ($bits(da[1]))'(st_wd);
    8'h2D: da[2] <= ($bits(da[2]))'(st_wd);
    8'h2E: da[3] <= ($bits(da[3]))'(st_wd);
    8'h2F: cr[0] <= ($bits(cr[0]))'(st_wd);
    8'h30: cr[1] <= ($bits(cr[1]))'(st_wd);
    8'h31: cr[2] <= ($bits(cr[2]))'(st_wd);
    8'h32: cr[3] <= ($bits(cr[3]))'(st_wd);
    8'h33: ch <= ($bits(ch))'(st_wd);
    8'h34: bad <= ($bits(bad))'(st_wd);
    8'h35: cc[0] <= ($bits(cc[0]))'(st_wd);
    8'h36: cc[1] <= ($bits(cc[1]))'(st_wd);
    8'h37: cc[2] <= ($bits(cc[2]))'(st_wd);
    8'h38: cc[3] <= ($bits(cc[3]))'(st_wd);
    default: ;
    endcase
`endif  // st_lists: write
end

// synthesis translate_off
// benches: words sent to the GCU, starts dropped (a DMACR start while a transfer runs), register
// writes to the channel that is running, and the direct path's clocks waiting on each side
int unsigned sim_words = 0, sim_dropped = 0, sim_live = 0, sim_gcu_wait = 0, sim_src_wait = 0;
always_ff @(posedge clk) begin
    if (g_we) sim_words <= sim_words + 1;
    if (e == E_FAST && have_cur && !g_ready) sim_gcu_wait <= sim_gcu_wait + 1;
    if (e == E_FAST && !have_cur) sim_src_wait <= sim_src_wait + 1;
    if (dcr_we && dcr_hit && dcr_addr != 10'h0E0 && e != E_IDLE) begin
        if (dcr_addr[2:0] == 3'd0 && dcr_wdata[31]) sim_dropped <= sim_dropped + 1;
        if (dcr_addr[4:3] == ch) sim_live <= sim_live + 1;
    end
end
final $display("fb_ppc_dma: %0d words to the GCU, %0d starts dropped, %0d writes to the running channel; clocks waiting for the GCU %0d, for the source %0d",
               sim_words, sim_dropped, sim_live, sim_gcu_wait, sim_src_wait);
// synthesis translate_on

// st_lists: begin
// [Firebeat] The state dump's register block (docs/STATE.md), generated by scripts/st_lists.py:
// a word a register, in the order of its always_ff block; written in Verilator only.
always_comb begin
    st_d = 32'd0;
    case (st_a)
    8'h0: st_d = 32'(f_on);
    8'h1: st_d = 32'(f_addr);
    8'h2: st_d = 32'(f_dst);
    8'h3: st_d = 32'(fb[0][31:0]);
    8'h4: st_d = 32'(fb[0][63:32]);
    8'h5: st_d = 32'(fb[0][95:64]);
    8'h6: st_d = 32'(fb[0][127:96]);
    8'h7: st_d = 32'(fb[0][159:128]);
    8'h8: st_d = 32'(fb[0][191:160]);
    8'h9: st_d = 32'(fb[0][223:192]);
    8'hA: st_d = 32'(fb[0][255:224]);
    8'hB: st_d = 32'(fb[1][31:0]);
    8'hC: st_d = 32'(fb[1][63:32]);
    8'hD: st_d = 32'(fb[1][95:64]);
    8'hE: st_d = 32'(fb[1][127:96]);
    8'hF: st_d = 32'(fb[1][159:128]);
    8'h10: st_d = 32'(fb[1][191:160]);
    8'h11: st_d = 32'(fb[1][223:192]);
    8'h12: st_d = 32'(fb[1][255:224]);
    8'h13: st_d = 32'(fa[0]);
    8'h14: st_d = 32'(fa[1]);
    8'h15: st_d = 32'(fv);
    8'h16: st_d = 32'(sa[0]);
    8'h17: st_d = 32'(sa[1]);
    8'h18: st_d = 32'(sa[2]);
    8'h19: st_d = 32'(sa[3]);
    8'h1A: st_d = 32'(ct[0]);
    8'h1B: st_d = 32'(ct[1]);
    8'h1C: st_d = 32'(ct[2]);
    8'h1D: st_d = 32'(ct[3]);
    8'h1E: st_d = 32'(sr);
    8'h1F: st_d = 32'(e);
    8'h20: st_d = 32'(word);
    8'h21: st_d = 32'(blk[31:0]);
    8'h22: st_d = 32'(blk[63:32]);
    8'h23: st_d = 32'(blk[95:64]);
    8'h24: st_d = 32'(blk[127:96]);
    8'h25: st_d = 32'(blk[159:128]);
    8'h26: st_d = 32'(blk[191:160]);
    8'h27: st_d = 32'(blk[223:192]);
    8'h28: st_d = 32'(blk[255:224]);
    8'h29: st_d = 32'(blk_a);
    8'h2A: st_d = 32'(blk_v);
    8'h2B: st_d = 32'(da[0]);
    8'h2C: st_d = 32'(da[1]);
    8'h2D: st_d = 32'(da[2]);
    8'h2E: st_d = 32'(da[3]);
    8'h2F: st_d = 32'(cr[0]);
    8'h30: st_d = 32'(cr[1]);
    8'h31: st_d = 32'(cr[2]);
    8'h32: st_d = 32'(cr[3]);
    8'h33: st_d = 32'(ch);
    8'h34: st_d = 32'(bad);
    8'h35: st_d = 32'(cc[0]);
    8'h36: st_d = 32'(cc[1]);
    8'h37: st_d = 32'(cc[2]);
    8'h38: st_d = 32'(cc[3]);
    default: ;
    endcase
end
// st_lists: end

endmodule
