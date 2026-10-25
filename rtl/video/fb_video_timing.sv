// SPDX-License-Identifier: GPL-3.0-or-later
//
// The GCU's CRTC at ppp's mode: mode 1 of the games' table (k057714.cpp device_reset), 512 x 384
// of 685 x 416, a pixel every fourth clk (16.667 MHz from 66.667 MHz). Phase 4 makes the
// registers 0x00-0x08 programmable.
//
// h and v count the pixel being output, visible area first: front porch, sync, back porch after.
// Syncs are active high.

module fb_video_timing #(
    parameter int H_VIS = 512, H_FP = 5, H_SYNC = 96, H_BP = 72,
    parameter int V_VIS = 384, V_FP = 6, V_SYNC = 4, V_BP = 22
) (
    input  logic       clk,
    input  logic       reset,
    output logic       ce_pix,
    output logic [9:0] h,
    output logic [9:0] v,
    output logic       hs,
    output logic       vs,
    output logic       hb,
    output logic       vb,
    output logic       line_start,      // one clk, as h becomes 0
    output logic       frame_start      // one clk, as h and v become 0
);

localparam int H_TOT = H_VIS + H_FP + H_SYNC + H_BP;
localparam int V_TOT = V_VIS + V_FP + V_SYNC + V_BP;

logic [1:0] div;
always_ff @(posedge clk) begin
    div <= div + 2'd1;
    ce_pix <= div == 2'd3;
    line_start <= 1'b0;
    frame_start <= 1'b0;
    if (ce_pix) begin
        if (h == 10'(H_TOT - 1)) begin
            h <= 10'd0;
            line_start <= 1'b1;
            if (v == 10'(V_TOT - 1)) begin v <= 10'd0; frame_start <= 1'b1; end
            else v <= v + 10'd1;
        end else h <= h + 10'd1;
    end
    if (reset) begin div <= 2'd0; h <= 10'd0; v <= 10'd0; end
end

assign hb = h >= 10'(H_VIS);
assign vb = v >= 10'(V_VIS);
assign hs = h >= 10'(H_VIS + H_FP) && h < 10'(H_VIS + H_FP + H_SYNC);
assign vs = v >= 10'(V_VIS + V_FP) && v < 10'(V_VIS + V_FP + V_SYNC);

endmodule
