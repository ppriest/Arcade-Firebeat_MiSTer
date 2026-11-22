// SPDX-License-Identifier: GPL-3.0-or-later
//
// BM3: firebeat's slave CD-ROM drive (ata:1), empty, as far as bm3 sees it. bm3 never selects it
// (its device register writes are all 0xA0: debug/bm3-boot/io.txt), so of fb_atapi with CSEL 1
// only what an unselected slave drives is kept: DASP (asserted from power-on until the first SRST)
// and PDIAG (raised 2 ms after power-on or after SRST ends, cleared by SRST), MAME's
// atahle reset and start_diagnostic timing. It never answers a read and never interrupts. A
// device register write that selects it raises `bad` (the state dump's trigger): from then on
// fb_atapi would answer and this does not.
//
// sim/atapi_absent_tb checks it against fb_atapi CSEL 1 clock for clock on bm3's ATA accesses.

module fb_atapi_absent (
    input  logic        clk,
    input  logic        reset,
    input  logic        tick_us,
    input  logic        acc,
    input  logic        we,
    input  logic        cs1,
    input  logic [2:0]  off,
    input  logic [15:0] wd,
    output logic        dasp_o,
    output logic        pdiag_o,
    output logic        bad
);

logic        resetting, busy_on, srst_hold;   // busy_on: fb_atapi's BSY
logic [11:0] btmr;
logic [7:0]  devctl;

always_ff @(posedge clk) begin
    // busy_tick, finished_busy: the 2 ms diagnostic, then start_diagnostic's PDIAG
    if (busy_on && !srst_hold && tick_us) begin
        if (btmr <= 12'd1) begin
            busy_on <= 1'b0;
            pdiag_o <= 1'b1;
            resetting <= 1'b0;
        end
        else begin
            btmr <= btmr - 12'd1;
        end
    end
    // the device register as fb_atapi takes it: not while busy
    if (acc && we && !cs1 && off == 3'd6 && !busy_on && wd[4]) begin
        bad <= 1'b1;
    end
    // SRST, devctl bit 2: on, DASP and PDIAG drop and the drive holds busy; off, the diagnostic
    if (acc && we && cs1 && off == 3'd6) begin
        devctl <= wd[7:0];
        if ((devctl ^ wd[7:0]) & 8'h04) begin
            if (wd[2]) begin
                if (!resetting) begin
                    dasp_o <= 1'b0;
                    pdiag_o <= 1'b0;
                    busy_on <= 1'b1;
                    srst_hold <= 1'b1;
                end
            end
            else if (busy_on && srst_hold) begin
                srst_hold <= 1'b0;
                btmr <= 12'd2000;
            end
        end
    end
    if (reset) begin
        devctl <= 8'h00;
        resetting <= 1'b1;
        dasp_o <= 1'b1;
        pdiag_o <= 1'b0;
        busy_on <= 1'b1;
        srst_hold <= 1'b0;
        btmr <= 12'd2000;
        bad <= 1'b0;
    end
end

endmodule
