// SPDX-License-Identifier: GPL-3.0-or-later
//
// A disc in an hps_io image slot, for one fb_atapi drive.
//
// The image (MiSTer_Firebeat's support/firebeat, sim/board_tb's server): the disc's frames by
// logical frame number (MAME's cdrom_file logical LBA), 2,352 bytes each, then padding to a 512-byte
// block, then two blocks of TOC:
//   bytes 0-3   "FBTC"
//   byte  4     tracks (n, 1-99); byte 5 version 1
//   8 + 8 i     entry i, i = 0..n (n: the lead-out): its logical start frame (4 bytes, little
//               endian), byte 4 bit 0 audio, byte 5 the control flags
// Without "FBTC" the image is taken as one data track from frame 0 to the end (HACKS).
//
// Requests from the drive: a frame's 2,048 bytes of user data (MODE1/2352: bytes 16-2063), as
// the 4 or 5 blocks that hold them, the words in that window written to the drive's buffer.
// hps_io's handshake: sd_rd held until sd_ack rises, words with sd_buff_wr while sd_ack is high,
// the request over when sd_ack falls.
//
// CD audio: whole frames (2,352 bytes, 588 stereo samples, little endian as the .bin holds them)
// into a ring of four, kept filled with play_lba and the three after it while the drive plays; a
// data request goes first. The sample play_lba/play_smp is output at each play_tick as
// sample * vol >>> 9 (MAME: the cdda route's 0.5 times MODE SELECT's vol / 255), 0 while the drive
// is not playing or the frame has not arrived (HACKS).
//
// The disc outlives a board reset (the OSD's "Reset" after mounting): `reset` is power-on only. A
// board reset drops the pending request and the rest of one in flight, whose words and done would
// otherwise reach the reset drive's next fetch.

module fb_cd_slot (
    input  logic        clk,
    input  logic        reset,          // power-on
    input  logic        brd_reset,

    input  logic        mounted,        // img_mounted for this slot
    input  logic [63:0] img_size,

    output logic [31:0] sd_lba,
    output logic [5:0]  sd_blk_cnt,
    output logic        sd_rd,
    input  logic        sd_ack,
    input  logic        sd_buff_wr,
    input  logic [15:0] sd_buff_dout,

    output logic        have_disc,
    output logic        disc_new,       // the TOC is in (one clock)
    output logic [6:0]  ntrk,
    input  logic [6:0]  toc_a,
    output logic [31:0] toc_start,
    output logic        toc_audio,
    output logic [3:0]  toc_ctl,

    input  logic        rq,
    input  logic [31:0] rq_lba,
    output logic        rq_done,
    output logic        bw_we,
    output logic [9:0]  bw_a,
    output logic [15:0] bw_d,

    input  logic        play_on,
    input  logic [31:0] play_lba,
    input  logic [9:0]  play_smp,
    input  logic        play_tick,
    input  logic [7:0]  vol0, vol1,
    output logic signed [15:0] cd_l, cd_r
);

// the audio ring: frame slot lba[1:0], word 2 * sample + channel
logic [15:0] ring [8192];
logic [31:0] tag [4];
logic        tag_ok [4];
logic        aud;                       // the transfer is an audio frame
logic [31:0] aud_lba;
logic        r_we;
logic [12:0] r_wa, r_ra;
logic [15:0] r_wd, r_q;
always_ff @(posedge clk) begin
    if (r_we) ring[r_wa] <= r_wd;
    r_q <= ring[r_ra];
end

// the first of play_lba .. play_lba + 3 not in the ring
logic        a_need;
logic [31:0] a_want;
always_comb begin
    a_need = 1'b0; a_want = play_lba;
    for (int k = 3; k >= 0; k--) begin
        logic [31:0] l;
        l = play_lba + 32'(k);
        if (!(tag_ok[l[1:0]] && tag[l[1:0]] == l)) begin a_need = 1'b1; a_want = l; end
    end
end

// the output: read L then R after each tick, scale
logic [2:0]  o_ph;
logic        o_ok;
always_ff @(posedge clk) begin
    o_ph <= {o_ph[1:0], 1'b0};
    if (play_tick) begin
        r_ra <= {play_lba[1:0], play_smp, 1'b0};
        o_ok <= tag_ok[play_lba[1:0]] && tag[play_lba[1:0]] == play_lba;
        o_ph <= 3'b001;
    end
    if (o_ph[0]) r_ra[0] <= 1'b1;
    if (o_ph[1]) cd_l <= o_ok ? 16'((24'($signed(r_q)) * $signed({16'd0, vol0})) >>> 9) : 16'sd0;
    if (o_ph[2]) cd_r <= o_ok ? 16'((24'($signed(r_q)) * $signed({16'd0, vol1})) >>> 9) : 16'sd0;
    if (!play_on) begin cd_l <= '0; cd_r <= '0; end
end


// the TOC, read asynchronously by the drive
logic [15:0] t_lo [128], t_hi [128];
logic [7:0]  t_fl [128], t_ct [128];
assign toc_start = {t_hi[toc_a], t_lo[toc_a]};
assign toc_audio = t_fl[toc_a][0];
assign toc_ctl   = t_ct[toc_a][3:0];

typedef enum logic [2:0] { S_IDLE, S_TOC, S_TOCX, S_ASK, S_XFER } s_t;
s_t          s;
logic [31:0] blocks;
logic [10:0] w;                         // the word in the transfer (5 blocks: 1,280)
logic [8:0]  o0;                        // the window's offset in the first block
logic        magic_ok;
logic [31:0] pend_lba;
logic        pend;
logic        drop;                      // the transfer in flight began before a board reset

always_ff @(posedge clk) begin
    disc_new <= 1'b0;
    rq_done <= 1'b0;
    bw_we <= 1'b0;
    r_we <= 1'b0;
    if (rq) begin pend <= 1'b1; pend_lba <= rq_lba; end

    case (s)
    S_IDLE:
        if (pend && have_disc) begin
            logic [31:0] st;
            st = {pend_lba[20:0], 11'd0} + {pend_lba[23:0], 8'd0} + {pend_lba[26:0], 5'd0} + {pend_lba[27:0], 4'd0} + 32'd16;
            sd_lba <= {9'd0, st[31:9]};
            o0 <= st[8:0];
            sd_blk_cnt <= (st[8:0] != 9'd0) ? 6'd4 : 6'd3;   // 5 blocks, or 4 when the window starts a block
            sd_rd <= 1'b1; w <= '0; pend <= 1'b0; aud <= 1'b0;
            s <= S_ASK;
        end else if (play_on && a_need && have_disc) begin
            // the frame's 2,352 bytes from byte lba * 2352: 5 blocks, or 6 past offset 208
            logic [31:0] st;
            st = {a_want[20:0], 11'd0} + {a_want[23:0], 8'd0} + {a_want[26:0], 5'd0} + {a_want[27:0], 4'd0};
            sd_lba <= {9'd0, st[31:9]};
            o0 <= st[8:0];
            sd_blk_cnt <= (st[8:0] > 9'd208) ? 6'd5 : 6'd4;
            sd_rd <= 1'b1; w <= '0; aud <= 1'b1; aud_lba <= a_want;
            tag_ok[a_want[1:0]] <= 1'b0;
            s <= S_ASK;
        end
    S_TOC: if (sd_ack) begin sd_rd <= 1'b0; s <= S_TOCX; end
    S_TOCX: begin
        if (sd_ack && sd_buff_wr) begin
            logic [7:0] i;
            w <= w + 11'd1;
            case (w)
            11'd0: magic_ok <= sd_buff_dout == 16'h4246;        // "FB"
            11'd1: magic_ok <= magic_ok && sd_buff_dout == 16'h4354;   // "TC"
            11'd2: ntrk <= sd_buff_dout[6:0];
            default: if (w >= 11'd4) begin
                i = 8'((w - 11'd4) >> 2);
                case (w[1:0])
                2'd0: t_lo[i[6:0]] <= sd_buff_dout;
                2'd1: t_hi[i[6:0]] <= sd_buff_dout;
                2'd2: begin t_fl[i[6:0]] <= sd_buff_dout[7:0]; t_ct[i[6:0]] <= sd_buff_dout[15:8]; end
                default: ;
                endcase
            end
            endcase
        end
        if (!sd_ack && !sd_rd) begin
            if (!magic_ok) begin
                // a plain image: one data track, the lead-out at the image's end (whole 2 KB frames)
                ntrk <= 7'd1;
                t_lo[0] <= 16'd0; t_hi[0] <= 16'd0; t_fl[0] <= 8'd0; t_ct[0] <= 8'd0;
                t_lo[1] <= img_size[26:11]; t_hi[1] <= {5'd0, img_size[37:27]}; t_fl[1] <= 8'd0; t_ct[1] <= 8'd0;
            end
            have_disc <= 1'b1; disc_new <= 1'b1;
            s <= S_IDLE;
        end
    end
    S_ASK: if (sd_ack) begin sd_rd <= 1'b0; s <= S_XFER; end
    S_XFER: begin
        if (sd_ack && sd_buff_wr) begin
            logic [11:0] p;
            w <= w + 11'd1;
            p = {w, 1'b0} - {3'b000, o0};
            if (aud) begin
                if ({w, 1'b0} >= {3'b000, o0} && p < 12'd2352) begin r_we <= 1'b1; r_wa <= {aud_lba[1:0], p[11:1]}; r_wd <= sd_buff_dout; end
            end else if ({w, 1'b0} >= {3'b000, o0} && p < 12'd2048 && !drop) begin bw_we <= 1'b1; bw_a <= p[10:1]; bw_d <= sd_buff_dout; end
        end
        if (!sd_ack && !sd_rd) begin
            if (aud) begin tag[aud_lba[1:0]] <= aud_lba; tag_ok[aud_lba[1:0]] <= !drop; end
            else rq_done <= !drop;
            drop <= 1'b0; s <= S_IDLE;
        end
    end
    default: s <= S_IDLE;
    endcase

    if (mounted) begin
        have_disc <= 1'b0;
        for (int k = 0; k < 4; k++) tag_ok[k] <= 1'b0;
        blocks <= img_size[40:9];
        if (img_size != 64'd0) begin
            sd_lba <= img_size[40:9] - 32'd2; sd_blk_cnt <= 6'd1; sd_rd <= 1'b1; w <= '0; magic_ok <= 1'b0;
            s <= S_TOC;
        end else s <= S_IDLE;
    end
    if (brd_reset) begin pend <= 1'b0; if (s == S_ASK || s == S_XFER) drop <= 1'b1; end
    if (reset) begin
        for (int k = 0; k < 4; k++) tag_ok[k] <= 1'b0;
        s <= S_IDLE; sd_rd <= 1'b0; have_disc <= 1'b0; pend <= 1'b0; drop <= 1'b0; ntrk <= 7'd0; end
end

endmodule
