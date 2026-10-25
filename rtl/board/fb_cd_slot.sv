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

module fb_cd_slot (
    input  logic        clk,
    input  logic        reset,

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
    output logic [15:0] bw_d
);

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

always_ff @(posedge clk) begin
    disc_new <= 1'b0;
    rq_done <= 1'b0;
    bw_we <= 1'b0;
    if (rq) begin pend <= 1'b1; pend_lba <= rq_lba; end

    case (s)
    S_IDLE:
        if (pend && have_disc) begin
            logic [31:0] st;
            st = {pend_lba[20:0], 11'd0} + {pend_lba[23:0], 8'd0} + {pend_lba[26:0], 5'd0} + {pend_lba[27:0], 4'd0} + 32'd16;
            sd_lba <= {9'd0, st[31:9]};
            o0 <= st[8:0];
            sd_blk_cnt <= (st[8:0] != 9'd0) ? 6'd4 : 6'd3;   // 5 blocks, or 4 when the window starts a block
            sd_rd <= 1'b1; w <= '0; pend <= 1'b0;
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
            if ({w, 1'b0} >= {3'b000, o0} && p < 12'd2048) begin bw_we <= 1'b1; bw_a <= p[10:1]; bw_d <= sd_buff_dout; end
        end
        if (!sd_ack && !sd_rd) begin rq_done <= 1'b1; s <= S_IDLE; end
    end
    default: s <= S_IDLE;
    endcase

    if (mounted) begin
        have_disc <= 1'b0;
        blocks <= img_size[40:9];
        if (img_size != 64'd0) begin
            sd_lba <= img_size[40:9] - 32'd2; sd_blk_cnt <= 6'd1; sd_rd <= 1'b1; w <= '0; magic_ok <= 1'b0;
            s <= S_TOC;
        end else s <= S_IDLE;
    end
    if (reset) begin s <= S_IDLE; sd_rd <= 1'b0; have_disc <= 1'b0; pend <= 1'b0; ntrk <= 7'd0; end
end

endmodule
