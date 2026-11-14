// SPDX-License-Identifier: GPL-3.0-or-later
//
// KBM: the XT446's MIDI in (chan1's transmit, the bytes MAME's firebeat.cpp sends to xt446 midi_w)
// handed to the sound server on the HPS (MiSTer_ArcadeSoundServer, src/firebeat/), which plays
// them on a SoundFont synth (docs/HACKS.md). A block of DDR3 shared with the server, written
// through a wide hornet_ddr3 master; little-endian 64-bit words, byte offsets from SHM:
//
//   +0x00   "FBMI", version 1                                        every BEAT
//   +0x10   {count of ring entries written, 32}                      after each entry
//   +0x18   {beat count (+1 every BEAT), 32}                         every BEAT
//   +0x20   {board resets 16, 0 14, mute 1, held 1}                  every BEAT and each change
//   +0x1000 ring of RING entries {0 16, byte 8, 0 8, microseconds 32}
//
// Each byte is stamped when its stop bit went out, so the server can replay them at their
// spacing. An entry is written before the count that covers it, through the same master, so the
// count never runs ahead of the ring. held: the board in reset or paused, notes left sounding are
// for the server to silence; resets counts the board's resets (a watchdog reset included), after
// which the synth starts afresh; mute: the notes go to the MIDI port only (OSD Notes to), the server
// stays silent. Write-only: the server sends nothing back.

module fb_midibridge #(
    parameter logic [31:0] SHM  = 32'h3F20_0000,
    parameter int          RING = 512,
    parameter int          BEAT = 666_667           // 10 ms at 66.667 MHz
) (
    input  logic        clk,
    input  logic        reset,                      // the DDR3 side's
    input  logic        brd_reset,
    input  logic        held,
    input  logic        mute,

    input  logic        tx_v,                       // fb_board's midi_tx_*
    input  logic [7:0]  tx_byte,

    output logic        m_write,
    output logic [31:0] m_addr,
    output logic [10:0] m_burst,
    output logic [31:0] m_wdata,
    output logic [31:0] m_wdata_hi,
    input  logic        m_waitn
);

localparam int RW = $clog2(RING);

// microseconds: 66.667 MHz x 3 / 200
logic [7:0]  frac;
logic [31:0] us;
always_ff @(posedge clk) begin
    if (frac >= 8'd197) begin frac <= frac - 8'd197; us <= us + 1'd1; end
    else frac <= frac + 8'd3;
end

// a byte every 320 us at 31250 baud: a short queue covers the beat's three writes
logic [39:0] q [8];                                 // {us, byte}
logic [2:0]  q_wp, q_rp;
wire         q_empty = q_wp == q_rp;
always_ff @(posedge clk) begin
    if (tx_v && q_wp + 3'd1 != q_rp) begin q[q_wp] <= {us, tx_byte}; q_wp <= q_wp + 1'd1; end
    if (reset) q_wp <= '0;
end

logic [31:0] count, beats;
logic [15:0] resets;
logic        rst_d;
logic [1:0]  st_r, st_sent;                        // {mute, held}
logic [19:0] beat_t;
logic        beat_due;

typedef enum logic [2:0] { S_IDLE, S_ENTRY, S_COUNT, S_MAGIC, S_BEAT, S_STATE } st_t;
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
        end else if (beat_due) begin
            beat_due <= 1'b0;
            m_addr <= SHM; m_wdata <= 32'h494D_4246; m_wdata_hi <= 32'd1;      // "FBMI"
            m_write <= 1'b1; st <= S_MAGIC;
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
    S_STATE: if (m_waitn) begin m_write <= 1'b0; st <= S_IDLE; end
    default: st <= S_IDLE;
    endcase

    if (reset) begin
        st <= S_IDLE; m_write <= 1'b0; q_rp <= '0;
        count <= '0; beats <= '0; resets <= '0; st_sent <= 2'd0;
        beat_t <= '0; beat_due <= 1'b1;
    end
end

assign m_burst = 11'd2;                             // one 64-bit beat

endmodule
