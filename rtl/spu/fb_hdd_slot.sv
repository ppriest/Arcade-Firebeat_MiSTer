// SPDX-License-Identifier: GPL-3.0-or-later
//
// BM3: the hard disk in an hps_io image slot, for fb_atahdd.
//
// The image (MiSTer_Firebeat's support/firebeat for a hard disk CHD, ROADMAP Phase 10 "Media
// plan"): the disk's 512-byte sectors back to back, then one 512-byte block, "FBHD", version 1 at
// byte 4, and cylinders, heads, sectors a track and bytes a sector as 32-bit little-endian words at
// bytes 8, 12, 16 and 20. A mount reads that block; an image without it (a raw `chdman extracthd`
// image) is all sectors, with 16 heads and 64 sectors a track (HACKS: MAME guesses its own).
//
// A request is n sectors (1-8) from rq_lba; their words come out as bw_a 0 to 256 n - 1. The
// hps_io handshake as fb_dvd_slot's; the disk outlives a board reset (a request under way then is
// finished and dropped).

module fb_hdd_slot (
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

    output logic        have_disk,
    output logic [31:0] total,
    output logic [15:0] cyls,
    output logic [4:0]  heads,
    output logic [7:0]  spt,

    input  logic        rq,
    input  logic [31:0] rq_lba,
    input  logic [3:0]  rq_n,
    output logic        rq_done,
    output logic        bw_we,
    output logic [10:0] bw_a,
    output logic [15:0] bw_d
);

typedef enum logic [1:0] { S_IDLE, S_ASK, S_XFER } s_t;
s_t          s;
logic [11:0] w;
logic [31:0] pend_lba, blocks;
logic [3:0]  pend_n;
logic        pend, drop, geo, geo_ok;   // geo: this transfer is the FBHD block
logic [15:0] g_w [11];

always_ff @(posedge clk) begin
    rq_done <= 1'b0;
    bw_we <= 1'b0;
    if (rq) begin pend <= 1'b1; pend_lba <= rq_lba; pend_n <= rq_n; end

    case (s)
    S_IDLE:
        if (geo) begin
            sd_lba <= blocks - 32'd1; sd_blk_cnt <= 6'd0; sd_rd <= 1'b1; w <= '0; s <= S_ASK;
        end else if (pend && have_disk) begin
            sd_lba <= pend_lba; sd_blk_cnt <= {2'b00, pend_n - 4'd1};
            sd_rd <= 1'b1; w <= '0; pend <= 1'b0;
            s <= S_ASK;
        end
    S_ASK: if (sd_ack) begin sd_rd <= 1'b0; s <= S_XFER; end
    S_XFER: begin
        if (sd_ack && sd_buff_wr) begin
            w <= w + 12'd1;
            if (geo) begin if (w < 12'd11) g_w[w[3:0]] <= sd_buff_dout; end
            else if (!drop) begin bw_we <= 1'b1; bw_a <= w[10:0]; bw_d <= sd_buff_dout; end
        end
        if (!sd_ack && !sd_rd) begin
            if (geo) begin
                geo <= 1'b0; have_disk <= 1'b1;
                if (g_w[0] == 16'h4246 && g_w[1] == 16'h4448) begin     // "FBHD"
                    total <= blocks - 32'd1;
                    cyls <= g_w[4]; heads <= g_w[6][4:0]; spt <= g_w[8][7:0];
                end else begin
                    total <= blocks;
                    cyls <= blocks[25:10]; heads <= 5'd16; spt <= 8'd64;
                end
            end else rq_done <= !drop;
            drop <= 1'b0; s <= S_IDLE;
        end
    end
    default: s <= S_IDLE;
    endcase

    if (mounted) begin
        have_disk <= 1'b0;
        blocks <= img_size[40:9];
        geo <= img_size[63:9] != 55'd0;
        s <= S_IDLE;
    end
    if (brd_reset) begin pend <= 1'b0; if ((s == S_ASK || s == S_XFER) && !geo) drop <= 1'b1; end
    if (reset) begin
        s <= S_IDLE; sd_rd <= 1'b0; have_disk <= 1'b0; pend <= 1'b0; drop <= 1'b0; geo <= 1'b0;
        total <= '0; cyls <= '0; heads <= '0; spt <= '0;
    end
end

endmodule
