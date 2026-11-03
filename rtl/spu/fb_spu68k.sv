// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (c) Paul Priest
//
// The Pop'n Music SPU board's 68000 side (firebeat.cpp spu_map F:1211-1226): the CPU, its 256 KB
// RAM, the CY7C131 dual-port RAM shared with the PPC, the interrupt logic and the board
// registers. The program ROM, the wave RAM window, the SPU ATA bus and the RF5C400 are reached
// through one external bus (x_*), served by the system: SDRAM, fb_atapi, the RF5C400.
//
//   000000-07FFFF  program ROM             x_*   (x_rgn ROM)
//   100000-13FFFF  RAM                     here, block RAM
//   200000         SPU DSW (read)          dsw
//   220000         status LEDs (write)     leds
//   230000         IRQ acknowledge         bit 0 IRQ1, 1 IRQ2, 3 IRQ6
//   240000/250000  ATA DMA address low/high  dma_addr
//   260000         wave bank               wave_bank (x_* adds it to wave RAM addresses)
//   280000-2807FF  dual-port RAM, low byte  here
//   300000/340000  SPU ATA cs0/cs1         x_*   (x_rgn ATA0/ATA1)
//   400000-400FFF  RF5C400                 x_*   (x_rgn RF)
//   800000-FFFFFF  wave RAM, 4M words a bank  x_*   (x_rgn WAVE)
//
// Interrupts as MAME raises them (F:1236-1255, 1300-1320, 1384-1395), autovectored:
//   IRQ2  the 500 Hz timer while no SPU ATA interrupt is pending; dropped by the ATA interrupt
//         falling, or acknowledged
//   IRQ4  the dual-port RAM's left mailbox (PPC write of 0x3FE), cleared by the 68000's read of it
//   IRQ6  the 500 Hz timer while an SPU ATA interrupt is pending; acknowledged
// The PPC's interrupt is the right mailbox: the 68000's write of 0x3FF, cleared by the PPC's read.
//
// The 68000 runs at 16 MHz: phi1 and phi2 alternate on a 12/25 accumulator from clk_sys (66.667
// MHz), 32 million phases a second. The phi2 that samples DTACK waits while an access is not
// ready (KonamiGX's gx_sound), so a slow external access costs clk_sys clocks, not 68000 states.

module fb_spu68k (
    input  logic         clk,               // clk_sys, 66.667 MHz
    input  logic         rst,

    // the external bus: one access at a time, held until x_ack
    output logic         x_req,
    output logic         x_we,
    output logic [ 1:0]  x_be,              // { upper, lower } byte
    output logic [ 2:0]  x_rgn,
    output logic [24:1]  x_addr,            // ROM: [19:1]; WAVE: bank and offset, 16M words;
                                            // ATA, RF: the 68000's address [11:1]
    output logic [15:0]  x_wd,
    input  logic         x_ack,
    input  logic [15:0]  x_rd,

    // the PPC's side of the dual-port RAM (0x74000000-0x740003FF, a byte each)
    input  logic         pp_cs,
    input  logic         pp_we,
    input  logic [ 9:0]  pp_addr,
    input  logic [ 7:0]  pp_wd,
    output logic [ 7:0]  pp_rd,             // the clock after pp_cs
    output logic         ppc_irq,

    input  logic         ata_irq,           // the SPU ATA bus's INTRQ
    input  logic [ 7:0]  dsw,
    output logic [ 7:0]  leds,
    output logic [31:0]  dma_addr,          // the ATA DMA's wave RAM word, after the bank
    input  logic         dma_inc,           // a DMA word written: the next
    output logic [ 1:0]  wave_bank,

    // every bus cycle as it completes, for the bench: { IPL level, R/W, /UDS, /LDS,
    // address[23:1] } and the data
    output logic         tr_valid,
    output logic [26:0]  tr_info,
    output logic [15:0]  tr_data
);

localparam logic [2:0] R_ROM = 3'd0, R_WAVE = 3'd1, R_ATA0 = 3'd2, R_ATA1 = 3'd3, R_RF = 3'd4;

// ---------------------------------------------------------------- CPU
logic        as_n, rw_n, uds_n, lds_n, fc0, fc1, fc2;
logic [23:1] eab;
logic [15:0] cpu_dout;
logic [15:0] cpu_din;
logic [ 2:0] ipl_n;
logic        en_phi1, en_phi2;
logic        acc_ready, acc_busy;

wire [2:0] fc      = {fc2, fc1, fc0};
wire       in_iack = !as_n && fc == 3'b111;
wire       dtack_n = !(acc_ready && !as_n && !in_iack);

fx68k u_cpu (
    .clk, .HALTn(1'b1), .extReset(rst), .pwrUp(rst),
    .enPhi1(en_phi1), .enPhi2(en_phi2),
    .eRWn(rw_n), .ASn(as_n), .LDSn(lds_n), .UDSn(uds_n), .E(), .VMAn(),
    .FC0(fc0), .FC1(fc1), .FC2(fc2), .BGn(), .oRESETn(), .oHALTEDn(),
    .DTACKn(dtack_n), .VPAn(!in_iack), .BERRn(1'b1),
    .BRn(1'b1), .BGACKn(1'b1),
    .IPL0n(ipl_n[0]), .IPL1n(ipl_n[1]), .IPL2n(ipl_n[2]),
    .iEdb(cpu_din), .oEdb(cpu_dout), .eab(eab), .stop_out()
);

// phases: 12/25 of clk_sys; the DTACK-sampling phi2 (the second after AS) waits for acc_ready
logic [4:0] ph_acc;
logic       next_phi2;
logic [1:0] phi2_in_as;
wire  [5:0] ph_sum  = {1'b0, ph_acc} + 6'd12;
wire        ph_due  = !rst && ph_sum >= 6'd25;
wire        ph_hold = next_phi2 && !as_n && !in_iack && !acc_ready && phi2_in_as != 2'd0;
assign en_phi1 = ph_due && !next_phi2;
assign en_phi2 = ph_due && next_phi2 && !ph_hold;
always_ff @(posedge clk) begin
    if (rst) begin
        ph_acc <= 5'd0; next_phi2 <= 1'b0;
    end else if (!ph_due) ph_acc <= ph_sum[4:0];
    else if (!ph_hold) begin
        ph_acc    <= ph_sum[4:0] - 5'd25;
        next_phi2 <= !next_phi2;
    end
    if (as_n)                               phi2_in_as <= 2'd0;
    else if (en_phi2 && phi2_in_as != 2'd3) phi2_in_as <= phi2_in_as + 2'd1;
end

// ---------------------------------------------------------------- decode
wire [23:0] a = {eab, 1'b0};
wire s_rom  = a[23:19] == 5'b00000;                 // 000000-07FFFF
wire s_ram  = a[23:18] == 6'b000100;                // 100000-13FFFF
wire s_dsw  = a[23:16] == 8'h20;
wire s_led  = a[23:16] == 8'h22;
wire s_ack  = a[23:16] == 8'h23;
wire s_dmal = a[23:16] == 8'h24;
wire s_dmah = a[23:16] == 8'h25;
wire s_bank = a[23:16] == 8'h26;
wire s_dp   = a[23:16] == 8'h28 && a[15:11] == 5'd0;
wire s_ata0 = a[23:16] == 8'h30 && a[15:4] == 12'd0;
wire s_ata1 = a[23:16] == 8'h34 && a[15:4] == 12'd0;
wire s_rf   = a[23:12] == 12'h400;
wire s_wave = a[23];
wire s_ext  = s_rom || s_ata0 || s_ata1 || s_rf || s_wave;

// an access: AS and a strobe, served once, DTACK held until AS goes
wire acc_active = !as_n && !in_iack && !(uds_n && lds_n);
wire acc_new    = acc_active && !acc_busy && !acc_ready;

// ---------------------------------------------------------------- RAM, 128K words
logic [7:0] ram_h [0:131071];
logic [7:0] ram_l [0:131071];
logic [7:0] ram_qh, ram_ql;
always_ff @(posedge clk) begin
    if (acc_new && s_ram && !rw_n && !uds_n) ram_h[a[17:1]] <= cpu_dout[15:8];
    if (acc_new && s_ram && !rw_n && !lds_n) ram_l[a[17:1]] <= cpu_dout[7:0];
    ram_qh <= ram_h[a[17:1]];
    ram_ql <= ram_l[a[17:1]];
end

// ---------------------------------------------------------------- dual-port RAM
logic [7:0] dp [0:1023];
logic [7:0] dp_ql;
logic       dp_l_we, dp_r_we;
assign dp_l_we = acc_new && s_dp && !rw_n && !lds_n;
assign dp_r_we = pp_cs && pp_we;
// Intel's true dual-port template: a port reads its own write back, the only form Quartus infers
always_ff @(posedge clk)
    if (dp_l_we) begin dp[a[10:1]] <= cpu_dout[7:0]; dp_ql <= cpu_dout[7:0]; end
    else dp_ql <= dp[a[10:1]];
always_ff @(posedge clk)
    if (dp_r_we) begin dp[pp_addr] <= pp_wd; pp_rd <= pp_wd; end
    else pp_rd <= dp[pp_addr];

// the mailboxes: INTL (the 68000's IRQ4) and INTR (the PPC's)
logic intl;
always_ff @(posedge clk) begin
    if (rst) begin
        intl <= 1'b0; ppc_irq <= 1'b0;
    end else begin
        if (dp_r_we && pp_addr == 10'h3FE)                           intl <= 1'b1;
        else if (acc_new && s_dp && rw_n && a[10:1] == 10'h3FE)      intl <= 1'b0;
        if (dp_l_we && a[10:1] == 10'h3FF)                           ppc_irq <= 1'b1;
        else if (pp_cs && !pp_we && pp_addr == 10'h3FF)              ppc_irq <= 1'b0;
    end
end

// ---------------------------------------------------------------- interrupts
// the 500 Hz timer: 133,333 1/3 clocks, an accumulator of 3 a clock against 400,000
logic [18:0] tm_acc;
wire  [18:0] tm_sum  = tm_acc + 19'd3;
wire         tm_fire = tm_sum >= 19'd400000;
logic irq2, irq6, ata_q;
always_ff @(posedge clk) begin
    if (rst) begin
        tm_acc <= 19'd0; irq2 <= 1'b0; irq6 <= 1'b0; ata_q <= 1'b0;
    end else begin
        tm_acc <= tm_fire ? tm_sum - 19'd400000 : tm_sum;
        ata_q  <= ata_irq;
        if (ata_q && !ata_irq) irq2 <= 1'b0;
        if (tm_fire) begin
            if (ata_irq) irq6 <= 1'b1;
            else         irq2 <= 1'b1;
        end
        if (acc_new && s_ack && !rw_n && !lds_n) begin
            if (cpu_dout[1]) irq2 <= 1'b0;
            if (cpu_dout[3]) irq6 <= 1'b0;
        end
    end
end
assign ipl_n = irq6 ? ~3'd6 : intl ? ~3'd4 : irq2 ? ~3'd2 : 3'b111;

// ---------------------------------------------------------------- registers
always_ff @(posedge clk) begin
    if (rst) begin
        leds <= 8'h00; dma_addr <= 32'd0; wave_bank <= 2'd0;
    end else begin
        // a DMA word's increment is not lost to a 68000 write in the same clock
        if (dma_inc) dma_addr <= dma_addr + 32'd1;
        if (acc_new && !rw_n) begin
            if (s_led && !lds_n)  leds <= cpu_dout[7:0];
            if (s_dmal)           dma_addr[15:0]  <= cpu_dout;
            if (s_dmah)           dma_addr[31:16] <= cpu_dout;
            if (s_bank)           wave_bank <= cpu_dout[1:0];
        end
    end
end

// ---------------------------------------------------------------- the bus
// internal accesses complete the clock after they are taken (the block RAMs' read), external
// ones on x_ack
logic int_pend;
always_ff @(posedge clk) begin
    if (rst || as_n) begin
        acc_ready <= 1'b0; acc_busy <= 1'b0; int_pend <= 1'b0; x_req <= 1'b0;
    end else begin
        int_pend <= 1'b0;
        if (acc_new) begin
            acc_busy <= 1'b1;
            if (s_ext) begin
                x_req  <= 1'b1;
                x_we   <= !rw_n;
                x_be   <= {!uds_n, !lds_n};
                x_wd   <= cpu_dout;
                x_rgn  <= s_rom ? R_ROM : s_wave ? R_WAVE : s_ata0 ? R_ATA0 : s_ata1 ? R_ATA1 : R_RF;
                x_addr <= s_wave ? {wave_bank, a[22:1]} : {1'b0, a[23:1]};
            end else
                int_pend <= 1'b1;
        end
        if (int_pend) begin
            cpu_din   <= s_ram ? {ram_qh, ram_ql} : s_dp ? {8'h00, dp_ql} :
                         s_dsw ? {8'h00, dsw} : 16'h0000;
            acc_ready <= 1'b1; acc_busy <= 1'b0;
        end
        if (x_req && x_ack) begin
            x_req <= 1'b0;
            cpu_din   <= x_rd;
            acc_ready <= 1'b1; acc_busy <= 1'b0;
        end
    end
end

// the bench's view: each access the clock it completes
always_ff @(posedge clk) begin
    tr_valid <= (int_pend || (x_req && x_ack)) && !rst && !as_n;
    tr_info  <= {~ipl_n, rw_n, uds_n, lds_n, eab};
    tr_data  <= rw_n ? (int_pend ? (s_ram ? {ram_qh, ram_ql} : s_dp ? {8'h00, dp_ql} :
                                    s_dsw ? {8'h00, dsw} : 16'h0000) : x_rd)
                     : cpu_dout;
end

endmodule
