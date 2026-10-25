// SPDX-License-Identifier: GPL-3.0-or-later
// rtl/firebeat_sys.sv on the 128 MB SDRAM module's command-decoding model and a DDR3 memory model
// (Hornet's bench model: in-order reads lat clocks after the command, BUSY high busy_pct percent
// of the clocks). main.cpp drives the clocks and hps_io's side of the transfers.
module tb_sys (
    input  logic         clk,
    input  logic         clk_mem,
    input  logic         pll_locked,
    input  logic         hps_reset,         // also the DDR3 bridge's: in-flight reads are lost
    input  logic         hold,              // the board in reset

    input  logic         ioctl_download,
    input  logic [15:0]  ioctl_index,
    input  logic         ioctl_wr,
    input  logic [26:0]  ioctl_addr,
    input  logic [15:0]  ioctl_dout,
    input  logic         ioctl_upload,
    input  logic         ioctl_rd,
    output logic [15:0]  ioctl_din,
    output logic         ioctl_wait,

    output logic         ce_pix,
    output logic [7:0]   vid_r, vid_g, vid_b,
    output logic         vid_hs, vid_vs, vid_hb, vid_vb,

    input  logic         chk_start,
    input  logic         chk_sel,
    input  logic         pat_start,
    input  logic         pat_variant,
    output logic         chk_busy,
    output logic [31:0]  chk_sum,
    output logic [22:0]  chk_lines,
    output logic [31:0]  chk_lat_sum,
    output logic [7:0]   chk_lat_max,
    output logic [15:0]  scan_late,
    output logic         pat_done,
    output logic [15:0]  dl_kb,
    output logic [31:0]  brd_pc,
    output logic         brd_bad,
    output logic         brd_reset,

    input  logic [7:0]   ddr_lat,
    input  logic [7:0]   ddr_busy_pct
);
    wire  [15:0] SDRAM_DQ;
    logic [12:0] SDRAM_A;
    logic [1:0]  SDRAM_BA;
    logic        SDRAM_DQML, SDRAM_DQMH, SDRAM_nCS, SDRAM_nWE, SDRAM_nRAS, SDRAM_nCAS, SDRAM_CKE;

    logic        DDRAM_BUSY = 1'b0, DDRAM_DOUT_READY = 1'b0, DDRAM_RD, DDRAM_WE;
    logic [7:0]  DDRAM_BURSTCNT, DDRAM_BE;
    logic [28:0] DDRAM_ADDR;
    logic [63:0] DDRAM_DOUT = 64'd0, DDRAM_DIN;

    // the board's inputs, idle: no discs, no time, nothing pressed
    logic        pause = 1'b0;
    logic [64:0] hps_rtc = '0;
    logic [1:0]  img_mounted = 2'b00, sd_ack = 2'b00, sd_rd;
    logic [63:0] img_size = '0;
    logic [31:0] sd_lba [2];
    logic [5:0]  sd_blk_cnt [2];
    logic        sd_buff_wr = 1'b0;
    logic [15:0] sd_buff_dout = '0;
    logic [7:0]  in0 = 8'h7F, in1 = 8'hFF, in2 = 8'hFF, in3 = 8'hFF;
    logic [15:0] sensor [4] = '{16'd0, 16'd0, 16'd0, 16'd0};
    logic [3:0]  cabinet_info = 4'd8;

    firebeat_sys u (.reset(1'b0), .*);

    sdram_chip_model_128 u_chip (
        .clk(clk_mem), .SDRAM_DQ, .SDRAM_A, .SDRAM_BA, .SDRAM_nCS, .SDRAM_nWE, .SDRAM_nRAS,
        .SDRAM_nCAS
    );

    // ---------------------------------------------------------------- DDR3
    logic [63:0] mem [1 << 22];             // 32 MB: the DDR3 address's low 22 bits
    int          w_left = 0;
    logic [28:0] w_a;
    logic [28:0] rq_a [64];                 // reads due, a ring
    int          rq_n [64];
    longint      rq_t [64];
    int          rq_wp = 0, rq_rp = 0, r_k = 0;
    longint      now = 0;

    always @(posedge clk) begin
        now++;
        DDRAM_DOUT_READY <= 1'b0;
        if (rq_rp != rq_wp && rq_t[rq_rp] <= now) begin
            logic [28:0] a;
            a = rq_a[rq_rp] + 29'(r_k);
            DDRAM_DOUT_READY <= 1'b1;
            DDRAM_DOUT <= mem[a[21:0]];
            r_k++;
            if (r_k == rq_n[rq_rp]) begin r_k = 0; rq_rp = (rq_rp + 1) % 64; end
        end
        if (!DDRAM_BUSY && DDRAM_WE) begin
            logic [28:0] a;
            logic [63:0] d;
            if (w_left == 0) begin a = DDRAM_ADDR; w_left = int'(DDRAM_BURSTCNT); end else a = w_a;
            d = mem[a[21:0]];
            for (int k = 0; k < 8; k++) if (DDRAM_BE[k]) d[8*k +: 8] = DDRAM_DIN[8*k +: 8];
            mem[a[21:0]] = d;
            w_a = a + 29'd1;
            w_left--;
        end else if (!DDRAM_BUSY && DDRAM_RD) begin
            rq_a[rq_wp] = DDRAM_ADDR; rq_n[rq_wp] = int'(DDRAM_BURSTCNT);
            rq_t[rq_wp] = now + longint'(ddr_lat);
            rq_wp = (rq_wp + 1) % 64;
        end
        DDRAM_BUSY <= $urandom_range(0, 99) < int'(ddr_busy_pct);
        if (hps_reset) begin rq_rp = 0; rq_wp = 0; r_k = 0; w_left = 0; DDRAM_BUSY <= 1'b1; end
    end
endmodule
