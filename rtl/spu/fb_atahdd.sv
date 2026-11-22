// SPDX-License-Identifier: GPL-3.0-or-later
//
// BM3: the SPU's hard disk as MAME runs it (IDE_HARDDISK: machine/atastorage.cpp on
// machine/atahle.cpp), the only device on its bus (master, no slave).
//
// Protocol (atahle): the task file, power-on reset (device-1 detection 2 ms, diagnostic 2 ms),
// soft reset through SRST, DIAGNOSTIC, SET FEATURES (atahle's set_features with the identify
// words' DMA modes), CACHE FLUSH; a register write during DRQ aborts the transfer; while BSY
// every register but data reads as the status. The status's IDX bit (ide_hdd_device_base
// calculate_status) is set on a status read 11.111 ms (one turn at 5,400 rpm) or more after the
// last read that showed it, counted from reset.
//
// Commands (atastorage process_command, finished_command, fill_buffer, finished_read):
//   20 21 READ SECTORS        an interrupt a sector
//   C4    READ MULTIPLE        an interrupt every SET MULTIPLE (C6) block, the first at sector 1
//   40 41 VERIFY SECTORS       no data; the interrupt at the last sector
//   C8    READ DMA             DMARQ a sector at a time; the interrupt at the last sector
//   EC    IDENTIFY DEVICE      MAME's identify words for the image's geometry
//   10 RECALIBRATE, 91 SET CONFIG, F8 READ NATIVE MAX (10 us, then the interrupt); 70 SEEK, C6,
//   E1 E3 F9 (the interrupt at once); anything else, the writes and the 48-bit commands included,
//   is aborted (ERR, ABRT, the interrupt), as atahle's default (HACKS: MAME takes a write's data
//   first and then fails it with BAD SECTOR).
// The first sector of a read comes after seek_time (400 ns on the same cylinder, else 13 ms x the
// cylinders crossed / the cylinders, + 1.3 ms); each later one 400 ns after the last word of the
// one before (READ MULTIPLE: at once). Times run in nanoseconds, NS a clock.
//
// Sectors arrive from the slot through a ring of 16 (8 KB): requests of up to 8 sectors, never
// across a 4 KB CHD hunk (8 sectors), run ahead of the host while there is room, past the end of
// a command too, so that a read that continues the last one finds its sectors waiting. A read at
// any other LBA empties the ring. A sector the timing has reached but the slot has not delivered
// keeps BSY up until it arrives (MAME's data is always there).
//
// Access as fb_atapi's: a one-clock strobe (acc, or dma_acc while dmarq), the answer the clock
// after (resp, rd), strobes at least two clocks apart. Reads return MAME's 16-bit value with the
// high byte 0xFF above an 8-bit register (as fb_atapi; HARDWARE_NOTES "bm3's boot against MAME").

module fb_atahdd #(
    parameter int NS = 15                   // nanoseconds a clock (66.667 MHz)
) (
    input  logic        clk,
    input  logic        reset,

    input  logic        acc,
    input  logic        we,
    input  logic        cs1,
    input  logic [2:0]  off,
    input  logic [15:0] wd,
    output logic        resp,
    output logic [15:0] rd,
    input  logic        dma_acc,
    output logic        dmarq,
    output logic        irq_o,

    input  logic        have_disk,          // the slot's image and geometry are valid
    input  logic [31:0] total,              // sectors in the image
    input  logic [15:0] cyls,
    input  logic [4:0]  heads,
    input  logic [7:0]  spt,

    output logic        rq,                 // n sectors from rq_lba into the ring from rq_slot (one clock)
    output logic [31:0] rq_lba,
    output logic [3:0]  rq_n,
    input  logic        rq_done,
    input  logic        bw_we,              // word bw_a of the request
    input  logic [10:0] bw_a,
    input  logic [15:0] bw_d,

    output logic        bad,                // a CHS address (not modelled: read as LBA)
    input  logic [5:0]  st_a,               // the state dump's register block (end of file)
    output logic [31:0] st_d,
    input  logic        st_we,
    input  logic [31:0] st_wd
);

localparam logic [2:0] P_RESET = 3'd0, P_DETECT = 3'd1, P_DIAG = 3'd2, P_PDIAG = 3'd3, P_CMD = 3'd4;
localparam logic [24:0] T_SECTOR = 25'd400, T_CMD = 25'd10_000, T_DIAG = 25'd2_000_000;
localparam logic [23:0] T_ROT = 24'd11_111_111;

// ============================================================================ the ring
logic [15:0] ring [4096];
logic [3:0]  r_head;                        // the slot of sector r_lba
logic [15:0] br_q;
logic [7:0]  b_off;                         // the word within the sector, the host's
logic [3:0]  f_slot;                        // the request's first slot
always_ff @(posedge clk) begin
    if (bw_we) ring[{f_slot + {1'b0, bw_a[10:8]}, bw_a[7:0]}] <= bw_d;
    br_q <= ring[{r_head, b_off}];
end

// ============================================================================ the drive
logic [7:0]  status, error, feature, count, secnum, cyll, cylh, devhead, command, devctl;
logic        resetting, single, irq, ident, dmarq_r;
logic        busy_on, rd_wait;              // rd_wait: finished_read waiting for its sector
logic [2:0]  bparam;
logic [24:0] btmr;
logic [8:0]  remain, until_int, block_count;
logic [7:0]  dma62, dma63;                  // the identify words' selected-mode bytes
logic [23:0] idx_ns;
// seek_time: the cylinder of the new LBA (a serial division), then 13 ms x the difference
logic [15:0] cur_cyl;
logic [12:0] cur_in;                        // cur_lba mod the sectors a cylinder
logic [12:0] spc;                           // heads x spt
logic [1:0]  sk;                            // 0 idle, 1 cylinder, 2 product, 3 time
logic [5:0]  sk_i;
logic [27:0] sk_q;                          // the quotient (the cylinder), then the multiplier
logic [39:0] sk_r;                          // the remainder, then the product, then its remainder
logic [39:0] sk_m;                          // 13,000,000, shifted a bit a clock
logic [24:0] sk_ns;                         // nanoseconds spent computing
// the ring
logic [31:0] r_lba, f_lba;
logic [4:0]  r_have;                        // complete sectors from r_head
logic        f_fly, f_on, flush;
logic [3:0]  f_n;

wire selected = !devhead[4];
wire is_read  = command == 8'h20 || command == 8'h21 || command == 8'hC4 || command == 8'h40 ||
                command == 8'h41 || command == 8'hC8;
wire verify   = command == 8'h40 || command == 8'h41;
wire multiple = command == 8'hC4;
wire [27:0] lba_reg = {devhead[3:0], cylh, cyll, secnum};
assign irq_o = selected && !devctl[1] && irq;
assign dmarq = dmarq_r;

// the free room in the ring and the next request's size: to the hunk's end, the image's end
wire [4:0]  in_ring = r_have + (f_fly ? {1'b0, f_n} : 5'd0);
wire [3:0]  to_hunk = 4'd8 - {1'b0, f_lba[2:0]};
wire [31:0] to_end  = total - f_lba;
wire [3:0]  next_n  = (to_end < {28'd0, to_hunk}) ? to_end[3:0] : to_hunk;

always_ff @(posedge clk) begin
    logic do_fread, do_empty, do_sig, consume;
    logic [7:0] st_v;
    do_fread = 1'b0; do_empty = 1'b0; do_sig = 1'b0; consume = 1'b0;
    resp <= 1'b0;
    rq <= 1'b0;
    bad <= 1'b0;
    if (idx_ns <= T_ROT) idx_ns <= idx_ns + NS[23:0];

    // calculate_status: IDX once a turn has passed since the last time it was shown
    st_v = status;
    if (idx_ns > T_ROT) st_v[1] = 1'b1;

    // ---- the ring's requests
    if (rq_done) begin f_fly <= 1'b0; r_have <= r_have + {1'b0, f_n}; end
    if (flush && !f_fly) begin
        flush <= 1'b0; r_have <= '0; r_head <= '0; f_slot <= '0; r_lba <= f_lba;
    end else if (f_on && !flush && !f_fly && !rq_done && have_disk && f_lba < total &&
                 5'd16 - in_ring >= {1'b0, next_n}) begin
        rq <= 1'b1; rq_lba <= f_lba; rq_n <= next_n; f_n <= next_n; f_fly <= 1'b1;
        f_slot <= r_head + r_have[3:0];
        f_lba <= f_lba + {28'd0, next_n};
    end

    // ---- seek_time
    if (sk != 2'd0) sk_ns <= sk_ns + NS[24:0];
    case (sk)
    2'd1: begin                             // lba_reg / spc, a bit a clock
        logic [13:0] t;
        t = {sk_r[12:0], sk_q[27]};
        if (t >= {1'b0, spc}) begin sk_r[12:0] <= t[12:0] - spc; sk_q <= {sk_q[26:0], 1'b1}; end
        else begin sk_r[12:0] <= t[12:0]; sk_q <= {sk_q[26:0], 1'b0}; end
        if (sk_i == 6'd27) sk <= 2'd2;
        sk_i <= sk_i + 6'd1;
    end
    2'd2: begin                             // the cylinder known: the difference, the product
        if (sk_i == 6'd28) begin
            logic [15:0] c, d;
            c = sk_q[15:0];
            d = (c > cur_cyl) ? c - cur_cyl : cur_cyl - c;
            cur_cyl <= c; cur_in <= sk_r[12:0];
            if (d == 16'd0 || cyls == 16'd0) begin
                sk <= 2'd0;
                btmr <= (sk_ns < T_SECTOR) ? T_SECTOR - sk_ns : 25'd1;
            end else begin sk_q <= {12'd0, d}; sk_r <= '0; sk_m <= 40'd13_000_000; sk_i <= 6'd29; end
        end else begin                      // 13,000,000 x d, a bit of d a clock
            if (sk_q[0]) sk_r <= sk_r + sk_m;
            sk_m <= sk_m << 1;
            sk_q <= sk_q >> 1;
            if (sk_i == 6'd44) begin sk <= 2'd3; sk_i <= '0; sk_q <= '0; end
            else sk_i <= sk_i + 6'd1;
        end
    end
    2'd3: begin                             // the product / cyls, the remainder in sk_q
        logic [16:0] t;
        logic [24:0] tm;
        if (sk_i == 6'd40) begin            // sk_r holds the quotient: the seek in ns
            sk <= 2'd0;
            tm = sk_r[24:0] + 25'd1_300_000;
            btmr <= (sk_ns < tm) ? tm - sk_ns : 25'd1;
        end else begin
            t = {sk_q[15:0], sk_r[39]};
            if (t >= {1'b0, cyls}) begin sk_q[15:0] <= t[15:0] - cyls; sk_r <= {sk_r[38:0], 1'b1}; end
            else begin sk_q[15:0] <= t[15:0]; sk_r <= {sk_r[38:0], 1'b0}; end
            sk_i <= sk_i + 6'd1;
        end
    end
    default: ;
    endcase

    // ---- busy timer: busy_tick, finished_busy
    if (busy_on && bparam != P_RESET && sk == 2'd0) begin
        if (btmr <= NS[24:0]) begin
            busy_on <= 1'b0;
            status[7] <= 1'b0;
            case (bparam)
            P_DETECT: begin                 // single_device (no device 1), then soft_reset
                single <= 1'b1;
                b_off <= '0; status <= 8'h90; busy_on <= 1'b1; btmr <= T_DIAG; bparam <= P_DIAG;
                cur_cyl <= '0; cur_in <= '0;
            end
            P_DIAG: begin                   // start_diagnostic; single, so no PDIAG wait
                error <= have_disk ? 8'h01 : 8'h00;
                resetting <= 1'b0; do_sig = 1'b1;
            end
            P_CMD:                          // finished_command
                case (command)
                8'h90: begin
                    error <= have_disk ? 8'h01 : 8'h00;
                    resetting <= 1'b0; do_sig = 1'b1; irq <= 1'b1;
                end
                8'hEF: begin
                    if (!set_features_ok(feature, count)) begin status[0] <= 1'b1; error <= 8'h04; end
                    else if (feature == 8'h03) begin
                        case (count[7:3])
                        5'b00001: if (count[2:0] >= 3'd3) begin dma62 <= 8'h00; dma63 <= 8'h00; end
                        5'b00010: begin dma62 <= 8'h01 << count[2:0]; dma63 <= 8'h00; end
                        5'b00100: begin dma62 <= 8'h00; dma63 <= 8'h01 << count[2:0]; end
                        default: ;
                        endcase
                    end
                    irq <= 1'b1;
                end
                8'hEC: begin
                    if (have_disk) begin status[3] <= 1'b1; ident <= 1'b1; b_off <= '0; end
                    else begin status[0] <= 1'b1; error <= 8'h00; end
                    irq <= 1'b1;
                end
                8'h20, 8'h21, 8'hC4, 8'h40, 8'h41, 8'hC8: do_fread = 1'b1;
                default: irq <= 1'b1;       // 10, 91, E7, F8
                endcase
            default: ;
            endcase
        end else btmr <= btmr - NS[24:0];
    end

    // ---- finished_read, retried while its sector has not arrived
    if (rd_wait) do_fread = 1'b1;
    if (do_fread) begin
        if (!have_disk) begin
            rd_wait <= 1'b0; status[7] <= 1'b0;
            status[0] <= 1'b1; error <= 8'h80; irq <= 1'b1;
        end else if (r_have == 5'd0 || flush) begin
            rd_wait <= 1'b1; status[7] <= 1'b1;
        end else begin
            logic [8:0] u;
            rd_wait <= 1'b0; status[7] <= 1'b0;
            if (remain != 9'd1) begin       // next_sector, LBA
                {devhead[3:0], cylh, cyll, secnum} <= lba_reg + 28'd1;
                if (cur_in + 13'd1 == spc) begin cur_in <= '0; cur_cyl <= cur_cyl + 16'd1; end
                else cur_in <= cur_in + 13'd1;
            end
            u = until_int - 9'd1;
            until_int <= u;
            if (u == 9'd0 || (remain == 9'd1 && !multiple)) begin
                until_int <= multiple ? block_count : 9'd1;
                irq <= 1'b1;
            end
            b_off <= '0;
            if (verify) do_empty = 1'b1;
            else begin
                status[3] <= 1'b1;
                if (command == 8'hC8) dmarq_r <= 1'b1;
            end
        end
    end

    // ---- register access
    if (acc && !we) begin
        logic [15:0] v;
        logic        sr;
        v = 16'hFFFF; sr = 1'b0;
        if (!cs1) begin
            if (status[7] && off != 3'd0) begin v = {8'hFF, selected ? st_v : 8'h00}; sr = 1'b1; end
            else case (off)
            3'd0: if (selected && status[3] && !status[7]) begin
                      v = ident ? id_word(b_off) : br_q;
                      b_off <= b_off + 8'd1;
                      if (b_off == 8'd255) do_empty = 1'b1;
                  end
            3'd1: v = {8'hFF, error};
            3'd2: v = {8'hFF, count};
            3'd3: v = {8'hFF, secnum};
            3'd4: v = {8'hFF, cyll};
            3'd5: v = {8'hFF, cylh};
            3'd6: v = {8'hFF, devhead};
            3'd7: begin v = {8'hFF, selected ? st_v : 8'h00}; sr = 1'b1; if (selected) irq <= 1'b0; end
            endcase
        end else case (off)
            3'd6: begin v = {8'hFF, selected ? st_v : 8'h00}; sr = 1'b1; end
            3'd7: v = {15'h7FFF, selected};
            default: ;
        endcase
        if (sr && selected && st_v[1]) idx_ns <= '0;
        resp <= selected;
        rd <= v;
    end
    if (dma_acc && dmarq_r) begin           // dma_r: read_data
        rd <= br_q;
        resp <= 1'b1;
        b_off <= b_off + 8'd1;
        if (b_off == 8'd255) do_empty = 1'b1;
    end
    if (acc && we && !cs1) begin
        // command_w: a register other than data written during DRQ aborts the transfer
        if (status[3] && off != 3'd0 && (off != 3'd6 || wd[7:0] != devhead)) begin
            busy_on <= 1'b0; rd_wait <= 1'b0; status[7] <= 1'b0; status[3] <= 1'b0; dmarq_r <= 1'b0;
            status[0] <= 1'b1; error <= 8'h04; ident <= 1'b0;
        end
        if (!status[7]) case (off)
            3'd1: feature <= wd[7:0];
            3'd2: count <= wd[7:0];
            3'd3: secnum <= wd[7:0];
            3'd4: cyll <= wd[7:0];
            3'd5: cylh <= wd[7:0];
            3'd6: devhead <= wd[7:0];
            3'd7: if (selected || command == 8'h90) begin
                command <= wd[7:0];
                b_off <= '0; ident <= 1'b0;
                status[0] <= 1'b0; error <= 8'h00;
                irq <= 1'b0;
                until_int <= '0;
                case (wd[7:0])
                8'h20, 8'h21, 8'hC4, 8'h40, 8'h41, 8'hC8: begin
                    // read_first_sector: seek_time, and the ring to the new LBA unless it continues
                    remain <= (count == 8'd0) ? 9'd256 : {1'b0, count};
                    until_int <= (wd[7:0] == 8'h40 || wd[7:0] == 8'h41 || wd[7:0] == 8'hC8)
                                 ? ((count == 8'd0) ? 9'd256 : {1'b0, count}) : 9'd1;
                    status[7] <= 1'b1; busy_on <= 1'b1; bparam <= P_CMD; btmr <= T_SECTOR;
                    sk <= 2'd1; sk_i <= '0; sk_q <= lba_reg; sk_r <= '0; sk_ns <= '0;
                    if (!devhead[6]) bad <= 1'b1;
                    if (!f_on || lba_reg != r_lba[27:0] || r_lba[31:28] != 4'd0) begin
                        f_on <= 1'b1; flush <= 1'b1; f_lba <= {4'd0, lba_reg};
                    end
                end
                8'hEC, 8'h10, 8'h91, 8'hF8, 8'hEF, 8'hE7: begin
                    status[7] <= 1'b1; busy_on <= 1'b1; btmr <= T_CMD; bparam <= P_CMD;
                end
                8'h90: begin status[7] <= 1'b1; busy_on <= 1'b1; btmr <= T_DIAG; bparam <= P_CMD; end
                8'hC6: begin block_count <= (count == 8'd0) ? 9'd256 : {1'b0, count}; irq <= 1'b1; end
                8'h70, 8'hE1, 8'hE3, 8'hF9: irq <= 1'b1;
                default: begin status[0] <= 1'b1; error <= 8'h04; irq <= 1'b1; end
                endcase
            end
            default: ;
        endcase
    end
    if (acc && we && cs1 && off == 3'd6) begin
        devctl <= wd[7:0];
        if (devctl[2] != wd[2]) begin
            if (wd[2]) begin
                if (!resetting) begin
                    dmarq_r <= 1'b0; irq <= 1'b0; rd_wait <= 1'b0; sk <= 2'd0;
                    status[7] <= 1'b1; busy_on <= 1'b1; bparam <= P_RESET;
                end
            end else if (busy_on && bparam == P_RESET) begin   // soft_reset
                b_off <= '0; status <= 8'h90; btmr <= T_DIAG; bparam <= P_DIAG;
                cur_cyl <= '0; cur_in <= '0;
            end
        end
    end

    // ---- read_buffer_empty, then fill_buffer
    if (do_empty) begin
        b_off <= '0;
        status[3] <= 1'b0; dmarq_r <= 1'b0;
        if (ident) ident <= 1'b0;
        else if (is_read) begin
            consume = 1'b1;
            if (remain != 9'd0) begin
                remain <= remain - 9'd1;
                count <= remain[7:0] - 8'd1;
            end
            if (remain > 9'd1) begin
                if (!multiple) begin            // READ MULTIPLE: finished_read at once (below)
                    irq <= 1'b0;
                    status[7] <= 1'b1; busy_on <= 1'b1; bparam <= P_CMD; btmr <= T_SECTOR;
                end
            end
        end
    end
    if (do_empty && !ident && is_read && remain > 9'd1 && multiple) rd_wait <= 1'b1;   // the next clock
    if (consume) begin
        r_head <= r_head + 4'd1; r_lba <= r_lba + 32'd1;
        r_have <= r_have - 5'd1 + ((rq_done) ? {1'b0, f_n} : 5'd0);
    end

    // ---- signature (finished_diagnostic)
    if (do_sig) begin
        if (have_disk) status[6] <= 1'b1;
        count <= 8'd1; secnum <= 8'd1; cyll <= 8'h00; cylh <= 8'h00; devhead <= 8'h00;
    end

    if (reset) begin
        status <= 8'h80; devctl <= 8'h00; resetting <= 1'b1; irq <= 1'b0; ident <= 1'b0; dmarq_r <= 1'b0;
        error <= 8'h00; feature <= 8'h00; count <= 8'h00; secnum <= 8'h00; cyll <= 8'h00; cylh <= 8'h00;
        devhead <= 8'h00; command <= 8'h00; b_off <= '0; single <= 1'b0; rd_wait <= 1'b0;
        remain <= '0; until_int <= '0; block_count <= 9'd256; dma62 <= 8'h00; dma63 <= 8'h04;
        idx_ns <= '0; sk <= 2'd0; sk_i <= '0; sk_q <= '0; sk_r <= '0; sk_m <= '0; sk_ns <= '0; cur_cyl <= '0; cur_in <= '0;
        busy_on <= 1'b1; btmr <= T_DIAG; bparam <= P_DETECT;
        r_have <= '0; r_head <= '0; f_fly <= 1'b0; f_on <= 1'b0; flush <= 1'b0; f_slot <= '0;
        r_lba <= '0; f_lba <= '0; f_n <= '0;
    end
`ifdef VERILATOR  // st_lists: write
    if (st_we) case (st_a)
    6'h0: idx_ns <= ($bits(idx_ns))'(st_wd);
    6'h1: f_fly <= ($bits(f_fly))'(st_wd);
    6'h2: r_have <= ($bits(r_have))'(st_wd);
    6'h3: flush <= ($bits(flush))'(st_wd);
    6'h4: r_head <= ($bits(r_head))'(st_wd);
    6'h5: f_slot <= ($bits(f_slot))'(st_wd);
    6'h6: r_lba <= ($bits(r_lba))'(st_wd);
    6'h7: rq_lba <= ($bits(rq_lba))'(st_wd);
    6'h8: rq_n <= ($bits(rq_n))'(st_wd);
    6'h9: f_n <= ($bits(f_n))'(st_wd);
    6'hA: f_lba <= ($bits(f_lba))'(st_wd);
    6'hB: sk_ns <= ($bits(sk_ns))'(st_wd);
    6'hC: sk_r[31:0] <= ($bits(sk_r[31:0]))'(st_wd);
    6'hD: sk_r[39:32] <= ($bits(sk_r[39:32]))'(st_wd);
    6'hE: sk_q <= ($bits(sk_q))'(st_wd);
    6'hF: sk <= ($bits(sk))'(st_wd);
    6'h10: sk_i <= ($bits(sk_i))'(st_wd);
    6'h11: cur_cyl <= ($bits(cur_cyl))'(st_wd);
    6'h12: cur_in <= ($bits(cur_in))'(st_wd);
    6'h13: btmr <= ($bits(btmr))'(st_wd);
    6'h14: sk_m[31:0] <= ($bits(sk_m[31:0]))'(st_wd);
    6'h15: sk_m[39:32] <= ($bits(sk_m[39:32]))'(st_wd);
    6'h16: busy_on <= ($bits(busy_on))'(st_wd);
    6'h17: status <= ($bits(status))'(st_wd);
    6'h18: single <= ($bits(single))'(st_wd);
    6'h19: b_off <= ($bits(b_off))'(st_wd);
    6'h1A: bparam <= ($bits(bparam))'(st_wd);
    6'h1B: error <= ($bits(error))'(st_wd);
    6'h1C: resetting <= ($bits(resetting))'(st_wd);
    6'h1D: irq <= ($bits(irq))'(st_wd);
    6'h1E: dma62 <= ($bits(dma62))'(st_wd);
    6'h1F: dma63 <= ($bits(dma63))'(st_wd);
    6'h20: ident <= ($bits(ident))'(st_wd);
    6'h21: rd_wait <= ($bits(rd_wait))'(st_wd);
    6'h22: until_int <= ($bits(until_int))'(st_wd);
    6'h23: dmarq_r <= ($bits(dmarq_r))'(st_wd);
    6'h24: rd <= ($bits(rd))'(st_wd);
    6'h25: feature <= ($bits(feature))'(st_wd);
    6'h26: count <= ($bits(count))'(st_wd);
    6'h27: secnum <= ($bits(secnum))'(st_wd);
    6'h28: cyll <= ($bits(cyll))'(st_wd);
    6'h29: cylh <= ($bits(cylh))'(st_wd);
    6'h2A: devhead <= ($bits(devhead))'(st_wd);
    6'h2B: command <= ($bits(command))'(st_wd);
    6'h2C: remain <= ($bits(remain))'(st_wd);
    6'h2D: f_on <= ($bits(f_on))'(st_wd);
    6'h2E: block_count <= ($bits(block_count))'(st_wd);
    6'h2F: devctl <= ($bits(devctl))'(st_wd);
    default: ;
    endcase
`endif  // st_lists: write
end

// spc = heads x spt, by shift and add when the geometry changes
logic [12:0] spc_acc;
logic [2:0]  spc_i;
logic [4:0]  g_heads;
logic [7:0]  g_spt;
always_ff @(posedge clk) begin
    if (heads != g_heads || spt != g_spt) begin
        g_heads <= heads; g_spt <= spt; spc_i <= '0; spc_acc <= '0;
    end else if (spc_i != 3'd5) begin
        if (g_heads[spc_i]) spc_acc <= spc_acc + ({5'd0, g_spt} << spc_i);
        spc_i <= spc_i + 3'd1;
    end else spc <= spc_acc;
`ifdef VERILATOR  // st_lists: write
    if (st_we) case (st_a)
    6'h30: g_heads <= ($bits(g_heads))'(st_wd);
    6'h31: g_spt <= ($bits(g_spt))'(st_wd);
    6'h32: spc_i <= ($bits(spc_i))'(st_wd);
    6'h33: spc_acc <= ($bits(spc_acc))'(st_wd);
    6'h34: spc <= ($bits(spc))'(st_wd);
    default: ;
    endcase
`endif  // st_lists: write
end

// IDENTIFY DEVICE: ide_build_identify_device for the image's geometry
wire        chs_cap = total >= 32'd16_514_064;
function automatic logic [15:0] id_word(input logic [7:0] w);
    case (w)
    8'd0:  return 16'h045A;
    8'd1:  return chs_cap ? 16'd16383 : cyls;
    8'd3:  return chs_cap ? 16'd16 : {11'd0, heads};
    8'd6:  return chs_cap ? 16'd63 : {8'd0, spt};
    8'd10, 8'd11, 8'd12, 8'd13, 8'd14, 8'd15, 8'd16, 8'd17, 8'd18, 8'd19: return 16'h3030;
    8'd22: return 16'd4;
    8'd23: return 16'h312E;                 // "1.0"
    8'd24: return 16'h3020;
    8'd25, 8'd26: return 16'h2020;
    8'd27: return 16'h4D41;                 // "MAME    Virtual Hard Disk"
    8'd28: return 16'h4D45;
    8'd29, 8'd30: return 16'h2020;
    8'd31: return 16'h5669;
    8'd32: return 16'h7274;
    8'd33: return 16'h7561;
    8'd34: return 16'h6C20;
    8'd35: return 16'h4861;
    8'd36: return 16'h7264;
    8'd37: return 16'h2044;
    8'd38: return 16'h6973;
    8'd39: return 16'h6B20;
    8'd40, 8'd41, 8'd42, 8'd43, 8'd44, 8'd45, 8'd46: return 16'h2020;
    8'd47: return 16'h8010;
    8'd49: return 16'h0F03;
    8'd51, 8'd52: return 16'd2;
    8'd53: return 16'd3;
    8'd54: return chs_cap ? 16'd16383 : cyls;
    8'd55: return chs_cap ? 16'd16 : {11'd0, heads};
    8'd56: return chs_cap ? 16'd63 : {8'd0, spt};
    8'd57: return chs_cap ? 16'hFC10 : total[15:0];             // 16,514,064
    8'd58: return chs_cap ? 16'h00FB : total[31:16];
    8'd60: return (total > 32'h0FFF_FFFF) ? 16'hFFFF : total[15:0];
    8'd61: return (total > 32'h0FFF_FFFF) ? 16'h0FFF : total[31:16];
    8'd62: return {dma62, 8'h07};
    8'd63: return {dma63, 8'h07};
    8'd64: return 16'h0003;
    8'd65, 8'd66, 8'd68: return 16'h0078;
    8'd67: return 16'h014D;
    default: return 16'h0000;
    endcase
endfunction

// atahle set_features with this drive's identify words (62 0x0007, 63 0x0007, 64 0x0003, 88 0)
function automatic logic set_features_ok(input logic [7:0] f, input logic [7:0] n);
    case (f)
    8'h01, 8'h81, 8'h66, 8'hCC, 8'h02, 8'h88, 8'hAA: return 1'b1;
    8'h03:
        case (n[7:3])
        5'b00000: return n[2:0] <= 3'd1;            // PIO default
        5'b00001: return n[2:0] <= 3'd4;            // PIO flow control: 0-2, and 3-4 from word 64
        5'b00010, 5'b00100: return n[2:0] <= 3'd2;  // single- and multi-word DMA 0-2
        default: return 1'b0;                       // Ultra DMA: word 88 is 0
        endcase
    default: return 1'b0;
    endcase
endfunction

// st_lists: begin
// [Firebeat] The state dump's register block (docs/STATE.md), generated by scripts/st_lists.py:
// a word a register, in the order of its always_ff block; written in Verilator only.
always_comb begin
    st_d = 32'd0;
    case (st_a)
    6'h0: st_d = 32'(idx_ns);
    6'h1: st_d = 32'(f_fly);
    6'h2: st_d = 32'(r_have);
    6'h3: st_d = 32'(flush);
    6'h4: st_d = 32'(r_head);
    6'h5: st_d = 32'(f_slot);
    6'h6: st_d = 32'(r_lba);
    6'h7: st_d = 32'(rq_lba);
    6'h8: st_d = 32'(rq_n);
    6'h9: st_d = 32'(f_n);
    6'hA: st_d = 32'(f_lba);
    6'hB: st_d = 32'(sk_ns);
    6'hC: st_d = 32'(sk_r[31:0]);
    6'hD: st_d = 32'(sk_r[39:32]);
    6'hE: st_d = 32'(sk_q);
    6'hF: st_d = 32'(sk);
    6'h10: st_d = 32'(sk_i);
    6'h11: st_d = 32'(cur_cyl);
    6'h12: st_d = 32'(cur_in);
    6'h13: st_d = 32'(btmr);
    6'h14: st_d = 32'(sk_m[31:0]);
    6'h15: st_d = 32'(sk_m[39:32]);
    6'h16: st_d = 32'(busy_on);
    6'h17: st_d = 32'(status);
    6'h18: st_d = 32'(single);
    6'h19: st_d = 32'(b_off);
    6'h1A: st_d = 32'(bparam);
    6'h1B: st_d = 32'(error);
    6'h1C: st_d = 32'(resetting);
    6'h1D: st_d = 32'(irq);
    6'h1E: st_d = 32'(dma62);
    6'h1F: st_d = 32'(dma63);
    6'h20: st_d = 32'(ident);
    6'h21: st_d = 32'(rd_wait);
    6'h22: st_d = 32'(until_int);
    6'h23: st_d = 32'(dmarq_r);
    6'h24: st_d = 32'(rd);
    6'h25: st_d = 32'(feature);
    6'h26: st_d = 32'(count);
    6'h27: st_d = 32'(secnum);
    6'h28: st_d = 32'(cyll);
    6'h29: st_d = 32'(cylh);
    6'h2A: st_d = 32'(devhead);
    6'h2B: st_d = 32'(command);
    6'h2C: st_d = 32'(remain);
    6'h2D: st_d = 32'(f_on);
    6'h2E: st_d = 32'(block_count);
    6'h2F: st_d = 32'(devctl);
    6'h30: st_d = 32'(g_heads);
    6'h31: st_d = 32'(g_spt);
    6'h32: st_d = 32'(spc_i);
    6'h33: st_d = 32'(spc_acc);
    6'h34: st_d = 32'(spc);
    default: ;
    endcase
end
// st_lists: end

endmodule
