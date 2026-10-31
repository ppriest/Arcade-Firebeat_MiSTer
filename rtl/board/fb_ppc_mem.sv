// SPDX-License-Identifier: GPL-3.0-or-later
//
// The PPC403GCX's memory side: the instruction cache (16 KB) and data cache (8 KB) of
// rtl/board/fb_cache.sv between ppc403_core's ports and the board.
//
// A region is cached when its ICCR/DCCR bit is set (bit 31 the 128 MB at 0x00000000; ppp's start-up
// code sets 0x0000FFFF, the upper 2 GB: the work RAM alias at 0x80000000 and the BIOS) and it is
// memory: work RAM (physical 0x00000000-0x01FFFFFF) or the BIOS (0x7FF80000-0x7FFFFFFF). Everything
// else, and memory through an uncached region, goes through the word port.
//
// Cache instructions (ppc403_core d_cop): dcbf, dcbst, dcbi, dccci to the data cache's
// maintenance port, icbi and iccci to the instruction cache's.
//
// [Firebeat] flush (the state dump, with the CPU stopped at an instruction boundary): every dirty
// line of the data cache is written back, set by set, lines kept valid and clean; flushed is high
// from the last write-back until flush drops. The data cache runs without ce for it.
//
// Line port: firebeat_sdram's cache port (16-byte lines at SDRAM addresses: work RAM at 0, the BIOS
// at 0x2800000). Word port: physical byte addresses, for the board's decode.

module fb_ppc_mem (
    input  logic         clk,
    input  logic         reset,
    input  logic         ce,

    input  logic         i_req,
    input  logic [30:0]  i_addr,
    input  logic         i_a31,
    output logic         i_ack,
    output logic [31:0]  i_rdata,

    input  logic         d_req,
    input  logic         d_we,
    input  logic [30:0]  d_addr,
    input  logic         d_a31,
    input  logic [3:0]   d_be,
    input  logic [31:0]  d_wdata,
    input  logic [2:0]   d_cop,
    output logic         d_ack,
    output logic [31:0]  d_rdata,

    input  logic         flush,
    output logic         flushed,

    input  logic [31:0]  iccr,
    input  logic [31:0]  dccr,
    input  logic [31:0]  dcwr,

    output logic         c_req,
    output logic         c_we,
    output logic [26:4]  c_addr,
    output logic [127:0] c_wdata,
    input  logic         c_ack,
    input  logic [127:0] c_rdata,

    output logic         u_req,
    output logic         u_we,
    output logic [30:0]  u_addr,
    output logic [3:0]   u_be,
    output logic [31:0]  u_wdata,
    input  logic         u_ack,
    input  logic [31:0]  u_rdata
);

function automatic logic is_mem(input logic [30:0] a);
    return a[30:25] == 6'd0 || a[30:19] == 12'hFFF;
endfunction

function automatic logic [26:4] sd_line(input logic [30:4] a);
    return a[30] ? {4'b0101, 4'b0000, a[18:4]} : {2'b00, a[24:4]};
endfunction

// region bits: bit 31 is the region at address 0
wire [4:0] ireg = {i_a31, i_addr[30:27]};
wire [4:0] dreg = {d_a31, d_addr[30:27]};

// ---------------------------------------------------------------- the caches
logic         ic_l_req, ic_l_we, dc_l_req, dc_l_we;
logic [30:4]  ic_l_addr, dc_l_addr;
logic [127:0] ic_l_wdata, dc_l_wdata;
logic         ic_l_ack, dc_l_ack;
logic         ic_u_req, ic_u_we, dc_u_req, dc_u_we;
logic [30:0]  ic_u_addr, dc_u_addr;
logic [3:0]   ic_u_be, dc_u_be;
logic [31:0]  ic_u_wdata, dc_u_wdata;
logic         ic_u_ack, dc_u_ack;
logic         ic_m_ack, dc_m_ack, dc_ack;

// A cache operation is a one-clock request from the core; the instruction cache may be in a fetch
// then, so the operation is held here until its cache takes it.
logic        mp_v;
logic [2:0]  mp_op;
logic [30:0] mp_addr;
wire         mp_new = ce && d_req && d_cop != 3'd0;    // a request counts in a ce cycle
wire         mv = mp_v || mp_new;
wire  [2:0]  mo = mp_v ? mp_op : d_cop;
wire  [30:0] ma = mp_v ? mp_addr : d_addr;
always_ff @(posedge clk) begin
    if (mp_new) begin mp_v <= 1'b1; mp_op <= d_cop; mp_addr <= d_addr; end
    if (ic_m_ack || (dc_m_ack && !wk_on)) mp_v <= 1'b0;
    if (reset) mp_v <= 1'b0;
end

// the flush walk: set wk_i[8:1], way wk_i[0]
logic        wk_on;
logic [8:0]  wk_i;
always_ff @(posedge clk) begin
    if (!flush) begin wk_on <= 1'b0; flushed <= 1'b0; wk_i <= '0; end
    else if (!wk_on && !flushed && !mp_v) wk_on <= 1'b1;
    else if (wk_on && dc_m_ack) begin
        wk_i <= wk_i + 9'd1;
        if (wk_i == 9'h1FF) begin wk_on <= 1'b0; flushed <= 1'b1; end
    end
    if (reset) begin wk_on <= 1'b0; flushed <= 1'b0; end
end

fb_cache #(.SB(9), .FWD(1'b0)) u_ic (
    .clk, .reset, .ce,
    .req(i_req), .we(1'b0), .addr(i_addr), .be(4'hF), .wdata(32'd0),
    .cacheable(iccr[31 - ireg] && is_mem(i_addr)), .wthru(1'b0),
    .ack(i_ack), .rdata(i_rdata),
    .m_req(mv && (mo == 3'd5 || mo == 3'd6)), .m_op(mo == 3'd5 ? 3'd3 : 3'd4),
    .m_addr(ma), .m_ack(ic_m_ack),
    .l_req(ic_l_req), .l_we(ic_l_we), .l_addr(ic_l_addr), .l_wdata(ic_l_wdata), .l_ack(ic_l_ack),
    .l_rdata(c_rdata),
    .u_req(ic_u_req), .u_we(ic_u_we), .u_addr(ic_u_addr), .u_be(ic_u_be), .u_wdata(ic_u_wdata),
    .u_ack(ic_u_ack), .u_rdata
);

fb_cache #(.SB(8)) u_dc (
    .clk, .reset, .ce(ce || wk_on),
    .req(d_req && d_cop == 3'd0 && ce), .we(d_we), .addr(d_addr), .be(d_be), .wdata(d_wdata),
    .cacheable(dccr[31 - dreg] && is_mem(d_addr)), .wthru(dcwr[31 - dreg]),
    .ack(dc_ack), .rdata(d_rdata),
    .m_req(wk_on || (mv && mo <= 3'd4)), .m_op(wk_on ? {1'b1, wk_i[0], !wk_i[0]} : mo),
    .m_addr(wk_on ? {19'd0, wk_i[8:1], 4'd0} : ma), .m_ack(dc_m_ack),
    .l_req(dc_l_req), .l_we(dc_l_we), .l_addr(dc_l_addr), .l_wdata(dc_l_wdata), .l_ack(dc_l_ack),
    .l_rdata(c_rdata),
    .u_req(dc_u_req), .u_we(dc_u_we), .u_addr(dc_u_addr), .u_be(dc_u_be), .u_wdata(dc_u_wdata),
    .u_ack(dc_u_ack), .u_rdata
);

assign d_ack = dc_ack || (dc_m_ack && !wk_on) || ic_m_ack;

// ---------------------------------------------------------------- the line and word ports
// each held by one cache from its request to its acknowledge, the data cache first
logic lg_v, lg_i, ug_v, ug_i;
wire  l_i = lg_v ? lg_i : !dc_l_req;
wire  u_i = ug_v ? ug_i : !dc_u_req;

assign c_req   = l_i ? ic_l_req : dc_l_req;
assign c_we    = l_i ? ic_l_we : dc_l_we;
assign c_addr  = sd_line(l_i ? ic_l_addr : dc_l_addr);
assign c_wdata = l_i ? ic_l_wdata : dc_l_wdata;
assign ic_l_ack = c_ack && l_i;
assign dc_l_ack = c_ack && !l_i;

assign u_req   = u_i ? ic_u_req : dc_u_req;
assign u_we    = u_i ? ic_u_we : dc_u_we;
assign u_addr  = u_i ? ic_u_addr : dc_u_addr;
assign u_be    = u_i ? ic_u_be : dc_u_be;
assign u_wdata = u_i ? ic_u_wdata : dc_u_wdata;
assign ic_u_ack = u_ack && u_i;
assign dc_u_ack = u_ack && !u_i;

always_ff @(posedge clk) begin
    if (c_req && !c_ack) begin lg_v <= 1'b1; lg_i <= l_i; end
    if (c_ack) lg_v <= 1'b0;
    if (u_req && !u_ack) begin ug_v <= 1'b1; ug_i <= u_i; end
    if (u_ack) ug_v <= 1'b0;
    if (reset) begin lg_v <= 1'b0; ug_v <= 1'b0; end
end

endmodule
