// SPDX-License-Identifier: GPL-3.0-or-later
//
// Phase 1: reads `lines` 16-byte lines of SDRAM from line `base` through firebeat_sdram's cache
// port, as the PPC's fills will, summing their 32-bit words (big-endian, as the PPC reads them)
// and timing each fill from request to acknowledge in clk.

module mem_check (
    input  logic         clk,
    input  logic         reset,
    input  logic         start,
    input  logic [26:4]  base,
    input  logic [22:0]  lines,

    output logic         c_req,
    output logic [26:4]  c_addr,
    input  logic         c_ack,
    input  logic [127:0] c_rdata,

    output logic         busy,
    output logic [31:0]  sum,
    output logic [22:0]  done_lines,
    output logic [31:0]  lat_sum,
    output logic [7:0]   lat_max
);

logic [7:0]  lat;                       // clocks since the request, the acknowledge's included
logic [22:0] n;                         // lines, taken at start

always_ff @(posedge clk) begin
    if (c_req && lat != 8'hFF) lat <= lat + 8'd1;
    if (c_req && c_ack) begin
        sum <= sum + c_rdata[31:0] + c_rdata[63:32] + c_rdata[95:64] + c_rdata[127:96];
        lat_sum <= lat_sum + {24'd0, lat};
        if (lat > lat_max) lat_max <= lat;
        done_lines <= done_lines + 23'd1;
        c_req <= 1'b0;
        c_addr <= c_addr + 23'd1;
        if (done_lines + 23'd1 == n) busy <= 1'b0;
    end else if (busy && !c_req) begin
        c_req <= 1'b1;
        lat <= 8'd1;
    end
    if (start && !busy) begin
        busy <= 1'b1; c_addr <= base; n <= lines; sum <= 32'd0; done_lines <= 23'd0; lat_sum <= 32'd0;
        lat_max <= 8'd0;
    end
    if (reset) begin busy <= 1'b0; c_req <= 1'b0; end
end

endmodule
