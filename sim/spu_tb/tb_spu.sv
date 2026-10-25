// SPDX-License-Identifier: GPL-3.0-or-later
// rtl/board/fb_spu.sv alone: ppp's set-up writes (MAME boot capture, frame 1039), then the dongle's
// first byte (C1, frame 2020) and the line status polled until the reply is in.
`timescale 1ns/1ps
module tb_spu;
logic clk = 0, reset = 1;
always #7.5 clk = !clk;
logic tick66 = 0;
int tn = 0;
always @(posedge clk) begin tn <= (tn == 99) ? 0 : tn + 1; tick66 <= tn != 99; end
logic req = 0, we = 0, irq_rx, irq_tx, bad;
logic [3:0] addr = 0;
logic [7:0] wdata = 0, rdata;
fb_spu u (.clk, .reset, .tick66, .iocr_b1(1'b0), .req, .we, .addr, .wdata, .rdata,
          .irq_rx, .irq_tx, .bad, .ld_we(1'b0), .ld_addr(8'd0), .ld_data(8'd0));
task automatic wr(input int a, input int d);
    @(posedge clk); req <= 1; we <= 1; addr <= 4'(a); wdata <= 8'(d);
    @(posedge clk); req <= 0; we <= 0;
endtask
task automatic rd(input int a, output int d);
    @(posedge clk); req <= 1; we <= 0; addr <= 4'(a);
    @(posedge clk); req <= 0;
    @(posedge clk); d = rdata;
endtask
initial begin
    int d, n;
    repeat (5) @(posedge clk); reset = 0;
    // frame 1039
    wr(4, 0); wr(5, 0); wr(0, 8'h78); wr(2, 8'hFF); wr(6, 0); wr(7, 0); wr(8, 0);
    wr(4, 0); wr(5, 8'hD5); wr(6, 8'h08); wr(7, 8'hA8); wr(8, 8'h80); wr(2, 8'hFF);
    rd(6, d); wr(6, 8'h38);
    repeat (100000) @(posedge clk);
    rd(0, d); $display("LS before %02x", d);
    wr(9, 8'hC1);
    n = 0;
    do begin rd(0, d); n++; end while (!(d & 8'h80) && n < 100000);
    $display("LS %02x after %0d polls (%0d clocks)", d, n, n * 3);
    rd(9, d); $display("buffer %02x", d);
    $finish;
end
endmodule
