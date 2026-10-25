// SPDX-License-Identifier: GPL-3.0-or-later
//
// One ATAPI CD-ROM drive as MAME runs it. CSEL 0 is the master (firebeat's program CD), 1 the
// slave (the audio CD).
//
// Protocol (machine/atahle.cpp, bus/ata/atapihle.cpp): the task file, reset and diagnostic with
// MAME's timers (device-1 detection, diagnostic and PDIAG wait 2 ms each; SET FEATURES and CACHE
// FLUSH 10 us), the ATA commands an ATAPI device takes, PACKET, and PIO through process_buffer,
// fill_buffer, wait_buffer, read_buffer_empty and write_buffer_full.
//
// Commands (bus/ata/atapicdr.cpp ExecCommand, machine/t10mmc.cpp, t10spc.cpp, sound/cdda.cpp): the
// media-change gate (UNIT ATTENTION 28h until TEST UNIT READY, after power-on or a new disc),
// TEST UNIT READY, REQUEST SENSE (with t10mmc's audio-status sense), INQUIRY, START STOP UNIT,
// PREVENT ALLOW, READ CAPACITY, READ(10), READ SUB-CHANNEL format 1, READ TOC format 0,
// PLAY AUDIO(10)/(12), STOP PLAY/SCAN, SET CD SPEED, MODE SELECT(10) (audio-page volumes kept for
// Phase 5); anything else completes with no data, as t10spc's default.
//
// Differences from MAME (HACKS): data for a transfer is produced while the drive shows BSY (MAME
// produces it inside the command write); a READ transfers at most one 2048-byte sector a DRQ
// (`bad` if the host's byte count asks for more: firebeat asks for 0x800); READ SUB-CHANNEL's
// index field is 1 (MAME's comes from track-index data its CHD path leaves unset); READ TOC
// formats other than 0, sub-channel formats other than 1 and MODE SENSE set `bad`.
//
// Access (fb_ata): a one-clock strobe; every drive takes every write; the selected drive answers
// a read (resp) with its data the clock after, MAME's internal 16-bit value (low byte first).

module fb_atapi #(
    parameter bit CSEL = 1'b0
) (
    input  logic        clk,
    input  logic        reset,
    input  logic        tick_us,

    input  logic        acc,
    input  logic        we,
    input  logic        cs1,
    input  logic [2:0]  off,
    input  logic [15:0] wd,
    output logic        resp,
    output logic [15:0] rd,

    output logic        irq_o,
    output logic        dasp_o,
    output logic        pdiag_o,
    input  logic        dasp_i,
    input  logic        pdiag_i,

    input  logic        have_disc,
    input  logic        disc_new,
    input  logic [6:0]  ntrk,
    output logic [6:0]  toc_a,          // entry ntrk is the lead-out
    input  logic [31:0] toc_start,
    input  logic        toc_audio,
    input  logic [3:0]  toc_ctl,

    output logic        rq,             // a sector's user data into half rq_half (one clock)
    output logic [31:0] rq_lba,
    output logic        rq_half,
    input  logic        rq_done,
    input  logic        bw_we,          // its words, into half rq_half
    input  logic [9:0]  bw_a,
    input  logic [15:0] bw_d,

    output logic        play_on,
    output logic [31:0] play_lba,
    output logic [7:0]  vol0, vol1,
    output logic        bad
);

localparam logic [2:0] P_RESET = 3'd0, P_DETECT = 3'd1, P_DIAG = 3'd2, P_PDIAG = 3'd3, P_CMD = 3'd4;
localparam logic [1:0] PH_NONE = 2'd0, PH_IN = 2'd1, PH_OUT = 2'd2;
localparam logic [15:0] ASC_NONE = 16'h0000, ASC_PLAYING = 16'h0011, ASC_DONE = 16'h0013,
                        ASC_STOPPED = 16'h0014;

// ============================================================================ the buffer
// two halves of 2 KB, even and odd bytes apart; index {half, word}
logic [7:0]  b_e [2048], b_o [2048];
logic        eb_we;                     // the engine's byte
logic [11:0] eb_a;                      // {half, byte}
logic [7:0]  eb_d;
logic [10:0] br_a;
logic [15:0] br_q;
always_ff @(posedge clk) begin
    if (bw_we) begin b_e[{rq_half, bw_a}] <= bw_d[7:0]; b_o[{rq_half, bw_a}] <= bw_d[15:8]; end
    else if (eb_we) begin
        if (eb_a[0]) b_o[{eb_a[11], eb_a[10:1]}] <= eb_d;
        else b_e[{eb_a[11], eb_a[10:1]}] <= eb_d;
    end
    br_q <= {b_o[br_a], b_e[br_a]};
end

// data-out bytes (MODE SELECT) and the packet
logic [7:0] dout [64];
logic [7:0] cmd [12];

// ============================================================================ engine <-> protocol
logic        x_go, x_done;              // ExecCommand
logic        x_check, x_dsc;
logic [1:0]  x_phase;
logic [31:0] x_len;
logic        f_go, f_done;              // ReadData of f_n bytes; f_dhalf: the half holding them
logic [15:0] f_n;
logic        f_dhalf;
logic        w_go, w_done;              // WriteData of w_n bytes from dout
logic [15:0] w_n;
logic [3:0]  skey;
logic        identify;                  // f_go for IDENTIFY PACKET DEVICE

// ============================================================================ protocol
logic [7:0]  status, error, feature, count, secnum, cyll, cylh, devhead, command, devctl;
logic        resetting, single, irq, packet;
logic        busy_on;
logic [2:0]  bparam;
logic [11:0] btmr;
logic [15:0] boff, bsize;
logic [31:0] dsize;
logic        pdiag_q;
logic        fill_wait, wout_wait;

wire selected = devhead[4] == CSEL;
assign irq_o = selected && !devctl[1] && irq;

always_ff @(posedge clk) begin
    logic do_fill, do_wbuf, do_sig;
    do_fill = 1'b0; do_wbuf = 1'b0; do_sig = 1'b0;
    resp <= 1'b0;
    x_go <= 1'b0; f_go <= 1'b0; w_go <= 1'b0;
    pdiag_q <= pdiag_i;

    // ---- busy timer: busy_tick, finished_busy
    if (busy_on && bparam != P_RESET && tick_us) begin
        if (btmr <= 12'd1) begin
            busy_on <= 1'b0;
            status[7] <= 1'b0;
            case (bparam)
            P_DETECT: begin             // single_device, then soft_reset
                single <= !dasp_i;
                boff <= '0; bsize <= '0; status <= 8'h80; busy_on <= 1'b1; btmr <= 12'd2000; bparam <= P_DIAG;
            end
            P_DIAG: begin               // start_diagnostic
                error <= 8'h01;
                if (CSEL) pdiag_o <= 1'b1;
                if (!CSEL && !single && !pdiag_q) begin status[7] <= 1'b1; busy_on <= 1'b1; btmr <= 12'd2000; bparam <= P_PDIAG; end
                else begin resetting <= 1'b0; do_sig = 1'b1; end
            end
            P_PDIAG: begin error <= 8'h81; resetting <= 1'b0; do_sig = 1'b1; end
            P_CMD:                      // finished_command
                case (command)
                8'h90: begin
                    error <= 8'h01;
                    if (CSEL) pdiag_o <= 1'b1;
                    resetting <= 1'b0; do_sig = 1'b1;
                    if (!CSEL) irq <= 1'b1;
                end
                8'hEF: begin
                    if (!set_features_ok(feature, count)) begin status[0] <= 1'b1; error <= 8'h04; end
                    irq <= 1'b1;
                end
                default: irq <= 1'b1;
                endcase
            default: ;
            endcase
        end else btmr <= btmr - 12'd1;
    end
    // set_pdiag_in
    if (!CSEL && pdiag_i && !pdiag_q && busy_on && bparam == P_PDIAG) begin
        busy_on <= 1'b0; status[7] <= 1'b0; resetting <= 1'b0; do_sig = 1'b1;
    end

    // ---- register access
    if (acc && !we) begin
        logic [15:0] v;
        v = 16'hFFFF;
        if (!cs1) case (off)
            3'd0: if (selected && !status[7] && status[3]) begin
                      v = br_q;
                      br_a <= br_a + 11'd1;
                      boff <= boff + 16'd2;
                      if (boff + 16'd2 >= bsize) begin    // read_buffer_empty
                          boff <= '0; status[3] <= 1'b0;
                          do_fill = 1'b1;
                      end
                  end
            3'd1: v = {8'hFF, error};
            3'd2: v = {8'hFF, count};
            3'd3: v = {8'hFF, secnum};
            3'd4: v = {8'hFF, cyll};
            3'd5: v = {8'hFF, cylh};
            3'd6: v = {8'hFF, devhead};
            3'd7: begin v = {8'hFF, selected ? status : 8'h00}; if (selected) irq <= 1'b0; end
        endcase
        else case (off)
            3'd6: v = {8'hFF, selected ? status : 8'h00};
            3'd7: v = {15'h7FFF, selected};
            default: ;
        endcase
        resp <= selected;
        rd <= v;
    end
    if (acc && we && !cs1) begin
        // command_w: a register other than data written during DRQ aborts the transfer
        if (status[3] && off != 3'd0 && (off != 3'd6 || wd[7:0] != devhead)) begin
            busy_on <= 1'b0; status[7] <= 1'b0; status[3] <= 1'b0; status[0] <= 1'b1; error <= 8'h04;
        end
        if (!(status[7] && !(off == 3'd7 && wd[7:0] == 8'h08))) case (off)
            3'd0: if (selected && status[3]) begin
                      if (packet) begin
                          cmd[boff[3:0]] <= wd[7:0]; cmd[boff[3:0] + 4'd1] <= wd[15:8];
                      end else begin
                          dout[boff[5:0]] <= wd[7:0]; dout[boff[5:0] + 6'd1] <= wd[15:8];
                      end
                      boff <= boff + 16'd2;
                      if (boff + 16'd2 >= bsize) begin    // write_buffer_full -> process_buffer
                          boff <= '0; status[3] <= 1'b0;
                          if (packet) begin packet <= 1'b0; error <= 8'h00; status[7] <= 1'b1; x_go <= 1'b1; end
                          else begin status[7] <= 1'b1; w_go <= 1'b1; w_n <= bsize; end
                      end
                  end
            3'd1: feature <= wd[7:0];
            3'd2: count <= wd[7:0];
            3'd3: secnum <= wd[7:0];
            3'd4: cyll <= wd[7:0];
            3'd5: cylh <= wd[7:0];
            3'd6: devhead <= wd[7:0];
            3'd7: if (selected || command == 8'h90) begin
                command <= wd[7:0];
                boff <= '0;
                status[0] <= 1'b0; error <= 8'h00;
                irq <= 1'b0; dasp_o <= 1'b0;
                packet <= 1'b0;
                case (wd[7:0])          // atapihle process_command
                8'h08: begin boff <= '0; bsize <= '0; status <= 8'h80; busy_on <= 1'b1; btmr <= 12'd2000; bparam <= P_DIAG; end
                8'h10, 8'hE1: irq <= 1'b1;
                8'hA0: begin status[3] <= 1'b1; count <= 8'h01; packet <= 1'b1; bsize <= 16'd12; end
                8'hA1: begin
                    // IDENTIFY PACKET DEVICE: 512 bytes of identify words, DRQ and INTRQ once
                    bsize <= 16'd512; error <= 8'h00; cyll <= 8'h00; cylh <= 8'h02;
                    status[7] <= 1'b1; f_go <= 1'b1; f_n <= 16'd512;
                end
                8'hEC: begin do_sig = 1'b1; status[0] <= 1'b1; error <= 8'h04; irq <= 1'b1; end
                8'hE5: begin count <= 8'hFF; irq <= 1'b1; end
                8'h90: begin status[7] <= 1'b1; busy_on <= 1'b1; btmr <= 12'd2000; bparam <= P_CMD; end
                8'hEF, 8'hE7: begin status[7] <= 1'b1; busy_on <= 1'b1; btmr <= 12'd10; bparam <= P_CMD; end
                default: begin status[0] <= 1'b1; error <= 8'h04; irq <= 1'b1; end
                endcase
                if (wd[7:0] == 8'h08 || wd[7:0] == 8'h90) status[6] <= 1'b0;
                else if (wd[7:0] != 8'hA0) status[6] <= 1'b1;
            end
            default: ;
        endcase
    end
    if (acc && we && cs1 && off == 3'd6) begin
        devctl <= wd[7:0];
        if ((devctl ^ wd[7:0]) & 8'h04) begin
            if (wd[2]) begin
                if (!resetting) begin dasp_o <= 1'b0; irq <= 1'b0; pdiag_o <= 1'b0; status[7] <= 1'b1; busy_on <= 1'b1; bparam <= P_RESET; end
            end else if (busy_on && bparam == P_RESET) begin
                boff <= '0; bsize <= '0; status <= 8'h80; btmr <= 12'd2000; bparam <= P_DIAG;
            end
        end
    end

    // ---- process_buffer after ExecCommand
    if (x_done) begin
        logic [15:0] c;
        status[7] <= 1'b0;
        if (x_check) begin status[0] <= 1'b1; error <= {skey, 4'h0}; end
        if (x_dsc) status[4] <= 1'b1;
        dsize <= x_len;
        c = {cylh, cyll};
        c = (c == 16'hFFFF) ? 16'hFFFE : c;
        c = (c == 16'd0 || c > 16'hF800) ? 16'hF800 : c;
        bsize <= c;
        case (x_phase)
        PH_OUT: do_wbuf = 1'b1;
        PH_IN: do_fill = 1'b1;
        default: begin cyll <= 8'h00; cylh <= 8'h00; count <= 8'h03; irq <= 1'b1; end
        endcase
    end
    if (w_done) begin                   // the PACKET command's data out written: wait_buffer
        status[7] <= 1'b0;
        dsize <= dsize - {16'd0, w_n};
        do_wbuf = 1'b1;
    end
    if (f_done) begin
        status[7] <= 1'b0;
        br_a <= {f_dhalf, 10'd0};
        status[3] <= 1'b1;
        if (command == 8'hA1) begin count <= 8'h02; irq <= 1'b1; end
        else begin count <= 8'h02; irq <= 1'b1; end
    end

    // ---- fill_buffer (sizes from the state after x_done / read_buffer_empty)
    if (do_fill) begin
        if (command == 8'hA0) begin
            logic [15:0] n, bs;
            logic [31:0] ds;
            bs = x_done ? bsize_next(cylh, cyll) : bsize;
            ds = x_done ? x_len : dsize;
            n = bs;
            if ({16'd0, n} >= ds) n = ds[15:0] & 16'hFFFE;
            else begin
                if (n[0]) n = n - 16'd1;
                if (cmd[0] == 8'h28 && n[10:0] != 11'd0) n = {n[15:11], 11'd0};
            end
            bsize <= n; cyll <= n[7:0]; cylh <= n[15:8];
            if (n != 16'd0) begin
                dsize <= ds - {16'd0, n};
                status[7] <= 1'b1;
                f_go <= 1'b1; f_n <= n;
            end else begin count <= 8'h03; irq <= 1'b1; end
        end else if (command == 8'hA1) begin
            cyll <= 8'h00; cylh <= 8'h00; count <= 8'h03;
        end
    end
    // ---- wait_buffer
    if (do_wbuf) begin
        logic [15:0] n, bs;
        logic [31:0] ds;
        bs = x_done ? bsize_next(cylh, cyll) : bsize;
        ds = x_done ? x_len : (dsize - {16'd0, w_n});
        n = bs;
        if ({16'd0, n} >= ds) n = ds[15:0];
        else if (n[0]) n = n - 16'd1;
        bsize <= n; cyll <= n[7:0]; cylh <= n[15:8];
        if (n != 16'd0) begin status[3] <= 1'b1; count <= 8'h00; irq <= 1'b1; end
        else begin count <= 8'h03; irq <= 1'b1; end
    end

    // ---- signature (finished_diagnostic, IDENTIFY DEVICE)
    if (do_sig) begin
        status[4] <= 1'b1; count <= 8'd1; secnum <= 8'd1; cyll <= 8'h14; cylh <= 8'hEB;
        devhead <= devhead & 8'h10;
    end

    if (reset) begin
        status <= 8'h80; devctl <= 8'h00; resetting <= 1'b1; irq <= 1'b0; dasp_o <= CSEL; pdiag_o <= 1'b0;
        error <= 8'h00; feature <= 8'h00; count <= 8'h00; secnum <= 8'h00; cyll <= 8'h00; cylh <= 8'h00;
        devhead <= 8'h00; command <= 8'h00; packet <= 1'b0; boff <= '0; bsize <= '0; single <= 1'b0;
        busy_on <= 1'b1; btmr <= 12'd2000; bparam <= CSEL ? P_DIAG : P_DETECT;
    end
end

function automatic logic [15:0] bsize_next(input logic [7:0] h, input logic [7:0] l);
    logic [15:0] c;
    c = {h, l};
    c = (c == 16'hFFFF) ? 16'hFFFE : c;
    return (c == 16'd0 || c > 16'hF800) ? 16'hF800 : c;
endfunction

function automatic logic set_features_ok(input logic [7:0] f, input logic [7:0] n);
    case (f)
    8'h01, 8'h81, 8'h66, 8'hCC, 8'h02, 8'h88, 8'hAA: return 1'b1;   // 8-bit, revert, ECC, retries, look-ahead
    8'h03:
        case (n[7:3])
        5'b00000: return n[2:0] <= 3'd1;            // PIO default
        5'b00001: return n[2:0] <= 3'd2;            // PIO flow control (identify word 64 is 0)
        default: return 1'b0;                       // DMA modes: identify words 62, 63, 88 are 0
        endcase
    default: return 1'b0;
    endcase
endfunction

// ============================================================================ the command engine
logic [3:0]  e_skey;
logic [7:0]  sasc, sascq;
logic        media_change;
logic [15:0] audio_sense;
logic [31:0] lba, blocks, last_lba;
logic        a_play, a_pause, a_ended;
logic [31:0] a_lba, a_len;
logic [9:0]  a_smp;
logic [21:0] a_acc;
logic        tick44;
logic [7:0]  ntoc;

assign skey = e_skey;
assign play_on = a_play && !a_pause;
assign play_lba = a_lba;

typedef enum logic [3:0] {
    G_IDLE, G_PLAY0, G_PLAY1, G_PLAY2, G_BYTE, G_SUBTRK, G_SUB2, G_MSF, G_WOUT, G_XDONE, G_LEAD
} g_t;
g_t          g;
logic [15:0] bi;                        // response byte index
logic [6:0]  t_i;                       // a track search
logic [31:0] t_lba;
logic [31:0] m_v;                       // MSF: the value being converted
logic [7:0]  m_m, m_s;
logic        m_sel;                     // 0 minutes, 1 seconds
logic        m_rel;                     // converting the relative frame (READ SUB-CHANNEL)
logic [31:0] msf_abs, msf_rel, t_rel;
logic        msf_ok;                    // msf_abs holds this READ TOC entry's start
logic        pf_on, pf_ok;
logic [31:0] pf_lba;
logic        pf_half;
logic        fetching;                  // a sector read under way
logic        fetch_host;                // ... for the host now (not a prefetch)
logic [7:0]  w_i;
logic        f_half_r;                  // the half a response or sector is in
logic [31:0] a_len_n;
assign f_dhalf = f_half_r;

// TOC lookups (asynchronous in fb_ata)
logic [6:0] toc_sel;
assign toc_a = toc_sel;
// the next track's start, for searches
logic [6:0] t_next;

function automatic logic [7:0] adrctl(input logic audio, input logic [3:0] ctl);
    return {4'h1, ctl | (audio ? 4'h0 : 4'h4)};
endfunction

// MAME's identify words (atapicdr device_start), low byte first
function automatic logic [7:0] ident_byte(input logic [8:0] i);
    logic [7:0]  w;
    logic [15:0] v;
    w = i[8:1];
    case (w)
    8'd0: v = 16'h8580;
    8'd23: v = {"1", "."}; 8'd24: v = {"0", " "};
    8'd27: v = {"M", "A"}; 8'd28: v = {"M", "E"};
    8'd31: v = {"V", "i"}; 8'd32: v = {"r", "t"}; 8'd33: v = {"u", "a"}; 8'd34: v = {"l", " "};
    8'd35: v = {"C", "D"}; 8'd36: v = {"R", "O"}; 8'd37: v = {"M", " "};
    8'd49: v = 16'h0600;
    default: v = (w >= 8'd23 && w <= 8'd46) ? {" ", " "} : 16'h0000;
    endcase
    return i[0] ? v[15:8] : v[7:0];
endfunction

// the response byte bi (READ TOC needs msf_abs of its entry, READ SUB-CHANNEL msf_abs/rel)
logic [7:0] bval;
logic       toc_entry_start;           // READ TOC: bi is the first byte of an entry
always_comb begin
    logic [7:0]  first, tr, i;
    logic [3:0]  k;
    logic [31:0] st;
    logic [15:0] len;
    bval = 8'h00;
    toc_entry_start = 1'b0;
    case (cmd[0])
    8'h03:
        if (cmd[4] == 8'd0) bval = (bi == 16'd0) ? {1'b0, sasc[6:0]} : 8'h00;
        else case (bi)
            16'd0: bval = 8'h70; 16'd2: bval = {4'h0, e_skey}; 16'd7: bval = 8'd10;
            16'd12: bval = sasc; 16'd13: bval = sascq;
            default: bval = 8'h00;
        endcase
    8'h12:
        case (bi)
        16'd0: bval = 8'h05; 16'd1: bval = 8'h80; 16'd2: bval = 8'h05; 16'd3: bval = 8'h02; 16'd4: bval = 8'h1F;
        16'd8: bval = "M"; 16'd9: bval = "A"; 16'd10: bval = "M"; 16'd11: bval = "E";
        16'd16: bval = "V"; 16'd17: bval = "i"; 16'd18: bval = "r"; 16'd19: bval = "t"; 16'd20: bval = "u";
        16'd21: bval = "a"; 16'd22: bval = "l"; 16'd24: bval = "C"; 16'd25: bval = "D"; 16'd26: bval = "R";
        16'd27: bval = "O"; 16'd28: bval = "M"; 16'd32: bval = "1"; 16'd33: bval = "."; 16'd34: bval = "0";
        default: bval = (bi >= 16'd8 && bi < 16'd36) ? " " : 8'h00;
        endcase
    8'h25: begin
        st = toc_start - 32'd1;
        case (bi)
        16'd0: bval = st[31:24]; 16'd1: bval = st[23:16]; 16'd2: bval = st[15:8]; 16'd3: bval = st[7:0];
        16'd6: bval = 8'h08; default: bval = 8'h00;
        endcase
    end
    8'h43: begin
        len = 16'd2 + {5'd0, ntoc, 3'd0};
        first = (cmd[6] == 8'd0) ? 8'd1 : cmd[6];
        if (bi < 16'd4) case (bi[1:0])
            2'd0: bval = len[15:8]; 2'd1: bval = len[7:0]; 2'd2: bval = 8'd1; default: bval = {1'b0, ntrk};
        endcase
        else begin
            i = 8'((bi - 16'd4) >> 3);
            k = 4'((bi - 16'd4) & 16'd7);
            toc_entry_start = k == 4'd0;
            tr = (i == ntoc - 8'd1) ? 8'hAA : first + i;
            st = cmd[1][1] ? msf_abs : toc_start;
            case (k)
            4'd1: bval = adrctl(toc_audio, toc_ctl);       // the lead-out: the last track's flags (below)
            4'd2: bval = tr;
            4'd4: bval = st[31:24]; 4'd5: bval = st[23:16]; 4'd6: bval = st[15:8]; 4'd7: bval = st[7:0];
            default: bval = 8'h00;
            endcase
        end
    end
    8'h42: begin
        case (bi)
        16'd1: bval = a_play ? (a_pause ? 8'h12 : 8'h11) : (a_ended ? 8'h13 : 8'h15);
        16'd3: bval = cmd[2][6] ? 8'd12 : 8'd0;
        16'd4: bval = cmd[2][6] ? 8'h01 : 8'h00;
        16'd5: bval = cmd[2][6] ? adrctl(toc_audio, toc_ctl) : 8'h00;
        16'd6: bval = cmd[2][6] ? {1'b0, t_i} + 8'd1 : 8'h00;
        16'd7: bval = cmd[2][6] ? 8'd1 : 8'h00;
        16'd8: bval = cmd[2][6] ? msf_abs[31:24] : 8'h00; 16'd9: bval = cmd[2][6] ? msf_abs[23:16] : 8'h00;
        16'd10: bval = cmd[2][6] ? msf_abs[15:8] : 8'h00; 16'd11: bval = cmd[2][6] ? msf_abs[7:0] : 8'h00;
        16'd12: bval = cmd[2][6] ? msf_rel[31:24] : 8'h00; 16'd13: bval = cmd[2][6] ? msf_rel[23:16] : 8'h00;
        16'd14: bval = cmd[2][6] ? msf_rel[15:8] : 8'h00; 16'd15: bval = cmd[2][6] ? msf_rel[7:0] : 8'h00;
        default: bval = 8'h00;
        endcase
    end
    default: ;
    endcase
end

// the TOC entry the engine reads: the response's entry, or a track search's
always_comb begin
    logic [7:0] first, tr, i;
    logic [3:0] k;
    toc_sel = t_i;
    case (cmd[0])
    8'h25: toc_sel = ntrk;
    8'h43:
        if (bi >= 16'd4) begin
            first = (cmd[6] == 8'd0) ? 8'd1 : cmd[6];
            i = 8'((bi - 16'd4) >> 3);
            k = 4'((bi - 16'd4) & 16'd7);
            tr = (i == ntoc - 8'd1) ? 8'hAA : first + i;
            toc_sel = (tr == 8'hAA) ? ((k == 4'd1) ? ntrk - 7'd1 : ntrk) : 7'(tr - 8'd1);
        end
    default: ;
    endcase
    // get_track: the next entry while searching, the lead-out, then the track found
    case (g)
    G_PLAY0: toc_sel = 7'd0;
    G_PLAY1, G_SUBTRK: toc_sel = t_next;
    G_LEAD: toc_sel = ntrk;
    G_PLAY2, G_SUB2: toc_sel = t_i;
    default: ;
    endcase
end
assign t_next = t_i + 7'd1;
logic t_play;                           // the search is PLAY AUDIO's (else READ SUB-CHANNEL's)

always_ff @(posedge clk) begin
    eb_we <= 1'b0;
    rq <= 1'b0;
    x_done <= 1'b0; f_done <= 1'b0; w_done <= 1'b0;

    // ---- CD audio (cdda: a sector of 588 samples at 44.1 kHz; ends at its length)
    tick44 <= 1'b0;
    if (a_acc >= 22'd1998677) begin a_acc <= a_acc - 22'd1998677; tick44 <= 1'b1; end
    else a_acc <= a_acc + 22'd1323;
    if (a_play && !a_pause && tick44) begin
        if (a_len == 32'd0) begin a_play <= 1'b0; a_ended <= 1'b1; end
        else if (a_smp == 10'd587) begin
            a_smp <= 10'd0; a_lba <= a_lba + 32'd1; a_len <= a_len - 32'd1;
            if (a_len == 32'd1) begin a_play <= 1'b0; a_ended <= 1'b1; end
        end else a_smp <= a_smp + 10'd1;
    end

    // ---- a sector read finishing
    if (rq_done && fetching) begin
        fetching <= 1'b0;
        if (fetch_host) begin
            fetch_host <= 1'b0;
            f_done <= 1'b1;
            lba <= lba + 32'd1; blocks <= blocks - 32'd1; last_lba <= lba + 32'd1;
            if (blocks > 32'd1) begin pf_on <= 1'b1; pf_ok <= 1'b0; pf_lba <= lba + 32'd1; pf_half <= !f_half_r; fetching <= 1'b1; rq <= 1'b1; rq_lba <= lba + 32'd1; rq_half <= !f_half_r; end
        end else pf_ok <= 1'b1;
    end

    // ---- ExecCommand
    if (x_go) begin
        logic [7:0] c0;
        c0 = cmd[0];
        x_check <= 1'b0; x_dsc <= 1'b0; x_phase <= PH_NONE; x_len <= '0;
        g <= G_XDONE;
        if ((c0 == 8'h00 || c0 == 8'h25 || c0 == 8'h28 || c0 == 8'h42 || c0 == 8'h43 || c0 == 8'h45 ||
             c0 == 8'h48 || c0 == 8'h4B || c0 == 8'hA5 || c0 == 8'hBE || c0 == 8'hA8 || c0 == 8'h2B) && !have_disc) begin
            x_check <= 1'b1; e_skey <= 4'h3; sasc <= 8'h3A; sascq <= 8'h00;
        end else if (media_change && c0 != 8'h12 && c0 != 8'h03) begin
            x_check <= 1'b1; e_skey <= 4'h6; sasc <= 8'h28; sascq <= 8'h00;
            if (c0 == 8'h00 || c0 == 8'h5A) media_change <= 1'b0;
        end else begin
            if (c0 == 8'h12 || c0 == 8'h03) media_change <= 1'b0;
            case (c0)
            8'h03: begin
                if (audio_sense != ASC_NONE && e_skey == 4'h0 && sasc == 8'h00 && sascq == 8'h00) begin
                    logic [15:0] as;
                    as = (audio_sense == ASC_PLAYING && !a_play) ? ASC_DONE : audio_sense;
                    sasc <= as[15:8]; sascq <= as[7:0];
                    audio_sense <= (as != ASC_PLAYING) ? ASC_NONE : as;
                end
                x_phase <= PH_IN;
                x_len <= (cmd[4] == 8'd0) ? 32'd4 : (cmd[4] > 8'd18) ? 32'd18 : {24'd0, cmd[4]};
            end
            8'h12: begin x_phase <= PH_IN; x_len <= (cmd[4] == 8'd0 || cmd[4] > 8'd36) ? 32'd36 : {24'd0, cmd[4]}; end
            8'h1B: if (a_play) begin a_play <= 1'b0; a_ended <= 1'b1; audio_sense <= ASC_STOPPED; end
            8'h25: begin x_phase <= PH_IN; x_len <= 32'd8; end
            8'h28: begin
                lba <= {cmd[2], cmd[3], cmd[4], cmd[5]};
                blocks <= {16'd0, cmd[7], cmd[8]};
                if (a_play) begin a_play <= 1'b0; a_ended <= 1'b1; audio_sense <= ASC_STOPPED; end
                x_phase <= PH_IN; x_len <= {5'd0, cmd[7], cmd[8], 11'd0};
                pf_on <= 1'b0; pf_ok <= 1'b0;
            end
            8'h42: begin
                x_phase <= PH_IN; x_len <= {16'd0, cmd[7], cmd[8]};
                if (cmd[3] != 8'd1) bad <= 1'b1;
            end
            8'h43: begin
                logic [7:0] n;
                logic [15:0] len, alloc;
                n = (cmd[6] == 8'd0) ? {1'b0, ntrk} + 8'd1 : (cmd[6] <= {1'b0, ntrk}) ? {1'b0, ntrk} - cmd[6] + 8'd2 :
                    (cmd[6] <= 8'hAA) ? 8'd1 : 8'd0;
                ntoc <= n;
                len = 16'd4 + {5'd0, n, 3'd0};
                alloc = {cmd[7], cmd[8]};
                if (cmd[2][3:0] != 4'd0 || cmd[9][7:6] != 2'd0) bad <= 1'b1;
                if (a_play) begin a_play <= 1'b0; a_ended <= 1'b1; audio_sense <= ASC_STOPPED; end
                x_phase <= PH_IN; x_len <= {16'd0, (len > alloc) ? alloc : len};
            end
            8'h45, 8'hA5: begin
                t_lba <= ({cmd[2], cmd[3], cmd[4], cmd[5]} == 32'hFFFF_FFFF) ? a_lba : {cmd[2], cmd[3], cmd[4], cmd[5]};
                a_len_n <= (c0 == 8'hA5) ? {cmd[6], cmd[7], cmd[8], cmd[9]} : {16'd0, cmd[7], cmd[8]};
                g <= G_PLAY0;
            end
            8'h4E: begin
                last_lba <= a_lba;
                if (a_play) begin a_play <= 1'b0; a_ended <= 1'b1; audio_sense <= ASC_STOPPED; end
            end
            8'h55: begin x_phase <= PH_OUT; x_len <= {16'd0, cmd[7], cmd[8]}; end
            8'h5A: bad <= 1'b1;
            default: ;
            endcase
        end
    end

    case (g)
    G_IDLE: ;
    G_XDONE: begin
        g <= G_IDLE;
        x_done <= 1'b1;
        if (!x_check && (cmd[0] == 8'h45 || cmd[0] == 8'hA5 || cmd[0] == 8'h2B || cmd[0] == 8'h47 || cmd[0] == 8'h48))
            x_dsc <= 1'b1;
    end
    // PLAY AUDIO: lba 0 is the first track's start if audio, else 150; then the lba's track
    G_PLAY0: begin
        if (t_lba == 32'd0) t_lba <= toc_audio ? toc_start : 32'd150;     // toc_a = 0
        t_i <= 7'd0;
        g <= G_PLAY1;
    end
    G_PLAY1:
        if (t_next < ntrk && t_lba >= toc_start) t_i <= t_next;
        else begin t_play <= 1'b1; g <= G_LEAD; end
    G_LEAD: begin                       // past the lead-out MAME's get_track finds no track: 0
        if (t_lba >= toc_start) t_i <= 7'd0;
        g <= t_play ? G_PLAY2 : G_SUB2;
    end
    G_PLAY2: begin
        if (toc_audio) begin
            a_play <= 1'b1; a_pause <= 1'b0; a_ended <= 1'b0; a_lba <= t_lba; a_len <= a_len_n; a_smp <= '0;
            audio_sense <= ASC_PLAYING;
        end else begin e_skey <= 4'h5; sasc <= 8'h64; sascq <= 8'h00; end
        g <= G_XDONE;
    end
    // READ SUB-CHANNEL: the position's track, then its MSFs, then the bytes
    G_SUBTRK:
        if (t_next < ntrk && t_lba >= toc_start) t_i <= t_next;
        else begin t_play <= 1'b0; g <= G_LEAD; end
    G_SUB2:
        if (cmd[1][1]) begin m_v <= t_lba + 32'd150; m_m <= '0; m_s <= '0; m_sel <= 1'b0; m_rel <= 1'b0; t_rel <= t_lba - toc_start; g <= G_MSF; end
        else begin msf_abs <= t_lba; msf_rel <= t_lba - toc_start; g <= G_BYTE; end
    G_MSF:
        if (!m_sel) begin
            if (m_v >= 32'd4500) begin m_v <= m_v - 32'd4500; m_m <= m_m + 8'd1; end
            else m_sel <= 1'b1;
        end else if (m_v >= 32'd75) begin m_v <= m_v - 32'd75; m_s <= m_s + 8'd1; end
        else begin
            // to_msf_raw: minutes mod 100
            logic [7:0] mm;
            mm = (m_m >= 8'd100) ? m_m - 8'd100 : m_m;
            if (cmd[0] == 8'h42 && m_rel) begin msf_rel <= {8'd0, mm, m_s, m_v[7:0]}; g <= G_BYTE; end
            else if (cmd[0] == 8'h42) begin
                msf_abs <= {8'd0, mm, m_s, m_v[7:0]};
                m_v <= t_rel; m_m <= '0; m_s <= '0; m_sel <= 1'b0; m_rel <= 1'b1;
            end else begin msf_abs <= {8'd0, mm, m_s, m_v[7:0]}; msf_ok <= 1'b1; g <= G_BYTE; end
        end
    // a response, a byte a clock, into half f_half_r
    G_BYTE:
        if (cmd[0] == 8'h43 && toc_entry_start && cmd[1][1] && !msf_ok) begin
            m_v <= toc_start + 32'd150; m_m <= '0; m_s <= '0; m_sel <= 1'b0; g <= G_MSF;
        end else begin
            msf_ok <= 1'b0;
            eb_we <= 1'b1; eb_a <= {f_half_r, bi[10:0]};
            eb_d <= identify ? ident_byte(bi[8:0]) : bval;
            bi <= bi + 16'd1;
            if (bi + 16'd1 == f_n) begin
                g <= G_IDLE; f_done <= 1'b1;
                if (!identify && cmd[0] == 8'h03) begin e_skey <= 4'h0; sasc <= 8'h00; sascq <= 8'h00; end
            end
        end
    G_WOUT:
        // MODE SELECT(10): block descriptors, then pages; the audio page (0Eh) gives the volumes
        if (w_i >= w_n[7:0] || w_i >= 8'd52) begin g <= G_IDLE; w_done <= 1'b1; end
        else if ((dout[w_i] & 8'h3F) == 8'h0E) begin
            vol0 <= dout[w_i + 8'd9]; vol1 <= dout[w_i + 8'd11];
            w_i <= w_i + dout[w_i + 8'd1] + 8'd2;
        end else w_i <= w_i + dout[w_i + 8'd1] + 8'd2;
    default: g <= G_IDLE;
    endcase

    // ---- ReadData requests
    if (f_go) begin
        f_half_r <= 1'b0;
        identify <= command == 8'hA1;
        bi <= '0;
        if (command == 8'hA1) g <= G_BYTE;
        else if (cmd[0] == 8'h28) begin
            if (f_n > 16'd2048) bad <= 1'b1;
            if (pf_on && pf_ok && pf_lba == lba) begin
                // the prefetched sector: the host takes it now
                f_half_r <= pf_half; f_done <= 1'b1;
                lba <= lba + 32'd1; blocks <= blocks - 32'd1; last_lba <= lba + 32'd1;
                pf_on <= 1'b0; pf_ok <= 1'b0;
                if (blocks > 32'd1) begin pf_on <= 1'b1; pf_lba <= lba + 32'd1; pf_half <= !pf_half; fetching <= 1'b1; rq <= 1'b1; rq_lba <= lba + 32'd1; rq_half <= !pf_half; end
            end else if (pf_on && fetching && pf_lba == lba) begin
                fetch_host <= 1'b1; f_half_r <= pf_half; pf_on <= 1'b0;
            end else begin
                fetch_host <= 1'b1; fetching <= 1'b1; rq <= 1'b1; rq_lba <= lba; rq_half <= 1'b0; f_half_r <= 1'b0;
                pf_on <= 1'b0; pf_ok <= 1'b0;
            end
        end else if (cmd[0] == 8'h42) begin
            t_lba <= a_play ? a_lba : 32'd0;
            if (a_play) last_lba <= a_lba; else last_lba <= 32'd0;
            t_i <= 7'd0;
            g <= cmd[2][6] ? G_SUBTRK : G_BYTE;
        end else g <= G_BYTE;
    end
    if (w_go) begin w_i <= 8'd8 + dout[7]; g <= G_WOUT; end   // the block descriptors' length (< 256)

    if (disc_new) media_change <= 1'b1;
    if (reset) begin
        g <= G_IDLE; media_change <= 1'b1; e_skey <= 4'h0; sasc <= 8'h00; sascq <= 8'h00;
        audio_sense <= ASC_NONE; a_play <= 1'b0; a_pause <= 1'b0; a_ended <= 1'b0; a_acc <= '0;
        pf_on <= 1'b0; pf_ok <= 1'b0; fetching <= 1'b0; fetch_host <= 1'b0; bad <= 1'b0;
        vol0 <= 8'hFF; vol1 <= 8'hFF; msf_ok <= 1'b0;
    end
end

endmodule
