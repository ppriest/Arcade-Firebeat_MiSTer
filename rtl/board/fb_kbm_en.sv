// SPDX-License-Identifier: GPL-3.0-or-later
//
// Keyboardmania's English instructions (OSD). kbm's and kbh's program discs carry English copies
// of six screens (XDEMO.ZCC ... XMU_SELR.ZCC) that the game never opens; while `en` is set, the
// root directory's records for the Japanese files are given the English files' extents and sizes
// as the sectors reach the drive's buffer (rtl/board/fb_kbm_en.svh, scripts/gen_kbm_en.py).
//
// The disc is told by its volume size, read from the primary volume descriptor (frame 16) when
// the BIOS reads it; a word is replaced only on a disc in the table, in the frame and at the word
// the table names, and only while it still reads as that disc's. The game reads the directory
// once a boot, so a change takes effect at the next reset.

module fb_kbm_en (
    input  logic        clk,
    input  logic        reset,          // a new disc, or power-on
    input  logic        en,
    input  logic [31:0] rq_lba,
    input  logic        bw_we,
    input  logic [9:0]  bw_a,
    input  logic [15:0] bw_d,
    output logic [15:0] bw_q
);

`include "fb_kbm_en.svh"

logic [31:0] vol;
always_ff @(posedge clk) begin
    if (bw_we && rq_lba == 32'd16 && bw_a == 10'd40) vol[15:0] <= bw_d;
    if (bw_we && rq_lba == 32'd16 && bw_a == 10'd41) vol[31:16] <= bw_d;
    if (reset) vol <= '0;
end

always_comb begin
    bw_q = bw_d;
    if (en)
        for (int i = 0; i < KBM_EN_N; i++)
            if (vol == KBM_EN[i][97:66] && rq_lba == 32'(KBM_EN[i][65:42]) && bw_a == KBM_EN[i][41:32]
                && bw_d == KBM_EN[i][31:16])
                bw_q = KBM_EN[i][15:0];
end

endmodule
