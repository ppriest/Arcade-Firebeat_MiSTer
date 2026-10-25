// SPDX-License-Identifier: GPL-3.0-or-later
//
// Phase 1: writes a test picture of 512 x 384 RGB555 pixels into VRAM (fb_scanout's layout), a
// row a burst, as a wide hornet_ddr3 master; once after reset and again on each start.
//
// The picture (sim/sys_tb recomputes it): a white border and a white grid every 64 pixels; inside,
// eight colour bars in rows 0-127, a red ramp along x over a green ramp along y in rows 128-255,
// and a blue ramp along x in rows 256-383. variant inverts every pixel.

module pattern_writer #(
    parameter logic [31:0] BASE = 32'h3000_0000
) (
    input  logic        clk,
    input  logic        reset,
    input  logic        start,
    input  logic        variant,
    output logic        done,

    output logic        m_write,
    output logic [31:0] m_addr,
    output logic [10:0] m_burst,
    output logic [31:0] m_wdata,
    output logic [31:0] m_wdata_hi,
    input  logic        m_waitn
);

function automatic logic [15:0] pixel(input logic [8:0] x, input logic [8:0] y, input logic inv);
    logic [14:0] c;
    if (x == 0 || x == 511 || y == 0 || y == 383 || x[5:0] == 0 || y[5:0] == 0) c = 15'h7FFF;
    else if (y < 128) case (x[8:6])
        3'd0: c = 15'h7FFF; 3'd1: c = 15'h7FE0; 3'd2: c = 15'h03FF; 3'd3: c = 15'h03E0;
        3'd4: c = 15'h7C1F; 3'd5: c = 15'h7C00; 3'd6: c = 15'h001F; default: c = 15'h0000;
    endcase
    else if (y < 256) c = {x[8:4], y[6:2], 5'd0};
    else c = {10'd0, x[8:4]};
    return {1'b0, inv ? ~c : c};
endfunction

logic [8:0] row;
logic [6:0] k;                          // the beat: pixels 4k..4k+3
logic [6:0] k1;
logic       inv, go;
assign k1 = k + 7'd1;

always_ff @(posedge clk) begin
    if (m_write && m_waitn) begin
        if (k == 7'd127) begin
            m_write <= 1'b0;
            if (row == 9'd383) done <= 1'b1;
            else begin row <= row + 9'd1; go <= 1'b1; end
        end else begin
            k <= k1;
            m_wdata    <= {pixel({k1, 2'd1}, row, inv), pixel({k1, 2'd0}, row, inv)};
            m_wdata_hi <= {pixel({k1, 2'd3}, row, inv), pixel({k1, 2'd2}, row, inv)};
        end
    end
    if (go && !m_write) begin
        go <= 1'b0;
        m_write <= 1'b1;
        m_addr <= BASE + {12'd0, row, 11'd0};
        m_burst <= 11'd256;
        k <= 7'd0;
        m_wdata    <= {pixel(9'd1, row, inv), pixel(9'd0, row, inv)};
        m_wdata_hi <= {pixel(9'd3, row, inv), pixel(9'd2, row, inv)};
    end
    if (start && !m_write && !go) begin row <= 9'd0; inv <= variant; go <= 1'b1; done <= 1'b0; end
    if (reset) begin m_write <= 1'b0; row <= 9'd0; inv <= 1'b0; go <= 1'b1; done <= 1'b0; end
end

endmodule
