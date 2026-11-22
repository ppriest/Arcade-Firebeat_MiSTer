// SPDX-License-Identifier: GPL-3.0-or-later
//
// MIDI chan1's transmit (the bytes MAME's firebeat.cpp sends to xt446 midi_w, or bm3's to the
// ST-224) handed to the sound server on the HPS (MiSTer_ArcadeSoundServer, src/firebeat/): KBM's
// XT446 as a SoundFont synth, bm3's ST-224 (ST224) as an effects unit on the RF5C400's effect sends
// (docs/HACKS.md). A block of DDR3 shared with the server, through a wide hornet_ddr3 master;
// little-endian 64-bit words, byte offsets from SHM:
//
//   +0x00   "FBMI", version 1 (2 with ST224)                         every BEAT
//   +0x10   {count of ring entries written, 32}                      after each entry
//   +0x18   {beat count (+1 every BEAT), 32}                         every BEAT
//   +0x20   {board resets 16, 0 14, mute 1, held 1}                  every BEAT and each change
//   +0x28   ST224: {count of send frames written, 32}                after each frame
//   +0x30   ST224: {the server's heartbeat, 32}, written by the server, read every BEAT
//   +0x1000 ring of RING entries {0 16, byte 8, 0 8, microseconds 32}
//   +0x2000 ST224: ring of SRING send frames {microseconds 32, right 16, left 16}, 44.1 kHz
//
// Each byte is stamped when its stop bit went out, each send frame when the RF5C400 produced it,
// so the server can replay them at their spacing. An entry is written before the count that
// covers it, through the same master, so the count never runs ahead of the ring. held: the board
// in reset or paused, notes left sounding are for the server to silence; resets counts the board's
// resets (a watchdog reset included), after which the server starts afresh; mute: the bytes go to
// the MIDI port only (a real unit there), the server stays silent and, for the ST-224, stops its
// heartbeat. server_on: the heartbeat changed within the last ALIVE beats; the core then leaves
// the sends to the server. Without ST224 the block is write-only.

module fb_midibridge #(
    parameter logic [31:0] SHM   = 32'h3F20_0000,
    parameter int          RING  = 512,
    parameter int          SRING = 2048,
    parameter int          BEAT  = 666_667,          // 10 ms at 66.667 MHz
    parameter int          ALIVE = 5,
    parameter bit          ST224 = 0
) (
    input  logic        clk,
    input  logic        reset,                      // the DDR3 side's
    input  logic        brd_reset,
    input  logic        held,
    input  logic        mute,

    input  logic        tx_v,                       // fb_board's midi_tx_*
    input  logic [7:0]  tx_byte,

    input  logic        send_v,                     // ST224: fb_rf5c400's sample, send_*
    input  logic [15:0] send_l, send_r,
    output logic        server_on,

    output logic        m_read,
    output logic        m_write,
    output logic [31:0] m_addr,
    output logic [10:0] m_burst,
    output logic [31:0] m_wdata,
    output logic [31:0] m_wdata_hi,
    input  logic        m_waitn,
    input  logic        m_rvalid,
    input  logic [31:0] m_rdata
);

localparam int RW = $clog2(RING);
localparam int SW = $clog2(SRING);

// microseconds: 66.667 MHz x 3 / 200
logic [7:0]  frac;
logic [31:0] us;
always_ff @(posedge clk) begin
    if (frac >= 8'd197) begin frac <= frac - 8'd197; us <= us + 1'd1; end
    else frac <= frac + 8'd3;
end

// a byte every 320 us at 31250 baud: a short queue covers the beat's writes
logic [39:0] q [8];                                 // {us, byte}
logic [2:0]  q_wp, q_rp;
wire         q_empty = q_wp == q_rp;
always_ff @(posedge clk) begin
    if (tx_v && q_wp + 3'd1 != q_rp) begin q[q_wp] <= {us, tx_byte}; q_wp <= q_wp + 1'd1; end
    if (reset) q_wp <= '0;
end

// a send frame every 1512 clocks; the queue covers a beat's writes and a slow DDR3 turn
logic [63:0] f [8];                                 // {us, right, left}
logic [2:0]  f_wp, f_rp;
wire         f_empty = !ST224 || f_wp == f_rp;
always_ff @(posedge clk) begin
    if (ST224 && send_v && f_wp + 3'd1 != f_rp) begin f[f_wp] <= {us, send_r, send_l}; f_wp <= f_wp + 1'd1; end
    if (reset) f_wp <= '0;
end

logic [31:0] count, beats, frames, hb;
logic [15:0] resets;
logic        rst_d;
logic [1:0]  st_r, st_sent;                        // {mute, held}
logic [19:0] beat_t;
logic        beat_due, hb_due, hb_ok;           // hb_ok: hb holds a value read since reset
logic [3:0]  stale;                                 // beats since the heartbeat last changed

typedef enum logic [3:0] { S_IDLE, S_ENTRY, S_COUNT, S_MAGIC, S_BEAT, S_STATE, S_FRAME, S_FCOUNT,
                           S_HBRD, S_HBWAIT } st_t;
st_t st;

always_ff @(posedge clk) begin
    if (beat_t == 20'(BEAT - 1)) begin beat_t <= '0; beat_due <= 1'b1; end
    else beat_t <= beat_t + 1'd1;
    rst_d <= brd_reset;
    if (brd_reset && !rst_d) resets <= resets + 1'd1;
    st_r <= {mute, brd_reset || held};

    case (st)
    S_IDLE:
        if (!q_empty) begin
            m_addr <= SHM + 32'h1000 + {count[RW-1:0], 3'b000};
            m_wdata <= q[q_rp][39:8];
            m_wdata_hi <= {16'h0, q[q_rp][7:0], 8'h0};
            q_rp <= q_rp + 1'd1;
            m_write <= 1'b1; st <= S_ENTRY;
        end else if (!f_empty) begin
            m_addr <= SHM + 32'h2000 + {frames[SW-1:0], 3'b000};
            {m_wdata_hi, m_wdata} <= f[f_rp];
            f_rp <= f_rp + 1'd1;
            m_write <= 1'b1; st <= S_FRAME;
        end else if (beat_due) begin
            beat_due <= 1'b0;
            m_addr <= SHM; m_wdata <= 32'h494D_4246; m_wdata_hi <= ST224 ? 32'd2 : 32'd1;   // "FBMI"
            m_write <= 1'b1; st <= S_MAGIC;
        end else if (hb_due) begin
            hb_due <= 1'b0;
            m_addr <= SHM + 32'h30;
            m_read <= 1'b1; st <= S_HBRD;
        end else if (st_r != st_sent) begin
            st_sent <= st_r;
            m_addr <= SHM + 32'h20; m_wdata <= {30'd0, st_r}; m_wdata_hi <= {16'd0, resets};
            m_write <= 1'b1; st <= S_STATE;
        end
    S_ENTRY: if (m_waitn) begin
        count <= count + 1'd1;
        m_addr <= SHM + 32'h10; m_wdata <= count + 1'd1; m_wdata_hi <= '0;
        st <= S_COUNT;
    end
    S_COUNT: if (m_waitn) begin m_write <= 1'b0; st <= S_IDLE; end
    S_FRAME: if (m_waitn) begin
        frames <= frames + 1'd1;
        m_addr <= SHM + 32'h28; m_wdata <= frames + 1'd1; m_wdata_hi <= '0;
        st <= S_COUNT;
    end
    S_MAGIC: if (m_waitn) begin
        beats <= beats + 1'd1;
        m_addr <= SHM + 32'h18; m_wdata <= beats + 1'd1; m_wdata_hi <= '0;
        st <= S_BEAT;
    end
    S_BEAT: if (m_waitn) begin
        st_sent <= st_r;
        m_addr <= SHM + 32'h20; m_wdata <= {30'd0, st_r}; m_wdata_hi <= {16'd0, resets};
        st <= S_STATE;
    end
    S_STATE: if (m_waitn) begin
        m_write <= 1'b0; st <= S_IDLE;
        hb_due <= ST224;
    end
    S_HBRD: if (m_waitn) begin m_read <= 1'b0; st <= S_HBWAIT; end
    S_HBWAIT: if (m_rvalid) begin
        hb <= m_rdata; hb_ok <= 1'b1;
        if (hb_ok && m_rdata != hb) stale <= '0;
        else if (stale != 4'hF) stale <= stale + 1'd1;
        st <= S_IDLE;
    end
    default: st <= S_IDLE;
    endcase

    if (reset) begin
        st <= S_IDLE; m_write <= 1'b0; m_read <= 1'b0; q_rp <= '0; f_rp <= '0;
        count <= '0; beats <= '0; frames <= '0; resets <= '0; st_sent <= 2'd0;
        beat_t <= '0; beat_due <= 1'b1; hb_due <= 1'b0; hb_ok <= 1'b0; stale <= 4'hF;
    end
end

// the switch at a frame's edge, so no frame is half one path and half the other
always_ff @(posedge clk) begin
    if (send_v || !ST224) server_on <= ST224 && stale < 4'(ALIVE);
    if (reset) server_on <= 1'b0;
end

assign m_burst = 11'd2;                             // one 64-bit beat

endmodule
