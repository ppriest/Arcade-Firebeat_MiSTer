// SPDX-License-Identifier: GPL-3.0-or-later
//
// A DVD in an hps_io image slot, for the SPU's fb_atapi drive (Pop'n Music's data DVD).
//
// The image (MiSTer_Firebeat's support/firebeat, for a DVD CHD): the disc's 2,048-byte sectors
// back to back, sector n at byte 2048 n, four 512-byte blocks each. The TOC the drive sees is
// one data track from sector 0, the lead-out at the image's end.
//
// Requests and the hps_io handshake as fb_cd_slot's; the disc outlives a board reset.

module fb_dvd_slot (
    input  logic        clk,
    input  logic        reset,          // power-on
    input  logic        brd_reset,

    input  logic        mounted,
    input  logic [63:0] img_size,

    output logic [31:0] sd_lba,
    output logic [5:0]  sd_blk_cnt,
    output logic        sd_rd,
    input  logic        sd_ack,
    input  logic        sd_buff_wr,
    input  logic [15:0] sd_buff_dout,

    output logic        have_disc,
    output logic        disc_new,
    output logic [6:0]  ntrk,
    input  logic [6:0]  toc_a,
    output logic [31:0] toc_start,

    input  logic        rq,
    input  logic [31:0] rq_lba,
    output logic        rq_done,
    output logic        bw_we,
    output logic [9:0]  bw_a,
    output logic [15:0] bw_d
);

logic [31:0] sectors;
assign ntrk = 7'd1;
assign toc_start = (toc_a == 7'd0) ? 32'd0 : sectors;

typedef enum logic [1:0] { S_IDLE, S_ASK, S_XFER } s_t;
s_t          s;
logic [10:0] w;
logic [31:0] pend_lba;
logic        pend, drop;

always_ff @(posedge clk) begin
    disc_new <= 1'b0;
    rq_done <= 1'b0;
    bw_we <= 1'b0;
    if (rq) begin pend <= 1'b1; pend_lba <= rq_lba; end

    case (s)
    S_IDLE:
        if (pend && have_disc) begin
            sd_lba <= {pend_lba[29:0], 2'b00}; sd_blk_cnt <= 6'd3;
            sd_rd <= 1'b1; w <= '0; pend <= 1'b0;
            s <= S_ASK;
        end
    S_ASK: if (sd_ack) begin sd_rd <= 1'b0; s <= S_XFER; end
    S_XFER: begin
        if (sd_ack && sd_buff_wr) begin
            w <= w + 11'd1;
            if (!drop) begin bw_we <= 1'b1; bw_a <= w[9:0]; bw_d <= sd_buff_dout; end
        end
        if (!sd_ack && !sd_rd) begin
            rq_done <= !drop;
            drop <= 1'b0; s <= S_IDLE;
        end
    end
    default: s <= S_IDLE;
    endcase

    if (mounted) begin
        have_disc <= img_size != 64'd0; disc_new <= img_size != 64'd0;
        sectors <= img_size[42:11];
        s <= S_IDLE;
    end
    if (brd_reset) begin pend <= 1'b0; if (s == S_ASK || s == S_XFER) drop <= 1'b1; end
    if (reset) begin s <= S_IDLE; sd_rd <= 1'b0; have_disc <= 1'b0; pend <= 1'b0; drop <= 1'b0; end
end

endmodule
