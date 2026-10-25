// SPDX-License-Identifier: GPL-3.0-or-later
//
// Epson RTC-65271 as MAME runs it (devices/machine/rtc65271.cpp): 64 register bytes (clock,
// alarms, A-D, 50 of user RAM) through an index register, and 4 KB of extended RAM in 128 pages of
// 32 bytes.
//
//   rtc (0x7E000000-0x7E00003F): an odd offset is the data register, an even one the index
//   xram (0x7E000100-0x7E00013F): offset bit 5 the page register, else a byte of the page
//
// Reads: A returns its DV field replaced by 0x20 (normal operation); C is cleared by a read; D
// reads its value and becomes 0x80 (VRT). Writes: seconds lose bit 7, A keeps UIP, B with SET
// clears UIP and UIE, C and D ignore writes.
//
// The update cycle, MAME's: every second (from power-up) UIP is set if DV is 0x20 and SET is
// clear; 1,984 us later the time advances by a second in BCD or binary (B.DM), 12 or 24 hours, with
// MAME's month lengths and leap rule (year & 3), UIP clears and C gets UF (and AF on an alarm
// match). The periodic flag C.PF is set at the rate A.RS selects (MAME's SQW timer). The interrupt
// output is not connected on firebeat.
//
// The persistent part is MAME's .nv format for this chip, 4,152 bytes: version 0, A (its DV), B
// (SET, DM, 24h, DSE), the three alarm registers, user RAM (registers 14-63), the 4 KB. nv_* read
// and write it a byte at a time (the core's NVRAM file); a load sets D.VRT. tm_set takes the time
// from the HPS (BCD fields), converted to binary when B.DM is set, as MAME's rtc_clock_updated.

module fb_rtc65271 (
    input  logic        clk,
    input  logic        reset,

    input  logic        req,
    input  logic        we,
    input  logic        xram,           // the extended-RAM window
    input  logic [5:0]  addr,
    input  logic [7:0]  wdata,
    output logic [7:0]  rdata,          // valid the clock after req

    input  logic        nv_we,
    input  logic [12:0] nv_addr,        // 0-4151
    input  logic [7:0]  nv_wdata,
    output logic [7:0]  nv_rdata,       // the clock after nv_addr

    input  logic        tm_set,
    input  logic [55:0] tm_bcd          // hps_io RTC: sec, min, hour, day, month, year (BCD), weekday
);

localparam int CLK_HZ   = 66_666_667;
localparam int UPD_CLKS = 132_267;      // 1,984 us

logic [7:0] regs [64];
logic [7:0] xmem [4096];
logic [6:0] page;
logic [5:0] cur;

localparam logic [5:0] SEC = 0, ASEC = 1, MIN = 2, AMIN = 3, HOUR = 4, AHOUR = 5, WDAY = 6,
                       MDAY = 7, MON = 8, YEAR = 9, RA = 10, RB = 11, RC = 12, RD = 13;

function automatic logic [7:0] inc_bcd(input logic [7:0] d);
    if (d[3:0] < 4'd9) return d + 8'd1;
    return {d[7:4] + 4'd1, 4'd0};
endfunction
function automatic logic [7:0] bcd2bin(input logic [7:0] d);
    return {3'd0, d[7:4], 1'b0} + {1'b0, d[7:4], 3'b0} + {4'd0, d[3:0]};   // tens x 2 + tens x 8 + ones
endfunction
// MAME's days_in_month_table, binary
function automatic logic [7:0] mdays(input logic [3:0] m);
    case (m)
    4'd4, 4'd6, 4'd9, 4'd11: return 8'd30;
    4'd2: return 8'd28;
    default: return 8'd31;
    endcase
endfunction

// ---------------------------------------------------------------- timers
logic [25:0] sec_cnt;
logic [17:0] upd_cnt;
logic        upd_on;
logic [24:0] pf_cnt;
logic [24:0] pf_half;                   // clocks a half period of the SQW rate
always_comb case (regs[RA][3:0])
    4'd0: pf_half = '0;
    4'd1, 4'd8: pf_half = 25'(CLK_HZ / 512);
    4'd2, 4'd9: pf_half = 25'(CLK_HZ / 256);
    4'd3: pf_half = 25'(CLK_HZ / 16384);
    4'd4: pf_half = 25'(CLK_HZ / 8192);
    4'd5: pf_half = 25'(CLK_HZ / 4096);
    4'd6: pf_half = 25'(CLK_HZ / 2048);
    4'd7: pf_half = 25'(CLK_HZ / 1024);
    4'd10: pf_half = 25'(CLK_HZ / 128);
    4'd11: pf_half = 25'(CLK_HZ / 64);
    4'd12: pf_half = 25'(CLK_HZ / 32);
    4'd13: pf_half = 25'(CLK_HZ / 16);
    4'd14: pf_half = 25'(CLK_HZ / 8);
    default: pf_half = 25'(CLK_HZ / 4);
endcase
logic pf_phase;

// ---------------------------------------------------------------- the clock and the bus
logic [7:0] xq;
logic [7:0] rreg;
always_ff @(posedge clk) begin
    logic [7:0] r [64];
    for (int i = 0; i < 64; i++) r[i] = regs[i];

    // the second
    if (sec_cnt == 26'(CLK_HZ - 1)) begin
        sec_cnt <= '0;
        if (r[RA][6:4] == 3'd2 && !r[RB][7]) begin r[RA][7] = 1'b1; upd_on <= 1'b1; upd_cnt <= '0; end
    end else sec_cnt <= sec_cnt + 26'd1;

    // the end of the update cycle
    if (upd_on) begin
        if (upd_cnt == 18'(UPD_CLKS - 1)) begin
            upd_on <= 1'b0;
            if (r[RA][7]) begin
                logic dm;
                logic [7:0] c59, c23, c12, c11, c29, dim;
                dm = r[RB][2];
                c59 = dm ? 8'd59 : 8'h59; c23 = dm ? 8'd23 : 8'h23; c12 = dm ? 8'd12 : 8'h12;
                c11 = dm ? 8'd11 : 8'h11; c29 = dm ? 8'd29 : 8'h29;
                if (r[SEC] < c59) r[SEC] = dm ? r[SEC] + 8'd1 : inc_bcd(r[SEC]);
                else begin
                    r[SEC] = 8'd0;
                    if (r[MIN] < c59) r[MIN] = dm ? r[MIN] + 8'd1 : inc_bcd(r[MIN]);
                    else begin
                        r[MIN] = 8'd0;
                        if (r[RB][1]) r[HOUR] = (r[HOUR] < c23) ? (dm ? r[HOUR] + 8'd1 : inc_bcd(r[HOUR])) : 8'd0;
                        else if (r[HOUR] < c12) begin
                            logic [7:0] hn;
                            if (r[HOUR][6:0] == c11[6:0]) r[HOUR][7] = !r[HOUR][7];
                            hn = dm ? {1'b0, r[HOUR][6:0]} + 8'd1 : inc_bcd({1'b0, r[HOUR][6:0]});
                            r[HOUR] = {r[HOUR][7], hn[6:0]};
                        end else r[HOUR] = {r[HOUR][7], 7'd1};
                        if (r[HOUR] == (r[RB][1] ? 8'd0 : c12)) begin
                            r[WDAY] = (r[WDAY] < 8'd7) ? r[WDAY] + 8'd1 : 8'd1;
                            if (r[MON] != 8'd2 || r[YEAR][1:0] != 2'd0)
                                dim = dm ? mdays(r[MON][3:0]) :
                                      // BCD: binary_to_BCD of the binary month's length
                                      ((mdays(bcd2bin(r[MON])[3:0]) == 8'd31) ? 8'h31 :
                                       (mdays(bcd2bin(r[MON])[3:0]) == 8'd30) ? 8'h30 : 8'h28);
                            else dim = c29;
                            if (r[MDAY] < dim) r[MDAY] = dm ? r[MDAY] + 8'd1 : inc_bcd(r[MDAY]);
                            else begin
                                r[MDAY] = 8'd1;
                                if (r[MON] < c12) r[MON] = dm ? r[MON] + 8'd1 : inc_bcd(r[MON]);
                                else begin
                                    r[MON] = 8'd1;
                                    if (dm) r[YEAR] = (r[YEAR] < 8'd99) ? r[YEAR] + 8'd1 : 8'd0;
                                    else r[YEAR] = inc_bcd(r[YEAR]);
                                end
                            end
                        end
                    end
                end
                r[RA][7] = 1'b0;
                r[RC][4] = 1'b1;
                if ((r[ASEC][7:6] == 2'b11 || r[ASEC] == r[SEC]) && (r[AMIN][7:6] == 2'b11 || r[AMIN] == r[MIN]) &&
                    (r[AHOUR][7:6] == 2'b11 || r[AHOUR] == r[HOUR]))
                    r[RC][5] = 1'b1;
            end
        end else upd_cnt <= upd_cnt + 18'd1;
    end

    // the periodic flag
    if (pf_half == '0) begin pf_cnt <= '0; pf_phase <= 1'b0; end
    else if (pf_cnt >= pf_half - 25'd1) begin
        pf_cnt <= '0;
        pf_phase <= !pf_phase;
        if (pf_phase) r[RC][6] = 1'b1;
    end else pf_cnt <= pf_cnt + 25'd1;
    // IRQF follows MAME's field_interrupts
    r[RC][7] = (r[RC] & r[RB] & 8'h70) != 0;

    // the bus
    if (req && !xram) begin
        if (addr[0]) begin
            if (we) case (cur)
                SEC: r[SEC] = {1'b0, wdata[6:0]};
                RA: r[RA] = {r[RA][7], wdata[6:0]};
                RB: begin r[RB] = wdata; if (wdata[7]) begin r[RA][7] = 1'b0; r[RB][4] = 1'b0; end end
                RC, RD: ;
                default: r[cur] = wdata;
            endcase
            else case (cur)
                RA: rreg <= {r[RA][7], 3'b010, r[RA][3:0]};
                RC: begin rreg <= r[RC]; r[RC] = 8'h00; end
                RD: begin rreg <= r[RD]; r[RD] = 8'h80; end
                default: rreg <= r[cur];
            endcase
        end else begin
            if (we) cur <= wdata[5:0]; else rreg <= {2'b00, cur};
        end
    end
    if (req && xram) begin
        if (addr[5]) begin if (we) page <= wdata[6:0]; else rreg <= {1'b0, page}; end
    end
    if (tm_set) begin
        logic [7:0] h, h12;
        h = bcd2bin(tm_bcd[23:16]);
        h12 = (h >= 8'd12) ? h - 8'd12 : h;
        r[SEC] = r[RB][2] ? bcd2bin(tm_bcd[7:0]) : tm_bcd[7:0];
        r[MIN] = r[RB][2] ? bcd2bin(tm_bcd[15:8]) : tm_bcd[15:8];
        if (r[RB][1]) r[HOUR] = r[RB][2] ? h : tm_bcd[23:16];
        // 12 hours: MAME's 0-based hour with bit 7 for PM (rtc_clock_updated)
        else r[HOUR] = {h >= 8'd12, 7'(r[RB][2] ? h12 : (h12 >= 8'd10 ? h12 + 8'd6 : h12))};
        r[WDAY] = tm_bcd[55:48];
        r[MDAY] = r[RB][2] ? bcd2bin(tm_bcd[31:24]) : tm_bcd[31:24];
        r[MON]  = r[RB][2] ? bcd2bin(tm_bcd[39:32]) : tm_bcd[39:32];
        r[YEAR] = r[RB][2] ? bcd2bin(tm_bcd[47:40]) : tm_bcd[47:40];
    end
    // the .nv image: version, A, B, alarms, user RAM, then the 4 KB (below)
    if (nv_we) case (nv_addr)
        13'd0: ;
        13'd1: r[RA] = nv_wdata & 8'h70;
        13'd2: begin r[RB] = nv_wdata & 8'h87; r[RD] = 8'h80; end
        13'd3: r[ASEC] = nv_wdata;
        13'd4: r[AMIN] = nv_wdata;
        13'd5: r[AHOUR] = nv_wdata;
        default: if (nv_addr < 13'd56) r[nv_addr[5:0] + 6'd8] = nv_wdata;   // 6..55: registers 14..63
    endcase

    for (int i = 0; i < 64; i++) regs[i] <= r[i];

    if (reset) begin
        cur <= 6'd0; page <= 7'd0; sec_cnt <= '0; upd_on <= 1'b0; pf_cnt <= '0; pf_phase <= 1'b0;
        // MAME's nvram_default: every register 0 but B's binary mode (firebeat.cpp's note there);
        // a loaded NVRAM file then overwrites the persistent ones
        for (int i = 0; i < 64; i++) regs[i] <= (i == 11) ? 8'h04 : 8'h00;
    end
end

// the extended RAM: the CPU's byte, or the NVRAM file's
wire        nv_x = nv_addr >= 13'd56;
wire [11:0] nv_xa = 12'(nv_addr - 13'd56);
always_ff @(posedge clk) begin
    if (req && xram && !addr[5] && we) xmem[{page, addr[4:0]}] <= wdata;
    else if (nv_we && nv_x) xmem[nv_xa] <= nv_wdata;
    xq <= xmem[(req && xram && !addr[5]) ? {page, addr[4:0]} : nv_xa];
end
// a CPU read of the extended RAM is answered from xq the clock after
logic xr_q;
always_ff @(posedge clk) xr_q <= req && xram && !addr[5] && !we;
assign rdata = xr_q ? xq : rreg;

always_comb begin
    case (nv_addr)
    13'd0: nv_rdata = 8'h00;
    13'd1: nv_rdata = regs[RA] & 8'h7F;
    13'd2: nv_rdata = regs[RB] & 8'h87;
    13'd3: nv_rdata = regs[ASEC];
    13'd4: nv_rdata = regs[AMIN];
    13'd5: nv_rdata = regs[AHOUR];
    default: nv_rdata = (nv_addr < 13'd56) ? regs[nv_addr[5:0] + 6'd8] : xq;
    endcase
end

endmodule
