// SPDX-License-Identifier: GPL-3.0-or-later
//
// Phase 0 item 2: how fast an image mounted in an hps_io slot can be read, from a core launched
// by an .mra. One instance per slot. While `run` is high it issues read requests of
// (BLKCNT+1) x 512-byte blocks, one after another: sequentially from block 0 (wrapping at the
// image's end), or at pseudo-random blocks when `rnd` is high. It counts what came back and how
// long each request took, for the ISSP probe (FirebeatCD.sv lays the bus out).
//
// The request handshake is hps_io's: sd_rd is held until sd_ack rises; the data arrive as
// sd_buff_wr strobes while sd_ack is high; the request is over when sd_ack falls.

module cd_reader #(
    parameter int BLKCNT = 31                   // blocks per request, minus one (16 KB)
) (
    input  logic        clk,
    input  logic        clear,                  // zero the counters
    input  logic        run,
    input  logic        rnd,

    input  logic        mounted,                // img_mounted for this slot (a pulse)
    input  logic [63:0] img_size,

    output logic [31:0] sd_lba,
    output logic [5:0]  sd_blk_cnt,
    output logic        sd_rd,
    input  logic        sd_ack,
    input  logic        sd_buff_wr,             // with sd_ack: a data word for this slot
    input  logic [15:0] sd_buff_dout,

    output logic        have_image,
    output logic [31:0] image_blocks,           // 512-byte blocks in the image
    output logic [31:0] requests,               // completed requests
    output logic [31:0] words,                  // data words received
    output logic [31:0] run_clocks,             // clocks with run high
    output logic [31:0] latency_sum,            // clocks from sd_rd to the first data word
    output logic [31:0] latency_max,
    output logic [31:0] checksum                // sum of the first 2,048 words read from block 0
);

assign sd_blk_cnt = 6'(BLKCNT);

typedef enum logic [1:0] { IDLE, ASK, XFER } state_t;
state_t st;
logic        ack_d, first;
logic [31:0] lat, next_lba;
logic [31:0] lfsr = 32'h1;
logic [4:0]  rnd_bits;                          // the random block number's width
logic        sum_on, sum_done;
logic [11:0] sum_left;

always_ff @(posedge clk) begin
    ack_d <= sd_ack;

    if (mounted) begin
        have_image   <= img_size != 0;
        image_blocks <= img_size[40:9];
        // widest power of two of blocks within the image, for the random positions
        rnd_bits <= 5'd0;
        for (int b = 0; b < 31; b++) if (img_size[9 + b]) rnd_bits <= 5'(b);
        next_lba <= 32'd0;
    end

    if (run) run_clocks <= run_clocks + 32'd1;

    case (st)
    IDLE:
        if (run && have_image) begin
            sd_lba <= next_lba;
            sd_rd  <= 1'b1;
            lat    <= 32'd0;
            first  <= 1'b1;
            st     <= ASK;
            if (next_lba == 32'd0 && !sum_done) begin sum_on <= 1'b1; sum_left <= 12'd2047; end
        end
    ASK: begin
        lat <= lat + 32'd1;
        if (sd_ack) begin sd_rd <= 1'b0; st <= XFER; end
    end
    XFER: begin
        if (first) lat <= lat + 32'd1;
        if (sd_buff_wr && sd_ack) begin
            words <= words + 32'd1;
            if (first) begin
                first <= 1'b0;
                latency_sum <= latency_sum + lat;
                if (lat > latency_max) latency_max <= lat;
            end
            if (sum_on) begin
                checksum <= checksum + {16'd0, sd_buff_dout};
                if (sum_left == 12'd0) begin sum_on <= 1'b0; sum_done <= 1'b1; end
                else sum_left <= sum_left - 12'd1;
            end
        end
        if (ack_d && !sd_ack) begin
            requests <= requests + 32'd1;
            lfsr <= {lfsr[30:0], lfsr[31] ^ lfsr[21] ^ lfsr[1] ^ lfsr[0]};
            if (rnd) next_lba <= lfsr & ((32'd1 << rnd_bits) - 32'd1);
            // wrap when the next request would run past the image's last whole block
            else if (sd_lba + 32'(2 * (BLKCNT + 1)) > image_blocks) next_lba <= 32'd0;
            else next_lba <= sd_lba + 32'(BLKCNT + 1);
            st <= IDLE;
        end
    end
    default: st <= IDLE;
    endcase

    if (clear) begin
        requests <= 0; words <= 0; run_clocks <= 0; latency_sum <= 0; latency_max <= 0;
        checksum <= 0; sum_on <= 1'b0; sum_done <= 1'b0; sum_left <= 12'd0; next_lba <= 32'd0;
    end
end

initial begin
    st = IDLE; sd_rd = 1'b0; sd_lba = 0; have_image = 1'b0; image_blocks = 0;
    requests = 0; words = 0; run_clocks = 0; latency_sum = 0; latency_max = 0; checksum = 0;
    next_lba = 0; sum_on = 1'b0; sum_done = 1'b0; sum_left = 0; rnd_bits = 0; ack_d = 1'b0; first = 1'b0; lat = 0;
end

endmodule
