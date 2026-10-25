// SPDX-License-Identifier: GPL-3.0-or-later
//
// The GCU's VRAM traffic on DDR3 through rtl/mister/hornet_ddr3.sv: the worst play frame ppp11
// showed in MAME (stage 2, HARDWARE_NOTES "Play": 504,881 object source pixels, 395,284
// destination, 94,765 blended, 393,216 fill, 149,684 uploaded words) as a blitter working one row
// at a time, beside the scan-out of two 512-pixel contexts a line (416 lines of 685 pixels at one
// pixel every 4 clocks, 2,740 clocks a line). All masters are wide (64 bits a handshake). The
// DDR3 is Hornet's bench model: read data in order, the first beat lat clocks after the command,
// BUSY high busy percent of the clocks.
//
//     scripts/run_verilator.sh vram_tb [+lat=N] [+busy=P] [+seed=N]
//
// Reports the blitter's clocks against a frame's (1,128,205 at 66.667 MHz) and the scan-out
// lines that were not fully read before their next line began.

`timescale 1ns/1ps

module tb_vram;

localparam int N = 4;                   // 0 blit writes, 1 source reads, 2 blend reads, 3 scan-out
logic clk = 0, reset = 1;
always #7.5 clk = !clk;                 // 66.667 MHz

logic [N-1:0]       m_read = '0, m_write = '0, m_waitn, m_rvalid;
logic [N-1:0][31:0] m_addr = '0, m_wdata = '0;
logic [N-1:0][10:0] m_burst = '0;
logic [N-1:0][3:0]  m_be = '0, m_be_hi = '0;
logic [N-1:0][31:0] m_wdata_hi = '0;
logic [N-1:0]       m_rready = '1;
logic [31:0]        m_rdata, m_rdata_hi;
localparam logic [N-1:0] WIDE = '1;

logic        DDRAM_BUSY = 0, DDRAM_DOUT_READY = 0, DDRAM_RD, DDRAM_WE;
logic [7:0]  DDRAM_BURSTCNT, DDRAM_BE;
logic [28:0] DDRAM_ADDR;
logic [63:0] DDRAM_DOUT = 0, DDRAM_DIN;
logic [23:0] dbg;
logic        drain = 0, idle;
logic [77:0] dbg_cmd;

hornet_ddr3 #(.N(N), .WIDE(WIDE)) dut (.*);

int lat = 20, busy_pct = 10, seed = 1;

// ---------------------------------------------------------------- the DDR3 model (Hornet's)
int          w_left = 0;
typedef struct { int n; longint t; } rd_t;
rd_t         rq [$];
int          rq_left = 0;
longint      now = 0;

always @(posedge clk) begin
    now++;
    DDRAM_DOUT_READY <= 0;
    if (rq.size() != 0 && rq[0].t <= now) begin
        DDRAM_DOUT_READY <= 1;
        DDRAM_DOUT <= 64'(now);
        if (rq_left == 0) rq_left = rq[0].n;
        rq_left--;
        if (rq_left == 0) void'(rq.pop_front());
    end
    if (!DDRAM_BUSY && DDRAM_WE) begin
        if (w_left == 0) w_left = DDRAM_BURSTCNT;
        w_left--;
    end else if (!DDRAM_BUSY && DDRAM_RD) begin
        rd_t r;
        r.n = int'(DDRAM_BURSTCNT);
        r.t = now + lat;
        rq.push_back(r);
    end
    DDRAM_BUSY <= $urandom_range(0, 99) < busy_pct;
end

// words each master still expects
int got [N];
for (genvar gi = 0; gi < N; gi++) begin : g_cnt
    always @(posedge clk) if (m_rvalid[gi]) got[gi] = got[gi] + 2;
end

// a read of n words (even) by master i, waiting for all of them
task automatic rd(input int i, input logic [31:0] a, input int n);
    int want;
    want = got[i] + n;
    @(posedge clk);
    m_read[i] <= 1; m_addr[i] <= a; m_burst[i] <= 11'(n);
    @(posedge clk);
    while (!m_waitn[i]) @(posedge clk);
    m_read[i] <= 0;
    while (got[i] < want) @(posedge clk);
endtask

// a write burst of n words (even) by master 0
task automatic wr(input logic [31:0] a, input int n);
    @(posedge clk);
    m_write[0] <= 1; m_addr[0] <= a; m_burst[0] <= 11'(n); m_be[0] <= 4'hF; m_be_hi[0] <= 4'hF;
    for (int k = 0; k < n; k += 2) begin
        m_wdata[0] <= 32'(k); m_wdata_hi[0] <= 32'(k + 1);
        @(posedge clk);
        while (!m_waitn[0]) @(posedge clk);
    end
    m_write[0] <= 0;
endtask

// ---------------------------------------------------------------- scan-out
localparam int LINE = 2740, LINES = 416, VIS = 384;
int late = 0, worst = 0;
longint line_t0;
bit blit_done = 0;

task automatic scanout();
    for (int frame = 0; !blit_done; frame++)
        for (int l = 0; l < LINES && !blit_done; l++) begin
            longint t0;
            t0 = now;
            if (l < VIS) begin
                rd(3, 32'h3000_0000 + l * 2048, 256);           // context A, 512 pixels
                rd(3, 32'h3080_0000 + l * 2048, 256);           // context B
                if (now - t0 > worst) worst = int'(now - t0);
                if (now - t0 > LINE) late++;
            end
            while (now - t0 < LINE) @(posedge clk);
        end
endtask

// ---------------------------------------------------------------- the blitter, a row at a time
longint blit_clocks;
task automatic blitter();
    longint t0;
    t0 = now;
    for (int r = 0; r < 768; r++) wr(32'h3000_0000 + r * 2048, 256);              // fills
    for (int r = 0; r < 3945; r++) begin                                           // objects
        logic [31:0] src, dst;
        src = 32'h3100_0000 + (r % 4096) * 2048;
        dst = 32'h3000_0000 + (r % 384) * 2048 + (r % 4) * 256;
        rd(1, src, 64);
        if (r < 740) rd(2, dst, 64);
        if (r < 3088) wr(dst, 64);
    end
    for (int r = 0; r < 1170; r++) wr(32'h3180_0000 + r * 512, 128);              // uploads
    blit_clocks = now - t0;
    blit_done = 1;
endtask

initial begin
    int r;
    if ($value$plusargs("seed=%d", seed)) ;
    if ($value$plusargs("lat=%d", lat)) ;
    if ($value$plusargs("busy=%d", busy_pct)) ;
    r = $urandom(seed);
    for (int i = 0; i < N; i++) got[i] = 0;
    repeat (5) @(posedge clk);
    reset = 0;
    repeat (5) @(posedge clk);
    fork
        blitter();
        scanout();
    join
    $display("lat %0d busy %0d%%: blitter %0d clocks (%.1f%% of a frame); scan-out lines late %0d, worst line %0d of %0d clocks",
             lat, busy_pct, blit_clocks, 100.0 * blit_clocks / 1128205.0, late, worst, LINE);
    $finish;
end

endmodule
