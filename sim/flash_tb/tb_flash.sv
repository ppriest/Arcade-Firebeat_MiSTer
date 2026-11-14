// SPDX-License-Identifier: GPL-3.0-or-later
//
// fb_flash's blank chips: scripts/run_verilator.sh flash_tb
//
// The SDRAM model holds a pattern (old contents) and answers a word access after LAT clocks.
// Without the NVRAM file (loaded 0) every read must give 0xFF, before and after the pass, and the
// pass must leave 0xFF in all 6 MB; a CPU sector erase must mark its sector at once. With loaded 1
// reads give the SDRAM's bytes and nothing is written.
module tb_flash;
localparam int LAT = 8;
localparam int WORDS = 3 * 2 * 1024 * 1024 / 4;
logic clk = 0, reset = 1, por = 1, loaded = 0;
always #1 clk = !clk;

logic        c_req = 0, c_we = 0, c_ack;
logic [1:0]  c_chip = 0;
logic [20:0] c_addr = 0;
logic [7:0]  c_wdata = 0, c_rdata;
logic        y_req = 0, y_ack;
logic [21:0] y_addr = 0;
logic [7:0]  y_rdata;
logic        w_req, w_we, w_ack = 0;
logic [26:2] w_addr;
logic [3:0]  w_be;
logic [31:0] w_wdata, w_rdata;
logic        bad;

fb_flash u (.*, .st_a(6'd0), .st_d(), .st_we(1'b0), .st_wd(32'd0));

logic [31:0] mem [WORDS];
function automatic logic [31:0] pat(input int k); return 32'(k) * 32'h9E3779B1 ^ 32'h5A5AA5A5; endfunction
function automatic int widx(input logic [26:2] a); return int'(a) - (32'h2000000 >> 2); endfunction

int lat = 0, writes = 0;
always_ff @(posedge clk) begin
    w_ack <= 1'b0;
    if (w_req && !w_ack) begin
        if (lat == LAT) begin
            lat <= 0; w_ack <= 1'b1;
            if (w_we) begin
                writes <= writes + 1;
                for (int b = 0; b < 4; b++) if (w_be[3 - b]) mem[widx(w_addr)][31 - 8*b -: 8] <= w_wdata[31 - 8*b -: 8];
            end else w_rdata <= mem[widx(w_addr)];
        end else lat <= lat + 1;
    end
end

int errors = 0;
task automatic yread(input logic [21:0] a, input logic [7:0] want, input string what);
    @(posedge clk); y_addr <= a; y_req <= 1'b1;
    do @(posedge clk); while (!y_ack);
    y_req <= 1'b0;
    if (y_rdata !== want) begin errors++; $display("  %s: y %06X = %02X, want %02X", what, a, y_rdata, want); end
endtask
task automatic cread(input logic [1:0] k, input logic [20:0] a, input logic [7:0] want, input string what);
    @(posedge clk); c_chip <= k; c_addr <= a; c_we <= 1'b0; c_req <= 1'b1;
    do @(posedge clk); while (!c_ack);
    c_req <= 1'b0;
    if (c_rdata !== want) begin errors++; $display("  %s: c %0d:%06X = %02X, want %02X", what, k, a, c_rdata, want); end
endtask
task automatic cwrite(input logic [1:0] k, input logic [20:0] a, input logic [7:0] d);
    @(posedge clk); c_chip <= k; c_addr <= a; c_wdata <= d; c_we <= 1'b1; c_req <= 1'b1;
    do @(posedge clk); while (!c_ack);
    c_req <= 1'b0;
endtask
function automatic logic [7:0] old(input logic [1:0] k, input logic [20:0] a);
    int i; i = (int'(k) * 2097152 + int'(a)) / 4;
    return pat(i)[31 - 8 * (int'(a) % 4) -: 8];
endfunction

initial begin
    int t0, pass_clk, not_ff;
    for (int i = 0; i < WORDS; i++) mem[i] = pat(i);

    // ---- no NVRAM file
    repeat (4) @(posedge clk); por <= 0;
    repeat (4) @(posedge clk); reset <= 0;
    yread(22'h3F1234, 8'hFF, "blank snd2, before the pass");
    cread(2'd0, 21'h1F0000, 8'hFF, "blank main, before the pass");
    // a CPU sector erase of main sector 31: marked at once, and the pass skips it
    cwrite(2'd0, 21'h555, 8'hAA); cwrite(2'd0, 21'h2AA, 8'h55); cwrite(2'd0, 21'h555, 8'h80);
    cwrite(2'd0, 21'h555, 8'hAA); cwrite(2'd0, 21'h2AA, 8'h55); cwrite(2'd0, 21'h1F0000, 8'h30);
    if (!u.sv[0][31]) begin errors++; $display("  sector erase did not mark main sector 31"); end
    cwrite(2'd0, 21'h0, 8'hF0);  // reads return the status until MAME's timer: leave erase mode by reset
    t0 = $time;
    wait (u.f_p == 7'd96 && !u.e_on);
    pass_clk = ($time - t0) / 2;
    yread(22'h000000, 8'hFF, "snd1 after the pass");
    yread(22'h3FFFFF, 8'hFF, "snd2 after the pass");
    not_ff = 0;
    for (int i = 0; i < WORDS; i++) if (mem[i] !== 32'hFFFFFFFF) not_ff++;
    $display("no NVRAM: pass %0d clocks at latency %0d, %0d word writes, %0d words not 0xFF", pass_clk, LAT, writes, not_ff);
    if (not_ff != 0) errors++;

    // ---- the NVRAM file loaded: the SDRAM's bytes, nothing written
    for (int i = 0; i < WORDS; i++) mem[i] = pat(i);
    reset <= 1; por <= 1; loaded <= 1; writes = 0;
    repeat (4) @(posedge clk); por <= 0; reset <= 0;
    yread(22'h012345, old(2'd1, 21'h012345), "loaded snd1");
    yread(22'h3ABCDE, old(2'd2, 21'h1ABCDE), "loaded snd2");
    cread(2'd0, 21'h0F00F1, old(2'd0, 21'h0F00F1), "loaded main");
    repeat (2000) @(posedge clk);
    $display("loaded: %0d word writes", writes);
    if (writes != 0) errors++;

    if (errors == 0) $display("PASS"); else $display("FAIL: %0d", errors);
    $finish;
end
endmodule
