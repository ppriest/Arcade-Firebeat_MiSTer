// SPDX-License-Identifier: GPL-3.0-or-later
//
// The display's pixel stream from its own clock to clk, for fb_rot16 on bm3 (fb_gcu_disp VCLK): each
// ce_pix's {vs, de, r, g, b} into a 16-entry FIFO on i_clk, out on clk as o_ce with the same fields,
// one a clock while there are any. clk (66.667 MHz) drains faster than the pixel clock (25.175 MHz)
// fills, so it never overflows. Gray-coded pointers, two flops each way.

module fb_pix_cdc (
    input  logic       i_clk,
    input  logic       i_ce,
    input  logic       i_vs, i_de,
    input  logic [7:0] i_r, i_g, i_b,

    input  logic       clk,
    output logic       o_ce,
    output logic       o_vs, o_de,
    output logic [7:0] o_r, o_g, o_b
);

logic [16:0] mem [16];
logic [4:0]  wp, wg, rp, rg;                 // binary and Gray, one bit over the depth
logic [4:0]  wg_s0, wg_s1;

function automatic logic [4:0] gray(input logic [4:0] b);
    return b ^ (b >> 1);
endfunction

always_ff @(posedge i_clk) if (i_ce) begin
    mem[wp[3:0]] <= {i_vs, i_de, i_r[7:3], i_g[7:3], i_b[7:3]};
    wp <= wp + 5'd1;
    wg <= gray(wp + 5'd1);
end

logic [16:0] q;
always_ff @(posedge clk) begin
    wg_s0 <= wg; wg_s1 <= wg_s0;
    o_ce <= 1'b0;
    if (gray(rp) != wg_s1) begin
        q <= mem[rp[3:0]];
        rp <= rp + 5'd1;
        o_ce <= 1'b1;
    end
end
assign o_vs = q[16];
assign o_de = q[15];
assign o_r = {q[14:10], q[14:12]};
assign o_g = {q[9:5], q[9:7]};
assign o_b = {q[4:0], q[4:2]};

endmodule
