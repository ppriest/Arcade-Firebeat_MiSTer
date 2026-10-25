// SPDX-License-Identifier: GPL-3.0-or-later
//
// One of the PPC403GCX's caches: two ways of 2^SB sets of 16-byte lines (instruction cache: SB 9,
// 16 KB; data cache: SB 8, 8 KB; the 403GCX's geometry, its manual), LRU replacement. The data
// cache is write-back with write-allocate; a store in a write-through region (DCWR) writes the
// memory through the word port and the line if present, allocating nothing. MAME models no cache.
//
// CPU port (ppc403_core's): a request taken in a ce cycle, answered by ack no earlier than the
// next cycle, ack held until a ce cycle; the next request is taken in the clock of an ack. A hit
// is answered the clock after the request. addr is the physical byte address; cacheable comes
// from ICCR/DCCR and the memory map, wthru from DCWR.
//
// Maintenance port (the cache instructions, ppc403_core d_cop): op 1 write back the line if it is
// dirty and invalidate it (dcbf), 2 write it back and keep it clean (dcbst), 3 invalidate it
// (dcbi, icbi), 4 invalidate both ways of the line's set (dccci, iccci). Taken only between CPU
// requests; m_ack like ack.
//
// Line port: a 16-byte read (fill) or write (write-back), held until l_ack; word k of the line
// (byte address + 4k) in bits 32k+31:32k, big-endian words. Word port: an uncached access.
//
// Storage: data in four word lanes per way, each a RAM with a registered read address (so a whole
// line is read or written in a clock), tags likewise; valid, dirty and LRU bits in registers so
// that reset and set invalidation are immediate. The last data and tag writes are forwarded to the
// lookup that reads them in the same clock.

module fb_cache #(
    parameter int SB = 8                // set bits
) (
    input  logic         clk,
    input  logic         reset,
    input  logic         ce,

    input  logic         req,
    input  logic         we,
    input  logic [30:0]  addr,
    input  logic [3:0]   be,            // be[3]: the byte at (addr & ~3), bits 31:24
    input  logic [31:0]  wdata,
    input  logic         cacheable,
    input  logic         wthru,
    output logic         ack,
    output logic [31:0]  rdata,

    input  logic         m_req,
    input  logic [2:0]   m_op,
    input  logic [30:0]  m_addr,
    output logic         m_ack,

    output logic         l_req,
    output logic         l_we,
    output logic [30:4]  l_addr,
    output logic [127:0] l_wdata,
    input  logic         l_ack,
    input  logic [127:0] l_rdata,

    output logic         u_req,
    output logic         u_we,
    output logic [30:0]  u_addr,
    output logic [3:0]   u_be,
    output logic [31:0]  u_wdata,
    input  logic         u_ack,
    input  logic [31:0]  u_rdata
);

localparam int NS = 1 << SB;
localparam int TW = 27 - SB;            // tag: addr[30:SB+4]

typedef enum logic [3:0] {
    C_IDLE, C_LOOK, C_WB, C_FILL, C_UNC, C_DONE, C_MLOOK, C_MWB, C_MDONE
} c_t;
c_t c;

// ---------------------------------------------------------------- storage
logic [SB-1:0]  ra;                     // the read address (set), a register
logic [SB-1:0]  ra_n;
logic [TW-1:0]  tq [2];
logic [127:0]   dq [2];
logic [NS-1:0]  v [2], dt [2];
logic [NS-1:0]  lru;                    // the way to replace next

// writes, decided combinationally by the state machine
logic           tw_en;
logic           tw_way;
logic [SB-1:0]  tw_set;
logic [TW-1:0]  tw_tag;
logic [1:0]     dw_way;                 // one-hot
logic [SB-1:0]  dw_set;
logic [15:0]    dw_be;                  // per byte of the line, lane 0 in [3:0]
logic [127:0]   dw_data;

genvar gw, gl;
generate for (gw = 0; gw < 2; gw++) begin : g_way
    logic [TW-1:0] tmem [NS];
    always_ff @(posedge clk) if (tw_en && tw_way == gw) tmem[tw_set] <= tw_tag;
    assign tq[gw] = tmem[ra];
    for (gl = 0; gl < 4; gl++) begin : g_lane
        logic [3:0][7:0] dmem [NS];
        always_ff @(posedge clk)
            if (dw_way[gw])
                for (int b = 0; b < 4; b++)
                    if (dw_be[4*gl + b]) dmem[dw_set][b] <= dw_data[32*gl + 8*b +: 8];
        assign dq[gw][32*gl +: 32] = dmem[ra];
    end
end endgenerate

always_ff @(posedge clk) ra <= ra_n;

// the last writes, forwarded to a lookup of the same set
logic           ft_v, ft_way;
logic [SB-1:0]  ft_set;
logic [TW-1:0]  ft_tag;
logic [1:0]     fd_way;
logic [SB-1:0]  fd_set;
logic [15:0]    fd_be;
logic [127:0]   fd_data;
always_ff @(posedge clk) begin
    if (tw_en) begin ft_v <= 1'b1; ft_way <= tw_way; ft_set <= tw_set; ft_tag <= tw_tag; end
    if (dw_way != 2'b00) begin fd_way <= dw_way; fd_set <= dw_set; fd_be <= dw_be; fd_data <= dw_data; end
    if (reset) begin ft_v <= 1'b0; fd_way <= 2'b00; end
end

logic [TW-1:0]  tag_r [2];
logic [127:0]   line_r [2];
always_comb for (int w = 0; w < 2; w++) begin
    tag_r[w] = (ft_v && ft_way == w && ft_set == ra) ? ft_tag : tq[w];
    line_r[w] = dq[w];
    if (fd_way[w] && fd_set == ra)
        for (int b = 0; b < 16; b++) if (fd_be[b]) line_r[w][8*b +: 8] = fd_data[8*b +: 8];
end

// ---------------------------------------------------------------- the request in hand
logic           r_we, r_wthru;
logic [30:0]    r_addr;
logic [3:0]     r_be;
logic [31:0]    r_wdata;
logic [2:0]     r_op;
wire  [SB-1:0]  r_set = r_addr[SB+3:4];
wire  [TW-1:0]  r_tag = r_addr[30:SB+4];
wire  [1:0]     r_lane = r_addr[3:2];

wire  [1:0]     hit_w = {v[1][ra] && tag_r[1] == r_tag, v[0][ra] && tag_r[0] == r_tag};
wire            hit = hit_w != 2'b00;
wire            hway = hit_w[1];
wire  [127:0]   hline = line_r[hway];
// the way a fill replaces: an invalid one first
wire            vway = !v[0][ra] ? 1'b0 : !v[1][ra] ? 1'b1 : lru[ra];

function automatic logic [15:0] lane_be(input logic [1:0] lane, input logic [3:0] b);
    // be[3] is the word's byte 0 (bits 31:24): the line's byte 4*lane + 3 in little-endian bit order
    logic [15:0] m;
    m = '0;
    m[4*lane +: 4] = b;
    return m;
endfunction

logic [127:0]   wb_line;                // the line being written back
logic [30:4]    wb_addr;
logic [31:0]    rd_hold;
logic           fill_way;

// a CPU request can be taken: idle, or answering the last
wire answering = (c == C_LOOK && ce && hit && !(r_we && r_wthru)) || (c == C_DONE && ce);
// The core counts a request as issued in the clock it is high: one the cache cannot take then (a
// maintenance request goes first, or back-to-back fetches would never leave the cache idle for it)
// is held here.
logic        p_v, p_we, p_cacheable, p_wthru;
logic [30:0] p_addr;
logic [3:0]  p_be;
logic [31:0] p_wdata;
wire         in_req = p_v || (ce && req);
wire         in_we = p_v ? p_we : we;
wire  [30:0] in_addr = p_v ? p_addr : addr;
wire  [3:0]  in_be = p_v ? p_be : be;
wire  [31:0] in_wdata = p_v ? p_wdata : wdata;
wire         in_cacheable = p_v ? p_cacheable : cacheable;
wire         in_wthru = p_v ? p_wthru : wthru;
wire take = ce && in_req && (c == C_IDLE || answering) && !m_req;
wire m_take = ce && m_req && c == C_IDLE;

assign ack   = answering;
assign rdata = (c == C_DONE) ? rd_hold : hline[32*r_lane +: 32];
assign m_ack = (c == C_MDONE) && ce;

assign l_addr  = (c == C_WB || c == C_MWB) ? wb_addr : r_addr[30:4];
assign l_we    = (c == C_WB || c == C_MWB);
assign l_wdata = wb_line;
assign l_req   = c == C_WB || c == C_MWB || c == C_FILL;

assign u_req   = c == C_UNC;
assign u_we    = r_we;
assign u_addr  = r_addr;
assign u_be    = r_be;
assign u_wdata = r_wdata;

always_comb begin
    ra_n = ra;
    if (take) ra_n = in_addr[SB+3:4];
    else if (m_take) ra_n = m_addr[SB+3:4];

    tw_en = 1'b0; tw_way = 1'b0; tw_set = r_set; tw_tag = r_tag;
    dw_way = 2'b00; dw_set = r_set; dw_be = '0; dw_data = {4{r_wdata}};
    case (c)
    C_LOOK:
        // a store hit: the lane's bytes (write-through too: the memory write follows)
        if (hit && r_we) begin
            dw_way = hit_w; dw_be = lane_be(r_lane, r_be);
        end
    C_FILL:
        if (l_ack) begin
            tw_en = 1'b1; tw_way = fill_way;
            dw_way = fill_way ? 2'b10 : 2'b01; dw_be = '1; dw_data = l_rdata;
            if (r_we)                   // the store that missed, over the line
                for (int b = 0; b < 4; b++)
                    if (r_be[3 - b]) dw_data[32*r_lane + 8*(3 - b) +: 8] = r_wdata[8*(3 - b) +: 8];
        end
    default: ;
    endcase
end

always_ff @(posedge clk) begin
    case (c)
    C_IDLE: ;
    C_LOOK:
        if (hit) begin
            lru[ra] <= !hway;
            if (r_we && r_wthru) c <= C_UNC;
            else begin
                if (r_we) dt[hway][ra] <= 1'b1;
                if (ce) c <= C_IDLE;            // a request taken now overrides below
            end
        end else if (r_we && r_wthru) c <= C_UNC;
        else begin
            fill_way <= vway;
            wb_line <= line_r[vway];
            wb_addr <= {tag_r[vway], r_set};
            c <= (v[vway][ra] && dt[vway][ra]) ? C_WB : C_FILL;
        end
    C_WB: if (l_ack) c <= C_FILL;
    C_FILL:
        if (l_ack) begin
            v[fill_way][r_set] <= 1'b1;
            dt[fill_way][r_set] <= r_we;
            lru[r_set] <= !fill_way;
            rd_hold <= l_rdata[32*r_lane +: 32];
            c <= C_DONE;
        end
    C_UNC:
        if (u_ack) begin rd_hold <= u_rdata; c <= C_DONE; end
    C_DONE: if (ce) c <= C_IDLE;
    C_MLOOK: begin
        case (r_op)
        3'd4: begin v[0][ra] <= 1'b0; v[1][ra] <= 1'b0; c <= C_MDONE; end
        3'd3: begin if (hit) v[hway][ra] <= 1'b0; c <= C_MDONE; end
        default:                        // 1 flush, 2 store
            if (hit && dt[hway][ra]) begin
                wb_line <= hline; wb_addr <= r_addr[30:4]; fill_way <= hway; c <= C_MWB;
            end else begin
                if (hit && r_op == 3'd1) v[hway][ra] <= 1'b0;
                c <= C_MDONE;
            end
        endcase
    end
    C_MWB:
        if (l_ack) begin
            dt[fill_way][r_set] <= 1'b0;
            if (r_op == 3'd1) v[fill_way][r_set] <= 1'b0;
            c <= C_MDONE;
        end
    C_MDONE: if (ce) c <= C_IDLE;
    default: c <= C_IDLE;
    endcase

    if (take) begin
        r_we <= in_we; r_addr <= in_addr; r_be <= in_be; r_wdata <= in_wdata; r_wthru <= in_wthru;
        c <= in_cacheable ? C_LOOK : C_UNC;
        p_v <= 1'b0;
    end else if (ce && req && !p_v) begin
        p_v <= 1'b1; p_we <= we; p_addr <= addr; p_be <= be; p_wdata <= wdata;
        p_cacheable <= cacheable; p_wthru <= wthru;
    end
    if (m_take) begin
        r_addr <= m_addr; r_op <= m_op; r_we <= 1'b0;
        c <= C_MLOOK;
    end

    if (reset) begin
        c <= C_IDLE; p_v <= 1'b0;
        v[0] <= '0; v[1] <= '0; dt[0] <= '0; dt[1] <= '0; lru <= '0;
    end
end

endmodule
