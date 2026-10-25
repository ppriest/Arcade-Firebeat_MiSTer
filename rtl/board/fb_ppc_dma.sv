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
    input  logic [31:0]  b_rdata
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
end

endmodule
