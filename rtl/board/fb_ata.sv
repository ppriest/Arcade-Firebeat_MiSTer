// SPDX-License-Identifier: GPL-3.0-or-later
//
// firebeat's ATA interface (bus/ata/ataintf.cpp) with its two ATAPI CD-ROM drives: master (ata:0)
// the program CD, slave (ata:1) the audio CD (firebeat.cpp:744-749), each on an hps_io image slot.
//
// The bus side is MAME's internal 16-bit value of a register access, the caller swapping bytes
// as cs0_swap_r/w and cs1_swap_r/w do. A write reaches both drives; a read is answered by the drive
// that responds, else 0xFFFF (m_default_data). IRQ is either drive's. The drives see each other's
// DASP and PDIAG.

module fb_ata (
    input  logic        clk,
    input  logic        reset,
    input  logic        por,            // power-on: the slots' discs survive a board reset

    input  logic        req,            // held until ack
    input  logic        we,
    input  logic        cs1,
    input  logic [2:0]  off,
    input  logic [15:0] wdata,
    output logic        ack,
    output logic [15:0] rdata,
    output logic        irq,

    // the two slots (hps_io: shared data lines, an acknowledge each)
    input  logic [1:0]  img_mounted,
    input  logic [63:0] img_size,
    output logic [31:0] sd_lba [2],
    output logic [5:0]  sd_blk_cnt [2],
    output logic [1:0]  sd_rd,
    input  logic [1:0]  sd_ack,
    input  logic        sd_buff_wr,
    input  logic [15:0] sd_buff_dout,

    output logic [1:0]  play_on,
    output logic [31:0] play_lba [2],
    output logic signed [15:0] cd_l, cd_r,   // CD audio, both drives', at MAME's speaker gain
    output logic [1:0]  check,          // [Firebeat] a drive's CHECK CONDITION (fb_atapi check), the state dump's trigger
    output logic [3:0]  check_key [2],
    input  logic [7:0]  st_a,           // [Firebeat] the drives' register blocks (fb_atapi), drive st_a[7]
    output logic [31:0] st_d,
    input  logic        st_we,
    input  logic [31:0] st_wd,
    input  logic [11:0] lg_a,           // [Firebeat] the slave's access log: word lg_a[10:0], or the count
    output logic [31:0] lg_d,           // a clock after lg_a
    output logic        bad
);

// the drives' microsecond
logic        tick_us;
logic [6:0]  us_n;                      // 66.667 clocks a microsecond: 66, 67, 67 (3 x 200/3)
logic [1:0]  us_ph;
always_ff @(posedge clk) begin
    tick_us <= 1'b0;
    if (us_n == ((us_ph == 2'd0) ? 7'd65 : 7'd66)) begin
        us_n <= 7'd0; tick_us <= 1'b1; us_ph <= (us_ph == 2'd2) ? 2'd0 : us_ph + 2'd1;
    end else us_n <= us_n + 7'd1;
    if (reset) begin us_n <= '0; us_ph <= '0; end
end

// an access: the strobe, the drives' answer the clock after, latched, then the acknowledge
logic        acc, acc_q;
always_ff @(posedge clk) begin
    acc <= req && !acc && !acc_q && !ack;
    acc_q <= acc;
    ack <= acc_q;
    if (acc_q) rdata <= resp[0] ? rd[0] : resp[1] ? rd[1] : 16'hFFFF;
    if (reset) begin acc <= 1'b0; acc_q <= 1'b0; ack <= 1'b0; end
end

logic [1:0]  resp, irq_o, dasp_o, pdiag_o, have, dnew, rq, rq_done, bw_we, bad_d;
logic [15:0] rd [2];
logic [6:0]  ntrk [2], toc_a [2];
logic [31:0] toc_start [2], rq_lba [2];
logic [1:0]  toc_audio, rq_half;
logic [3:0]  toc_ctl [2];
logic [9:0]  bw_a [2];
logic [15:0] bw_d [2];
logic [9:0]  play_smp [2];
logic [1:0]  play_tick;
logic [7:0]  vol0 [2], vol1 [2];
logic signed [15:0] dl [2], dr [2];

logic [31:0] st_dd [2];
assign st_d = st_dd[st_a[7]];

genvar d;
generate for (d = 0; d < 2; d++) begin : g_drv
    fb_atapi #(.CSEL(d[0])) u_drv (
        .clk, .reset, .tick_us,
        .acc, .we, .cs1, .off, .wd(wdata), .resp(resp[d]), .rd(rd[d]),
        .irq_o(irq_o[d]), .dasp_o(dasp_o[d]), .pdiag_o(pdiag_o[d]),
        .dasp_i(dasp_o[1 - d]), .pdiag_i(pdiag_o[1 - d]),
        .have_disc(have[d]), .disc_new(dnew[d]), .ntrk(ntrk[d]), .toc_a(toc_a[d]),
        .toc_start(toc_start[d]), .toc_audio(toc_audio[d]), .toc_ctl(toc_ctl[d]),
        .rq(rq[d]), .rq_lba(rq_lba[d]), .rq_half(rq_half[d]), .rq_done(rq_done[d]),
        .bw_we(bw_we[d]), .bw_a(bw_a[d]), .bw_d(bw_d[d]),
        .play_on(play_on[d]), .play_lba(play_lba[d]), .play_smp(play_smp[d]), .play_tick(play_tick[d]),
        .vol0(vol0[d]), .vol1(vol1[d]),
        .check(check[d]), .check_key(check_key[d]),
        .st_a(st_a[6:0]), .st_d(st_dd[d]), .st_we(st_we && st_a[7] == d[0]), .st_wd,
        .bad(bad_d[d])
    );
    fb_cd_slot u_slot (
        .clk, .reset(por), .brd_reset(reset),
        .mounted(img_mounted[d]), .img_size,
        .sd_lba(sd_lba[d]), .sd_blk_cnt(sd_blk_cnt[d]), .sd_rd(sd_rd[d]), .sd_ack(sd_ack[d]),
        .sd_buff_wr, .sd_buff_dout,
        .have_disc(have[d]), .disc_new(dnew[d]), .ntrk(ntrk[d]), .toc_a(toc_a[d]),
        .toc_start(toc_start[d]), .toc_audio(toc_audio[d]), .toc_ctl(toc_ctl[d]),
        .rq(rq[d]), .rq_lba(rq_lba[d]), .rq_done(rq_done[d]),
        .bw_we(bw_we[d]), .bw_a(bw_a[d]), .bw_d(bw_d[d]),
        .play_on(play_on[d]), .play_lba(play_lba[d]), .play_smp(play_smp[d]), .play_tick(play_tick[d]),
        .vol0(vol0[d]), .vol1(vol1[d]), .cd_l(dl[d]), .cd_r(dr[d])
    );
end endgenerate

function automatic logic signed [15:0] sat_add(input logic signed [15:0] a, b);
    logic signed [16:0] x;
    x = 17'(a) + 17'(b);
    return (x > 17'sd32767) ? 16'sd32767 : (x < -17'sd32768) ? -16'sd32768 : x[15:0];
endfunction
always_ff @(posedge clk) begin
    cd_l <= sat_add(dl[0], dl[1]);
    cd_r <= sat_add(dr[0], dr[1]);
end

// [Firebeat] The slave drive's access log, for the state dump (docs/STATE.md): every access while
// the slave is selected, and every write to the device register. An access equal to the one before
// (direction, block, register, data) counts a repeat instead of taking an entry, so a status poll
// stays one entry. 1024 entries, a ring; lg_n counts every entry made. Word 0: [31] write,
// [30] cs1, [29:27] register, [25:16] repeats (saturating), [15:0] data. Word 1: the first access's
// time in microseconds.
logic        sel_dev;                   // the device register's DEV bit, as the drives latch it
logic [31:0] us_t, lg_n;
logic [31:0] lg_w0 [1024], lg_w1 [1024];
logic [31:0] lg_last;
logic        lg_we, lg_new;
logic [9:0]  lg_wa;
logic [31:0] lg_q0, lg_q1;
wire         lg_hit = acc_q && (sel_dev || (we && !cs1 && off == 3'd6));
wire  [15:0] lg_data = we ? wdata : (resp[0] ? rd[0] : resp[1] ? rd[1] : 16'hFFFF);
wire  [31:0] lg_ent = {we, cs1, off, 11'd0, lg_data};
always_ff @(posedge clk) begin
    if (tick_us) us_t <= us_t + 32'd1;
    if (acc && we && !cs1 && off == 3'd6) sel_dev <= wdata[4];
    lg_we <= 1'b0;
    if (lg_hit) begin
        lg_we <= 1'b1;
        if (lg_n != 32'd0 && {lg_last[31:26], lg_last[15:0]} == {lg_ent[31:26], lg_ent[15:0]}) begin
            lg_new <= 1'b0;
            if (lg_last[25:16] != 10'h3FF) lg_last[25:16] <= lg_last[25:16] + 10'd1;
        end else begin
            lg_new <= 1'b1;
            lg_last <= lg_ent;
            lg_wa <= lg_n[9:0];
            lg_n <= lg_n + 32'd1;
        end
    end
    if (por) begin us_t <= '0; lg_n <= '0; sel_dev <= 1'b0; lg_we <= 1'b0; end
end
always_ff @(posedge clk) begin
    if (lg_we) begin
        lg_w0[lg_wa] <= lg_last;
        if (lg_new) lg_w1[lg_wa] <= us_t;
    end
    lg_q0 <= lg_w0[lg_a[10:1]];
    lg_q1 <= lg_w1[lg_a[10:1]];
end
logic [11:0] lg_a_q;
always_ff @(posedge clk) lg_a_q <= lg_a;
assign lg_d = lg_a_q[11] ? lg_n : lg_a_q[0] ? lg_q1 : lg_q0;

assign irq = irq_o[0] || irq_o[1];
assign bad = bad_d[0] || bad_d[1];

endmodule
